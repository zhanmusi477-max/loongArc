# 双发射完善路线分析：合理性与改进建议

> **项目**: LoongArch 兼容 CPU（ThinPad 平台）  
> **日期**: 2026-08-10  
> **分析对象**: 五条双发射完善路线 vs 当前源码实现  

---

## 目录

1. [当前双发射实现状态](#1-当前双发射实现状态)
2. [逐条路线分析](#2-逐条路线分析)
   - [路线 1：槽1乘法](#21-路线-1槽1乘法)
   - [路线 2：4项有序写缓冲](#22-路线-24项有序写缓冲)
   - [路线 3：两宽ID2 / 64位内部取指](#23-路线-3两宽id2--64位内部取指)
   - [路线 4：通用双ALU与lane steering](#24-路线-4通用双alu与lane-steering)
   - [路线 5：完成队列和寄存化scoreboard](#25-路线-5完成队列和寄存化scoreboard)
3. [路线中缺失的关键问题](#3-路线中缺失的关键问题)
4. [建议的优先级重排](#4-建议的优先级重排)
5. [分阶段实施方案](#5-分阶段实施方案)
6. [附录：关键当前瓶颈分析](#6-附录关键当前瓶颈分析)

---

## 1. 当前双发射实现状态

### 1.1 已有的基础设施

| 组件 | 文件 | 状态 |
|------|------|------|
| **IBUF 双弹出** | `IBUF.v` | ✅ 已实现 — 4-entry FIFO 支持 `pop` + `pop2` 同时弹出两条 |
| **ID1 双路并行译码** | `ID_stage.v` | ✅ 已实现 — 两个 `CU` 实例并行译码 B 和 C |
| **RF 四读两写** | `RF.v` (RF_4R2W) | ✅ 已实现 — 双 bank + LVT 实现 4R2W |
| **Slot-1 窄解码** | `slot1_narrow_decode.v` | ✅ 已实现 — 仅允许纯 ALU 操作 |
| **Slot-1 执行通道** | `restricted_slot1_lane.v` | ✅ 已实现 — OF/EX/M1/M2/WB 五级流水 |
| **记分板** | `myCPU.v` | ✅ 已实现 — `pending_older_busy` 32-bit bitmap |
| **Writer Tag 追踪** | `myCPU.v` | ✅ 已实现 — 9-bit one-hot tag: {S1_OF, S0_OF, S1_EX, S0_EX, S1_M1, S0_M1, S1_M2, S0_M2, S1_WB} |
| **配对决策** | `myCPU.v` | ✅ 已实现 — `pair_accept` 七条件判定 |

### 1.2 当前双发射配对的约束条件

从 `myCPU.v` 的 `pair_accept` 信号可以看到当前配对需满足**全部**以下条件：

```verilog
wire pair_accept = ibuf_valid && ibuf_valid2        // (1) IBUF 中有两条指令
                && s1_dec_eligible                  // (2) 第二条指令是 slot1 可执行的
                && id_pair_class_ok                 // (3) 第一条指令类型允许配对
                && !ibuf_pred_taken                 // (4) 第二条指令不是预测跳转
                && ibuf_seq_from_prev               // (5) 两条指令地址连续
                && !pair_raw && !pair_waw            // (6) 无 RAW/WAW 冒险
                && !pair_next_raw                   // (7) B→C 无 RAW
                && !s1_old_producer_block;          // (8) Slot-1 操作数不依赖在途指令
```

### 1.3 当前 Slot-1 可执行的指令

来自 `slot1_narrow_decode.v`：

| 指令类别 | 指令 | 数量 |
|---------|------|------|
| 3R 整数 ALU | ADD.W, SUB.W, AND.W, OR.W, XOR.W, NOR.W, SLL.W, SRL.W, SRA.W, SLT.W, SLTU.W | 11 |
| 2RI5 移位立即数 | SLLI.W, SRLI.W, SRAI.W | 3 |
| 2RI12 立即数 | ADDI.W, ANDI.W, ORI.W, XORI.W, SLTI.W, SLTUI.W | 6 |
| 常量生成 | LU12I.W, PCADDU12I | 2 |
| **明确排除** | MUL/DIV, Load/Store, Branch/JIRL, CSR/CPUCFG, CACOP | — |

---

## 2. 逐条路线分析

### 2.1 路线 1：槽1乘法

> 让乘法可以进入槽1或与槽0普通指令配对。

#### ✅ 合理的方面

- MUL 指令确实与普通 ALU 共享 3R 指令格式（`inst[31:15]`），从译码角度看最容易扩展
- 乘法在数值计算程序中频率较高（如矩阵运算、FIR 滤波器），放到 Slot-1 可以显著提升这类代码的 IPC
- 已有 3 周期 DSP 流水线和 MUL queue 基础设施

#### ❌ 不合理/需要警惕的方面

**a) 排序不合理 — 不应该放在第一条**

这是五条路线中**最不应该优先做**的一条。理由：

1. **MUL 是唯一的多周期非访存指令**。当前 MUL 的完成信号 `mul_result_next_valid` 直接参与全局暂停 `mul_div_suspend`。如果 MUL 进入 Slot-1，需要处理以下场景：
   - Slot-0 的普通 ALU 指令在 MEM 阶段遇到 Slot-1 的 MUL 尚未完成 → 需要额外的等待逻辑
   - 两个 MUL 同时在不同阶段（一个在 Slot-0 MEM，一个在 Slot-1 EX）→ MUL queue 需要双端口

2. **MUL bypass 路径仅存在于 Slot-0**。当前 `ex_late_mul_arch_valid` / `ex_late_mul_arch_wd` 是 Slot-0 专用的零气泡 MUL→ADD 前递路径。Slot-1 完全没有任何 MUL 结果前递。

3. **`mul_queue_select` 是单比特选择器**，假设只有一个 MUL 结果在途。两个 MUL 同时存在需要 2-bit 选择器或两个独立的 queue。

**b) 建议的替代方案**

| 优先级 | 方案 | 说明 |
|--------|------|------|
| **更合理先做** | 允许 MUL 在 Slot-1 但**互斥**：当 MUL 在 Slot-1 时 Slot-0 不能同时发射 MUL | 序列化 MUL，避免双 queue 复杂度 |
| **后续优化** | 增加第二个 MUL queue + 扩展 `mul_queue_select` 为 2-bit | 需要大量验证 |

**c) 代码改动预估**

```
slot1_narrow_decode.v: 新增 MUL_W/MULH_W/MULH_WU 的 eligible 判定 (~5 行)
restricted_slot1_lane.v: OF 阶段新增 MUL case (~5 行)
myCPU.v: MUL 互斥逻辑 (~10 行)
EX_stage.v: ex_is_mul_div 信号需区分 lane (~5 行)
```

---

### 2.2 路线 2：4项有序写缓冲

> 双发射的后端支撑。当前已完成并保留，但它只减少Store阻塞，不会直接提高每周期发射数量。

#### ✅ 合理的方面

- **这是五条中最合理、风险最低的一条**
- 当前 2-entry Store Buffer 确实太小：连续 3 条 `st.w` 就会停顿
- 双发射场景下，一次配对可能产生 **两条 Store**（虽然当前配对条件排除了 Store，但未来会放开），Store Buffer 压力倍增
- 代码改动局部性强：主要在 `myCPU.v` 的 Store Buffer 状态机

#### ❌ 需要注意的方面

**a) Store-Load 歧义检测 CAM 从 2-way 变为 4-way**

当前实现：
```verilog
wire store_entry0_conflict = store_entry0_pending && (...);
wire store_entry1_conflict = store_entry1_pending && (...);
```

改为 4-entry 后需要 4 路比较器。这在面积上可控（4 × 21-bit 比较），但需要注意时序。

**b) 路线描述说"已完成并保留"但代码中仍是 2-entry**

当前 `myCPU.v` 中的声明：
```verilog
reg [31:0] store_addr_mem [0:1];   // ← 仍是 [0:1]（2-entry）
reg [31:0] store_data_mem [0:1];
reg [ 3:0] store_wen_mem  [0:1];
```

如果已经完成了 4-entry 设计，建议合入主线。

**c) 建议的改进点**

| 当前 | 建议 | 理由 |
|------|------|------|
| 2-entry | **4-entry** | 平衡面积与性能 |
| 1-bit 读写指针 | **2-bit** | 支持 4-entry |
| 2 路 CAM | **4 路 CAM** | 代码生成（generate） |
| `store_count` 2-bit | **3-bit**（0-4） | 容纳 4 条目 |

---

### 2.3 路线 3：两宽ID2 / 64位内部取指

> 直接完善前端双发射，保证每周期稳定提供两条指令。

#### ✅ 合理的方面

- 当前 ICache 每周期只输出 32-bit（一条指令），IBUF 需要缓存才能提供两条
- 如果 IBUF 经常被"掏空"，64-bit 取指确实必要
- IBUF 已经支持双弹出，基础设施部分就绪

#### ❌ 存在的问题

**a) 收益可能被高估**

IBUF 当前是 4-entry。只有当 IBUF 经常接近空（occupancy ≤ 1）时，64-bit 取指才有明显收益。从设计角度看：

- 普通顺序代码中，IBUF 通常在 2-4 条目之间
- ICache 命中时每周期可以交付 1 条指令，足够维持 4-entry 的 IBUF 不空
- **真正的瓶颈不在前端带宽，而在后端执行**

**b) 实际上已经做了"类似的事情"**

当前 `pair_accept` 条件中的 `ibuf_seq_from_prev`：
```verilog
&& ibuf_seq_from_prev      // 两条指令地址连续
```

这意味着配对已经需要 IBUF 中有两条连续指令。当前靠 IBUF 缓存来实现，64-bit 取指只是减少了"等待 IBUF 积累两条"的延迟。

**c) 实现复杂度被低估**

64-bit 内部取指意味着：
- ICache 需要输出 64-bit（需要修改 `ICache.v`，增加一个 32-bit 输出端口或改为 64-bit 数据通路）
- SRAM/总线接口需要支持 64-bit 读取（或连续两个 32-bit 读取）
- BPU 需要能同时预测两条指令（当前 BPU 每周期只预测一条）

**d) 建议的更优方案**

| 优先级 | 方案 |
|--------|------|
| **先做** | 保持 32-bit ICache，将 IBUF 从 4-entry 扩到 **6-entry**，降低被掏空的概率 |
| **再做** | 在 ICache 内部增加一个 **预取缓冲**（prefetch buffer），连续地址时自动预取下一个 32-bit |
| **最后** | 真正的 64-bit ICache 输出 |

**e) IBUF 扩容分析**

