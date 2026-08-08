`timescale 1ns / 1ps

`include "defines.vh"

module RF (
    input  wire         cpu_clk,
    input  wire [ 4:0]  rR1    ,
    input  wire [ 4:0]  rR2    ,
    input  wire         we     ,
    input  wire [ 4:0]  wR     ,
    input  wire [31:0]  wD     ,
    output wire [31:0]  rD1    ,
    output wire [31:0]  rD2    
);

    reg [31:0] r [1:31];

    always @(posedge cpu_clk) begin
        if (we & (wR != 5'h0)) r[wR] <= wD;
    end

    assign rD1 = (rR1 == 5'h0) ? 32'h0 : r[rR1];
    assign rD2 = (rR2 == 5'h0) ? 32'h0 : r[rR2];

endmodule

// -----------------------------------------------------------------------------
// Four-read/two-write register file for a future restricted dual-issue front
// end.  The legacy RF module above is intentionally left unchanged so the
// current single-issue design keeps exactly the same netlist until integration.
//
// Port mapping convention:
//   rR1/rR2, we/wR/wD   : older (slot 0) instruction
//   rR3/rR4, we2/wR2/wD2: younger (slot 1) instruction
//
// A single Verilog array with two write ports is normally implemented as
// flip-flops on 7-series devices.  Keep each data bank single-write instead:
// slot 0 writes bank0, slot 1 writes bank1, and a 31-bit live-value table (LVT)
// records which bank owns the latest committed value of r1..r31.  The four
// asynchronous read ports can therefore be made by replicating single-write
// distributed RAMs rather than by building a 992-bit two-write FF array.
//
// Both write ports commit on the same rising edge.  Pairing logic is expected
// to reject WAW pairs, but the RF is defensive: if both enabled ports name the
// same non-zero architectural register, the younger slot-1 value wins.  Every
// asynchronous read is write-first with the same priority, which gives ID1 an
// explicit same-cycle WB bypass.  Register x0 is never written and always
// reads as zero.
// -----------------------------------------------------------------------------
module RF_4R2W (
    input  wire         cpu_clk,
    input  wire [ 4:0]  rR1,
    input  wire [ 4:0]  rR2,
    input  wire [ 4:0]  rR3,
    input  wire [ 4:0]  rR4,
    input  wire         we,
    input  wire [ 4:0]  wR,
    input  wire [31:0]  wD,
    input  wire         we2,
    input  wire [ 4:0]  wR2,
    input  wire [31:0]  wD2,
    output wire [31:0]  rD1,
    output wire [31:0]  rD2,
    output wire [31:0]  rD3,
    output wire [31:0]  rD4
);

    // A power-of-two physical depth is intentional: it lets Vivado infer
    // RAM32-style distributed storage.  Entry zero is never written and is
    // hidden by the architectural x0 checks below.
    (* ram_style = "distributed" *) reg [31:0] bank0 [0:31];
    (* ram_style = "distributed" *) reg [31:0] bank1 [0:31];

    // Store only r1..r31, then prepend a constant x0 ownership bit for reads.
    // The four timing-sensitive reads use the architectural register number
    // directly.  Only the two clocked write selectors address the 31-bit
    // physical vector, keeping address normalization off the read paths.
    reg  [31:1] latest_writer_q;
    wire [31:0] latest_writer = {latest_writer_q, 1'b0};

    wire write1_nonzero = we  && (wR  != 5'd0);
    wire write2_nonzero = we2 && (wR2 != 5'd0);

    always @(posedge cpu_clk) begin
        if (write1_nonzero) begin
            bank0[wR] <= wD;
            latest_writer_q[wR] <= 1'b0;
        end
        if (write2_nonzero)
        begin
            bank1[wR2] <= wD2;
            // This assignment is deliberately after the slot-0 assignment.
            // For a defensive same-address write, the younger slot owns LVT.
            latest_writer_q[wR2] <= 1'b1;
        end
    end

    // Keep every bypass dependency explicit.  In particular, do not hide the
    // write ports or the storage array behind a function which takes only the
    // read address: older event-driven simulators may then omit those external
    // references from the function call's reevaluation set.
    assign rD1 = (rR1 == 5'd0) ? 32'b0 :
                 (write2_nonzero && (rR1 == wR2)) ? wD2 :
                 (write1_nonzero && (rR1 == wR )) ? wD  :
                 latest_writer[rR1] ? bank1[rR1] : bank0[rR1];
    assign rD2 = (rR2 == 5'd0) ? 32'b0 :
                 (write2_nonzero && (rR2 == wR2)) ? wD2 :
                 (write1_nonzero && (rR2 == wR )) ? wD  :
                 latest_writer[rR2] ? bank1[rR2] : bank0[rR2];
    assign rD3 = (rR3 == 5'd0) ? 32'b0 :
                 (write2_nonzero && (rR3 == wR2)) ? wD2 :
                 (write1_nonzero && (rR3 == wR )) ? wD  :
                 latest_writer[rR3] ? bank1[rR3] : bank0[rR3];
    assign rD4 = (rR4 == 5'd0) ? 32'b0 :
                 (write2_nonzero && (rR4 == wR2)) ? wD2 :
                 (write1_nonzero && (rR4 == wR )) ? wD  :
                 latest_writer[rR4] ? bank1[rR4] : bank0[rR4];

endmodule
