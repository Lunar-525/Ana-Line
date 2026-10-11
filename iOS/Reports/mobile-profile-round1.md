# 移动端性能档位（第一轮）

实现日期：2026-10-12。分支：`iOS`。目标：按用户给出的六项优先级降低统一电视链路在手机上的持续耗时，同时不改变 macOS 默认行为。

**当前状态：代码、回归测试和 iOS 构建已完成；真机 A/B 尚未执行，本文所有耗时数字来自 Mac 主机（M3 Max），只用于确认改动方向，不能当作 iPhone 结论。**

## 一、六项优先级的落地情况

新增 `TVChainProfile`（`Sources/AnalogCore/TVChainProfile.swift`），通过 `TerrestrialSettings.performance` 传入，默认 `.full`。非 iOS 调用方和旧会话仍是参考档位，代码路径与改动前相同。

| 优先级 | 目标 | 实际实现 | 质量代价（实测） |
| --- | --- | --- | --- |
| 1 | 声音上采样、载波合成 | 插值抽头改用单精度累加（核函数长度、抽头位置、抗镜像响应完全不变）；FM 相位积分改用整数采样表 | 0 |
| 1 | 声音提取 | 抽头同样改单精度累加；抗混叠核长度保持 12 | 0 |
| 2 | 载波 PLL | 锁定后相位误差反馈每 2 个 RF 样本更新一次，振荡器仍逐样本推进；失锁/捕获恢复逐样本；振荡器 sin/cos 与相干检波按区间并行 | PAL ≤0.003，NTSC ≤0.005 峰值 RGB 误差 |
| 3 | RF 信道噪声 | 每个工作线程独立 Box-Muller 流覆盖互不重叠的样本区间，按绝对样本索引寻址；分布、功率、白噪特性与参考实现完全相同 | ≈0.0001 |
| 4 | 调制、功放 | 曲线查表从 8193 点降到 2049 点并按单精度索引；交叉压缩功率估计按 4 抽样 | PAL ≤0.001（NTSC 0） |
| 5 | 载波估计／AFC | 锁定后载波滤波器输出按 8 抽取后估计（滤波器本身即抗混叠），捕获/失锁恢复逐样本 | 0 |
| 6 | 频谱、功率统计 | 频谱平均窗口 8 → 2（仅显示用，功率按窗口数归一） | 0（显示噪声变大） |

失败即恢复密集更新是共用的：`carrierTracked` 由上一帧的捕获结果决定，一旦失锁，下一帧 AFC 抽取与 PLL 步长都自动回到 1。测试 `testMobileAFCRestoresFullEstimateAfterLoss` 直接验证该行为。

## 二、被测量否决的改动

用户列出的取舍里，有三项按建议实现后经实测否决，已回退到参考值：

| 尝试 | 实测结果 | 结论 |
| --- | --- | --- |
| 声音上采样核半径 6 → 3 | 损伤 PAL 峰值 RGB 误差 0.086，NTSC 0.80（半径 5 时 0.029／0.025，半径 4 时 0.057／0.57） | 正是"杂散串入画面"。回退，改用不改变核响应的单精度累加 |
| 声音提取核半径 12 → 10 | 主机耗时无可测收益 | 回退，保留保守抗混叠 |
| 功放抗混叠核半径 12 → 6 | PAL 0.029／NTSC 0.023 误差，收益约 0.2–0.3 ms | 回退（该项也超出用户指示范围） |
| 噪声改用均匀分布求和近似 | 主机基准：Box-Muller 1.40 ms／次，Irwin-Hall(4) 1.93 ms（更慢），Irwin-Hall(3) 1.36 ms | 串行 PRNG 才是瓶颈，不是超越函数。改为并行精确 Box-Muller，既不损失分布又更快 |
| PLL 步长 4 或 8 | NTSC 峰值 RGB 误差 0.60（步长 2 为 0.011） | 取 2 |

## 三、主机阶段耗时对照

损伤场景，统一音画链路，Release，每档 9 帧均值（毫秒）：

| 阶段 | PAL 参考 | PAL 移动 | 变化 | NTSC 参考 | NTSC 移动 | 变化 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 合计 | 28.47 | 25.25 | −11% | 20.52 | 17.18 | −16% |
| VSB＋功放 | 5.83 | 5.43 | −7% | 4.35 | 3.57 | −18% |
| RF 信道 | 4.48 | 3.51 | −22% | 2.86 | 1.87 | −35% |
| 调谐／IF | 2.80 | 2.87 | +2% | 2.12 | 1.84 | −13% |
| 载波估计 AFC | 1.97 | 1.11 | −44% | 1.31 | 0.75 | −43% |
| 载波 PLL | 4.69 | 3.67 | −22% | 3.06 | 2.42 | −21% |
| 同步 | 3.68 | 3.73 | +1% | 2.49 | 2.43 | −3% |
| 视频解码 | 2.15 | 2.11 | −2% | 2.27 | 2.37 | +4% |
| 声音提取 | 0.90 | 0.86 | −5% | 0.60 | 0.59 | −2% |

