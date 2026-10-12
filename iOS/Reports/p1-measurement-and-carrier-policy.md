# P1：状态感知的性能测量（第一版）

日期：2026-10-12。设备：iPhone 14 Pro（A16，iOS 27.0），mobile 档位，Release，30 秒/例 quick 模式，worker 上限不限，userInitiated QoS。

## 1. 新增的测量能力

| 能力 | 落地位置 |
| --- | --- |
| 阶段边界 Signpost（九个阶段） | `Sources/AnalogCore/TVSignpost.swift`，引擎与接收机内共 18 个 begin/end；默认零开销，`--benchmark-signpost` 或 `TV_SIGNPOST=1` 打开 |
| 载波策略遥测 | `TerrestrialReception.carrierTracked / carrierEstimationDecimation / carrierPLLStrideUsed`，逐帧写入基准报告 |
| 帧连续性与阶段进度 | `frameIdentity` / `frameContinuity`（P0），报告里 `continuity` 字段与 repeat 计数 |
| 三类接收状态基准 | `--benchmark-regime lock｜edge｜loss` |
| 阶段外开销度量 | 报告与 `summarize.py` 的 `unattributedMS` |

Signpost 的一条实操教训：**Time Profiler 模板在 iOS 上默认不采集 signpost**，空表会误导。必须显式加 instrument：

```sh
xcrun xctrace record --template 'Time Profiler' \
  --instrument 'Points of Interest' --instrument 'os_signpost' \
  --device <UDID> --time-limit 70s --output sig.trace \
  --launch -- com.analine.benchmark --benchmark-signpost --benchmark-quick --benchmark-regime edge
xcrun xctrace export --input sig.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]'
```

（表格里 `signpost-name` 与 `process` 都会以 `ref` 复用，解析要两趟建 id 映射。）

## 2. 三类基准的基线（改前，14 Pro）

| 场景 | PAL 平均 | vs 锁定 | NTSC 平均 | vs 锁定 | 载波策略 | 锁定率 |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 稳定锁定 | 30.75 | — | 22.06 | — | tracked 100%、降率 100% | 100% |
| 捕获边缘 | 40.03 | **+30%** | 29.80 | **+35%** | **tracked 0%、降率 0%** | 100% |
| 持续失锁 | 45.77 | **+49%** | 33.29 | **+51%** | tracked 100%、降率 100% | **0%** |

两个问题的答案（P1 验收标准的前两条）：

1. **载波失锁让成本增加**：捕获边缘 +30…+35%，持续失锁 +49…+51%。
2. **全速 AFC/PLL 占据多少**：Signpost 实测（edge 场景，1398 帧）载波 PLL 6.34 ms + 载波估计 2.77 ms = **9.1 ms，约占 40 ms 帧预算的 23%**。其中大部分本可省掉，因为该场景其实一直锁着。

同一批 Signpost 数据的阶段墙钟（14 Pro，edge，均值/P95 ms）：载波 PLL 6.34/8.65、调制（含合并）6.64/8.50、检测 4.48/5.78、解码 4.30/4.71、合并 4.29/5.74、信道 3.50/7.07、载波估计 2.77/3.57、伴音 1.59/1.97。（`frontEnd` 24.3 ms 是父区间，包含四个接收机子阶段，不可相加。）

3. **可消除的同步等待**：`unattributedMS`（阶段之外：校验、分配、原子提交、线程调度与 join）实测只有 **0.02…0.07 ms**。也就是说时间确实都在阶段内部，P2 要解决的不是"阶段之间的空隙"，而是**阶段内部的串行部分**。
4. **谁决定持续吞吐上限**：在 edge 这类边缘场景，接收机内部链（估计+PLL+检测+解码 ≈ 17.9 ms）加上前端自身（≈6.4 ms）占了一帧的约六成。

## 3. 由测量直接驱动的修复（P3 第一项）

基线的载波判据在两个方向都错：

- 捕获边缘**明明锁着（738/738）却 0% 降率**——白跑密集 AFC/PLL；
- 持续失锁**一帧没锁却 100% 降率**——噪声功率骗过了"载波存在"判据。

原判据是我早先写的 `captured && |measured| < 100 kHz` 频率余量规则。改为按**接收机是否真的锁定**判定，并把策略分成三级（`TVChainProfile.sustainedLossFrames`，默认 8 帧）：

| 进入本帧时的状态 | 策略 | 理由 |
| --- | --- | --- |
| 已锁定 | 降率（PLL 步长 2、AFC 8×） | 正在正常接收 |
| 刚失锁（< 8 帧） | 密集 | 可能只是短暂跌落，快速重捕 |
| 持续失锁（≥ 8 帧） | 重新降率 | 噪声信道上全速搜索不会更快，只是白烧时间 |

**真机验证**（同样协议；热漂移很大，用解码+同步这两个判据无法影响的阶段做热探针归一化）：

| 场景 | 系统 | 原始变化 | 热因子 | **归一化变化** | 策略（改后） | 锁定率 |
| --- | --- | ---: | ---: | ---: | --- | ---: |
| 稳定锁定 | PAL/NTSC | +3.8% / +4.8% | 1.047 / 1.042 | −0.8% / +0.6% | tracked 100%、降率 100% | 100% |
| 捕获边缘 | PAL/NTSC | +22.9% / +13.1% | 1.394 / 1.219 | **−11.8% / −7.2%** | tracked 100%、降率 100% | 100% |
| 持续失锁 | PAL/NTSC | +12.3% / +3.5% | 1.127 / 1.035 | −0.4% / ±0.0% | tracked **0%**、降率 99% | 0% |

