`timescale 1ns / 1ps

`include "defines.vh"

// Elastic operand-fetch / address-generation / dependent-branch stage.
//
// ID2 writes only a decoded payload, source identities and an RF/WB snapshot
// into this boundary.  The youngest matching producer is selected here.  If
// that producer is a Load or MUL whose registered result is not available, the
// entry remains resident instead of falling through to an older value.
module OF_stage (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    input  wire        pl_suspend,
    input  wire        downstream_hold,
    // Registered one-cycle kill for a younger instruction captured while the
    // resident, older OF branch generated a late redirect.  This must remain a
    // registered control; feeding of_mispredict back into this stage's own
    // enables recreates the long EX -> branch -> OF CE timing path.
    input  wire        late_redirect_kill,

    input  wire        id_valid,
    input  wire [31:0] id_pc,
    input  wire        id_pred_taken,
    input  wire [31:0] id_pred_target,
    input  wire [ 1:0] id_npc_op,
    input  wire [31:0] id_ext,
    input  wire [31:0] id_target_ext,
    input  wire [31:0] id_raw_rD1,
    input  wire [31:0] id_raw_rD2,
    input  wire [ 4:0] id_rR1,
    input  wire        id_rR1_re,
    input  wire [ 4:0] id_rR2,
    input  wire        id_rR2_re,
    // One-hot dependency location after this payload crosses ID2->OF.
    // Bit order is {EX, M1, M2, WB}.
    input  wire [ 3:0] id_r1_dep_tag,
    input  wire [ 3:0] id_r2_dep_tag,
    input  wire [ 4:0] id_alu_op,
    input  wire        id_alua_sel,
    input  wire        id_alub_sel,
    input  wire        id_rf_we,
    input  wire [ 4:0] id_wR,
    input  wire [ 1:0] id_wd_sel,
    input  wire [ 3:0] id_ram_we,
    input  wire [ 2:0] id_ram_ext_op,
    input  wire        id_is_br_jmp,
    input  wire        id_branch_deferred,
    input  wire        id_is_call,
    input  wire        id_is_return,
    input  wire        id_is_system,
    input  wire        id_csr_we,
    input  wire [ 4:0] id_csr_rj,
    input  wire [13:0] id_csr_num,
    input  wire        id_cacop_valid,
    input  wire [ 4:0] id_cacop_code,

    input  wire        ex_valid,
    input  wire        ex_rf_we,
    input  wire [ 4:0] ex_wR,
    input  wire [ 1:0] ex_wd_sel,
    input  wire        ex_is_mul,
    input  wire [31:0] ex_wd,
    input  wire [31:0] ex_fast_wd,
    input  wire [31:0] ex_control_fast_wd,
    input  wire        ex_fast_result_valid,
    input  wire        ex_data_forward_ready,
    input  wire        ex_control_forward_ready,
    input  wire        ex_memory_forward_ready,
    input  wire        ex_slow_result,
    input  wire [ 4:0] ex_exec_alu_op,
    input  wire [31:0] ex_exec_A,
    input  wire [31:0] ex_exec_B,
    input  wire [31:0] ex_exec_add_wd,
    input  wire [31:0] ex_exec_sll_wd,
    input  wire [31:0] ex_exec_srl_wd,
    input  wire        ex_exec_sll_by_one,
    input  wire [31:0] ex_exec_sll1_wd,
    input  wire [31:0] ex_exec_xor_wd,
    input  wire [31:0] ex_exec_and_wd,
    input  wire        ex_exec_registered_operands,
    input  wire        ex_exec_mul_late,
    input  wire        ex_mul_queue_select,
    input  wire [31:0] ex_exec_nonmul_A,
    input  wire [31:0] ex_exec_nonmul_B,
    input  wire [31:0] ex_exec_nonmul_sll_wd,
    input  wire [31:0] ex_exec_mul_queue_A,
    input  wire [31:0] ex_exec_mul_queue_B,
    input  wire [31:0] ex_exec_mul_bypass_A,
    input  wire [31:0] ex_exec_mul_bypass_B,
    input  wire        ex_mul_bypass_low_select,
    input  wire [31:0] ex_exec_mul_bypass_low_A,
    input  wire [31:0] ex_exec_mul_bypass_high_A,

    input  wire        m1_valid,
    input  wire        m1_rf_we,
    input  wire [ 4:0] m1_wR,
    input  wire [ 1:0] m1_wd_sel,
    input  wire        m1_is_mul,
    input  wire [31:0] m1_wd,
    input  wire        m1_result_ready,

    input  wire        m2_valid,
    input  wire        m2_rf_we,
    input  wire [ 4:0] m2_wR,
    input  wire [ 1:0] m2_wd_sel,
    input  wire        m2_is_mul,
    input  wire [31:0] m2_wd,
    input  wire        m2_load_result_available,
    input  wire [31:0] m2_load_result_data,
    input  wire        m2_mul_result_available,
    input  wire [31:0] m2_mul_result_data,
    // Dedicated M1->M2 registered result for ordinary conditional branches.
    // It deliberately excludes Load and MUL results, and is physically
    // independent of the generic M2 writeback/result mux.
    input  wire        m2_branch_result_available,
    input  wire [31:0] m2_branch_result_data,
    // The Load variant is asserted only after DCache data has crossed the
    // dedicated Load-result register.  It is not a live SRAM response.
    input  wire        m2_branch_load_available,
    // Registered M1->M2 Load type.  This is deliberately independent of the
    // generic M2 writeback selector and remains asserted while a returning
    // Load is waiting for its CPU-clocked result register.
    input  wire        m2_load_pending,

    input  wire        wb_valid,
    input  wire        wb_rf_we,
    input  wire [ 4:0] wb_wR,
    input  wire [31:0] wb_wd,

    output wire        id_allowin,
    output reg         of_valid,
    output wire        of_fire,
    output wire        of_operand_wait,

    output wire [31:0] of_pc,
    output wire        of_pred_taken,
    output wire [31:0] of_pred_target,
    output wire [ 1:0] of_npc_op,
    output wire [31:0] of_ext,
    output wire [31:0] of_target_ext,
    output wire [31:0] of_real_rD1,
    output wire [31:0] of_real_rD2,
    // Dedicated early-MUL issue operands.  These exclude every live late
    // result cone which is not actually safe for a MUL consumer.
    output wire [31:0] of_mul_rD1,
    output wire [31:0] of_mul_rD2,
    output wire        of_load_dep_r1,
    output wire        of_load_dep_r2,
    output wire        of_mul_dep_r1,
    output wire        of_mul_dep_r2,
    output wire [31:0] of_mem_addr,
    output wire [26:0] of_order_addr_key,
    output wire [ 4:0] of_alu_op,
    output wire        of_alua_sel,
    output wire        of_alub_sel,
    output wire        of_shadow_valid,
    // True only when an accepted AND must use the final OF operands instead
    // of the ordinary speculative shadow operands.  This tag is derived from
    // registered dependency locations, never from of_fire/result readiness,
    // so availability cannot leak into the 32-bit shadow-data input cone.
    output wire        of_shadow_repair_and,
    output wire [ 2:0] of_shadow_class,
    output wire [31:0] of_shadow_addsub_wd,
    output wire [31:0] of_shadow_logic_wd,
    output wire [31:0] of_shadow_shift_wd,
    output wire [31:0] of_shadow_compare_wd,
    output wire [31:0] of_shadow_simple_wd,
    output wire [31:0] of_shadow_pc4_wd,
    // Unified observability output retained for directed verification.  The
    // CPU datapath consumes the banked candidates above.
    output wire [31:0] of_shadow_wd,
    // Architectural copy of the zero-bubble MUL.W -> ADD.W result.  The two
    // product candidates pass through independent adders before the registered
    // queue selector, so EX2 need not traverse the generic late-operand ALU
    // and writeback mux for this hot recurrence.
    output wire        ex_late_mul_arch_valid,
    output wire [31:0] ex_late_mul_arch_wd,
    output wire        of_rf_we,
    output wire [ 4:0] of_wR,
    output wire [ 1:0] of_wd_sel,
    output wire [ 3:0] of_ram_we,
    output wire [ 2:0] of_ram_ext_op,
    output wire        of_is_br_jmp,
    output wire        of_branch_deferred,
    output wire        of_is_call,
    output wire        of_is_return,
    output wire        of_is_system,

    output wire        of_deferred_resolve,
    output wire        of_br_jmp_f,
    output wire [31:0] of_taken_target,
    output wire        of_mispredict,
    output reg         of_redirect_valid_r,
    output reg         of_redirect_taken_r,

    output wire        of_csr_we,
    output wire [13:0] of_csr_num,
    output wire [31:0] of_csr_wmask,
    output wire [31:0] of_csr_wdata,
    output wire        of_cacop_valid,
    output wire [ 4:0] of_cacop_code,
    output wire [31:0] of_cacop_addr
);

    reg [31:0] pc_r;
    reg        pred_taken_r;
    reg [31:0] pred_target_r;
    reg [ 1:0] npc_op_r;
    reg [31:0] ext_r;
    reg [31:0] target_ext_r;
    reg [31:0] raw_rD1_r;
    reg [31:0] raw_rD2_r;
    reg [ 4:0] rR1_r;
    reg        rR1_re_r;
    reg [ 4:0] rR2_r;
    reg        rR2_re_r;
    reg [ 4:0] alu_op_r;
    reg        alua_sel_r;
    reg        alub_sel_r;
    reg        rf_we_r;
    reg [ 4:0] wR_r;
    reg [ 1:0] wd_sel_r;
    reg [ 3:0] ram_we_r;
    reg [ 2:0] ram_ext_op_r;
    reg        is_br_jmp_r;
    reg        branch_deferred_r;
    reg        is_call_r;
    reg        is_return_r;
    reg        is_system_r;
    reg        csr_we_r;
    reg [ 4:0] csr_rj_r;
    reg [13:0] csr_num_r;
    reg        cacop_valid_r;
    reg [ 4:0] cacop_code_r;
    reg [3:0] dep_r1_r;
    reg [3:0] dep_r2_r;
    // Dedicated physical copies for the speculative shadow operand muxes.
    // The canonical tags also drive wait/forward/control networks; using the
    // same high-fanout Q in the barrel-shifter recurrence was a routed timing
    // bottleneck.  These copies have identical state transitions and affect
    // data placement only, never readiness or issue timing.
    (* keep = "true", dont_touch = "true", max_fanout = 12 *)
    reg [3:0] dep_r1_shadow_r;
    (* keep = "true", dont_touch = "true", max_fanout = 12 *)
    reg [3:0] dep_r2_shadow_r;
    // Operation-class qualifiers captured with the OF payload.  Keeping these
    // one-bit facts beside the payload removes opcode/wd_sel decoding from the
    // operand-wait -> of_fire -> IBUF/EX backpressure cone.
    reg        ordinary_late_consumer_r;
    reg        late_mul_add_eligible_r;
    reg        consumer_is_mul_r;
    // For JIRL, target equality can be tested one cycle later as
    //   rj == pred_target - immediate  (modulo 2^32).
    // Saving that base at the existing ID2/OF boundary removes the target
    // adder from mispredict-valid while leaving the actual redirect target
    // and branch-recovery cycle unchanged.
    (* keep = "true" *) reg [31:0] jirl_pred_base_r;
    // Compact registered branch class.  EQ/SLT/SLTU plus an inversion bit
    // represent all six conditional branches; B/JIRL use ALWAYS.  After the
    // comparator this is one six-input LUT instead of the former two-level
    // merge of seven one-hot conditions.
    localparam [1:0] BR_CMP_EQ     = 2'b00;
    localparam [1:0] BR_CMP_SLT    = 2'b01;
    localparam [1:0] BR_CMP_SLTU   = 2'b10;
    localparam [1:0] BR_CMP_ALWAYS = 2'b11;
    reg [1:0] branch_cmp_mode_r;
    reg       branch_cmp_invert_r;
    // Dedicated Store class for the high-fanout allowin tree.  The canonical
    // ram_we payload remains available to memory/tag logic, but cannot route
    // back through operand_wait into every OF payload clock enable.
    (* keep = "true", dont_touch = "true", max_fanout = 8 *)
    reg       is_store_wait_r;

    // id_valid is a same-cycle ready/valid decision, but the final shared LUT
    // used to drive almost two hundred native CE pins.  Allow synthesis and
    // physical optimization to create local copies of that final decision;
    // dependency comparison remains in one cone while only its last stage is
    // replicated next to the OF payload banks.
    (* keep = "true", max_fanout = 8 *) wire id_payload_capture = id_valid;

    // These registered, one-hot selects replace the old source-index compare
    // plus youngest-wins priority chain.  Data readiness remains local to the
    // selected producer stage.
    // The dependency tags move with the OF payload and are meaningful only
    // when of_valid is set.  Keep validity on of_fire/wait/event generation,
    // not on these data selects: stale selections on an invalid payload are
    // unobservable, while ANDing of_valid here places that high-fanout bit in
    // front of every forwarding mux and the next shadow ALU.
    wire r1_sel_ex = dep_r1_r[3];
    wire r1_sel_m1 = dep_r1_r[2];
    wire r1_sel_m2 = dep_r1_r[1];
    wire r1_sel_wb = dep_r1_r[0];
    wire r2_sel_ex = dep_r2_r[3];
    wire r2_sel_m1 = dep_r2_r[2];
    wire r2_sel_m2 = dep_r2_r[1];
    wire r2_sel_wb = dep_r2_r[0];

    // A normal EX producer uses a duplicate ALU fed only by ID/EX registers.
    // If that producer is itself consuming a late Load/MUL result, its ordinary
    // ex_wd remains correct but is too deep to feed address/branch/system logic
    // in this same cycle.  Those consumers wait one cycle for the M1 register;
    // plain ALU consumers retain the existing no-bubble late chain.
    // Do not serialize address-generation chains here: CRYPTONIGHT relies on
    // Load/MUL -> ALU -> next memory-address issue without a fixed bubble.
    // Branch/system control is isolated because it adds another compare or
    // side-effect cone after the forwarded value.
    wire of_needs_final_ex = is_br_jmp_r || is_system_r;
    wire ex_direct_add = (ex_wd_sel == `WD_ALU) &&
                         (ex_exec_alu_op == `ALU_ADD);
    wire ex_direct_sll = (ex_wd_sel == `WD_ALU) &&
                         (ex_exec_alu_op == `ALU_SLL);
    wire ex_direct_srl = (ex_wd_sel == `WD_ALU) &&
                         (ex_exec_alu_op == `ALU_SRL);
    wire ex_direct_xor = (ex_wd_sel == `WD_ALU) &&
                         (ex_exec_alu_op == `ALU_XOR);
    wire ex_direct_and = (ex_wd_sel == `WD_ALU) &&
                         (ex_exec_alu_op == `ALU_AND) &&
                         ex_exec_registered_operands;
    // npc_op_r is decoded and registered with the rest of the OF payload.
    // NPC_JMPREG is produced only for JIRL, so use this compact class bit in
    // the issue/resolve control cone instead of decoding the five-bit ALU op.
    wire of_is_jirl = (npc_op_r == `NPC_JMPREG);
`ifndef SYNTHESIS
    wire of_is_jirl_reference =
        is_br_jmp_r && (alu_op_r == `ALU_JIRL);
    always @(posedge cpu_clk) begin
        if (cpu_rstn && of_valid &&
            (of_is_jirl !== of_is_jirl_reference))
            $fatal(1, "compact JIRL class differs from legacy decode");
    end
`endif
    // Producer readiness is predecoded and registered on the OF->EX boundary.
    // OF therefore selects among one-bit stage facts instead of rebuilding
    // wd_sel/opcode/late-dependency logic in its high-fanout allowin cone.
    wire ex_data_result_ready = ex_data_forward_ready;
    wire ex_control_result_ready = ex_control_forward_ready;
    // Control and early-MUL issue consume only the dedicated M1->M2 result
    // shadow or the CPU-clocked Load-result register.  This is cycle-equivalent
    // to the generic M2 type/result test, but it prevents MEM rf_we/wd_sel from
    // feeding OF backpressure and then a younger ID2 branch/front redirect.
    // M2 MUL still waits one more boundary and is consumed from WB.
    wire m2_control_result_ready =
        m2_branch_result_available || m2_branch_load_available;
    // Every ordinary M2 result now reaches OF through a result-class shadow:
    // ordinary ALU through m2_branch_result_*, Load through the CPU-clocked
    // Load register, and MUL through its registered result queue.  The generic
    // MEM wd_sel/is_mul/wd cone no longer controls OF readiness or data.
    wire m2_data_result_ready =
        m2_control_result_ready || m2_mul_result_available;
    wire of_is_memory = (wd_sel_r == `WD_RAM);
    // This classification is immutable for the lifetime of the OF payload.
    // Capture it at the ID/OF boundary so the opcode decoder cannot sit in
    // the operand-ready -> of_fire -> IBUF-pop timing cone.
    wire consumer_is_mul = consumer_is_mul_r;
    wire ex_memory_result_ready = ex_memory_forward_ready;
    wire m2_memory_result_ready = m2_control_result_ready;

    // Dependency tags are registered one-hot-or-zero stage selectors.  Build
    // wait directly as (selected stage && !stage ready), so a tag bit crosses
    // one local LUT instead of a priority ready mux followed by has_match and
    // inversion.  The simulation reference below retains the old equations.
    wire r1_wait_data_nonmem =
        (r1_sel_ex && !ex_data_result_ready) ||
        (r1_sel_m1 && !m1_result_ready) ||
        (r1_sel_m2 && m2_load_pending);
    wire r1_wait_data_memory =
        (r1_sel_ex && !ex_memory_result_ready) ||
        (r1_sel_m1 && !m1_result_ready) ||
        (r1_sel_m2 && !m2_memory_result_ready);
    wire r1_wait_data = of_is_memory ?
                        r1_wait_data_memory : r1_wait_data_nonmem;
    wire r2_wait_data =
        (r2_sel_ex && !ex_data_result_ready) ||
        (r2_sel_m1 && !m1_result_ready) ||
        (r2_sel_m2 && m2_load_pending);
    wire r1_wait_control =
        (r1_sel_ex && !ex_control_result_ready) ||
        (r1_sel_m1 && !m1_result_ready) ||
        (r1_sel_m2 && !m2_control_result_ready);
    wire r2_wait_control =
        (r2_sel_ex && !ex_control_result_ready) ||
        (r2_sel_m1 && !m1_result_ready) ||
        (r2_sel_m2 && !m2_control_result_ready);
    wire r1_wait_branch = r1_wait_control;
    wire r2_wait_branch = r2_wait_control;
    wire r1_wait_jirl =
        (r1_sel_ex && !ex_control_result_ready) ||
        (r1_sel_m1 && !m1_result_ready) ||
        r1_sel_m2;
    wire r1_wait_mul =
        (r1_sel_ex && !ex_fast_result_valid) ||
        (r1_sel_m1 && !m1_result_ready) ||
        (r1_sel_m2 && !m2_control_result_ready);
    wire r2_wait_mul =
        (r2_sel_ex && !ex_fast_result_valid) ||
        (r2_sel_m1 && !m1_result_ready) ||
        (r2_sel_m2 && !m2_control_result_ready);
    wire r1_wait_nonmul =
        of_is_jirl ? r1_wait_jirl :
        is_br_jmp_r ? r1_wait_branch :
        of_needs_final_ex ? r1_wait_control : r1_wait_data;
    wire r2_wait_nonmul =
        is_br_jmp_r ? r2_wait_branch :
        of_needs_final_ex ? r2_wait_control : r2_wait_data;

    wire r1_unavailable_load =
        (r1_sel_ex && (ex_wd_sel == `WD_RAM)) ||
        (r1_sel_m1 && (m1_wd_sel == `WD_RAM)) ||
        (r1_sel_m2 && m2_load_pending &&
                       !m2_branch_load_available);
    wire r2_unavailable_load =
        (r2_sel_ex && (ex_wd_sel == `WD_RAM)) ||
        (r2_sel_m1 && (m1_wd_sel == `WD_RAM)) ||
        (r2_sel_m2 && m2_load_pending &&
                       !m2_branch_load_available);

    wire is_store = (wd_sel_r == `WD_RAM) && (ram_we_r != `RAM_WE_N);
    // Keep the proven late-result mechanism for consumers whose result does
    // not affect a branch decision, JIRL target, system side effect or memory
    // address.  Such an instruction may cross OF with a one-bit dependency
    // tag; EX is then held by the older memory transaction and selects the
    // registered Load/MUL result locally.  Address-bearing rj operands always
    // wait here so of_mem_addr remains final and timing-safe.
    wire r1_late_load = ordinary_late_consumer_r &&
                        ((r1_sel_ex && (ex_wd_sel == `WD_RAM)) ||
                         (r1_sel_m1 && (m1_wd_sel == `WD_RAM)));
    wire r2_late_load = ordinary_late_consumer_r &&
                        ((r2_sel_ex && (ex_wd_sel == `WD_RAM)) ||
                         (r2_sel_m1 && (m1_wd_sel == `WD_RAM)));
    // Only the measured rj-only MUL.W -> ADD.W shape crosses this boundary
    // with an unresolved MUL tag.  It has a dedicated carry chain and final
    // EX2 selector.  All other MUL consumers wait for a registered result,
    // which keeps live DSP/queue data completely out of the generic EX ALU.
    wire r1_late_mul_mul = late_mul_add_eligible_r &&
                           r1_sel_m1 && m1_is_mul && !r2_wait_mul;
    wire r1_late_mul_nonmul = late_mul_add_eligible_r &&
                              r1_sel_m1 && m1_is_mul &&
                              !r2_wait_nonmul;
    wire r2_late_mul = 1'b0;
    wire r1_effective_wait_mul = r1_wait_mul &&
        !r1_late_load && !r1_late_mul_mul;
    wire r1_effective_wait_nonmul = r1_wait_nonmul &&
        !r1_late_load && !r1_late_mul_nonmul;
    wire r2_effective_wait_nonmul = r2_wait_nonmul &&
        !r2_late_load && !r2_late_mul;
    wire store_data_load_late_nonmul = is_store &&
        !r1_wait_nonmul && r2_wait_nonmul && r2_unavailable_load;
    // Fold the Store-data late-Load exception into the r2 blocking term.
    //
    //   (W2 & !L2 & !M2) & !(S & !W1 & W2 & U2)
    // =  W2 & !L2 & !M2 & (!S | W1 | !U2)
    //
    // This is a strict Boolean identity (it does not rely on one-hot tags),
    // while avoiding the former wait -> Store-exception -> inverted-wait
    // cascade in the ID2/OF backpressure path.  The explicit
    // store_data_load_late_* facts above remain available for the late-result
    // tag that EX consumes.
    wire r2_blocking_wait_mul = r2_wait_mul &&
        !r2_late_load && !r2_late_mul;
    // Store payloads are captured with ordinary_late_consumer_r=0 and
    // late_mul_add_eligible_r=0.  Therefore, whenever is_store is true,
    // r1_effective_wait_nonmul is exactly r1_wait_nonmul and absorbs the
    // r1_wait term from the general identity above.  This reachable-state
    // form removes r1/r2 wait reconvergence from the IBUF-pop path while
    // retaining the identical accepted-cycle set.
    // EX has one shared late-Load value and one shared late-MUL value.  A
    // consumer may safely carry two tags only when both operands name the
    // same producer stage/instruction.  If its two unavailable sources name
    // EX and M1 respectively, hold for one cycle so the older producer first
    // crosses a result register; otherwise two distinct results would have to
    // occupy the same late-result boundary at once.
    wire dual_unavailable_producers_mul =
        r1_wait_mul && r2_wait_mul &&
        ((r1_sel_ex && r2_sel_m1) ||
         (r2_sel_ex && r1_sel_m1));
    wire dual_unavailable_producers_nonmul =
        r1_wait_nonmul && r2_wait_nonmul &&
        ((r1_sel_ex && r2_sel_m1) ||
         (r2_sel_ex && r1_sel_m1));
    wire operand_wait_mul =
        dual_unavailable_producers_mul ||
        r1_effective_wait_mul ||
        r2_blocking_wait_mul;
    wire nonstore_wait_nonmul =
        dual_unavailable_producers_nonmul ||
        r1_effective_wait_nonmul ||
        r2_effective_wait_nonmul;
    // For a Store, ordinary/late-MUL consumer classes are both false.  Thus
    // r1_effective_wait collapses to r1_wait, while a late Load feeding only
    // Store data is the sole r2 exception.  Compute both candidates in
    // parallel and select with the independent registered class bit.
    wire store_wait_nonmul = r1_wait_nonmul ||
        (r2_wait_nonmul && !r2_unavailable_load);
    wire operand_wait_nonmul = is_store_wait_r ?
        store_wait_nonmul : nonstore_wait_nonmul;

    // These selected facts remain available to the existing late-result tag
    // outputs.  The high-fanout OF allowin path below uses the two completed
    // candidates directly, keeping consumer_is_mul at the final 2:1 select.
    wire r1_wait = consumer_is_mul ? r1_wait_mul : r1_wait_nonmul;
    wire r2_wait = consumer_is_mul ? r2_wait_mul : r2_wait_nonmul;
    wire store_data_load_late = store_data_load_late_nonmul;
    wire r1_late_mul = consumer_is_mul ?
        r1_late_mul_mul : r1_late_mul_nonmul;

    assign of_operand_wait = of_valid &&
        (consumer_is_mul ? operand_wait_mul : operand_wait_nonmul);
    assign of_fire = of_valid && !late_redirect_kill &&
                     !pl_suspend && !downstream_hold &&
                     !of_operand_wait;
    assign id_allowin = late_redirect_kill || !of_valid || of_fire;

`ifndef SYNTHESIS
    // Cycle-by-cycle equivalence against the former priority-ready network.
    wire r1_data_selected_ready_reference =
        r1_sel_ex ? (of_is_memory ?
                     ex_memory_result_ready : ex_data_result_ready) :
        r1_sel_m1 ? m1_result_ready :
        r1_sel_m2 ? (of_is_memory ?
                     m2_memory_result_ready : m2_data_result_ready) :
        1'b1;
    wire r2_data_selected_ready_reference =
        r2_sel_ex ? ex_data_result_ready :
        r2_sel_m1 ? m1_result_ready :
        r2_sel_m2 ? m2_data_result_ready : 1'b1;
    wire r1_control_selected_ready_reference =
        r1_sel_ex ? ex_control_result_ready :
        r1_sel_m1 ? m1_result_ready :
        r1_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r2_control_selected_ready_reference =
        r2_sel_ex ? ex_control_result_ready :
        r2_sel_m1 ? m1_result_ready :
        r2_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r1_branch_selected_ready_reference =
        r1_sel_ex ? ex_control_result_ready :
        r1_sel_m1 ? m1_result_ready :
        r1_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r2_branch_selected_ready_reference =
        r2_sel_ex ? ex_control_result_ready :
        r2_sel_m1 ? m1_result_ready :
        r2_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r1_jirl_selected_ready_reference =
        r1_sel_ex ? ex_control_result_ready :
        r1_sel_m1 ? m1_result_ready :
        r1_sel_m2 ? 1'b0 : 1'b1;
    wire r1_mul_selected_ready_reference =
        r1_sel_ex ? ex_fast_result_valid :
        r1_sel_m1 ? m1_result_ready :
        r1_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r2_mul_selected_ready_reference =
        r2_sel_ex ? ex_fast_result_valid :
        r2_sel_m1 ? m1_result_ready :
        r2_sel_m2 ? m2_control_result_ready : 1'b1;
    wire r1_nonmul_selected_ready_reference =
        of_is_jirl ? r1_jirl_selected_ready_reference :
        is_br_jmp_r ? r1_branch_selected_ready_reference :
        of_needs_final_ex ? r1_control_selected_ready_reference :
                            r1_data_selected_ready_reference;
    wire r2_nonmul_selected_ready_reference =
        is_br_jmp_r ? r2_branch_selected_ready_reference :
        of_needs_final_ex ? r2_control_selected_ready_reference :
                            r2_data_selected_ready_reference;
    wire r1_has_match_reference =
        r1_sel_ex | r1_sel_m1 | r1_sel_m2 | r1_sel_wb;
    wire r2_has_match_reference =
        r2_sel_ex | r2_sel_m1 | r2_sel_m2 | r2_sel_wb;
    wire r1_selected_ready_reference = consumer_is_mul ?
        r1_mul_selected_ready_reference :
        r1_nonmul_selected_ready_reference;
    wire r2_selected_ready_reference = consumer_is_mul ?
        r2_mul_selected_ready_reference :
        r2_nonmul_selected_ready_reference;
    wire r1_wait_reference = r1_has_match_reference &&
                             !r1_selected_ready_reference;
    wire r2_wait_reference = r2_has_match_reference &&
                             !r2_selected_ready_reference;
    wire store_data_load_late_reference = is_store &&
        !r1_wait_reference && r2_wait_reference && r2_unavailable_load;
    wire r1_late_mul_reference = late_mul_add_eligible_r &&
        r1_sel_m1 && m1_is_mul && !r2_wait_reference;
    wire r1_effective_wait_reference = r1_wait_reference &&
        !r1_late_load && !r1_late_mul_reference;
    wire r2_effective_wait_reference = r2_wait_reference &&
        !r2_late_load && !r2_late_mul;
    wire dual_unavailable_producers_reference =
        r1_wait_reference && r2_wait_reference &&
        ((r1_sel_ex && r2_sel_m1) ||
         (r2_sel_ex && r1_sel_m1));
    wire of_operand_wait_reference = of_valid &&
        (dual_unavailable_producers_reference ||
         r1_effective_wait_reference ||
         (r2_effective_wait_reference &&
          !store_data_load_late_reference));
    wire of_fire_reference = of_valid && !late_redirect_kill &&
        !pl_suspend && !downstream_hold &&
        !of_operand_wait_reference;
    wire id_allowin_reference = late_redirect_kill ||
                                !of_valid || of_fire_reference;
    wire dep_r1_onehot0 = (dep_r1_r == 4'b0000) ||
                          (dep_r1_r == 4'b0001) ||
                          (dep_r1_r == 4'b0010) ||
                          (dep_r1_r == 4'b0100) ||
                          (dep_r1_r == 4'b1000);
    wire dep_r2_onehot0 = (dep_r2_r == 4'b0000) ||
                          (dep_r2_r == 4'b0001) ||
                          (dep_r2_r == 4'b0010) ||
                          (dep_r2_r == 4'b0100) ||
                          (dep_r2_r == 4'b1000);
    always @(posedge cpu_clk) begin
        if (cpu_rstn && of_valid && is_store &&
            (ordinary_late_consumer_r || late_mul_add_eligible_r))
            $fatal(1, "Store payload violates late-consumer class invariant");
        if (cpu_rstn && (!dep_r1_onehot0 || !dep_r2_onehot0))
            $fatal(1, "OF dependency tag is not one-hot-or-zero");
        if (cpu_rstn && (is_store_wait_r !== is_store))
            $fatal(1, "OF Store wait-class copy diverged");
        if (cpu_rstn &&
            ((dep_r1_shadow_r !== dep_r1_r) ||
             (dep_r2_shadow_r !== dep_r2_r)))
            $fatal(1, "OF shadow dependency copy diverged");
        // An unfinished M2 MUL already raises pl_suspend, so the optimized
        // raw wait may differ only while every architectural accept event is
        // globally blocked.  Fire/allowin must remain equivalent every cycle;
        // raw wait/late classifications must match on every observable cycle.
        if (cpu_rstn &&
            ((of_fire !== of_fire_reference) ||
             (id_allowin !== id_allowin_reference)))
            $fatal(1, "parallel OF handshake differs from reference");
        if (cpu_rstn && !pl_suspend &&
            ((of_operand_wait !== of_operand_wait_reference) ||
             (r1_late_mul !== r1_late_mul_reference) ||
             (store_data_load_late !==
              store_data_load_late_reference)))
            $fatal(1, "parallel OF wait differs from reference");
    end
`endif

    wire [31:0] m2_registered_data =
        m2_branch_load_available ? m2_load_result_data :
        m2_mul_result_available ? m2_mul_result_data :
                                  m2_branch_result_data;
    wire [31:0] r1_m2_data = m2_registered_data;
    wire [31:0] r2_m2_data = m2_registered_data;
    // Control consumers use only the result shadow registered on OF->EX.
    // EX now also creates that shadow for an AND with final operands, so the
    // former live ex_exec_and_wd fallback is unnecessary.  Removing it makes
    // ALU -> branch remain zero-bubble without an EX operand-to-redirect
    // combinational path.
    wire [31:0] ex_control_wd = ex_control_fast_wd;
    // The measured late-MUL dependency is exclusively MUL.W -> ADD.W.  Build
    // the two ADD candidates in parallel and select after both carry chains.
    // This preserves its zero-bubble schedule while removing two complete
    // duplicate ALUs (and their output opcode muxes) from the critical region.
    (* keep = "true" *) wire [31:0] ex_mul_queue_add_wd =
        ex_exec_mul_queue_A + ex_exec_mul_queue_B;
    // Select MUL.W low versus MULH high only after both addition carry chains.
    // This keeps the DSP result-type bit out of the hot architectural ADD
    // chain while preserving every multiply variant.
    (* keep = "true" *) wire [31:0] ex_mul_bypass_low_add_wd =
        ex_exec_mul_bypass_low_A + ex_exec_mul_bypass_B;
    (* keep = "true" *) wire [31:0] ex_mul_bypass_high_add_wd =
        ex_exec_mul_bypass_high_A + ex_exec_mul_bypass_B;
    wire [31:0] ex_mul_bypass_add_wd =
        ex_mul_bypass_low_select ? ex_mul_bypass_low_add_wd :
                                   ex_mul_bypass_high_add_wd;
    wire [31:0] ex_mul_late_add_wd =
        ex_mul_queue_select ? ex_mul_queue_add_wd :
                              ex_mul_bypass_add_wd;
    assign ex_late_mul_arch_valid = ex_exec_mul_late && ex_direct_add;
    assign ex_late_mul_arch_wd    = ex_mul_late_add_wd;
`ifndef SYNTHESIS
    // Verify the timing-oriented parallel carry chains against an independent
    // select-before-add reference.  The generic EX ALU is deliberately not
    // part of this check because its result is architecturally unobservable
    // for ex_late_mul_arch_valid.
    wire [31:0] ex_mul_late_reference_A =
        ex_mul_queue_select ? ex_exec_mul_queue_A :
                              ex_exec_mul_bypass_A;
    wire [31:0] ex_mul_late_reference_B =
        ex_mul_queue_select ? ex_exec_mul_queue_B :
                              ex_exec_mul_bypass_B;
    wire [31:0] ex_mul_late_reference_wd =
        ex_mul_late_reference_A + ex_mul_late_reference_B;
    always @(posedge cpu_clk) begin
        if (cpu_rstn && !pl_suspend && ex_valid &&
            ex_late_mul_arch_valid &&
            (ex_late_mul_arch_wd !== ex_mul_late_reference_wd))
            $fatal(1, "late-MUL architectural bypass reference mismatch");
    end
`endif
    // The generic ALU/writeback selector is intentionally bypassed for the
    // two high-frequency CRYPTONIGHT chains found by dynamic diagnostics.
    wire [31:0] ex_short_wd =
        ex_fast_result_valid ? ex_fast_wd :
        ex_exec_mul_late ? (ex_direct_add ? ex_mul_late_add_wd : 32'b0) :
        ex_direct_add ? ex_exec_add_wd :
        ex_direct_and ? ex_exec_and_wd :
        ex_exec_sll_by_one ? ex_exec_sll1_wd :
        ex_direct_sll ? ex_exec_sll_wd :
        ex_direct_srl ? ex_exec_srl_wd :
        ex_direct_xor ? ex_exec_xor_wd : 32'b0;
    wire [31:0] data_rD1 =
        r1_sel_ex && ex_data_result_ready ? ex_short_wd :
        r1_sel_m1 && m1_result_ready ? m1_wd :
        r1_sel_m2 && m2_data_result_ready ? r1_m2_data :
        r1_sel_wb ? wb_wd : raw_rD1_r;
    wire [31:0] data_rD2 =
        r2_sel_ex && ex_data_result_ready ? ex_short_wd :
        r2_sel_m1 && m1_result_ready ? m1_wd :
        r2_sel_m2 && m2_data_result_ready ? r2_m2_data :
        r2_sel_wb ? wb_wd : raw_rD2_r;

    // Dedicated control forwarding muxes are intentionally independent of
    // ex_wd and m2_mul_result_data.  They contain only the duplicate EX ALU,
    // M1/M2 stage registers, registered Load data, WB and the saved RF value.
    // This physically prevents MUL/late-result data from reaching the branch
    // compare, JIRL target or system side-effect cone.
    wire [31:0] control_m2_data =
        m2_branch_load_available ?
        m2_load_result_data : m2_branch_result_data;
    wire [31:0] control_rD1 =
        r1_sel_ex && ex_control_result_ready ? ex_control_wd :
        r1_sel_m1 && m1_result_ready ? m1_wd :
        r1_sel_m2 && m2_control_result_ready ? control_m2_data :
        r1_sel_wb ? wb_wd : raw_rD1_r;
    wire [31:0] control_rD2 =
        r2_sel_ex && ex_control_result_ready ? ex_control_wd :
        r2_sel_m1 && m1_result_ready ? m1_wd :
        r2_sel_m2 && m2_control_result_ready ? control_m2_data :
        r2_sel_wb ? wb_wd : raw_rD2_r;
    // Dependency tags are registered one-hot.  Express the branch operand
    // network as one-hot gating rather than a priority chain: a dependency tag
    // now crosses a balanced OR network instead of three serial data muxes
    // before entering the comparator.
    wire r1_branch_raw = !(r1_sel_ex | r1_sel_m1 |
                           r1_sel_m2 | r1_sel_wb);
    wire r2_branch_raw = !(r2_sel_ex | r2_sel_m1 |
                           r2_sel_m2 | r2_sel_wb);
    wire [31:0] branch_m2_data =
        m2_branch_load_available ?
        m2_load_result_data : m2_branch_result_data;
    wire [31:0] branch_rD1 =
        ({32{r1_sel_ex}}  & ex_control_wd) |
        ({32{r1_sel_m1}}  & m1_wd) |
        ({32{r1_sel_m2}}  & branch_m2_data) |
        ({32{r1_sel_wb}}  & wb_wd) |
        ({32{r1_branch_raw}} & raw_rD1_r);
    wire [31:0] branch_rD2 =
        ({32{r2_sel_ex}}  & ex_control_wd) |
        ({32{r2_sel_m1}}  & m1_wd) |
        ({32{r2_sel_m2}}  & branch_m2_data) |
        ({32{r2_sel_wb}}  & wb_wd) |
        ({32{r2_branch_raw}} & raw_rD2_r);
    wire [31:0] jirl_rD1 =
        r1_sel_ex ? ex_control_wd :
        r1_sel_m1 ? m1_wd :
        r1_sel_wb ? wb_wd : raw_rD1_r;
    // The DSP input network is deliberately independent of ex_wd,
    // ex_exec_add/sll and the M2 MUL-result queue.  This also prevents
    // non-MUL OF instructions from creating a meaningless static timing path
    // through the always-clocking DSP input registers.
    assign of_mul_rD1 =
        r1_sel_ex && ex_fast_result_valid ? ex_fast_wd :
        r1_sel_m1 && m1_result_ready ? m1_wd :
        r1_sel_m2 && m2_control_result_ready ? control_m2_data :
        r1_sel_wb ? wb_wd : raw_rD1_r;
    assign of_mul_rD2 =
        r2_sel_ex && ex_fast_result_valid ? ex_fast_wd :
        r2_sel_m1 && m1_result_ready ? m1_wd :
        r2_sel_m2 && m2_control_result_ready ? control_m2_data :
        r2_sel_wb ? wb_wd : raw_rD2_r;

    // Memory address generation and dependent branch resolution are complete
    // in OF.  Their rj/branch operands have no architectural consumer in EX,
    // so do not write a deep forwarded value into an otherwise unused payload
    // register.  Store data (rD2) is retained unchanged.
    wire payload_rD1_unused = (wd_sel_r == `WD_RAM) || is_br_jmp_r;
    wire payload_rD2_unused = is_br_jmp_r;
    assign of_real_rD1 = payload_rD1_unused ? 32'b0 :
                         of_needs_final_ex ? control_rD1 : data_rD1;
    assign of_real_rD2 = payload_rD2_unused ? 32'b0 :
                         of_needs_final_ex ? control_rD2 : data_rD2;

    // Precompute a forwarding-only copy of the accepted result and register it
    // at the OF->EX edge.  EX still performs the architectural ALU operation;
    // this shadow merely ensures that the next OF consumer sees a registered
    // producer result instead of an EX ALU combinational cone.
    // Shadow operands have a physically restricted forwarding network.  No
    // live EX late-result path and no M2 MUL queue data can reach these nets;
    // unavailability travels only on the separate valid bit.
    wire r1_shadow_unsafe =
        (r1_sel_ex && !ex_fast_result_valid) || r1_sel_m2;
    wire r2_shadow_unsafe =
        (r2_sel_ex && !ex_fast_result_valid) || r2_sel_m2;
    assign of_shadow_repair_and =
        (wd_sel_r == `WD_ALU) && (alu_op_r == `ALU_AND) &&
        !r1_late_load && !r2_late_load &&
        !r1_late_mul && !r2_late_mul &&
        (r1_shadow_unsafe || r2_shadow_unsafe);
    // Data and validity are deliberately independent here.  The one-hot
    // dependency tag selects the registered producer value even while its
    // separate ready bit is low; of_fire/of_shadow_valid already prevent that
    // speculative value from becoming architectural.  Gating these 32-bit
    // muxes with producer-ready made ex_shadow_valid feed the complete next
    // ALU and return to ex_shadow_wd_r in one cycle.
    // EX already registered an independently preselected copy of the same
    // shadow result.  Reusing it here avoids selecting the six shadow banks
    // with ex_shadow_class and then immediately feeding the next shadow ALU.
    // ex_fast_wd remains available to the ordinary data path, while the
    // recurrence EX result -> next OF shadow -> EX register starts from this
    // physically local, class-free register bank.
    wire [31:0] shadow_rD1 =
        dep_r1_shadow_r[3] ? ex_control_fast_wd :
        dep_r1_shadow_r[2] ? m1_wd :
        dep_r1_shadow_r[0] ? wb_wd : raw_rD1_r;
    wire [31:0] shadow_rD2 =
        dep_r2_shadow_r[3] ? ex_control_fast_wd :
        dep_r2_shadow_r[2] ? m1_wd :
        dep_r2_shadow_r[0] ? wb_wd : raw_rD2_r;
`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ex_valid && ex_fast_result_valid &&
            (ex_fast_wd !== ex_control_fast_wd))
            $fatal(1, "EX preselected shadow differs from banked shadow");
    end
`endif
    wire [31:0] shadow_alu_A = alua_sel_r ? shadow_rD1 : pc_r;
    wire [31:0] shadow_alu_B = alub_sel_r ? shadow_rD2 : ext_r;

    // Capture operation candidates in separate OF/EX result banks.  A single
    // generic ALU followed by a wide opcode mux made WB->OF ADD traverse the
    // carry chain and five more LUT levels before reaching ex_shadow_wd_r.
    // Candidate banks put that class mux after the register boundary instead.
    assign of_shadow_addsub_wd =
        (alu_op_r == `ALU_SUB) ? (shadow_alu_A - shadow_alu_B) :
                                 (shadow_alu_A + shadow_alu_B);

    reg [31:0] shadow_logic_wd;
    always @(*) begin
        case (alu_op_r)
            `ALU_AND: shadow_logic_wd = shadow_alu_A & shadow_alu_B;
            `ALU_OR : shadow_logic_wd = shadow_alu_A | shadow_alu_B;
            `ALU_XOR: shadow_logic_wd = shadow_alu_A ^ shadow_alu_B;
            `ALU_NOR: shadow_logic_wd = ~(shadow_alu_A | shadow_alu_B);
            default : shadow_logic_wd = 32'b0;
        endcase
    end
    assign of_shadow_logic_wd = shadow_logic_wd;

    reg [31:0] shadow_shift_wd;
    always @(*) begin
        case (alu_op_r)
            `ALU_SLL: shadow_shift_wd =
                      shadow_alu_A << shadow_alu_B[4:0];
            `ALU_SRL: shadow_shift_wd =
                      shadow_alu_A >> shadow_alu_B[4:0];
            `ALU_SRA: shadow_shift_wd =
                      $signed(shadow_alu_A) >>> shadow_alu_B[4:0];
            default : shadow_shift_wd = 32'b0;
        endcase
    end
    assign of_shadow_shift_wd = shadow_shift_wd;

    assign of_shadow_compare_wd =
        (alu_op_r == `ALU_SLT) ?
            (($signed(shadow_alu_A) < $signed(shadow_alu_B)) ?
             32'd1 : 32'd0) :
            ((shadow_alu_A < shadow_alu_B) ? 32'd1 : 32'd0);
    assign of_shadow_simple_wd =
        (wd_sel_r == `WD_CSR) ? ext_r : shadow_alu_B;
    assign of_shadow_pc4_wd = pc_r + 32'd4;

    assign of_shadow_class =
        (wd_sel_r == `WD_CSR) ? `SHADOW_SIMPLE :
        (wd_sel_r == `WD_PC4) ? `SHADOW_PC4 :
        (wd_sel_r != `WD_ALU) ? `SHADOW_NONE :
        ((alu_op_r == `ALU_ADD) || (alu_op_r == `ALU_SUB)) ?
            `SHADOW_ADDSUB :
        ((alu_op_r == `ALU_AND) || (alu_op_r == `ALU_OR) ||
         (alu_op_r == `ALU_XOR) || (alu_op_r == `ALU_NOR)) ?
            `SHADOW_LOGIC :
        ((alu_op_r == `ALU_SLL) || (alu_op_r == `ALU_SRL) ||
         (alu_op_r == `ALU_SRA)) ? `SHADOW_SHIFT :
        ((alu_op_r == `ALU_SLT) || (alu_op_r == `ALU_SLTU)) ?
            `SHADOW_COMPARE :
        (alu_op_r == `ALU_LU12I) ? `SHADOW_SIMPLE :
                                   `SHADOW_NONE;
    wire shadow_has_late_operand =
        r1_late_load || r2_late_load || r1_late_mul || r2_late_mul ||
        r1_shadow_unsafe || r2_shadow_unsafe;
    assign of_shadow_valid = of_fire && rf_we_r &&
                             (wd_sel_r != `WD_RAM) &&
                             !consumer_is_mul &&
                             !shadow_has_late_operand &&
                             (of_shadow_class != `SHADOW_NONE);
    assign of_shadow_wd =
        (of_shadow_class == `SHADOW_ADDSUB) ?
            of_shadow_addsub_wd :
        (of_shadow_class == `SHADOW_LOGIC) ?
            of_shadow_logic_wd :
        (of_shadow_class == `SHADOW_SHIFT) ?
            of_shadow_shift_wd :
        (of_shadow_class == `SHADOW_COMPARE) ?
            of_shadow_compare_wd :
        (of_shadow_class == `SHADOW_SIMPLE) ?
            of_shadow_simple_wd :
        (of_shadow_class == `SHADOW_PC4) ?
            of_shadow_pc4_wd : 32'b0;

    // Only the late Store-data case may leave OF without its final value.  The
    // registered Load-result fill in EX/M1 consumes this tag.  No ordinary
    // consumer and no branch crosses the boundary with an unresolved source.
    assign of_load_dep_r1 = of_fire && r1_late_load;
    assign of_load_dep_r2 = of_fire &&
                            (r2_late_load || store_data_load_late);
    assign of_mul_dep_r1  = of_fire && r1_late_mul;
    assign of_mul_dep_r2  = of_fire && r2_late_mul;

    assign of_pc              = pc_r;
    assign of_pred_taken      = pred_taken_r;
    assign of_pred_target     = pred_target_r;
    assign of_npc_op          = npc_op_r;
    assign of_ext             = ext_r;
    assign of_target_ext      = target_ext_r;
    assign of_alu_op          = alu_op_r;
    assign of_alua_sel        = alua_sel_r;
    assign of_alub_sel        = alub_sel_r;
    assign of_rf_we           = rf_we_r;
    assign of_wR              = wR_r;
    assign of_wd_sel          = wd_sel_r;
    assign of_ram_we          = ram_we_r;
    assign of_ram_ext_op      = ram_ext_op_r;
    assign of_is_br_jmp       = is_br_jmp_r;
    assign of_branch_deferred = branch_deferred_r;
    assign of_is_call         = is_call_r;
    assign of_is_return       = is_return_r;
    assign of_is_system       = is_system_r;

    // Address generation is before the OF/EX register.  For the measured
    // MUL-result -> ADD.W -> memory chain, combine the producer's two ADD
    // inputs with the memory immediate using carry-save compression followed
    // by one carry-propagate adder.  This is exactly A+B+imm modulo 2^32 but
    // removes the former two serial carry chains.
    wire [31:0] ex_add_ext_sum =
        ex_exec_nonmul_A ^ ex_exec_nonmul_B ^ ext_r;
    wire [31:0] ex_add_ext_carry =
        ((ex_exec_nonmul_A & ex_exec_nonmul_B) |
         (ex_exec_nonmul_A & ext_r) |
         (ex_exec_nonmul_B & ext_r)) << 1;
    wire [31:0] ex_add_plus_ext =
        ex_add_ext_sum + ex_add_ext_carry;
    (* keep = "true" *) wire [31:0] ex_mul_queue_plus_ext;
    (* keep = "true" *) wire [31:0] ex_mul_bypass_plus_ext;
    (* dont_touch = "true" *) OF_add3_candidate u_mul_queue_addr (
        .a(ex_exec_mul_queue_A),
        .b(ex_exec_mul_queue_B),
        .c(ext_r),
        .y(ex_mul_queue_plus_ext)
    );
    (* dont_touch = "true" *) OF_add3_candidate u_mul_bypass_addr (
        .a(ex_exec_mul_bypass_A),
        .b(ex_exec_mul_bypass_B),
        .c(ext_r),
        .y(ex_mul_bypass_plus_ext)
    );
    wire [31:0] ex_mul_add_plus_ext =
        ex_mul_queue_select ? ex_mul_queue_plus_ext :
                              ex_mul_bypass_plus_ext;
    wire use_fused_mem_addr = (wd_sel_r == `WD_RAM) &&
                              r1_sel_ex &&
                              ex_data_result_ready &&
                              ex_direct_add &&
                              !ex_fast_result_valid;
    // Address generation has its own physically restricted forwarding mux.
    // A fixed SLLI.W #1 is wiring and retains its zero-bubble address path.
    // A late, variable SLL waits for the M1 register: admitting its live
    // barrel-shifter output here would put the shifter and this address carry
    // chain in one 150 MHz cycle.  Other unsupported invalid-shadow EX
    // producers and a live M2 MUL follow the same registered-result rule.
    wire [31:0] mem_rD1 =
        r1_sel_ex && ex_fast_result_valid ? ex_fast_wd :
        r1_sel_ex && ex_exec_sll_by_one ? ex_exec_sll1_wd :
        r1_sel_m1 && m1_result_ready ? m1_wd :
        r1_sel_m2 && m2_memory_result_ready ? control_m2_data :
        r1_sel_wb ? wb_wd : raw_rD1_r;
    wire [31:0] normal_mem_addr = mem_rD1 + ext_r;
    assign of_mem_addr = (wd_sel_r == `WD_RAM) ?
                         (use_fused_mem_addr ?
                          (ex_exec_mul_late ?
                           ex_mul_add_plus_ext : ex_add_plus_ext) :
                          normal_mem_addr) : 32'b0;
    assign of_order_addr_key = of_mem_addr[28:2];

    wire r_eq   = (branch_rD1 == branch_rD2);
    wire r_slt  = ($signed(branch_rD1) < $signed(branch_rD2));
    wire r_sltu = (branch_rD1 < branch_rD2);
    wire branch_taken_raw =
        (branch_cmp_mode_r == BR_CMP_ALWAYS) ? 1'b1 :
        (((branch_cmp_mode_r == BR_CMP_EQ)  ? r_eq :
          (branch_cmp_mode_r == BR_CMP_SLT) ? r_slt : r_sltu) ^
         branch_cmp_invert_r);

`ifndef SYNTHESIS
    wire branch_taken_reference =
        (alu_op_r == `ALU_B) ||
        (alu_op_r == `ALU_JIRL) ||
        ((alu_op_r == `ALU_BGEU) && !r_sltu) ||
        ((alu_op_r == `ALU_SLTU) &&  r_sltu) ||
        ((alu_op_r == `ALU_BGE)  && !r_slt) ||
        ((alu_op_r == `ALU_SLT)  &&  r_slt) ||
        ((alu_op_r == `ALU_BNE)  && !r_eq) ||
        ((alu_op_r == `ALU_SUB)  &&  r_eq);
    always @(posedge cpu_clk) begin
        if (cpu_rstn && of_valid && is_br_jmp_r &&
            (branch_taken_raw !== branch_taken_reference))
            $fatal(1, "compact OF branch class changed branch outcome");
    end
`endif

    assign of_br_jmp_f = of_valid && is_br_jmp_r && branch_taken_raw;
    assign of_taken_target = (npc_op_r == `NPC_JMPREG) ?
                             (jirl_rD1 + ext_r) : target_ext_r;
    wire control_operand_wait =
        (of_is_jirl ? r1_wait_jirl :
         is_br_jmp_r ? r1_wait_branch : r1_wait_control) ||
        (is_br_jmp_r ? r2_wait_branch : r2_wait_control);
    wire branch_fire = of_valid && is_br_jmp_r &&
                       !late_redirect_kill && !pl_suspend &&
                       !downstream_hold && !control_operand_wait;
`ifndef SYNTHESIS
    wire control_operand_wait_reference =
        (r1_has_match_reference &&
         !(of_is_jirl ? r1_jirl_selected_ready_reference :
           is_br_jmp_r ? r1_branch_selected_ready_reference :
                         r1_control_selected_ready_reference)) ||
        (r2_has_match_reference &&
         !(is_br_jmp_r ? r2_branch_selected_ready_reference :
                         r2_control_selected_ready_reference));
    wire branch_fire_reference = of_valid && is_br_jmp_r &&
        !late_redirect_kill && !pl_suspend && !downstream_hold &&
        !control_operand_wait_reference;
    always @(posedge cpu_clk) begin
        if (cpu_rstn &&
            ((control_operand_wait !== control_operand_wait_reference) ||
             (branch_fire !== branch_fire_reference)))
            $fatal(1, "direct control wait differs from reference");
    end
`endif
    assign of_deferred_resolve = branch_fire && branch_deferred_r;
    wire target_mismatch = (npc_op_r == `NPC_JMPREG) ?
                           (jirl_rD1 != jirl_pred_base_r) :
                           (pred_target_r != target_ext_r);
    // of_deferred_resolve already proves valid && branch.  For a real-taken
    // branch, either a not-taken prediction or a wrong target is an error;
    // for a real-not-taken branch, only a taken prediction is an error.  This
    // is exactly the old direction/target expression but leaves just one
    // local select after the branch comparator.
    wire prediction_error_raw = branch_taken_raw ?
                                (!pred_taken_r || target_mismatch) :
                                pred_taken_r;
    assign of_mispredict = of_deferred_resolve && prediction_error_raw;

    // The OF redirect event crosses its register boundary locally.  The old
    // implementation routed the complete Load-forward/branch-compare cone out
    // of this module, through a top-level ID/OF OR, and only then reached the
    // redirect flops.  These registers capture the same event and outcome on
    // the same edge; the front end still observes the redirect on the following
    // cycle, but no combinational OF result reaches front-end control.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            of_redirect_valid_r <= 1'b0;
            of_redirect_taken_r <= 1'b0;
        end else begin
            of_redirect_valid_r <= of_mispredict;
            // The direction payload is observable only when the registered
            // redirect valid bit is set.  of_mispredict already proves a
            // valid branch, so branch_taken_raw is then exactly of_br_jmp_f.
            // Capture the local comparator result directly and remove the
            // redundant valid/branch LUT from the register D path.
            of_redirect_taken_r <= branch_taken_raw;
        end
    end
`ifndef SYNTHESIS
    wire legacy_taken_error = (pred_taken_r != of_br_jmp_f);
    wire legacy_target_error = pred_taken_r && of_br_jmp_f &&
                               (pred_target_r != of_taken_target);
    wire legacy_mispredict = of_deferred_resolve &&
                             (legacy_taken_error || legacy_target_error);
    always @(posedge cpu_clk) begin
        if (cpu_rstn && of_valid &&
            (npc_op_r == `NPC_JMPREG) &&
            ((pred_target_r != of_taken_target) !==
             (jirl_rD1 != jirl_pred_base_r)))
            $fatal(1, "JIRL predicted-base comparison is not equivalent");
        if (cpu_rstn && (of_mispredict !== legacy_mispredict))
            $fatal(1, "OF prediction-error simplification is not equivalent");
        if (cpu_rstn && of_mispredict &&
            (branch_taken_raw !== of_br_jmp_f))
            $fatal(1, "redirect direction payload differs from legacy value");
    end
`endif

    assign of_csr_we = of_fire && csr_we_r;
    assign of_csr_num = csr_num_r;
    assign of_csr_wmask = (csr_rj_r == 5'd1) ?
                          32'hffff_ffff : control_rD1;
    assign of_csr_wdata = control_rD2;
    assign of_cacop_valid = of_fire && cacop_valid_r;
    assign of_cacop_code = cacop_code_r;
    assign of_cacop_addr = control_rD1 + ext_r;

    // Keep the architectural hold-refresh rule independent of the dependency
    // tag.  A same-cycle WB write updates the saved RF snapshot even when the
    // producer was not one of the four live stages classified at capture.
    // This comparator feeds only the raw snapshot register D input; it is not
    // part of the branch/result forwarding cone.
    wire wb_refresh_r1 = of_valid && wb_valid && wb_rf_we && rR1_re_r &&
                         (rR1_r != 5'd0) && (rR1_r == wb_wR);
    wire wb_refresh_r2 = of_valid && wb_valid && wb_rf_we && rR2_re_r &&
                         (rR2_r != 5'd0) && (rR2_r == wb_wR);

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            of_valid <= 1'b0;
        end else if (late_redirect_kill) begin
            of_valid <= 1'b0;
        end else if (id_valid) begin
            of_valid <= 1'b1;
        end else if (of_fire) begin
            of_valid <= 1'b0;
        end
    end

    // Advance dependency ownership whenever the older pipeline advances while
    // an OF payload remains resident.  downstream_hold is the precise case in
    // which EX is held while the old M1/M2 stages continue draining.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            dep_r1_r <= 4'b0000;
            dep_r2_r <= 4'b0000;
            dep_r1_shadow_r <= 4'b0000;
            dep_r2_shadow_r <= 4'b0000;
        end else if (late_redirect_kill) begin
            dep_r1_r <= 4'b0000;
            dep_r2_r <= 4'b0000;
            dep_r1_shadow_r <= 4'b0000;
            dep_r2_shadow_r <= 4'b0000;
        end else if (id_valid) begin
            dep_r1_r <= id_r1_dep_tag;
            dep_r2_r <= id_r2_dep_tag;
            dep_r1_shadow_r <= id_r1_dep_tag;
            dep_r2_shadow_r <= id_r2_dep_tag;
        end else if (of_fire || !of_valid) begin
            dep_r1_r <= 4'b0000;
            dep_r2_r <= 4'b0000;
            dep_r1_shadow_r <= 4'b0000;
            dep_r2_shadow_r <= 4'b0000;
        end else if (!pl_suspend) begin
            dep_r1_r <= {downstream_hold && dep_r1_r[3],
                         !downstream_hold && dep_r1_r[3],
                         dep_r1_r[2], dep_r1_r[1]};
            dep_r2_r <= {downstream_hold && dep_r2_r[3],
                         !downstream_hold && dep_r2_r[3],
                         dep_r2_r[2], dep_r2_r[1]};
            dep_r1_shadow_r <=
                        {downstream_hold && dep_r1_shadow_r[3],
                         !downstream_hold && dep_r1_shadow_r[3],
                         dep_r1_shadow_r[2], dep_r1_shadow_r[1]};
            dep_r2_shadow_r <=
                        {downstream_hold && dep_r2_shadow_r[3],
                         !downstream_hold && dep_r2_shadow_r[3],
                         dep_r2_shadow_r[2], dep_r2_shadow_r[1]};
        end
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            pc_r              <= 32'b0;
            pred_taken_r      <= 1'b0;
            pred_target_r     <= 32'b0;
            npc_op_r          <= 2'b0;
            ext_r             <= 32'b0;
            target_ext_r      <= 32'b0;
            raw_rD1_r         <= 32'b0;
            raw_rD2_r         <= 32'b0;
            rR1_r             <= 5'b0;
            rR1_re_r          <= 1'b0;
            rR2_r             <= 5'b0;
            rR2_re_r          <= 1'b0;
            alu_op_r          <= 5'b0;
            alua_sel_r        <= 1'b0;
            alub_sel_r        <= 1'b0;
            rf_we_r           <= 1'b0;
            wR_r              <= 5'b0;
            wd_sel_r          <= 2'b0;
            ram_we_r          <= 4'b0;
            ram_ext_op_r      <= 3'b0;
            is_br_jmp_r       <= 1'b0;
            branch_deferred_r <= 1'b0;
            is_call_r         <= 1'b0;
            is_return_r       <= 1'b0;
            is_system_r       <= 1'b0;
            csr_we_r          <= 1'b0;
            csr_rj_r          <= 5'b0;
            csr_num_r         <= 14'b0;
            cacop_valid_r     <= 1'b0;
            cacop_code_r      <= 5'b0;
            branch_cmp_mode_r   <= BR_CMP_EQ;
            branch_cmp_invert_r <= 1'b0;
            is_store_wait_r      <= 1'b0;
            ordinary_late_consumer_r <= 1'b0;
            late_mul_add_eligible_r  <= 1'b0;
            consumer_is_mul_r        <= 1'b0;
            jirl_pred_base_r         <= 32'b0;
        end else if (late_redirect_kill) begin
            // Payload is architecturally dead.  Keeping it unchanged avoids
            // adding redirect control to every payload D/CE cone.
        end else if (id_payload_capture) begin
            pc_r              <= id_pc;
            pred_taken_r      <= id_pred_taken;
            pred_target_r     <= id_pred_target;
            npc_op_r          <= id_npc_op;
            ext_r             <= id_ext;
            target_ext_r      <= id_target_ext;
            raw_rD1_r         <= id_raw_rD1;
            raw_rD2_r         <= id_raw_rD2;
            rR1_r             <= id_rR1;
            rR1_re_r          <= id_rR1_re;
            rR2_r             <= id_rR2;
            rR2_re_r          <= id_rR2_re;
            alu_op_r          <= id_alu_op;
            alua_sel_r        <= id_alua_sel;
            alub_sel_r        <= id_alub_sel;
            rf_we_r           <= id_rf_we;
            wR_r              <= id_wR;
            wd_sel_r          <= id_wd_sel;
            ram_we_r          <= id_ram_we;
            ram_ext_op_r      <= id_ram_ext_op;
            is_br_jmp_r       <= id_is_br_jmp;
            branch_deferred_r <= id_branch_deferred;
            is_call_r         <= id_is_call;
            is_return_r       <= id_is_return;
            is_system_r       <= id_is_system;
            csr_we_r          <= id_csr_we;
            csr_rj_r          <= id_csr_rj;
            csr_num_r         <= id_csr_num;
            cacop_valid_r     <= id_cacop_valid;
            cacop_code_r      <= id_cacop_code;
            ordinary_late_consumer_r <=
                !id_is_br_jmp && !id_is_system &&
                (id_wd_sel != `WD_RAM) &&
                (id_alu_op != `ALU_MUL) &&
                (id_alu_op != `ALU_MULH) &&
                (id_alu_op != `ALU_MULHU);
            late_mul_add_eligible_r <=
                !id_is_br_jmp && !id_is_system &&
                (id_wd_sel != `WD_RAM) &&
                (id_alu_op == `ALU_ADD);
            consumer_is_mul_r <=
                (id_alu_op == `ALU_MUL) ||
                (id_alu_op == `ALU_MULH) ||
                (id_alu_op == `ALU_MULHU);
            jirl_pred_base_r <= id_pred_target - id_ext;
            case (id_alu_op)
                `ALU_B,
                `ALU_JIRL: branch_cmp_mode_r <= BR_CMP_ALWAYS;
                `ALU_BGEU,
                `ALU_SLTU: branch_cmp_mode_r <= BR_CMP_SLTU;
                `ALU_BGE,
                `ALU_SLT:  branch_cmp_mode_r <= BR_CMP_SLT;
                default:   branch_cmp_mode_r <= BR_CMP_EQ;
            endcase
            branch_cmp_invert_r <=
                (id_alu_op == `ALU_BGEU) ||
                (id_alu_op == `ALU_BGE) ||
                (id_alu_op == `ALU_BNE);
            is_store_wait_r <= (id_wd_sel == `WD_RAM) &&
                               (id_ram_we != `RAM_WE_N);
        end else begin
            if (wb_refresh_r1)
                raw_rD1_r <= wb_wd;
            if (wb_refresh_r2)
                raw_rD2_r <= wb_wd;
        end
    end

endmodule

// Carry-save three-input address candidate.  The two late-MUL candidates are
// instantiated with DONT_TOUCH so Vivado cannot algebraically move queue
// occupancy back in front of their carry chains.
(* keep_hierarchy = "yes" *)
module OF_add3_candidate (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    output wire [31:0] y
);
    wire [31:0] sum_bits = a ^ b ^ c;
    wire [31:0] carry_bits =
        ((a & b) | (a & c) | (b & c)) << 1;
    assign y = sum_bits + carry_bits;
endmodule
