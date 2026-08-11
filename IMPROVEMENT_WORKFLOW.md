# 双发射改进流程：基于四项基准的针对性性能提升方案

日期：2026-08-11
设计基线：F0（WNS +0.010ns, 150MHz）
约束文件：`run_vivado/constraints/thinpad_top.xdc`

---

## 一、当前架构总览与关键约束

### 1.1 流水线结构

```
IF → ID1/ID2 → OF(operand fetch) → EX → EX2(M1) → MEM(M2) → WB
     ↑ BPU(128-entry BHT) + RAS(8-entry)
     ↑ IBUF(4-entry FIFO, 双pop能力)
     ↑ restricted_slot1_lane (已存在但配对范围极窄)
```

关键模块：
- `myCPU.v`: 顶层流水线控制、双发射配对逻辑、Store Buffer、依赖标签
- `IF_stage.v`: 取指控制 + PC
- `ID_stage.v`: ID1译码 + ID2配对选择 + RF读取
- `OF_stage.v`: 操作数获取 + 分支解析 + 前递影子寄存器
- `EX_stage.v`: ALU执行 + 乘法队列接口
- `EX2_stage.v`: M1访存请求 + 乘法结果收集
- `MEM_stage.v`: 访存等待/完成
- `WB_stage.v`: 写回选择
- `restricted_slot1_lane.v`: 槽1窄ALU通道（OF→EX→M1→M2→WB）
- `slot1_narrow_decode.v`: 槽1指令资格解码（仅普通整数ALU）
- `DCache.v`: 数据Cache（32行×8字，写通/写分配）
- `ICache.v`: 指令Cache
- `BPU.v`: 分支预测（128-entry直接映射BHT，2-bit饱和计数器）
- `Store Buffer`: 4-entry有序写缓冲（F0唯一保留的性能改动）

### 1.2 关键时序约束

| 指标 | 值 |
|---|---|
| 目标频率 | 150 MHz (6.667ns周期) |
| F0 WNS | +0.010 ns |
| F0 TNS | 0 |
| F0 failing endpoints | 0 |
| 可用时序余量 | **仅 +0.010ns，约0.15% 的周期** |

这意味着：**任何增加关键路径的改动都必须同时减少至少等量的其他逻辑层数。**

### 1.3 当前双发射状态

代码中已存在完整的窄双发射基础设施：
- `restricted_slot1_lane.v`：槽1独立流水线
- `slot1_narrow_decode.v`：槽1指令解码器
- `IBUF.v`：支持双pop（ENABLE_POP2参数）
- `myCPU.v`：完整的pair_issue判断逻辑

但配对条件极其严格：
```verilog
wire pair_accept = ibuf_valid && ibuf_valid2 && s1_dec_eligible &&
                   id_pair_class_ok && !ibuf_pred_taken &&
                   ibuf_seq_from_prev &&
                   !pair_raw && !pair_waw && !pair_next_raw &&
                   !s1_old_producer_block;
```

槽1只接受：ADD/SUB/AND/OR/XOR/NOR/SLL/SRL/SRA/SLT/SLTU + ADDI/ANDI/ORI/XORI/SLTI/SLTUI + SLLI/SRLI/SRAI + LU12I.W + PCADDU12I

---

## 二、四项基准的动态瓶颈分析

基于 `four_official_benchmarks_instruction_sequence.md` 的静态指令布局和动态骨架：

### 2.1 STREAM（顺序拷贝3MiB）

```
动态骨架：LD.W → ST.W → ADDI.W → ADDI.W → BNE（循环786,432次）
```

| 瓶颈 | 根因 | 双发射是否有帮助 |
|---|---|---|
| 每轮5条指令，强RAW依赖 | LD→ST必须等待，ADDI之间RAW | 窄双发射无法配对任何对 |
| 单LSU瓶颈 | LD和ST共享一个LSU端口 | 即使双发射也无法解决 |
| Store背压 | 连续ST.W填满Store Buffer | **4-entry SB已缓解（F0）** |

