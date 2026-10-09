# SSTV 工具调研

调研日期：2026-10-09。AnaLine 现有 LUT、颗粒、漏光工具命名为 **Film Damage**；
**SSTV** 已作为独立工具实现 Robot36、Martin M1、Scottie S1、PD120 的基带信号链、逐段 TX/RX 与控制面板。下文保留选型依据；实际实现与限制见 README 的 SSTV 章节。

## 候选实现

| 项目 | 语言 / 许可 | 已公开的功能 | 对 AnaLine 的用途 |
| --- | --- | --- | --- |
| [dnet/pySSTV](https://github.com/dnet/pySSTV) | Python / MIT | 图片编码为 SSTV 音频；Martin、Scottie、Robot 等模式 | 清晰的编码参考和独立测试音频生成器；不自带解码 |
| [xdsopl/robot36](https://github.com/xdsopl/robot36) | Java / v2 分支 0BSD | Android SSTV 解码，支持音频文件和实时输入 | 研究同步、FM 解调、图像重建；不能直接当 Swift 库链接 |
| [unexcellent/sstv](https://github.com/unexcellent/sstv) | Rust / MIT | 编码和解码，流式扫描线事件，多模式；README 描述跨实现和真实录音测试 | 一体化核心候选；需要验证测试并评估 Swift/C ABI 桥接，不是假定已有 Swift API |
| [rimio/libsstv](https://github.com/rimio/libsstv) | C / MIT | 多模式编码；README 明确当前尚未实现解码 | C 接口适合接入 Swift，但单独使用不能完成信号往返 |
| [colaclanth/sstv](https://github.com/colaclanth/sstv) | Python / GPL-3.0 | 从音频文件解码 Martin、Scottie、Robot | 独立解码对照，适合开发验证 |
| [oftx/python-sstv](https://github.com/oftx/python-sstv) | Python / 本轮未核实许可 | Robot36 编解码，sstv_filter 工具，压缩与信号模拟；作者标明使用 Gemini 生成代码 | 参考效果参数与实验流程；不作为未经验证的生产依赖 |

许可与接口以最终选定的提交及对应文件为准。正式 App 没有添加第三方运行依赖。开发验证运行了临时目录中的 PySSTV，生成独立测试频率序列；未将其代码打包入 App。
上表的支持范围与测试覆盖来自项目说明，不表示 AnaLine 已独立验证。

## 建议实现路线

### 第二轮 GitHub 补充调研

以下依据 2026-10-09 阅读的仓库说明和文件列表整理，尚未在本机编译或做互操作测试。

| 项目 | 能力与许可 | 对 AnaLine 的价值与限制 |
| --- | --- | --- |
| [windytan/slowrx](https://github.com/windytan/slowrx) | C99 / ISC；多模式 RX、频移检测、自动斜率校正、自适应降噪、FSK ID | 优先研究 `modespec.c`、`vis.c`、`sync.c`、`video.c`；原仓库标明停止维护，Linux ALSA/GTK/FFTW 依赖不能直接照搬进 App |
| [ON4QZ/QSSTV](https://github.com/ON4QZ/QSSTV) | C++/Qt / 仓库显示 GPL-3.0；模拟 SSTV 与数字 HAMDRM 收发 | 完整收发对照候选，README 提供 macOS 构建步骤；HAMDRM 是另一条数字链路，不应混入现有模拟 SSTV 管线 |
| [n5ac/mmsstv](https://github.com/n5ac/mmsstv) | Windows C++ 源码；仓库声明 LGPL，带 COPYING.LESSER.txt | 研究实际接收器的 VIS/同步启动、时钟校准、接收缓存、带通与 LMS 滤波；这是源码存档，不是假定可直接移植的跨平台库 |
| [F4JTV/sstv_decoder](https://github.com/F4JTV/sstv_decoder) | SDR++ RX 模块；14 模式：Martin M1/M2、Scottie S1/S2/DX、Robot36/72、PD 七模式 | VIS 自动识别、同步点线性回归与可选 RANSAC、校准锁定、逐步预览；本轮未确认项目整体许可 |
| [ktauchathuranga/sstv](https://github.com/ktauchathuranga/sstv) | Rust / MIT；12 模式 TX，库与 CLI、WAV 导出和播放 | 适合生成 Martin、Scottie、Robot、PD、BW 的独立测试音频；不包含 RX |
| [SEKY443/sstv-encoder](https://github.com/SEKY443/sstv-encoder) | Kotlin / MIT；声明 35 模式、8 家族，输出 PCM/WAV | 模式时序与扫描顺序参考。AVT、SC-1、SC2-60、历史单色模式被标为实验性：部分 VIS 是猜测，AVT 数字同步头未实现，不能按 35 个互操作模式计算 |
| [bashkirtsevich/sstv](https://github.com/bashkirtsevich/sstv) | Python / GPL-3.0；提供 encode/decode，列出宽带与窄带模式 | 扩展 MMSSTV MR/MP/ML 与 MP-N/MC-N 的参考；README 的编码列表很广，不能据此推定解码覆盖与质量同等完整 |
| [milesburton/sstv-toolkit](https://github.com/milesburton/sstv-toolkit) | 浏览器编解码 / README 声明 MIT；Robot36、Martin M1、Scottie S1、PD120 | WAV 往返、VIS 与时序回退、频偏自动校准的交互参考；需独立核对时序与实际兼容性 |

建议下一批模式按 **Martin M1 → Scottie S1 → PD120 → Robot72 → BW8/12** 扩展：先覆盖 RGB 分量扫描、行内同步、双行共享色度三种不同结构，再加入易复用与单色模式。模式定义应包含 VIS、尺寸、颜色模型、分量顺序、同步位置和精确段时长，不能只把 Robot36 的尺寸和时长换掉。

对当前允许“玩”信号的目标，接收器补偿应可单独开关：频偏校准、斜率校正、同步重捕获、降噪分别控制，避免自动补偿悄悄抵消用户制造的损伤。新模式先用独立 TX/RX 对照验证，再用于效果预览。

先用 **Robot36（320×240）** 验证真实往返：

图片 ICC → 显示 RGB → 保持比例缩放/补边至模式尺寸 → 颜色分量与扫描时序 → FM 音频 → 信道损伤 → FM 解调/同步 → 重建图片。

编码规范的独立来源为 [JL Barber, Proposal for SSTV Mode Specifications（Dayton Paper）](http://www.barberdsp.com/downloads/Dayton%20Paper.pdf)。
PySSTV 的 [sstv.py](https://github.com/dnet/pySSTV/blob/master/pysstv/sstv.py) 显示基本频率约定：
同步 1200 Hz，黑 1500 Hz，白 2300 Hz；VIS 头部和各模式的行时序需要分别正确实现。
Robot36 的分量/色度子采样与 RGB 顺序扫描模式不同，不应只替换输出分辨率。

可验证之后再选择 Rust 核心桥接或原生 Swift 实现。Python 优先作为开发对照，不要求最终 macOS App 携带 Python 环境。

已实现的首批参数：

- SNR / Noise：在音频信号中加噪声。
- Frequency Offset / Drift：频偏及随时间变化的漂移。
- Clock Error：收发时钟偏差，产生倾斜；须允许关闭自动斜率校正，否则会抵消效果。
- Dropout / Fading：短时失落、衰落；与噪声共同影响接收信噪比。
- Interference：叠加窄带干扰信号。
- Seed：固定损伤随机种子；Mix：与输入图混合。

信号链必须区分损伤和接收机补偿：自动频偏校准、同步追踪、自动增益可能抵消部分效果。
预览不需要按 36 秒的实际播放速度运行，但全音频往返也不预先承诺所有参数即时更新。

## 验证要求

1. 无损伤色条、灰阶与已知图片往返，检查正确模式尺寸、颜色矩阵/范围、行顺序与累计时序。
2. AnaLine 编码结果交给独立解码器；独立编码结果交给 AnaLine，避免内部自洽但不符合协议。
3. 固定种子复现信号损伤；验证单独参数产生可解释的差异，并处理失去同步时的结果。
4. 单独测量离线解码与交互预览性能，再决定缓存和预览精度。Robot36 的当前 Release 实测在本机约 TX 3 ms、RX 7–8 ms；并非通用性能保证。

Film Damage 与 SSTV 应各自保存参数与预览状态；共享选图和拖动对比组件。
当前已加入 1× TX 声音监听与麦克风混入，并提供逐段 RX；任意音频文件导入、导出仍未实现。
