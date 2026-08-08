`timescale 1ns / 1ps

module RAS #(
    parameter DEPTH = 8,
    parameter PTR_W = 3
) (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    input  wire        push,
    input  wire [31:0] push_addr,
    input  wire        pop,
    output wire [31:0] top,
    output wire        empty
);

    reg [31:0] stack [0:DEPTH-1];
    reg [PTR_W-1:0] sp;
    reg [PTR_W:0] count;

    assign empty = (count == 0);
    assign top = empty ? 32'h0 : stack[sp - 1'b1];

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            sp    <= {PTR_W{1'b0}};
            count <= {(PTR_W+1){1'b0}};
        end else if (push) begin
            stack[sp] <= push_addr;
            sp <= sp + 1'b1;
            if (count < DEPTH)
                count <= count + 1'b1;
        end else if (pop && !empty) begin
            sp    <= sp - 1'b1;
            count <= count - 1'b1;
        end
    end

endmodule
