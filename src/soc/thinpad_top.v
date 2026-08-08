`default_nettype none

module thinpad_top(
    input  wire        clk_50M,
    input  wire        clk_11M0592,

    input  wire        clock_btn,
    input  wire        reset_btn,

    input  wire [ 3:0] touch_btn,
    input  wire [31:0] dip_sw,
    output wire [15:0] leds,
    output wire [ 7:0] dpy0,
    output wire [ 7:0] dpy1,

    inout  wire [31:0] base_ram_data,
    output wire [19:0] base_ram_addr,
    output wire [ 3:0] base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,

    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [ 3:0] ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,

    output wire        txd,
    input  wire        rxd,

    output wire [22:0] flash_a,
    inout  wire [15:0] flash_d,
    output wire        flash_rp_n,
    output wire        flash_vpen,
    output wire        flash_ce_n,
    output wire        flash_oe_n,
    output wire        flash_we_n,
    output wire        flash_byte_n,

    output wire [ 2:0] video_red,
    output wire [ 2:0] video_green,
    output wire [ 1:0] video_blue,
    output wire        video_hsync,
    output wire        video_vsync,
    output wire        video_clk,
    output wire        video_de
);

    wire cpu_clk;
    wire sram_uclk;
    wire sram_wclk;
    wire pll_locked;

    pll_example u_clock_gen (
        .clk_in1  (clk_50M),
        .clk_out1 (cpu_clk),
        .clk_out2 (sram_uclk),
        .clk_out3 (sram_wclk),
        .reset    (reset_btn),
        .locked   (pll_locked)
    );

    wire reset_async_n = pll_locked & ~reset_btn;
    // Assert reset asynchronously from the button/PLL lock, then release it
    // independently in each local clock domain.  Never distribute a reset
    // synchronized by cpu_clk into the SRAM clock domain.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [1:0] cpu_reset_sync;
    always @(posedge cpu_clk or negedge reset_async_n) begin
        if (!reset_async_n)
            cpu_reset_sync <= 2'b00;
        else
            cpu_reset_sync <= {cpu_reset_sync[0], 1'b1};
    end
    wire cpu_rstn = cpu_reset_sync[1];

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [1:0] sram_reset_sync;
    always @(posedge sram_uclk or negedge reset_async_n) begin
        if (!reset_async_n)
            sram_reset_sync <= 2'b00;
        else
            sram_reset_sync <= {sram_reset_sync[0], 1'b1};
    end
    wire sram_rstn = sram_reset_sync[1];

    wire        sram_bus_en;
    wire [31:0] sram_bus_addr;
    wire [ 3:0] sram_bus_we;
    wire [31:0] sram_bus_wdata;
    wire [31:0] sram_bus_rdata;

    wire        peri_bus_en;
    wire [31:0] peri_bus_addr;
    wire [ 3:0] peri_bus_we;
    wire [31:0] peri_bus_wdata;
    wire [31:0] peri_bus_rdata;

    mycpu_top u_cpu (
        .cpu_rstn       (cpu_rstn),
        .sram_rstn      (sram_rstn),
        .cpu_clk        (cpu_clk),
        .sram_uclk      (sram_uclk),
        .sram_bus_en    (sram_bus_en),
        .sram_bus_addr  (sram_bus_addr),
        .sram_bus_we    (sram_bus_we),
        .sram_bus_wdata (sram_bus_wdata),
        .sram_bus_rdata (sram_bus_rdata),
        .peri_bus_en    (peri_bus_en),
        .peri_bus_addr  (peri_bus_addr),
        .peri_bus_we    (peri_bus_we),
        .peri_bus_wdata (peri_bus_wdata),
        .peri_bus_rdata (peri_bus_rdata)
    );

    // -------------------------------------------------------------------------
    // Direct UART (115200 baud, 8 data bits, no parity, 1 stop bit).
    // Supervisor MMIO: 0x1F000000 data and 0x1F000005 status.  The legacy
    // monitor addresses remain accepted so existing basic tests still work.
    // Keep UART in the peripheral-bus clock domain to avoid another CDC path.
    // ------------------------------------------------------------------------
    localparam integer UART_CLK_FREQ = 51_000_000;
    localparam [31:0] UART_DATA_ADDR         = 32'h1F00_0000;
    localparam [31:0] UART_STAT_ADDR         = 32'h1F00_0005;
    localparam [31:0] UART_LCR_ADDR          = 32'h1F00_0003;
    localparam [31:0] UART_DATA_ADDR_LEGACY  = 32'hBFD0_03F8;
    localparam [31:0] UART_STAT_ADDR_LEGACY  = 32'hBFD0_03FC;
    localparam [31:0] UART_LCR_ADDR_LEGACY   = 32'hBFD0_03FB;

    wire       uart_rx_ready;
    wire [7:0] uart_rx_data;
    reg        uart_rx_clear;
    wire       uart_tx_busy;
    reg        uart_tx_start;
    reg  [7:0] uart_tx_data;
    reg        uart_dlab;

    wire uart_bus_read   = peri_bus_en && !(|peri_bus_we);
    wire uart_bus_write  = peri_bus_en &&  (|peri_bus_we);
    wire uart_data_selected = (peri_bus_addr == UART_DATA_ADDR) ||
                              (peri_bus_addr == UART_DATA_ADDR_LEGACY);
    wire uart_read_data  = uart_bus_read  && uart_data_selected;
    wire uart_write_lcr  = uart_bus_write &&
                           ((peri_bus_addr == UART_LCR_ADDR) ||
                            (peri_bus_addr == UART_LCR_ADDR_LEGACY));
    wire uart_write_data = uart_bus_write && uart_data_selected && !uart_dlab;
    wire uart_tx_ready   = !(uart_tx_busy | uart_tx_start);
    wire [7:0] uart_status = {2'b0, uart_tx_ready, 4'b0, uart_rx_ready};

    assign peri_bus_rdata =
        (peri_bus_addr == UART_STAT_ADDR)        ? {16'b0, uart_status, 8'b0} :
        (peri_bus_addr == UART_STAT_ADDR_LEGACY) ? {30'b0, uart_rx_ready, uart_tx_ready} :
        uart_data_selected                       ? {24'b0, uart_rx_data} :
                                                   32'b0;

    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn) begin
            uart_rx_clear <= 1'b0;
            uart_tx_start <= 1'b0;
            uart_tx_data  <= 8'b0;
            uart_dlab     <= 1'b0;
        end else begin
            uart_rx_clear <= 1'b0;
            uart_tx_start <= 1'b0;

            if (uart_write_lcr)
                uart_dlab <= peri_bus_wdata[7];

            if (uart_read_data && uart_rx_ready)
                uart_rx_clear <= 1'b1;

            if (uart_write_data && uart_tx_ready) begin
                uart_tx_data  <= peri_bus_wdata[7:0];
                uart_tx_start <= 1'b1;
            end
        end
    end

    async_receiver #(
        .ClkFrequency (UART_CLK_FREQ),
        .Baud         (115200)
    ) u_uart_rx (
        .clk            (sram_uclk),
        .rstn           (sram_rstn),
        .RxD            (rxd),
        .RxD_data_ready (uart_rx_ready),
        .RxD_clear      (uart_rx_clear),
        .RxD_data       (uart_rx_data)
    );

    async_transmitter #(
        .ClkFrequency (UART_CLK_FREQ),
        .Baud         (115200)
    ) u_uart_tx (
        .clk       (sram_uclk),
        .rstn      (sram_rstn),
        .TxD_start (uart_tx_start),
        .TxD_data  (uart_tx_data),
        .TxD       (txd),
        .TxD_busy  (uart_tx_busy)
    );

    wire base_ram_en = sram_bus_en & ~sram_bus_addr[20];
    wire ext_ram_en  = sram_bus_en &  sram_bus_addr[20];
    wire [31:0] base_ram_rdata;
    wire [31:0] ext_ram_rdata;

    sram_ctrl #(.ADDR_WID(20)) u_base_ram (
        .rstn       (sram_rstn),
        .usr_clk    (sram_uclk),
        .wen_clk    (sram_wclk),
        .usr_en     (base_ram_en),
        .usr_addr   (sram_bus_addr),
        .usr_we     (sram_bus_we),
        .usr_wdata  (sram_bus_wdata),
        .usr_rdata  (base_ram_rdata),
        .sram_addr  (base_ram_addr),
        .sram_data  (base_ram_data),
        .sram_oen   (base_ram_oe_n),
        .sram_cen   (base_ram_ce_n),
        .sram_wen   (base_ram_we_n),
        .sram_ben   (base_ram_be_n)
    );

    sram_ctrl #(.ADDR_WID(20)) u_ext_ram (
        .rstn       (sram_rstn),
        .usr_clk    (sram_uclk),
        .wen_clk    (sram_wclk),
        .usr_en     (ext_ram_en),
        .usr_addr   (sram_bus_addr),
        .usr_we     (sram_bus_we),
        .usr_wdata  (sram_bus_wdata),
        .usr_rdata  (ext_ram_rdata),
        .sram_addr  (ext_ram_addr),
        .sram_data  (ext_ram_data),
        .sram_oen   (ext_ram_oe_n),
        .sram_cen   (ext_ram_ce_n),
        .sram_wen   (ext_ram_we_n),
        .sram_ben   (ext_ram_be_n)
    );

    reg read_from_ext;
    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn)
            read_from_ext <= 1'b0;
        else if (sram_bus_en && !(|sram_bus_we))
            read_from_ext <= sram_bus_addr[20];
    end
    assign sram_bus_rdata = read_from_ext ? ext_ram_rdata : base_ram_rdata;

    assign leds = 16'b0;
    assign dpy0 = 8'b0;
    assign dpy1 = 8'b0;
    assign flash_a = 23'b0;
    assign flash_d = 16'hzzzz;
    assign flash_rp_n = 1'b1;
    assign flash_vpen = 1'b0;
    assign flash_ce_n = 1'b1;
    assign flash_oe_n = 1'b1;
    assign flash_we_n = 1'b1;
    assign flash_byte_n = 1'b1;

    assign video_red = 3'b0;
    assign video_green = 3'b0;
    assign video_blue = 2'b0;
    assign video_hsync = 1'b0;
    assign video_vsync = 1'b0;
    assign video_clk = 1'b0;
    assign video_de = 1'b0;

endmodule

`default_nettype wire
