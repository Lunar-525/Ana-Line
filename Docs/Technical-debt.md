# 待处理技术债

审查：2026-10-12 05:00。基线：工作区（HEAD `aaa9919` 加 20 个未提交修改），非干净提交。

**此清单当前优先级低于 iOS 移植。** 等 iOS 移植跑通、性能验收完成后再逐条处理。处理前请重新核对位置：审查期间文件仍在改动（`Terrestrial.swift` 已从 973 行增至 1115 行），下面给出的行号会漂移，符号名和函数名是稳定的定位依据。

审查时的规模：源码 11,068 行、测试 4,872 行、文档 1,251 行，`swift build` 通过，仅一条已弃用 API 警告。

## 处理顺序

| 顺序 | 事项 | 预估 | 理由 |
| --- | --- | --- | --- |
| 1 | 建立提交边界 | 10 分钟 | 目前唯一没有回滚点的区域 |
| 2 | 双路径数学去重 | 约 1 小时 | 唯一会**静默**产生错误的一项 |
| 3 | 最小 CI | 约 1 小时 | 让第 2 项的等价性测试自动执行 |
| 4 | GUI 状态单向化 | 半天 | 必须在继续加控件**之前**做 |
| 5 | 零散清理 | 各 5～20 分钟 | 随时可做，无依赖 |

---

## 1. 建立提交边界

**位置**：工作区。

**现象**：20 个已修改文件（+612 / −151）未提交，另有 7 项未跟踪，含整个 `iOS/` 基准 App、`Demos/`、`build.sh`、`TVChainProfile.swift`、`TVMobileOptimizationTests.swift`、`TVMobileProfileTests.swift`、`WorkspaceGlassBackground.swift`。

**风险**：提交历史显示约 10 个内聚提交/天，最后一次提交停在 10-10 21:13。当前这个缺口已经比历史上任何两个提交之间的间隔都长，是唯一无法回滚到已知良好状态的位置。

**建议**：按功能切分提交（iOS 移植脚手架 / 基准 App / 移动端剖析与测试 / 构建脚本）。不需要整理成完美历史，只需要有回滚点。

---

## 2. 双路径数学复制

**位置**：`TVEngine.decode`，`Sources/AnalogCore/TVEngine.swift:344` 与 `:365`。

**现象**：同一函数内 `.accelerated` 分支与 `.reference` 分支各写了一遍 PAL/NTSC 的 YUV→RGB 矩阵字面量：

```swift
if s == .pal { pixel = SIMD3(yy+1.14025*vv,yy-0.39473*uu-0.58081*vv,yy+2.03252*uu) }
else { pixel = SIMD3(yy+0.956*uu+0.621*vv,yy-0.272*uu-0.647*vv,yy-1.106*uu+1.703*vv) }
```

全项目共 12 处 `execution == .accelerated` 分支，多数是同函数内的路径复制。

**风险**：改动某一条路径的系数而漏掉另一条，会在无任何报错的情况下产生两条数值不一致的信号链。当前靠 `TVPerformanceTests` 的等价性断言兜底——但那只能*检测*，不能*阻止*，而且该测试依赖手工运行（见第 3 项）。两项叠加时风险相乘。

**建议**：把像素公式抽成 `@inline(__always)` 的纯函数供两条路径共用。编译器仍会内联到同等性能，而矩阵常量只剩一处定义。`TVReceiverFrontEnd` 的调谐器循环（标量与 `TVTunerWork`）是同类结构，可一并考虑。

**验收**：`swift test -c release --filter TVPerformanceTests` 全部通过，且基准数值无回退。

---

## 3. 最小 CI

**位置**：仓库根目录（无 `.github/`）。

**现象**：全部验证依赖手工运行。且关键验收大量不可移植：

- 环境变量门控：`ANALINE_WINDOW_BENCHMARK`、`ANALINE_CAPTURE_RACK`
- 机型限定：`XCTSkip("This real-time acceptance check targets M3 Max")`
- 硬件/字体依赖：`XCTSkip("VCR OSD Mono is not installed on this test host")`
- 需要原生窗口：`XCTSkip("Opt-in: opens an owned native window …")`

**风险**：安全网（第 2 项的等价性断言）在没有人手动跑的时候等于不存在。以当前提交速度，这是最容易被无声破坏的一环。

