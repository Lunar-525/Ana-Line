# P0：确定性状态管理基础（第一刀）

日期：2026-10-12。范围：统一信道引擎（`TVUnifiedChannelEngine`）的帧身份、状态所有权、原子提交、进度追踪与异常策略。硬约束：不改帧率、不产生可见观感变化、不改信号模型。

## 1. 落地内容

新增 `Sources/AnalogCore/TVProcessContract.swift`：

| 类型 | 作用 |
| --- | --- |
| `TVFrameIdentity` | 帧号 + 该帧覆盖的精确输入采样区间（`sampleStart`/`sampleCount`/`sampleEnd`）。阶段提交的是身份，不是裸计数器。 |
| `TVFrameContinuity` | `first` / `continuous` / `forwardGap(skippedSamples:skippedFrames:)` / `repeatOrRewind`。跳变被**记录并分类**，不隐藏。 |
| `TVStage` | 九个阶段：调制、合并、信道、前端、载波估计、载波 PLL、检测、伴音、解码。 |
| `TVStageProgress` | 单阶段的已提交身份、提交次数、跳变次数、重复次数。 |
| `TVProgressLedger` | 各阶段进度；`stagesBehind(frameIndex:)` 直接回答"哪个阶段没跟上"。 |
| `TVProcessDiagnostics.injectedFault` | 故障注入钩子（五个注入点），供验收测试证明回滚。 |

引擎侧：

- `process` 改为**原子提交**：`var candidate = self` → `processFrame` 全程只改候选 → 成功才 `self = candidate`。任何阶段抛错，引擎（含各路 FIR 历史、PLL 相位、AGC、同步、信道 RNG 与回声尾巴）**逐位不变**。
- 九个阶段在各自完成后提交身份；由于候选在失败时整体丢弃，不存在"部分提交"。

## 2. 验收证据

新增 `Tests/AnalogCoreTests/TVProcessContractTests.swift`（7 项，全通过；全量 158 项 0 失败）：

| 测试 | 断言 |
| --- | --- |
| `testIdentityTracksTheFrameSampleGrid` | 身份的帧号与采样区间等于该制式的采样栅格；九个阶段各提交一次/帧；无跳变。 |
| `testRepeatedFrameIsRecordedAndCounted` | 重复帧被接受并计为 `repeatOrRewind` + 计数。 |
| `testStrictOrderRefusesARepeatWithoutAdvancing` | 严格模式（可选）下重复帧被拒，且**进度不前进**。 |
| `testForwardGapIsRecordedAndAccepted` | 向前跳变被接受并记录跳过的样本数与帧数。 |
| `testInjectedFaultRollsBackEveryStage` | 五个注入点（含最后的 `beforeCommit`）分别失败后，随后各帧输出与"从未失败过"的参照引擎**误差 < 1e-7**，且进度计数不变。 |
| `testProgramFaultAndLockLossStayDistinct` | 失锁是接收机模型的一部分：不抛错、继续推进物理时间；程序级违约在严格模式下被拒。 |
| `testCarrierStrategyIsReportedPerFrame` | 捕获帧必须走密集路径；跟踪后按档位降低更新率。 |

## 3. 过程中发现的两件事

**（1）播放器会故意重送同一帧，而且代价是 3 帧。**
`TVRenderer` 在 seek 或暂停重渲染时新建引擎，并用 `[max(0,frameIndex-2), max(0,frameIndex-1)]` 送两帧预热稳定环路。因为 `max(0,…)` 夹取，**时间轴开头会把第 0 帧连送三次**；其余 seek 每次也多算 2 帧。因此"重复帧"在本应用里是**故意行为**，不是违约：账本改为记录并计数（`progress.totalRepeats`，基准报告里也有 `repeatFrames`），严格拒绝改为可选（`engine.strictFrameOrder`）。这条也是 P2 的输入：seek 开销 3× 是流水线可以吃掉的那类成本。

**（2）载波策略有一处与注释契约不符的缺陷，已修。**
AFC 抽取用的是**上一帧**的跟踪状态，而 PLL 步长用的是**本帧刚算出**的状态，导致"捕获帧"的 PLL 可能已经被降到 1/N——正是 P3 里"捕获边缘"的风险。现改为两者都取自进入本帧时的状态（`trackedOnEntry`），捕获与重捕获一律走密集反馈。这**提升**了捕获帧的精度，代价只是每个捕获帧多算一点。

## 4. 状态与遥测

- 引擎新增只读 `progress`（各阶段身份/提交/跳变/重复计数），`stagesBehind(frameIndex:)` 可直接定位滞后阶段。
- `TerrestrialReception` 新增：`frameIdentity`、`frameContinuity`、`carrierTracked`、`carrierEstimationDecimation`、`carrierPLLStrideUsed`。
- iOS 基准报告（schema 3 字段扩展）逐帧记录 `continuity`/`carrierTracked`/`afcDecimation`/`pllStride`，`iOS/summarize.py` 输出 tracked/afc/pll 占比与 repeat 帧数——**"失锁让成本涨多少"现在可以直接从报告读出来**，这正是 P1 要回答的第一个问题。

## 5. 尚未做（留给后续）

- 接收机内部（`TerrestrialReceiver`）仍是单次调用内跑完估计/PLL/检测/解码，没有自己的进度账本；P2 做流水线时需要拆出独立的阶段进度与提交边界。
- `TerrestrialEngine`（旧参考路径）未加同样的账本，仅在统一引擎上落地。
- seek 的 3 帧预热开销尚未消除，只是被记录下来了。
