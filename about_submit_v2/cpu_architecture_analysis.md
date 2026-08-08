# CPU 架构分析报告

> 项目：`submit_v2` (LoongArch 32-bit 受限双发射处理器)
> 日期：2026-08-08
> 目标：四项性能测试（STREAM / MATRIX / CRYPTONIGHT / MIXED）执行时间最小化

---

## 一、架构总览

### 1.1 流水线结构

```
IF        ID1         ID2         OF/AG_BR        EX            EX2/M1        MEM/M2       WB
──┼─────────┼───────────┼───────────┼───────────────┼─────────────┼─────────────┼────────────┼──
 PC生成    解码        发射槽      操作数获取      执行          访存请求      访存完成     写回
 BPU查询   RF读(×4)   依赖标记    AG地址生成     ALU+MUL发射   SRAM请求      Load扩展    RF写
 RAS查询   双发射配对  等待/持有   分支比较+重定向  转发shadow    Store入队     MUL收结果
 IBUF管理  系统串行化              shadow ALU     Store数据冲突  地址翻译
```

- **Slot-0**：完整指令支持（访存、分支、乘除、系统指令）
- **Slot-1**：仅简单整数 ALU 指令（`slot1_narrow_decode.v`）：ADD/SUB/AND/OR/XOR/NOR/SLL/SRL/SRA/SLT/SLTU 及其立即数形式 + LU12I/PCADDU12I。无访存/分支/MUL/DIV/CSR。

### 1.2 关键组件配置

| 组件 | 配置 |
|---|---|
| ICache | 32 行 × 8 word/行 = 1KB，直接映射 |
| DCache | 32 行 × 8 word/行 = 1KB，直接映射，双 bank（512×32 TDP BRAM） |
| RWC (Random Word Cache) | 512 KiB（128K 条目），直接映射，generation-based 无效化，仅自适应模式下启用 |
| BPU | 128 条目 BHT + 2-bit 饱和计数器 + 8-bit XOR 折叠标签 + 8 条目 RAS |
| Store Buffer | 2 条目有序写缓冲，带精确 Store→Load 消歧 |
| MUL | 3 级 DSP 流水线（mult_gen_0），II=1，结果队列 |
| IBUF | 4 条目指令缓冲，支持双 pop |

### 1.3 频率与资源

- 目标器件：xc7a200tfbg676-2
- CPU 时钟：150 MHz（通过 PLL 从 50MHz 生成）
- SRAM 时钟：~51 MHz（独立时钟域，异步 FIFO 桥接）

---

## 二、流水线划分分析

### 2.1 各级详细职责

#### IF（取指）
- PC 生成，BPU 异步查询（同周期出预测结果）
- ICache 请求/响应握手
- IBUF push/pop 管理
- 重定向处理（来自 OF 的 mispredict 或 ID2 的前端重定向）

#### ID1（解码 + 寄存器读取）
- 双 IBUF head 并行解码（head0 + head1）
- 4 读端口 RF（`RF_4R2W`）：head0 的 rj/rk + head1 的 rj/rk
- 双发射配对资格判定（`slot1_narrow_decode`）
- 立即数扩展（5/12/16/20/26-bit）

#### ID2（发射槽 / 依赖标记）
- 单条目指令持有寄存器
- 9-bit writer tag 编码：`{S1_OF, S0_OF, S1_EX, S0_EX, S1_M1, S0_M1, S1_M2, S0_M2, S1_WB}`
- 依赖等待判定：system 串行化 / branch resolve 冲突 / slot0_lane1_wait
- WB 旁路刷新（ID2 中等待的指令可从 WB 直接获取最新值）

#### OF/AG_BR（操作数获取 / 地址生成 / 分支解析）
- **操作数转发**：从 4 个来源（EX/M1/M2/WB）选择 r1/r2，分 data/control/memory/mul 四套独立转发路径
- **Shadow ALU**：6 类预计算结果（ADDSUB/LOGIC/SHIFT/COMPARE/SIMPLE/PC4），消费者按类选取
- **地址生成**：`rj + immediate` 同时产生 mem_addr 和 order_addr_key
- **分支解析**：6 种条件分支比较器 + JIRL 目标验证 + mispredict 重定向
- **Deferred branch**：有依赖的分支在 OF 等待操作数就绪
- **弹性边界**：可 hold（`of_operand_wait`）等待未就绪的 producer

