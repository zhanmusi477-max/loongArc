`timescale 1ns / 1ps

`include "defines.vh"

`define BHT_IDX_W 7                     // 128 direct-mapped entries
`define BHT_ENTRY (1 << `BHT_IDX_W)
`define BHT_TAG_W 8

module BPU (
    input  wire         cpu_clk,
    input  wire         cpu_rstn,
    input  wire [31:0]  if_pc,
    input  wire         if_valid,
    input  wire         id_valid,
    input  wire         pl_suspend,
    input  wire [31:0]  ras_top,
    input  wire         ras_empty,
    output wire [31:0]  pred_target,
    output wire         pred_taken,
    output wire         pred_is_return,
    output wire         pred_error,
    input  wire         ex_valid,
    input  wire         ex_is_bj,
    input  wire         ex_is_return,
    input  wire [31:0]  ex_pc,
    input  wire         ex_pred_taken,
    input  wire [31:0]  ex_pred_target,
    input  wire         real_taken,
    input  wire [31:0]  real_target
);

`ifdef ENABLE_BPU

    // Keep valid bits separate so reset only clears 64 bits. The packed table
    // itself has no reset and therefore remains eligible for distributed RAM.
    localparam integer ENTRY_TARGET_LSB  = 0;
    localparam integer ENTRY_TARGET_MSB  = 31;
    localparam integer ENTRY_HISTORY_LSB = 32;
    localparam integer ENTRY_HISTORY_MSB = 33;
    localparam integer ENTRY_RETURN_BIT  = 34;
    localparam integer ENTRY_TAG_LSB     = 35;
    localparam integer ENTRY_TAG_MSB     = ENTRY_TAG_LSB + `BHT_TAG_W - 1;
    localparam integer ENTRY_W           = ENTRY_TAG_MSB + 1;

    (* ram_style = "distributed" *)
    reg [ENTRY_W-1:0] entry [`BHT_ENTRY-1:0];
    reg [`BHT_ENTRY-1:0] valid;

    // The 1024-entry index consumes PC[11:2]. Fold the higher address bytes
    // into the 8-bit tag so distinct code regions remain distinguishable.
    wire [`BHT_TAG_W-1:0] if_tag =
        if_pc[15:8] ^ if_pc[23:16] ^ if_pc[31:24];
    wire [`BHT_TAG_W-1:0] ex_tag =
        ex_pc[15:8] ^ ex_pc[23:16] ^ ex_pc[31:24];
    wire [`BHT_IDX_W-1:0] if_index = if_pc[`BHT_IDX_W+1:2];
    wire [`BHT_IDX_W-1:0] ex_index = ex_pc[`BHT_IDX_W+1:2];

    // Asynchronous prediction read: no extra prediction stage is introduced.
    wire [ENTRY_W-1:0] if_entry = entry[if_index];
    wire [`BHT_TAG_W-1:0] if_entry_tag =
        if_entry[ENTRY_TAG_MSB:ENTRY_TAG_LSB];
    wire [1:0] if_entry_history =
        if_entry[ENTRY_HISTORY_MSB:ENTRY_HISTORY_LSB];
    wire [31:0] if_entry_target =
        if_entry[ENTRY_TARGET_MSB:ENTRY_TARGET_LSB];
    wire if_entry_return = if_entry[ENTRY_RETURN_BIT];

    // The prediction decision drives all 32 target-select bits plus the
    // fetch metadata.  Permit synthesis/phys_opt to duplicate the small tag
    // comparison near those consumers instead of routing one high-fanout
    // asynchronous-table result across the whole front end.
    (* max_fanout = 8 *) wire pred_taken_i = valid[if_index] &&
                                             (if_entry_tag == if_tag) &&
                                             if_entry_history[1];
    assign pred_taken = pred_taken_i;
    wire [31:0] seq_target = if_pc + 32'h4;
    wire pred_use_ras = pred_taken_i && if_entry_return && !ras_empty;
    // Merge the former BPU taken/fallthrough mux and the top-level RAS mux.
    // Per bit this is one six-input Boolean function, so the prediction
    // recurrence no longer crosses two target-select LUTs and their
    // intervening route.  Prediction timing and table/RAS behaviour are
    // otherwise unchanged.
    assign pred_target =
        ({32{!pred_taken_i}} & seq_target) |
        ({32{pred_use_ras}} & ras_top) |
        ({32{pred_taken_i &&
             (!if_entry_return || ras_empty)}} & if_entry_target);
    assign pred_is_return = pred_taken_i && if_entry_return;

`ifndef SYNTHESIS
    wire [31:0] pred_target_reference = pred_use_ras ? ras_top :
        (pred_taken_i ? if_entry_target : seq_target);
    always @(posedge cpu_clk) begin
        if (cpu_rstn && (pred_target !== pred_target_reference))
            $fatal(1, "merged BPU/RAS target differs from reference");
    end
`endif

    wire taken_error = (ex_pred_taken && !ex_is_bj) |
                       (ex_is_bj && (ex_pred_taken != real_taken));
    wire target_error = ex_is_bj && ex_pred_taken && real_taken &&
                        (ex_pred_target != real_target);
    assign pred_error = ex_valid && (taken_error || target_error);

    // Register one accepted EX result and update the table one cycle later.
    wire update_accept = ex_valid && !pl_suspend &&
                         (ex_is_bj || ex_pred_taken);
    reg                   update_valid;
    reg                   update_is_bj;
    reg                   update_is_return;
    reg                   update_pred_taken;
    reg                   update_real_taken;
    reg [`BHT_IDX_W-1:0] update_index;
    reg [`BHT_TAG_W-1:0] update_tag;
    reg [31:0]            update_pred_target;
    reg [31:0]            update_target;

    // A second asynchronous read supplies the old counter/target to the one
    // packed write port. The packed entry retains a single full-word write
    // point and avoids the original independent tag/history/target fanout.
    wire [ENTRY_W-1:0] current_entry = entry[update_index];
    wire [`BHT_TAG_W-1:0] current_tag =
        current_entry[ENTRY_TAG_MSB:ENTRY_TAG_LSB];
    wire [1:0] current_history =
        current_entry[ENTRY_HISTORY_MSB:ENTRY_HISTORY_LSB];
    wire [31:0] current_target =
        current_entry[ENTRY_TARGET_MSB:ENTRY_TARGET_LSB];
    wire current_return = current_entry[ENTRY_RETURN_BIT];

    wire update_tag_hit = valid[update_index] &&
                          (current_tag == update_tag);
    wire add_entry = update_valid && update_is_bj &&
                     update_real_taken && !valid[update_index];
    wire update_existing_entry = update_valid && update_is_bj &&
                                 update_tag_hit;
    wire replace_entry = update_valid && update_is_bj &&
                         update_real_taken && valid[update_index] &&
                         !update_tag_hit;
    wire clear_entry = update_valid && !update_is_bj &&
                       update_pred_taken && update_tag_hit;
    wire update_target_entry = update_existing_entry &&
                               update_real_taken &&
                               (!update_pred_taken ||
                                (update_pred_target != update_target));

    reg [1:0] next_history;
    always @(*) begin
        if (update_real_taken) begin
            case (current_history)
                2'b00: next_history = 2'b01;
                2'b01: next_history = 2'b10;
                2'b10: next_history = 2'b11;
                default: next_history = 2'b11;
            endcase
        end else begin
            case (current_history)
                2'b00: next_history = 2'b00;
                2'b01: next_history = 2'b00;
                2'b10: next_history = 2'b01;
                default: next_history = 2'b10;
            endcase
        end
    end

    wire allocate_entry = add_entry || replace_entry;
    wire entry_write_enable = allocate_entry || update_existing_entry;
    wire [`BHT_TAG_W-1:0] entry_write_tag =
        allocate_entry ? update_tag : current_tag;
    wire [1:0] entry_write_history =
        allocate_entry ? 2'b10 : next_history;
    wire [31:0] entry_write_target =
        allocate_entry ? update_target :
        (update_target_entry ? update_target : current_target);
    wire entry_write_return = update_valid ? update_is_return : current_return;
    wire [ENTRY_W-1:0] entry_write_data = {
        entry_write_tag,
        entry_write_return,
        entry_write_history,
        entry_write_target
    };

    // Register the complete table write transaction.  The asynchronous old
    // entry read and counter/tag decisions end here; distributed-RAM WE,
    // address and data are all driven by local flops on the following cycle.
    reg                   entry_write_enable_r;
    reg [`BHT_IDX_W-1:0] entry_write_index_r;
    reg [ENTRY_W-1:0]    entry_write_data_r;
    reg                   clear_entry_r;
    reg                   allocate_entry_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            valid              <= {`BHT_ENTRY{1'b0}};
            update_valid       <= 1'b0;
            update_is_bj       <= 1'b0;
            update_is_return   <= 1'b0;
            update_pred_taken  <= 1'b0;
            update_real_taken  <= 1'b0;
            update_index       <= {`BHT_IDX_W{1'b0}};
            update_tag         <= {`BHT_TAG_W{1'b0}};
            update_pred_target <= 32'h0;
            update_target      <= 32'h0;
            entry_write_enable_r <= 1'b0;
            entry_write_index_r  <= {`BHT_IDX_W{1'b0}};
            entry_write_data_r   <= {ENTRY_W{1'b0}};
            clear_entry_r        <= 1'b0;
            allocate_entry_r     <= 1'b0;
        end else begin
            update_valid <= update_accept;
            // Capture the resolve payload every cycle and qualify it only with
            // update_valid.  Holding 129 payload flops with update_accept made
            // the complete OF readiness/branch-resolve cone drive their CE
            // pins.  Unconditional capture is architecturally identical while
            // leaving that cone with a single, local update_valid endpoint.
            update_is_bj       <= ex_is_bj;
            update_is_return   <= ex_is_return;
            update_pred_taken  <= ex_pred_taken;
            update_real_taken  <= real_taken;
            update_index       <= ex_index;
            update_tag         <= ex_tag;
            update_pred_target <= ex_pred_target;
            update_target      <= real_target;

            entry_write_enable_r <= entry_write_enable;
            entry_write_index_r  <= update_index;
            entry_write_data_r   <= entry_write_data;
            clear_entry_r        <= clear_entry;
            allocate_entry_r     <= allocate_entry;

            if (clear_entry_r)
                valid[entry_write_index_r] <= 1'b0;
            else if (allocate_entry_r)
                valid[entry_write_index_r] <= 1'b1;

        end
    end

    // Keep the packed table out of the asynchronous-reset process. This is
    // the single full-word write point Vivado can map to distributed RAM.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && entry_write_enable_r)
            entry[entry_write_index_r] <= entry_write_data_r;
    end

`else

    assign pred_taken  = 1'b0;
    assign pred_target = if_pc + 32'h4;
    assign pred_is_return = 1'b0;

    wire taken_error  = ex_is_bj && real_taken;
    wire target_error = 1'b0;
    assign pred_error = ex_valid && (taken_error || target_error);

`endif

endmodule