**结论：STREAM对双发射基本免疫。瓶颈在访存带宽和LSU数量。**

### 2.2 MATRIX（96³的四元素展开乘加）

```
最内层循环展开：
  LD.W(B)×4 → LD.W(C)×4 → MUL.W×4 → ADD.W×4 → ST.W×4
  共20条指令，884,736次MUL.W
```

| 瓶颈 | 根因 | 双发射是否有帮助 |
|---|---|---|
| MUL.W×4 连续乘法 | 单乘法器串行化 | **槽1乘法在旧谱系中减少470,266 cycles** |
| LD.W批次 | 可流水但受DCache命中率限制 | 双发射不能并行两个Load |
| ADD.W依赖MUL结果 | RAW依赖 | 前递已足够（OF影子寄存器） |

**结论：MATRIX是双发射最有潜力的目标。关键机会是让槽1执行MUL.W。**

### 2.3 CRYPTONIGHT（随机读改写）

```
每轮：AND → SLLI.W → ADD.W → LD.W → SRLI.W → SLLI.W → XOR → AND → XOR → SLLI.W → ST.W → ADD.W → LD.W → OR → MUL.W → ADDI.W → ADD.W → ST.W → XOR → BNE
共19条指令，循环1,048,576次
```

| 瓶颈 | 根因 | 双发射是否有帮助 |
|---|---|---|
| 长依赖链 | XOR→AND→SLLI→ADD→LD→... 每个结果都是下一个的输入 | 即使双ALU也无法并行化 |
| 随机LD地址 | LD.W依赖上一个XOR结果 | 地址计算依赖必须等待 |
| 单MUL | 每轮一个MUL.W | 1,048,576次乘法的总耗时有限 |

**结论：CRYPTONIGHT的指令间依赖极深，双发射增加ALU数量几乎无帮助。重点是减少访存延迟。**

### 2.4 MIXED（初始化+归约+随机分支）

```
前半段：LD.W×4 → ADD/XOR×4 → ST.W×4（4,096次，四路独立）
后半段：AND → SLLI.W → ADD.W → LD.W → XOR×3 → ANDI → BEQ → ADD/XOR → ST.W → ADDI.W → BNE（8,192次）
```

| 瓶颈 | 根因 | 双发射是否有帮助 |
|---|---|---|
| 前半段四路归约 | 四路独立ADD/XOR可并行 | 窄双发射可配对ADD/XOR |
| 后半段分支 | BEQ 50%概率，BPU已预测 | 分支预测错误有代价 |
| 数据依赖xorshift | XOR链不可并行 | 双ALU无帮助 |

**结论：MIXED前半段有机会受益于双ALU配对，后半段受限于依赖链和分支。**

---

## 三、为什么五类修改全部被退回——精确诊断

从 `dual_issue_five_modifications_gain_analysis.md` 中提取关键教训：

| 路线 | 核心问题 | 根本原因 |
|---|---|---|
| 槽1乘法 | 周期收益明确(+3.1ms)但未完成时序验收 | 不是在F0上做的，需要重新移植 |
| 4-entry Store Buffer | **已保留，是F0的唯一性能收益(+4.4ms)** | — |
| 槽1 Store配对 | 零增量 | 单LSU+已充分的SB吸收 |
| 两宽前端 | 周期收益极小(+0.038ms)，频率代价巨大(WNS -0.927ns) | IBUF已有双pop，`candidate_absent`仅406次 |
| 双ALU/steering | 零增量（三轮） | 只加了前递没改配对集合，lane steering未实现 |
| 完成队列/Scoreboard | 零增量（基础设施），WNS -0.346ns | 没有可变延迟结果可利用 |

### 核心教训

