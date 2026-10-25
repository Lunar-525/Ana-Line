# AsyncAlter 引擎边界

> **定义**：AsyncAlter 是一个由 Runtime 统一管理仿真时间、以 Environment 提供射频世界交互、通过标准 IQ 接口连接独立 TX/RX 的实时信号仿真平台。ANALINE 是这个平台的官方 Host。

本文档冻结 AsyncAlter 的架构骨架。三条真正重要的边界是：

- **TX → Environment**：发射信号。
- **Environment → RX**：射频观测。
- **Runtime → 所有组件**：统一时间与调度。

一句话概括：**Runtime 管时间，Environment 管空间与传播，TX/RX 管设备与信号协议。**

标记约定：未标注的条目已定稿。标 **【待定】** 的是实现建议，尚未确认。标 **【现状偏差】** 的记录当前代码与本文档不一致之处，供迁移时对照。

---

## 1. 五个角色

| 对象 | 拥有什么 | 不应该拥有什么 |
| --- | --- | --- |
| **TX** | 调制器、发射机状态、信号生成、自身天线特性、自身频率偏差 | RX 列表、世界传播模型、其他设备状态 |
| **RX** | 接收前端、本振与中频变换、调谐误差、镜像抑制、解调与解码、设备噪声 | TX 列表、其他设备内部状态、世界传播模型 |
| **Environment** | RF 坐标与频率搬运、信号路由、传播、外部噪声、相干叠加 | 协议解码、音视频内容语义、全局时钟所有权 |
| **Runtime** | 仿真时间、调度、生命周期、缓冲协调、不连续点的声明 | AM / FM / PAL 等具体协议 |
| **ANALINE** | GUI、场景编辑、用户交互、媒体输出 | RF 传播计算的内部规则 |

### 唯一权威所有者

**同一个物理现象只能有一个权威所有者。** 否则不同插件会重复叠加同一种失真，结果从物理上就不正确：

| 物理现象 | 唯一所有者 |
| --- | --- |
| 发射机频率偏差 | TX，模拟一次 |
| 环境传播延迟 | Environment 的传播模型，计算一次 |
| RX 内部噪声 | RX，加入一次 |
| RF 世界坐标变换 | Environment 的观测适配层 |

---

## 2. 核心问题一：频率坐标属于谁

**Environment。** TX 只声明自己的绝对频率和基带，Environment 计算 `Δf = F_TX − F_RX` 并完成搬运。

```
TX                          Environment                     RX

生成 IQ ──► 声明 98 MHz ──► 搬移至 RX 观察窗口 ──► 接收 IQ
                                   │
                              Δf = -60 kHz
                                   │
                              传播 / 噪声
```

若由 RX 自己寻找每台 TX 并计算频率差，RX 就必须理解整个世界的发射机注册表，TX/RX 插件的独立性当场破裂。

### 但必须区分两种混频

| 操作 | 所有者 |
| --- | --- |
| TX 绝对频率 → RX 观察窗口 | Environment |
| 多 TX 的频率对齐与叠加 | Environment |
| 不同基带采样率之间的转换 | Environment / Runtime 的信号适配层 |
| RX 调谐误差 | RX |
| RX 内部本振与中频变换 | RX |
| RX 前端滤波与镜像抑制 | RX |
| 解调与解码 | RX |

这样既能任意组合不同协议的 TX/RX，又不牺牲对真实接收机结构的模拟能力。

**结论：Environment 负责把射频世界投影到接收机的观察窗口；RX 负责自己的接收硬件行为。**

### 相位连续性

频率搬运必须保留相位连续性。不得对每个 DSP block 从零开始：

```swift
phase = 0   // 错误：每个 block 重置
```

应当由统一仿真时间确定相位，或在连续处理的状态中维护 NCO 相位。否则 Environment 自己会引入本不存在的相位跳变。**【现状偏差】** 现有实现按状态维护相位但在每个 block 边界重新归一化，行为正确；迁移时必须保留这一性质。

---

## 3. 核心问题二：噪声由谁产生

分两层，各自独立。

### A. 共享的环境噪声 —— Environment

