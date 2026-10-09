# Terrestrial picture and sound RF simulator

The shared CVBS encoder/decoder remains available. Terrestrial uses `VSBModulator`,
`TerrestrialRFChannel`, and `TerrestrialReceiver` instead of the old CVBS channel.
`TerrestrialSoundEngine` supplies the primary mono FM sound channel.

## Profiles and representation

- PAL-D/K: 625/50, nominal 8 MHz channel, 6 MHz vision bandwidth.
- NTSC-M: 525/59.94, nominal 6 MHz channel, 4.2 MHz vision bandwidth,
  7.5 IRE active-picture setup. The shared NTSC CVBS source remains zero-setup.
- Both profiles use a nominal 0.75 MHz VSB region.
- Vision uses its original 4fsc complex-envelope rate. Sound uses a separate
  384 kHz complex envelope around its RF carrier, with 48 kHz mono input/output.
  Each branch evaluates the same linear propagation model over its own frequency
  band. This does not assert 4fsc can carry an entire cable network.

The modulator maps CVBS sync=-0.3 V, blanking=0 V, white=0.7 V to carrier amplitudes
1.0, 0.7375, 0.125. Its asymmetric complex FIR retains the upper sideband and
suppresses the lower sideband above the vestigial region. Inside the video passband,
H(f)+H(-f)=2, preserving baseband amplitude after coherent detection. FIRs are causal,
with persistent history; the decoder recovers their timing delay from sync pulses.
These windowed finite filters approximate the nominal response, not a certified
transmitter spectral mask. The existing PAL picture encoder is limited to 5 MHz.

## Channel and controls

- Signal level: voltage gain `10^(dB/20)` relative to the nominal transmitter.
- Reference C/N: complex white Gaussian noise power referenced to an unattenuated
  blanking-level vision carrier, **over the RF sampling bandwidth**. It is not a
  measured post-IF C/N. Reducing signal level with a fixed noise floor reduces C/N.
- Multipath: one additional fractional-sample delayed complex path. Amplitude is a
  voltage ratio; phase is total relative phase at the carrier. Delay history crosses
  frame boundaries. This manual path adds to the optional scene's ground/clutter paths.
- Tuning: receiver LO offset applied to I/Q before its complex IF filter. Filter lower
  edge is -1.25 MHz; upper edge is configured channel bandwidth minus 1.25 MHz.
  Tuning therefore affects both carrier capture and the received spectrum.
- AFC capture range: +/-150 kHz. Coarse frequency is measured from unwrapped received
  phase after the initial filter transient; a narrow proportional carrier PLL follows
  phase. The decoder does not receive transmitter carrier phase/frequency as an oracle.
- AGC: fast acquisition plus block-smoothed sync-tip quantile gain estimation,
  followed by a detected back-porch clamp. It cannot restore S/N erased by RF noise.
  Manual mode bypasses the automatic RF gain estimate.

## Sync and playback

A separate 700 kHz detector filter and hysteretic slicer protect sync detection from
chroma and sample noise. A train of three broad pulses establishes vertical timing;
valid horizontal intervals update the raster period. Lock requires >65% active-line
matches and carrier capture. Holdover lasts three frame blocks, followed by a
free-running raster until reacquisition. Loss is a status, not an exception.

The H Sync, V Sync and Color Sync lamps expose separate detector states. H uses
valid horizontal intervals with carrier capture; V uses the broad vertical pulse
train; color requires current H detection and burst lock on >65% of active lines.
Each lamp has independent three-frame holdover: green=detected, amber=holdover,
red=searching, and gray=no loaded video/preparation. A lost V train does not force
H off; removing chroma bandwidth can lose color while retaining H/V.

The selected PAL/NTSC nominal raster is known, as in a manually selected receiver
standard. The shared color decoder still uses standard/frame-index PAL phase
conventions; it is not a universal decoder for unknown off-air recordings.

