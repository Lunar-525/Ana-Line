# AnaLine iOS 初版

独立工程：`iOS/AnaLine.xcodeproj`，scheme `AnaLine`，bundle ID `com.analine.ios`。最低 iOS 17，支持 iPhone / iPad。保留原 `AnaLineBenchmark.xcodeproj` 做性能实验。

## 已实现

- 从“文件”导入 AVFoundation 支持的视频（建议 MOV / MP4），拷贝至 App 的 Documents/Media；显示伴音预处理进度。
- 原生解码、方向与 4:3 适配；根据 PAL 25 fps / NTSC 30000/1001 的时间栅格明确选择或重复源帧。
- 现有三级流水线连续模拟；Full 默认、Fast 对应 mobile；seek 重新建立状态并预热两帧。
- 播放、暂停、seek、静音和原图滑动对照；播放恢复后的 48 kHz 单声道伴音。
- 调谐、信号、载噪比、多径、功放、前端非线性与传播开关；干净、串扰、多径、雨天预设。
- 内置原始 24 秒串扰演示（视频转为兼容的 H.264 4:2:0，原始 PCM 伴音保留，封装为 MOV）：0–8 秒灰底＋间歇 900 Hz，8–16 秒源音轨静音＋条纹，16–24 秒组合。演示没有预先混入串扰。
- 独立渲染器输出 H.264 / PCM MOV，4:3 显示比例；进度、速度倍率、取消、系统分享／保存到文件。
- JSON 会话导入／导出，记录源文件名、制式、完整模拟参数、位置与静音状态；源文件缺失时保留参数并允许重新导入替代视频。
- 显示交付 fps、速度倍率、处理时间和系统热状态；后台／音频中断时停止任务。无静默降帧率策略。

## 媒体与资源约束

视频使用流式 AVAssetReader，只保留当前／下一源帧与有界模拟流水线。伴音先转成磁盘 PCM，逐帧按 TVSoundClock 读取，不把整段音轨留在内存。取消和失败会清理输出；预览与离线输出不共享模拟状态。

导出使用有损 H.264（8 Mbps）和 无压缩浮点 PCM 伴音；视频与伴音独立写入，最后原生无重编码封装，避免跨轨背压互等。Full 的“参考精度”指模拟核心，不意味着导出文件逐位无损。倍率包含模拟与编码封装，不包含导入预处理。导出始终处理全片，从第零帧开始。

会话是 iOS 初版格式，不直接兼容 macOS `.analine` 会话；转移到其他设备时需同时提供原视频并重新定位。导入的视频与完成的输出保存在 App 文档目录，可通过文件共享管理。MKV 等 AVFoundation 不支持的输入需先转为 MOV / MP4；H.264 High 4:4:4 输入会明确拒绝，避免解码为黑帧。

## 验证

以 `--validate-initial-app` 启动，会用原生 AVAssetWriter 生成短片，再逐一测试 PAL / NTSC × Full / Fast：首帧像素内容、音频计数、seek、输出轨道与时长、重新解码后的帧数、取消清理和会话还原。报告写入 Documents/initial-app-validation.json。

模拟器四组通过，留存于 `iOS/Validation/initial-app-simulator.json`。最终版本在 iPhone 14 Pro 上四组短片与完整 24 秒演示均通过，报告为 `iOS/Validation/initial-app-14pro.json`；已开发签名并安装到该设备。这不是实时性能或感知质量验收；真机实际播放、路由切换与 iPhone 12 持续热态仍需要测试。

## 构建

```sh
xcodebuild -project iOS/AnaLine.xcodeproj -scheme AnaLine -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/iOSApp \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

在 Xcode 中选 Personal Team 和连接的手机运行即可。不能复用基准 App 的专用 provisioning profile 签名新包名。
