`timescale 1ns / 1ps

`include "defines.vh"

// Restricted decoder for the younger lane of an in-order dual-issue pair.
//
// Slot 1 is deliberately side-effect free: it accepts only ordinary integer
// register/register operations, integer immediate operations, LU12I.W and
// PCADDU12I.  Memory, branch/JIRL, MUL/DIV, CSR/CPUCFG and CACOP instructions
// are rejected and must be issued alone through slot 0.
//
// The decoder produces a final 32-bit immediate.  This keeps the integration
// boundary narrow: pairing/hazard logic needs only the source/destination
// metadata, while a slot-1 ALU can consume alua_sel/alub_sel/alu_op/imm without
// instantiating the full CU/EXT/system-control path.
module slot1_narrow_decode (
    input  wire [31:0] inst,

    output wire        eligible,
    output wire [ 4:0] rR1,
    output wire        rR1_re,
    output wire [ 4:0] rR2,
    output wire        rR2_re,
    output wire [ 4:0] wR,
    output wire        rf_we,
    output wire        writes_gpr,
    output wire        alua_sel,
    output wire        alub_sel,
    output wire [ 4:0] alu_op,
    output wire [31:0] imm
);

    // Register/register integer ALU operations.  MUL/DIV are intentionally
    // absent even though they share the same instruction format.
    wire add_w  = (inst[31:15] == 17'h00020);
    wire sub_w  = (inst[31:15] == 17'h00022);
    wire and_w  = (inst[31:15] == 17'h00029);
    wire or_w   = (inst[31:15] == 17'h0002a);
    wire xor_w  = (inst[31:15] == 17'h0002b);
    wire nor_w  = (inst[31:15] == 17'h00028);
    wire sll_w  = (inst[31:15] == 17'h0002e);
    wire srl_w  = (inst[31:15] == 17'h0002f);
    wire sra_w  = (inst[31:15] == 17'h00030);
    wire slt_w  = (inst[31:15] == 17'h00024);
    wire sltu_w = (inst[31:15] == 17'h00025);

    wire type_3r = add_w | sub_w | and_w | or_w | xor_w | nor_w |
                   sll_w | srl_w | sra_w | slt_w | sltu_w;

    // Shift-immediate operations.
    wire slli_w = (inst[31:15] == 17'h00081);
    wire srli_w = (inst[31:15] == 17'h00089);
    wire srai_w = (inst[31:15] == 17'h00091);
    wire type_2ri5 = slli_w | srli_w | srai_w;

    // 12-bit integer-immediate operations.
    wire addi_w  = (inst[31:22] == 10'h00a);
    wire andi_w  = (inst[31:22] == 10'h00d);
    wire ori_w   = (inst[31:22] == 10'h00e);
    wire xori_w  = (inst[31:22] == 10'h00f);
    wire slti_w  = (inst[31:22] == 10'h008);
    wire sltui_w = (inst[31:22] == 10'h009);
    wire type_2ri12 = addi_w | andi_w | ori_w | xori_w | slti_w |
                      sltui_w;

    // Immediate-only / PC-relative constant generation.  PCADDU12I remains
    // safe in slot 1 because it has no GPR source and no control-flow effect;
    // the slot-1 execute lane supplies that instruction's own PC on ALUA_PC.
    wire lu12i_w   = (inst[31:25] == 7'h0a);
    wire pcaddu12i = (inst[31:25] == 7'h0e);

    assign eligible = type_3r | type_2ri5 | type_2ri12 |
                      lu12i_w | pcaddu12i;

    assign rR1 = inst[9:5];
    assign rR2 = inst[14:10];
    assign rR1_re = eligible && !lu12i_w && !pcaddu12i;
    assign rR2_re = type_3r;

    assign wR = inst[4:0];
    assign rf_we = eligible;
    // Pair dependency logic should use writes_gpr, not rf_we, so a nominal
    // write to x0 creates neither a false RAW/WAW dependency nor a write event.
    assign writes_gpr = eligible && (wR != 5'd0);

    assign alua_sel = pcaddu12i ? `ALUA_PC : `ALUA_R1;
    assign alub_sel = type_3r ? `ALUB_R2 : `ALUB_EXT;

    assign alu_op =
        add_w | addi_w | pcaddu12i ? `ALU_ADD :
        sub_w                       ? `ALU_SUB :
        and_w | andi_w             ? `ALU_AND :
        or_w | ori_w               ? `ALU_OR :
        xor_w | xori_w             ? `ALU_XOR :
        nor_w                       ? `ALU_NOR :
        sll_w | slli_w             ? `ALU_SLL :
        srl_w | srli_w             ? `ALU_SRL :
        sra_w | srai_w             ? `ALU_SRA :
        slt_w | slti_w             ? `ALU_SLT :
        sltu_w | sltui_w           ? `ALU_SLTU :
        lu12i_w                     ? `ALU_LU12I : 5'b0;

    wire [31:0] imm_5 = {27'b0, inst[14:10]};
    wire [31:0] imm_12_signed = {{20{inst[21]}}, inst[21:10]};
    wire [31:0] imm_12_unsigned = {20'b0, inst[21:10]};
    wire [31:0] imm_20 = {inst[24:5], 12'b0};

    assign imm = type_2ri5 ? imm_5 :
                 (addi_w | slti_w | sltui_w) ? imm_12_signed :
                 (andi_w | ori_w | xori_w) ? imm_12_unsigned :
                 (lu12i_w | pcaddu12i) ? imm_20 : 32'b0;

endmodule