雷暴脉冲、大气背景噪声、人造电磁干扰、天体无线电辐射。这些与接收机设备无关：**即使环境中没有任何 RX，它们也作为环境的统计场或事件存在。**

关键要求是相关性。两台相距 100 m 的 RX 同时收到远处雷暴干扰时，**不应该各自生成一条互不相关的随机脉冲序列**，而应观察同一个环境噪声事件，只是各自传播路径、接收频带与设备特性不同。

因此需要区分**共享噪声过程**与**接收机局部噪声过程**。

**【待定】实现建议**：不必生成覆盖 149 MHz 的全局噪声 IQ 流。把共享噪声做成 `(seed, time, frequency, position)` 的**确定性函数**，相关性就自动成立，同时天然支持将来的一致性重放。需要存储的只有事件时间轴与频谱统计模型。

### B. 接收机自身噪声 —— RX

LNA 噪声、混频器噪声、接收机噪声系数、ADC 量化噪声、后级模拟电路噪声。

### 带宽决定积分噪声

```
N = k T B
```

`B` 是接收带宽，因此带宽直接影响进入解调器的噪声功率。一台 200 kHz 的 FM RX 与一台 2.7 kHz 的 SSB RX，即使处在相同外部噪声环境中，总噪声功率也可能完全不同。

**Environment 描述外部噪声的频谱与空间分布；RX 决定经自身接收带宽和噪声特性后，最终有多少噪声进入解调器。**

### 关于噪声的单位

**不要把 `noiseDB` 直接拆成 `externalNoiseDB` / `internalNoiseDB` 两个 `Double`** —— 那仍然没有规定 dB 的参考量：它表示 dBm、dBm/Hz、相对信号的 SNR，还是数字 IQ 的幅度比？

**【待定】实现建议**：Environment 提供某一频率附近的**噪声功率谱密度**（明确单位），RX 依据自身带宽与噪声系数计算接收噪声。需要模拟共享脉冲事件时，另外提供独立的噪声过程接口。这比两个含义模糊的浮点数更容易扩展。

### 一处修正

低于约 20 MHz 的部分频率与环境中，大气噪声**可能**非常显著，但**不能规定整个 `< 20 MHz` 都由大气噪声主导**。频率、位置、季节、时间与人为噪声环境都会改变主导来源。

---

## 4. 核心问题三：谁有权推进仿真时间

**Runtime 拥有仿真时间。** Core Audio、SwiftUI 和插件都不能各自成为整个世界的时钟源。

### Environment 不能是完全无状态的，但也不拥有时钟

世界时间推进**不意味着整个环境都要逐采样前进**。从 `t=10.000 s` 推进到 `t=10.050 s`，不代表所有 TX 都必须在这 50 ms 内生成完整波形——Environment 应根据实际请求计算必要的信号。

接口因此拆成两件事：

```swift
runtime.advance(to: time)                    // 时间与状态转换
environment.render(observation: request)     // 特定观察请求下的 RF 计算
```

需要更新的环境状态（移动发射机位置、电离层参数、雷暴事件、传播路径缓存）在逻辑时间推进时更新，**或按确定性的时间查询求值**。

**Environment 可以拥有状态，但不拥有独立的世界时钟。**

### 时间源与执行路径

```
                AsyncAlter Runtime
                    Simulation Clock
                           │
                DSP Producer / Scheduler
                           │
                请求 RF Observation
                           │
                           ▼
                    RF Environment
                           │
                    Received IQ
                           │
                           ▼
                       RX Plugin
                           │
                       Audio PCM
                           │
                      SPSC FIFO
                           │
                           ▼
                    Core Audio
```

**Core Audio 回调只消费数据，绝不在实时回调中直接触发环境仿真。**

- 请求未来仿真时间范围的是 **DSP Producer / Scheduler**。
- Core Audio 的消费进度可用于决定生产者背压与目标前瞻量，但声卡回调不得成为仿真执行器。
- 已建立的 SPSC 无锁环形缓冲与背压机制必须保持，不得在架构拆分中破坏。

**SwiftUI 同样不驱动世界时间。** 它可以查询已提交的状态快照，但不能因为用户打开一个频谱图就让所有发射机推进 50 ms。

