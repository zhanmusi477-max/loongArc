`timescale 1ns / 1ps

module ID1_ID2 (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    input  wire        hold,
    input  wire        flush,
    input  wire        valid_in,
    input  wire [31:0] pc_in,
    input  wire [31:0] pc_plus4_in,
    input  wire [31:0] inst_in,
    input  wire [31:0] raw_rD1_in,
    input  wire [31:0] raw_rD2_in,
    input  wire [ 2:0] ext_op_in,
    input  wire [31:0] taken_target_in,
    input  wire        pred_taken_in,
    input  wire [31:0] pred_target_in,
    input  wire [ 1:0] npc_op_in,
    input  wire [ 4:0] rR1_in,
    input  wire        rR1_re_in,
    input  wire [ 4:0] rR2_in,
    input  wire        rR2_re_in,
    input  wire [ 4:0] wR_in,
    input  wire        rf_we_in,
    input  wire [ 1:0] wd_sel_in,
    input  wire [ 4:0] alu_op_in,
    input  wire        alua_sel_in,
    input  wire        alub_sel_in,
    input  wire [ 3:0] ram_we_in,
    input  wire [ 2:0] ram_ext_op_in,
    input  wire        is_br_jmp_in,
    input  wire        is_call_in,
    input  wire        is_return_in,
    input  wire        is_cpucfg_in,
    input  wire        is_csr_in,
    input  wire        is_cacop_in,
    input  wire        system_issue_class_in,
    input  wire        pair_class_ok_in,
    input  wire        control_consumer_in,
    input  wire        wb_valid,
    input  wire        wb_rf_we,
    input  wire [ 4:0] wb_wR,
    input  wire [31:0] wb_wd,
    input  wire        wb2_valid,
    input  wire        wb2_rf_we,
    input  wire [ 4:0] wb2_wR,
    input  wire [31:0] wb2_wd,

    output reg         valid_out,
    output reg  [31:0] pc_out,
    output reg  [31:0] pc_plus4_out,
    output reg  [31:0] inst_out,
    output reg  [31:0] raw_rD1_out,
    output reg  [31:0] raw_rD2_out,
    output reg  [ 2:0] ext_op_out,
    output reg  [31:0] taken_target_out,
    output reg         pred_taken_out,
    output reg  [31:0] pred_target_out,
    output reg  [ 1:0] npc_op_out,
    output reg  [ 4:0] rR1_out,
    output reg         rR1_re_out,
    output reg  [ 4:0] rR2_out,
    output reg         rR2_re_out,
    output reg  [ 4:0] wR_out,
    output reg         rf_we_out,
    output reg  [ 1:0] wd_sel_out,
    output reg  [ 4:0] alu_op_out,
    output reg         alua_sel_out,
    output reg         alub_sel_out,
    output reg  [ 3:0] ram_we_out,
    output reg  [ 2:0] ram_ext_op_out,
    output reg         is_br_jmp_out,
    output reg         is_call_out,
    output reg         is_return_out,
    output reg         is_cpucfg_out,
    output reg         is_csr_out,
    output reg         is_cacop_out,
    (* KEEP = "TRUE" *) output reg system_issue_class_out,
    (* KEEP = "TRUE" *) output reg pair_class_ok_out,
    (* KEEP = "TRUE" *) output reg control_consumer_out
);

    wire wb_refresh_r1 = valid_out && wb_valid && wb_rf_we &&
                         rR1_re_out && (rR1_out != 5'd0) &&
                         (rR1_out == wb_wR);
    wire wb_refresh_r2 = valid_out && wb_valid && wb_rf_we &&
                         rR2_re_out && (rR2_out != 5'd0) &&
                         (rR2_out == wb_wR);
    wire wb2_refresh_r1 = valid_out && wb2_valid && wb2_rf_we &&
                          rR1_re_out && (rR1_out != 5'd0) &&
                          (rR1_out == wb2_wR);
    wire wb2_refresh_r2 = valid_out && wb2_valid && wb2_rf_we &&
                          rR2_re_out && (rR2_out != 5'd0) &&
                          (rR2_out == wb2_wR);

    // Flush affects only the architectural validity bit.  Keeping it out of
    // the payload register enables prevents the ID2 branch decision from
    // becoming a reset/enable tree for every ID1/ID2 field.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn || flush)
            valid_out <= 1'b0;
        else if (!hold)
            valid_out <= valid_in;
    end

    // The payload is architecturally observable only when valid_out is set.
    // Capture it only on a real IBUF->ID1 transfer.  Rewriting every field on
    // an empty cycle made the downstream M1 backpressure/IBUF-pop decision
    // pass through the complete ID1 decoder and return to the D/R pins of this
    // register bank.  valid_in is mutually exclusive with hold at the caller,
    // so this is cycle-equivalent while giving the payload a local write
    // boundary.  A resident entry still receives the required WB refresh.
    always @(posedge cpu_clk) begin
        if (valid_in) begin
            pc_out           <= pc_in;
            pc_plus4_out     <= pc_plus4_in;
            inst_out         <= inst_in;
            raw_rD1_out      <= raw_rD1_in;
            raw_rD2_out      <= raw_rD2_in;
            ext_op_out       <= ext_op_in;
            taken_target_out <= taken_target_in;
            pred_taken_out   <= pred_taken_in;
            pred_target_out  <= pred_target_in;
            npc_op_out       <= npc_op_in;
            rR1_out          <= rR1_in;
            rR1_re_out       <= rR1_re_in;
            rR2_out          <= rR2_in;
            rR2_re_out       <= rR2_re_in;
            wR_out           <= wR_in;
            rf_we_out        <= rf_we_in;
            wd_sel_out       <= wd_sel_in;
            alu_op_out       <= alu_op_in;
            alua_sel_out     <= alua_sel_in;
            alub_sel_out     <= alub_sel_in;
            ram_we_out       <= ram_we_in;
            ram_ext_op_out   <= ram_ext_op_in;
            is_br_jmp_out    <= is_br_jmp_in;
            is_call_out      <= is_call_in;
            is_return_out    <= is_return_in;
            is_cpucfg_out    <= is_cpucfg_in;
            is_csr_out       <= is_csr_in;
            is_cacop_out     <= is_cacop_in;
            // These independent class bits terminate the ID1 decode at this
            // boundary.  Downstream issue/slot-1 enables must not rebuild a
            // high-fanout OR tree from the individual instruction classes.
            system_issue_class_out <= system_issue_class_in;
            pair_class_ok_out      <= pair_class_ok_in;
            control_consumer_out   <= control_consumer_in;
        end else begin
            // A held ID2 entry may outlive the producer's live forwarding
            // window.  Refresh only from the architecturally registered WB
            // result; no EX/M1/M2 data is allowed into this boundary.
            // Slot 1 is younger than slot 0 inside a dual-issued bundle, so
            // its same-cycle write has architectural priority.  Pair WAW is
            // rejected by issue logic, but retaining the priority here makes
            // the boundary correct even for defensive/unexpected collisions.
            if (wb2_refresh_r1)
                raw_rD1_out <= wb2_wd;
            else if (wb_refresh_r1)
                raw_rD1_out <= wb_wd;
            if (wb2_refresh_r2)
                raw_rD2_out <= wb2_wd;
            else if (wb_refresh_r2)
                raw_rD2_out <= wb_wd;
        end
    end

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && valid_in && hold)
            $fatal(1, "ID1/ID2 valid_in asserted while the boundary is held");
    end
`endif

endmodule