#### EX（执行）
- ALU 运算（ADD/SUB/AND/OR/XOR/NOR/SLL/SRL/SRA/SLT/SLTU）
- MUL 提前发射（从 ID2 payload 发起 DSP，隐藏一级流水）
- 操作数局部旁路（Load→XOR, Load→SLL by 1 等热路径零气泡）
- MUL→ADD 零气泡转发（`ex_exec_mul_late` 路径，仅限 `MUL.W → ADD.W(rj)` 形状）
- Store 数据 Load 依赖处理
- 对齐检查

#### EX2/M1（访存请求）
- 物理地址生成（DMW 翻译后高 3-bit 与低 29-bit 合并）
- 读请求发出（Byte enable 生成）
- Store 入队（进入 2 条目 Store Buffer）
- 提前 Load 探测（`ex_load_probe_valid` → DCache 可提前启动单字请求）
- MUL 结果捕获（`ex_late_mul_arch_valid`）

#### MEM/M2（访存完成）
- Load 结果对齐/扩展（byte/half/word + 符号/零扩展）
- 写回数据选择（ALU/RAM/CSR/PC+4）
- Store 退休跟踪
- MUL 结果队列管理

#### WB（写回）
- 最终 mux 选择写回值
- RF 写端口（slot-0 + slot-1 各自独立写端口）

### 2.2 关键时序路径分析

#### OF 级 —— 最复杂的单级
OF 同时承担操作数转发 + 地址生成 + 分支解析，是三合一的设计。代码中存在大量 `(* keep = "true", dont_touch = "true", max_fanout = ... *)` 属性，说明该级是时序收敛焦点。

**关键决策**：有依赖的操作数在 OF 等待一拍，避免 late Load/MUL 结果进入 OF 的组合逻辑路径：
> "A normal EX producer uses a duplicate ALU... If that producer is itself consuming a late Load/MUL result... Those consumers wait one cycle for the M1 register."

#### EX→OF 转发路径
EX 的 shadow forwarding 结果在 EX 级预计算，下一周期 OF 可直接使用，避免 live ALU 输出 → OF mux 的同周期路径。

#### RWC 元数据路径
512 KiB RWC 的 BRAM 输出 → tag 比较 → 命中判断 —— 这是跨 128K 深 BRAM 的路径。设计通过以下方式处理：
- 4 bank 拆分（每 bank 32K×19 bit），bank 选择在 EX 级注册
- 命中结果在 M1 级注册后才驱动 CPU 响应路径
- 独立的 `rwc_hit_request_r` 副本用于请求发射，避免高 fanout Q 跨芯片路由

### 2.3 流水线瓶颈

#### 瓶颈 1：ID2 单槽位发射队列
```
ID2:  [ 一条指令 | 或空 ]
        ↑ 满则阻塞 ID1 和 IBUF
```

阻塞条件：
```verilog
wire id_boundary_block = id_issue_block |
    (!front_redirect_from_of_r && of_valid &&
     (early_load_hold || of_operand_wait));
```

当 ID2 中的指令在等待（Load 依赖、系统指令提交、Branch resolve 冲突），整个前端全部停摆。无乱序处理器的 ROB 来缓冲。

#### 瓶颈 2：OF 级职责过重
三合一设计（操作数转发 + AG + BR）使 OF 成为可变延迟级。有依赖的分支在此额外停顿。

#### 瓶颈 3：单指令取指宽度
ICache 每周期最多 32-bit。双发射仅在 IBUF 有缓存时发生，一旦排空即回到单发射。

---

## 三、CPU 结构缺陷分析

### 3.1 按四项测试影响排序

#### 🔴 缺陷 1：单指令取指瓶颈（影响全部测试）

IBUF/ICache 每周期最多取一条指令。热循环指令中大量是 slot-0-only（ld.w / st.w / mul.w / 分支），无法配对。

| 测试 | 热循环指令 | 可配对比例 |
|---|---|---|
| STREAM | ld.w, st.w, addi, addi, bne（5条） | 仅 2/5 (addi) |
| MATRIX | 大量 mul.w + ld.w + add.w + st.w | < 20% |
| CRYPTONIGHT | 复杂依赖链 | < 30% |
| MIXED | 混合指令 | < 30% |

#### 🔴 缺陷 2：Slot-1 过于受限

仅支持简单 ALU 操作。ld.w / st.w / mul.w / 分支全部只能在 slot-0 执行。RTL 注释中明确排除了 MUL（即使共享 3R 指令格式）。

#### 🔴 缺陷 3：DCache 容量（1KB）vs 工作集（2-3 MiB）

