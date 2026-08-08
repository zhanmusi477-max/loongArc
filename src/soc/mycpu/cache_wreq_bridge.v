`timescale 1ns / 1ps

module cache_wreq_bridge(
    input  wire         cpu_rstn ,
    input  wire         bus_rstn ,
    input  wire         cpu_clk  ,
    input  wire         cpu_ready,
    input  wire         bus_ready,
    // Cache Write Interface
    output wire         dev_wrdy ,      // 给Cache写主存的就绪信号（就绪时Cache才能发出写主存请求）
    output wire         write_pending,
    // Monotonic store-order tickets.  A following read captures
    // write_order_cpu and the SRAM-domain read engine waits until
    // write_order_done_bus reaches that ticket.  The counters may wrap;
    // FIFO_DEPTH bounds the outstanding distance to far below 256.
    output wire [ 7:0]  write_order_cpu,
    output reg  [ 7:0]  write_order_done_bus,
    // Dependency query for a following load miss. Different-word ordinary
    // loads may bypass buffered stores; same-word and peripheral loads wait.
    input  wire [31:0]  cpu_load_addr,
    output reg          cpu_load_block,
    input  wire         cpu_wperipheral,
    input  wire [ 3:0]  cpu_wen  ,      // Cache的写主存使能信号，支持字节使能
    input  wire [31:0]  cpu_waddr,      // Cache的写主存地址
    input  wire [31:0]  cpu_wdata,      // Cache的写主存数据
    // SRAM-User Interface
    input  wire         bus_uclk ,
    output wire         bus_en   ,      // SRAM使能信号
    output wire [31:0]  bus_waddr,      // 写SRAM地址
    output wire [ 3:0]  bus_we   ,      // 写SRAM写使能，支持字节使能
    output wire [31:0]  bus_wdata       // 写SRAM数据
);

    wire [ 3:0] fifo_we;
    wire [31:0] fifo_waddr;
    wire [31:0] fifo_wdata;
    wire        fifo_empty;
    wire        fifo_full;
    wire        fifo_wr_empty;
    wire        bus_fire = bus_ready && !fifo_empty;

    reg         pending_peripheral;
    reg         done_toggle_bus;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg done_toggle_cpu1;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg done_toggle_cpu2;
    reg         done_toggle_seen;
    reg  [ 7:0] write_order_cpu_r;
    reg  [ 7:0] write_order_done_gray_bus;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] write_order_done_gray_cpu1;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] write_order_done_gray_cpu2;
    // A compact signature is sufficient for the ordering query: equal word
    // addresses always produce an equal signature, so a true dependency can
    // never escape.  A rare collision only waits for an older Store ticket
    // conservatively.  The narrower compare removes the 30-bit carry chain
    // from M1's address to the DCache request mailbox.
    // Keep the complete word offset within a 2 MiB region plus the top region
    // bits.  This avoids collisions in CRYPTONIGHT's 2 MiB scratchpad while
    // still shortening the hot compare by eight address bits.
    reg  [21:0] store_word_sig_shadow [0:3];
    reg  [ 7:0] store_seq_shadow [0:3];
    reg  [ 3:0] store_peripheral_shadow;
    reg  [ 3:0] store_valid_shadow;

    function [7:0] gray_to_bin;
        input [7:0] gray;
        integer bit_idx;
        begin
            gray_to_bin[7] = gray[7];
            for (bit_idx = 6; bit_idx >= 0; bit_idx = bit_idx - 1)
                gray_to_bin[bit_idx] = gray_to_bin[bit_idx+1] ^ gray[bit_idx];
        end
    endfunction

    wire        done_seen = done_toggle_cpu2 ^ done_toggle_seen;
    wire        wr_accept = (cpu_wen != 4'h0) && dev_wrdy;
    wire        wr_peripheral = (fifo_waddr[31:16] == 16'h1F00) ||
                                (fifo_waddr[31:16] == 16'hBFD0);
    wire [31:0] wr_word_addr  = {2'h0, fifo_waddr[31:2]};
    wire [ 7:0] write_order_done_cpu =
                gray_to_bin(write_order_done_gray_cpu2);
    wire        cpu_load_peripheral = (cpu_load_addr[31:16] == 16'h1F00) ||
                                      (cpu_load_addr[31:16] == 16'hBFD0);
    wire [21:0] cpu_load_word_sig = {cpu_load_addr[31:29],
                                     cpu_load_addr[20:2]};
    wire [21:0] cpu_store_word_sig = {cpu_waddr[31:29],
                                      cpu_waddr[20:2]};

    integer shadow_cmp_idx;
    always @(*) begin
        cpu_load_block = 1'b0;
        for (shadow_cmp_idx = 0; shadow_cmp_idx < 4;
             shadow_cmp_idx = shadow_cmp_idx + 1) begin
            if (store_valid_shadow[shadow_cmp_idx] &&
                (store_peripheral_shadow[shadow_cmp_idx] ||
                 cpu_load_peripheral ||
                 (store_word_sig_shadow[shadow_cmp_idx] == cpu_load_word_sig)))
                cpu_load_block = 1'b1;
        end
        // Conservatively include a store accepted on the same CPU edge.
        if (wr_accept &&
            (cpu_wperipheral || cpu_load_peripheral ||
             (cpu_store_word_sig == cpu_load_word_sig)))
            cpu_load_block = 1'b1;
    end

    async_fifo #(
        .DATA_WIDTH(68)
    ) dc_wreq_fifo (
        // Write Port
        .wr_rstn    (cpu_rstn),
        .wr_clk     (cpu_clk),
        .wr_en      (wr_accept),
        .din        ({cpu_wen, cpu_waddr, cpu_wdata}),
        .full       (fifo_full),
        .wr_empty   (fifo_wr_empty),
        // Read Port
        .rd_rstn    (bus_rstn),
        .rd_clk     (bus_uclk),
        .rd_en      (bus_fire),
        .dout       ({fifo_we, fifo_waddr, fifo_wdata}),
        .empty      (fifo_empty)
    );

    // Ordinary SRAM writes complete from the CPU's point of view as soon as
    // they enter the FIFO.  Peripheral writes retain the old, strongly ordered
    // completion behavior because they may have externally visible effects.
    assign dev_wrdy = cpu_ready && !fifo_full &&
                       (!cpu_wperipheral || !pending_peripheral);
    assign write_pending = !fifo_wr_empty;
    // Conservatively include a store accepted on the same CPU edge as a
    // read request.  This can only add ordering; it can never let a load pass
    // an older store.
    assign write_order_cpu = write_order_cpu_r + (wr_accept ? 8'd1 : 8'd0);

    // Retire shadow entries from a registered valid bitmap.  Sequence
    // arithmetic is intentionally confined to this next-state path; the hot
    // load-address query above is now only four parallel equality checks.
    // The synchronized done count can lag by an extra CPU edge, which is
    // conservative (a load may wait longer) but can never release early.
    reg [3:0] store_valid_shadow_next;
    integer shadow_valid_idx;
    always @(*) begin
        store_valid_shadow_next = store_valid_shadow;
        for (shadow_valid_idx = 0; shadow_valid_idx < 4;
             shadow_valid_idx = shadow_valid_idx + 1) begin
            if (store_valid_shadow[shadow_valid_idx] &&
                (((store_seq_shadow[shadow_valid_idx] -
                   write_order_done_cpu) == 8'd0) ||
                 ((store_seq_shadow[shadow_valid_idx] -
                   write_order_done_cpu) > 8'd4)))
                store_valid_shadow_next[shadow_valid_idx] = 1'b0;
        end
        // A newly accepted store owns its modulo-four slot even if an older
        // completion for that slot is observed on the same edge.
        if (wr_accept)
            store_valid_shadow_next[write_order_cpu_r[1:0]] = 1'b1;
    end

    integer shadow_reset_idx;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            pending_peripheral <= 1'b0;
            done_toggle_cpu1 <= 1'b0;
            done_toggle_cpu2 <= 1'b0;
            done_toggle_seen <= 1'b0;
            write_order_cpu_r <= 8'd0;
            write_order_done_gray_cpu1 <= 8'd0;
            write_order_done_gray_cpu2 <= 8'd0;
            store_peripheral_shadow <= 4'd0;
            store_valid_shadow <= 4'd0;
            for (shadow_reset_idx = 0; shadow_reset_idx < 4;
                 shadow_reset_idx = shadow_reset_idx + 1)
                store_seq_shadow[shadow_reset_idx] <= 8'd0;
        end else begin
            done_toggle_cpu1 <= done_toggle_bus;
            done_toggle_cpu2 <= done_toggle_cpu1;
            write_order_done_gray_cpu1 <= write_order_done_gray_bus;
            write_order_done_gray_cpu2 <= write_order_done_gray_cpu1;
            store_valid_shadow <= store_valid_shadow_next;

            if (done_seen) begin
                pending_peripheral <= 1'b0;
                done_toggle_seen <= done_toggle_cpu2;
            end else if (wr_accept && cpu_wperipheral) begin
                pending_peripheral <= 1'b1;
            end

            if (wr_accept) begin
                store_word_sig_shadow[write_order_cpu_r[1:0]] <=
                    cpu_store_word_sig;
                store_seq_shadow[write_order_cpu_r[1:0]] <=
                    write_order_cpu_r + 8'd1;
                store_peripheral_shadow[write_order_cpu_r[1:0]] <=
                    cpu_wperipheral;
                write_order_cpu_r <= write_order_cpu_r + 8'd1;
            end
        end
    end

    always @(posedge bus_uclk or negedge bus_rstn) begin
        if (!bus_rstn) begin
            done_toggle_bus <= 1'b0;
            write_order_done_bus <= 8'd0;
            write_order_done_gray_bus <= 8'd0;
        end else begin
            if (bus_fire) begin
                write_order_done_bus <= write_order_done_bus + 8'd1;
                write_order_done_gray_bus <=
                    ((write_order_done_bus + 8'd1) >> 1) ^
                     (write_order_done_bus + 8'd1);
                if (wr_peripheral)
                    done_toggle_bus <= !done_toggle_bus;
            end
        end
    end

    assign bus_en    = bus_fire;
    assign bus_waddr = wr_peripheral ? fifo_waddr : wr_word_addr;
    assign bus_we    = bus_fire ? fifo_we : 4'h0;
    assign bus_wdata = fifo_wdata;

endmodule
