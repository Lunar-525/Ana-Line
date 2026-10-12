# 14 Pro 热态剖析（Time Profiler）

2026-10-12 06:48–06:51。设备：iPhone 14 Pro（iPhone15,2，iOS 27.0）。构建：Release、mobile 档位、unlimited workers、userInitiated QoS，`--benchmark-sustained`。

方法：`xcrun xctrace record --template 'Time Profiler' --time-limit 180s --window 90s --launch -- com.analine.benchmark --benchmark-sustained`。

**覆盖范围**：持续模式每个场景 180 秒，而录制总长也是 180 秒，所以这份剖析只覆盖**第一个场景 PAL 默认**——也就是说下面这些热点里**不含**功放、回声、降雨这些只有损伤场景才打开的整帧工作。损伤场景的分阶段归因见 `thermal-realtime-round2.md` 第 3 节与本文末的对照；要一份损伤场景的剖析需要把录制时长拉到覆盖第二个场景（≥360 s）或单独跑损伤场景。trace 自带的 `device-thermal-state-intervals` 表显示 0–48.6 s 为 nominal、48.6–78.6 s 为 fair、**78.6 s 之后为 serious**，所以取 90–180 s 这一段做聚合，全部落在 serious。聚合脚本：`iOS/profile_symbols.py`（两趟解析，Instruments 的 XML 把进程/线程/核/回溯都做成 id 引用且分批定义，单趟流式解析只能解出一小部分）。

## 1. 最关键的结论：不是算力不够，是并行度和串行路径

- 90 秒窗口内 App 累计 **198.5 s CPU**，平均 **2.21 个核**在跑。
- 设备有 6 个核，也就是说**只用了约 37% 的 CPU 容量，却仍然超预算**。

核分配看起来是合理的，不需要干预：

| 核 | 占比 |
| --- | ---: |
| CPU 4（S＝性能簇） | 33.7% |
| CPU 5（S＝性能簇） | 31.1% |
| CPU 0–3（E）合计 | 35.3% |

6 个核都用上了，65% 的时间落在两个性能核上——这与 QoS 扫描"userInteractive 无收益"一致（调度本来就对）。所以问题不在"跑到小核上了"，而在**每个阶段的并行区太短、阶段之间又是串行的**：一帧里十几个阶段各自 `concurrentPerform` 起停一次，跨阶段的串行部分吃掉了大部分时间。用 Amdahl 表述：实测并行度 2.21×，意味着串行占比约 55%。

## 2. 热点（self time，占 App CPU）

| 排名 | 占比 | 符号 | 说明 |
| ---: | ---: | --- | --- |
| 1 | 8.09% | `TVResamplerWork.runSingle` | 伴音重采样（mobile 档的单精度累加路径） |
| 2 | 5.04% | `TVEngine.components` | CVBS 编码 RGB→YUV 逐像素 |
| 3 | 3.64% | `TVEngine.encode` 闭包 | CVBS 编码内层 |
| 4 | 2.35% | `TVEngine.decode` 闭包（梳状/分离） | 视频解码内层 |
| 5 | 2.35% | `TVEngine.decode` 闭包（另一处） | 视频解码内层 |
| 6 | 1.92% | `TVSoundChannelNCO.run` | 合并器载波搬移 |
| 7 | 1.48% | `TVComplexShiftWork.run` | 提取器下变频 |
| 8 | 1.41% | libsystem（memcpy 类） | 数组搬移 |
| 9 | 0.77% | `TVNoiseBlock.run` | 信道噪声 |
| 10 | 0.74% | `BenchmarkRunner.run` | 基准自身的预览/内存采样 |
| 11 | 0.62% | `TVCarrierDetect.run` | 载波相干检波 |
| — | 1.41% | `TelevisionFIR.process`（inclusive） | **全部 97 抽头卷积合计** |

前 10 个符号只占 27.8%，前 25 个占 31.8%——**profile 是平的**，没有单个大核可以一刀切掉，剩下的是大量小函数与系统帧。

## 3. 这次剖析撤回了我上一轮路线里的三项

| 上一轮的判断 | 实测 | 处理 |
| --- | --- | --- |
| 重设计 VSB/IF 的 97 抽头核（预计 −1.4 ms） | `TelevisionFIR.process` inclusive 只有 **1.41%**，全部卷积加起来约 0.9 ms/帧 | **撤回**，收益只有估计的十分之一 |
| 向量化 `isFinite` 全帧校验（预计 −1.5…−3 ms） | 整个 profile 里 `validate` 只占 0.2%（窗口前统计），窗口内根本进不了榜 | **撤回**，编译器已经处理得足够好 |
| 去掉 FIR 的 `history + input` 复制与零初始化（预计 −1…−2 ms） | 对应的 `Array`/`copyCollection`/`memcpy` 合计不到 0.5% | **撤回** |

这三项都是我从算式推出来的，实测证明推错了。这也说明为什么这一轮剖析是必要的。

## 4. 修正后的目标（按实测热点排序）

