`timescale 1ns / 1ps

`include "defines.vh"

module EX_stage (
    input  wire         cpu_rstn     ,
    input  wire         cpu_clk      ,
    // pipeline control
    input  wire         pl_suspend   ,      // 流水线暂停信号
    input  wire         early_load_hold,
    input  wire         pred_error   ,      // 分支预测错误的标志位
    output reg          ldst_unalign ,      // 访存地址是否不满足对齐条件
    // From ID
    input  wire         id_valid     ,      // ID阶段有效信号
    input  wire         id_kill      ,      // late branch correction kills only this issue slot
    input  wire [31:0]  id_pc        ,      // ID阶段PC值
    input  wire         id_pred_taken,      // prediction direction for ID instruction
    input  wire [31:0]  id_pred_target,     // prediction target for ID instruction
    input  wire [ 1:0]  id_npc_op    ,      // ID阶段的npc_op，用于控制下一条指令PC值的生成
    input  wire [31:0]  id_ext       ,      // ID阶段的扩展后的立即数
    input  wire [31:0]  id_target_ext,
    input  wire [31:0]  id_mem_addr,
    input  wire [26:0]  id_order_addr_key,
    input  wire [31:0]  id_real_rD1  ,      // ID阶段的源操作数1的实际值
    input  wire [31:0]  id_real_rD2  ,      // ID阶段的源操作数2的实际值
    input  wire         id_load_dep_r1,
    input  wire         id_load_dep_r2,
    input  wire         id_mul_dep_r1,
    input  wire         id_mul_dep_r2,
    input  wire [ 4:0]  id_alu_op    ,      // ID阶段的alu_op，用于控制ALU进行何种运算
    input  wire         id_alua_sel  ,      // ID阶段的ALU操作数A选择信号（选择源寄存器1的值或扩展后的立即数或其他）
    input  wire         id_alub_sel  ,      // ID阶段的ALU操作数B选择信号（选择源寄存器2的值或扩展后的立即数或其他）
    input  wire         id_rf_we     ,      // ID阶段的寄存器写使能（指令需要写回时rf_we为1）
    input  wire [ 4:0]  id_wR        ,      // ID阶段的目标寄存器
    input  wire [ 1:0]  id_wd_sel    ,      // ID阶段的写回数据选择（选择ALU执行结果写回，或选择访存数据写回，etc.）
    input  wire [ 3:0]  id_ram_we    ,      // ID阶段的主存写使能信号（针对store指令）
    input  wire [ 2:0]  id_ram_ext_op,      // ID阶段的读主存数据扩展op，用于控制主存读回数据的扩展方式（针对load指令）
    input  wire         id_is_br_jmp ,      // ID阶段是否是条件分支或直接跳转指令
    input  wire         id_branch_deferred,
    input  wire         id_is_call   ,
    input  wire         id_is_return ,
    input  wire [31:0]  id_mul_rD1   ,
    input  wire [31:0]  id_mul_rD2   ,
    input  wire         id_shadow_valid,
    input  wire         id_shadow_repair_and,
    input  wire [ 2:0]  id_shadow_class,
    input  wire [31:0]  id_shadow_addsub_wd,
    input  wire [31:0]  id_shadow_logic_wd,
    input  wire [31:0]  id_shadow_shift_wd,
    input  wire [31:0]  id_shadow_compare_wd,
    input  wire [31:0]  id_shadow_simple_wd,
    input  wire [31:0]  id_shadow_pc4_wd,
    // To IF
    output wire [ 1:0]  ex_npc_op    ,      // EX阶段的npc_op，用于控制下一条指令PC值的生成
    output wire         ex_alu_f     ,      // EX阶段的标志位
    output wire         ex_is_ld_st  ,      // EX阶段是否是Load/Store指令
    output wire         ex_is_mul_div,      // EX阶段是否是乘除法相关指令
    output wire         ex_is_br_jmp ,      // EX阶段是否是条件分支或直接跳转指令
    output wire         ex_branch_deferred,
    output wire         ex_is_call   ,
    output wire         ex_is_return ,
    output wire         ex_br_jmp_f  ,      // EX阶段分支跳转指令实际是否会发生跳转
    // To MEM
    output wire         ex_valid     ,      // EX阶段有效信号
    output wire [31:0]  ex_pc        ,      // EX阶段PC值
    output wire         ex_pred_taken,      // prediction direction for EX instruction
    output wire [31:0]  ex_pred_target,     // prediction target for EX instruction
    output wire [31:0]  ex_rD1       ,      // EX阶段的源寄存器1的值
    output wire [31:0]  ex_rD2       ,      // EX阶段的源寄存器2的值
    output wire         ex_load_dep_r1,
    output wire         ex_load_dep_r2,
    output wire         ex_mul_dep_r1,
    output wire         ex_mul_dep_r2,
    output wire [31:0]  ex_ext       ,      // EX阶段的扩展后的立即数
    output wire [31:0]  ex_taken_target,
    output wire [31:0]  ex_alu_C     ,      // EX阶段的ALU运算结果
    output wire [31:0]  ex_mem_addr  ,
    output wire [26:0]  ex_order_addr_key,
    output wire         ex_rf_we     ,      // EX阶段的寄存器写使能（指令需要写回时rf_we为1）
    output wire [ 4:0]  ex_wR        ,      // EX阶段的目的寄存器
    output wire [ 1:0]  ex_wd_sel    ,      // EX阶段的写回数据选择（选择ALU执行结果写回，或选择访存数据写回，etc.）
    output wire [ 3:0]  ex_ram_we    ,      // EX阶段的主存写使能信号（针对store指令）
    output wire [ 2:0]  ex_ram_ext_op,      // EX阶段的读主存数据扩展op，用于控制主存读回数据的扩展方式（针对load指令）
    // Data Forward
    output reg  [31:0]  ex_wd        ,      // EX阶段的待写回数据
    output wire [31:0]  ex_mul_fwd_wd,
    output wire [31:0]  ex_control_fwd_wd,
    output wire         ex_fast_result_valid,
    output wire         ex_data_forward_ready,
    output wire         ex_control_forward_ready,
    output wire         ex_memory_forward_ready,
    // Operation-local forwarding paths for exact adjacent dependencies.
    output wire [ 4:0]  ex_exec_alu_op,
    output wire [31:0]  ex_exec_A,
    output wire [31:0]  ex_exec_B,
    output wire [31:0]  ex_exec_add_wd,
    output wire [31:0]  ex_exec_sll_wd,
    output wire [31:0]  ex_exec_srl_wd,
    output wire         ex_exec_sll_by_one,
    output wire [31:0]  ex_exec_sll1_wd,
    output wire [31:0]  ex_exec_xor_wd,
    output wire [31:0]  ex_exec_and_wd,
    output wire         ex_exec_registered_operands,
    output wire         ex_exec_mul_late,
    output wire         ex_mul_queue_select,
    output wire [31:0]  ex_exec_nonmul_A,
    output wire [31:0]  ex_exec_nonmul_B,
    output wire [31:0]  ex_exec_nonmul_sll_wd,
    output wire [31:0]  ex_exec_mul_queue_A,
    output wire [31:0]  ex_exec_mul_queue_B,
    output wire [31:0]  ex_exec_mul_bypass_A,
    output wire [31:0]  ex_exec_mul_bypass_B,
    output wire         ex_mul_bypass_low_select,
    output wire [31:0]  ex_exec_mul_bypass_low_A,
    output wire [31:0]  ex_exec_mul_bypass_high_A,
    output wire         ex_sel_ram   ,          // EX阶段是否是访存指令 (特指Load指令, 用于Load-Use处理)

    input  wire         load_result_valid,
    input  wire [31:0]  load_result_data,

    input  wire         mul_result_take,
    // M1->M2 registered result selector aligned with the oldest MUL.
    input  wire         mul_result_queue_select,
    input  wire [31:0]  mul_result_queue_select_mask,
    output wire         mul_result_valid,
    output wire [31:0]  mul_result_data,
    output wire         mul_result_next_valid,
    output wire         mul_queue_select_next
);

    // -------------------------------------------------------------------------
    // EX阶段数据选择和指令类型
    // -------------------------------------------------------------------------
    // Keep the late-mispredict cone local to the ID/EX valid input.  Payload
    // flops may capture don't-care values for a killed instruction, but no
    // architectural control observes them while ex_valid is zero.
    wire        id_accept = id_valid && !id_kill;
    wire [ 4:0] ex_alu_op;
    wire [31:0] ex_rD1_raw;
    wire [31:0] ex_rD2_raw;
    // A late-MUL dependency is admitted from OF only when its producer is in
    // M1.  On the following edge the producer and its exact queue selector
    // enter M2 together.  If the DSP result is not ready, the registered
    // M2 interlock holds both stages until it is; therefore mul_result_valid
    // is an advance qualification, not an operand-mux input.  Selecting with
    // the registered dependency tag removes live queue occupancy from the
    // 32-bit ALU cone without changing any issue or retirement cycle.
    // OF admits a late MUL operand only for the profiled zero-bubble
    // MUL.W -> ADD.W(rj) shape.  That shape has an independent architectural
    // carry chain in OF_stage and is selected again at the EX->M1 boundary.
    // Consequently no live MUL result belongs on either generic ALU input.
    // This structural cut (rather than a control-only mutually-exclusive mux)
    // prevents static timing from traversing DSP/queue -> generic ALU -> EX2.
    reg         ex_mul_r1_add_fast_r;
    assign ex_rD1 = (ex_load_dep_r1 && load_result_valid)
                   ? load_result_data :
                     ex_rD1_raw;
    assign ex_rD2 = (ex_load_dep_r2 && load_result_valid)
                   ? load_result_data :
                     ex_rD2_raw;
    wire        ex_alua_sel, ex_alub_sel;