被指定优化的四个阶段都下降，未改动的同步与解码在噪声范围内不变。主机上单次运行波动可达 ±1.5 ms（同一设置两次相差 3 ms 以上），因此只有幅度明显且方向一致的项才可采信；手机上的相对收益需要真机复测。

## 四、确定性的工作量下降

这些与机器无关，可直接核对：

- 载波估计：锁定后每帧载波滤波器输出点数为 1/8（`carrierEstimationDecimation`）。
- 载波 PLL：锁定后每帧相位误差评估次数为 1/2（`carrierPLLStrideUsed`）。
- 噪声：同样的 2 次均匀采样/复数样本，但分布到最多 8 个工作线程，且按绝对样本索引寻址，结果与线程数无关。
- 频谱：每帧 FFT 窗口 8 → 2。
- 交叉压缩功率：每帧读取样本数 1/4。
- 功放曲线表：8193 → 2049 点（16 KB，可常驻一级缓存）。

## 五、不破坏 macOS 的验证

- `TVChainProfile.full` 的每个开关都取回原常量，`.full` 走原分支与原算式；并行噪声、并行检波、单精度累加、粗索引都只在非 `.full` 档位生效。
- 新增 `TVChainProfile` 的编码使用 `decodeIfPresent`，缺少该键的旧会话解码为 `.full`（`testLegacySessionWithoutProfileDecodesAsFull`）。
- FM 整数调度被证明与浮点调度逐位一致（`testIntegerFMPhaseScheduleIsExact`），因为统一信道的 RF/PCM 比率恰好是 8。
- `swift test -c release`：142 项通过、0 失败（改动前 131 项，新增 11 项移动档位测试）。
- `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` 构建通过（`TVChainProfile.swift` 已加入 iOS 工程）。

## 六、真机复测方法

手机上默认使用移动档位，报告里新增 `chainProfile` 字段。建议同一台手机、同一热状态下跑两次并对比：

```sh
xcodebuild -project iOS/AnaLineBenchmark.xcodeproj -scheme AnaLineBenchmark \
  -configuration Release -destination 'id=YOUR_DEVICE_UDID' \
  -derivedDataPath build/iOSBenchmark DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  build/iOSBenchmark/Build/Products/Release-iphoneos/AnaLineBenchmark.app
# 移动档位
xcrun devicectl device process launch --device YOUR_DEVICE_UDID com.analine.benchmark --benchmark-sustained
xcrun devicectl device copy from --device YOUR_DEVICE_UDID --domain-type appDataContainer \
  --domain-identifier com.analine.benchmark --source Documents/benchmark.json \
  --destination iOS/Reports/iphone-mobile-sustained.json
# 参考档位对照
xcrun devicectl device process launch --device YOUR_DEVICE_UDID com.analine.benchmark --benchmark-sustained --benchmark-full
xcrun devicectl device copy from --device YOUR_DEVICE_UDID --domain-type appDataContainer \
  --domain-identifier com.analine.benchmark --source Documents/benchmark.json \
  --destination iOS/Reports/iphone-full-sustained.json
python3 iOS/summarize.py iOS/Reports/iphone-mobile-sustained.json
python3 iOS/summarize.py iOS/Reports/iphone-full-sustained.json
```

## 七、边界与后续

- 本轮不承诺整帧实时。主机合计下降 11–16%，按同比例外推，iPhone 14 Pro 的持续损伤 PAL 仍在 60 ms 量级，高于 40 ms 帧预算；默认 NTSC 更接近预算但需真机确认。
- 未做：视觉 VSB 的 97 抽头 FIR（"调制"里最大的一项）、视频解码、同步。若要继续压缩，应优先批量 FIR／重采样与解码，而不是继续降低估计精度。
- 未做：把档位接到 macOS 界面或命令行开关。目前只有 iOS 基准和会话文件能找到它。
- 档位里的 `soundUpsampleRadius`、`soundUpsamplePhases`、`soundExtractionRadius`、`amplifierAntiAliasRadius` 在移动档位等于参考值，保留字段是为了让被否决的取舍可复现、可再测。
