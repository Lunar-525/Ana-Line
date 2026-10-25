# Radio · 调制 / 解调核心

Radio 页面现在只有共享无线电环境，操作与界面见 [共享无线电场景](Radio-Scene.md)。本文件记录 `AnalogCore` 中五种调制 / 解调模式和它们的公开入口；这些类型既被场景引擎逐台 TX / RX 复用，也可以单独调用。

## 五种模式

- AM：带载波双边带调幅、包络检波和 20 Hz DC 阻断。默认调制度 0.8、音频带宽 5 kHz、IQ 96 kHz。包络以 `(hypot(I,Q) − 1) / modulationIndex` 标定，发射端先限幅到 ±1 再加载波。
- FM：连续相位调制、相位差鉴频。默认峰值频偏 75 kHz、音频带宽 15 kHz、IQ 384 kHz、预加重 / 去加重 50 µs。鉴频后按 `iqRate / (2π · deviationHz)` 还原音频。
- SSB（USB / LSB）：用因果 Hilbert 变换与匹配延迟形成解析音频，接收端用复数单边带滤波加乘积检波。默认 200–3000 Hz 音频通带、96 kHz IQ。在 1 kHz 测试音上验证另一边带抑制至少 40 dB。
- CW：键控输入是 [0,1] 键电平（不是音频）；平滑后形成 OOK 载波，接收端 IF 滤波后由 BFO 差拍成可听音调。默认 700 Hz 音调、800 Hz 接收带宽、5 ms 平滑时间常数、96 kHz IQ。`CWMorse.encode` 支持英文字母、数字和 `. , ? / = + - @`，最多 140 字符、5–60 WPM；点 1 单位、划 3 单位，符号间隔 1、字母间隔 3、单词间隔 7，每单位 1.2/WPM 秒，结束追加 3 单位空白。
- PM：直接令相位等于音频乘以峰值相偏，不执行 FM 的音频积分。接收端对相邻 IQ 相位差连续展开，再用两级 20 Hz DC 阻断抑制相位偏置与频率漂移。默认峰值相偏 1 rad、10 kHz 音频带宽、192 kHz IQ。不含载波 PLL / AFC，大失谐或低信噪比仍会损坏接收。

各模式都包含带限重采样、连续 IF / 音频滤波、调谐和可重复的均匀 IQ 噪声。IQ 是载波附近的复数基带，不直接采样实际 RF 载波。

## 公开入口

`AnalogCore` 提供每一模式的 `Transmitter`、`Receiver` 和组合 `Engine`：`AMTransmitter` / `AMReceiver` / `AMEngine`，FM、SSB、CW、PM 同理。`RadioEngine(mode:...)` 把五种模式收在一个枚举里，方便按当前设置切换。

发射机接受任意连续 PCM（CW 为键电平）块，接收机接受任意长度连续 IQ 块并校验采样率、样本有限性和绝对样本位置。空块不推进时钟，非法输入不会修改状态。改变设置时应创建新实例；场景引擎会在模式或参数变化时重建实例并保留载波相位。

底层复用 `TelevisionFIR`、`TVSoundFilterDesign`、`TVComplexResampler` 和 `TVSpectrumAnalyzer`，不依赖电视帧时钟。输出保留因果滤波延迟；默认 FM 约 72 个音频样本（1.5 ms）、AM 约 96 个样本（2 ms）、SSB 约 544 个样本（11.33 ms）、PM 约 80 个样本（1.67 ms），另含 AM / PM DC 阻断的频率相关相位响应。输出长度与输入一致，结束时不额外冲刷滤波尾部。

不连接 SDR 硬件或麦克风，不含 FM 立体声 MPX、RDS、AFC、AGC 或静噪。

## 界面一致性

Radio 的选择器沿用地面电视的连续滑动选中底板（0.38 秒曲线），面板复用 `RadioPanelSurface`、`TVRotaryParameter`、`TVNativeKnob` 和 `TVSegmentValue`。旋钮支持拖动、滚轮、Shift 精细调整和双击恢复默认值；点击七段读数可输入数值。界面遵循系统“减少动态效果”，模式与悬停动画由交互触发，没有常驻动画时钟。

## 验证

`swift test -c release --filter 'AMTests|FMTests|RadioAdvancedTests|RadioSceneTests'`，覆盖调幅包络、音调恢复、限幅、静音、不规则 PCM / IQ 分块、噪声与调谐、输入校验、USB/LSB 频谱方向与另一边带抑制、PM 恒包络及相位展开、CW 平滑键控与 BFO、Morse 时序，以及五种模式的实时 DSP 吞吐。Release 性能测试要求每块平均计算时间小于 42.67 ms，不能代替所有设备上的持续播放验收。
