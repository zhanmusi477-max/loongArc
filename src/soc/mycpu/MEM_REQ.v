`timescale 1ns / 1ps

`include "defines.vh"

module MEM_REQ (
    input  wire         clk           ,
    input  wire         rstn          ,
    input  wire         ex_valid      ,
    input  wire         ldst_suspend  ,
    input  wire [ 1:0]  mem_wd_sel    ,
    input  wire [31:0]  mem_ram_addr  ,

    input  wire [ 2:0]  mem_ram_ext_op,
    output reg  [ 3:0]  da_ren        ,
    output wire [31:0]  da_addr       ,

    input  wire [ 3:0]  mem_ram_we    ,
    input  wire [31:0]  mem_ram_wdata ,
    output reg  [ 3:0]  da_wen        ,
    output reg  [31:0]  da_wdata      
);

    reg        send_ldst_req;       // only valid at the first clk of mem stage
    wire [1:0] offset = mem_ram_addr[1:0];

    always @(posedge clk) begin
        send_ldst_req <= !rstn ? 1'b0 : ex_valid & !ldst_suspend;
    end

    assign da_addr = mem_ram_addr;
   always @(*) begin
        da_wen   = 4'h0;
        da_wdata = mem_ram_wdata;

        if (send_ldst_req && (mem_wd_sel == `WD_RAM)) begin
            case(mem_ram_we)
                `RAM_WE_B: begin // 存字节
                    case(offset)
                    //这里的offset是所要存的地址的低两位 在这里确定他具体要存在一个字的
                    //哪个位置 确定之后可以告诉数据总线读哪里
                        2'b00: da_wen = 4'b0001;
                        2'b01: da_wen = 4'b0010;
                        2'b10: da_wen = 4'b0100;
                        2'b11: da_wen = 4'b1000;

                    endcase
                    da_wdata = {4{mem_ram_wdata[7:0]}};
                end

                `RAM_WE_H: begin // 存半字
                    case(offset)
                        2'b00: da_wen = 4'b0011;
                        2'b10: da_wen = 4'b1100;

                        default: da_wen = 4'b0;
                    endcase
                    da_wdata = {2{mem_ram_wdata[15:0]}};
                end

                `RAM_WE_W: begin // 存字
                    da_wen = 4'b1111;
                end
            endcase
        end
    end


    always @(*) begin
        if (send_ldst_req & (mem_wd_sel == `WD_RAM) & (mem_ram_we == `RAM_WE_N)) begin
            case (mem_ram_ext_op)
                `RAM_EXT_H, `RAM_EXT_HU: da_ren = (offset == 2'h0 || offset == 2'h2) ? 4'hF : 4'h0; 
                `RAM_EXT_B, `RAM_EXT_BU: da_ren = 4'hF;
                `RAM_EXT_N: da_ren = (offset == 2'h0) ? 4'hF : 4'h0; 
                default: da_ren = 4'h0;
            endcase
        end else
            da_ren = 4'h0;
    end

endmodule