**显示请求必须是只读观察行为。**

---

## 5. 接口契约

### 注入端

```swift
protocol RFEmitter {
    var emitterID: RFEmitterID { get }
    var carrierHz: Double { get }      // 绝对频率，由 TX 自己声明
    var occupiedHz: Double { get }     // 占用带宽
    var eirpDB: Float { get }
    var position: RFPosition { get }
    /// 为 [t, t + count/rate) 生成自己的基带。Environment 不解释它是什么。
    mutating func emit(count: Int, rate: Double, at time: SimulationTime) throws -> RFBaseband
}
```

### 观测端

```swift
protocol RFObserver {
    var observerID: RFObserverID { get }
    var position: RFPosition { get }
    var antenna: AntennaPort { get }
    /// Environment 按本请求的口径交付一段合成 RF。
    mutating func observe(_ rf: RFObservation, at time: SimulationTime) throws
}
```

### 边界产物

```swift
struct RFObservationRequest {
    let centerFrequencyHz: Double
    let sampleRateHz: Double
    let frameCount: Int
    let startTime: SimulationTime
    let antennaPort: AntennaPortID
}

struct RFObservation {
    let format: IQFormat
    let samples: IQBuffer
    /// 宽带功率信息：窄带 IQ 切片无法表达同一天线上的强信号阻塞。
    let widebandPowerDB: Float?
}
```

边界产物**没有** `system`、没有 mode、没有载波含义。RX 只需要告诉 Environment：

> 我在什么地方，用什么天线，以什么频率和带宽观察哪一段时间。

RX 不需要知道：有多少 TX、TX 用什么调制、哪个信号来自电视、哪个来自 Radio、发生过哪些多径。

### Environment

```swift
protocol RFEnvironment {
    mutating func register(emitter: RFEmitter)
    mutating func register(observer: RFObserver)
    /// 只计算落在所请求窗口内的注入者。
    mutating func render(_ request: RFObservationRequest) throws -> RFObservation
}
```

### 请求描述的是理想化的天线端口观测窗口

它**不包含** RX 内部所有设备特性：RX 自己的频率偏差、前端阻塞、镜像响应仍留在 RX 层。

若要模拟同一天线上的宽带强信号阻塞，观测接口必须额外提供宽带功率信息或允许更宽的观测窗口——**仅靠窄带 IQ 切片表达不了阻塞**。

---

## 6. 世界时间：顺序推进，非随机访问

实时主路径是**顺序推进**。时间跳转是**显式的不连续点**，而非随机访问。

**不连续点由 Runtime 声明**（因为 Runtime 拥有时间），插件收到后按自己的方式重置与重新捕获：

- 状态量清空：滤波器历史、PLL / NCO 相位、AGC 状态、重采样状态、观测历史。
- 从新时刻重新捕获，而不是重建"若连续运行本该有的状态"。
- 跳转结果因此是**合理的**，而不是**逐位相同的**。

**【现状偏差】** 这一点当前只在 TV 路径实现（`seekTV` 量化到帧边界后重置频谱 / 瀑布 / 雷电历史并重新捕获），Radio 与 SSTV 尚无对应概念。迁移时应由 Runtime 统一声明，而不是各插件自己发明。

**长期能力**：确定性重放与检查点。它把跳转的"合理"升级为"精确"，但不是实时主路径的前提。不为了尚未实现的随机时间访问，把所有 TX/RX 强制设计成无状态函数——那会与既有的有状态 DSP、SPSC 与背压机制冲突。

---

## 7. 按需执行

**一个 1–150 MHz 的频率空间，不意味着必须始终计算 149 MS/s 的完整 IQ。**

Environment 的 `render` 是**查询**，不是"推进世界并输出全体 IQ"。成本应当正比于：

```
（落在所请求窗口内的注入者数量） × （提出请求的观察者数量）
```

而不是总发射机数量。调谐在 +240 kHz、中频 96 kHz 的 RX，只可能受 ±48 kHz 内的 TX 影响，其余发射机不应被卷进它的缓冲。

**【现状偏差】** `RadioSceneEngine.process` 对每台 RX 分配全尺寸缓冲，并无条件遍历全部 TX 做链路卷积——即"始终物化整个世界"。详见第 9 节。

