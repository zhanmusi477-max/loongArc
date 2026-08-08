`timescale 1ns / 1ps

`include "mycpu_inst.vh"
`include "defines.vh"

module CU (
    input  wire [31:15] inst_31_15,     //opcode_func
    output wire [ 1: 0] npc_op    ,     //next_op
    output wire         is_br_jmp ,     //jump_or_not
    output wire [ 2: 0] ext_op    ,     //extends_option
    output wire         r2_sel    ,     //select_rd_or_rk_as_2nd_source
    output wire         rR1_re    ,     //enable_1st_reg
    output wire         rR2_re    ,     //enable_2nd_reg
    output wire         alua_sel  ,     //AluA_select_rd1_or_pc
    output wire         alub_sel  ,     //AluB_select_rd2_or_ext
    output wire [ 4: 0] alu_op    ,
    output wire [ 2: 0] ram_ext_op,     //Type_load_extend
    output wire [ 3: 0] ram_we    ,     //ram_enable
    output wire         rf_we     ,     //regfile_enable
    output wire         wr_sel    ,     //select_wb_reg
    output wire [ 1: 0] wd_sel          //select_wb_source
);

    // -------------------------------------------------------------------------
    // ָ������
    // -------------------------------------------------------------------------
    // 3R��ָ��
    wire ADD_W     = (inst_31_15[31:15] == 17'h00020);
    wire SUB_W     = (inst_31_15[31:15] == 17'h00022);
    wire AND_W     = (inst_31_15[31:15] == 17'h00029);
    wire OR_W      = (inst_31_15[31:15] == 17'h0002A);
    wire XOR_W     = (inst_31_15[31:15] == 17'h0002B);
    wire NOR_W     = (inst_31_15[31:15] == 17'h00028);
    wire SLL_W     = (inst_31_15[31:15] == 17'h0002E);
    wire SRL_W     = (inst_31_15[31:15] == 17'h0002F);
    wire SRA_W     = (inst_31_15[31:15] == 17'h00030);
    wire SLT_W     = (inst_31_15[31:15] == 17'h00024);
    wire SLTU_W    = (inst_31_15[31:15] == 17'h00025);
    wire MUL_W     = (inst_31_15[31:15] == 17'h00038);
    wire MULH_W    = (inst_31_15[31:15] == 17'h00039);
    wire MULH_WU   = (inst_31_15[31:15] == 17'h0003A);
    wire DIV_W     = (inst_31_15[31:15] == 17'h00040);
    wire DIVU_W    = (inst_31_15[31:15] == 17'h00042);
    wire MOD_W     = (inst_31_15[31:15] == 17'h00041);
    wire MODU_W    = (inst_31_15[31:15] == 17'h00043);
    
    // 2RI5��ָ��
    wire SLLI_W    = (inst_31_15[31:15] == 17'h00081);
    wire SRLI_W    = (inst_31_15[31:15] == 17'h00089);
    wire SRAI_W    = (inst_31_15[31:15] == 17'h00091);
    
    // 2RI12��ָ��
    wire ADDI_W    = (inst_31_15[31:22] == 10'h00A);
    wire ANDI_W    = (inst_31_15[31:22] == 10'h00D);
    wire ORI_W     = (inst_31_15[31:22] == 10'h00E);
    wire XORI_W    = (inst_31_15[31:22] == 10'h00F);
    wire SLTI_W    = (inst_31_15[31:22] == 10'h008);
    wire SLTUI_W   = (inst_31_15[31:22] == 10'h009);
    
    // Loadָ��
    wire LD_B      = (inst_31_15[31:22] == 10'h0A0);
    wire LD_BU     = (inst_31_15[31:22] == 10'h0A8);
    wire LD_H      = (inst_31_15[31:22] == 10'h0A1);
    wire LD_HU     = (inst_31_15[31:22] == 10'h0A9);
    wire LD_W      = (inst_31_15[31:22] == 10'h0A2);
    
    // Storeָ��
    wire ST_B      = (inst_31_15[31:22] == 10'h0A4);
    wire ST_H      = (inst_31_15[31:22] == 10'h0A5);
    wire ST_W      = (inst_31_15[31:22] == 10'h0A6);
    
    // 1RI20��ָ��
    wire LU12I_W   = (inst_31_15[31:25] == 7'h0A);
    wire PCADDU12I = (inst_31_15[31:25] == 7'h0E);
    
    // 2RI16��ָ��
    wire BEQ       = (inst_31_15[31:26] == 6'h16);
    wire BNE       = (inst_31_15[31:26] == 6'h17);
    wire BLT       = (inst_31_15[31:26] == 6'h18);
    wire BLTU      = (inst_31_15[31:26] == 6'h1A);
    wire BGE       = (inst_31_15[31:26] == 6'h19);
    wire BGEU      = (inst_31_15[31:26] == 6'h1B);
    wire JIRL      = (inst_31_15[31:26] == 6'h13);
    
    // I26��ָ��
    wire BL        = (inst_31_15[31:26] == 6'h15);
    wire B         = (inst_31_15[31:26] == 6'h14);
    // -------------------------------------------------------------------------
    // ָ�����
    // -------------------------------------------------------------------------
    //�ض�ָ���ж� ���ж��ǲ���Ҫ��ĳ������
    
    //3R����
    wire TYPE_3R    = ADD_W | SUB_W | AND_W | OR_W | XOR_W | NOR_W | SLL_W | SRL_W | SRA_W | SLT_W | SLTU_W | MUL_W | MULH_W | MULH_WU | DIV_W | DIVU_W | MOD_W | MODU_W;
    //2RI5����
    wire TYPE_2RI5  = SLLI_W | SRLI_W | SRAI_W;
    //2RI12��չ��ָ��
    wire TYPE_2RI12 = ADDI_W | ANDI_W | ORI_W | XORI_W | SLTI_W | SLTUI_W;
    //��Ҫ��ȡ�ڴ�
    wire LOAD = LD_B | LD_BU | LD_H | LD_HU | LD_W;
    //��Ҫ���ڴ�д
    wire STORE = ST_B | ST_H | ST_W;
    //����ִ����һ��ָ��
    wire NPC_OP_PC4  = TYPE_3R | TYPE_2RI5 | PCADDU12I | LU12I_W | LOAD | STORE | TYPE_2RI12;
    wire TYPE_BRANCH = BEQ | BNE | BLT | BLTU | BGE | BGEU;
    wire TYPE_BBL =  B | BL;
    wire TYPE_JMPREG = JIRL;
    
    //��������չ��ʽ
    wire EXT_OP_5    = TYPE_2RI5;
    wire EXT_OP_12_S = ADDI_W | SLTI_W | SLTUI_W | LOAD | STORE;   // ������չ
    //����ķ�����չָ���Ƕ���Ҫ�ҵĵ�ַ���з�����չ ldbu ldhu�е�uָ���Ƕ���ȡ���������ݵ���չ 
    wire EXT_OP_12_Z = ANDI_W | ORI_W | XORI_W;    // ����չ
    wire EXT_OP_16  = BEQ | BNE | BLT | BLTU | BGE | BGEU | JIRL;
    wire EXT_OP_20 = PCADDU12I | LU12I_W;
    wire EXT_OP_26 = B | BL;
    //ALU��ʲô����
    wire ALU_OP_ADD   = ADD_W  | PCADDU12I | LOAD | STORE | ADDI_W;
    wire ALU_OP_SUB   = SUB_W  | BEQ; 
    wire ALU_OP_AND   = AND_W  | ANDI_W;
    wire ALU_OP_OR    = OR_W   | ORI_W;
    wire ALU_OP_XOR   = XOR_W  | XORI_W;
    wire ALU_OP_NOR = NOR_W;
    wire ALU_OP_SLL = SLL_W | SLLI_W;
    wire ALU_OP_SRL = SRL_W | SRLI_W;
    wire ALU_OP_SRA = SRA_W | SRAI_W;
    wire ALU_OP_SLT   = SLT_W  | BLT    | SLTI_W;    
    wire ALU_OP_SLTU  = SLTU_W | BLTU   | SLTUI_W;
    wire ALU_OP_LU12I = LU12I_W;
    //ʣ���֧��ת��������
    wire ALU_BNE   = BNE;
    wire ALU_BGE   = BGE;
    wire ALU_BGEU  = BGEU;  
    wire ALU_JIRL = JIRL;   // �� JIRL ʹ�üӷ�
    wire ALU_UNCOND = B | BL;      // ��������ת
    
    wire ALU_MUL    = MUL_W;
    wire ALU_MULH   = MULH_W;
    wire ALU_MULHU  = MULH_WU;
    
    wire ALU_DIV    = DIV_W;
    wire ALU_DIVU   = DIVU_W;
    wire ALU_MOD    = MOD_W;
    wire ALU_MODU   = MODU_W;
    
    wire WD_SEL_ALU = TYPE_3R | TYPE_2RI5 | PCADDU12I | LU12I_W | TYPE_2RI12;
    wire WD_SEL_RAM = LOAD | STORE;
    wire WD_SEL_PC4 = BL | JIRL;

    // -------------------------------------------------------------------------
    // PC����
    // -------------------------------------------------------------------------
    assign npc_op = NPC_OP_PC4  ? `NPC_PC4    :
                    TYPE_BRANCH ? `NPC_BRANCH :
                    TYPE_BBL    ? `NPC_BBL    :
                    TYPE_JMPREG ? `NPC_JMPREG : 2'b00;
    assign is_br_jmp = TYPE_BRANCH | TYPE_BBL | TYPE_JMPREG;

    // -------------------------------------------------------------------------
    // �������ͼĴ���������
    // -------------------------------------------------------------------------
    assign ext_op = ({3{EXT_OP_5}}    & `EXT_5) |
                    ({3{EXT_OP_12_S}} & `EXT_12) |
                    ({3{EXT_OP_12_Z}} & `EXT_12_Z) |
                    {3{EXT_OP_16}} & `EXT_16 | 
                    {3{EXT_OP_20}} & `EXT_20 |
                    {3{EXT_OP_26}} & `EXT_26 ;  

    assign r2_sel = (STORE | TYPE_BRANCH) ? `R2_RD : `R2_RK;

    assign rR1_re = !(PCADDU12I | LU12I_W | TYPE_BBL);

    assign rR2_re = TYPE_3R | STORE | TYPE_BRANCH;

    // -------------------------------------------------------------------------
    // ALU����
    // -------------------------------------------------------------------------
    assign alua_sel = PCADDU12I ? `ALUA_PC : `ALUA_R1;

    assign alub_sel = (PCADDU12I | LOAD | STORE | LU12I_W | JIRL | TYPE_2RI5 | TYPE_2RI12) ? `ALUB_EXT : `ALUB_R2;

    assign alu_op = {5{ALU_OP_ADD}} & `ALU_ADD 
    | {5{ALU_OP_SUB}} & `ALU_SUB 
    | {5{ALU_OP_AND}} & `ALU_AND
    | {5{ALU_OP_OR}} & `ALU_OR
    | {5{ALU_OP_XOR}} & `ALU_XOR
    | {5{ALU_OP_NOR}} & `ALU_NOR
    | {5{ALU_OP_SLL}} & `ALU_SLL
    | {5{ALU_OP_SRL}} & `ALU_SRL
    | {5{ALU_OP_SRA}} & `ALU_SRA
    | {5{ALU_OP_SLT}} & `ALU_SLT
    | {5{ALU_OP_SLTU}} & `ALU_SLTU
    | {5{ALU_OP_LU12I}} & `ALU_LU12I
    | {5{ALU_BNE}}     & `ALU_BNE    
    | {5{ALU_BGE}}     & `ALU_BGE
    | {5{ALU_BGEU}}    & `ALU_BGEU
    | {5{ALU_UNCOND}} & `ALU_B
    | {5{ALU_JIRL}}   & `ALU_JIRL
    | {5{ALU_MUL}}    & `ALU_MUL
    | {5{ALU_MULH}}   & `ALU_MULH
    | {5{ALU_MULHU}}  & `ALU_MULHU
    | {5{ALU_DIV}}    & `ALU_DIV
    | {5{ALU_DIVU}}   & `ALU_DIVU
    | {5{ALU_MOD}}    & `ALU_MOD
    | {5{ALU_MODU}}   & `ALU_MODU;
    // -------------------------------------------------------------------------
    // �ô����
    // -------------------------------------------------------------------------
    assign ram_ext_op =
      {3{LD_B }} & `RAM_EXT_B
    | {3{LD_BU}} & `RAM_EXT_BU
    | {3{LD_H }} & `RAM_EXT_H
    | {3{LD_HU}} & `RAM_EXT_HU
    | {3{LD_W }} & `RAM_EXT_N;

    assign ram_we = 
    {4{ST_B}} & `RAM_WE_B  |
    {4{ST_H}} & `RAM_WE_H  |
    {4{ST_W}} & `RAM_WE_W  |
    {4{1'b0}}  & `RAM_WE_N;

    // -------------------------------------------------------------------------
    // д�ؿ���
    // -------------------------------------------------------------------------
    assign rf_we = (NPC_OP_PC4 | BL | JIRL) & !STORE; //storeд���ڴ� ��д�ؼĴ�����

    assign wr_sel = `WR_RD;

    assign wd_sel = {2{WD_SEL_ALU}} & `WD_ALU |
                    {2{WD_SEL_RAM}} & `WD_RAM |
                    {2{WD_SEL_PC4}} & `WD_PC4;

endmodule