`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ex_valid && !pl_suspend &&
            (ex_mul_dep_r1 || ex_mul_dep_r2) &&
            !mul_result_valid)
            $fatal(1, "late-MUL EX consumer advanced before result valid");
        if (cpu_rstn && ex_valid && ex_exec_mul_late &&
            (!ex_alua_sel || (ex_wd_sel != `WD_ALU) ||
             (ex_alu_op != `ALU_ADD) || !ex_mul_dep_r1 || ex_mul_dep_r2 ||
             ex_load_dep_r1 || ex_load_dep_r2))
            $fatal(1, "late-MUL ADD fast-path shape invariant failed");
    end
`endif
    assign ex_is_ld_st = ex_valid & (ex_wd_sel == `WD_RAM);
    wire [31:0] ex_alu_A = ex_alua_sel ? ex_rD1 : ex_pc;
    wire [31:0] ex_alu_B = ex_alub_sel ? ex_rD2 : ex_ext;
    // This operation-local path is fed only by OF/EX payload registers.  It
    // deliberately bypasses the late Load/MUL selection mux, so an AND result
    // can feed an adjacent branch without reconnecting the live MUL queue to
    // the branch/redirect cone.
    wire [31:0] ex_raw_alu_A = ex_alua_sel ? ex_rD1_raw : ex_pc;
    wire [31:0] ex_raw_alu_B = ex_alub_sel ? ex_rD2_raw : ex_ext;
    wire [31:0] mul_queue_head_data;
    wire [31:0] mul_complete_result_data;
    wire        mul_complete_low_select;
    wire [31:0] mul_complete_low_data;
    wire [31:0] mul_complete_high_data;
    wire        mul_queue_select_live;
    wire [31:0] mul_result_data_live;
    // The architectural result selector is registered with the instruction
    // in M2.  The live queue counter remains inside ALU for queue maintenance
    // and verification only; it cannot enter EX arithmetic or OF backpressure.
    assign ex_mul_queue_select = mul_result_queue_select;
    assign mul_result_data =
        (mul_queue_head_data & mul_result_queue_select_mask) |
        (mul_complete_result_data & ~mul_result_queue_select_mask);
    // These buses feed forwarding-only arithmetic in OF.  Keep them on the
    // OF/EX payload registers: putting either load_result_valid or a late-load
    // dependency tag in front of a 32-bit carry chain recreates a cross-stage
    // critical path.  The two measured late-Load hot operations are handled
    // below by parallel result candidates and a short post-operation mux.
    wire [31:0] ex_nonmul_rD1 = ex_rD1_raw;
    wire [31:0] ex_nonmul_rD2 = ex_rD2_raw;
    assign ex_exec_alu_op = ex_alu_op;
    assign ex_exec_A      = ex_alu_A;
    assign ex_exec_B      = ex_alu_B;
    assign ex_exec_add_wd = ex_raw_alu_A + ex_raw_alu_B;
    assign ex_exec_sll_wd = ex_raw_alu_A << ex_raw_alu_B[4:0];
    assign ex_exec_srl_wd = ex_raw_alu_A >> ex_raw_alu_B[4:0];
    wire [31:0] ex_raw_xor_wd =
        ex_raw_alu_A ^ ex_raw_alu_B;
    wire [31:0] ex_load_r1_xor_wd =
        load_result_data ^ ex_raw_alu_B;
    wire [31:0] ex_load_r2_xor_wd =
        ex_raw_alu_A ^ load_result_data;
    // Select after the XOR LUTs.  A two-source match names the same older
    // Load destination, so both operands equal load_result_data and XOR to 0.
    assign ex_exec_xor_wd =
        ex_load_dep_r1 ?
            (ex_load_dep_r2 ? 32'b0 : ex_load_r1_xor_wd) :
            (ex_load_dep_r2 ? ex_load_r2_xor_wd : ex_raw_xor_wd);
    assign ex_exec_and_wd = ex_raw_alu_A & ex_raw_alu_B;
    assign ex_exec_registered_operands =
        !(ex_load_dep_r1 || ex_load_dep_r2 ||
          ex_mul_dep_r1 || ex_mul_dep_r2);
    // This registered bit names the only zero-bubble late-MUL forwarding
    // shape retained below (MUL.W -> ADD.W through rj).  It is captured with
    // the OF/EX payload so the live dependency-tag OR/decode cannot enter the
    // next instruction's operand register cone.
    assign ex_exec_mul_late = ex_mul_r1_add_fast_r;
    assign ex_exec_nonmul_A = ex_alua_sel ? ex_nonmul_rD1 : ex_pc;
    assign ex_exec_nonmul_B = ex_alub_sel ? ex_nonmul_rD2 : ex_ext;
    assign ex_exec_nonmul_sll_wd =
        ex_exec_nonmul_A << ex_exec_nonmul_B[4:0];
    // CRYPTONIGHT's registered Load result feeds SLLI.W #1 once per loop.
    // Shift-by-one is wiring, so compute the possible late-result sources in
    // parallel and select after that wiring instead of placing a late operand
    // mux in front of a five-level barrel shifter.
    wire [31:0] ex_raw_sll1_wd = {ex_rD1_raw[30:0], 1'b0};
    wire [31:0] ex_load_sll1_wd = {load_result_data[30:0], 1'b0};
    assign ex_exec_sll1_wd =
        ex_load_dep_r1 ? ex_load_sll1_wd :
                         ex_raw_sll1_wd;
    // Full-image profiling proves that all 1,048,576 recurrent late-MUL
    // operations are MUL.W -> ADD.W with the dependency in rj (r1); r2 count
    // is zero.  Feed that hot candidate directly into each carry chain.  Rare
    // r2/both-source late-MUL consumers remain architecturally supported by
    // the normal EX result path but are forwarded from M1 instead of creating
    // a dependency-tag mux in front of the adder.
    // ex_exec_mul_late is asserted only for the registered
    // MUL.W -> ADD.W(rj) shape.  Its A operand is therefore unconditionally
    // the completed multiply result.  Keeping ex_alua_sel in these dedicated
    // candidates placed that control mux in front of all four carry chains
    // and then into the following instruction's OF/EX operand register.
    assign ex_exec_mul_queue_A = mul_queue_head_data;
    assign ex_exec_mul_queue_B =
        ex_alub_sel ? ex_rD2_raw : ex_ext;
    assign ex_exec_mul_bypass_A = mul_complete_result_data;
    assign ex_exec_mul_bypass_B =
        ex_alub_sel ? ex_rD2_raw : ex_ext;
    assign ex_mul_bypass_low_select = mul_complete_low_select;
    assign ex_exec_mul_bypass_low_A  = mul_complete_low_data;
    assign ex_exec_mul_bypass_high_A = mul_complete_high_data;
    // Effective address and Store/Load ordering key are generated in OF and
    // cross the OF/EX boundary as registered values.  EX does not recompute
    // rj+immediate.
    // Forwarding shadow aligned with the OF/EX payload.  Its value is valid
    // for every ordinary non-Load/non-MUL producer without a late operand.
    // The existing ex_slow_result tag selects the operation-local path for the
    // exceptional late-result case, so invalid shadows are never consumed.
    reg         ex_shadow_valid_r;
    reg  [ 2:0] ex_shadow_class_r;
    reg  [31:0] ex_shadow_addsub_wd_r;
    reg  [31:0] ex_shadow_logic_wd_r;
    reg  [31:0] ex_shadow_shift_wd_r;
    reg  [31:0] ex_shadow_compare_wd_r;
    reg  [31:0] ex_shadow_simple_wd_r;
    reg  [31:0] ex_shadow_pc4_wd_r;
    reg  [31:0] ex_control_shadow_wd_r;
    reg         ex_sll_by_one_r;
    reg         ex_data_forward_ready_r;
    reg         ex_control_forward_ready_r;
    reg         ex_memory_forward_ready_r;
    wire id_exec_load_late = id_load_dep_r1 || id_load_dep_r2;
    wire id_exec_mul_late = id_mul_dep_r1 || id_mul_dep_r2;
    wire id_is_mul_op = (id_alu_op == `ALU_MUL) ||
                        (id_alu_op == `ALU_MULH) ||
                        (id_alu_op == `ALU_MULHU);
    wire id_sll_by_one =
        (id_alu_op == `ALU_SLL) &&
        (id_alub_sel == `ALUB_EXT) &&
        (id_ext[4:0] == 5'd1);
    // Dynamic full-image profiling found the recurrent late-Load chains to be
    // Load->SLLI.W #1->XOR (CRYPTONIGHT) and Load->XOR (MIXED).
    // Preserve those zero-bubble paths with the short post-operation selects
    // above.  Other rare late-Load ALU producers become forwardable from M1,
    // avoiding a dependency-tag -> carry/barrel-shifter -> next-OF path.
    wire id_load_fast_forward =
        (id_alu_op == `ALU_XOR) || id_sll_by_one;
    // Only the result already computed in OF may become the registered EX
    // shadow.  The former M2/late-EX AND repair recomputed AND from the final
    // operands on this edge.  For ADD -> AND it joined the live ADD carry
    // chain and the AND gate before these registers, recreating a complete
    // two-operation path in one 150 MHz cycle.  The architectural EX ALU and
    // its ordinary short forwarding path remain unchanged; only this optional
    // speculative shadow is suppressed when OF marked it unsafe.
    wire id_supported_shadow =
        id_shadow_valid && (id_shadow_class != `SHADOW_NONE);
    wire id_fast_shadow_valid = id_supported_shadow;
    wire [ 2:0] id_effective_shadow_class = id_shadow_class;
    wire [31:0] id_effective_logic_wd = id_shadow_logic_wd;
    // Keep the variable-shift candidate on its own final arm.  Folding SHIFT
    // into the general six-way class mux made the barrel-shifter result cross
    // an extra LUT6/MUXF7 before the control-shadow register.
    (* keep = "true" *) reg [31:0] id_control_shadow_nonshift_wd;
    always @(*) begin
        case (id_effective_shadow_class)
            `SHADOW_ADDSUB : id_control_shadow_nonshift_wd = id_shadow_addsub_wd;
            `SHADOW_LOGIC  : id_control_shadow_nonshift_wd = id_effective_logic_wd;
            `SHADOW_COMPARE: id_control_shadow_nonshift_wd = id_shadow_compare_wd;
            `SHADOW_SIMPLE : id_control_shadow_nonshift_wd = id_shadow_simple_wd;
            `SHADOW_PC4    : id_control_shadow_nonshift_wd = id_shadow_pc4_wd;
            default        : id_control_shadow_nonshift_wd = 32'b0;
        endcase
    end
    wire [31:0] id_control_shadow_wd =
        (id_effective_shadow_class == `SHADOW_SHIFT)
        ? id_shadow_shift_wd : id_control_shadow_nonshift_wd;
`ifndef SYNTHESIS
    reg [31:0] id_control_shadow_reference;
    always @(*) begin
        case (id_effective_shadow_class)
            `SHADOW_ADDSUB : id_control_shadow_reference = id_shadow_addsub_wd;
            `SHADOW_LOGIC  : id_control_shadow_reference = id_effective_logic_wd;
            `SHADOW_SHIFT  : id_control_shadow_reference = id_shadow_shift_wd;
            `SHADOW_COMPARE: id_control_shadow_reference = id_shadow_compare_wd;
            `SHADOW_SIMPLE : id_control_shadow_reference = id_shadow_simple_wd;
            `SHADOW_PC4    : id_control_shadow_reference = id_shadow_pc4_wd;
            default        : id_control_shadow_reference = 32'b0;
        endcase
    end
    always @(posedge cpu_clk) begin
        if (cpu_rstn && id_accept && id_fast_shadow_valid &&
            (id_control_shadow_wd !== id_control_shadow_reference))
            $fatal(1, "split control-shadow mux differs from legacy case");
    end
`endif
    wire id_operation_forward_path =
        id_fast_shadow_valid ||
        (id_alu_op == `ALU_ADD) ||
        (id_alu_op == `ALU_AND) ||
        (id_alu_op == `ALU_SLL) ||
        (id_alu_op == `ALU_SRL) ||
        (id_alu_op == `ALU_XOR);
    // The dedicated late-MUL ADD candidate uses the saved r2 operand.  It is
    // valid only when no Load result must replace either operand in EX.
    // Mixed MUL/Load dependencies stay on the generic ALU path and are not
    // advertised as an EX-forwardable specialized result.
    wire id_mul_r1_add_fast_shape =
        (id_wd_sel == `WD_ALU) &&
        (id_alu_op == `ALU_ADD) &&
        id_mul_dep_r1 && !id_mul_dep_r2 &&
        !id_exec_load_late;
    wire id_data_forward_ready =
        (id_wd_sel != `WD_RAM) && !id_is_mul_op &&
        id_operation_forward_path &&
        (!id_exec_mul_late || id_mul_r1_add_fast_shape) &&
        (!id_exec_load_late || id_load_fast_forward);
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            ex_shadow_valid_r <= 1'b0;
            ex_shadow_class_r <= `SHADOW_NONE;
            ex_sll_by_one_r    <= 1'b0;
            ex_mul_r1_add_fast_r <= 1'b0;
            ex_data_forward_ready_r    <= 1'b0;
            ex_control_forward_ready_r <= 1'b0;
            ex_memory_forward_ready_r  <= 1'b0;
        end else if (!(pl_suspend | early_load_hold)) begin
            ex_shadow_valid_r <= id_accept && id_fast_shadow_valid;
            ex_shadow_class_r <= id_effective_shadow_class;
            // All operation candidates cross the boundary independently.
            // Data is ignored while ex_shadow_valid_r is clear; no valid or
            // opcode-class mux is therefore present on these wide D inputs.
            ex_shadow_addsub_wd_r <= id_shadow_addsub_wd;
            ex_shadow_logic_wd_r <= id_effective_logic_wd;
            ex_shadow_shift_wd_r   <= id_shadow_shift_wd;
            ex_shadow_compare_wd_r <= id_shadow_compare_wd;
            ex_shadow_simple_wd_r  <= id_shadow_simple_wd;
            ex_shadow_pc4_wd_r     <= id_shadow_pc4_wd;
            // Branch and JIRL use this direct duplicate, so the following
            // cycle's target/compare cone never sees ex_shadow_class_r.
            ex_control_shadow_wd_r <= id_control_shadow_wd;
            ex_sll_by_one_r    <= id_accept && id_sll_by_one;
            ex_mul_r1_add_fast_r <=
                id_accept && id_exec_mul_late &&
                id_mul_r1_add_fast_shape;
            ex_data_forward_ready_r <= id_accept &&
                                       id_data_forward_ready;
            ex_control_forward_ready_r <=
                id_accept && id_data_forward_ready &&
                id_fast_shadow_valid;
            ex_memory_forward_ready_r <=
                id_accept && id_data_forward_ready &&
                (id_fast_shadow_valid ||
                 ((id_wd_sel == `WD_ALU) &&
                  ((id_alu_op == `ALU_ADD) ||
                   (id_sll_by_one && !id_exec_mul_late))));
        end
    end
    reg [31:0] ex_shadow_wd_mux;
    always @(*) begin
        case (ex_shadow_class_r)
            `SHADOW_ADDSUB : ex_shadow_wd_mux = ex_shadow_addsub_wd_r;
            `SHADOW_LOGIC  : ex_shadow_wd_mux = ex_shadow_logic_wd_r;
            `SHADOW_SHIFT  : ex_shadow_wd_mux = ex_shadow_shift_wd_r;
            `SHADOW_COMPARE: ex_shadow_wd_mux = ex_shadow_compare_wd_r;
            `SHADOW_SIMPLE : ex_shadow_wd_mux = ex_shadow_simple_wd_r;
            `SHADOW_PC4    : ex_shadow_wd_mux = ex_shadow_pc4_wd_r;
            default        : ex_shadow_wd_mux = 32'b0;
        endcase
    end
    assign ex_mul_fwd_wd = ex_shadow_wd_mux;
    assign ex_control_fwd_wd = ex_control_shadow_wd_r;
    assign ex_fast_result_valid = ex_shadow_valid_r;
    assign ex_data_forward_ready = ex_data_forward_ready_r;
    assign ex_control_forward_ready = ex_control_forward_ready_r;
    assign ex_memory_forward_ready = ex_memory_forward_ready_r;
    assign ex_exec_sll_by_one = ex_sll_by_one_r;
`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ex_valid && ex_control_forward_ready_r &&
            !ex_shadow_valid_r)
            $fatal(1, "EX control-forward ready without registered shadow");
        if (cpu_rstn && ex_valid && ex_mul_r1_add_fast_r &&
            ((ex_wd_sel != `WD_ALU) || (ex_alu_op != `ALU_ADD) ||
             !ex_mul_dep_r1 || ex_mul_dep_r2 ||
             ex_load_dep_r1 || ex_load_dep_r2))
            $fatal(1, "late-MUL ADD fast tag is not operand-complete");
        if (cpu_rstn && ex_valid &&
            (ex_mul_dep_r1 || ex_mul_dep_r2) &&
            !ex_mul_r1_add_fast_r)
            $fatal(1, "unsupported late-MUL shape crossed OF boundary");
    end
`endif
    // A branch/JIRL arrives here only after ID2 has selected its final
    // forwarded operands; Load-dependent control flow is held until the
    // registered Load result can be captured at ID/EX.  Keep the late branch
    // cone on those ID/EX registers instead of the live EX Load refresh mux.
    // This removes load_result_valid -> branch correction -> M1 predecode
    // without changing branch issue timing or architectural data.
    // ID1 already computed and registered the PC-relative target.
    wire [31:0] id_pc_target = id_target_ext;
    wire [31:0] ex_pc_target;
    wire [31:0] ex_jirl_target = ex_rD1_raw + ex_ext;
    assign ex_taken_target =
        (ex_npc_op == `NPC_JMPREG) ? ex_jirl_target : ex_pc_target;
    assign ex_sel_ram  = ex_valid & (ex_wd_sel == `WD_RAM) & ex_rf_we;  
    
    // -------------------------------------------------------------------------
    // 乘除法暂停控制
    // -------------------------------------------------------------------------
    // Multiply now has initiation interval one.  These verification-visible
    // names mark ordered result availability/retirement but never freeze the
    // front end or the unrelated architectural stages.
    wire mul_done = mul_result_take;
    wire ex_is_mul_div_doing = mul_result_valid;

    assign ex_is_mul_div = ex_valid &
        ((ex_alu_op == `ALU_MUL)   |
         (ex_alu_op == `ALU_MULH)  |
         (ex_alu_op == `ALU_MULHU));
    // -------------------------------------------------------------------------
    // ID/EX流水寄存器
    // -------------------------------------------------------------------------
    ID_EX u_ID_EX (
        .cpu_clk        (cpu_clk),
        .cpu_rstn       (cpu_rstn),
        .suspend        (pl_suspend | early_load_hold),
        // Independent branches resolve in ID2.  A branch that consumes a live
        // EX/M1/M2 result carries its already-forwarded operands across this
        // boundary and is confirmed locally in EX instead of stalling ID2.
        .valid_in       (id_accept),

        .wR_in          (id_wR),
        .pc_in          (id_pc),
        .rD1_in         (id_real_rD1),
        .rD2_in         (id_real_rD2),
        .load_dep_r1_in (id_load_dep_r1),
        .load_dep_r2_in (id_load_dep_r2),
        .mul_dep_r1_in  (id_mul_dep_r1),
        .mul_dep_r2_in  (id_mul_dep_r2),
        .ext_in         (id_ext),
        .mem_addr_in    (id_mem_addr),
        .order_addr_key_in(id_order_addr_key),
        .taken_target_in(id_pc_target),
        .pred_taken_in  (id_pred_taken),
        .pred_target_in (id_pred_target),

        .npc_op_in      (id_npc_op),
        .rf_we_in       (id_rf_we & id_valid),
        .wd_sel_in      (id_wd_sel),
        .alu_op_in      (id_alu_op & {5{id_valid}}),
        .alua_sel_in    (id_alua_sel),
        .alub_sel_in    (id_alub_sel),
        .ram_we_in      (id_ram_we & {4{id_valid}}),
        .ram_ext_op_in  (id_ram_ext_op),
        .is_br_jmp_in   (id_is_br_jmp & id_valid),
        .branch_deferred_in(id_branch_deferred & id_valid),
        .is_call_in     (id_is_call & id_valid),
        .is_return_in   (id_is_return & id_valid),

        .valid_out      (ex_valid),
        .wR_out         (ex_wR),
        .pc_out         (ex_pc),
        .rD1_out        (ex_rD1_raw),
        .rD2_out        (ex_rD2_raw),
        .load_dep_r1_out(ex_load_dep_r1),
        .load_dep_r2_out(ex_load_dep_r2),
        .mul_dep_r1_out (ex_mul_dep_r1),
        .mul_dep_r2_out (ex_mul_dep_r2),
        .ext_out        (ex_ext),
        .mem_addr_out   (ex_mem_addr),
        .order_addr_key_out(ex_order_addr_key),
        .taken_target_out(ex_pc_target),
        .pred_taken_out (ex_pred_taken),
        .pred_target_out(ex_pred_target),

        .npc_op_out     (ex_npc_op),
        .rf_we_out      (ex_rf_we),
        .wd_sel_out     (ex_wd_sel),
        .alu_op_out     (ex_alu_op),
        .alua_sel_out   (ex_alua_sel),
        .alub_sel_out   (ex_alub_sel),
        .ram_we_out     (ex_ram_we),
        .ram_ext_op_out (ex_ram_ext_op),
        .is_br_jmp_out  (ex_is_br_jmp),
        .branch_deferred_out(ex_branch_deferred),
        .is_call_out    (ex_is_call),
        .is_return_out  (ex_is_return)
    );

    // -------------------------------------------------------------------------
    // ALU执行单元
    // -------------------------------------------------------------------------
    wire id_mul_issue = id_accept & !pl_suspend &
                        ((id_alu_op == `ALU_MUL)   |
                         (id_alu_op == `ALU_MULH)  |
                         (id_alu_op == `ALU_MULHU));
    ALU u_ALU (
        .cpu_rstn   (cpu_rstn    ),
        .cpu_clk    (cpu_clk     ),
        .alu_op     (ex_alu_op   ),
        .A          (ex_alu_A    ),
        .B          (ex_alu_B    ),
        .mul_issue  (id_mul_issue),
        .mul_issue_op(id_alu_op  ),
        .mul_issue_A(id_mul_rD1  ),
        .mul_issue_B(id_mul_rD2  ),
        .mul_result_take(mul_result_take),
        .is_br_jmp  (ex_is_br_jmp),
        .C          (ex_alu_C    ),
        .f          (ex_alu_f    ),
        .mul_result_valid(mul_result_valid),
        .mul_result_data(mul_result_data_live),
        .mul_queue_select(mul_queue_select_live),
        .mul_queue_head_data(mul_queue_head_data),
        .mul_complete_result_data(mul_complete_result_data),
        .mul_complete_low_select(mul_complete_low_select),
        .mul_complete_low_data(mul_complete_low_data),
        .mul_complete_high_data(mul_complete_high_data),
        .mul_result_next_valid(mul_result_next_valid),
        .mul_queue_select_next(mul_queue_select_next)
    );


    // -------------------------------------------------------------------------
    // 分支结果、写回数据和访存对齐检查
    // -------------------------------------------------------------------------
    wire ex_r_eq      = (ex_rD1_raw == ex_rD2_raw);
    wire ex_r_slt     = ($signed(ex_rD1_raw) < $signed(ex_rD2_raw));
    wire ex_r_sltu    = (ex_rD1_raw < ex_rD2_raw);
    wire ex_br_taken_raw =
                (ex_alu_op == `ALU_SUB)  ? ex_r_eq    :
                (ex_alu_op == `ALU_BNE)  ? !ex_r_eq   :
                (ex_alu_op == `ALU_SLT)  ? ex_r_slt   :
                (ex_alu_op == `ALU_BGE)  ? !ex_r_slt  :
                (ex_alu_op == `ALU_SLTU) ? ex_r_sltu  :
                (ex_alu_op == `ALU_BGEU) ? !ex_r_sltu :
                (ex_alu_op == `ALU_B)    ? 1'b1       :
                (ex_alu_op == `ALU_JIRL) ? 1'b1       : 1'b0;
    assign ex_br_jmp_f = ex_valid && ex_is_br_jmp && ex_br_taken_raw;
    
    always @(*) begin
        case (ex_wd_sel)
            `WD_CSR: ex_wd = ex_ext;
            `WD_ALU: ex_wd = ex_alu_C;
            `WD_PC4 : ex_wd = ex_pc + 4;
            default: ex_wd = 32'b0;
        endcase
    end

    // 检查访存地址是否关于 待访问数据大小 对齐, 不对齐则不访存
    always @(*) begin
        case (ex_ram_we)
            default:
                case (ex_ram_ext_op)
                    `RAM_EXT_H : ldst_unalign = (ex_mem_addr[1:0] != 2'h0) & (ex_mem_addr[1:0] != 2'h2);
                    default    : ldst_unalign = 1'b0;
                endcase
        endcase
    end

endmodule

