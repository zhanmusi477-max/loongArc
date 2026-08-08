`timescale 1ns / 1ps

`include "defines.vh"

module ALU (
    input  wire         cpu_rstn,
    input  wire         cpu_clk,
    input  wire [ 4:0]  alu_op,
    input  wire [31:0]  A,
    input  wire [31:0]  B,
    // Launch a multiply from the accepted ID2 payload one cycle before that
    // instruction becomes the resident EX instruction.  This compensates an
    // additional internal DSP pipeline stage without adding a CPU stall.
    input  wire         mul_issue,
    input  wire [ 4:0]  mul_issue_op,
    input  wire [31:0]  mul_issue_A,
    input  wire [31:0]  mul_issue_B,
    input  wire         mul_result_take,
    input  wire         is_br_jmp,
    output reg  [31:0]  C,
    output reg          f,
    output wire         mul_result_valid,
    output wire [31:0]  mul_result_data,
    // Physically separate candidates for timing-safe late-MUL consumers.
    // Queue occupancy selects only after the consumer's arithmetic cone.
    output wire         mul_queue_select,
    output wire [31:0]  mul_queue_head_data,
    output wire [31:0]  mul_complete_result_data,
    output wire         mul_complete_low_select,
    output wire [31:0]  mul_complete_low_data,
    output wire [31:0]  mul_complete_high_data,
    // State of the ordered-result mux immediately after the next CPU edge.
    // M1 registers these two bits with the instruction entering M2, so global
    // pipeline control never depends on the live queue counter.
    output wire         mul_result_next_valid,
    output wire         mul_queue_select_next
);

    wire        is_mul_op;
    wire [65:0] mul_result;
    wire [32:0] mul_ip_A;
    wire [32:0] mul_ip_B;

    assign is_mul_op = (alu_op == `ALU_MUL) | (alu_op == `ALU_MULH) | (alu_op == `ALU_MULHU);

    // mult_gen_0 is a three-stage, initiation-interval-one DSP pipeline.  Its
    // inputs sample every cycle; mul_issue is therefore carried through a
    // matching valid/op pipeline instead of being turned into a global stall.
    // Idle samples are ignored by the delayed valid bit.  Keeping the operand
    // data ungated also avoids broadcasting mul_issue into all DSP inputs.
    assign mul_ip_A = (mul_issue_op == `ALU_MULHU) ?
                      {1'b0, mul_issue_A} :
                      {mul_issue_A[31], mul_issue_A};
    assign mul_ip_B = (mul_issue_op == `ALU_MULHU) ?
                      {1'b0, mul_issue_B} :
                      {mul_issue_B[31], mul_issue_B};

    reg [2:0] mul_valid_pipe;
    // Operand signedness is already encoded in mul_ip_A/mul_ip_B at issue.
    // The result side only needs one metadata bit: MUL.W selects the low word;
    // MULH.W/MULH.WU select the high word.  Carrying the complete 5-bit opcode
    // through the DSP pipeline created an unnecessarily deep equality decode
    // on every registered-product forwarding path.
    reg mul_low_pipe0;
    reg mul_low_pipe1;
    // This one-bit result selector fans into both EX2 architectural result
    // buses.  Explicitly cap each physical copy's fanout so placement can keep
    // the final low/high muxes beside their destination flops; duplicating this
    // metadata bit is much cheaper than duplicating either 32-bit adder.
    (* max_fanout = 8 *) reg mul_low_pipe2;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            mul_valid_pipe <= 3'b0;
            mul_low_pipe0  <= 1'b0;
            mul_low_pipe1  <= 1'b0;
            mul_low_pipe2  <= 1'b0;
        end else begin
            mul_valid_pipe[0] <= mul_issue;
            mul_valid_pipe[1] <= mul_valid_pipe[0];
            mul_valid_pipe[2] <= mul_valid_pipe[1];
            mul_low_pipe0     <= (mul_issue_op == `ALU_MUL);
            mul_low_pipe1     <= mul_low_pipe0;
            mul_low_pipe2     <= mul_low_pipe1;
        end
    end

    mult_gen_0 u_mult_gen_0 (
        .CLK (cpu_clk   ),
        .A   (mul_ip_A  ),
        .B   (mul_ip_B  ),
        .P   (mul_result)
    );

    // A DCache or Store-buffer stall can freeze the architectural stages while
    // the DSP continues to advance (the generated IP has no CE).  Preserve
    // completed products in a small ordered skid queue.  In the common case
    // the queue is empty and M2 consumes the registered DSP output directly,
    // so no extra multiply latency or throughput bubble is introduced.
    wire       mul_complete_valid = mul_valid_pipe[2];
    wire [31:0] mul_complete_data =
        mul_low_pipe2 ? mul_result[31:0] : mul_result[63:32];

    reg [31:0] mul_queue0;
    reg [31:0] mul_queue1;
    reg [31:0] mul_queue2;
    reg [31:0] mul_queue3;
    reg [ 2:0] mul_queue_count;

    wire mul_queue_valid = (mul_queue_count != 3'd0);
    wire mul_take_queued = mul_result_take && mul_queue_valid;
    wire mul_take_bypass = mul_result_take && !mul_queue_valid &&
                           mul_complete_valid;
    wire mul_enqueue = mul_complete_valid && !mul_take_bypass;
    reg [2:0] mul_queue_count_next;

    // Exact next occupancy for the same enqueue/dequeue event implemented by
    // the sequential queue below.  The following DSP-valid bit becomes the
    // direct result after the edge, independently of queue occupancy.
    always @(*) begin
        mul_queue_count_next = mul_queue_count;
        case ({mul_take_queued, mul_enqueue})
            2'b01: begin
                if (mul_queue_count != 3'd4)
                    mul_queue_count_next = mul_queue_count + 3'd1;
            end
            2'b10:
                mul_queue_count_next = mul_queue_count - 3'd1;
            2'b11:
                mul_queue_count_next = mul_queue_count;
            default:
                mul_queue_count_next = mul_queue_count;
        endcase
    end

    assign mul_result_valid = mul_queue_valid || mul_complete_valid;
    assign mul_result_data  = mul_queue_valid ? mul_queue0 :
                                                 mul_complete_data;
    assign mul_queue_select = mul_queue_valid;
    assign mul_queue_head_data = mul_queue0;
    assign mul_complete_result_data = mul_complete_data;
    assign mul_complete_low_select = mul_low_pipe2;
    assign mul_complete_low_data = mul_result[31:0];
    assign mul_complete_high_data = mul_result[63:32];
    assign mul_queue_select_next = (mul_queue_count_next != 3'd0);
    assign mul_result_next_valid =
        mul_queue_select_next || mul_valid_pipe[1];

    // Retained as a verification-visible occupancy signal.  It no longer
    // controls pl_suspend and therefore does not serialize independent work.
    wire mul_busy = (mul_valid_pipe != 3'b0) || mul_queue_valid;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            mul_queue0     <= 32'b0;
            mul_queue1     <= 32'b0;
            mul_queue2     <= 32'b0;
            mul_queue3     <= 32'b0;
            mul_queue_count <= 3'd0;
        end else begin
            case ({mul_take_queued, mul_enqueue})
                2'b01: begin
                    case (mul_queue_count)
                        3'd0: mul_queue0 <= mul_complete_data;
                        3'd1: mul_queue1 <= mul_complete_data;
                        3'd2: mul_queue2 <= mul_complete_data;
                        3'd3: mul_queue3 <= mul_complete_data;
                        default: mul_queue3 <= mul_queue3;
                    endcase
                    if (mul_queue_count != 3'd4)
                        mul_queue_count <= mul_queue_count + 3'd1;
                end
                2'b10: begin
                    mul_queue0 <= mul_queue1;
                    mul_queue1 <= mul_queue2;
                    mul_queue2 <= mul_queue3;
                    mul_queue_count <= mul_queue_count - 3'd1;
                end
                2'b11: begin
                    // Consume the oldest queued product and append the newly
                    // completed one on the same edge; occupancy is unchanged.
                    case (mul_queue_count)
                        3'd1: mul_queue0 <= mul_complete_data;
                        3'd2: begin
                            mul_queue0 <= mul_queue1;
                            mul_queue1 <= mul_complete_data;
                        end
                        3'd3: begin
                            mul_queue0 <= mul_queue1;
                            mul_queue1 <= mul_queue2;
                            mul_queue2 <= mul_complete_data;
                        end
                        default: begin
                            mul_queue0 <= mul_queue1;
                            mul_queue1 <= mul_queue2;
                            mul_queue2 <= mul_queue3;
                            mul_queue3 <= mul_complete_data;
                        end
                    endcase
                end
                default: mul_queue_count <= mul_queue_count;
            endcase
        end
    end

    always @(*) begin
        case (alu_op)
            `ALU_ADD   : C = A + B;
            `ALU_SUB   : C = A - B;
            `ALU_AND   : C = A & B;
            `ALU_OR    : C = A | B;
            `ALU_XOR   : C = A ^ B;
            `ALU_NOR   : C = ~(A | B);
            `ALU_SLL   : C = A << B[4:0];
            `ALU_SRL   : C = A >> B[4:0];
            `ALU_SRA   : C = $signed(A) >>> B[4:0];
            `ALU_SLT   : C = ($signed(A) < $signed(B)) ? 32'd1 : 32'd0;
            `ALU_SLTU  : C = (A < B) ? 32'd1 : 32'd0;
            `ALU_LU12I : C = B;
            `ALU_BNE   : C = A - B;
            `ALU_BGE   : C = ($signed(A) < $signed(B)) ? 32'd1 : 32'd0;
            `ALU_BGEU  : C = (A < B) ? 32'd1 : 32'd0;
            `ALU_JIRL  : C = A + B;
            // Products join the architectural data path at M2.  EX/M1
            // forwarding is explicitly disabled for multiply instructions.
            `ALU_MUL   : C = 32'b0;
            `ALU_MULH  : C = 32'b0;
            `ALU_MULHU : C = 32'b0;
            default    : C = 32'h87654321;
        endcase
    end

    always @(*) begin
        if (!is_br_jmp) begin
            f = 1'b0;
        end else begin
            case (alu_op)
                `ALU_SUB   : f = (C == 32'd0);
                `ALU_BNE   : f = (C != 32'd0);
                `ALU_SLT   : f = (C == 32'd1);
                `ALU_BGE   : f = (C == 32'd0);
                `ALU_SLTU  : f = (C == 32'd1);
                `ALU_BGEU  : f = (C == 32'd0);
                `ALU_B     : f = 1'b1;
                `ALU_JIRL  : f = 1'b1;
                default    : f = 1'b0;
            endcase
        end
    end

endmodule