Playback preserves DSP state across consecutive frames. CPU-limited playback slows
the common audio/video clock instead of dropping RF samples. A seek resets state;
two frozen-picture pre-roll frames warm the receiver. This reconstructs steady
reception at the seek position, not the exact historical receiver state before it.
Paused slider changes also reacquire from pre-roll. Independent scanlines and FIR
branches use CPU parallelism; filtering and sample math use Accelerate SIMD. Feedback
loops and consecutive frames preserve time order. Measurements and parallel boundaries
are documented in [Terrestrial performance](Terrestrial-performance.md). This CPU
implementation is not a real-time guarantee.

## Primary FM sound

The mono profiles follow the primary sound parameters in ITU-R BT.470 Table 3:
PAL-D/K uses a +6.5 MHz carrier offset, ±50 kHz deviation and 50 μs emphasis;
NTSC-M uses +4.5 MHz, ±25 kHz and 75 μs. Both use a 10:1 vision sync-carrier/sound
power ratio. Stereo inputs are downmixed by FFmpeg; BTSC, A2 and NICAM are not implemented.

PCM → 15 kHz source filter → pre-emphasis and over-deviation limiter → continuous
FM phase integration → complex RF channel → projected front-end passband → tuning
and vision-derived AFC → sound IF → phase-difference discriminator → de-emphasis,
audio lowpass and DC rejection → 48 kHz PCM.

Sound attenuation and noise floor use the same controls as vision. The RF C/N
definition remains referenced to the vision blanking carrier over the vision RF
sampling bandwidth; sound noise power is scaled by its sample-rate ratio to preserve
noise spectral density. Delayed echoes include the extra carrier-spacing phase
`-2π × soundCarrierHz × delay`, in addition to the user-selected vision-carrier phase.
Reducing IF bandwidth can reject the sound carrier while the picture still works.
FM amplitude limiting is implicit in phase discrimination; vision AGC does not
force the sound output volume. Optional separate transmitter PAs model envelope
compression and phase conversion before propagation; cross-carrier nonlinear products
are not represented by the separate envelopes.

The separate envelopes are a multirate propagation model with separate PAs and a split-carrier
receiver. Sound is not mixed into the high-rate vision arrays. Intercarrier picture
buzz, sound-to-picture interference, stereo multiplexes and receiver hardware
nonlinearities require additional models. The finite filters approximate bandwidths.

## Interactive propagation scene

The white rectangular Propagation panel above Reception is a vertical TX–RX profile,
with a fixed 0–50 km horizontal axis and an exaggerated height scale. Drag the RX
antenna mast to change distance (3–50 km) and height (2–150 m); drag its elements to
rotate elevation (±90°). Numerical fields provide the same controls. Changing kind
selects a generic dipole, Yagi, log-periodic or bow-tie array and resets gain to its
nominal 2.15/12/8/10 dBi; gain remains independently adjustable from −5 to +25 dBi.
Direction patterns are generic elevation-plane approximations, not product data.

TX height, carrier frequency (50–860 MHz), effective-Earth-radius k and an optional
ridge determine clearance and the first Fresnel zone. Drag the ridge's apex for its
height and relative position; switching Ridge off retains its settings while removing
that obstruction. Earth curvature remains. Free-space loss follows 20 log10(4πd/λ).
An effective-Earth bulge and a single equivalent knife edge use the P.526 Fresnel
parameter and J(v) approximation. An off-path ridge can still leave curvature as the
dominant obstruction; this first version does not solve multiple edges or a spherical
Earth diffraction field. The yellow bent line illustrates the obstructed path, not
an exact ray trajectory or diffraction phase solution.