| 测试 | 工作集 | DCache 覆盖率 | Miss 代价 |
|---|---|---|---|
| STREAM | 3 MiB | 0% | 每次 8-word refill |
| MATRIX | A+B+C=108KB | ~0.9% | 直接映射冲突严重 |
| CRYPTONIGHT | 2 MiB scratchpad | 0.05% | 随机访问几乎全 miss |
| MIXED | 64KB+64KB | ~1.5% | 随机部分大量 miss |

**但对 CRYPTONIGHT 有自适应缓解**（见 4.1 节）。

#### 🟡 缺陷 4：无硬件预取

STREAM（3 MiB 顺序拷贝）和 MATRIX（规则步长访问）可从预取中极大受益，当前设计无任何预取逻辑。

#### 🟡 缺陷 5：Store Buffer 仅 2 条目 + 写通 DCache

- 2 条目满 → `store_buffer_full` → 流水线停顿
- 写通设计意味着每次 store 最终都要到达 SRAM
- DCache 读写共享单 BRAM 端口 —— refill 期间 store 被阻塞

#### 🟡 缺陷 6：MUL 3 拍延迟

虽然 II=1 可以连续发射，但 3 拍延迟意味着 `C[i][j] += A[i][k] * B[k][j]` 中 add 必须等 mul 完成。通过 `ex_exec_mul_late` 路径（MUL→ADD 零气泡）部分缓解。

#### 🟡 缺陷 7：BPU 预测精度受限

- 仅 2-bit 饱和计数器，无全局历史/相关预测
- 8-bit XOR 折叠标签 → 别名冲突
- CRYPTONIGHT 中数据依赖的分支几乎必然 mispredict
- MIXED 中 `if (state & 1)` 预测准确率约 50%

#### 🟢 缺陷 8：Branch 解析延迟不对称

| 分支类型 | 解析位置 | 误预测惩罚 |
|---|---|---|
| 条件分支（操作数就绪） | OF | ~2 周期 |
| JIRL（寄存器跳转） | OF（等 rj） | ~3-4 周期 |
| 有依赖的分支（deferred） | OF 等待 | ~4-6 周期 |

#### 🟢 缺陷 9：DCache 直接映射冲突

MATRIX 的 A/B/C 三矩阵各 36KB（128-word 行跨度 = 512B/行）。在 1KB 直接映射 cache 中，不同矩阵元素可能映射到同一 line，不断 evict。

#### 🟢 缺陷 10：RAS 深度有限（8 条目）

对大多数场景够用，但边界情况可能溢出导致误预测。

---

## 四、自适应 DCache 策略详解

### 4.1 两级自适应机制

```
                        ┌─────────────────────────────┐
                        │  Line Mode（默认）            │
                        │  1KB DCache, 8-word refill    │
                        │  ┌───────────────────────┐    │
                        │  │ 连续 32 次 miss        │    │
                        │  │ 无一次 hit 打断        │───▶│ adaptive_word_mode
                        │  └───────────────────────┘    │
                        └─────────────────────────────┘
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │  Word Mode（自适应单字）      │
                        │  单字 refill, no-allocate     │
                        │  + 启用 512 KiB RWC          │
                        │  ┌───────────────────────┐    │
                        │  │ 连续 3 次空间局部访问   │───▶│ 切回 Line Mode
                        │  └───────────────────────┘    │
                        └─────────────────────────────┘
```

**阈值**：
- 触发条件：`ADAPT_MISS_THRESHOLD = 31`（32 次连续 miss）
- 回切条件：`ADAPT_LOCAL_THRESHOLD = 3`（3 次同 32B 区域或连续地址）

### 4.2 RWC (Random Word Cache)

- 512 KiB 直接映射（128K × 32-bit）
- 单字粒度，no-allocate 策略
- Generation-based 无效化（6-bit generation tag，CACOP 时递增）
- 4 bank 元数据 BRAM，bank 选择在 EX 级注册
- Store 也写入 RWC（`rwc_store_event`）

### 4.3 对 CRYPTONIGHT 的影响

CRYPTONIGHT 执行分两阶段：

| 阶段 | 访问模式 | DCache 行为 |
|---|---|---|
| 初始化 524,288 words | 完全顺序写 | Line mode 正常工作 |
| 主循环 1,048,576 次 | 完全随机 (r5 & 0x7FFFF) | 32 次 miss → 切 word mode + RWC |

RWC 命中率：$\frac{512\text{ KiB}}{2\text{ MiB}} = 25\%$

- ✅ 不再做 8-word line fill（SRAM 带宽从 12.5% 恢复到 100%）
- ✅ 25% 访问命中 RWC，免除 SRAM 往返
- ❌ 75% 仍 miss 到 SRAM（512 KiB 对 2 MiB 的硬伤）

