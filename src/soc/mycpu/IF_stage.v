`timescale 1ns / 1ps

module IF_stage (
    input  wire         cpu_rstn     ,
    input  wire         cpu_clk      ,
    // pipeline control
    input  wire         pause_ifetch ,      // 暂停取指信号
    input  wire         resume_ifetch,      // 恢复取指信号
    input  wire         pl_suspend   ,      // 流水线暂停
    // From BPU
    input  wire         front_redirect_valid,
    input  wire [31:0]  front_redirect_pc,
    input  wire [31:0]  pred_target  ,      // 预测的下一条指令的地址
    // From other stages
    input  wire         id_valid     ,      // ID阶段的有效信号
    input  wire         ex_valid     ,      // EX阶段的有效信号
    input  wire [ 1:0]  ex_npc_op    ,      // EX阶段的npc_op，用于控制下一条指令PC值的生成
    input  wire [31:0]  ex_pc        ,      // EX阶段的PC值
    input  wire [31:0]  ex_rD1       ,      // EX阶段的源寄存器1的值
    input  wire [31:0]  ex_ext       ,      // EX阶段的扩展后的立即数
    input  wire [31:0]  ex_taken_target,
    input  wire         ex_alu_f     ,      // EX阶段的标志位
    // To ID
    output wire         if_valid     ,      // IF阶段有效信号
    output wire [31:0]  if_pc        ,      // IF阶段PC值
    output wire [31:0]  if_pred_pc   ,      // BPU查询PC，纠错周期不走EX组合目标
    output wire [31:0]  if_npc       ,      // 实际的下一条指令的地址
    output wire         if_redirect_req,    // 本拍发出寄存后的纠错请求
    output wire         if_redirect_pending,
    output wire         ifetch_start_req,
    // Instruction Fetch Interface
    output wire         ifetch_rreq  ,      // 取指请求信号
    output wire [31:0]  ifetch_addr  ,      // 取指地址
    input  wire         ifetch_valid        // 指令有效信号
);

    reg  rstn_r;
    wire first_req = !rstn_r & cpu_rstn;    // posedge of cpu_rstn
    always @(posedge cpu_clk) rstn_r <= cpu_rstn;

    // ICache has a single pending-request slot.  The normal hit/refill chain
    // launches the next request together with ifetch_valid, but an IBUF
    // resume pulse is generated independently from cache progress.  Without
    // this credit bit, a resume during a long refill can overwrite the
    // request already held by ICache and permanently skip one instruction.
    // A registered redirect is allowed to replace an old-path request; all
    // ordinary resume requests must wait until the outstanding response.
    reg fetch_outstanding;

    wire [31:0] pc_reg;     // PC寄存器的值
    wire [31:0] bpu_pc_reg;
    // The redirect event and target are registered at the ID2/front-end
    // boundary in myCPU.  IF consumes only those flops; no ID2 compare or
    // target arithmetic can reach PC/ICache control in the same cycle.
    wire issue_redirect = front_redirect_valid;
    wire [31:0] pc_din = issue_redirect ?
                         (front_redirect_pc + 32'h4) : pred_target;
    assign      if_pc      = issue_redirect ? front_redirect_pc : pc_reg;
    // Query the BPU from the registered sequential PC.  On a redirect cycle
    // its prediction is not consumed (the registered redirect target wins),
    // so feeding the redirect mux back through the asynchronous BPU table only
    // creates a false topological valid->BPU->PC data cone.  The next cycle's
    // registered PC is the first prediction that can affect fetching.
    assign      if_pred_pc = bpu_pc_reg;
    assign      if_redirect_req = issue_redirect;
    assign      if_redirect_pending = front_redirect_valid;
    wire resume_request = resume_ifetch && !fetch_outstanding;
    // Keep the cache-start event physically independent from the normal
    // hit-chain event. ICache consumes this signal only while IDLE, so its
    // state register cannot be reached through BRAM hit -> ifetch_valid ->
    // ifetch_rreq. The OR below preserves the exact request cycle.
    assign ifetch_start_req = !pause_ifetch &&
                              (front_redirect_valid | first_req |
                               resume_request);
    assign ifetch_rreq = ifetch_start_req |
                         (!pause_ifetch && ifetch_valid);
    assign ifetch_addr = if_pc;
    assign if_valid    = ifetch_rreq;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            fetch_outstanding <= 1'b0;
        else begin
            case ({ifetch_rreq, ifetch_valid})
                2'b10: fetch_outstanding <= 1'b1;
                2'b01: fetch_outstanding <= 1'b0;
                2'b11: fetch_outstanding <= 1'b1;
                default: fetch_outstanding <= fetch_outstanding;
            endcase
        end
    end

    PC u_PC (
        .cpu_clk    (cpu_clk    ),
        .cpu_rstn   (cpu_rstn   ),
        .suspend    (1'b0       ),

        .if_valid   (if_valid   ),
        .din        (pc_din     ),
        .pc         (pc_reg     ),
        .pred_pc    (bpu_pc_reg )
    );


    NPC u_NPC (
        .cpu_clk    (cpu_clk    ),
        .cpu_rstn   (cpu_rstn   ),
        .id_valid   (id_valid   ),
        .ex_valid   (ex_valid   ),
        .npc_op     (ex_npc_op  ),
        .ex_pc      (ex_pc      ),
        .taken_target(ex_taken_target),
        .br         (ex_alu_f   ), 
        .npc        (if_npc     )
    );

endmodule
