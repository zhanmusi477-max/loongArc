`timescale 1ns / 1ps

module InstBuffer #(
    parameter DEPTH = 4,
    // Keep the existing single-pop instance cycle-for-cycle compatible until
    // the dual-issue top level explicitly connects pop2.  With the default
    // value an omitted pop2 port is a Z in simulation, but the constant false
    // arm below removes it from every state transition.
    parameter ENABLE_POP2 = 0
) (
    input  wire         cpu_clk,
    input  wire         cpu_rstn,
    input  wire         flush,
    input  wire         push,
    input  wire         pop,
    input  wire         pop2,

    input  wire [31:0]  pc_in,
    input  wire [31:0]  inst_in,
    input  wire         r2_use_rd_in,
    input  wire [31:0]  target_offset_in,
    input  wire         pred_taken_in,
    input  wire [31:0]  pred_target_in,

    output wire         valid,
    output wire         valid2,
    output wire         full,
    output wire         empty,
    output wire         can_fetch,
    output wire         resume_fetch,
    output wire [31:0]  pc_out,
    output wire [31:0]  inst_out,
    // Eager one-bit second-source address metadata.  It is captured with the
    // same next payload as each visible head, so ID1 selects rd/rk with one
    // mux instead of decoding the opcode in front of the RF read address.
    output wire         r2_use_rd_out,
    output wire         r2_use_rd_out2,
    // True when the current head PC is exactly four bytes after the previous
    // instruction accepted by this FIFO.  Pair admission consumes this
    // registered sidecar instead of rebuilding a 32-bit PC+4 comparison from
    // the live head and feeding that result back into the head payload D mux.
    output wire         seq_from_prev_out,
    // Slot-1 pair metadata is decoded one cycle after its instruction enters
    // the registered bank and is read by the registered circular head pointer.
    // ICache response data therefore crosses a register before opcode decode,
    // and backend pop/count control never drives a metadata register.
    output wire         pair_eligible_out,
    output wire [ 4:0]  pair_rR1_out,
    output wire         pair_rR1_re_out,
    output wire [ 4:0]  pair_rR2_out,
    output wire         pair_rR2_re_out,
    output wire [ 4:0]  pair_wR_out,
    output wire         pair_writes_gpr_out,
    output wire [31:0]  target_offset_out,
    output wire         pred_taken_out,
    output wire [31:0]  pred_target_out,
    output wire [31:0]  pc_out2,
    output wire [31:0]  inst_out2,
    // Registered conservative B->C dependency carried beside the second
    // visible entry.  Pair admission consumes this one-bit sidecar instead of
    // feeding C's three live register fields back through the pop/head muxes.
    output wire         raw_from_prev_out2,
    output wire [31:0]  target_offset_out2,
    output wire         pred_taken_out2,
    output wire [31:0]  pred_target_out2
);

    localparam COUNT_W = $clog2(DEPTH + 1);
    localparam PTR_W = $clog2(DEPTH);
    localparam [COUNT_W-1:0] DEPTH_COUNT = DEPTH;
    localparam [COUNT_W-1:0] COUNT_1 = 1;
    localparam [COUNT_W-1:0] COUNT_2 = 2;
    localparam [COUNT_W-1:0] COUNT_3 = 3;

    function r2_use_rd_decode;
        input [31:0] inst;
        begin
            r2_use_rd_decode =
                (inst[31:24] == 8'h04) ||
                ((inst[31:24] == 8'h29) &&
                 !(inst[23] && inst[22])) ||
                (inst[31:27] == 5'b01011) ||
                (inst[31:28] == 4'b0110);
        end
    endfunction

    // Force a four-entry FF bank.  A LUTRAM read reintroduces rd_ptr ->
    // distributed-RAM -> ID1 decode timing; FF data plus the 4:1 output mux
    // maps to one LUT per payload bit.
    (* ram_style = "registers" *)
    reg [31:0] pc_mem          [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg [31:0] inst_mem        [0:DEPTH-1];
    // Predecode the rd/rk selector before the entry reaches either visible
    // head.  Keeping this one bit beside the instruction removes opcode
    // decode from the circular-bank/head-bypass selection path.
    (* ram_style = "registers" *)
    reg        r2_use_rd_mem   [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg        seq_from_prev_mem [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg [ 5:0] raw_match_parts_mem [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg [31:0] target_offset_mem [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg        pred_taken_mem  [0:DEPTH-1];
    (* ram_style = "registers" *)
    reg [31:0] pred_target_mem [0:DEPTH-1];
    localparam PAIR_META_W = 19;

    reg [COUNT_W-1:0] count;
    reg [PTR_W-1:0] rd_ptr;
    reg [PTR_W-1:0] wr_ptr;

    // A full-buffer pop may coincide with the last already-issued ICache
    // response.  Capture that response in a one-entry tail skid, then commit
    // it to the newly freed circular slot on the following edge.  Main payload
    // write enables therefore depend only on registered occupancy or the
    // registered skid-valid bit, never on the same-cycle decode/pop path.
    reg        overflow_valid;
    reg [31:0] overflow_pc;
    reg [31:0] overflow_inst;
    reg        overflow_r2_use_rd;
    reg [ 5:0] overflow_raw_match_parts;
    reg        overflow_seq_from_prev;
    reg [31:0] overflow_target_offset;
    reg        overflow_pred_taken;
    reg [31:0] overflow_pred_target;

    assign empty = count == {COUNT_W{1'b0}};
    wire main_full = count == DEPTH_COUNT;
    assign full  = main_full || overflow_valid;
    assign valid = !empty;
    assign valid2 = count >= {{(COUNT_W-2){1'b0}}, 2'b10};

    wire do_pop  = pop && valid;
    // pop remains the request to consume the oldest instruction.  pop2 only
    // extends an accepted pop to two entries and can never consume by itself.
    // The parameterized select fully masks an unconnected pop2 input in the
    // current single-issue top level.
    wire pop2_req = ENABLE_POP2 ? pop2 : 1'b0;
    // This fact deliberately excludes do_pop.  State transitions still use
    // do_pop_second below, while credit prediction can evaluate the result of
    // a hypothetical accepted pop in parallel with the incoming pop signal.
    wire pop2_accept_if_pop = pop2_req && valid2;
    wire do_pop_second = do_pop && pop2_accept_if_pop;
    wire do_push_main = push && !main_full && !overflow_valid;
    wire overflow_capture = push && main_full && !overflow_valid;
    wire overflow_accept = overflow_capture && do_pop;
    wire overflow_commit = overflow_valid;
    // While the skid entry is invalid its payload is architecturally
    // unobservable, so continuously prewrite the current response data.  The
    // capture edge then changes only overflow_valid.  Once valid, the payload
    // is held until it commits to the main FIFO on the following edge.
    wire overflow_payload_prewrite = !overflow_valid;
    wire main_write = do_push_main || overflow_commit;
    wire [31:0] main_write_pc = overflow_commit ? overflow_pc : pc_in;
    wire [31:0] main_write_inst =
        overflow_commit ? overflow_inst : inst_in;
    wire main_write_r2_use_rd = overflow_commit ?
        overflow_r2_use_rd : r2_use_rd_in;
    // Accepted instruction responses form the exact FIFO order.  Remembering
    // the last accepted PC lets every new entry carry its relationship to its
    // predecessor even when the queue temporarily becomes empty.
    reg        last_enqueued_valid;
    reg [31:0] last_enqueued_pc;
    // Writer metadata for the most recently accepted instruction.  The
    // pending decoder below supplies the immediately preceding instruction on
    // back-to-back pushes; this saved copy covers bubbles between pushes.
    reg        last_pair_writes_gpr;
    reg [ 4:0] last_pair_wR;
    wire [ 5:0] incoming_raw_match_parts;
    wire [ 5:0] main_write_raw_match_parts;
    wire incoming_seq_from_prev = last_enqueued_valid &&
                                  (pc_in == (last_enqueued_pc + 32'd4));
    wire main_write_seq_from_prev = overflow_commit ?
        overflow_seq_from_prev : incoming_seq_from_prev;
    wire [31:0] main_write_target_offset =
        overflow_commit ? overflow_target_offset : target_offset_in;
    wire main_write_pred_taken =
        overflow_commit ? overflow_pred_taken : pred_taken_in;
    wire [31:0] main_write_pred_target =
        overflow_commit ? overflow_pred_target : pred_target_in;
    // The circular tail names an architecturally free slot whenever the main
    // bank is not full.  Prewrite that free slot from the current response
    // payload even when push is low; without a pointer/count advance the value
    // is invisible and will simply be replaced by a later prewrite.  A real
    // push still owns all validity, pointer and count changes below.  This
    // removes ICache BRAM hit/tag logic from every payload CE while preserving
    // the exact one-response-per-cycle schedule.
    wire payload_prewrite = !main_full || overflow_commit;
    wire [COUNT_W-1:0] count_after =
        count + {{(COUNT_W-1){1'b0}}, main_write} -
                {{(COUNT_W-1){1'b0}}, do_pop} -
                {{(COUNT_W-1){1'b0}}, do_pop_second};

    // Keep occupancy arithmetic away from IF/ICache enables and reserve one
    // slot for the response already in the one-request ICache pipeline.  A
    // count of DEPTH-1 therefore stops new requests without consulting this
    // cycle's push/pop; recovery is intentionally one cycle conservative.
    localparam [COUNT_W-1:0] FETCH_LIMIT = DEPTH - 1;
    assign can_fetch = flush ||
                       ((count < FETCH_LIMIT) && !overflow_valid);

    // Generate the restart pulse from the exact registered occupancy/skid
    // next state.  The former top-level full/push/pop2 approximation missed a
    // skid-commit boundary and could also pulse one cycle too early after a
    // full+push+pop2 transaction.  This logic ends at a local flop and never
    // feeds IBUF payload selection or same-cycle IF enables.
    wire resume_fetch_event;
    generate
        if (DEPTH == 4) begin : g_fast_resume_credit
            // resume_fetch_event is already guarded by do_pop.  Under that
            // guard, overflow_accept == overflow_capture and do_pop_second ==
            // pop2_accept_if_pop.  Substituting those equalities removes the
            // pop -> occupancy -> pop reconvergence without changing a pulse.
            wire post_fetch_credit_if_pop = !overflow_capture &&
                ((count == COUNT_2) ||
                 ((count == COUNT_3) &&
                  (!main_write || pop2_accept_if_pop)) ||
                 ((count == DEPTH_COUNT) && pop2_accept_if_pop));
            // When fetch is blocked the FIFO is necessarily non-empty, so a
            // raw pop request is already an accepted pop.  Use that fact at
            // this local register boundary to avoid rebuilding valid from
            // count after the backend-ready cone.
            assign resume_fetch_event = !can_fetch && pop &&
                                        post_fetch_credit_if_pop;
        end else begin : g_generic_resume_credit
            wire [COUNT_W-1:0] count_after_if_pop =
                count + {{(COUNT_W-1){1'b0}}, main_write} - COUNT_1 -
                {{(COUNT_W-1){1'b0}}, pop2_accept_if_pop};
            wire post_fetch_credit_if_pop =
                (count_after_if_pop < FETCH_LIMIT) && !overflow_capture;
            assign resume_fetch_event = !can_fetch && pop &&
                                        post_fetch_credit_if_pop;
        end
    endgenerate

    reg resume_fetch_r;
    assign resume_fetch = resume_fetch_r;
    always @(posedge cpu_clk) begin
        if (!cpu_rstn || flush)
            resume_fetch_r <= 1'b0;
        else
            resume_fetch_r <= resume_fetch_event;
    end

    // Keep both architecturally visible heads as register mirrors.  Their
    // native clock enables are split by payload group below, so backend ready
    // does not drive one 258-bit CE net and neither ID port reads through the
    // circular-bank mux.
    (* extract_enable = "yes" *) reg [31:0] pc_head;
    (* extract_enable = "yes" *) reg [31:0] inst_head;
    (* extract_enable = "yes", keep = "true" *) reg r2_use_rd_head;
    (* extract_enable = "yes" *) reg [31:0] target_offset_head;
    (* extract_enable = "yes" *) reg        pred_taken_head;
    (* extract_enable = "yes" *) reg [31:0] pred_target_head;
    // Pair metadata is written one cycle after the instruction payload.  The
    // pending instruction is itself registered, so neither ICache response
    // data nor pop/count control can reach a metadata-bank D pin through the
    // slot-1 decoder.  A four-entry queue always gives a newly written entry
    // this one cycle before it can be the observable head while valid2=1.
    (* ram_style = "registers" *)
    reg [PAIR_META_W-1:0] pair_meta_mem [0:DEPTH-1];
    (* KEEP = "true" *) reg [31:0] pair_meta_pending_inst;
    (* KEEP = "true" *) reg [PTR_W-1:0] pair_meta_pending_ptr;
    (* KEEP = "true" *) reg pair_meta_pending_valid;
    (* extract_enable = "yes" *) reg [31:0] pc_head2;
    (* extract_enable = "yes" *) reg [31:0] inst_head2;
    (* extract_enable = "yes", keep = "true" *) reg r2_use_rd_head2;
    (* extract_enable = "yes" *) reg [31:0] target_offset_head2;
    (* extract_enable = "yes" *) reg        pred_taken_head2;
    (* extract_enable = "yes" *) reg [31:0] pred_target_head2;
    wire [PTR_W-1:0] rd_ptr_next =
        (rd_ptr == DEPTH-1) ? {PTR_W{1'b0}} :
                              rd_ptr + {{(PTR_W-1){1'b0}}, 1'b1};
    wire [PTR_W-1:0] rd_ptr_next2 =
        (rd_ptr_next == DEPTH-1) ? {PTR_W{1'b0}} :
                                   rd_ptr_next +
                                   {{(PTR_W-1){1'b0}}, 1'b1};
    wire [PTR_W-1:0] rd_ptr_next3 =
        (rd_ptr_next2 == DEPTH-1) ? {PTR_W{1'b0}} :
                                    rd_ptr_next2 +
                                    {{(PTR_W-1){1'b0}}, 1'b1};
    wire [PTR_W-1:0] wr_ptr_next =
        (wr_ptr == DEPTH-1) ? {PTR_W{1'b0}} :
                              wr_ptr + {{(PTR_W-1){1'b0}}, 1'b1};

    reg [31:0] next_pc_head;
    reg [31:0] next_inst_head;
    reg        next_r2_use_rd_head;
    reg [31:0] next_target_offset_head;
    reg        next_pred_taken_head;
    reg [31:0] next_pred_target_head;
    reg [31:0] next2_pc_head;
    reg [31:0] next2_inst_head;
    reg        next2_r2_use_rd_head;
    reg [31:0] next2_target_offset_head;
    reg        next2_pred_taken_head;
    reg [31:0] next2_pred_target_head;
    reg [31:0] next3_pc_head;
    reg [31:0] next3_inst_head;
    reg        next3_r2_use_rd_head;
    reg [31:0] next3_target_offset_head;
    reg        next3_pred_taken_head;
    reg [31:0] next3_pred_target_head;
    always @(*) begin
        case (rd_ptr_next)
            0: begin
                next_pc_head            = pc_mem[0];
                next_inst_head          = inst_mem[0];
                next_r2_use_rd_head      = r2_use_rd_mem[0];
                next_target_offset_head = target_offset_mem[0];
                next_pred_taken_head    = pred_taken_mem[0];
                next_pred_target_head   = pred_target_mem[0];
            end
            1: begin
                next_pc_head            = pc_mem[1];
                next_inst_head          = inst_mem[1];
                next_r2_use_rd_head      = r2_use_rd_mem[1];
                next_target_offset_head = target_offset_mem[1];
                next_pred_taken_head    = pred_taken_mem[1];
                next_pred_target_head   = pred_target_mem[1];
            end
            2: begin
                next_pc_head            = pc_mem[2];
                next_inst_head          = inst_mem[2];
                next_r2_use_rd_head      = r2_use_rd_mem[2];
                next_target_offset_head = target_offset_mem[2];
                next_pred_taken_head    = pred_taken_mem[2];
                next_pred_target_head   = pred_target_mem[2];
            end
            default: begin
                next_pc_head            = pc_mem[DEPTH-1];
                next_inst_head          = inst_mem[DEPTH-1];
                next_r2_use_rd_head      = r2_use_rd_mem[DEPTH-1];
                next_target_offset_head = target_offset_mem[DEPTH-1];
                next_pred_taken_head    = pred_taken_mem[DEPTH-1];
                next_pred_target_head   = pred_target_mem[DEPTH-1];
            end
        endcase
        case (rd_ptr_next2)
            0: begin
                next2_pc_head            = pc_mem[0];
                next2_inst_head          = inst_mem[0];
                next2_r2_use_rd_head      = r2_use_rd_mem[0];
                next2_target_offset_head = target_offset_mem[0];
                next2_pred_taken_head    = pred_taken_mem[0];
                next2_pred_target_head   = pred_target_mem[0];
            end
            1: begin
                next2_pc_head            = pc_mem[1];
                next2_inst_head          = inst_mem[1];
                next2_r2_use_rd_head      = r2_use_rd_mem[1];
                next2_target_offset_head = target_offset_mem[1];
                next2_pred_taken_head    = pred_taken_mem[1];
                next2_pred_target_head   = pred_target_mem[1];
            end
            2: begin
                next2_pc_head            = pc_mem[2];
                next2_inst_head          = inst_mem[2];
                next2_r2_use_rd_head      = r2_use_rd_mem[2];
                next2_target_offset_head = target_offset_mem[2];
                next2_pred_taken_head    = pred_taken_mem[2];
                next2_pred_target_head   = pred_target_mem[2];
            end
            default: begin
                next2_pc_head            = pc_mem[DEPTH-1];
                next2_inst_head          = inst_mem[DEPTH-1];
                next2_r2_use_rd_head      = r2_use_rd_mem[DEPTH-1];
                next2_target_offset_head = target_offset_mem[DEPTH-1];
                next2_pred_taken_head    = pred_taken_mem[DEPTH-1];
                next2_pred_target_head   = pred_target_mem[DEPTH-1];
            end
        endcase
        case (rd_ptr_next3)
            0: begin
                next3_pc_head            = pc_mem[0];
                next3_inst_head          = inst_mem[0];
                next3_r2_use_rd_head      = r2_use_rd_mem[0];
                next3_target_offset_head = target_offset_mem[0];
                next3_pred_taken_head    = pred_taken_mem[0];
                next3_pred_target_head   = pred_target_mem[0];
            end
            1: begin
                next3_pc_head            = pc_mem[1];
                next3_inst_head          = inst_mem[1];
                next3_r2_use_rd_head      = r2_use_rd_mem[1];
                next3_target_offset_head = target_offset_mem[1];
                next3_pred_taken_head    = pred_taken_mem[1];
                next3_pred_target_head   = pred_target_mem[1];
            end
            2: begin
                next3_pc_head            = pc_mem[2];
                next3_inst_head          = inst_mem[2];
                next3_r2_use_rd_head      = r2_use_rd_mem[2];
                next3_target_offset_head = target_offset_mem[2];
                next3_pred_taken_head    = pred_taken_mem[2];
                next3_pred_target_head   = pred_target_mem[2];
            end
            default: begin
                next3_pc_head            = pc_mem[DEPTH-1];
                next3_inst_head          = inst_mem[DEPTH-1];
                next3_r2_use_rd_head      = r2_use_rd_mem[DEPTH-1];
                next3_target_offset_head = target_offset_mem[DEPTH-1];
                next3_pred_taken_head    = pred_taken_mem[DEPTH-1];
                next3_pred_target_head   = pred_target_mem[DEPTH-1];
            end
        endcase
    end
    assign pc_out          = pc_head;
    assign inst_out        = inst_head;
    assign r2_use_rd_out   = r2_use_rd_head;
    assign r2_use_rd_out2  = r2_use_rd_head2;
    reg seq_from_prev_visible;
    always @(*) begin
        case (rd_ptr)
            0: seq_from_prev_visible = seq_from_prev_mem[0];
            1: seq_from_prev_visible = seq_from_prev_mem[1];
            2: seq_from_prev_visible = seq_from_prev_mem[2];
            default: seq_from_prev_visible = seq_from_prev_mem[DEPTH-1];
        endcase
    end
    assign seq_from_prev_out = seq_from_prev_visible;
    // The second visible FIFO entry is always rd_ptr+1.  Read its registered
    // one-bit sidecar directly from the tiny FF bank.  This intentionally has
    // no same-cycle main-write bypass: after an entry is accepted, the bank FF
    // and rd/count state change on the same edge, so the new value is already
    // visible throughout the first cycle in which valid2 can be true.
    reg [5:0] raw_match_parts_visible2;
    always @(*) begin
        case (rd_ptr_next)
            0: raw_match_parts_visible2 = raw_match_parts_mem[0];
            1: raw_match_parts_visible2 = raw_match_parts_mem[1];
            2: raw_match_parts_visible2 = raw_match_parts_mem[2];
            default: raw_match_parts_visible2 =
                         raw_match_parts_mem[DEPTH-1];
        endcase
    end
    // (valid&&low2 && high3) for each of rj, rk and rd.  Writer validity is
    // already folded into the three low partials at enqueue, so the six
    // registered bits fit exactly in one LUT6 with no seventh control input.
    wire raw_field_match_visible2 =
        (raw_match_parts_visible2[5] && raw_match_parts_visible2[4]) ||
        (raw_match_parts_visible2[3] && raw_match_parts_visible2[2]) ||
        (raw_match_parts_visible2[1] && raw_match_parts_visible2[0]);
    assign raw_from_prev_out2 = raw_field_match_visible2;
    reg [PAIR_META_W-1:0] pair_meta_visible_reference;
    always @(*) begin
        case (rd_ptr)
            0: pair_meta_visible_reference = pair_meta_mem[0];
            1: pair_meta_visible_reference = pair_meta_mem[1];
            2: pair_meta_visible_reference = pair_meta_mem[2];
            default: pair_meta_visible_reference = pair_meta_mem[DEPTH-1];
        endcase
    end
    assign {
        pair_eligible_out,
        pair_rR1_out, pair_rR1_re_out,
        pair_rR2_out, pair_rR2_re_out,
        pair_wR_out, pair_writes_gpr_out
    } = pair_meta_visible_reference;
    assign target_offset_out = target_offset_head;
    assign pred_taken_out  = pred_taken_head;
    assign pred_target_out = pred_target_head;
    assign pc_out2          = pc_head2;
    assign inst_out2        = inst_head2;
    assign target_offset_out2 = target_offset_head2;
    assign pred_taken_out2  = pred_taken_head2;
    assign pred_target_out2 = pred_target_head2;

    // Select both post-pop heads from the old registered bank.  When a pop
    // consumes every old entry, or leaves exactly one old entry before a
    // simultaneous tail write, the just-written payload is not visible from
    // the FF bank until after the edge.  The local main_write bypass handles
    // those cases, including an overflow-skid commit following a full pop2.
    wire dual_head_uses_main_write;
    wire head2_uses_main_write;
    generate
        if (DEPTH == 4) begin : g_fast_head_bypass_select
            // Payload mirrors already have native clock enables.  Evaluate
            // their D inputs for the hypothetical accepted pop2 directly;
            // on every edge where a mirror is actually written this is
            // identical to do_pop_second.  Removing do_pop/id_refill_fire
            // from these equations keeps backend readiness on CE only.
            assign dual_head_uses_main_write = empty ||
                (count == COUNT_1) ||
                (pop2_accept_if_pop && (count == COUNT_2));
            assign head2_uses_main_write =
                (count == COUNT_1) ||
                (!pop2_accept_if_pop && (count == COUNT_2)) ||
                ( pop2_accept_if_pop && (count == COUNT_3));
        end else begin : g_generic_head_bypass_select
            wire [COUNT_W-1:0] count_after_pop_generic =
                count - {{(COUNT_W-1){1'b0}}, do_pop} -
                        {{(COUNT_W-1){1'b0}}, do_pop_second};
            assign dual_head_uses_main_write = empty ||
                (do_pop &&
                 (count_after_pop_generic == {COUNT_W{1'b0}}));
            assign head2_uses_main_write =
                count_after_pop_generic ==
                {{(COUNT_W-1){1'b0}}, 1'b1};
        end
    endgenerate
    // A one-entry advance shifts the already-registered second head into
    // head0.  The D cone uses the accepted-if-pop fact; the real count and
    // pointer transitions below continue to use do_pop_second.
    wire [31:0] head_bank_pc = pop2_accept_if_pop ?
                               next2_pc_head : pc_head2;
    wire [31:0] head_bank_inst = pop2_accept_if_pop ?
                                  next2_inst_head : inst_head2;
    wire head_bank_r2_use_rd = pop2_accept_if_pop ?
        next2_r2_use_rd_head : r2_use_rd_head2;
    wire [31:0] head_bank_target_offset = pop2_accept_if_pop ?
        next2_target_offset_head : target_offset_head2;
    wire head_bank_pred_taken = pop2_accept_if_pop ?
        next2_pred_taken_head : pred_taken_head2;
    wire [31:0] head_bank_pred_target = pop2_accept_if_pop ?
        next2_pred_target_head : pred_target_head2;
    wire [31:0] dual_head_pc_next = dual_head_uses_main_write ?
                                    main_write_pc : head_bank_pc;
    wire [31:0] dual_head_inst_next = dual_head_uses_main_write ?
                                       main_write_inst : head_bank_inst;
    wire dual_head_r2_use_rd_next = dual_head_uses_main_write ?
        main_write_r2_use_rd : head_bank_r2_use_rd;
    wire [31:0] dual_head_target_offset_next = dual_head_uses_main_write ?
        main_write_target_offset : head_bank_target_offset;
    wire dual_head_pred_taken_next = dual_head_uses_main_write ?
        main_write_pred_taken : head_bank_pred_taken;
    wire [31:0] dual_head_pred_target_next = dual_head_uses_main_write ?
        main_write_pred_target : head_bank_pred_target;
    wire single_head_uses_input = empty ||
        (count == {{(COUNT_W-1){1'b0}}, 1'b1});
    wire [31:0] head_pc_next;
    wire [31:0] head_inst_next;
    wire        head_r2_use_rd_next;
    wire [31:0] head_target_offset_next;
    wire        head_pred_taken_next;
    wire [31:0] head_pred_target_next;
    generate
        if (ENABLE_POP2) begin : g_dual_head0
            assign head_pc_next = dual_head_pc_next;
            assign head_inst_next = dual_head_inst_next;
            assign head_r2_use_rd_next = dual_head_r2_use_rd_next;
            assign head_target_offset_next =
                dual_head_target_offset_next;
            assign head_pred_taken_next = dual_head_pred_taken_next;
            assign head_pred_target_next = dual_head_pred_target_next;
        end else begin : g_legacy_head0
            // Preserve the original head0 D cone exactly in the default
            // instance.  In particular, the unreachable overflow mux is not
            // allowed to perturb the already-closed 150 MHz single-issue path.
            assign head_pc_next = single_head_uses_input ?
                                  pc_in : next_pc_head;
            assign head_inst_next = single_head_uses_input ?
                                     inst_in : next_inst_head;
            assign head_r2_use_rd_next = single_head_uses_input ?
                r2_use_rd_in : next_r2_use_rd_head;
            assign head_target_offset_next = single_head_uses_input ?
                target_offset_in : next_target_offset_head;
            assign head_pred_taken_next = single_head_uses_input ?
                pred_taken_in : next_pred_taken_head;
            assign head_pred_target_next = single_head_uses_input ?
                pred_target_in : next_pred_target_head;
        end
    endgenerate
    // The new second head is old entry pop_count+1.  When that item is the
    // simultaneous tail write, bypass the old FF-bank value into the mirror.
    wire [31:0] head2_bank_pc = pop2_accept_if_pop ?
                                   next3_pc_head : next2_pc_head;
    wire [31:0] head2_bank_inst = pop2_accept_if_pop ?
                                     next3_inst_head : next2_inst_head;
    wire head2_bank_r2_use_rd = pop2_accept_if_pop ?
        next3_r2_use_rd_head : next2_r2_use_rd_head;
    wire [31:0] head2_bank_target_offset = pop2_accept_if_pop ?
        next3_target_offset_head : next2_target_offset_head;
    wire head2_bank_pred_taken = pop2_accept_if_pop ? next3_pred_taken_head :
                                                next2_pred_taken_head;
    wire [31:0] head2_bank_pred_target = pop2_accept_if_pop ?
        next3_pred_target_head : next2_pred_target_head;
    wire [31:0] head2_pc_next = head2_uses_main_write ?
                                main_write_pc : head2_bank_pc;
    wire [31:0] head2_inst_next = head2_uses_main_write ?
                                  main_write_inst : head2_bank_inst;
    wire head2_r2_use_rd_next = head2_uses_main_write ?
        main_write_r2_use_rd : head2_bank_r2_use_rd;
    wire [31:0] head2_target_offset_next = head2_uses_main_write ?
        main_write_target_offset : head2_bank_target_offset;
    wire head2_pred_taken_next = head2_uses_main_write ?
        main_write_pred_taken : head2_bank_pred_taken;
    wire [31:0] head2_pred_target_next = head2_uses_main_write ?
        main_write_pred_target : head2_bank_pred_target;

    // Preserve native FDRE clock enables.  A max-fanout hint lets synthesis
    // replicate the final local driver without KEEP-induced identity buffers.
    // The relaxed raw-pop equations differ from strict accepted pop only while
    // the corresponding head is invalid, so visible FIFO state is unchanged.
    (* max_fanout = 24 *) wire head_update = pop || empty;
    (* max_fanout = 24 *) wire head2_update =
        pop || (count == COUNT_1);

    wire        pair_pending_eligible;
    wire [ 4:0] pair_pending_rR1;
    wire        pair_pending_rR1_re;
    wire [ 4:0] pair_pending_rR2;
    wire        pair_pending_rR2_re;
    wire [ 4:0] pair_pending_wR;
    wire        pair_pending_writes_gpr;

    slot1_narrow_decode u_pair_decode_pending (
        .inst       (pair_meta_pending_inst),
        .eligible   (pair_pending_eligible),
        .rR1        (pair_pending_rR1),
        .rR1_re     (pair_pending_rR1_re),
        .rR2        (pair_pending_rR2),
        .rR2_re     (pair_pending_rR2_re),
        .wR         (pair_pending_wR),
        .rf_we      (),
        .writes_gpr (pair_pending_writes_gpr),
        .alua_sel   (),
        .alub_sel   (),
        .alu_op     (),
        .imm        ()
    );

    // For consecutive writes, pair_meta_pending_inst is the exact predecessor
    // of main_write_inst and has already crossed a register before decode.  If
    // a bubble separated the writes, the saved metadata names that same last
    // accepted predecessor.  Thus this is Boolean-identical to comparing the
    // live B/C fields when they later become the two visible FIFO heads.
    // Split each five-bit equality at the FIFO write boundary.  A low-two or
    // high-three comparison fits in one LUT after predecessor selection; the
    // three full matches are reconstructed from the six registered partials
    // only after the entry becomes the visible second head.  This is exactly
    // (rj==wR)||(rk==wR)||(rd==wR), but the ICache-data path no longer crosses
    // the equality reduction and OR tree in the same cycle.
    wire [4:0] incoming_prev_wR = pair_meta_pending_valid ?
        pair_pending_wR : last_pair_wR;
    wire incoming_prev_writes_gpr = pair_meta_pending_valid ?
        pair_pending_writes_gpr : last_pair_writes_gpr;
    wire incoming_raw_writer_valid = last_enqueued_valid &&
        incoming_prev_writes_gpr && (incoming_prev_wR != 5'd0);
    assign incoming_raw_match_parts = {
        incoming_raw_writer_valid &&
            (inst_in[ 6: 5] == incoming_prev_wR[1:0]),
        inst_in[ 9: 7] == incoming_prev_wR[4:2],
        incoming_raw_writer_valid &&
            (inst_in[11:10] == incoming_prev_wR[1:0]),
        inst_in[14:12] == incoming_prev_wR[4:2],
        incoming_raw_writer_valid &&
            (inst_in[ 1: 0] == incoming_prev_wR[1:0]),
        inst_in[ 4: 2] == incoming_prev_wR[4:2]
    };
    assign main_write_raw_match_parts = overflow_commit ?
        overflow_raw_match_parts : incoming_raw_match_parts;

    wire [PAIR_META_W-1:0] pair_meta_pending_value = {
        pair_pending_eligible,
        pair_pending_rR1, pair_pending_rR1_re,
        pair_pending_rR2, pair_pending_rR2_re,
        pair_pending_wR, pair_pending_writes_gpr
    };

    always @(posedge cpu_clk) begin
        if (!cpu_rstn || flush) begin
            pair_meta_pending_valid <= 1'b0;
            last_pair_writes_gpr <= 1'b0;
            last_pair_wR <= 5'd0;
        end else begin
            // Prewrite payload and pointer every cycle; the single valid bit
            // owns whether this sample updates the metadata bank next cycle.
            // This keeps ICache valid away from 34 replicated CE pins.
            pair_meta_pending_inst  <= main_write_inst;
            pair_meta_pending_ptr   <= wr_ptr;
            pair_meta_pending_valid <= main_write;

            if (pair_meta_pending_valid) begin
                last_pair_writes_gpr <= pair_pending_writes_gpr;
                last_pair_wR <= pair_pending_wR;
                case (pair_meta_pending_ptr)
                    0: pair_meta_mem[0] <= pair_meta_pending_value;
                    1: pair_meta_mem[1] <= pair_meta_pending_value;
                    2: pair_meta_mem[2] <= pair_meta_pending_value;
                    default: pair_meta_mem[DEPTH-1] <=
                                 pair_meta_pending_value;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    wire raw_from_prev_reference = pair_writes_gpr_out &&
        (pair_wR_out != 5'd0) &&
        ((inst_head2[ 9: 5] == pair_wR_out) ||
         (inst_head2[14:10] == pair_wR_out) ||
         (inst_head2[ 4: 0] == pair_wR_out));
    wire [COUNT_W-1:0] count_after_pop_ref =
        count - {{(COUNT_W-1){1'b0}}, do_pop} -
                {{(COUNT_W-1){1'b0}}, do_pop_second};
    wire dual_head_uses_main_write_ref = empty ||
        (do_pop && (count_after_pop_ref == {COUNT_W{1'b0}}));
    wire head2_uses_main_write_ref =
        count_after_pop_ref == {{(COUNT_W-1){1'b0}}, 1'b1};
    wire next_can_fetch_ref =
        (count_after < FETCH_LIMIT) && !overflow_accept;
    wire resume_fetch_event_ref =
        !can_fetch && do_pop && next_can_fetch_ref;
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ENABLE_POP2 && head_update &&
            (dual_head_uses_main_write !==
             dual_head_uses_main_write_ref))
            $fatal(1, "IBUF fast head0 select differs from reference");
        // The second mirror is architecturally visible only when the next
        // occupancy still contains at least two entries.  Invalid payload
        // contents are don't-care and are refreshed before valid2 rises.
        if (cpu_rstn && ENABLE_POP2 && head2_update &&
            (count_after >= COUNT_2) &&
            (head2_uses_main_write !== head2_uses_main_write_ref))
            $fatal(1, "IBUF fast head1 select differs from reference");
        if (cpu_rstn && (head_update || head2_update) &&
            (pop2_accept_if_pop !== do_pop_second))
            $fatal(1, "IBUF payload pop2 fact differs on an update edge");
        if (cpu_rstn &&
            (resume_fetch_event !== resume_fetch_event_ref))
            $fatal(1, "IBUF resume event differs from next-state credit");
        if (cpu_rstn && do_pop_second && !valid2)
            $fatal(1, "IBUF accepted pop2 without a valid second head");
        if (cpu_rstn && valid &&
            (r2_use_rd_head !== r2_use_rd_decode(inst_head)))
            $fatal(1, "IBUF head0 r2 metadata misaligned");
        if (cpu_rstn && valid2 &&
            (r2_use_rd_head2 !== r2_use_rd_decode(inst_head2)))
            $fatal(1, "IBUF head1 r2 metadata misaligned");
        if (cpu_rstn && valid2 &&
            (raw_from_prev_out2 !== raw_from_prev_reference))
            $fatal(1, "IBUF B-to-C RAW sidecar misaligned");
        if (cpu_rstn && push &&
            (r2_use_rd_in !== r2_use_rd_decode(inst_in)))
            $fatal(1, "IBUF input r2 metadata differs from instruction");
        if (cpu_rstn && ENABLE_POP2 && head_update &&
            (count_after != 0) && dual_head_uses_main_write && !main_write)
            $fatal(1, "IBUF head0 requires a missing tail-write bypass");
        if (cpu_rstn && head2_update && (count_after >= COUNT_2) &&
            head2_uses_main_write && !main_write)
            $fatal(1, "IBUF head1 requires a missing tail-write bypass");
    end
`endif

    // Payload mirrors carry no validity of their own.  Let them update from
    // their native CE in a separate process so reset/flush qualification does
    // not add another LUT on the backend-pop path.  count/valid are cleared by
    // the state process below; any payload write while invalid is unobservable,
    // and empty/count==1 prewrite guarantees the next visible value is fresh.
    always @(posedge cpu_clk) begin
        if (head_update) begin
            pc_head            <= head_pc_next;
            inst_head          <= head_inst_next;
            r2_use_rd_head     <= head_r2_use_rd_next;
            target_offset_head <= head_target_offset_next;
            pred_taken_head    <= head_pred_taken_next;
            pred_target_head   <= head_pred_target_next;
        end

        if (head2_update) begin
            pc_head2            <= head2_pc_next;
            inst_head2          <= head2_inst_next;
            r2_use_rd_head2     <= head2_r2_use_rd_next;
            target_offset_head2 <= head2_target_offset_next;
            pred_taken_head2    <= head2_pred_taken_next;
            pred_target_head2   <= head2_pred_target_next;
        end
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            count  <= {COUNT_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            wr_ptr <= {PTR_W{1'b0}};
            overflow_valid <= 1'b0;
            last_enqueued_valid <= 1'b0;
            last_enqueued_pc <= 32'b0;
        end else if (flush) begin
            count  <= {COUNT_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            wr_ptr <= {PTR_W{1'b0}};
            overflow_valid <= 1'b0;
            last_enqueued_valid <= 1'b0;
            last_enqueued_pc <= 32'b0;
        end else begin
            if (do_pop)
                rd_ptr <= do_pop_second ? rd_ptr_next2 : rd_ptr_next;

            // A full push without a simultaneous pop is rejected exactly as
            // before: the payload may be prewritten, but overflow_valid stays
            // clear and it cannot become architecturally visible.
            if (overflow_payload_prewrite) begin
                overflow_pc            <= pc_in;
                overflow_inst          <= inst_in;
                overflow_r2_use_rd     <= r2_use_rd_in;
                overflow_raw_match_parts <= incoming_raw_match_parts;
                overflow_seq_from_prev <= incoming_seq_from_prev;
                overflow_target_offset <= target_offset_in;
                overflow_pred_taken    <= pred_taken_in;
                overflow_pred_target   <= pred_target_in;
            end

            // A skid entry is created only by the full-buffer push+pop case
            // and is consumed on the following edge.  Express the complete
            // next state directly so ICache hit/valid crosses one local LUT,
            // rather than nested capture/accept/hold muxes, before this flop.
            overflow_valid <= overflow_accept;

            if (payload_prewrite) begin
                case (wr_ptr)
                    0: begin
                        pc_mem[0] <= overflow_commit ?
                                     overflow_pc : pc_in;
                        inst_mem[0] <= overflow_commit ?
                                       overflow_inst : inst_in;
                        r2_use_rd_mem[0] <= main_write_r2_use_rd;
                        seq_from_prev_mem[0] <= main_write_seq_from_prev;
                        raw_match_parts_mem[0] <=
                            main_write_raw_match_parts;
                        target_offset_mem[0] <= overflow_commit ?
                            overflow_target_offset : target_offset_in;
                        pred_taken_mem[0] <= overflow_commit ?
                                            overflow_pred_taken :
                                            pred_taken_in;
                        pred_target_mem[0] <= overflow_commit ?
                                             overflow_pred_target :
                                             pred_target_in;
                    end
                    1: begin
                        pc_mem[1] <= overflow_commit ?
                                     overflow_pc : pc_in;
                        inst_mem[1] <= overflow_commit ?
                                       overflow_inst : inst_in;
                        r2_use_rd_mem[1] <= main_write_r2_use_rd;
                        seq_from_prev_mem[1] <= main_write_seq_from_prev;
                        raw_match_parts_mem[1] <=
                            main_write_raw_match_parts;
                        target_offset_mem[1] <= overflow_commit ?
                            overflow_target_offset : target_offset_in;
                        pred_taken_mem[1] <= overflow_commit ?
                                            overflow_pred_taken :
                                            pred_taken_in;
                        pred_target_mem[1] <= overflow_commit ?
                                             overflow_pred_target :
                                             pred_target_in;
                    end
                    2: begin
                        pc_mem[2] <= overflow_commit ?
                                     overflow_pc : pc_in;
                        inst_mem[2] <= overflow_commit ?
                                       overflow_inst : inst_in;
                        r2_use_rd_mem[2] <= main_write_r2_use_rd;
                        seq_from_prev_mem[2] <= main_write_seq_from_prev;
                        raw_match_parts_mem[2] <=
                            main_write_raw_match_parts;
                        target_offset_mem[2] <= overflow_commit ?
                            overflow_target_offset : target_offset_in;
                        pred_taken_mem[2] <= overflow_commit ?
                                            overflow_pred_taken :
                                            pred_taken_in;
                        pred_target_mem[2] <= overflow_commit ?
                                             overflow_pred_target :
                                             pred_target_in;
                    end
                    default: begin
                        pc_mem[DEPTH-1] <= overflow_commit ?
                                           overflow_pc : pc_in;
                        inst_mem[DEPTH-1] <= overflow_commit ?
                                             overflow_inst : inst_in;
                        r2_use_rd_mem[DEPTH-1] <= main_write_r2_use_rd;
                        seq_from_prev_mem[DEPTH-1] <=
                            main_write_seq_from_prev;
                        raw_match_parts_mem[DEPTH-1] <=
                            main_write_raw_match_parts;
                        target_offset_mem[DEPTH-1] <=
                            overflow_commit ? overflow_target_offset :
                                              target_offset_in;
                        pred_taken_mem[DEPTH-1] <= overflow_commit ?
                                                  overflow_pred_taken :
                                                  pred_taken_in;
                        pred_target_mem[DEPTH-1] <= overflow_commit ?
                                                   overflow_pred_target :
                                                   pred_target_in;
                    end
                endcase
            end

            if (main_write) begin
                wr_ptr <= wr_ptr_next;
            end

            // Update the stream tail on a normal main-bank push or when a
            // previously captured full-buffer skid entry commits.  While the
            // skid is valid, full remains asserted and no following response
            // can be accepted, so deferring this tail update from skid capture
            // to skid commit is architecturally invisible.  Crucially, the
            // 32-bit tail CE no longer depends on do_pop/backend readiness.
            if (do_push_main) begin
                last_enqueued_valid <= 1'b1;
                last_enqueued_pc <= pc_in;
            end else if (overflow_commit) begin
                last_enqueued_valid <= 1'b1;
                last_enqueued_pc <= overflow_pc;
            end

            count <= count_after;
        end
    end

endmodule