1. **先有瓶颈，再解瓶颈。** 不是"做了双发射结构自然快"，而是"找到程序的真实串行化点，定向解除"。
2. **时序余量是硬通货。** F0只有+0.010ns，任何新增逻辑必须伴随等量优化。
3. **监控数据驱动决策。** 不要用decode拒绝总数推断收益，要用实际可新增的配对计数。

---

## 四、改进流程设计（四阶段）

### 阶段0：基线确认与监控增强（第1-2天）

#### Step 0.1：在当前workspace构建并确认F0基线
```bash
# 1. 创建Vivado项目
vivado -mode batch -source run_vivado/flow/create_vivado_project.tcl

# 2. 运行综合+实现
vivado -mode batch -source run_vivado/flow/implement_design.tcl

# 3. 检查时序
grep -A5 "Design Timing Summary" project/thinpad_top.runs/impl_1/timing_summary.rpt
```

验证：确认WNS ≥ 0，TNS = 0，所有四项测试PASS。

#### Step 0.2：增加动态配对机会计数器

在 `myCPU.v` 中增加仿真可见的16-bit计数器，记录被每个条件拒绝的候选配对次数。这些计数器**不在综合路径上**（使用 `ifndef SYNTHESIS`）：

```verilog
`ifndef SYNTHESIS
// Pairing opportunity diagnostics (simulation only, zero hardware cost)
reg [15:0] diag_pair_candidate_total;     // 总候选配对周期数
reg [15:0] diag_reject_not_eligible;      // B指令不在槽1白名单
reg [15:0] diag_reject_class_ok;          // A指令不允许配对
reg [15:0] diag_reject_pred_taken;        // B是预测跳转的目标
reg [15:0] diag_reject_not_seq;           // B不是A的顺序后继
reg [15:0] diag_reject_raw;               // A写B读 (RAW)
reg [15:0] diag_reject_waw;               // A和B写同一寄存器 (WAW)
reg [15:0] diag_reject_next_raw;          // B写C读 (链式RAW)
reg [15:0] diag_reject_old_producer;      // B依赖槽0/槽1旧生产者
reg [15:0] diag_pair_accepted;            // 实际接受的配对
reg [15:0] diag_slot1_mul_would_help;     // 如果槽1支持MUL，这里可以配对
reg [15:0] diag_slot1_load_would_help;    // 如果槽1支持Load，这里可以配对
reg [15:0] diag_slot1_store_would_help;   // 如果槽1支持Store，这里可以配对

always @(posedge cpu_clk) begin
    if (!cpu_rstn) begin
        // ... reset all to 0
    end else if (id_waiting && ibuf_valid && !pl_suspend) begin
        diag_pair_candidate_total <= diag_pair_candidate_total + 1'b1;

        if (!s1_dec_eligible) begin
            diag_reject_not_eligible <= diag_reject_not_eligible + 1'b1;
            // 子分类：如果可以MUL/Load/Store...
            if (slot1_mul_decode_eligible)  // MUL.W/MULH.W/MULH.WU
                diag_slot1_mul_would_help <= diag_slot1_mul_would_help + 1'b1;
            if (slot1_load_decode_eligible) // LD.B/LD.H/LD.W/LD.BU/LD.HU
                diag_slot1_load_would_help <= diag_slot1_load_would_help + 1'b1;
            if (slot1_store_decode_eligible) // ST.B/ST.H/ST.W
                diag_slot1_store_would_help <= diag_slot1_store_would_help + 1'b1;
        end
        // ... similar for other rejection reasons
    end
end
`endif
```

**关键：** 每项测试运行结束后，dump这些计数器。这给出了**精确的**优化优先级排序。

---

### 阶段1：槽1乘法（优先级最高，第3-5天）

#### 为什么这个方向最有价值？

- MATRIX有884,736次MUL.W，且为四连发批次
- 旧谱系Phase 4A实验：-470,266 cycles（约+3.135ms @150MHz）
- 当前F0槽1窄解码已将MUL排除在外
- 乘法器已在硅中（DSP48），只是被限制在槽0

