`timescale 1ns / 1ps

// Exact shallow decoder for the ID1 second RF-read address.
//
// The full CU still owns all architectural decode/control.  This module only
// reproduces CU.r2_sel plus the CSR override, so the registered IBUF head does
// not traverse the shared opcode-class tree before reaching the RF address.
module ID1_r2_addr_decode (
    input  wire [31:0] inst,
    output wire [ 4:0] rR2
);

    wire r2_from_rd =
        (inst[31:24] == 8'h04) ||
        ((inst[31:24] == 8'h29) && !(inst[23] && inst[22])) ||
        (inst[31:27] == 5'b01011) ||
        (inst[31:28] == 4'b0110);

    (* KEEP = "true" *) wire [4:0] rR2_local =
        r2_from_rd ? inst[4:0] : inst[14:10];
    assign rR2 = rR2_local;

endmodule
