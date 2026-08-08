`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 4
) (
    // Write port
    input  wire                  wr_rstn,
    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire                  full,
    output wire                  wr_empty,
    // Read port
    input  wire                  rd_rstn,
    input  wire                  rd_clk,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  empty
);

    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

    // No reset or read-clocked process touches mem.  This is the standard
    // dual-clock, first-word-fall-through form that maps to distributed RAM.
    (* ram_style = "distributed" *)
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_gray;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [ADDR_WIDTH:0] wr_ptr_gray_rdclk1, wr_ptr_gray_rdclk2;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [ADDR_WIDTH:0] rd_ptr_gray_wrclk1, rd_ptr_gray_wrclk2;

    wire [ADDR_WIDTH:0] wr_ptr_bin_next  = wr_ptr_bin + 1'b1;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next =
                          (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
    wire [ADDR_WIDTH:0] rd_ptr_bin_next  = rd_ptr_bin + 1'b1;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next =
                          (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;

    assign full =
        wr_ptr_gray_next ==
        {~rd_ptr_gray_wrclk2[ADDR_WIDTH:ADDR_WIDTH-1],
           rd_ptr_gray_wrclk2[ADDR_WIDTH-2:0]};
    assign wr_empty = wr_ptr_gray == rd_ptr_gray_wrclk2;
    assign empty    = rd_ptr_gray == wr_ptr_gray_rdclk2;

    // The consumer samples this head on the same rd_clk edge that advances
    // rd_ptr_bin, so consecutive pops return consecutive FIFO entries.
    assign dout = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

    // The memory write process intentionally has no reset sensitivity.  FIFO
    // validity comes from the pointers, so clearing the array is unnecessary.
    always @(posedge wr_clk) begin
        if (wr_en && !full)
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= din;
    end

    // Both reset inputs are generated with asynchronous assertion and
    // synchronous release in their own clock domains.  Reset FIFO pointers
    // synchronously here: these pointers and the second synchronizer stages
    // feed cache address/control logic, so asynchronous reset recovery arcs
    // must not propagate into cache BRAM inputs.
    always @(posedge wr_clk) begin
        if (!wr_rstn) begin
            wr_ptr_bin  <= 0;
            wr_ptr_gray <= 0;
        end else if (wr_en && !full) begin
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_rstn) begin
            rd_ptr_bin  <= 0;
            rd_ptr_gray <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr_bin  <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_rstn) begin
            wr_ptr_gray_rdclk1 <= 0;
            wr_ptr_gray_rdclk2 <= 0;
        end else begin
            wr_ptr_gray_rdclk1 <= wr_ptr_gray;
            wr_ptr_gray_rdclk2 <= wr_ptr_gray_rdclk1;
        end
    end

    always @(posedge wr_clk) begin
        if (!wr_rstn) begin
            rd_ptr_gray_wrclk1 <= 0;
            rd_ptr_gray_wrclk2 <= 0;
        end else begin
            rd_ptr_gray_wrclk1 <= rd_ptr_gray;
            rd_ptr_gray_wrclk2 <= rd_ptr_gray_wrclk1;
        end
    end

endmodule