#### Step 1.1：扩展槽1解码器支持MUL

在 `slot1_narrow_decode.v` 中增加MUL指令识别：

```verilog
// 新增信号
wire mul_w   = (inst[31:15] == 17'h00038);
wire mulh_w  = (inst[31:15] == 17'h00039);
wire mulh_wu = (inst[31:15] == 17'h0003A);
wire type_mul = mul_w | mulh_w | mulh_wu;

// 扩展 eligible
assign eligible = type_3r | type_2ri5 | type_2ri12 |
                  lu12i_w | pcaddu12i | type_mul;
```

#### Step 1.2：槽1乘法数据通路

乘法器(MULT_GEN)有一个输入寄存器阶段。当前 `myCPU.v` 中：
```verilog
assign mul_result_take = mem_valid && mem_is_mul &&
                         m2_mul_result_ready_r && !base_pipeline_suspend;
```

槽1乘法需要：
1. 操作数从槽1的 `of_rD1_r/of_rD2_r` 获取（已有）
2. 共享乘法器队列入口（需要新增一个mux）
3. 结果在M2阶段写回到槽1的WB路径

**关键时序风险：** 乘法器输入mux会增加DSP48的data path。但由于DSP48有内部寄存器，可以在OF→EX边界寄存操作数后送入乘法器，不影响关键路径。

#### Step 1.3：依赖关系处理

- **同对RAW（A写→B读MUL源）**: 必须禁止（`pair_raw`已覆盖）
- **槽1 MUL结果被后续指令消费**: 已有 `pending_older_busy` 和 `s1_m*_producer` 跟踪
- **乘法器队列冲突**: 槽0和槽1共享队列，需要round-robin仲裁或年龄优先

#### Step 1.4：时序验证

```bash
# 实现并检查WNS
vivado -mode batch -source run_vivado/flow/implement_design.tcl
grep "WNS" project/thinpad_top.runs/impl_1/timing_summary.rpt
```

**盈亏平衡频率：** 若槽1乘法增加的关键路径延迟为ΔT：
- 需要 f_new × (T_old - Δcycles × T_old) > f_old × T_old
- 即：150MHz下Δcycles只需 470,266/54,496,309 ≈ 0.86%
- 频率只需 > 150 × (1-0.0086) ≈ 148.7 MHz 即有正收益

如果WNS变为负值，先尝试物理优化后仍不满足，再回退。

---

### 阶段2：基于监控数据的定向配对扩展（第6-8天）

#### Step 2.1：运行阶段0的诊断计数器

四项测试各运行一次，收集 `diag_*` 计数器值。预期发现：

| 计数器 | MATRIX预期 | CRYPTONIGHT预期 | MIXED预期 |
|---|---|---|---|
| `diag_reject_not_eligible` | 高（连续MUL） | 中 | 低 |
| `diag_reject_raw` | 低 | 高 | 中 |
| `diag_reject_next_raw` | 中 | 高 | 中 |
| `diag_reject_old_producer` | 中 | 高 | 中 |
| `diag_pair_accepted` | 低→中（加入MUL后） | 低 | 中 |

#### Step 2.2：根据计数器优先级决策

```
if diag_slot1_mul_would_help > 0:
    → 已完成阶段1
if diag_reject_next_raw 占比 > 30%:
    → 这是最大瓶颈，但解除需要更复杂的旁路网络
    → 先尝试有限解除：仅当C的消费是"已在WB可用的值"时放行
if diag_reject_old_producer 占比 > 20%:
    → 说明有大量指令等待M2/WB结果
    → 已有OF影子寄存器缓解，进一步需要增加写端口
```

#### Step 2.3：可选的有限解除

**解除 `pair_next_raw` 的保守限制（仅在C读x0或C读的值已知在WB时）：**

当前：
```verilog
wire pair_next_raw = ibuf_raw_from_prev2; // B写C读，无条件禁止
```