当前 IBUF 深度由参数控制：
```verilog
module InstBuffer #(
    parameter DEPTH = 4,
    ...
)
```

改为 `DEPTH = 6` 或 `DEPTH = 8` 几乎不需要代码改动（仅参数化），但能显著降低前端饥饿概率。代价是约 (32+32+1+6+32+1+32) × 2 = ~272 FF 额外寄存器。

---

### 2.4 路线 4：通用双ALU与lane steering

> 最核心的双发射扩展，让更多普通ALU指令可以自由分配到两个槽。

#### ✅ 合理的方面

- **正确识别为"最核心"** — 如果只做一条改进，就应该是这条
- Lane steering 比当前"Slot-0 必须是第一条、Slot-1 只能捡剩下的"灵活得多
- 可以让两条相同类型的 ALU 指令都进入各自的 lane

#### ❌ 缺失的关键设计要素

**a) 跨 Lane 转发（Cross-Lane Forwarding）— 路线完全没有提及！**

这是双 ALU 设计中最难的部分，也是当前设计的**最大空白**。

当前 Slot-1 的操作数来源：
```
Slot-1 操作数 = 仅架构寄存器值（RF 读出时的值）
              ≠ 可以来自 Slot-0 的 EX/M1/M2 前递
```

这意味着以下代码**不能配对**：
```asm
add.w $r1, $r2, $r3    # Slot-0: 产生 r1
add.w $r4, $r1, $r5    # Slot-1: 需要 r1 ← 不能配对！（需等待 r1 写回 RF）
```

