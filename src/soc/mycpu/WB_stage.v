`timescale 1ns / 1ps

`include "defines.vh"

module WB_stage (
    input  wire        cpu_rstn,
    input  wire        cpu_clk,
    input  wire        pl_suspend,
    input  wire        mem_valid,
    input  wire [31:0] mem_pc,
    input  wire [31:0] mem_ext,
    input  wire [31:0] mem_alu_C,
    input  wire [31:0] mem_ram_ext,
    input  wire        mem_rf_we,
    input  wire [ 4:0] mem_wR,
    input  wire [ 1:0] mem_wd_sel,
    output wire        wb_rf_we,
    output wire [ 4:0] wb_wR,
    output wire [31:0] wb_wd,
    output wire        wb_valid,
    output wire [31:0] wb_pc
);

    reg [31:0] mem_wd_next;
    always @(*) begin
        case (mem_wd_sel)
            `WD_CSR: mem_wd_next = mem_ext;
            `WD_RAM: mem_wd_next = mem_ram_ext;
            `WD_ALU: mem_wd_next = mem_alu_C;
            `WD_PC4: mem_wd_next = mem_pc + 32'd4;
            default: mem_wd_next = 32'b0;
        endcase
    end

    // This is the architectural M2->WB result boundary.  Register the final
    // selected value, rather than registering candidates and selecting after
    // WB, so DCache data cannot be propagated into ID2 combinational logic.
    wire [31:0] unused_alu_C;
    wire [31:0] unused_ram_ext;
    wire [31:0] unused_ext;
    wire [ 1:0] unused_wd_sel;
    (* DONT_TOUCH = "true" *) MEM_WB u_MEM_WB (
        .cpu_clk(cpu_clk), .cpu_rstn(cpu_rstn), .suspend(pl_suspend),
        .valid_in(mem_valid), .wR_in(mem_wR), .pc_in(mem_pc),
        .alu_C_in(mem_alu_C), .ram_ext_in(mem_ram_ext), .ext_in(mem_ext),
        .wd_in(mem_wd_next), .rf_we_in(mem_rf_we), .wd_sel_in(mem_wd_sel),
        .valid_out(wb_valid), .wR_out(wb_wR), .pc_out(wb_pc),
        .alu_C_out(unused_alu_C), .ram_ext_out(unused_ram_ext),
        .ext_out(unused_ext), .wd_out(wb_wd), .rf_we_out(wb_rf_we),
        .wd_sel_out(unused_wd_sel)
    );

endmodule