改进：
```verilog
// 仅当C确实依赖B的结果且B的结果尚未可用时才禁止
wire c_reads_x0 = (ibuf_inst2[9:5] == 5'd0) && (ibuf_inst2[14:10] == 5'd0);
wire c_reads_b_result = ibuf_raw_from_prev2;
wire pair_next_raw = c_reads_b_result && !c_reads_x0;
```

---

### 阶段3：Cache/访存定向优化（第9-12天）

四项测试中STREAM和MATRIX有大量连续访存模式。这是不增加双发射复杂度的纯收益方向。

#### Step 3.1：硬件预取（针对连续访问模式）

STREAM的 `LD.W → ST.W → ADDI.W+4` 和 MATRIX的 `LD.W×4(间隔16字节)` 都有明确的步长模式。

在DCache中增加简单的next-line预取：
- 记录最近两次Load地址的差值
- 若连续两次差值相同，预取下一行
- 预取请求优先级低于demand请求
- 预取仅对BaseRAM地址空间有效

**预期收益：** 减少MATRIX的DCache miss惩罚（每次miss ~8 cycles → 0 cycles若预取命中）

#### Step 3.2：非对齐访问的硬件支持

STREAM拷贝3MiB按4字节对齐，但若地址非对齐则会触发异常。确认当前是否已有非对齐支持。

#### Step 3.3：Load-to-Use延迟优化

当前Load结果在DCache返回后还需一个周期寄存（`daccess_valid_r`），这对STREAM的 `LD.W → ?` 模式造成额外延迟。

检查是否可以：当Load命中DCache时，数据在同一周期即可被消费（bypass `daccess_valid_r`）。

**注意：** 这直接增加关键路径（DCache BRAM→数据对齐→前递mux→ALU），需要极其谨慎。

---

### 阶段4：综合评估与最终配置（第13-15天）

#### Step 4.1：运行全部四项测试，记录：

| 指标 | 基线F0 | 阶段1(槽1MUL) | 阶段2(定向配对) | 阶段3(Cache优化) |
|---|---|---|---|---|
| STREAM cycles | 5,498,240 | | | |
| MATRIX cycles | 10,262,037 | | | |
| CRYPTONIGHT cycles | 38,348,476 | | | |
| MIXED cycles | 387,556 | | | |
| 总耗时@150MHz | 363.308727ms | | | |
| WNS | +0.010ns | | | |
| TNS | 0 | | | |
| Failing endpoints | 0 | | | |

#### Step 4.2：决策矩阵

```
收益 = 总耗时减少(ms)
代价 = WNS减少(ns)
效率 = 收益 / |代价|  (ms/ns)

优先保留效率最高且WNS≥0的改动
```

---

## 五、是否需要双发射？——精确答案

**结论：当前窄双发射基础设施应保留但不加宽。性能提升应走"定向功能迁移"路线，而非"加宽结构"路线。**

原因：

1. **窄双发射（当前已存在）**：对于MATRIX后半段的ADD/ST配对、MIXED前半段的ADD/XOR配对，窄双发射已有正向贡献（虽然微小）。

2. **为什么不再加宽**：
   - F0时序余量仅+0.010ns，任何宽化（第二套BPU、双ICache返回、双译码）都会立即破坏时序
   - 四项测试的动态瓶颈不是"前端供给不足"（`candidate_absent`仅406次/千万次）
   - 所有"大结构"改动（完成队列、双ALU、steering）在五项测试中均零收益
   - 硬件代价≈0收益，纯负向

