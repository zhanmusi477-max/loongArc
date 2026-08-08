`timescale 1ns / 1ps

module sram_ctrl #(
    parameter ADDR_WID = 20
)(
    input  wire         rstn,
    input  wire         usr_clk,        // 0  degree phase, 50% duty cycle
    input  wire         wen_clk,        // 45 degree phase, 75% duty cycle (or 90-50%)
    
    input  wire         usr_en,
    input  wire [31:0]  usr_addr,
    input  wire [ 3:0]  usr_we,
    input  wire [31:0]  usr_wdata,
    output wire [31:0]  usr_rdata,

    output wire [ADDR_WID-1:0]  sram_addr,      // read/write address
    inout  wire [31:0]  sram_data,      // read/write data
    output wire         sram_oen,       // output enable
    output wire         sram_cen,       // chip select
    output wire         sram_wen,       // write enable
    output wire [ 3:0]  sram_ben        // byte enable
);

    // Capture the asynchronous SRAM bus in the input I/O registers.
    (* IOB = "TRUE" *) reg [31:0] sram_rdata;

    // Launch every external SRAM transaction from the 0-degree bus edge.
    // The bus arbiter may change its combinational head immediately after the
    // 0-degree edge.  Driving that head straight to the package pins produced
    // 14-15 ns unconstrained paths, leaving no write-data setup before the end
    // of the 90-degree write pulse.  These IOB registers give writes 1/4 cycle
    // of address setup before WE_n falls and a full half-cycle low pulse.  Read
    // data is sampled at the phase-clock falling edge, 3/4 cycle after launch,
    // so it is already registered before the response FIFO's next 0-degree
    // edge.  Request pop and response push cycles therefore remain unchanged.
    (* IOB = "TRUE" *) reg [ADDR_WID-1:0] sram_addr_r;
    (* IOB = "TRUE" *) reg [31:0] sram_wdata_r;
    (* IOB = "TRUE" *) reg [31:0] sram_data_t_r;
    (* IOB = "TRUE" *) reg        sram_cen_r;
    (* IOB = "TRUE" *) reg        sram_oen_r;
    (* IOB = "TRUE" *) reg [ 3:0] sram_ben_r;
    reg write_active_r;

    always @(posedge usr_clk) begin
        if (!rstn) begin
            sram_addr_r    <= {ADDR_WID{1'b0}};
            sram_wdata_r   <= 32'b0;
            sram_data_t_r  <= {32{1'b1}};
            sram_cen_r     <= 1'b1;
            sram_oen_r     <= 1'b1;
            sram_ben_r     <= 4'hF;
            write_active_r <= 1'b0;
        end else begin
            sram_addr_r    <= usr_addr[ADDR_WID-1:0];
            sram_wdata_r   <= usr_wdata;
            sram_data_t_r  <= {32{!(usr_en && (|usr_we))}};
            sram_cen_r     <= !usr_en;
            sram_oen_r     <= !(usr_en && !(|usr_we));
            sram_ben_r     <= !usr_en ? 4'hF :
                              ((|usr_we) ? ~usr_we : 4'h0);
            write_active_r <= usr_en && (|usr_we);
        end
    end

    assign sram_addr = sram_addr_r;
    assign sram_cen  = sram_cen_r;
    assign sram_oen  = sram_oen_r;
    assign sram_ben  = sram_ben_r;

    genvar data_bit;
    generate
        for (data_bit = 0; data_bit < 32; data_bit = data_bit + 1) begin : gen_sram_data
            assign sram_data[data_bit] = sram_data_t_r[data_bit]
                                       ? 1'bz : sram_wdata_r[data_bit];
        end
    endgenerate

    // The 90-degree rising edge starts the write pulse after the IOB outputs
    // have been stable for one quarter cycle; its falling edge ends the pulse
    // after half a cycle.  The lint tool does not provide a model for the
    // Xilinx ODDR primitive, so lint/simulation uses the equivalent edge model
    // while the FPGA build keeps WE_n in the output I/O cell.
`ifdef SIMULATION
    reg sram_wen_sim;

    always @(posedge wen_clk or negedge wen_clk) begin
        if (wen_clk)
            sram_wen_sim <= ~write_active_r;
        else
            sram_wen_sim <= 1'b1;
    end

    assign sram_wen = sram_wen_sim;
`else
    ODDR #(
        .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
        .INIT         (1'b1),
        .SRTYPE       ("SYNC")
    ) u_sram_we_oddr (
        .Q  (sram_wen),
        .C  (wen_clk),
        .CE (1'b1),
        .D1 (~write_active_r),
        .D2 (1'b1),
        .R  (1'b0),
        .S  (1'b0)
    );
`endif

    always @(negedge wen_clk) begin
        if (!rstn)
            sram_rdata <= 32'h0;
        else if (!sram_cen_r && !sram_oen_r)
            sram_rdata <= sram_data;
    end

    // Reads return the value sampled late in the preceding SRAM bus cycle.
    // Bypassing usr_wdata here corrupts that pending read response whenever a
    // write takes the shared bus on the following cycle (including a write to
    // the other SRAM bank).  Write transactions do not consume usr_rdata.
    assign usr_rdata = sram_rdata;

endmodule