| 顺序 | 手段 | 依据 | 预计 |
| --- | --- | --- | ---: |
| 1 | 伴音重采样累加链打散：多个独立部分和 / SIMD4 / vDSP | 单项最大热点 8.09%；13 抽头是一串依赖浮点加法，而每个输入样本对应约 46 个输出相位，几乎没有 ILP | −4…−6 ms |
| 2 | CVBS 编码与解码内层改 SIMD4/vDSP | 5.04 + 3.64 + 2.35 + 2.35 = **13.4%** | −3…−5 ms |
| 3 | 把各阶段零散的 `concurrentPerform` 合并成少数几个大并行区 | 并行度只有 2.21×/6 核，串行占比约 55% | −3…−5 ms（主要是墙钟时间） |
| 4 | 重采样/合并器/提取器三处共用一趟搬运 | NCO 1.92% + complex shift 1.48% + memcpy 1.41% | −1…−2 ms |

四项都是零精度损失。合计约 **11–18 ms**，足以把 14 Pro 的严重热态损伤场景（约 49.5 ms）拉进 40 ms 预算——而且第 1、3 项直接作用在关键路径上，不只是省 CPU 时间。

## 5. 能耗：能测到的与测不到的

- **测到了**：热状态轨迹（`device-thermal-state-intervals`，本次 60 s 复录整段都在 Serious）与 CPU 时间，而且用两条独立途径互相印证：
  - Time Profiler 采样：90 s 窗口内 198.5 s CPU → **2.21 个核**平均。
  - Activity Monitor 进程账本（`activity-monitor-process-ledger` 的 `cpu-total`）：45 s 录制内 102.0 s CPU → **2.22 个核**平均。
  折算下来 14 Pro 在 Serious 下每帧约消耗 60–70 ms CPU，而墙钟只有约 30–50 ms/帧。
- **没测到**：焦耳。`Power Profiler` 模板在本机导出时报 `Document Missing Template Error`；可导出的能量 schema（`cl-energy-level`）是 CoreLocation 的定位功耗模型，与 App 的 CPU/GPU 功耗无关；`Activity Monitor` 的进程账本有 `cpu-total`、`idle-wakeups`、磁盘字节，但没有能量列。CPU 秒数是本机拿得到的最接近的能耗代理量。
- **但这不影响结论**：设备有 6 个核，App 只用了 2.21 个就已经超预算。**当前瓶颈不是能耗或吞吐，而是串行关键路径**——继续降低每次运算的能耗并不会让这一帧变快，缩短串行段才会。

## 6. 损伤场景为什么更差（同一次运行内对比，热状态一致）

| 阶段 | 16 Pro PAL | 16 Pro NTSC | 14 Pro PAL | 14 Pro NTSC | 是否由损伤设置打开 |
| --- | ---: | ---: | ---: | ---: | --- |
| 调制（含合并） | **+3.10** | **+2.03** | **+5.52** | **+4.22** | 是：功放 + 交叉压缩估计 |
| RF 信道 | **+2.05** | **+1.36** | **+2.80** | **+2.18** | 是：回声插值 + 降雨噪声 |
| 调谐/IF | +1.00 | +0.71 | +1.78 | +1.34 | 是：20 kHz 调谐偏移使旋转递推生效 |
| 载波 PLL | +0.86 | +0.19 | +0.80 | +0.78 | 否（数据相关） |
| 同步 | +0.52 | +0.15 | +0.59 | +0.68 | 部分是（AGC/同步损伤） |
| CVBS 编码 | +0.35 | +0.33 | +0.80 | +0.73 | 是：微分增益损伤 |
| 载波估计 | +0.28 | +0.06 | +0.19 | +0.25 | 否（数据相关） |
| 视频解码 | +0.19 | +0.10 | +0.54 | +0.59 | 否（数据相关） |
| 合计增量 | +8.63 | +5.08 | +13.38 | +11.29 | |

两个阶段就占了增量的约 60%。它们不是"损坏模型本身更重"，而是损伤设置**打开了默认场景根本不执行的整帧循环**：发射机（两路功放的 2× 内插 + 查表 + 抽取，以及共耦合的逐格功率估计）、回声的分数延迟插值、降雨噪声、调谐旋转。剩下约 40% 是数据相关的税：失锁边缘的 PLL/估计、切片与解码的分支、微分增益路径。

**一个尚未证实的怀疑**：mobile 档位的自适应抽取（PLL 步长 2、AFC 8×）只在 `carrierTracked` 为真时生效，而损伤信号（20 kHz 偏移 + 回声 + 降雨）更靠近捕获阈值，可能**恰好在最忙的时候把优化关掉了**。载波 PLL 与载波估计在两台设备上都是正增量，方向一致，但报告目前不记录每帧实际使用的抽取率，所以这只是怀疑。加一个每帧诊断字段就能证实或排除。

## 7. 方法可复用

```sh
xcrun xctrace record --template 'Time Profiler' --device <UDID> \
  --time-limit 180s --window 90s --output run.trace --launch -- com.analine.benchmark --benchmark-sustained
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-thermal-state-intervals"]'
python3 iOS/profile_symbols.py tp.xml 90
```

CPU 秒数的独立交叉验证（比 Time Profiler 便宜得多，适合每次改动后复跑）：

```sh
xcrun xctrace record --template 'Activity Monitor' --device <UDID> \
  --time-limit 45s --output am.trace --launch -- com.analine.benchmark --benchmark-sustained
xcrun xctrace export --input am.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-ledger"]'
```

注意三点：剖析期间设备必须解锁（屏幕锁上时 App 的视图不出现，基准不会启动）；`--window` 只影响 Instruments 的分析窗口，导出的表仍是整段录制，所以要按 sample-time 过滤；回溯里的 `S Core` 在这份 A16 trace 上指性能簇，`E Core` 指能效簇。
