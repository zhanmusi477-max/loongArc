`timescale 1ns / 1ps

`include "defines.vh"

module sram_bus_master(
    input  wire         cpu_rstn,
    input  wire         sram_rstn,
    input  wire         cpu_clk,
    input  wire         sram_uclk,

    // ICache interface
    output wire         ic_dev_rrdy,
    input  wire         ic_cpu_ren,
    input  wire [31:0]  ic_cpu_raddr,
    output wire         ic_dev_rvalid,
    output wire [31:0]  ic_dev_rdata,
    output wire         ic_dev_r2_use_rd,

    // DCache interface
    output wire         dc_dev_wrdy,
    input  wire [ 3:0]  dc_cpu_wen,
    input  wire [31:0]  dc_cpu_waddr,
    input  wire         dc_cpu_wperipheral,
    input  wire [31:0]  dc_cpu_wdata,
    output wire         dc_dev_rrdy,
    input  wire         dc_cpu_ren,
    input  wire [31:0]  dc_cpu_raddr,
    input  wire [31:0]  dc_cpu_order_addr,
    input  wire         dc_cpu_rshort,
    output wire         dc_dev_rvalid,
    output wire [31:0]  dc_dev_rdata,

    // Bus 0: unified BaseRAM/ExtRAM SRAM bus
    output wire         bus_en0,
    output reg  [31:0]  bus_addr0,
    output wire [ 3:0]  bus_we0,
    output wire [31:0]  bus_wdata0,
    input  wire [31:0]  bus_rdata0,

    // Bus 1: peripheral
    output wire         bus_en1,
    output reg  [31:0]  bus_addr1,
    output wire [ 3:0]  bus_we1,
    output wire [31:0]  bus_wdata1,
    input  wire [31:0]  bus_rdata1
);

`ifdef ENABLE_ICACHE
    localparam IC_BLK_LEN = `CACHE_BLK_LEN;
`else
    localparam IC_BLK_LEN = 1;
`endif

`ifdef ENABLE_DCACHE
    localparam DC_BLK_LEN = `CACHE_BLK_LEN;
