# Tape / CHF60 初版

macOS 的第五个模式为 Tape：通过右上角「选择音频」导入系统可解码的音频文件，
按面板 REC（或右上角选择音频）打开文件，PLAY 实时处理。支持暂停继续、20× 快退/快进、拖动定位、独立 L/R 录音电平、输出增益、底噪和原声旁路。
保留立体声；单声道转换为双声道。没有麦克风/声卡直通、导出或会话保存。

## 来源和标定边界

- CHF 样本测量：[Audiochrome，2020-07-26](https://audiochrome.blogspot.com/2020/07/cassette-tape-measurements-sony-hf-hf-s.html)。
- [测量方法](https://audiochrome.blogspot.com/2019/12/cassette-tape-comparative-measurements.html)：Nakamichi BX-300E + audioTester；参考 Maxell UR 1994，Dolby level 为 200 nWb/m ANSI。
- 原文样本标为 Sony CHF (1978)，作者认为可能是较后期生产；没有明确它的时长。
  因而 UI 中 CHF60 是本项目的目标型号，不代表已经测量验证了 CHF60 实物。

公开目标：相对灵敏度 -0.8 dB；参考电平 THD 1.5%；MOL400(1%) -1.3 dB；
MOL400(3%) +2.1 dB；MOL1k(3%) +1.8 dB；SOL10k -1.4 dB；
未加权偏磁噪声 -47.6 dB、A 加权 -50.7 dB(A)；动态范围 52.8 dB。
偏磁 -2 是 BX-300E 面板刻度，没有映射为材料系数。

本版只把低电平 400 Hz 灵敏度、名义参考输入的 400 Hz THD 与未加权噪声 RMS
作为已校准的约束；没有宣称同时拟合所有 MOL/SOL、A 加权噪声或频响曲线。
数字约定：峰值 -18 dBFS 的正弦输入定义为名义 0 dB 录音参考，
没有建立数字电压到真实磁通的绝对校准。原文 THD 测试与我们名义输入参考的
差异也限制了两者的直接可比性。把 dBFS 当作磁通单位是不成立的。

## DSP

`CTapeDSP` 通过 C ABI 提供双声道、跨块保存状态的处理器；`AnalogCore/Tape.swift`
管理生命周期；`AnalogGUI/TapePlayback.swift` 负责流式解码、重采样和播放。

链路：48 kHz 立体声 PCM → 录音增益 → 有效前加重 → 4× FIR 插值 →
CHOW 衍生 Jiles–Atherton / RK4 → FIR 抗混叠抽取 → 后去加重 →
有效高频损耗、20 Hz DC 阻隔 → 独立双声道噪声 → 输出增益。

有效系数为 Ms=1、a=0.28、k=0.47875、c=0.97、alpha=0.0016，
它们是音频域近似拟合，不是 CHF 磁性材料的 SI 测量值。
两级过采样 FIR 各 63 taps，约 15 个基带样本延迟；
有效前后加重为一对相反的高架滤波器，损耗为 18 kHz 一阶低通。
这些滤波器并非从缺失的 CHF 磁头/涂层测量推导。底噪用 63 taps / 20 kHz FIR 带限的伪随机噪声近似，并按滤波器能量归一化，
不包含真实磁带颗粒噪声谱、信号调制噪声、掉磁或覆印。
没有添加未经 CHF 实测支持的默认 wow/flutter 或咬带效果。

公开 C API 接受 32–192 kHz；本模式固定在 48 kHz，当前参考标定也仅针对 48 kHz。
旋钮用约 10 ms 平滑，旁路交叉淡化；旁路不经过增益和底噪。
输出保持浮点，不用隐藏限幅器改变标定曲线；超过 0 dBFS 时界面提示降低输出电平。

## 播放和验证

AVAudioFile + AVAudioConverter 在专用串行队列按块解码到 48 kHz，
内存不随文件时长增长。生产者将 PCM 放入预分配 SPSC 环形队列；
AVAudioSourceNode 回调仅做有界复制，不解码、不运行 DSP、不加锁、不分配。
水位约 4096 samples；旋钮听感更新会有约 85 ms 预缓冲加设备延迟。
暂停保留解码器与磁滞状态，回到开头重建它们，离开 Tape 模式暂停。

运行：`swift test -c release --filter 'TapeTests|TapePlaybackTests|WorkspaceHeaderGeometryTests'`。
包括参考失真/噪声/灵敏度、饱和趋势、跨块一致性、立体声隔离、非有限输入、
旁路/复位、多采样率流式解码和尾部排空，以及五模式公共标题布局。
播放吞吐量报告不构成任意设备上的硬实时保证。

许可和上游准确版本见 `ThirdParty/CHOWTape/NOTICE.md`，上游许可证随应用打包。

## 本机验证结果（2026-10-15）

Release 的 17 项相关测试通过，包含实际音频设备的播放、暂停继续、自然结束、回到开头及离开模式停止播放。
400 Hz 名义参考输入 THD 1.5389%，低电平灵敏度 -0.7991 dB，未加权噪声 -47.6160 dB。
本机处理 1 秒双声道 PCM 用时约 0.093 秒（约 10.8 倍实时吞吐量），不代表所有 Mac 的实时保证。

## FF8 面板与走带控制

界面参考用户提供的 AIWA FF8 正面照片，以 SwiftUI / Canvas 原生绘制银色机身、
烟色显示区、磁带窗、按键、双声道 LED 峰值表和七段时间显示。只参考外观，
音频仍为 CHOW 衍生的 CHF60 近似模型，没有宣称复现 AIWA FF8 电路。

- REW / FFWD：按下后持续以 20× 移动位置，触边自动停止；不播放快进/快退噪声。
- PLAY：从当前位置播放；文件结束后再次 PLAY 从头开始。
- REC：打开音频文件，不执行录音或覆写文件；取消选择保留原播放。
- STOP：停止并保留位置，再次 PLAY 续播；前往开头可用 REW 或进度条。
- PAUSE：暂停/继续；停止状态可先进入暂停。
- MUTE：仅静音监听，不影响走带、DSP 或电平表。
- TIME COUNTER：显示相对 RESET 位置的分:秒，RESET 只清零读数，不改变音频位置；
  回到 RESET 位置之前可显示负数。
- 右下角 L/R 滑杆：输入到磁带非线性之前的真实录音增益，范围 -24～+18 dB。
  位置 5 为 0 dB；该刻度不是实测的 FF8 电位器曲线。默认 LINK，解除后可独立调节。
- 双声道电平表：实际处理输出，名义磁带 0 dB 对应 -18 dBFS 峰值；
  10 ms 上升、550 ms 回落、900 ms 峰值保持，随后 14 dB/s 下降。
  这些是显示仿真参数，不是 FF8 仪表响应的实测值。

Tape logo 使用 `Design/Logo/ana-line-tape.svg` 的原始矢量轮廓，颜色读取设计的
`#82A8F5`（RGB 130/168/245），没有修改设计源文件。

### Head and tape health

The Tape panel provides independent Head health and Tape health sliders (0–100%,
both defaulting to 100%). These are effective wear controls, not calibrated
measurements of a physical deck. At 100% the existing reference response is
preserved. Head wear lowers the replay low-pass cutoff (18 kHz to 3.24 kHz) and
level (up to 4 dB). Tape wear further lowers the cutoff (by up to a factor of
0.35), reduces level by up to 2 dB, increases enabled hiss by up to 12 dB and adds
slow, channel-dependent level fluctuations. The hiss switch still controls all
hiss; SOURCE bypasses the wear effects along with the tape model. Health changes
are smoothed over 10 ms and survive transport resets.