需要增加的前递路径：

| 源 | 目标 | 延迟 | 说明 |
|----|------|------|------|
| Slot-0 EX | Slot-1 OF | 同周期 | 最关键的路径，延迟压力最大 |
| Slot-0 M1 | Slot-1 OF | 1 周期后 | 常规流水线前递 |
| Slot-0 M2 | Slot-1 OF | 2 周期后 | 常规流水线前递 |
| Slot-1 EX | Slot-0 OF | 同周期 | 反向路径 |
| Slot-1 M1 | Slot-0 OF | 1 周期后 | 反向路径 |

当前记分板 `pending_older_busy` + `s1_old_producer_block` 阻止了所有跨 lane 依赖的配对。要真正实现 lane steering，必须解决这个问题。

**b) Lane Steering 策略**

"自由分配"需要额外的仲裁逻辑：

```
指令 A: ADD.W $r1, $r2, $r3     → 可以走 Slot-0 或 Slot-1
指令 B: ADD.W $r4, $r5, $r6     → 可以走 Slot-0 或 Slot-1
```

分配策略选择：
1. **简单方案**（推荐先做）：Slot-0 优先，Slot-1 填空
2. **均衡方案**：轮询（round-robin）
3. **优化方案**：基于依赖图的最优分配（复杂度高）