3. **应做什么**：
   | 优先级 | 改动 | 预期收益 | 时序风险 |
   |---|---|---|---|
   | P0 | 槽1执行MUL.W/MULH.W/MULH.WU | +3.1ms (MATRIX) | 低（DSP已有时序余量） |
   | P1 | DCache next-line预取 | +1~2ms (STREAM+MATRIX) | 低（独立状态机） |
   | P2 | 定向解除pair_next_raw（仅当C读x0） | 取决于计数器数据 | 极低 |
   | P3 | Load-to-Use单周期bypass | +0.5~1ms | 高（需物理优化） |
   | ❌ | 两宽前端/双BPU | -43ms（负收益！） | 极高 |
   | ❌ | 双ALU/steering | 0（零收益） | 高 |
   | ❌ | 完成队列 | 0（零收益） | 高 |

---

## 六、执行的精确命令序列

### 6.1 环境准备
```bash
cd /home/hgd011/Downloads/submit_v2

# 确认Vivado版本
which vivado
vivado -version
```

### 6.2 基线构建
```bash
# 创建项目
vivado -mode batch -source run_vivado/flow/create_vivado_project.tcl

# 实现
vivado -mode batch -source run_vivado/flow/implement_design.tcl

# 检查时序
grep -E "WNS|TNS|Failing" project/thinpad_top.runs/impl_1/timing_summary.rpt

# 生成bitstream
vivado -mode batch -source run_vivado/flow/generate_bitstream.tcl
```

### 6.3 RTL修改（阶段1：槽1乘法）
```bash
# 编辑文件
# 1. src/soc/mycpu/slot1_narrow_decode.v - 增加MUL指令识别
# 2. src/soc/mycpu/restricted_slot1_lane.v - 增加乘法数据通路
# 3. src/soc/mycpu/myCPU.v - 增加乘法器队列的槽1入口

# 重新实现
vivado -mode batch -source run_vivado/flow/implement_design.tcl
```

### 6.4 时序验证
```bash
# 检查所有时序路径
grep "Slack" project/thinpad_top.runs/impl_1/timing_summary.rpt

# 如有违例，分析最差路径
grep -A20 " Worst Negative Slack" project/thinpad_top.runs/impl_1/timing_summary.rpt
```

---

## 七、风险与回退策略

| 风险 | 概率 | 缓解措施 |
|---|---|---|
| 槽1乘法破坏时序 | 中(30%) | 如果WNS < -0.05ns，回退乘法修改，转做Cache优化 |
| 诊断计数器不准确 | 低(10%) | 用参考实现交叉验证 |
| DCache预取引入功能错误 | 中(20%) | 预取状态机完全独立于正确性关键路径；可通过CSR禁用 |
| 修改引入功能回归 | 低(15%) | 每次修改后跑全部五项测试 |

**核心原则：每次只改一件事，测完再改下一件。不累积未验证的修改。**

---

## 附录A：相关文件索引

| 文件 | 功能 |
|---|---|
| `src/soc/mycpu/myCPU.v` | 顶层流水线控制、双发射配对、Store Buffer |
| `src/soc/mycpu/slot1_narrow_decode.v` | 槽1指令资格解码 |
| `src/soc/mycpu/restricted_slot1_lane.v` | 槽1独立流水线 |
| `src/soc/mycpu/IBUF.v` | 指令缓冲FIFO（双pop） |
| `src/soc/mycpu/ID_stage.v` | ID1/ID2译码与配对选择 |
| `src/soc/mycpu/OF_stage.v` | 操作数获取与前递 |
| `src/soc/mycpu/EX_stage.v` | ALU执行 |
| `src/soc/mycpu/DCache.v` | 数据Cache |
| `src/soc/mycpu/BPU.v` | 分支预测器 |
| `src/soc/mycpu/defines.vh` | 架构常量 |
| `run_vivado/constraints/thinpad_top.xdc` | 时序/引脚约束 |
| `run_vivado/flow/*.tcl` | 构建流程脚本 |

## 附录B：四项测试入口PC

| 测试 | 入口PC |
|---|---|
| STREAM | 0x1c002008 |
| MATRIX | 0x1c002030 |
| CRYPTONIGHT | 0x1c0020f0 |
| MIXED | 0x1c002184 |
| 公共完成 | 0x1c002288 |