---

## 8. 频段世界

频率相关物理按**连续频率**求值，频段只是预设（限定观察中心范围、默认中心、外部噪声底、启用的机制、位置量程、演示场景）。不要为每个频段硬编码一套物理，否则频段边界处会出现跳变，同一段物理要维护多份。

典型传播特征：

| 频率区域 | 典型传播特征 |
| --- | --- |
| 1–3 MHz | 地波传播重要，部分频率的天波受昼夜影响明显 |
| 3–10 MHz | 电离层传播十分重要 |
| 10–30 MHz | 电离层传播仍重要，可用性强烈依赖时间与电离层状态 |
| 30–50 MHz | VHF 低端，视距与地形为主，可能出现异常传播 |
| 50–88 MHz | VHF，视距为主，特定条件下远距离传播 |
| 88–108 MHz | FM 广播频段，视距覆盖、多径、接收机捕获效应 |
| 108–137 MHz | 航空导航与通信，空地视距，飞行高度影响覆盖 |
| 137–150 MHz | VHF 通信及其他业务，地形遮挡、移动衰落、中继覆盖 |

一次只进入**一个**频段世界。频段内观察窗口仍由当前可处理的带宽决定，因此不需要一次跨越巨大窗口。

---

## 9. 现状偏差（迁移对照）

| 现状 | 位置 | 违反 |
| --- | --- | --- |
| `TVChannelIQ` 携带 `system` / `visionCarrierHz` / `soundCarrierHz` | `TVChannelSignal.swift` | 载荷语义进入边界产物 |
| TV 前端拒绝 `system` 不匹配的记录 | `TVReceiverFrontEnd.swift:251` | TV RX 无法接收外来 RF |
| `TerrestrialRFChannel` 归 `TVTransmitChain` 所有 | `TVTransmitChain.swift` | 传播属于 Environment，不属于 TX |
| `ScenePath.add(..., to: inout, _: inout)` 直接累加进 RX 缓冲 | `RadioScene.swift:232` | 传播同时承担"算信道"与"写接收机输入" |
| `SceneModulator` / `SceneDemodulator`（五种协议）在引擎文件内 | `RadioScene.swift:123,146` | 调制解调协议属于插件 |
| `RadioSceneSettings.transmitters[].parameters`（AM/FM/SSB/CW/PM） | `RadioScene.swift:69` | 协议设置属于插件 |
| 引擎校验 CW 键电平 `(0...1)` | `RadioScene.swift:354` | Environment 理解了调制协议 |
| `RadioSceneFrame.transmitSpectra` 由引擎返回 | `RadioScene.swift:334` | 插件遥测应由插件自己向 Environment 索取 |
| 引擎为每台 RX 分配全尺寸缓冲并无条件遍历全部 TX | `RadioSceneEngine.process` | 违反按需执行 |
| `clock.seconds = playbackStart + audio.mediaSeconds` | `RadioScenePlayback.swift:608` | Core Audio 成为世界时钟 |
| 单个平坦的 `noiseDB` | `RadioScene.swift:77` | 未区分外部 / 内部噪声，且无物理单位 |

---

## 10. 迁移顺序

按"能否独立验证"排序，每步都可单独交付：

1. **引入 `RFObservationRequest` / `RFObservation`，并写一个证明规则 6 的测试**：用 TX 插件生成一段 RF 存成边界产物，不经过该 TX 的任何代码，直接喂给 RX 插件。今天做不到，这是整套架构的验收标准。
2. **把 `SceneModulator` / `SceneDemodulator` 及其设置移出引擎**，让 `AnalogCore` 不再 switch 调制模式。
3. **`render` 改为查询式**（按需执行）：只计算落在窗口内的注入者。
4. **Runtime 接管仿真时间**，Core Audio 退化为消费者（保持 SPSC 与背压不变）。
5. **拆 `TVChannelIQ`**：Environment 侧只保留 `RFObservation`，TV 的载荷元数据留在 TV 插件内部。

第 1 步不动任何 DSP，也不破坏存档格式，却把"边界在哪"从注释变成类型系统里的既成事实。
