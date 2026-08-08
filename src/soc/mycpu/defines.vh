`ifndef DEFINES_VH
`define DEFINES_VH

`define ENABLE_ICACHE
`define ENABLE_DCACHE
`define ENABLE_BPU

`define CACHE_BLK_LEN   8
`define CACHE_BLK_SIZE  (`CACHE_BLK_LEN*32)
`define CACHE_BLK_NUM   32

`define PC_INIT_VAL 32'h1c000000

`define NPC_PC4     2'b00   // 顺序执行
`define NPC_BRANCH  2'b01    // 条件分支跳转
`define NPC_BBL     2'b10    // 无条件分支跳转
`define NPC_JMPREG  2'b11    // 寄存器跳转
`define EXT_5       3'b001   // 5位零扩展, 用于移位立即数
`define EXT_12      3'b011
`define EXT_12_Z    3'b100   // 零扩展
`define EXT_16      3'b010
`define EXT_20      3'b110
`define EXT_26      3'b111

`define ALU_ADD     5'b00001
`define ALU_SUB     5'b00010
`define ALU_AND     5'b00011
`define ALU_OR      5'b00100
`define ALU_XOR     5'b00101
`define ALU_NOR     5'b00110
`define ALU_SLL     5'b00111
`define ALU_SRL     5'b01000
`define ALU_SRA     5'b01001
`define ALU_SLT     5'b01010
`define ALU_SLTU    5'b01011
`define ALU_LU12I   5'b01100


`define ALU_BNE     5'b10001   
`define ALU_BGE     5'b10010   
`define ALU_BGEU    5'b10011   
`define ALU_B       5'b10100   
`define ALU_JIRL    5'b10101  

`define ALU_MUL     5'b10110
`define ALU_MULH    5'b10111
`define ALU_MULHU   5'b11000  
`define ALU_DIV     5'b11001
`define ALU_DIVU    5'b11010
`define ALU_MOD     5'b11011
`define ALU_MODU    5'b11100


`define RAM_EXT_N   3'b000
`define RAM_EXT_B   3'b001
`define RAM_EXT_BU   3'b010
`define RAM_EXT_H   3'b011
`define RAM_EXT_HU   3'b100

`define RAM_WE_N    4'b0000
`define RAM_WE_B    4'b0001
`define RAM_WE_H    4'b0010
`define RAM_WE_W    4'b0011

`define R2_RK       1'b1
`define R2_RD       1'b0

`define ALUA_R1     1'b1
`define ALUA_PC     1'b0

`define ALUB_R2     1'b1
`define ALUB_EXT    1'b0

`define WR_RD       1'b1
`define WR_Rr1      1'b0

`define WD_ALU      2'b11
`define WD_RAM      2'b01
`define WD_PC4      2'b10
`define WD_CSR      2'b00

// Registered forwarding-shadow result banks.  Each bank captures its
// operation candidate before the OF/EX edge; the class selects only among
// registered values on the following cycle.
`define SHADOW_NONE    3'd0
`define SHADOW_ADDSUB  3'd1
`define SHADOW_LOGIC   3'd2
`define SHADOW_SHIFT   3'd3
`define SHADOW_COMPARE 3'd4
`define SHADOW_SIMPLE  3'd5
`define SHADOW_PC4     3'd6

`endif
