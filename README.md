AnaLine 是一个使用 Swift 开发的 macOS 模拟影像实验工具，提供胶片效果、慢扫描电视（SSTV）和地面模拟电视（Terrestrial）三种模式。胶片模式支持 LUT 调色、程序颗粒和漏光；SSTV 支持 Robot36、Martin M1、Scottie S1 与 PD120，可观察逐行传输并调整信道损伤；电视模式将音画经过 VSB 图像与单声道 FM 伴音的模拟广播信号链路，呈现噪声、多径和失锁等接收效果。它用于影像创作与算法实验，当前模型并非经过实测标定的胶片系统或完整广播设备。

项目要求 macOS 13 或更新版本，以及支持 Swift 6 的 Xcode 或 Command Line Tools。运行 `swift run AnaLine /完整路径/image.jpg` 可打开图片，也可启动后通过界面选择、拖入或粘贴图片。运行 `sh Scripts/build-app.sh` 可生成 `build/AnaLine.app`，SSTV 麦克风功能需使用打包后的 App。Terrestrial 模式需要本机安装 FFmpeg 和 ffprobe；它们作为外部程序调用，不随项目分发。Swift 包没有第三方包依赖，部分 LUT 首次使用时需联网下载并校验。

运行 `swift test` 可执行测试。命令行工具使用 `swift run -c release analog input.jpg output.png` 处理图片，也可附加 JSON 配方路径；它保留独立的 CPU 效果链，与图形界面的渲染流程不同。Terrestrial 使用多核 CPU 和 Accelerate SIMD，测量结果见[性能说明](Docs/Terrestrial-performance.md)。完整操作说明和算法限制见[使用说明](Docs/Usage.md)，颗粒、SSTV 和电视信号的实现细节见 [Docs](Docs/)。

原创代码、文档和设计文件采用 [MIT 许可证](LICENSE)。第三方 LUT 保留各自许可，不包含在本项目的 MIT 授权范围内；资源来源、许可证及参考用途汇总于[参考项目列表](Docs/References.md)和[第三方许可说明](THIRD_PARTY_NOTICES.md)。Bliss 壁纸和测试视频属于本地测试素材，默认不纳入版本控制；克隆项目后请使用自己的图片和视频。部分 LUT 上游仅提供集合级许可声明，单项资源的权利链仍未核实，不能将其视为已获得统一的 MIT 授权。