`else
    localparam DC_BLK_LEN = 1;
`endif

    // Keep bridge traffic disabled until both clock domains have left reset.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sram_ready_cpu_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] cpu_ready_sram_sync;

    // cpu_rstn and sram_rstn are already asynchronously asserted and
    // synchronously released in their respective clock domains.  Keep the
    // destination-domain stages on synchronous reset so that these wide
    // ready enables do not create recovery paths into cache state/BRAM
    // controls.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            sram_ready_cpu_sync <= 2'b00;
        else
            sram_ready_cpu_sync <= {sram_ready_cpu_sync[0], sram_rstn};
    end

    always @(posedge sram_uclk) begin
        if (!sram_rstn)
            cpu_ready_sram_sync <= 2'b00;
        else
            cpu_ready_sram_sync <= {cpu_ready_sram_sync[0], cpu_rstn};
    end

    wire cpu_side_ready = sram_ready_cpu_sync[1];
    wire bus_side_ready = cpu_ready_sram_sync[1];

    wire        ic_rfifo_rdy;
    wire        dc_rfifo_rdy;
    wire        dc_wfifo_rdy;
    wire        dc_write_pending;
    wire [ 7:0] dc_write_order_cpu;
    wire [ 7:0] dc_write_order_done_bus;
    wire        dc_load_block;

    assign ic_dev_rrdy = cpu_side_ready & ic_rfifo_rdy;
    // A read may enter its CDC FIFO while older writes are draining.  A
    // same-word or peripheral dependency is carried with the request as a
    // strict-order bit below; the SRAM-domain engine then waits for the
    // captured store ticket.  Keeping that comparison out of dev_rrdy avoids
    // chaining address translation/store-shadow matching into the FIFO write
    // enable, while preserving exactly the same memory ordering.
    assign dc_dev_rrdy = cpu_side_ready & dc_rfifo_rdy;
    assign dc_dev_wrdy = cpu_side_ready & dc_wfifo_rdy;

    wire [31:0] bus_rdata;
    wire [ 3:0] bus_we;
    wire [31:0] bus_wdata;

    wire        ic_rd_bus_en;
    wire [31:0] ic_bus_raddr;
    wire        dc_rd_bus_en;
    wire [31:0] dc_bus_raddr;
    wire        dc_wr_bus_en;
    wire [31:0] dc_bus_waddr;

    wire rd_peripheral = (dc_bus_raddr[31:16] == 16'h1F00) ||
                         (dc_bus_raddr[31:16] == 16'hBFD0);
    wire wr_peripheral = (dc_bus_waddr[31:16] == 16'h1F00) ||
                         (dc_bus_waddr[31:16] == 16'hBFD0);

    wire wr_mem_en  = dc_wr_bus_en && !wr_peripheral;
    wire rd_mem_en  = dc_rd_bus_en && !rd_peripheral;
    wire wr_peri_en = dc_wr_bus_en &&  wr_peripheral;
    wire rd_peri_en = dc_rd_bus_en &&  rd_peripheral;

    cache_rreq_bridge #(
        .BLK_LEN (IC_BLK_LEN)
    ) u_ic_rreq_bridge (
        .cpu_rstn   (cpu_rstn),
        .bus_rstn   (sram_rstn),
        .cpu_clk    (cpu_clk),
        .cpu_ready  (cpu_side_ready),
        .bus_ready  (bus_side_ready),
        .w_hold     (wr_mem_en),
        .r_hold     (rd_mem_en),
        .dev_rrdy   (ic_rfifo_rdy),
        .cpu_ren    (ic_cpu_ren),
        .cpu_raddr  (ic_cpu_raddr),
        .cpu_short  (1'b0),
        .cpu_order_tag(8'd0),
        .cpu_strict_order(1'b0),
        .dev_rvalid (ic_dev_rvalid),
        .dev_rdata  (ic_dev_rdata),
        .dev_r2_use_rd(ic_dev_r2_use_rd),
        .bus_uclk   (sram_uclk),
        .bus_order_done(8'd0),
        .bus_en     (ic_rd_bus_en),
        .bus_raddr  (ic_bus_raddr),
        .bus_rdata  (bus_rdata0)
    );

    cache_rreq_bridge #(
        .BLK_LEN (DC_BLK_LEN),
        .ENFORCE_STORE_ORDER (1),
        .RELATED_CLOCK_MAILBOX (1)
    ) u_dc_rreq_bridge (
        .cpu_rstn   (cpu_rstn),
        .bus_rstn   (sram_rstn),
        .cpu_clk    (cpu_clk),
        .cpu_ready  (cpu_side_ready),
        .bus_ready  (bus_side_ready),
        .w_hold     (1'b0),
        .r_hold     (1'b0),
        .dev_rrdy   (dc_rfifo_rdy),
        .cpu_ren    (dc_cpu_ren),
        .cpu_raddr  (dc_cpu_raddr),
        .cpu_short  (dc_cpu_rshort),
        .cpu_order_tag(dc_write_order_cpu),
        .cpu_strict_order(dc_load_block ||
                          (dc_cpu_order_addr[31:16] == 16'h1F00) ||
                          (dc_cpu_order_addr[31:16] == 16'hBFD0)),
        .dev_rvalid (dc_dev_rvalid),
        .dev_rdata  (dc_dev_rdata),
        .dev_r2_use_rd(),
        .bus_uclk   (sram_uclk),
        .bus_order_done(dc_write_order_done_bus),
        .bus_en     (dc_rd_bus_en),
        .bus_raddr  (dc_bus_raddr),
        .bus_rdata  (bus_rdata)
    );

    cache_wreq_bridge u_dc_wreq_bridge (
        .cpu_rstn      (cpu_rstn),
        .bus_rstn      (sram_rstn),
        .cpu_clk       (cpu_clk),
        .cpu_ready     (cpu_side_ready),
        .bus_ready     (bus_side_ready && !dc_rd_bus_en),
        .dev_wrdy      (dc_wfifo_rdy),
        .write_pending (dc_write_pending),
        .write_order_cpu(dc_write_order_cpu),
        .write_order_done_bus(dc_write_order_done_bus),
        .cpu_load_addr (dc_cpu_order_addr),
        .cpu_load_block(dc_load_block),
        .cpu_wen       (dc_cpu_wen),
        .cpu_waddr     (dc_cpu_waddr),
        .cpu_wperipheral(dc_cpu_wperipheral),
        .cpu_wdata     (dc_cpu_wdata),
        .bus_uclk      (sram_uclk),
        .bus_en        (dc_wr_bus_en),
        .bus_waddr     (dc_bus_waddr),
        .bus_we        (bus_we),
        .bus_wdata     (bus_wdata)
    );

`ifndef SYNTHESIS
    // The ordering-only address is a timing retime, not a protocol change.
    // At the only edge on which either value is sampled they must be exact.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && dc_cpu_ren &&
            (dc_cpu_order_addr !== dc_cpu_raddr))
            $fatal(1, "DCache ordering address differs from request address");
    end
`endif

    assign bus_en0 = wr_mem_en | rd_mem_en | ic_rd_bus_en;
    always @(*) begin
        if      (wr_mem_en)      bus_addr0 = dc_bus_waddr;
        else if (rd_mem_en)      bus_addr0 = dc_bus_raddr;
        else if (ic_rd_bus_en)   bus_addr0 = ic_bus_raddr;
        else                     bus_addr0 = 32'hF0F0F0F0;

        if      (wr_peri_en)     bus_addr1 = dc_bus_waddr;
        else if (rd_peri_en)     bus_addr1 = dc_bus_raddr;
        else                     bus_addr1 = 32'hF1F1F1F1;
    end

    assign bus_en1    = wr_peri_en | rd_peri_en;
    assign bus_we0    = bus_we & {4{wr_mem_en}};
    assign bus_we1    = bus_we & {4{wr_peri_en}};
    assign bus_wdata0 = bus_wdata;
    assign bus_wdata1 = bus_wdata;

    // Hold peripheral read data until the response bridge consumes it.
    reg [31:0] peri_rdata_hold;
    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn)
            peri_rdata_hold <= 32'b0;
        else if (rd_peri_en)
            peri_rdata_hold <= bus_rdata1;
    end

    assign bus_rdata = rd_peripheral ? peri_rdata_hold : bus_rdata0;

endmodule
