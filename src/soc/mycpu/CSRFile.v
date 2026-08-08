`timescale 1ns / 1ps

module CSRFile (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    input  wire        csr_we,
    input  wire [13:0] csr_rnum,
    input  wire [13:0] csr_wnum,
    input  wire [31:0] csr_wmask,
    input  wire [31:0] csr_wdata,
    output reg  [31:0] csr_rdata,
    output reg  [31:0] csr_crmd,
    output reg  [31:0] csr_dmw0,
    output reg  [31:0] csr_dmw1
);

    localparam [13:0] CSR_CRMD = 14'h0000;
    localparam [13:0] CSR_DMW0 = 14'h0180;
    localparam [13:0] CSR_DMW1 = 14'h0181;

    always @(*) begin
        case (csr_rnum)
            CSR_CRMD: csr_rdata = csr_crmd;
            CSR_DMW0: csr_rdata = csr_dmw0;
            CSR_DMW1: csr_rdata = csr_dmw1;
            default : csr_rdata = 32'b0;
        endcase
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            // Reset in direct-address mode: DA=1, PG=0.
            csr_crmd <= 32'h0000_0008;
            csr_dmw0 <= 32'b0;
            csr_dmw1 <= 32'b0;
        end else if (csr_we) begin
            case (csr_wnum)
                CSR_CRMD: csr_crmd <= (csr_crmd & ~csr_wmask) |
                                     (csr_wdata &  csr_wmask);
                CSR_DMW0: csr_dmw0 <= (csr_dmw0 & ~csr_wmask) |
                                     (csr_wdata &  csr_wmask);
                CSR_DMW1: csr_dmw1 <= (csr_dmw1 & ~csr_wmask) |
                                     (csr_wdata &  csr_wmask);
                default : begin end
            endcase
        end
    end

endmodule
