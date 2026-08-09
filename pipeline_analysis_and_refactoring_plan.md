# CPU 流水线架构分析、缺陷诊断与重构方案

> **项目**: LoongArch 兼容 CPU  
> **日期**: 2026-08-09  
> **流水线**: IF → IBUF → ID1 → ID2 → OF → EX → EX2/M1 → MEM/M2 → WB（9 级）

---

## 目录

1. [流水线总体结构](#1-流水线总体结构)
2. [关键架构特征](#2-关键架构特征)
3. [明显缺陷分析](#3-明显缺陷分析)
4. [改进方案](#4-改进方案)
5. [推荐模块拆分方案](#5-推荐模块拆分方案)
6. [优先级排序与实施路线](#6-优先级排序与实施路线)

---

## 1. 流水线总体结构

```
                            ┌──────────┐
                            │   BPU    │
                            │ BHT+RAS  │
                            └────┬─────┘
                                 │ pred_target
                                 ▼
┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌───────┐   ┌───────┐   ┌──────┐
│  IF  │──▶│ IBUF │──▶│ ID1  │──▶│ ID2  │──▶│  OF  │──▶│  EX  │──▶│EX2/M1 │──▶│MEM/M2 │──▶│  WB  │
│ 取指 │   │4-条目│   │译码+ │   │译码  │   │操作数│   │ ALU+ │   │对齐+  │   │Load结果│   │ 写回 │
│      │   │FIFO  │   │RF读+ │   │寄存器│   │前递+ │   │乘法+ │   │Store  │   │扩展+  │   │      │
│      │   │      │   │双发射│   │      │   │AGU+  │   │分支  │   │Buffer │   │MUL完成│   │      │
│      │   │      │   │配对  │   │      │   │分支  │   │条件  │   │入队   │   │       │   │      │
└──┬───┘   └──────┘   └──────┘   └──────┘   └──┬───┘   └──┬───┘   └───┬───┘   └───┬───┘   └──┬───┘
   │                                           │          │           │           │          │
   │◄────── front_redirect（重定向）────────────┘          │           │           │          │
   │                                                      │           │           │          │
   │◄──────────── ex_alu_f（分支结果）─────────────────────┘           │           │          │
   │                                                                  │           │          │
   │                    ◄── ldst_suspend / store_buffer_suspend ──────┘           │          │
   │                                                                              │          │
   │                         ◄── mul_div_suspend ─────────────────────────────────┘          │
   │                                                                                         │
   │                                              ◄── RF 前递 ──────────────────────────────┘
   └─────────────────────────────────────────────────────────────────────────────────────────┘
                                  pred_error（分支预测错误）
```

### 各阶段职责

| 阶段 | 模块 | 职责 |
|------|------|------|
| **IF** | `IF_stage.v` | PC 生成、ICache 请求发起、重定向响应 |
| **IBUF** | `IBUF.v` | 4-entry 指令缓冲 FIFO，支持双弹出（dual-pop） |
| **ID1** | `ID_stage.v` | 指令译码、寄存器文件读取、双发射配对判定 |
| **ID2** | `ID1_ID2.v` | 译码结果寄存器、WB 刷新、依赖标签捕获 |
| **OF** | `OF_stage.v` | 操作数前递、Shadow 预计算、地址生成、分支判定 |
| **EX** | `EX_stage.v` | ALU 运算、乘法发起、分支条件求值 |
| **EX2/M1** | `EX2_stage.v` | 对齐检查、字节通道格式化、Store Buffer 入队、Load 请求 |
| **MEM/M2** | `MEM_stage.v` | DCache 响应等待、Load 结果扩展 |
| **WB** | `WB_stage.v` | 寄存器文件写回 |

---

## 2. 关键架构特征

### 2.1 分支预测（BPU）

- **128 条目**直接映射 BHT（Branch History Table）
- **2-bit 饱和计数器**（Smith 算法）
- **8-bit 折叠 XOR 标签**（`if_pc[15:8] ^ if_pc[23:16] ^ if_pc[31:24]`）
- **RAS**（Return Address Stack）独立预测返回指令
- 预测目标 mux 合并在单级 LUT 中（BPU taken/fallthrough + RAS 三路合并）

### 2.2 数据转发（Data Forwarding）

- **4 路前递**：EX → M1 → M2 → WB（优先级递减）
- **Shadow Forwarding**：6 个并行预计算结果 Bank 在 OF 阶段提前准备好
  - `SHADOW_ADDSUB`（加减法）
  - `SHADOW_LOGIC`（逻辑运算）
  - `SHADOW_SHIFT`（移位）
  - `SHADOW_COMPARE`（比较）
  - `SHADOW_SIMPLE`（LU12I / PCADDU12I）
  - `SHADOW_PC4`（PC + 4）
- **相邻依赖专用路径**：`ex_exec_add_wd`、`ex_exec_sll_wd` 等操作局部前递

### 2.3 访存系统

- **ICache + DCache** 分离，均支持 refill
- **2-entry 有序 Store Buffer**：Store 先入队，DCache 按序取走
- **提前 Load 探测**（`daccess_early_valid`）：在 EX 阶段即发出 Load 地址
- **精确 Store-Load 歧义检测**：基于 21-bit 字地址全相联比较
- **MMIO 识别**：基于地址 `0x1F00xxxx / 0xBFD0xxxx` 模式识别

### 2.4 双发射

- **Slot-0**：完整流水线，支持所有指令
- **Slot-1**（`restricted_slot1_lane.v`）：仅支持纯 ALU 操作
  - 无访存、无分支、无 CSR、无乘法
  - 不允许数据依赖（记分板阻止）
  - 必须与 Slot-0 同步推进

### 2.5 乘法器

- **3 周期 DSP 流水线**
- **MUL Queue**：两个并行候选结果，通过 `mul_queue_select` 选择
- 支持 **MUL → ADD 零气泡前递**（`ex_late_mul_arch_wd`）

---

## 3. 明显缺陷分析

### 🔴 缺陷 1：OF 阶段是严重时序瓶颈（严重程度：★★★★★）

OF 阶段在一个周期内承担了**过多职责**：

| 路径 | 组合逻辑深度 | 对时序影响 |
|------|-------------|-----------|
| 4 路操作数前递 mux（EX/M1/M2/WB） | 3-4 LUT 级 | **高** |
| 6 路 Shadow Result 并行预计算 | 4-5 LUT 级 + CARRY4 | **极高** |
| 分支条件判定 + Mispredict 检测 | 3-4 LUT 级 | **高** |
| Load/Store 地址生成（AGU） | CARRY4 链 | **高** |
| Shadow Repair（AND 修复逻辑） | 2-3 LUT 级 | 中等 |
| CSR 操作数格式化 | 2 LUT 级 | 低 |
| Load/MUL 依赖检测与等待 | 2 LUT 级 | 低 |

**问题本质**：OF 同时充当了 **Operand Fetch + Issue + Address Generation + Branch Resolution** 四个传统阶段的角色。在高频目标（>100MHz on FPGA）下，这是极难闭合的关键路径。

**证据**：源码中大量使用了 `(* keep_hierarchy = "yes" *)`、`(* max_fanout = *)`、`(* DONT_TOUCH = "true" *)` 等属性来手动干预综合优化，以及多处 `of_` 信号的独立物理副本（如 `load_result_valid_of_r` vs `load_result_valid_r`），都说明设计者已经意识到 OF 阶段的时序问题并采取了大量补丁式优化。

---

### 🔴 缺陷 2：`myCPU.v` 单体巨石文件（严重程度：★★★★★）

`myCPU.v` 约 **1200+ 行**，包含：

- 全部流水线控制信号声明与连线（~250 行）
- Store Buffer 完整状态机（~80 行）
- Load Result 捕获与格式化（~120 行）
- 地址翻译 DMW mux（~10 行）
- 依赖标签（dep_tag）计算（~50 行）
- Store-Load 精确歧义检测 CAM（~60 行）
- MUL 队列控制与结果选择（~40 行）
- Dual-issue 记分板逻辑（~30 行）
- 全局暂停/恢复策略（~20 行）
- 大量 formal assertion 验证逻辑（~100 行）

**后果**：
1. Vivado 将整个 CPU 核心作为一个编译单元综合，无法有效利用层次化策略
2. 任何微小改动都会触发全模块重新综合
3. 代码审查和维护极其困难
4. 时序优化工具（phys_opt_design）难以定位关键路径的具体来源

---

### 🟠 缺陷 3：Shadow Forwarding 过度设计（严重程度：★★★★）

6 个 Shadow Bank 各 32-bit 数据路径意味着 **192 根额外数据线**在 OF 阶段路由：

```
of_shadow_addsub_wd[31:0]   ─┐
of_shadow_logic_wd[31:0]    ─┤
of_shadow_shift_wd[31:0]    ─┤
of_shadow_compare_wd[31:0]  ─┼── 全部并行通过 OF → EX
of_shadow_simple_wd[31:0]   ─┤
of_shadow_pc4_wd[31:0]      ─┘
```

**问题**：
- 功耗显著增加（6 路 32-bit 加法器/移位器/比较器每周期翻转）
- Shadow Repair 逻辑极其脆弱（`of_shadow_repair_and`）
- 验证复杂度极高，formal assertion 遍布代码
- COMPARE、SIMPLE、PC4 这三个 Bank 的使用频率远低于 ADDSUB/LOGIC/SHIFT

---

### 🟠 缺陷 4：Store Buffer 仅 2 条目（严重程度：★★★★）

```verilog
reg [31:0] store_addr_mem [0:1];
reg [31:0] store_data_mem [0:1];
```

**影响**：
- 连续 3 条 Store 指令导致流水线**完全暂停**
- Store 密集场景（`memset`、结构体复制、函数调用保存寄存器）性能严重受损
- 例如：`st.w $r1, $r2, 0; st.w $r3, $r2, 4; st.w $r4, $r2, 8` 会导致 1 个周期的气泡
- Store-Load 歧义检测被迫等待 Store Buffer 排空

---

### 🟠 缺陷 5：Dual-Issue (Slot-1) 极度受限（严重程度：★★★）

`restricted_slot1_lane.v` 的约束：

| 能力 | Slot-0 | Slot-1 |
|------|--------|--------|
| ALU 操作 | ✅ | ✅ |
| Load/Store | ✅ | ❌ |
| 分支/跳转 | ✅ | ❌ |
| CSR | ✅ | ❌ |
| 乘法 | ✅ | ❌ |
| 数据前递 | ✅ | ❌（仅架构寄存器） |
| 独立推进 | ✅ | ❌（必须与 Slot-0 同步） |

**IPC 提升有限**（实际约 1.05-1.15），但成本不低：
- Slot-1 的 5 级流水寄存器
- 记分板 bitmap 逻辑
- RF 双写端口

---

### 🟡 缺陷 6：无发射队列 / 保留站（严重程度：★★★）

流水线采用**严格顺序发射、顺序执行、顺序写回**：

```
ID2 ──► OF ──► EX ──► EX2 ──► MEM ──► WB
  │                                  ▲
  └── 如果 Load 停顿，后续全部阻塞 ──┘
```

IBUF 只能缓冲 ICache 抖动（4 条目），不能掩盖执行端停顿。

**典型场景**：
```asm
ld.w  $r1, $r2, 0    # 停顿等待 DCache
add.w $r3, $r4, $r5   # 独立指令，也被阻塞
add.w $r6, $r7, $r8   # 独立指令，也被阻塞
```

---

### 🟡 缺陷 7：乘法延迟与流水线耦合过紧（严重程度：★★★）

3 周期乘法通过 DSP 流水线实现，但完成信号直接参与全局暂停：

```verilog
assign mul_div_suspend = mem_valid && mem_is_mul && !m2_mul_result_ready_r;
```

MUL 队列 bypass 有大量位扩展复制（`m2_mul_queue_select_mask_r`）来优化时序，这是信号过于紧张的体现。

---

### 🟡 缺陷 8：Load-Use 处理逻辑复杂且分散（严重程度：★★）

Load-Use 处理涉及：
- `early_load_hold`：提前 Load 暂停
- `ldst_suspend`：访存引起的全局暂停
- `load_pending_valid`：Load 请求待处理
- `load_result_valid_r`：Load 结果就绪（CPU 时钟域）
- `load_result_valid_of_r`：OF 专用物理副本
- `ex_store_data_load_dep`：Store 数据依赖 Load 的特殊路径

这些信号分散在 `myCPU.v`、`EX_stage.v`、`MEM_stage.v`、`EX2_stage.v` 中，交互逻辑需要大量 assertion 来保证正确性。

---

## 4. 改进方案

### 方案 A：拆分 OF 阶段为两段（优先级 P0）

```
原:  ID2 ──► OF（合并）──► EX
新:  ID2 ──► OF1 ──► OF2 ──► EX
```

| OF1（Operand Fetch） | OF2（AGU + Branch） |
|---------------------|---------------------|
| 4 路前递 mux | Load/Store 地址生成（AGU） |
| Shadow Result 选择 | 分支条件判定 |
| 操作数最终确定 | Mispredict 检测 |
| 依赖检测 | CSR 操作数格式化 |
| 操作数等待判定 | 重定向脉冲生成 |

**代价**：
- 分支延迟从 1 周期变为 2 周期（增加 1 个 bubble on mispredict）
- 增加一组流水线寄存器（~200 FF）
- 需要调整 BPU 更新时序

**收益**：
- 消除最关键的时序瓶颈
- 大约缩短 30-40% 的组合逻辑路径
- 可能提升最大频率 15-25%

**实施要点**：
1. 创建 `OF1_stage.v` 和 `OF2_stage.v`
2. OF1 输出：`of1_real_rD1`、`of1_real_rD2`、`of1_shadow_class`、`of1_shadow_wd`
3. OF2 输入：OF1 输出 + ID2 的 `npc_op`、`is_br_jmp`、`target_ext` 等非数据路径信号
4. BPU 的 `ex_valid` 更新改为 OF2 的 `of2_valid`

---

### 方案 B：拆分 `myCPU.v` 为独立模块（优先级 P1）

#### B.1 提取 `store_buffer.v`

```verilog
module store_buffer (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    // M1 入队接口
    input  wire        enqueue_valid,
    input  wire [31:0] enqueue_addr,
    input  wire [31:0] enqueue_data,
    input  wire [ 3:0] enqueue_wen,
    // DCache 出队接口
    output wire        issue_valid,
    output wire [31:0] issue_addr,
    output wire [31:0] issue_data,
    output wire [ 3:0] issue_wen,
    input  wire        issue_accept,   // DCache 接受
    // Store-Load 歧义检测
    input  wire [31:0] load_addr,
    input  wire        load_peripheral,
    output wire        conflict,
    // 状态
    output wire        buffer_full,
    output wire        buffer_busy,
    output wire        buffer_empty
);
```

#### B.2 提取 `load_unit.v`

```verilog
module load_unit (
    input  wire        cpu_clk,
    input  wire        cpu_rstn,
    // M1 Load 请求
    input  wire        load_request,
    input  wire [ 4:0] load_wR,
    input  wire [ 2:0] load_ext_op,
    input  wire [ 1:0] load_offset,
    // DCache 响应
    input  wire        daccess_valid,
    input  wire [31:0] daccess_rdata,
    // 结果输出（CPU 时钟域寄存器）
    output wire        result_valid,
    output wire [ 4:0] result_wR,
    output wire [31:0] result_data,
    // 待处理状态
    output wire        pending
);
```

#### B.3 提取 `pipeline_control.v`

```verilog
module pipeline_control (
    input  wire        ldst_suspend,
    input  wire        store_buffer_suspend,
    input  wire        mul_div_suspend,
    input  wire        early_load_hold,
    output wire        pl_suspend,       // 全局流水线暂停
    output wire        id2_stall,        // ID2 停顿
    output wire        pause_ifetch,     // 暂停取指
    output wire        resume_ifetch     // 恢复取指
);
```

#### B.4 提取 `dep_tracker.v`

```verilog
module dep_tracker (
    input  wire [ 4:0] id_rR1,
    input  wire [ 4:0] id_rR2,
    input  wire        id_rR1_re,
    input  wire        id_rR2_re,
    // 各阶段 writer 信息
    input  wire        of_valid, of_rf_we, [ 4:0] of_wR,
    input  wire        ex_valid, ex_rf_we, [ 4:0] ex_wR,
    input  wire        m1_valid, m1_rf_we, [ 4:0] m1_wR,
    input  wire        m2_valid, m2_rf_we, [ 4:0] m2_wR,
    // 依赖标签输出（one-hot: {EX, M1, M2, WB}）
    output wire [ 3:0] r1_dep_tag,
    output wire [ 3:0] r2_dep_tag
);
```

#### B.5 提取 `issue_scoreboard.v`

```verilog
module issue_scoreboard (
    input  wire [ 4:0] s1_dec_rR1,
    input  wire [ 4:0] s1_dec_rR2,
    input  wire        s1_dec_rR1_re,
    input  wire        s1_dec_rR2_re,
    // 在途 writer 的寄存器号
    input  wire [4:0]  older_writers [0:5],
    input  wire [5:0]  older_writers_valid,
    output wire        s1_operands_ready,
    output wire [31:0] pending_busy_bitmap
);
```

---

### 方案 C：简化 Shadow Forwarding（优先级 P2）

从 6 Banks 减少到 **3 Banks**：

| 保留 | 理由 |
|------|------|
| `SHADOW_ADDSUB` | 最高频 ALU 操作，CARRY4 延迟最大 |
| `SHADOW_LOGIC` | 仅次于 ADDSUB，AND/OR/XOR 在多数程序中占 20-30% |
| `SHADOW_SHIFT` | 桶形移位器延迟较高 |

移除：
- `SHADOW_COMPARE`（SLT/SLTU 频率低，可容忍常规转发延迟）
- `SHADOW_SIMPLE`（LU12I/PCADDU12I 仅需传递立即数，无 ALU 延迟）
- `SHADOW_PC4`（JIRL 写回 PC+4，频率低）

**收益**：
- 减少 96 根数据线
- 消除 Shadow Repair 逻辑
- 降低功耗约 10-15%

---

### 方案 D：扩大 Store Buffer 到 4-8 条目（优先级 P1）

```
原: 2-entry → 新: 4-entry（推荐）或 8-entry
```

**实施**：
- 使用 `reg [31:0] store_addr_mem [0:3]` 等声明
- 写指针/读指针改为 2-bit
- Store-Load 歧义检测改为 4 路全相联比较

**收益**：
- Store 密集代码性能提升 2-3×
- 减少 `memset` 类操作的停顿

**面积代价**（4-entry）：
- 4 × (32+32+4) = 272 FF + 4 × 21 = 84 FF（地址键）= ~356 FF
- 4 路 21-bit 比较器

---

### 方案 E：增加小型保留站（优先级 P2）

在 ID2 和 OF 之间插入 4-8 条目的 Reservation Station：

```
ID2 ──► [RS 4-8 entries] ──► OF ──► EX
              │
              └── Wakeup: 结果就绪即发射
```

| 字段 | 位宽 | 说明 |
|------|------|------|
| busy | 1 | 条目有效 |
| op | 5 | ALU 操作码 |
| Vj, Vk | 32+32 | 操作数 |
| Qj, Qk | 3+3 | 等待的 producer ID |
| wR | 5 | 目的寄存器 |
| pc | 32 | 程序计数器 |

**收益**：
- Load 停顿时后续独立指令可继续执行
- IPC 提升约 10-20%（取决于代码特征）

**代价**：
- CAM 唤醒逻辑面积
- 验证复杂度显著增加

---

### 方案 F：扩展 Slot-1 能力（优先级 P3）

| 扩展项 | 说明 |
|--------|------|
| 允许 RF 前递值 | 当前仅允许架构寄存器值 |
| 允许 Load 指令 | 需要 Slot-1 独立的 AGU |
| 与 Slot-0 OF1 合并 | 统一的操作数获取阶段 |

---

## 5. 推荐模块拆分方案

```
src/soc/mycpu/
│
├── myCPU.v                         # 顶层：仅连线与实例化（~200 行）
│
├── frontend/                        # 前端
│   ├── IF_stage.v                   # 取指（PC 控制 + ICache 请求）
│   ├── BPU.v                        # 分支预测（BHT + RAS，128-entry）
│   ├── RAS.v                        # 返回地址栈（独立模块）
│   └── IBUF.v                       # 4-entry 指令缓冲 FIFO
│
├── decode/                          # 译码
│   ├── ID_stage.v                   # ID1：译码 + RF 读取 + 双发射配对
│   ├── ID1_target_precompute.v      # 分支目标地址预计算
│   ├── ID1_ID2.v                    # ID1 → ID2 流水寄存器
│   ├── CU.v                         # 控制单元（指令译码）
│   ├── EXT.v                        # 立即数扩展
│   ├── slot1_narrow_decode.v        # Slot-1 窄解码
│   └── issue_scoreboard.v           # 双发射记分板
│
├── execute/                         # 执行
│   ├── OF1_stage.v                  # OF1：操作数获取 + Shadow 选择 + 依赖检测
│   ├── OF2_stage.v                  # OF2：AGU + 分支判定 + CSR 格式化
│   ├── data_forward.v               # 通用数据转发
│   ├── shadow_forward.v             # Shadow 预计算转发（3 Banks）
│   ├── AGU.v                        # 地址生成单元
│   ├── branch_resolve.v             # 分支判定逻辑
│   ├── ID_EX.v                      # OF → EX 流水寄存器
│   ├── EX_stage.v                   # EX：ALU + 乘法发起 + 分支条件
│   ├── ALU.v                        # 算术逻辑单元
│   ├── restricted_slot1_lane.v      # Slot-1 窄执行通道
│   └── mul_queue.v                  # 乘法 DSP 队列
│
├── memory/                          # 访存
│   ├── EX2_stage.v                  # M1：对齐检查 + 请求生成
│   ├── store_buffer.v               # 有序 Store Buffer（含歧义检测）
│   ├── load_unit.v                  # Load 结果捕获与格式化
│   ├── MEM_REQ.v                    # 访存请求字节通道格式化
│   ├── MEM_stage.v                  # M2：访存响应等待
│   ├── EX_MEM.v                     # EX → MEM 流水寄存器
│   └── MEM_WB.v                     # MEM → WB 流水寄存器
│
├── writeback/                       # 写回
│   └── WB_stage.v                   # WB：寄存器文件写回
│
├── csr/                             # 控制状态寄存器
│   └── CSRFile.v                    # CSR 寄存器文件
│
├── common/                          # 通用模块
│   ├── RF.v                         # 寄存器文件（32×32）
│   ├── PC.v                         # 程序计数器
│   ├── NPC.v                        # 下一条 PC 计算
│   ├── async_fifo.v                 # 异步 FIFO
│   ├── AddressTranslate.v           # DMW 地址翻译
│   ├── pipeline_control.v           # 统一流水线控制
│   └── dep_tracker.v                # 依赖标签追踪
│
├── defines.vh                       # 宏定义
└── mycpu_inst.vh                    # 指令实现开关
```

### 拆分后各模块行数估算

| 模块 | 估算行数 | 来源 |
|------|---------|------|
| `myCPU.v` | ~200 | 仅实例化 |
| `pipeline_control.v` | ~60 | 从 myCPU.v 提取 |
| `store_buffer.v` | ~150 | 从 myCPU.v 提取 |
| `load_unit.v` | ~120 | 从 myCPU.v 提取 |
| `dep_tracker.v` | ~80 | 从 myCPU.v 提取 |
| `issue_scoreboard.v` | ~60 | 从 myCPU.v 提取 |
| `OF1_stage.v` | ~200 | 新模块 |
| `OF2_stage.v` | ~200 | 新模块 |
| `shadow_forward.v` | ~120 | 从 OF_stage.v 提取 |
| `AGU.v` | ~50 | 从 OF_stage.v 提取 |
| `branch_resolve.v` | ~80 | 从 OF_stage.v 提取 |
| `mul_queue.v` | ~100 | 从 myCPU.v 提取 |

---

## 6. 优先级排序与实施路线

### 优先级矩阵

```
                    高收益
                      │
         P1-StoreBuf  │  P0-OF拆分
         P1-模块化    │
                      │
    ──────────────────┼──────────────────
         低风险       │       高风险
                      │
         P3-Slot1    │  P2-保留站
         P2-Shadow   │
                      │
                    低收益
```

### 实施路线图

```
Phase 1（1-2 周）：基础模块化
├── 提取 store_buffer.v
├── 提取 load_unit.v
├── 提取 pipeline_control.v
├── 提取 dep_tracker.v
└── 提取 issue_scoreboard.v

Phase 2（2-3 周）：OF 拆分 + Store Buffer 扩大
├── 拆分 OF → OF1 + OF2
├── 创建 shadow_forward.v
├── 创建 AGU.v
├── 创建 branch_resolve.v
├── Store Buffer 2 → 4 entries
└── 调整 BPU 更新时序

Phase 3（1-2 周）：Shadow Forwarding 简化
├── 移除 SHADOW_COMPARE
├── 移除 SHADOW_SIMPLE
├── 移除 SHADOW_PC4
└── 验证时序改善

Phase 4（2-4 周，可选）：性能增强
├── 增加 4-entry Reservation Station
└── 扩展 Slot-1 支持 Load/前递
```

### 各阶段验证策略

| Phase | 验证方法 |
|-------|---------|
| Phase 1 | 等价性检查：拆分前后仿真结果完全一致 |
| Phase 2 | 功能仿真 + 时序收敛检查 + IPC 对比 |
| Phase 3 | 功能仿真 + 功耗对比 |
| Phase 4 | 功能仿真 + IPC 性能对比 + FPGA 实测 |

---

## 附录 A：关键信号索引

| 信号 | 描述 | 来源 |
|------|------|------|
| `pl_suspend` | 全局流水线暂停 | OR of all suspend sources |
| `ldst_suspend` | Load 引起的暂停 | `MEM_stage.v` |
| `mul_div_suspend` | MUL 引起的暂停 | `myCPU.v` |
| `store_buffer_suspend` | Store Buffer 满引起的暂停 | `myCPU.v` |
| `early_load_hold` | Load-Use 冒险暂停 | `myCPU.v` |
| `front_redirect_valid` | 前端重定向有效 | 来自 ID2/OF |
| `pred_error` | 分支预测错误脉冲 | 来自 BPU |
| `of_shadow_repair_and` | Shadow AND 修复标志 | `OF_stage.v` |
| `m1_store_load_conflict_r` | Store-Load 冲突标志 | `myCPU.v` |

## 附录 B：文件依赖关系图

```
myCPU.v
├── IF_stage.v ─────── PC.v, NPC.v
├── IBUF.v
├── ID_stage.v ─────── CU.v, EXT.v, RF.v, ID1_target_precompute.v,
│                      slot1_narrow_decode.v
├── ID1_ID2.v
├── OF_stage.v ─────── data_forward.v, CSRFile.v
├── ID_EX.v
├── EX_stage.v ─────── ALU.v
├── EX2_stage.v
├── MEM_stage.v ────── EX_MEM.v, MEM_REQ.v
├── MEM_WB.v
├── WB_stage.v
├── BPU.v ──────────── RAS.v
├── AddressTranslate.v
├── restricted_slot1_lane.v
└── async_fifo.v
```