**建议从方案 1 开始**，因为当前 `pair_accept` 已经假设 B→C 的顺序。

**c) Slot-1 需要自己的 Shadow Forwarding**

当前 Shadow Forwarding 六路 Bank 全部为 Slot-0 设计。Slot-1 的 ALU 延迟同样需要预计算优化。但如果已经计划简化 Shadow Forwarding（从前一篇分析），可以为两个 Lane 各配置 3 个精简 Bank。

**d) 建议的渐进路线**

```
Step 1: Slot-1 支持从 Slot-0 EX/M1 前递（单向跨lane转发）
        → IPC 提升最大，改动最小

Step 2: Slot-0 支持从 Slot-1 EX/M1 前递（反向跨lane转发）
        → 实现真正的 lane steering

Step 3: Slot-1 增加 Shadow Forwarding（3 Banks）
        → 频率优化

Step 4: 动态 lane 分配策略
        → IPC 进一步提升
```

---

### 2.5 路线 5：完成队列和寄存化scoreboard

> 为更复杂的双发射提供顺序提交、相关性管理、异常与取消恢复。

#### ✅ 合理的方面

- 乱序完成确实需要完成队列（Completion Queue / Reorder Buffer）
- 当前的 `pending_older_busy` 是组合逻辑 bitmap，改为寄存化可以改善时序
- 异常处理在双发射场景下确实更复杂：如果 Slot-1 的指令触发异常，Slot-0 的指令是否已提交？

#### ❌ 严重问题

**a) 这条路线暗示了乱序完成，但当前是严格顺序流水线**

当前设计：**顺序发射 → 顺序执行 → 顺序写回**

引入完成队列意味着允许指令**乱序完成但顺序提交**。这需要：
- 每条指令携带一个序号（ROB ID）
- 结果先写入 ROB，再按序提交到 RF
- 异常时刷新 ROB 中该指令及之后的所有指令

这是**架构级别的变更**，不是"双发射完善"的一个子项，而是**完全不同的微架构**。

**b) 在本项目的规模下，完成队列可能是过度设计**

