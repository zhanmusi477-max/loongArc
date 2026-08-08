`timescale 1ns / 1ps

module AddressTranslate (
    input  wire [31:0] vaddr,
    input  wire [31:0] csr_crmd,
    input  wire [31:0] csr_dmw0,
    input  wire [31:0] csr_dmw1,
    output wire [31:0] paddr
);

    wire paging   = csr_crmd[4] && !csr_crmd[3];
    wire dmw0_hit = paging && csr_dmw0[0] &&
                    (vaddr[31:29] == csr_dmw0[31:29]);
    wire dmw1_hit = paging && csr_dmw1[0] &&
                    (vaddr[31:29] == csr_dmw1[31:29]);

    assign paddr = dmw0_hit ? {csr_dmw0[27:25], vaddr[28:0]} :
                   dmw1_hit ? {csr_dmw1[27:25], vaddr[28:0]} :
                              vaddr;

endmodule
