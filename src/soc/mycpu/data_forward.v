`timescale 1ns / 1ps

`include "defines.vh"

module data_forward (
    input  wire [ 4:0] id_rR1,
    input  wire [ 4:0] id_rR2,
    input  wire        id_rR1_re,
    input  wire        id_rR2_re,

    input  wire        ex_we,
    input  wire [ 4:0] ex_wr,
    input  wire [31:0] ex_wd,
    input  wire        x2_we,
    input  wire [ 4:0] x2_wr,
    input  wire [31:0] x2_wd,
    input  wire        mem_we,
    input  wire [ 4:0] mem_wr,
    input  wire [31:0] mem_wd,
    input  wire        wb_we,
    input  wire [ 4:0] wb_wr,
    input  wire [31:0] wb_wd,

    output wire        fd_rD1_sel,
    output wire [31:0] fd_rD1,
    output wire        fd_rD2_sel,
    output wire [31:0] fd_rD2
);

    wire raw_rR1_id_ex  = (id_rR1 == ex_wr ) & id_rR1_re & ex_we  &
                           (id_rR1 != 5'h0);
    wire raw_rR1_id_x2  = (id_rR1 == x2_wr ) & id_rR1_re & x2_we  &
                           (id_rR1 != 5'h0);
    wire raw_rR1_id_mem = (id_rR1 == mem_wr) & id_rR1_re & mem_we &
                           (id_rR1 != 5'h0);
    wire raw_rR1_id_wb  = (id_rR1 == wb_wr ) & id_rR1_re & wb_we  &
                           (id_rR1 != 5'h0);

    wire raw_rR2_id_ex  = (id_rR2 == ex_wr ) & id_rR2_re & ex_we  &
                           (id_rR2 != 5'h0);
    wire raw_rR2_id_x2  = (id_rR2 == x2_wr ) & id_rR2_re & x2_we  &
                           (id_rR2 != 5'h0);
    wire raw_rR2_id_mem = (id_rR2 == mem_wr) & id_rR2_re & mem_we &
                           (id_rR2 != 5'h0);
    wire raw_rR2_id_wb  = (id_rR2 == wb_wr ) & id_rR2_re & wb_we  &
                           (id_rR2 != 5'h0);

    assign fd_rD1_sel = raw_rR1_id_ex | raw_rR1_id_x2 |
                        raw_rR1_id_mem | raw_rR1_id_wb;
    assign fd_rD2_sel = raw_rR2_id_ex | raw_rR2_id_x2 |
                        raw_rR2_id_mem | raw_rR2_id_wb;

    // Resolve the architectural priority in the small control cone first,
    // then combine the 32-bit data in parallel.  This preserves
    // EX > M1 > M2 > WB while avoiding a serial four-stage data mux on every
    // ALU-to-consumer forwarding path.
    wire sel_r1_ex  = raw_rR1_id_ex;
    wire sel_r1_x2  = raw_rR1_id_x2  & !raw_rR1_id_ex;
    wire sel_r1_mem = raw_rR1_id_mem & !raw_rR1_id_ex & !raw_rR1_id_x2;
    wire sel_r1_wb  = raw_rR1_id_wb  & !raw_rR1_id_ex & !raw_rR1_id_x2 &
                      !raw_rR1_id_mem;

    wire sel_r2_ex  = raw_rR2_id_ex;
    wire sel_r2_x2  = raw_rR2_id_x2  & !raw_rR2_id_ex;
    wire sel_r2_mem = raw_rR2_id_mem & !raw_rR2_id_ex & !raw_rR2_id_x2;
    wire sel_r2_wb  = raw_rR2_id_wb  & !raw_rR2_id_ex & !raw_rR2_id_x2 &
                      !raw_rR2_id_mem;

    assign fd_rD1 = ({32{sel_r1_ex }} & ex_wd ) |
                    ({32{sel_r1_x2 }} & x2_wd ) |
                    ({32{sel_r1_mem}} & mem_wd) |
                    ({32{sel_r1_wb }} & wb_wd );

    assign fd_rD2 = ({32{sel_r2_ex }} & ex_wd ) |
                    ({32{sel_r2_x2 }} & x2_wd ) |
                    ({32{sel_r2_mem}} & mem_wd) |
                    ({32{sel_r2_wb }} & wb_wd );

endmodule