对于一个教学/竞赛级别的 FPGA CPU：
- ROB 通常需要 16-32 条目才能体现乱序优势
- 16-entry ROB × (32-bit data + 5-bit dst + 控制位) ≈ 600+ FF
- 唤醒（wakeup）逻辑的 CAM 比较复杂度是 O(N²)
- 验证难度极高

**c) 建议的替代方案**

| 方案 | 适用范围 | 复杂度 |
|------|---------|--------|
| **小保留站（4-6 entry）** | 允许 Load 停顿期间发射后续独立 ALU 指令 | 中等 |
| **有序发射 + 有序完成**（当前） | 简单、正确、时序友好 | 低 |
| 完整 ROB（16+ entry） | 真正乱序，但需要大量验证 | 极高 |

**建议**：将路线 5 改为"**小保留站（4-entry Reservation Station）+ 寄存化 scoreboard**"，而非完整的"完成队列"。这更符合项目的实际需求。

**d) 寄存器化 scoreboard 的合理改进**

当前 `pending_older_busy` 的实现：
```verilog
// 每周期从 live 信号重新计算
wire busy_next_g = (s0_ex_prod_next && ...) || (s0_m1_prod_next && ...) || ...;
always @(posedge cpu_clk)
    pending_older_busy[g] <= busy_next_g;
```

这已经是寄存化的（`always @(posedge cpu_clk)`），但 `busy_next_g` 的计算是组合逻辑。如果频率压力大，可以 pipeline 化这个计算（提前一个周期计算 next-next state）。

---

## 3. 路线中缺失的关键问题

### 3.1 🔴 缺失 1：跨 Lane 转发（Cross-Lane Forwarding）

**严重程度：★★★★★**

如 2.4 节详述，这是当前双发射 IPC 受限的**最大瓶颈**。五条路线完全没提。

### 3.2 🔴 缺失 2：双发射下的异常处理

**严重程度：★★★★**

当前异常（如地址不对齐 `ldst_unalign`）会触发流水线冲刷。双发射场景下：
- Slot-0 和 Slot-1 可能同时产生异常 → 优先级规则？
- Slot-1 先于 Slot-0 到达 MEM 阶段（虽然同时发射）→ 异常顺序可能与程序顺序不一致

**建议**：Slot-0 异常优先，Slot-1 异常时也冲刷 Slot-0（因为 Slot-0 在程序序中更早）。

### 3.3 🟠 缺失 3：双发射下的分支预测

**严重程度：★★★**

当前 BPU 每周期只预测一条指令。双发射可能每周期发射两条，其中任何一条都可能是分支。BPU 需要：
- 识别配对中是否包含分支
- 如果包含，预测方向和目标
- 如果不包含，生成顺序的下两条 PC

当前 `pair_accept` 条件 `!ibuf_pred_taken` 排除了第二条是预测跳转的情况，但第一条仍然可以是分支，此时配对被 `id_pair_class_ok` 阻止。这是合理的保守策略，但随着双发射扩展，需要更积极的预测。

### 3.4 🟠 缺失 4：功耗和面积预算

**严重程度：★★★**

五条路线都没有提及：
- Slot-1 的第二个完整 ALU 增加多少 LUT？（约 200-300 LUT）
- 跨 Lane 转发增加多少路由压力？
- 64-bit ICache 增加多少 BRAM？

### 3.5 🟡 缺失 5：验证策略

**严重程度：★★**

当前代码中已有大量的 `ifndef SYNTHESIS` formal assertion（至少 15 处）。双发射越复杂，验证越重要。建议：
- 每条路线完成后增加差分测试（diff-test）对比单发射 golden model
- 对跨 lane 转发增加专门的随机测试

---

## 4. 建议的优先级重排

### 原路线顺序 vs 建议顺序

