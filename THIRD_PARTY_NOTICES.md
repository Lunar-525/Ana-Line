# 第三方许可说明

根目录的 [GNU AGPLv3 许可证](LICENSE) 适用于 AnaLine 原创代码、文档和设计文件，不重新授权第三方资源、上游文档、许可证或本地测试素材。中文译文见 [LICENSE_zh-cn.txt](LICENSE_zh-cn.txt)，为非官方译文，以英文原文为准。第三方权利与具体许可以上游通知为准。项目未声明所有文件均适用 AGPLv3，也未将单纯的算法参考视作程序依赖。

## 随项目提供的 LUT

| 资源 | 上游 | 随附通知 |
| --- | --- | --- |
| Film-Luts CUBE 及 LUTLibrary 中同来源的样本 | [YahiaAngelo/Film-Luts](https://github.com/YahiaAngelo/Film-Luts) | [MIT 通知](Assets/FilmLuts/LICENSE)、[上游说明](Assets/FilmLuts/README.md)、[来源记录](Assets/FilmLuts/ATTRIBUTION.md) |
| hald-clut 样本 | [cedeber/hald-clut](https://github.com/cedeber/hald-clut) | [GPL-3.0 全文](Assets/LUTLibrary/hald-clut-LICENSE) |
| PoLUT 样本 | [TomPoczos/PoLUT](https://github.com/TomPoczos/PoLUT) | [GPL-3.0 全文](Assets/LUTLibrary/PoLUT-LICENSE) |
| film-lab Gold 200 样本 | [thedevmark/film-lab](https://github.com/thedevmark/film-lab)，源数据作者 Andrea Volpato | [许可说明](Assets/LUTLibrary/film-lab-LICENSE)、[完整署名与上游修改记录](Assets/LUTLibrary/film-lab-ATTRIBUTION.md)、[CC BY-SA 4.0 与上游前言](Assets/LUTLibrary/SPEKTRAFILM_LICENSE.txt) |

这些样本的原始字节未经 AnaLine 修改。film-lab 已将 spektrafilm 数据烘焙为 LUT 并调整参数，这一上游修改及作者署名保留在随附通知中。LUT 的来源、版本校验信息和色彩空间声明见 [资源清单](Assets/LUTLibrary/ATTRIBUTION.md)与 [catalog.json](Assets/LUTLibrary/catalog.json)。在线下载的其他预设仍遵守各自上游许可。

Film-Luts 上游声明 MIT，同时明确否认拥有全部 LUT；hald-clut 汇集多个来源，其集合级 GPL 声明不能独立证明每个文件的权利链。因此这两组资源仍有单项来源未核实的问题，本项目保留原始通知但不保证上游有权授权全部内容。公开分发这些资源前，需核实具体文件的授权或移除相应资源；不能通过增加本项目自己的许可证文件消除这一问题。

## 开发与运行工具

[PySSTV](https://github.com/dnet/pySSTV) 采用 MIT，用于独立生成自制色条图的频率测试夹具。Python 和 PySSTV 均不作为 App 运行依赖，上游程序代码未随 App 分发。测试夹具的生成方式见 [Tests/Fixtures/README.md](Tests/Fixtures/README.md)。

[FFmpeg 与 ffprobe](https://ffmpeg.org/legal.html) 由用户在本机安装，AnaLine 通过子进程调用。项目未打包它们的二进制或源码；若另行捆绑，需要按具体构建的许可保留通知并履行相应分发要求。

## 本地素材与参考资料

`Assets/bliss.jpg` 和 `Assets/rickroll.mp4` 为本地测试素材，不在本项目的授权范围，默认通过 `.gitignore` 排除。打包脚本会在本地存在 Bliss 图片时复制它，因此公开发布 App 前须换成有分发授权的图片，或从 App 资源中移除它。

论文、标准和调研项目仅列作参考，其内容与许可未被本项目的 AGPLv3 文件替代。完整链接与用途见[参考项目列表](Docs/References.md)。

## CHOW Tape Model DSP

`Sources/CTapeDSP/TapeDSP.cpp` 改编自 Jatin Chowdhury 的 [CHOW Tape Model](https://github.com/jatinchowdhury18/AnalogTapeModel)，采用 **GPLv3**。准确版本、源文件和修改记录见 [NOTICE](ThirdParty/CHOWTape/NOTICE.md)，[上游 GPLv3 全文](ThirdParty/CHOWTape/LICENSE) 随源码和 macOS App 打包。GPLv3/AGPLv3 第 13 条允许此组合；CHOW 衍生部分保留 GPLv3，原创部分保留 AGPLv3。未包含 JUCE、RTNeural、xsimd 或上游 GUI。分发二进制时应提供对应源码和构建脚本，不能仅提供署名。