The uncalibrated RF envelope is normalized against a 10 km / 600 MHz / aligned 12 dBi
reference. FSPL is an absolute loss diagnostic; “Link relative” is a voltage gain in
dB relative to that reference, **not RSSI in dBm**. Existing Signal level multiplies
the scene's output. RX gain/direction and diffraction lower desired signal without
scaling away the receiver noise floor. Antenna gain applies to admitted remote sources.
Scene is enabled in the app by default; the core API defaults to bypass for compatibility.
Disabling it bypasses all scene and weather contributions. Reset reception preserves
the scene and transmitter controls.

An optional ground reflection uses geometric excess path length, fractional delay,
carrier-dependent phase and a π reflection inversion. Wet surfaces strengthen that
path. Precipitation clutter supplies an additional weak delayed path with 0.07 Hz
Doppler. Their histories cross frame boundaries; absolute propagation delay and common
carrier phase are omitted because the simulated receiver is locally tuned. No terrain
map, material database, azimuth/polarization model, ray tracer or tropospheric duct
solver is included.

## Weather and transmitter controls

Weather is adjusted directly on the Propagation sky drawing (vertical drag, double-click
reset), with current units beside each phenomenon and adjustable accessibility actions.
A drag enables weather; bypass preserves the settings. Sunlight is controlled on the sun in the TX–RX profile, rather than the sky grid.
Rain and lightning have separate leaf-only TimelineView clocks (24 Hz profile /
12 Hz glyphs); bypass, zero activity, removal and Reduce Motion pause their clocks.
Motion uses analytic positions and bounded primitive counts, without configuration
writes or RF work. Flash frequency follows the scenario level, but the drawing is an
illustrative weather preview, not a visualization of individual RF impulse timestamps.

Weather is explicitly enabled; default rain/snow/fog/lightning/remote interference are
zero. Rain is mm/h, snow is mm/h **water equivalent**, fog is liquid-water g/m³, humidity
is %, temperature is °C, and daylight/clutter/lightning/ionization are scenario levels.
The following coefficients are illustrative controls, not measured propagation data:

- Sub-GHz bulk loss is d_km × (f_GHz)² × (0.00012 rain + 0.00006 snow + 0.002 fog),
  plus a small wet-antenna/surface loss. P.838 is **not extrapolated below 1 GHz**.
  Wetness also changes reflected/clutter energy. The GUI depicts rain, snow and fog over
  the TX–RX profile; these are diagram illustrations, not extra video effects.
- Weather perturbs the assumed refractivity gradient by
  24(sun−0.5) − 0.12(RH−50) + 0.15(T−20) N/km, then derives effective k with a
  0.65–4 limit. Surface temperature/humidity alone cannot establish a real atmospheric
  vertical gradient; this is a controllable scenario, not a meteorological prediction.
- Temperature scales RF thermal-noise amplitude by sqrt((T+273.15)/293.15).
- Lightning adds deterministic, exponentially decaying 3 ms RF-noise bursts. Image
  and sound share event times and seed, sampled at their own rates with noise-density
  scaling. Maximum activity averages two events per second. Seeking reconstructs the
  same event timeline rather than drawing another random flash.
- Ionospheric interference represents a synthetic **remote** near-co-channel TV source,
  with AM vision and independently modulated FM sound, +26 kHz detuning and a 173 Hz
  programme tone. Its admission strongly decreases with frequency above 100 MHz.
  The scalar control is not a solar/ionosphere forecast, nor direct UHF ionospheric
  attenuation of the local terrestrial path.

Transmitter nonlinearity is optional. Backoff controls saturation headroom, hardness
controls smoothness, and AM/PM shift adds envelope-dependent phase rotation. A cached
complex-gain table applies a bounded memoryless compression law to a 2× interpolated
envelope, followed by a 25-tap anti-alias FIR and decimation. Separate vision and sound
PAs reuse this model. It does not model a combined-carrier PA, intermodulation between
vision and sound, thermal memory, or a certified transmitter spectrum mask.