| 序号 | 原路线 | 建议排序 | 理由 |
|------|--------|---------|------|
| 1 | 槽1乘法 | **→ 第 4 位** | 需要 MUL queue 双端口化，依赖其他基础设施先完善 |
| 2 | 4项有序写缓冲 | **→ 第 1 位** ✅ | 风险最低，改动局部，双发射后端必备 |
| 3 | 两宽ID2/64位取指 | **→ 第 3 位** | 重要但非瓶颈；先扩 IBUF 深度更简单 |
| 4 | 通用双ALU+lane steering | **→ 第 2 位** ✅ | 核心，但必须与跨lane转发一起做 |
| 5 | 完成队列+scoreboard | **→ 第 5 位** | 架构级变更，应改为小保留站 |

### 建议的新路线顺序

```
Phase A：后端支撑（1-2 周）
├── A1: Store Buffer 2→4 entry
├── A2: IBUF 深度 4→6 entry
└── A3: Scoreboard 增强（跨lane依赖感知）

Phase B：核心双发射扩展（2-3 周）
├── B1: 跨Lane单向转发（Slot-0→Slot-1）
├── B2: Slot-1 扩展指令（支持更多 ALU 操作）
├── B3: Slot-1 Shadow Forwarding（3 Banks）
└── B4: Lane steering 基础（无分支时自由分配）

Phase C：前端增强（1-2 周）
├── C1: BPU 双指令预测（或保持保守策略）
└── C2: ICache 预取缓冲（prefetch buffer）

Phase D：深度优化（2-3 周）
├── D1: 跨Lane双向转发
├── D2: 4-entry 保留站（可选）
└── D3: Slot-1 MUL 支持（互斥模式）
```

---

## 5. 分阶段实施方案

### Phase A：后端支撑（风险低，收益明确）

#### A1: Store Buffer 2→4 entry

```diff
- reg [31:0] store_addr_mem [0:1];
+ reg [31:0] store_addr_mem [0:3];
- reg [31:0] store_data_mem [0:1];
+ reg [31:0] store_data_mem [0:3];
- reg [ 3:0] store_wen_mem  [0:1];
+ reg [ 3:0] store_wen_mem  [0:3];
- reg [20:0] store_word_key_mem [0:1];
+ reg [20:0] store_word_key_mem [0:3];
```

配合 `store_wr_ptr` / `store_rd_ptr` 改为 2-bit，`store_count` 改为 3-bit。

#### A2: IBUF 深度 4→6

```diff
- parameter DEPTH = 4
+ parameter DEPTH = 6
```

仅需修改参数，其余逻辑自动参数化。

#### A3: Scoreboard 增强

```verilog
// 新增：跨lane依赖感知
wire s1_dep_s0_ex = s1_dec_rR1_re && (s1_dec_rR1 != 5'd0) &&
                    ex_valid && ex_rf_we && (s1_dec_rR1 == ex_wR);
wire s1_dep_s0_m1 = s1_dec_rR1_re && (s1_dec_rR1 != 5'd0) &&
                    x2_valid && x2_rf_we && (s1_dec_rR1 == x2_wR);
// 新增到 s1_old_producer_block 的判断中（作为未来跨lane转发的预备）
```

### Phase B：核心双发射扩展

#### B1: 跨Lane单向转发（Slot-0→Slot-1）

这是**最关键也是最难**的改动。当前的 `restricted_slot1_lane.v` 在 OF 阶段直接使用 `issue_rD1 / issue_rD2`（来自 ID1 时的 RF 值）。需要改为：

```verilog
// 新增：Slot-1 OF 阶段的跨lane前递 mux
wire [31:0] s1_of_rD1_final = s1_fwd_s0_ex_sel ? ex_wd :
                               s1_fwd_s0_m1_sel ? x2_wd :
                               s1_fwd_s0_m2_sel ? mem_wd :
                               of_rD1_r;  // 默认：架构寄存器值

wire [31:0] s1_of_rD2_final = s1_fwd_s0_ex_sel_r2 ? ex_wd :
                               s1_fwd_s0_m1_sel_r2 ? x2_wd :
                               s1_fwd_s0_m2_sel_r2 ? mem_wd :
                               of_rD2_r;
```

