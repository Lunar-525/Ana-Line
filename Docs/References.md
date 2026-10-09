# 参考项目与资料

整理日期：2026-10-09。这里区分资源来源、开发验证和调研参考。参考某个项目不代表 AnaLine 链接、复制或随 App 分发其代码；Swift 包的实际依赖以 `Package.swift` 为准。许可未核实的项目只列为调研资料，不能据此取得复制或分发授权。历史调研中的许可标签不代替上游具体版本的许可证。

## LUT 资源来源

| 项目 | 用途 | 许可与状态 |
| --- | --- | --- |
| [Film-Luts](https://github.com/YahiaAngelo/Film-Luts) | 6 个 CUBE 预设及随附样本 | 仓库声明 MIT，但作者不主张拥有全部 LUT；单项权利链未核实 |
| [hald-clut](https://github.com/cedeber/hald-clut) | 350 个 Hald 预设，部分样本随项目分发 | 仓库声明 GPL-3.0；汇集多个来源，单项来源需继续核实 |
| [PoLUT](https://github.com/TomPoczos/PoLUT) | 196 个 Adobe RGB 胶片 LUT，部分样本随项目分发 | GPL-3.0，保留上游全文 |
| [film-lab](https://github.com/thedevmark/film-lab) | Gold 200 Hald LUT | 项目代码 MIT；所用 LUT 为 CC BY-SA 4.0，不按代码许可授权 |
| [spektrafilm](https://github.com/andreavolpato/spektrafilm) | film-lab LUT 的原始胶片数据来源 | 所用数据及直接派生 LUT 为 CC BY-SA 4.0，并附上游前言；AnaLine 未打包其程序代码 |

预设数量对应本项目的目录快照，不代表上游当前数量。具体下载地址和 Git blob 校验值记录于 [catalog.json](../Assets/LUTLibrary/catalog.json)。本地资源许可及署名见[第三方许可说明](../THIRD_PARTY_NOTICES.md)。

## 颗粒与胶片研究

| 来源 | 方法 | 选择 |
| --- | --- | --- |
| [Newson / Faraj / Delon / Galerne, Realistic Film Grain Rendering, IPOL 2017](https://www.ipol.im/pub/art/2017/192/) | 泊松点过程、随机半径的 Boolean 圆盘并集，经过光学滤波重建像素 | 采用随机几何与覆盖率标定原理，以原生 Metal 重写；不是原算法的完整 Monte Carlo 实现 |
| [作者 GPU 实现](https://github.com/alasdairnewson/film_grain_rendering_gpu) | CUDA Monte Carlo，半径/分布/滤波可调，GPL v3+ | 开发参考，未复制或打包其代码；CUDA 不是本项目的 macOS GPU 路线 |
| [Retraced](https://github.com/tr-nc/retraced) | 泊松成核、对数正态尺寸分布、Taichi，README 声明 MIT | 参考几何乳剂与扫描分离的结构；不增加 Python/Taichi 运行依赖 |
| [agx-emulsion](https://github.com/jkarow/agx-emulsion) | 更完整的光谱摄影流程，含乳剂密度、颗粒及显影扩散控制 | 长期胶片模拟候选；当前只有显示 RGB 与 LUT，不能据此声称已模拟完整胶片化学 |

这些项目用于方法研究，不作为运行时依赖。作者 GPU 实现的 GPL 代码未复制或打包；本项目采用原生 Metal 实现。agx-emulsion 的许可未在本次整理中单独核实，使用其代码或数据前需核对上游。

## SSTV 开发验证与候选项目

| 项目 | 语言 / 许可 | 已公开的功能 | 对 AnaLine 的用途 |
| --- | --- | --- | --- |
| [dnet/pySSTV](https://github.com/dnet/pySSTV) | Python / MIT | 图片编码为 SSTV 音频；Martin、Scottie、Robot 等模式 | 清晰的编码参考和独立测试音频生成器；不自带解码 |
| [xdsopl/robot36](https://github.com/xdsopl/robot36) | Java / v2 分支 0BSD | Android SSTV 解码，支持音频文件和实时输入 | 研究同步、FM 解调、图像重建；不能直接当 Swift 库链接 |
| [unexcellent/sstv](https://github.com/unexcellent/sstv) | Rust / MIT | 编码和解码，流式扫描线事件，多模式；README 描述跨实现和真实录音测试 | 一体化核心候选；需要验证测试并评估 Swift/C ABI 桥接，不是假定已有 Swift API |
| [rimio/libsstv](https://github.com/rimio/libsstv) | C / MIT | 多模式编码；README 明确当前尚未实现解码 | C 接口适合接入 Swift，但单独使用不能完成信号往返 |
| [colaclanth/sstv](https://github.com/colaclanth/sstv) | Python / GPL-3.0 | 从音频文件解码 Martin、Scottie、Robot | 独立解码对照，适合开发验证 |
| [oftx/python-sstv](https://github.com/oftx/python-sstv) | Python / 本轮未核实许可 | Robot36 编解码，sstv_filter 工具，压缩与信号模拟；作者标明使用 Gemini 生成代码 | 参考效果参数与实验流程；不作为未经验证的生产依赖 |

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

PySSTV 实际用于生成独立频率测试夹具，仅为开发工具；其他项目为选型与接收算法参考，未作为 Swift 包依赖。生成脚本见 [generate-sstv-mode-fixtures.py](../Scripts/generate-sstv-mode-fixtures.py)，夹具见 [Tests/Fixtures](../Tests/Fixtures/)。具体选型和未实现功能见 [SSTV 调研记录](SSTV-research.md)。

## 标准、论文与外部工具

| 来源 | 用途 | 关系与许可边界 |
| --- | --- | --- |
| [Realistic Film Grain Rendering, IPOL 2017](https://www.ipol.im/pub/art/2017/192/) | 随机几何颗粒与光学重建原理 | 论文引用，不将文章或参考代码纳入本项目 MIT 授权 |
| [JL Barber, Proposal for SSTV Mode Specifications](http://www.barberdsp.com/downloads/Dayton%20Paper.pdf) | SSTV 模式时序与扫描结构 | 技术资料引用，未随项目分发 PDF |
| [ITU-R BT.470](https://www.itu.int/rec/R-REC-BT.470/en) | 模拟电视制式参数 | 标准引用，未分发标准全文 |
| [ITU-R BT.1700](https://www.itu.int/rec/R-REC-BT.1700/en) | 复合视频信号参数 | 标准引用，未分发标准全文 |
| [FFmpeg](https://ffmpeg.org/legal.html) | Terrestrial 视频解码、探测与伴随音轨转换 | 用户自行安装的外部工具；许可取决于构建配置，未随 App 分发 |

Bliss 测试图曾取自 [Internet Archive 存档](https://archive.org/details/theoriginalfilesofsomewindowswallpapers)。存档提供下载不等于获得开放许可；该图片和本地测试视频不属于 AnaLine 原创内容，已通过 `.gitignore` 排除。发布 App 时也应使用有分发授权的素材。