### 4.4 对 STREAM 的影响

STREAM 是 3 MiB 完全顺序访问。自适应机制**不应该**触发（每次 miss 后很快会遇到同一 line 的 hit，miss streak 会中断）。但如果触发，`adaptive_local_read` 条件（3 次局部访问）会立即切回。

---

## 五、亮点设计

| 设计 | 说明 |
|---|---|
| **Shadow Forwarding** | 按操作分类的影子寄存器（ADDSUB/LOGIC/SHIFT/COMPARE/SIMPLE/PC4），减少转发 mux 深度 |
| **Writer Tag 系统** | 9-bit one-hot 编码依赖关系，在 ID2→OF 边界一次性解析，后续不再做 5-bit 寄存器号比较 |
| **MUL 提前发射** | 从 ID2 payload 发起 DSP，隐藏一级流水延迟 |
| **自适应 DCache + RWC** | 自动检测随机访问模式，切换单字 no-allocate + 512 KiB RWC |
| **Deferred Branch** | 有依赖的分支在 OF 等待而非一律延迟到 EX |
| **M1 请求与 Store 解耦** | 读请求直接发射，Store 通过有序 buffer 发出，避免地址 CAM |
| **OF 弹性边界** | 可以在等待操作数时 hold，形成 1 条指令的微型 decouple buffer |
| **MUL→ADD 零气泡** | `ex_exec_mul_late` 路径专为 `MUL.W → ADD.W(rj)` 优化 |
| **Load→XOR/SLL 零气泡** | CRYPTONIGHT 热路径：Load→SLLI.W #1→XOR 无需额外气泡 |

---

## 六、优化建议优先级

| 优先级 | 建议 | 预期收益 | 影响测试 | 代价 |
|---|---|---|---|---|
| **P0** | 扩大 DCache 至 8KB+（256 行）或增加 RWC 容量 | CRYPTONIGHT miss 率降低 | CRYPTONIGHT | BRAM 用量 |
| **P0** | ICache 升级为双指令取指（64-bit 口） | IPC +0.3~0.5 | 全部 | 前端复杂度 |
| **P1** | 添加顺序预取器（stream prefetcher） | STREAM CPI 接近 1 | STREAM/MATRIX | ~200 LUT |
| **P1** | 将 ld.w 加入 slot-1 配对（需第二 AG/DCache 端口） | IPC +0.2~0.3 | STREAM/MATRIX | 面积大 |
| **P2** | 扩大 Store Buffer 至 4-8 条目 | 减少 store 停顿 | MATRIX/CRYPTONIGHT | ~300 FF |
| **P2** | BPU 升级为 gshare（全局历史 + XOR 索引） | 分支预测精度 +5-10% | CRYPTONIGHT/MIXED | ~500 LUT |
| **P3** | Loop buffer（缓存热循环指令） | 消除 ICache 访问 | 全部 | ~512 LUT |
| **P3** | DCache 改为 2-way 组相联 | 减少 MATRIX 冲突 miss | MATRIX | 时序压力 |

---

## 七、基线性能参考

与在线板卡 374ms 结果对应的完整镜像周期数：

| 测试 | 周期数 | 占比 |
|---|---:|---:|
| STREAM | 5,498,240 | 10.0% |
| MATRIX | 10,910,319 | 19.8% |
| CRYPTONIGHT | 38,348,476 | 69.5% |
| MIXED | 405,093 | 0.7% |
| **合计** | **55,162,128** | 100% |

CRYPTONIGHT 占 69.5%，是优化的主要目标。其瓶颈本质是 2 MiB 随机工作集对 512 KiB RWC 的比率问题，而非流水线或控制逻辑缺陷。

---

## 八、总结

该 CPU 是一个**精心优化的受限双发射顺序处理器**。主要结构性特征：

1. **7 级流水线**，OF 级职责最重（三合一设计），是时序收敛焦点
2. **单指令取指 + 受限双发射**，实际 IPC 接近 1.0-1.2
3. **自适应两级缓存系统**，对 CRYPTONIGHT 的随机访问有专门的 512 KiB RWC
4. **丰富的转发优化**：shadow forwarding、MUL→ADD 零气泡、Load→XOR/SLL 零气泡
5. **Writer tag 依赖追踪系统**，避免重复的 5-bit 寄存器号比较

架构已达到当前设计约束下的高水平。进一步优化应优先考虑：扩大 RWC 容量、双指令取指、以及硬件预取。