#### B2: Slot-1 扩展指令

```diff
// slot1_narrow_decode.v 新增
+ wire mul_w  = (inst[31:15] == 17'h00038);  // MUL.W only, not MULH
+ wire type_3r = add_w | sub_w | ... | mul_w; // 新增 mul_w
```

暂不包括 MULH.W/MULH.WU（需要 64-bit 中间结果，复杂度高）。

#### B3: Slot-1 Shadow Forwarding

为 Slot-1 创建精简版 Shadow Bank（仅 ADDSUB + LOGIC）：

```verilog
// restricted_slot1_lane.v 新增
reg [31:0] s1_shadow_addsub_wd;
reg [31:0] s1_shadow_logic_wd;
reg        s1_shadow_addsub_valid;
reg        s1_shadow_logic_valid;
```

### Phase C-D: 前端增强与深度优化

#### C1: BPU 双指令预测

保持保守策略：如果配对中有预测跳转，只取跳转目标。不做双路径预测。

#### C2: ICache 预取缓冲

在 ICache hit 路径上增加一个 32-bit 预取寄存器：
```verilog
reg [31:0] ic_prefetch_data;
reg        ic_prefetch_valid;
// 连续地址时，下一个 32-bit 自动可用
```

#### D1-D3: 深度优化

根据 Phase A/B/C 的实测 IPC 数据决定是否需要。

---

## 6. 附录：关键当前瓶颈分析

### 6.1 配对率限制因素分析

从 `pair_accept` 的七个条件出发：

| 条件 | 失败概率 | 可改善性 |
|------|---------|---------|
| `s1_dec_eligible` | ~25-35% | **高** — 扩展 Slot-1 指令集 |
| `id_pair_class_ok` | ~10-15% | 中等 — 允许分支配对风险大 |
| `!ibuf_pred_taken` | ~10-15% | 低 — BPU 改进 |
| `ibuf_seq_from_prev` | ~5-10% | **高** — 64-bit 取指或 IBUF 扩容 |
| `!pair_raw && !pair_waw` | ~5-15% | **高** — 跨Lane转发 |
| `!pair_next_raw` | ~5-10% | 低 — 编译器优化 |
| `!s1_old_producer_block` | ~15-25% | **高** — 跨Lane转发 |

> **结论**：跨Lane转发 + Slot-1 指令扩展 是提升配对率的两个最高杠杆点。

### 6.2 时序关键路径

| 路径 | 当前状态 | 双发射后变化 |
|------|---------|-------------|
| Slot-0 OF Shadow 计算 | 6 Banks 并行 | 不变 |
| Slot-0 前递 mux | 4:1 mux | 不变 |
| `pair_accept` 判定 | ~5 LUT 级 | 跨lane依赖检测增加 1-2 级 |
| `pending_older_busy` 更新 | 1 级 | 2 lane 状态加倍，增加 ~1 级 |
| Slot-1 OF ALU | 1 级 | 加 Shadow 后增加 1 级 |

### 6.3 面积估算

| 组件 | 当前 | Phase A | Phase B | Phase C |
|------|------|---------|---------|---------|
| Store Buffer | ~200 FF | ~400 FF | ~400 FF | ~400 FF |
| IBUF | ~300 FF | ~450 FF | ~450 FF | ~450 FF |
| Slot-1 ALU | ~150 LUT | ~150 LUT | ~200 LUT | ~200 LUT |
| 跨Lane转发 mux | 0 | 0 | ~100 LUT | ~100 LUT |
| Slot-1 Shadow | 0 | 0 | ~150 LUT | ~150 LUT |
| ICache 预取 | 0 | 0 | 0 | ~50 FF |
| **总计增量** | 基准 | +~350 FF | +~300 LUT +~50 FF | +~50 FF |
```