**建议**：不追求完整 CI，只把 `AnalogCoreTests` 中不依赖窗口、不依赖机型的子集挂上去。建议先跑一次 `swift test --filter AnalogCoreTests` 记录实际耗时与跳过清单，再据此划定范围。

**注意**：部分测试硬编码写入 `/private/tmp`（`TVPerformanceTests.swift:99`、`TVRendererTests.swift:164,216,258`、`TVPlaybackTests.swift:175`、`TVMobileProfileTests.swift:375`）。CI 上应改为 `FileManager.default.temporaryDirectory`，否则并行运行会互相覆盖。

---

## 4. GUI 状态单向化

**位置**：`Sources/AnalogGUI/AnalogGUI.swift`（`PreviewModel` 约 795 行）与 `Sources/AnalogGUI/TVControlState.swift`。

**现象**：全部 GUI 文件共 62 个 `@Published`、19 处 `didSet`，其中 `PreviewModel` 与 `TVControlState` 通过 `didSet` 互相回写，并带防循环守卫：

```swift
@Published var tvChannel: TerrestrialSettings = … { didSet {
    if tvControlState.tvChannel != tvChannel { tvControlState.tvChannel = tvChannel }
    …
} }
```

反向在 `TVControlState` 中同样存在，另有 `bind(_:)` 做初始同步。

**风险**：两个可变副本互相同步，在加入第三个观察者时极易产生更新环或丢更新。此外 62 个 `@Published` 意味着任何一处遥测变化都可能触发大面积视图失效。

**建议**：合并为单一 source of truth（`PreviewModel` 持有，`TVControlState` 降为只读投影或纯派生视图模型），去掉双向回写。**必须在继续增加接收机面板控件之前完成**——再加十几个控件后再拆，成本高一个数量级。

---

## 5. 零散清理

### 5.1 `try!` 无说明

`Sources/AnalogCore/TVStandard.swift:53`，`TVFrame.colorBars`：

```swift
return try! TVFrame(standard: standard, rgb: (0..<standard.width*standard.height).map { … })
```

参数在此处恒有效，因此不会崩。但这是便利工厂却放在公共 API 上，且没有注释说明为何可以强解包。建议改为 `throws`，或加一行注释固定这个前提。

### 5.2 未解释的魔数

`Sources/AnalogCore/TVUnifiedChannelEngine.swift:80` 与 `:119`：

```swift
otherPower: visionPower.isEmpty ? [] : [0.1*settings.transmitter.powerGain],
…
result.transmitter.referencePower = audio != nil ? 1.1 : 1
```

`0.1` 与 `1.1` 的来源没有说明。建议补注释，或提为具名常量。

### 5.3 测试硬编码临时路径

见第 3 项，6 处 `/private/tmp` 绝对路径。

### 5.4 文档基线过期

`Docs/Unified-TV-channel.md:3` 写"工作分支：`codex/unified-tv-channel`，基线提交：`c7b1d7c`"，实际当前分支为 `iOS`，距该基线已过 6 个提交。此文其余部分（实现状态、实测数值）更新及时，只有头部这两行未跟进。

### 5.5 已弃用 API 警告

`Sources/AnalogImaging/AnalogEffects.swift:6-12`，`CIColorKernel(source:)` 在 macOS 10.14 起弃用。这是 `swift build` 目前唯一一条警告。可按提示定义 `CI_SILENCE_GL_DEPRECATION` 静音，或迁移到 `CIKernel` / Metal。低优先级，仅影响构建输出整洁度。

---

## 明确不要做的事

以下是审查第一轮提出、随后撤回的建议。列在这里避免以后重复考虑：

- **不要拆 `TerrestrialReceiver.detect`。** 该函数约 200 行，含手写 PLL/AFC 与并行扫描。但信号链仍在演进，正确的接缝还没显现，现在拆是过早抽象，拆错比重写更贵。等统一通道稳定并跑完长期验收后再评估。
- **不要现在引入 swift-format / 统一代码风格。** 现有风格（多语句行、冒号后无空格、DSP 循环内单字母变量）与 Swift API 设计准则相悖，但在高速迭代期统一风格只会制造与功能改动混在一起的大 diff。等速度降下来单独做一次。
- **不要收敛 `AnalogCore` 的 `public` 面。** 521 处 `public` 对单体 app 库零成本，没有收益。
