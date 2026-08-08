`timescale 1ns / 1ps

`include "defines.vh"

// Keep one target-generation cone per registered IBUF head.  Without this
// small hierarchy Vivado factors the final B/C payload selector in front of a
// shared carry chain, rebuilding a pair-control -> branch-target path.  The
// two instances below remain ordinary combinational ID1 logic; this module
// only protects the already-existing registered boundary.
(* keep_hierarchy = "yes" *)
module ID1_target_precompute (
    input  wire [31:0] pc,
    input  wire [31:0] inst,
    output wire [31:0] pc_plus4,
    output wire [31:0] pc_relative_target
);
    wire [31:0] target16_offset =
        {{14{inst[25]}}, inst[25:10], 2'b00};
    wire [31:0] target26_offset =
        {{4{inst[9]}}, inst[9:0], inst[25:10], 2'b00};
    wire target_is_ext26 = (inst[31:27] == 5'b01010);
    wire [31:0] selected_offset = target_is_ext26 ?
                                  target26_offset : target16_offset;

    assign pc_plus4 = pc + 32'd4;
    assign pc_relative_target = pc + selected_offset;
endmodule

module ID_stage (
    input  wire        cpu_rstn,
    input  wire        cpu_clk,
    input  wire        pl_suspend,
    input  wire        id2_stall,
    input  wire        pred_error,
    input  wire        if_valid,
    input  wire [31:0] if_pc,
    input  wire [31:0] if_npc,
    input  wire [31:0] if_inst,
    input  wire        if_r2_use_rd,
    input  wire [31:0] if_target_offset,
    input  wire        if_pred_taken,
    input  wire [31:0] if_pred_target,
    // Registered second IBUF head.  Both heads are decoded and read from the
    // RF in parallel; if_select_second is allowed to control only the final
    // payload mux immediately before ID1/ID2.  This prevents live pair/hazard
    // logic from preceding decode and RF access in the same timing path.
    input  wire [31:0] if_pc2,
    input  wire [31:0] if_inst2,
    input  wire        if_r2_use_rd2,
    input  wire [31:0] if_target_offset2,
    input  wire        if_pred_taken2,
    input  wire [31:0] if_pred_target2,
    input  wire        if_select_second,
    input  wire        wb_rf_we,
    input  wire        wb_valid,
    input  wire [ 4:0] wb_wR,
    input  wire [31:0] wb_wd,
    input  wire        wb2_rf_we,
    input  wire        wb2_valid,
    input  wire [ 4:0] wb2_wR,
    input  wire [31:0] wb2_wd,
    // Kept for interface compatibility with the restricted decoder.  The RF
    // ports now read IBUF head0/head1 directly in parallel, so these addresses
    // are informational only; aux_rD1/2 return the head0 values used by slot1.
    input  wire [ 4:0] aux_rR1,
    input  wire [ 4:0] aux_rR2,
    output wire [31:0] aux_rD1,
    output wire [31:0] aux_rD2,
    // Decoded source metadata for the exact payload selected at the ID1/ID2
    // capture mux.  These signals terminate at a top-level tag register.
    output wire [ 4:0] capture_rR1,
    output wire        capture_rR1_re,
    output wire [ 4:0] capture_rR2,
    output wire        capture_rR2_re,
    // Keep the two already-parallel decode results visible separately.  The
    // top level can precompute dependency tags for B and C before the late
    // pair select, instead of placing that select in front of decode/tag
    // comparison logic.
    output wire [ 4:0] capture0_rR1,
    output wire        capture0_rR1_re,
    output wire [ 4:0] capture0_rR2,
    output wire        capture0_rR2_re,
    output wire [ 4:0] capture1_rR1,
    output wire        capture1_rR1_re,
    output wire [ 4:0] capture1_rR2,
    output wire        capture1_rR2_re,
    input  wire        wb_csr_we,
    input  wire [13:0] wb_csr_num,
    input  wire [31:0] wb_csr_wmask,
    input  wire [31:0] wb_csr_wdata,
    // Metadata for the producer which will cross M2->WB on this edge.  The
    // match bit is registered with the ID2 payload; no M2 data enters ID1.
    input  wire        next_wb_valid,
    input  wire        next_wb_rf_we,
    input  wire [ 4:0] next_wb_wR,
    // Registered slot-0 M2 matches from the resident ID2 writer tag.  Reuse
    // these exact facts when a held payload follows M2 into WB; repeating the
    // live five-bit comparison here placed the complete ID2-stall cone before
    // four more LUT levels on the WB-match metadata D inputs.
    input  wire        resident_m2_match_r1,
    input  wire        resident_m2_match_r2,

    output wire        id_waiting,
    output wire        id_valid,
    output wire [31:0] id_pc,
    output wire [31:0] id_pc_plus4,
    output wire        id_pred_taken,
    output wire [31:0] id_pred_target,
    output wire [ 1:0] id_npc_op,
    output wire [31:0] id_ext,
    output wire [31:0] id_target_ext,
    output wire [31:0] id_real_rD1,
    output wire [31:0] id_real_rD2,
    output wire [31:0] id_mul_rD1,
    output wire [31:0] id_mul_rD2,
    output wire [ 4:0] id_alu_op,
    output wire        id_alua_sel,
    output wire        id_alub_sel,
    output wire        id_rf_we,
    output wire [ 4:0] id_wR,
    output wire [ 1:0] id_wd_sel,
    output wire [ 3:0] id_ram_we,
    output wire [ 2:0] id_ram_ext_op,
    output wire        id_is_ld_st,
    output wire        id_is_mul_div,
    output wire        id_is_br_jmp,
    output wire        id_is_call,
    output wire        id_is_return,
    output wire        id_is_system,
    output wire        id_pair_class_ok,
    output wire        id_control_consumer,
    output wire        id_br_jmp_raw,
    output wire        id_br_jmp_f,
    output wire [31:0] id_taken_target,
    output wire [ 4:0] id_rR1,
    output wire        id_rR1_re,
    output wire [ 4:0] id_rR2,
    output wire        id_rR2_re,
    output wire [31:0] csr_crmd,
    output wire [31:0] csr_dmw0,
    output wire [31:0] csr_dmw1,
    output wire        id_csr_we,
    output wire [ 4:0] id_csr_rj,
    output wire [13:0] id_csr_num,
    output wire [31:0] id_csr_wmask,
    output wire [31:0] id_csr_wdata,
    output wire        cacop_valid,
    output wire [ 4:0] cacop_code,
    output wire [31:0] cacop_addr,
    input  wire        ifetch_valid,
    input  wire [31:0] ifetch_inst
);

    // ID1: decode, immediate generation and raw RF read only.
    wire [31:0] d_inst = if_inst;
    wire        d_is_cpucfg = (d_inst[31:10] == 22'h00001b);
    wire        d_is_csr    = (d_inst[31:24] == 8'h04);
    wire        d_is_cacop  = (d_inst[31:22] == 10'h018);
    wire        d_is_priv   = d_is_cpucfg | d_is_csr | d_is_cacop;
    wire [ 4:0] d_csr_rj    = d_inst[9:5];
    wire        d_is_bl     = (d_inst[31:26] == 6'h15);
    wire        d_is_jirl   = (d_inst[31:26] == 6'h13);

    wire [ 1:0] cu_npc_op;
    wire        cu_is_br_jmp;
    wire [ 2:0] cu_ext_op;
    wire        cu_r2_sel;
    wire        cu_rR1_re, cu_rR2_re;
    wire        cu_alua_sel, cu_alub_sel;
    wire [ 4:0] cu_alu_op;
    wire [ 2:0] cu_ram_ext_op;
    wire [ 3:0] cu_ram_we;
    wire        cu_rf_we, cu_wr_sel;
    wire [ 1:0] cu_wd_sel;

    CU u_CU (
        .inst_31_15(d_inst[31:15]), .npc_op(cu_npc_op),
        .is_br_jmp(cu_is_br_jmp), .ext_op(cu_ext_op), .r2_sel(cu_r2_sel),
        .rR1_re(cu_rR1_re), .rR2_re(cu_rR2_re), .alua_sel(cu_alua_sel),
        .alub_sel(cu_alub_sel), .alu_op(cu_alu_op), .ram_ext_op(cu_ram_ext_op),
        .ram_we(cu_ram_we), .rf_we(cu_rf_we), .wr_sel(cu_wr_sel),
        .wd_sel(cu_wd_sel)
    );

    wire [ 2:0] d_ext_op = d_is_cacop ? `EXT_12 : cu_ext_op;
    wire [ 4:0] d_rR1 = d_inst[9:5];
    wire [ 4:0] d_rR2 = if_r2_use_rd ?
                         d_inst[4:0] : d_inst[14:10];
    wire        d_rR1_re = d_is_cpucfg | d_is_cacop |
                            (d_is_csr && (d_csr_rj > 5'd1)) |
                            (!d_is_priv && cu_rR1_re);
    wire        d_rR2_re = d_is_csr ? (d_csr_rj != 5'd0) :
                            (d_is_priv ? 1'b0 : cu_rR2_re);
    wire [ 4:0] d_wR = d_is_bl ? 5'd1 :
                        (d_is_cpucfg | d_is_csr) ? d_inst[4:0] :
                        (cu_wr_sel ? d_inst[4:0] : 5'd1);
    wire [ 1:0] d_npc_op = d_is_priv ? `NPC_PC4 : cu_npc_op;
    wire        d_is_br_jmp = d_is_priv ? 1'b0 : cu_is_br_jmp;
    wire        d_is_call = d_is_bl | (d_is_jirl && (d_inst[4:0] == 5'd1));
    wire        d_is_return = d_is_jirl && (d_inst[4:0] == 5'd0) &&
                              (d_inst[9:5] == 5'd1) &&
                              (d_inst[25:10] == 16'd0);

    // Decode the registered second IBUF head in parallel.  Do not select the
    // instruction before either CU: the pair decision must end at a shallow
    // payload mux, rather than pass through CU -> RF -> WB bypass.
    wire [31:0] e_inst = if_inst2;
    wire        e_is_cpucfg = (e_inst[31:10] == 22'h00001b);
    wire        e_is_csr    = (e_inst[31:24] == 8'h04);
    wire        e_is_cacop  = (e_inst[31:22] == 10'h018);
    wire        e_is_priv   = e_is_cpucfg | e_is_csr | e_is_cacop;
    wire [ 4:0] e_csr_rj    = e_inst[9:5];
    wire        e_is_bl     = (e_inst[31:26] == 6'h15);
    wire        e_is_jirl   = (e_inst[31:26] == 6'h13);

    wire [ 1:0] e_cu_npc_op;
    wire        e_cu_is_br_jmp;
    wire [ 2:0] e_cu_ext_op;
    wire        e_cu_r2_sel;
    wire        e_cu_rR1_re, e_cu_rR2_re;
    wire        e_cu_alua_sel, e_cu_alub_sel;
    wire [ 4:0] e_cu_alu_op;
    wire [ 2:0] e_cu_ram_ext_op;
    wire [ 3:0] e_cu_ram_we;
    wire        e_cu_rf_we, e_cu_wr_sel;
    wire [ 1:0] e_cu_wd_sel;

    CU u_CU_head2 (
        .inst_31_15(e_inst[31:15]), .npc_op(e_cu_npc_op),
        .is_br_jmp(e_cu_is_br_jmp), .ext_op(e_cu_ext_op),
        .r2_sel(e_cu_r2_sel), .rR1_re(e_cu_rR1_re),
        .rR2_re(e_cu_rR2_re), .alua_sel(e_cu_alua_sel),
        .alub_sel(e_cu_alub_sel), .alu_op(e_cu_alu_op),
        .ram_ext_op(e_cu_ram_ext_op), .ram_we(e_cu_ram_we),
        .rf_we(e_cu_rf_we), .wr_sel(e_cu_wr_sel),
        .wd_sel(e_cu_wd_sel)
    );

    wire [ 2:0] e_ext_op = e_is_cacop ? `EXT_12 : e_cu_ext_op;
    wire [ 4:0] e_rR1 = e_inst[9:5];
    wire [ 4:0] e_rR2 = if_r2_use_rd2 ?
                         e_inst[4:0] : e_inst[14:10];
    wire        e_rR1_re = e_is_cpucfg | e_is_cacop |
                            (e_is_csr && (e_csr_rj > 5'd1)) |
                            (!e_is_priv && e_cu_rR1_re);
    wire        e_rR2_re = e_is_csr ? (e_csr_rj != 5'd0) :
                            (e_is_priv ? 1'b0 : e_cu_rR2_re);
    wire [ 4:0] e_wR = e_is_bl ? 5'd1 :
                        (e_is_cpucfg | e_is_csr) ? e_inst[4:0] :
                        (e_cu_wr_sel ? e_inst[4:0] : 5'd1);
    wire [ 1:0] e_npc_op = e_is_priv ? `NPC_PC4 : e_cu_npc_op;
    wire        e_is_br_jmp = e_is_priv ? 1'b0 : e_cu_is_br_jmp;
    wire        e_is_call = e_is_bl |
                            (e_is_jirl && (e_inst[4:0] == 5'd1));
    wire        e_is_return = e_is_jirl && (e_inst[4:0] == 5'd0) &&
                              (e_inst[9:5] == 5'd1) &&
                              (e_inst[25:10] == 16'd0);

`ifndef SYNTHESIS
    wire d_r2_sel_reference = d_is_csr ? `R2_RD : cu_r2_sel;
    wire e_r2_sel_reference = e_is_csr ? `R2_RD : e_cu_r2_sel;
    wire [4:0] d_rR2_reference = d_r2_sel_reference ?
                                  d_inst[14:10] : d_inst[4:0];
    wire [4:0] e_rR2_reference = e_r2_sel_reference ?
                                  e_inst[14:10] : e_inst[4:0];
    always @(posedge cpu_clk) begin
        if (cpu_rstn && if_valid &&
            (d_rR2 !== d_rR2_reference))
            $fatal(1, "head0 shallow rR2 decode differs from CU");
        if (cpu_rstn && if_valid && if_select_second &&
            (e_rR2 !== e_rR2_reference))
            $fatal(1, "head1 shallow rR2 decode differs from CU");
    end
`endif

    wire [31:0] d_raw_rD1, d_raw_rD2;
    wire [31:0] e_raw_rD1, e_raw_rD2;
    // The RF writes on the same edge that ID1 captures its read values.  Make
    // the boundary explicitly write-first so a value leaving WB is not lost
    // before ID2 gets a chance to select it.
    // The read-enable bits describe whether the captured value will be used;
    // they do not change the value which a matching architectural register
    // must observe.  Keeping them in this same-edge WB bypass used to put the
    // complete opcode decoder in front of every ID1 operand register.  For an
    // unused source either RF/WB value is unobservable, so match only the
    // register indices here and carry the read-enable metadata independently.
    wire d_cap_r1_wb  = wb_valid && wb_rf_we && (d_rR1 != 5'd0) &&
                        (d_rR1 == wb_wR);
    wire d_cap_r2_wb  = wb_valid && wb_rf_we && (d_rR2 != 5'd0) &&
                        (d_rR2 == wb_wR);
    wire d_cap_r1_wb2 = wb2_valid && wb2_rf_we && (d_rR1 != 5'd0) &&
                        (d_rR1 == wb2_wR);
    wire d_cap_r2_wb2 = wb2_valid && wb2_rf_we && (d_rR2 != 5'd0) &&
                         (d_rR2 == wb2_wR);
    wire [31:0] d_capture_rD1 = d_cap_r1_wb2 ? wb2_wd :
                                d_cap_r1_wb ? wb_wd : d_raw_rD1;
    wire [31:0] d_capture_rD2 = d_cap_r2_wb2 ? wb2_wd :
                                d_cap_r2_wb ? wb_wd : d_raw_rD2;

    wire e_cap_r1_wb  = wb_valid && wb_rf_we && (e_rR1 != 5'd0) &&
                        (e_rR1 == wb_wR);
    wire e_cap_r2_wb  = wb_valid && wb_rf_we && (e_rR2 != 5'd0) &&
                        (e_rR2 == wb_wR);
    wire e_cap_r1_wb2 = wb2_valid && wb2_rf_we && (e_rR1 != 5'd0) &&
                        (e_rR1 == wb2_wR);
    wire e_cap_r2_wb2 = wb2_valid && wb2_rf_we && (e_rR2 != 5'd0) &&
                        (e_rR2 == wb2_wR);
    wire [31:0] e_capture_rD1 = e_cap_r1_wb2 ? wb2_wd :
                                e_cap_r1_wb ? wb_wd : e_raw_rD1;
    wire [31:0] e_capture_rD2 = e_cap_r2_wb2 ? wb2_wd :
                                e_cap_r2_wb ? wb_wd : e_raw_rD2;

    RF_4R2W u_RF (
        .cpu_clk(cpu_clk),
        .rR1(d_rR1), .rR2(d_rR2), .rR3(e_rR1), .rR4(e_rR2),
        .we(wb_valid && wb_rf_we), .wR(wb_wR), .wD(wb_wd),
        .we2(wb2_valid && wb2_rf_we), .wR2(wb2_wR), .wD2(wb2_wd),
        .rD1(d_raw_rD1), .rD2(d_raw_rD2),
        .rD3(e_raw_rD1), .rD4(e_raw_rD2)
    );

    // The restricted younger lane always executes head0 (B).  Return its
    // already-completed RF/WB capture, independent of the C selection used by
    // the ordinary ID path.
    assign aux_rD1 = d_capture_rD1;
    assign aux_rD2 = d_capture_rD2;

    // Build the complete target and sequential-PC values independently for B
    // and C.  The pair decision reaches only the final payload muxes below.
    wire [31:0] d_pc_plus4;
    wire [31:0] d_pc_relative_target;
    wire [31:0] e_pc_plus4;
    wire [31:0] e_pc_relative_target;
    (* dont_touch = "true" *) ID1_target_precompute u_target_head0 (
        .pc(if_pc), .inst(if_target_offset),
        .pc_plus4(d_pc_plus4),
        .pc_relative_target(d_pc_relative_target)
    );
    (* dont_touch = "true" *) ID1_target_precompute u_target_head1 (
        .pc(if_pc2), .inst(if_target_offset2),
        .pc_plus4(e_pc_plus4),
        .pc_relative_target(e_pc_relative_target)
    );

    // All expensive work above is parallel and starts at registered IBUF
    // heads.  The live pair decision reaches only these final 2:1 muxes.
    wire [31:0] cap_pc = if_select_second ? if_pc2 : if_pc;
    wire [31:0] cap_pc_plus4 = if_select_second ?
                               e_pc_plus4 : d_pc_plus4;
    wire [31:0] cap_inst = if_select_second ? e_inst : d_inst;
    wire [31:0] cap_raw_rD1 = if_select_second ?
                              e_capture_rD1 : d_capture_rD1;
    wire [31:0] cap_raw_rD2 = if_select_second ?
                              e_capture_rD2 : d_capture_rD2;
    wire [ 2:0] cap_ext_op = if_select_second ? e_ext_op : d_ext_op;
    wire [31:0] cap_taken_target = if_select_second ?
                                   e_pc_relative_target :
                                   d_pc_relative_target;
    wire        cap_pred_taken = if_select_second ?
                                  if_pred_taken2 : if_pred_taken;
    wire [31:0] cap_pred_target = if_select_second ?
                                  if_pred_target2 : if_pred_target;
    wire [ 1:0] cap_npc_op = if_select_second ? e_npc_op : d_npc_op;
    wire [ 4:0] cap_rR1 = if_select_second ? e_rR1 : d_rR1;
    wire        cap_rR1_re = if_select_second ? e_rR1_re : d_rR1_re;
    wire [ 4:0] cap_rR2 = if_select_second ? e_rR2 : d_rR2;
    wire        cap_rR2_re = if_select_second ? e_rR2_re : d_rR2_re;
    assign capture_rR1    = cap_rR1;
    assign capture_rR1_re = cap_rR1_re;
    assign capture_rR2    = cap_rR2;
    assign capture_rR2_re = cap_rR2_re;
    assign capture0_rR1    = d_rR1;
    assign capture0_rR1_re = d_rR1_re;
    assign capture0_rR2    = d_rR2;
    assign capture0_rR2_re = d_rR2_re;
    assign capture1_rR1    = e_rR1;
    assign capture1_rR1_re = e_rR1_re;
    assign capture1_rR2    = e_rR2;
    assign capture1_rR2_re = e_rR2_re;
    wire [ 4:0] cap_wR = if_select_second ? e_wR : d_wR;
    wire        cap_rf_we = if_select_second ?
        ((e_is_cpucfg | e_is_csr) ? 1'b1 :
         (e_is_cacop ? 1'b0 : e_cu_rf_we)) :
        ((d_is_cpucfg | d_is_csr) ? 1'b1 :
         (d_is_cacop ? 1'b0 : cu_rf_we));
    wire [ 1:0] cap_wd_sel = if_select_second ?
        ((e_is_cpucfg | e_is_csr) ? `WD_CSR : e_cu_wd_sel) :
        ((d_is_cpucfg | d_is_csr) ? `WD_CSR : cu_wd_sel);
    wire [ 4:0] cap_alu_op = if_select_second ?
        (e_is_priv ? `ALU_ADD : e_cu_alu_op) :
        (d_is_priv ? `ALU_ADD : cu_alu_op);
    wire        cap_alua_sel = if_select_second ?
        (e_is_priv ? `ALUA_R1 : e_cu_alua_sel) :
        (d_is_priv ? `ALUA_R1 : cu_alua_sel);
    wire        cap_alub_sel = if_select_second ?
        (e_is_priv ? `ALUB_EXT : e_cu_alub_sel) :
        (d_is_priv ? `ALUB_EXT : cu_alub_sel);
    wire [ 3:0] cap_ram_we = if_select_second ?
        (e_is_priv ? `RAM_WE_N : e_cu_ram_we) :
        (d_is_priv ? `RAM_WE_N : cu_ram_we);
    wire [ 2:0] cap_ram_ext_op = if_select_second ?
        (e_is_priv ? `RAM_EXT_N : e_cu_ram_ext_op) :
        (d_is_priv ? `RAM_EXT_N : cu_ram_ext_op);
    wire        cap_is_br_jmp = if_select_second ?
                                e_is_br_jmp : d_is_br_jmp;
    wire        cap_is_call = if_select_second ? e_is_call : d_is_call;
    wire        cap_is_return = if_select_second ?
                                 e_is_return : d_is_return;
    wire        cap_is_cpucfg = if_select_second ?
                                 e_is_cpucfg : d_is_cpucfg;
    wire        cap_is_csr = if_select_second ? e_is_csr : d_is_csr;
    wire        cap_is_cacop = if_select_second ? e_is_cacop : d_is_cacop;
    // Build the issue classes independently for both registered IBUF heads,
    // then select only the final one-bit payloads.  The selected values cross
    // ID1/ID2 and isolate all downstream issue enables from opcode decode.
    wire d_system_issue_class = d_is_cpucfg | d_is_csr | d_is_cacop;
    wire e_system_issue_class = e_is_cpucfg | e_is_csr | e_is_cacop;
    wire d_control_consumer = d_is_br_jmp | d_system_issue_class;
    wire e_control_consumer = e_is_br_jmp | e_system_issue_class;
    wire d_pair_class_ok = !d_control_consumer && !if_pred_taken;
    wire e_pair_class_ok = !e_control_consumer && !if_pred_taken2;
    wire cap_system_issue_class = if_select_second ?
                                  e_system_issue_class :
                                  d_system_issue_class;
    wire cap_control_consumer = if_select_second ?
                                e_control_consumer : d_control_consumer;
    wire cap_pair_class_ok = if_select_second ?
                             e_pair_class_ok : d_pair_class_ok;

    wire [31:0] id_inst;
    wire [31:0] id_raw_rD1, id_raw_rD2, id_imm_ext;
    wire [ 2:0] id_ext_op;
    wire id_is_cpucfg;
    wire id_is_csr;
    wire id_is_cacop;
    ID1_ID2 u_ID1_ID2 (
        .cpu_clk(cpu_clk), .cpu_rstn(cpu_rstn),
        .hold(pl_suspend | id2_stall), .flush(pred_error), .valid_in(if_valid),
        .pc_in(cap_pc), .pc_plus4_in(cap_pc_plus4),
        .inst_in(cap_inst), .raw_rD1_in(cap_raw_rD1),
        .raw_rD2_in(cap_raw_rD2), .ext_op_in(cap_ext_op),
        .taken_target_in(cap_taken_target),
        .pred_taken_in(cap_pred_taken), .pred_target_in(cap_pred_target),
        .npc_op_in(cap_npc_op), .rR1_in(cap_rR1),
        .rR1_re_in(cap_rR1_re), .rR2_in(cap_rR2),
        .rR2_re_in(cap_rR2_re), .wR_in(cap_wR),
        .rf_we_in(cap_rf_we), .wd_sel_in(cap_wd_sel),
        .alu_op_in(cap_alu_op), .alua_sel_in(cap_alua_sel),
        .alub_sel_in(cap_alub_sel), .ram_we_in(cap_ram_we),
        .ram_ext_op_in(cap_ram_ext_op),
        .is_br_jmp_in(cap_is_br_jmp), .is_call_in(cap_is_call),
        .is_return_in(cap_is_return),
        .is_cpucfg_in(cap_is_cpucfg), .is_csr_in(cap_is_csr),
        .is_cacop_in(cap_is_cacop),
        .system_issue_class_in(cap_system_issue_class),
        .pair_class_ok_in(cap_pair_class_ok),
        .control_consumer_in(cap_control_consumer),
        .wb_valid(wb_valid), .wb_rf_we(wb_rf_we), .wb_wR(wb_wR),
        .wb_wd(wb_wd), .wb2_valid(wb2_valid),
        .wb2_rf_we(wb2_rf_we), .wb2_wR(wb2_wR), .wb2_wd(wb2_wd),
        .valid_out(id_waiting), .pc_out(id_pc),
        .pc_plus4_out(id_pc_plus4), .inst_out(id_inst),
        .raw_rD1_out(id_raw_rD1), .raw_rD2_out(id_raw_rD2),
        .ext_op_out(id_ext_op), .taken_target_out(id_target_ext),
        .pred_taken_out(id_pred_taken), .pred_target_out(id_pred_target),
        .npc_op_out(id_npc_op), .rR1_out(id_rR1), .rR1_re_out(id_rR1_re),
        .rR2_out(id_rR2), .rR2_re_out(id_rR2_re), .wR_out(id_wR),
        .rf_we_out(id_rf_we), .wd_sel_out(id_wd_sel), .alu_op_out(id_alu_op),
        .alua_sel_out(id_alua_sel), .alub_sel_out(id_alub_sel),
        .ram_we_out(id_ram_we), .ram_ext_op_out(id_ram_ext_op),
        .is_br_jmp_out(id_is_br_jmp), .is_call_out(id_is_call),
        .is_return_out(id_is_return),
        .is_cpucfg_out(id_is_cpucfg), .is_csr_out(id_is_csr),
        .is_cacop_out(id_is_cacop),
        .system_issue_class_out(id_is_system),
        .pair_class_ok_out(id_pair_class_ok),
        .control_consumer_out(id_control_consumer)
    );

    // Immediate class is decoded in ID1 and registered with the instruction;
    // expand only those registered values in ID2.  This keeps the former
    // IBUF->opcode-decode->EXT->32-bit ID1 payload path from crossing one
    // boundary, without adding a stage or changing any acceptance cycle.
    EXT u_ID2_EXT (
        .ext_op(id_ext_op),
        .din(id_inst[25:0]),
        .ext(id_imm_ext)
    );

    // ID2: dependency classification and independent-branch resolution only.
    // The new OF stage performs the final multi-stage forwarding selection.
    assign id_valid = id_waiting && !pl_suspend && !id2_stall;
    // Compute B and C WB-match metadata in parallel with their two ID1
    // decoders.  The late pair decision is then only a one-bit 2:1 select;
    // it no longer precedes source decode, read-enable decode and equality.
    wire d0_next_wb_r1 = next_wb_valid && next_wb_rf_we && d_rR1_re &&
        (d_rR1 != 5'd0) && (d_rR1 == next_wb_wR);
    wire d0_next_wb_r2 = next_wb_valid && next_wb_rf_we && d_rR2_re &&
        (d_rR2 != 5'd0) && (d_rR2 == next_wb_wR);
    wire d1_next_wb_r1 = next_wb_valid && next_wb_rf_we && e_rR1_re &&
        (e_rR1 != 5'd0) && (e_rR1 == next_wb_wR);
    wire d1_next_wb_r2 = next_wb_valid && next_wb_rf_we && e_rR2_re &&
        (e_rR2 != 5'd0) && (e_rR2 == next_wb_wR);
    wire d_next_wb_r1 = if_valid && (if_select_second ?
                                     d1_next_wb_r1 : d0_next_wb_r1);
    wire d_next_wb_r2 = if_valid && (if_select_second ?
                                     d1_next_wb_r2 : d0_next_wb_r2);
`ifndef SYNTHESIS
    wire legacy_d_next_wb_r1 =
        if_valid && next_wb_valid && next_wb_rf_we && cap_rR1_re &&
        (cap_rR1 != 5'd0) && (cap_rR1 == next_wb_wR);
    wire legacy_d_next_wb_r2 =
        if_valid && next_wb_valid && next_wb_rf_we && cap_rR2_re &&
        (cap_rR2 != 5'd0) && (cap_rR2 == next_wb_wR);
`endif
    wire held_next_wb_r1_reference =
        id_waiting && next_wb_valid && next_wb_rf_we && id_rR1_re &&
        (id_rR1 != 5'd0) && (id_rR1 == next_wb_wR);
    wire held_next_wb_r2_reference =
        id_waiting && next_wb_valid && next_wb_rf_we && id_rR2_re &&
        (id_rR2 != 5'd0) && (id_rR2 == next_wb_wR);
    // A stalled ID2 cannot accept an IBUF refill, so d_next_wb_r* is zero
    // whenever id2_stall is one.  Absorb that reachable-state invariant into
    // the next equation instead of selecting H/D through a stall-controlled
    // mux after both match cones:
    //   stall ? H : D  ==  D | (stall & H), when stall -> !D.
    // The resident writer tag already registered the same M2 match.  Using
    // that bit keeps the late OF-ready chain on one local guard before the
    // flop instead of repeating source decode and a five-bit equality.
    wire next_id_wb_r1 = d_next_wb_r1 |
                         (id2_stall && resident_m2_match_r1);
    wire next_id_wb_r2 = d_next_wb_r2 |
                         (id2_stall && resident_m2_match_r2);
    // Keep independent low-fanout copies for the ID2 branch decision.  The
    // general operand copies drive the 32-bit OF payload, whereas these two
    // bits drive only the three local branch comparisons and the JIRL target.
    // Preventing equivalent-register merging is intentional: the previous
    // shared bits had fanout above 100 and dominated the routed redirect path.
    (* DONT_TOUCH = "true", KEEP = "true" *) reg id_br_wb_r1_r;
    (* DONT_TOUCH = "true", KEEP = "true" *) reg id_br_wb_r2_r;
    (* DONT_TOUCH = "true", KEEP = "true" *) reg id_data_wb_r1_r;
    (* DONT_TOUCH = "true", KEEP = "true" *) reg id_data_wb_r2_r;

    // Register only dependency metadata.  On an ID2-only hold, the old M2
    // producer still advances to WB, so reclassify the resident payload.  A
    // global pipeline hold retains the existing alignment.  WB data itself is
    // selected only after this boundary.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            id_br_wb_r1_r <= 1'b0;
            id_br_wb_r2_r <= 1'b0;
            id_data_wb_r1_r <= 1'b0;
            id_data_wb_r2_r <= 1'b0;
        end else if (!pl_suspend) begin
            id_br_wb_r1_r <= next_id_wb_r1;
            id_br_wb_r2_r <= next_id_wb_r2;
            id_data_wb_r1_r <= next_id_wb_r1;
            id_data_wb_r2_r <= next_id_wb_r2;
        end
    end

    // Keep branch/JIRL resolution on a deliberately small, local operand
    // network.  Older EX/M1/M2 values are covered by the branch dependency
    // interlock; only the registered ID2 snapshot and the same-cycle WB value
    // may enter the branch comparator/target adder.
    wire id_br_wb_r1 = id_br_wb_r1_r;
    wire id_br_wb_r2 = id_br_wb_r2_r;
    wire [31:0] id_system_rD1 = id_data_wb_r1_r ? wb_wd : id_raw_rD1;
    wire [31:0] id_system_rD2 = id_data_wb_r2_r ? wb_wd : id_raw_rD2;

    // This boundary carries only the saved RF value plus same-cycle WB.  It
    // cannot be driven by EX/M1/M2 or the MUL result queue.
    assign id_real_rD1 = id_system_rD1;
    assign id_real_rD2 = id_system_rD2;
    assign id_mul_rD1  = id_system_rD1;
    assign id_mul_rD2  = id_system_rD2;
    reg [31:0] cpucfg_data;
    always @(*) begin
        case (id_system_rD1)
            32'h10: cpucfg_data = 32'h0000_0005;
            32'h11: cpucfg_data = 32'h0505_0000;
            32'h12: cpucfg_data = 32'h0505_0000;
            default: cpucfg_data = 32'b0;
        endcase
    end

    wire [31:0] csr_rdata;
    wire [ 4:0] csr_rj = id_inst[9:5];
    CSRFile u_CSRFile (
        .cpu_clk(cpu_clk), .cpu_rstn(cpu_rstn),
        .csr_we(wb_csr_we), .csr_rnum(id_inst[23:10]),
        .csr_wnum(wb_csr_num),
        .csr_wmask(wb_csr_wmask), .csr_wdata(wb_csr_wdata),
        .csr_rdata(csr_rdata),
        .csr_crmd(csr_crmd), .csr_dmw0(csr_dmw0), .csr_dmw1(csr_dmw1)
    );
    assign id_ext = id_is_cpucfg ? cpucfg_data :
                    id_is_csr ? csr_rdata : id_imm_ext;
    assign id_csr_we = id_valid && id_is_csr && (csr_rj != 5'd0);
    assign id_csr_rj = csr_rj;
    assign id_csr_num = id_inst[23:10];
    assign id_csr_wmask = (csr_rj == 5'd1) ? 32'hffff_ffff : id_system_rD1;
    assign id_csr_wdata = id_system_rD2;

    // Build the three possible operand comparisons in parallel, then select
    // their one-bit results with the registered WB-match metadata.  This keeps
    // the match bit out of the 32-bit comparator carry chain.  If both sources
    // match WB they name the same architectural register, so equality is true
    // and both less-than results are false.
    wire id_raw_eq = (id_raw_rD1 == id_raw_rD2);
    wire id_wb_r1_eq = (wb_wd == id_raw_rD2);
    wire id_wb_r2_eq = (id_raw_rD1 == wb_wd);
    wire id_raw_slt = ($signed(id_raw_rD1) < $signed(id_raw_rD2));
    wire id_wb_r1_slt = ($signed(wb_wd) < $signed(id_raw_rD2));
    wire id_wb_r2_slt = ($signed(id_raw_rD1) < $signed(wb_wd));
    wire id_raw_sltu = (id_raw_rD1 < id_raw_rD2);
    wire id_wb_r1_sltu = (wb_wd < id_raw_rD2);
    wire id_wb_r2_sltu = (id_raw_rD1 < wb_wd);
    reg id_r_eq;
    reg id_r_slt;
    reg id_r_sltu;
    always @(*) begin
        case ({id_br_wb_r1, id_br_wb_r2})
            2'b00: begin
                id_r_eq   = id_raw_eq;
                id_r_slt  = id_raw_slt;
                id_r_sltu = id_raw_sltu;
            end
            2'b10: begin
                id_r_eq   = id_wb_r1_eq;
                id_r_slt  = id_wb_r1_slt;
                id_r_sltu = id_wb_r1_sltu;
            end
            2'b01: begin
                id_r_eq   = id_wb_r2_eq;
                id_r_slt  = id_wb_r2_slt;
                id_r_sltu = id_wb_r2_sltu;
            end
            default: begin
                id_r_eq   = 1'b1;
                id_r_slt  = 1'b0;
                id_r_sltu = 1'b0;
            end
        endcase
    end
    wire id_br_taken_raw =
        (id_alu_op == `ALU_SUB)  ? id_r_eq :
        (id_alu_op == `ALU_BNE)  ? !id_r_eq :
        (id_alu_op == `ALU_SLT)  ? id_r_slt :
        (id_alu_op == `ALU_BGE)  ? !id_r_slt :
        (id_alu_op == `ALU_SLTU) ? id_r_sltu :
        (id_alu_op == `ALU_BGEU) ? !id_r_sltu :
        (id_alu_op == `ALU_B)    ? 1'b1 :
        (id_alu_op == `ALU_JIRL) ? 1'b1 : 1'b0;
    // Keep the branch outcome independent of the OF-ready/ID-accept chain.
    // The accepted form remains available for legacy consumers, while the
    // top level can combine this raw result with its local accept event only
    // once at the redirect register boundary.
    assign id_br_jmp_raw = id_is_br_jmp && id_br_taken_raw;
    assign id_br_jmp_f = id_valid && id_br_jmp_raw;
    // JIRL follows the same post-operation selection rule: the WB match bit
    // selects between two completed sums instead of preceding a carry chain.
    // JIRL always uses the signed, word-scaled si16 form.  Decode that form
    // directly from the registered instruction so the generic ext_op mux is
    // not placed before either target carry chain.
    wire [31:0] id_jirl_imm =
        {{14{id_inst[25]}}, id_inst[25:10], 2'b00};
    wire [31:0] id_jirl_raw_target = id_raw_rD1 + id_jirl_imm;
    wire [31:0] id_jirl_wb_target  = wb_wd + id_jirl_imm;
    wire [31:0] id_jirl_target = id_br_wb_r1 ?
                                 id_jirl_wb_target : id_jirl_raw_target;
    assign id_taken_target = (id_npc_op == `NPC_JMPREG) ?
                             id_jirl_target : id_target_ext;

    assign id_is_ld_st = id_valid && (id_wd_sel == `WD_RAM);
    assign id_is_mul_div = id_valid &&
        ((id_alu_op == `ALU_MUL) | (id_alu_op == `ALU_MULH) |
         (id_alu_op == `ALU_MULHU));
    assign cacop_valid = id_valid && id_is_cacop;
    assign cacop_code  = id_inst[4:0];
    assign cacop_addr  = id_system_rD1 + id_imm_ext;

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ((d_next_wb_r1 !== legacy_d_next_wb_r1) ||
                         (d_next_wb_r2 !== legacy_d_next_wb_r2)))
            $fatal(1, "parallel B/C WB-match differs from selected reference");
        if (cpu_rstn && id2_stall &&
            (d_next_wb_r1 || d_next_wb_r2))
            $fatal(1, "stalled ID2 unexpectedly accepted a WB-match refill");
        if (cpu_rstn && id_waiting &&
            ((resident_m2_match_r1 !== held_next_wb_r1_reference) ||
             (resident_m2_match_r2 !== held_next_wb_r2_reference)))
            $fatal(1, "registered writer-tag M2 match differs from live reference");
        if (cpu_rstn &&
            ((next_id_wb_r1 !==
              (id2_stall ? held_next_wb_r1_reference : d_next_wb_r1)) ||
             (next_id_wb_r2 !==
              (id2_stall ? held_next_wb_r2_reference : d_next_wb_r2))))
            $fatal(1, "absorbed WB-match next state differs from legacy mux");
        if (cpu_rstn && id_waiting &&
            (id_is_cpucfg !== (id_inst[31:10] == 22'h00001b)))
            $fatal(1, "registered CPUCFG class differs from ID2 instruction");
        if (cpu_rstn && id_waiting &&
            (id_is_csr !== (id_inst[31:24] == 8'h04)))
            $fatal(1, "registered CSR class differs from ID2 instruction");
        if (cpu_rstn && id_waiting &&
            (id_is_cacop !== (id_inst[31:22] == 10'h018)))
            $fatal(1, "registered CACOP class differs from ID2 instruction");
        if (cpu_rstn && id_waiting &&
            (id_is_system !==
             (id_is_cpucfg | id_is_csr | id_is_cacop)))
            $fatal(1, "registered system issue class mismatch");
        if (cpu_rstn && id_waiting &&
            (id_control_consumer !== (id_is_br_jmp | id_is_system)))
            $fatal(1, "registered control-consumer class mismatch");
        if (cpu_rstn && id_waiting &&
            (id_pair_class_ok !==
             (!(id_is_br_jmp | id_is_system) && !id_pred_taken)))
            $fatal(1, "registered pair class mismatch");
    end
`endif

endmodule
