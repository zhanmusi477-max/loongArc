`timescale 1ns / 1ps

`include "defines.vh"

module PC (
    input  wire         cpu_rstn,
    input  wire         cpu_clk ,
    input  wire         suspend ,

    input  wire         if_valid,
    input  wire [31:0]  din     ,
    output wire [31:0]  pc      ,
    output wire [31:0]  pred_pc
);

    // BPU lookup gets an architecturally identical but physically independent
    // PC bank.  This prevents the high-fanout fetch PC from launching through
    // the asynchronous BPU table and back into another automatic PC replica.
    // Split the three reset-to-one bits from the reset-to-zero bits.  This lets
    // Vivado map the update condition to the native FDSE/FDRE CE pins instead
    // of folding ICache hit/valid into a 32-bit data mux.  The two banks remain
    // architecturally identical and update on exactly the old request cycles.
    localparam [31:0] RESET_PC = `PC_INIT_VAL;
    (* extract_enable = "yes" *) reg [28:0] pc_zero_r;
    (* extract_enable = "yes" *) reg [ 2:0] pc_one_r;
    // KEEP preserves this BPU-only bank instead of merging it back into the
    // main fetch PC.  MAX_FANOUT deliberately permits Vivado to replicate the
    // BPU address bits close to the distributed table; DONT_TOUCH would block
    // that timing-preserving physical duplication.
    (* keep = "true", max_fanout = 16, extract_enable = "yes" *)
    reg [28:0] pred_pc_zero_r;
    (* keep = "true", max_fanout = 16, extract_enable = "yes" *)
    reg [ 2:0] pred_pc_one_r;

    assign pc = {pc_zero_r[28:26], pc_one_r, pc_zero_r[25:0]};
    assign pred_pc = {pred_pc_zero_r[28:26], pred_pc_one_r,
                      pred_pc_zero_r[25:0]};

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            pc_zero_r      <= {RESET_PC[31:29], RESET_PC[25:0]};
            pc_one_r       <= RESET_PC[28:26];
            pred_pc_zero_r <= {RESET_PC[31:29], RESET_PC[25:0]};
            pred_pc_one_r  <= RESET_PC[28:26];
        end else if (!suspend && if_valid) begin
            pc_zero_r      <= {din[31:29], din[25:0]};
            pc_one_r       <= din[28:26];
            pred_pc_zero_r <= {din[31:29], din[25:0]};
            pred_pc_one_r  <= din[28:26];
        end
    end

endmodule