三点结论：边缘场景省下约 7–12%；持续失锁回到基线但**遥测不再说谎**（tracked 0%），且在 8 帧瞬态窗口后不再维持最高成本；锁定场景不变。捕获范围、锁定率、伴音与画面数值均未放宽（既有 158 项回归全过）。

**另一条必须记住的方法论**：这台设备同一二进制在不同时段的耗时差可达 **1.4 倍**（热因子 1.394）。任何跨时段比较都必须做热探针归一化，否则会把降频读成代码效果——本轮如果没有归一化，就会误判"判据修复让边缘场景变慢 22.9%"。

## 4. 阶段**内部**并行度（Signpost 区间 × Time Profiler 逐核采样）

方法：把 `OSSignpostIntervals` 的每个阶段区间当作时间窗，统计窗内 Time Profiler 的逐核采样数（1 采样 = 该核 1 ms），于是 CPU 毫秒 / 墙钟毫秒 = 该阶段实际用到的并行度。14 Pro，edge 场景，约 1150 个区间/阶段：

| 阶段 | 墙钟均值 ms | CPU 均值 ms | 内部并行度 | P 核 ms | E 核 ms | 串行占比 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| frontEnd（父区间） | 15.50 | 30.08 | 1.94× | 22.04 | 8.04 | 52% |
| modulation（含 combination） | 4.60 | 18.12 | 3.94× | 9.55 | 8.58 | 25% |
| **carrierPLL** | 3.58 | 5.16 | **1.44×** | 4.77 | 0.40 | **69%** |
| decode | 3.21 | 10.33 | 3.22× | 6.23 | 4.10 | 31% |
| detection | 3.06 | 6.52 | 2.13× | 4.94 | 1.58 | 47% |
| combination（嵌在 modulation 内） | 3.01 | 14.31 | 4.75× | 6.82 | 7.48 | 21% |
| channel | 2.40 | 5.86 | 2.44× | 4.05 | 1.81 | 41% |
| sound | 1.18 | 3.66 | 3.10× | 2.62 | 1.03 | 32% |
| carrierEstimation | 1.00 | 2.17 | 2.16× | 2.16 | 0.00 | 46% |

（`frontEnd` 是父区间，包含后四个接收机阶段，不能与其子项相加。）

结论：

- **载波 PLL 是最大的串行瓶颈**：并行度只有 1.44×（69% 串行），而且几乎全在性能核上（4.77 P-ms 对 0.40 E-ms）。它的墙钟（3.58 ms）也是所有叶子阶段里最高的。
- 检测（2.13×）、载波估计（2.16×）、信道（2.44×）同样偏低；调制/合并/解码/伴音的并行度在 3.1–4.8×，已经不错。
- 载波估计**完全没有用到能效核**，只在性能簇上跑——短而小的任务没有铺开。

## 5. P2 的两条硬约束（本轮发现）

**（1）跨帧反馈把发射半链和接收半链串起来了。** 统一引擎的前端 AGC 是块反馈：第 N+1 帧的公共增益来自第 N 帧接收端测得的 `agcTargetDB`。只要 `frontEnd.agcEnabled` 打开，发射半链（调制/合并/信道）就必须等接收半链完成，**发射/接收二级流水线不成立**。默认与基准场景里它是关闭的，所以流水线在常见路径上可行，但必须在打开时回落到顺序执行——这一点必须在 P2 的设计里显式处理，否则会悄悄改变 AGC 收敛行为。

**（2）流水线的收益上界可以直接算出来。** 用上面的墙钟/CPU 数据（edge 场景一帧）：

| 分组 | 墙钟 ms | CPU ms | 内部并行度 |
| --- | ---: | ---: | ---: |
| 发射半链 modulation+channel | 7.00 | 23.98 | 3.4× |
| 接收半链 frontEnd+sound | 16.68 | 33.74 | 2.0× |
| 顺序合计 | 23.68 | 57.72 | 2.4× |

- 现在：23.7 ms 墙钟（+编码与预览约 8 ms）。
- 二级流水线（发射 N+1 与接收 N 重叠）：受接收半链墙钟约束 ≈ **16.7 ms**，即 **−30%**；CPU 合计 57.7 ms 摊到 6 核只是 9.6 ms，说明核数不是限制，**接收半链内部的串行部分是**。
- 更深流水线的下界由串行段决定：PLL 69%×3.58 ≈ 2.5 ms、检测 47%×3.06 ≈ 1.4 ms、估计 46%×1.00 ≈ 0.5 ms，合计约 4.4 ms/帧。所以 P2 的现实目标是从 2.4× 提到 3.5–4×，而不是逼近 6×。

## 6. 尚未做（P1 剩余与 P2 输入）

- 阶段内部并行度已量化（见第 4 节）；下一步是把同一方法用到标准四场景（含损伤）与长期热态上，确认串行瓶颈排序在持续负载下不变。
- 等待/提交边界只有 `unattributedMS` 这一粗粒度指标；Signpost 目前标记的是阶段区间，还没有标记"提交边界"与"等锁/等线程"的独立区间。
- 三类基准目前只覆盖接收机工作点，还没有覆盖"反复切换策略"的抖动统计（例如 edge 场景下的策略切换次数）。

## 5. 文件

- `Sources/AnalogCore/TVSignpost.swift`（新增）、`TVChainProfile.swift`（新增 `sustainedLossFrames`）
- `Sources/AnalogCore/TVUnifiedChannelEngine.swift`、`Terrestrial.swift`（Signpost、三级策略、遥测）
- `iOS/BenchmarkApp.swift`（三类基准、`unattributedMS`、载波策略逐帧字段）、`iOS/summarize.py`
- 原始数据：`Reports/regime-{lock,edge,loss}.json`（基线）、`Reports/tier-{lock,edge,loss}.json`（三级策略后）、`Reports/after-standard.json`（标准四场景）
