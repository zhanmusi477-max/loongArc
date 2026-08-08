`timescale 1ns / 1ps

`include "defines.vh"

module EXT (
    input  wire [ 2:0]  ext_op,
    input  wire [25:0]  din   ,
    output reg  [31:0]  ext   
);

    always @(*) begin
        case (ext_op)
            `EXT_5  : ext = {27'b0, din[14:10]};   // ��λ������
            `EXT_12 : ext = (din[21] ? {20'hfffff,din[21:10]} : {20'h00000,din[21:10]});
            `EXT_12_Z : ext = {20'b0, din[21:10]};   // ����չ
            `EXT_16 : ext = (din[25] ? {{14{1'b1}},din[25:10],2'b00} : {{14{1'b0}},din[25:10],2'b00});
            `EXT_20 : ext = {din[24:5],12'h000};
            `EXT_26 : ext = { {4{din[9]}}, din[9:0], din[25:10],2'b00 };
            default : ext = 32'h0;
        endcase
    end

endmodule