Reference concepts: [ITU-R P.526 diffraction](https://www.itu.int/rec/R-REC-P.526/en),
[P.453 refractivity](https://www.itu.int/rec/R-REC-P.453/en),
[P.838 rain](https://www.itu.int/rec/R-REC-P.838/en),
[P.840 cloud/fog](https://www.itu.int/rec/R-REC-P.840/en),
[P.372 radio noise](https://www.itu.int/rec/R-REC-P.372/en) and
[BETS-4 transmitter requirements](https://ised-isde.canada.ca/site/spectrum-management-telecommunications/en/devices-and-equipment/broadcasting-equipment-standards/bets-4-technical-standards-and-requirements-television-broadcasting-transmitters).

An AVAudioEngine source node consumes a bounded PCM FIFO. Playback primes six frames;
video follows the consumed PCM clock with output latency compensation. TimePitch
smoothly slows CPU-limited playback while preserving pitch. Underruns emit silence
and stop advancement of media time; pause and seek flush queued PCM. The real-time
callback is nonisolated and accesses only a lock-protected, preallocated queue.
The producer yields after rendering and waits only when the PCM FIFO is full.
Device-start failures are reported in the UI rather than silently ignored.

## FFmpeg preparation

Video is normalized to lossless H.264 4:4:4 at the chosen raster/frame rate. Sound
is decoded to a separate mono float32 little-endian 48 kHz scratch file, with timestamp
alignment and padding to the normalized video duration. PCM is memory-mapped when
possible and read by absolute integer frame boundaries, avoiding NTSC rounding drift.
Replacing or unloading the video removes both intermediates.

The rectangular preparation bar reads FFmpeg `-progress pipe:1` / `out_time_us`.
When sound exists, video occupies 0–90% and PCM conversion 90–100%; silent clips use
the full range for video. Input inspection or unknown source duration shows an
indeterminate indicator. Progress measures processed media time, not an ETA.

## RX spectrum diagnostics

Reception lives below the preview. The VSB view measures the actual vision IQ
after LO mixing and the complex IF filter, before carrier recovery and AGC.
The FM view measures actual sound IQ after the common front-end passband
projection, before its AFC mixer, sound IF, and discriminator. These remain
separate envelope measurements, rather than a fabricated full-channel RF FFT.
Frequencies use the receiver tuning reference: vision is centered at 0 Hz;
sound is centered at its nominal spacing minus the LO tuning offset.

Eight distributed windows per presented frame use a periodic Hann window and
a full complex FFT (2048 vision / 512 sound samples). FFT-shifted bin powers are
normalized by `N * sum(window²)` so their sum estimates mean IQ power; resolution
is reported as the Hann equivalent noise bandwidth, `1.5 * sampleRate / N`.
The [Accelerate complex FFT](https://developer.apple.com/documentation/accelerate/vdsp_fft_zip)
preserves both independent quadratures and the sign of frequency. Plot columns
use peak bin pooling to retain narrow carriers; the fixed −100…0 dBFS/bin palette
does not normalize away signal attenuation. This is not a calibrated dBm display.

Waterfalls store 100 rows at 100 ms intervals, newest at the top. Only frames
presented against the playback clock update history; ahead-of-time DSP results
do not enter it. Re-presenting a paused frame replaces its row. Missing time
buckets stay blank. Seeking/source replacement resets history; a changed sound
frequency axis resets that branch. Frequency plots and the rasterized waterfall
use bounded storage and cached FFT plans.

## Validation

Tests cover positive/negative sideband rejection, carrier amplitude, clean PAL/NTSC
field/color recovery, attenuation and automatic gain, detuning and AFC, loss/holdover/
reacquisition, and RF multipath behavior. FFmpeg integration uses Assets/rickroll.mp4;
GUI checks cover seek/play/pause and source replacement. FM checks cover clean tone
recovery, emphasis, noise, attenuation, tuning, band rejection and carrier-dependent
multipath; native audio checks verify PCM consumption, mute, queue boundaries and
the shared presentation clock. FFmpeg integration verifies intermediate progress and
nonzero decoded soundtrack PCM. These tests are numerical
checks of the model, not validation against measured receiver hardware.

## References

- ITU-R BT.470, conventional analogue television systems:
  https://www.itu.int/rec/R-REC-BT.470/en
- ITU-R BT.470-6, Table 3 primary sound parameters:
  https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.470-6-199811-S!!PDF-E.pdf
- ITU-R BT.1700, characteristics of composite video signals:
  https://www.itu.int/rec/R-REC-BT.1700/en

Historical analogue systems are intentional here. CATV, satellite FM/TVRO and
VHS/Video8 recording models are not part of this mode.

### 编码器、发射机和接收电路破坏

播放器的显示窗口固定为 640 × 480（4:3）。PAL 的 720 × 576 和 NTSC 的 720 × 480 是采样尺寸；显示像素宽高比分别采用 16:15、8:9。FFmpeg 先按输入 SAR 恢复显示比例，在 4:3 画布上保留宽屏黑边，再转换为标准采样网格。GUI 按编码／发射、Propagation、接收／重建、Reception 排列；天气属于 Propagation。

新模型默认关闭，原有链路保留：

- **编码器**：低通后的 Y 决定色度向量的增益与旋转角；burst 相位、幅度和按绝对视频时间计算的正弦漂移单独作用于后肩色同步采样。PAL 的逐行相位交替及延迟线仍参与解码，能够抵消部分相位误差，并不强制生成与 NTSC 一样的偏色。
- **VSB 滤波器**：原有复数 FIR 加入可调过渡带、高频峰化以及三次频率相位项；附加群延迟随频率平方变化，标注的 ns 为 fsc 处的附加值。固定 97 taps 限制了极窄过渡带的真实陡峭度，这是可控硬件失真模型，不是指定设备的测量曲线。
- **功放**：2× 采样复包络 AM/AM、AM/PM 模型保留。新增两载波包络之间的交叉压缩，使用 in-band rotating-wave 近似（本载波功率 + 2×耦合×另一载波功率）。它会产生通带内包络调制，但不生成覆盖完整频道的所有载波间三阶频谱产物。音频额外驱动作用于 FM 调制前的限幅器；恒包络 FM 的独立 PA 压缩不等同于音频波形削顶。
- **AGC**：同步尖端目标驱动二阶 log-gain 伺服，可调响应和阻尼。亮度耦合模拟受画面平均电平污染的 AGC 检波，后肩钳位采用有限时间常数，避免瞬时归一化抵消全部泵浦。伴音共用增益，固定 ADC 噪声与过载位于 FM 鉴频器前；线性增益本身不会凭空改变 FM 音量。
- **H/V 同步**：在实测脉冲和载波可捕获判定之后加入持久振荡器、死区与有限捕获窗；行振荡器在场消隐脉冲间隔中自由运行并逐行恢复，场频偏差可离开捕获窗后滚屏、再次进入后拉回。滚屏以当前复合采样帧的循环寻址模拟跨场扫描，边界处复用当前帧而非未来帧。抖动作用于恢复扫描时钟，不是 RGB 后处理。无信号时仍保留雪花和自由扫描。
- **Y/C 分离**：可选 notch / comb，梳状失效按相邻传输行不一致程度退化至陷波；色度泄漏让亮度通道保留部分复合信号。源纹理本身的亮度高频也可能在色度通道混叠，dot crawl / cross-color 依赖纹理与连续的副载波相位，不是预制纹理。

这是可交互的电路／信号模型，未模拟元件温漂的完整电路、发射频谱模板或显示器扫描电子束。

物理定义参考：[Analog Devices 视频参数视觉影响](https://www.analog.com/en/resources/technical-articles/2022/07/21/08/24/visual-impact-of-video-parameters-in-video-systems.html)、[Tektronix RF 电视测量说明](https://download.tek.com/document/25W_7247_1_rfs.pdf)。

### 编码／发射机架与功率监测

GUI 的第一段改为 Encoder、2U VSB / Group Delay、3U Transmitter 三块纵向机架。参数仍写入同一份 `TVControlState`；左侧开关旁路的是附加硬件失真，基本编码和发射继续工作。检修弹层不增加页面高度。AppKit 旋钮通过局部命中区域处理拖动、滚轮、Shift 精调、双击复位、键盘与辅助功能，不监听全局输入。

`TVTransmitterTelemetry` 在每帧记录 PA 抗混叠降采样后的前向平均功率 `mean(I² + Q²)`。图像与伴音采用原有两个窄带包络，平均功率相加；参考为图像同步载波功率 1，以及存在伴音时的标称 0.1。仪表显示 `100 × power / referencePower`，是相对功率，不是校准瓦数或覆盖全频道互调产物的测量。PA 开启时，两路 FIR 工作任务各自统计输出能量，再合并结果；饱和检测保留 2× 插值驱动的逐样本峰值，包含交叉压缩的另一载波项。PA 关闭时功率仍从未经 PA 的 I/Q 测量。

新增的负载 VSWR 是匹配源条件下的无源标量失配：`Γ = (VSWR − 1) / (VSWR + 1)`，返回功率为 `Pforward × Γ²`，图像与伴音进入 RF 信道前都乘以 `sqrt(1 − Γ²)`。默认 VSWR 1 时不改变样本。模型没有馈线相位、谐振、功放 load-pull 或反射波重新压缩，也不把地形／天气多径当作馈线返回功率。关系参考：[Rohde & Schwarz VSWR 与返回损耗](https://www.rohde-schwarz.com/us/products/test-and-measurement/essentials-test-equipment/spectrum-analyzers/voltage-standing-wave-ratio-vswr-and-return-loss_258140.html)。

`PA SATURATION` 在开启的任一 PA 驱动峰值达到其 backoff 定义的饱和参考时亮起；这不是压缩为零与非零的分界。`OVERMODULATION` 在图像负极性 AM 包络小于零或伴音预加重／驱动后触发 ±1 限幅时亮起；伴音支路保留限幅，不生成超出原有 FM 偏移限制的波形。UI 仪表按现有媒体时间 100 ms 桶更新独立的 `TVTXInstrumentState`，不让整份工作区或旋钮随仪表更新重新求值。无输入时读数为空，指针停驻。

### 发射功率与传播控制分离

GUI 移除 `Signal level` 与 `Reference C/N` 两个传播滑块，保留回波控制。接收电平由 TX、路径增益、天线、障碍与天气产生；底层 `signalDB` / `carrierToNoiseDB` 保留用于离线诊断及既有数值测试，GUI 使用默认的 0 / 45 dB 参考，不再提供独立覆盖控件。这一参考是相对校准，没有绝对瓦数／dBm 或完整接收天线热噪声标定。

新增 `TVTransmitterSettings.powerDB`，范围 −60～+12 dB，默认 0。图像 VSB 输出与伴音 FM 包络在各自 PA 前乘以 `10^(powerDB/20)`；两载波交叉压缩的另一载波功率也按 `10^(powerDB/10)` 缩放。功率旋钮在 PA 模型旁路时仍有效，默认 0 dB 跳过图像额外缩放并保持旧链路。PA backoff 保持相同饱和参考，因此提高驱动会增加压缩及饱和概率。仪表继续测量实际的 PA 输出能量，再按 VSWR 分配前向、返回与送达负载功率，参考刻度不随旋钮一起缩放。

传播噪声底没有乘以 TX 功率；弱发射功率降低接收 C/N，而不会把噪声也一起降下去。发射功率不改变 FM 频偏、源 PCM 音量或音频调制器驱动。测试覆盖 PAL／NTSC 的图像／伴音电平比例、两只功率表比例、固定噪声底、PA 压缩及交叉载波的参考路径对照。
