`timescale 1ns / 1ps

`include "defines.vh"

// Narrow, side-effect-free younger lane for the first restricted dual-issue
// implementation.  Slot 0 keeps the complete existing pipeline.  A slot-1
// payload is captured only together with a slot-0 ID2->OF transfer and then
// advances on the same stage events as that older instruction.
//
// No forwarding is performed in this module.  The top-level issue scoreboard
// prevents either lane from reading an outstanding slot-1 destination and
// permits slot 1 only when all of its input operands are already architectural.
module restricted_slot1_lane (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,

    // Younger payload accepted beside the slot-0 ID2 payload.
    input  wire        issue_valid,
    input  wire [31:0] issue_pc,
    input  wire [31:0] issue_rD1,
    input  wire [31:0] issue_rD2,
    input  wire [31:0] issue_imm,
    input  wire [ 4:0] issue_alu_op,
    input  wire        issue_alua_sel,
    input  wire        issue_alub_sel,
    input  wire        issue_rf_we,
    input  wire [ 4:0] issue_wR,

    // Exact slot-0 stage movement controls.
    input  wire        slot0_of_fire,
    input  wire        late_redirect_kill,
    input  wire        pl_suspend,
    input  wire        early_load_hold,

    // Verification-visible stage ownership used by the issue scoreboard.
    output wire        s1_of_valid,
    output wire        s1_of_rf_we,
    output wire [ 4:0] s1_of_wR,
    output wire        s1_ex_valid,
    output wire        s1_ex_rf_we,
    output wire [ 4:0] s1_ex_wR,
    output wire        s1_m1_valid,
    output wire        s1_m1_rf_we,
    output wire [ 4:0] s1_m1_wR,
    output wire [31:0] s1_m1_wd,
    output wire        s1_m2_valid,
    output wire        s1_m2_rf_we,
    output wire [ 4:0] s1_m2_wR,
    output wire [31:0] s1_m2_wd,

    // Second architectural WB/commit port.
    output wire        s1_wb_valid,
    output wire        s1_wb_rf_we,
    output wire [ 4:0] s1_wb_wR,
    output wire [31:0] s1_wb_wd,
    output wire [31:0] s1_wb_pc
);

    // ---------------------------------------------------------------------
    // OF: pair payload and narrow ALU
    // ---------------------------------------------------------------------
    reg        of_valid_r;
    reg [31:0] of_pc_r;
    reg [31:0] of_rD1_r;
    reg [31:0] of_rD2_r;
    reg [31:0] of_imm_r;
    reg [ 4:0] of_alu_op_r;
    reg        of_alua_sel_r;
    reg        of_alub_sel_r;
    reg        of_rf_we_r;
    reg [ 4:0] of_wR_r;

    // A registered late redirect kills only the younger payload still in OF.
    // Older EX/M1/M2/WB slot-1 instructions must continue to retirement.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn || late_redirect_kill)
            of_valid_r <= 1'b0;
        else if (issue_valid)
            of_valid_r <= 1'b1;
        else if (slot0_of_fire)
            of_valid_r <= 1'b0;
    end

    // The payload bank is observable only while of_valid_r is set.  A pair can
    // be accepted only when this lane is empty or when its resident payload is
    // leaving with slot 0.  Use that local availability as the payload enable
    // and sample the issue bus even on an empty/no-issue cycle; the value is a
    // don't-care until of_valid_r is asserted.  This removes the complete
    // pending-writer/pair decision from roughly one hundred payload CE pins.
    wire of_payload_open = !pl_suspend &&
                           (!of_valid_r || slot0_of_fire);
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            of_pc_r       <= 32'b0;
            of_rD1_r      <= 32'b0;
            of_rD2_r      <= 32'b0;
            of_imm_r      <= 32'b0;
            of_alu_op_r   <= 5'b0;
            of_alua_sel_r <= 1'b0;
            of_alub_sel_r <= 1'b0;
            of_rf_we_r    <= 1'b0;
            of_wR_r       <= 5'b0;
        end else if (of_payload_open) begin
            of_pc_r       <= issue_pc;
            of_rD1_r      <= issue_rD1;
            of_rD2_r      <= issue_rD2;
            of_imm_r      <= issue_imm;
            of_alu_op_r   <= issue_alu_op;
            of_alua_sel_r <= issue_alua_sel;
            of_alub_sel_r <= issue_alub_sel;
            of_rf_we_r    <= issue_rf_we;
            of_wR_r       <= issue_wR;
        end
    end

    wire [31:0] of_alu_A = of_alua_sel_r ? of_rD1_r : of_pc_r;
    wire [31:0] of_alu_B = of_alub_sel_r ? of_rD2_r : of_imm_r;
    reg  [31:0] of_result;
    always @(*) begin
        case (of_alu_op_r)
            `ALU_ADD  : of_result = of_alu_A + of_alu_B;
            `ALU_SUB  : of_result = of_alu_A - of_alu_B;
            `ALU_AND  : of_result = of_alu_A & of_alu_B;
            `ALU_OR   : of_result = of_alu_A | of_alu_B;
            `ALU_XOR  : of_result = of_alu_A ^ of_alu_B;
            `ALU_NOR  : of_result = ~(of_alu_A | of_alu_B);
            `ALU_SLL  : of_result = of_alu_A << of_alu_B[4:0];
            `ALU_SRL  : of_result = of_alu_A >> of_alu_B[4:0];
            `ALU_SRA  : of_result = $signed(of_alu_A) >>> of_alu_B[4:0];
            `ALU_SLT  : of_result =
                ($signed(of_alu_A) < $signed(of_alu_B)) ? 32'd1 : 32'd0;
            `ALU_SLTU : of_result =
                (of_alu_A < of_alu_B) ? 32'd1 : 32'd0;
            `ALU_LU12I: of_result = of_alu_B;
            default   : of_result = 32'b0;
        endcase
    end

    assign s1_of_valid = of_valid_r;
    assign s1_of_rf_we = of_rf_we_r;
    assign s1_of_wR    = of_wR_r;

    // ---------------------------------------------------------------------
    // EX: mirrors ID_EX, including the special early-Load hold.
    // ---------------------------------------------------------------------
    reg        ex_valid_r;
    reg        ex_rf_we_r;
    reg [ 4:0] ex_wR_r;
    reg [31:0] ex_wd_r;
    reg [31:0] ex_pc_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            ex_valid_r <= 1'b0;
            ex_rf_we_r <= 1'b0;
            ex_wR_r    <= 5'b0;
            ex_wd_r    <= 32'b0;
            ex_pc_r    <= 32'b0;
        end else if (!(pl_suspend || early_load_hold)) begin
            ex_valid_r <= slot0_of_fire && of_valid_r;
            ex_rf_we_r <= slot0_of_fire && of_valid_r && of_rf_we_r;
            ex_wR_r    <= of_wR_r;
            ex_wd_r    <= of_result;
            ex_pc_r    <= of_pc_r;
        end
    end

    assign s1_ex_valid = ex_valid_r;
    assign s1_ex_rf_we = ex_rf_we_r;
    assign s1_ex_wR    = ex_wR_r;

    // ---------------------------------------------------------------------
    // M1: early_load_hold drains the old M1 payload while retaining EX.
    // ---------------------------------------------------------------------
    reg        m1_valid_r;
    reg        m1_rf_we_r;
    reg [ 4:0] m1_wR_r;
    reg [31:0] m1_wd_r;
    reg [31:0] m1_pc_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            m1_valid_r <= 1'b0;
            m1_rf_we_r <= 1'b0;
            m1_wR_r    <= 5'b0;
            m1_wd_r    <= 32'b0;
            m1_pc_r    <= 32'b0;
        end else if (!pl_suspend) begin
            m1_valid_r <= ex_valid_r && !early_load_hold;
            m1_rf_we_r <= ex_valid_r && !early_load_hold && ex_rf_we_r;
            m1_wR_r    <= ex_wR_r;
            m1_wd_r    <= ex_wd_r;
            m1_pc_r    <= ex_pc_r;
        end
    end

    assign s1_m1_valid = m1_valid_r;
    assign s1_m1_rf_we = m1_rf_we_r;
    assign s1_m1_wR    = m1_wR_r;
    assign s1_m1_wd    = m1_wd_r;

    // ---------------------------------------------------------------------
    // M2: mirrors the ordinary EX2/MEM boundary.
    // ---------------------------------------------------------------------
    reg        m2_valid_r;
    reg        m2_rf_we_r;
    reg [ 4:0] m2_wR_r;
    reg [31:0] m2_wd_r;
    reg [31:0] m2_pc_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            m2_valid_r <= 1'b0;
            m2_rf_we_r <= 1'b0;
            m2_wR_r    <= 5'b0;
            m2_wd_r    <= 32'b0;
            m2_pc_r    <= 32'b0;
        end else if (!pl_suspend) begin
            m2_valid_r <= m1_valid_r;
            m2_rf_we_r <= m1_valid_r && m1_rf_we_r;
            m2_wR_r    <= m1_wR_r;
            m2_wd_r    <= m1_wd_r;
            m2_pc_r    <= m1_pc_r;
        end
    end

    assign s1_m2_valid = m2_valid_r;
    assign s1_m2_rf_we = m2_rf_we_r;
    assign s1_m2_wR    = m2_wR_r;
    assign s1_m2_wd    = m2_wd_r;

    // ---------------------------------------------------------------------
    // WB: valid is a one-cycle commit pulse.  During a global hold M2 keeps
    // its payload while WB is cleared, matching MEM_WB and preventing a
    // duplicate second-port write/commit.
    // ---------------------------------------------------------------------
    reg        wb_valid_r;
    reg        wb_rf_we_r;
    reg [ 4:0] wb_wR_r;
    reg [31:0] wb_wd_r;
    reg [31:0] wb_pc_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            wb_valid_r <= 1'b0;
            wb_rf_we_r <= 1'b0;
            wb_wR_r    <= 5'b0;
            wb_wd_r    <= 32'b0;
            wb_pc_r    <= 32'b0;
        end else if (pl_suspend) begin
            wb_valid_r <= 1'b0;
            wb_rf_we_r <= 1'b0;
        end else begin
            wb_valid_r <= m2_valid_r;
            wb_rf_we_r <= m2_valid_r && m2_rf_we_r;
            wb_wR_r    <= m2_wR_r;
            wb_wd_r    <= m2_wd_r;
            wb_pc_r    <= m2_pc_r;
        end
    end

    assign s1_wb_valid = wb_valid_r;
    assign s1_wb_rf_we = wb_rf_we_r;
    assign s1_wb_wR    = wb_wR_r;
    assign s1_wb_wd    = wb_wd_r;
    assign s1_wb_pc    = wb_pc_r;

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && issue_valid && !of_payload_open)
            $fatal(1, "restricted slot1 accepted payload while resident OF was held");
        if (cpu_rstn && issue_valid && !issue_rf_we)
            $fatal(1, "restricted slot1 accepted a non-GPR instruction");
        if (cpu_rstn && slot0_of_fire && of_valid_r &&
            ((of_alu_op_r == 5'b0) || !of_rf_we_r))
            $fatal(1, "restricted slot1 payload is outside the narrow ALU set");
    end
`endif

endmodule
