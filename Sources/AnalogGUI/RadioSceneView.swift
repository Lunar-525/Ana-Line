import SwiftUI
import AnalogCore

@MainActor
struct RadioSceneView: View {
    @ObservedObject var model: RadioSceneModel
    @State private var environment = false
    private let accent = EditingTool.radio.logoAccentColor
    var body: some View {
        RadioSceneTelemetry.sceneBodies += 1
        return VStack(alignment: .leading,spacing: 16) {
            RadioSceneTransport(model: model)
            HStack(spacing: 10) {
                // The rack is fixed at eight, so the useful number is how many
                // are on air — the power switch on each card is what changes it.
                Text("TX 通电 \(model.settings.transmitters.filter(\.enabled).count) / \(RadioSceneSettings.transmitterSlots)")
                    .font(.system(size: 10,weight: .semibold,design: .monospaced))
                Menu("演示场景") {
                    Button("同频 / 近频串台") { model.demo(0) }
                    Button("邻频选择性") { model.demo(1) }
                    Button("FM 同频捕获") { model.demo(2) }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text("频率纵轴 · 功率横轴").foregroundStyle(TVPropagationPalette.muted)
                Button { environment = true } label: { Label("环境",systemImage: "slider.horizontal.3") }
            }.buttonStyle(.bordered).font(.system(size: 10))
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.settings.transmitters.enumerated()),id: \.element.id) { index, station in
                            RadioSceneTXCard(model: model,signal: model.stationSignal(station.id),station: txBinding(station.id),index: index)
                                .frame(width: max(112,(geometry.size.width-56)/8))
                        }
                    }.padding(.vertical,4)
                }
            }.frame(height: 390)
            HStack {
                Text("RX \(model.settings.receivers.count) / 2").font(.system(size: 10,weight: .semibold,design: .monospaced))
                Button { model.addRX() } label: { Label("添加 RX",systemImage: "plus") }
                    .disabled(model.settings.receivers.count == 2).buttonStyle(.bordered).font(.system(size: 10))
                Spacer()
                Text("独立解调 · 共享 RF · 右侧为调谐前 RF 全景").font(.system(size: 9)).foregroundStyle(TVPropagationPalette.muted)
            }
            HStack(alignment: .top,spacing: 12) {
                ForEach(Array(model.settings.receivers.enumerated()),id: \.element.id) { index, receiver in
                    RadioSceneRXCard(model: model,signal: model.stationSignal(receiver.id),station: rxBinding(receiver.id),index: index).frame(maxWidth: .infinity)
                }
                RadioSceneEnvironmentPanel(model: model).frame(maxWidth: .infinity)
            }
            RadioSceneStatus(clock: model.clock)
        }.padding(6)
            .popover(isPresented: $environment) {
                TVServicePanel(title: "无线电环境") {
                    HStack {
                        TVRotaryParameter(name: "环境噪声底",value: setting(\.noiseDB),range: -120...(-20),initial: -80,step: 1,unit: "dB",digits: 0)
                        TVRotaryParameter(name: "反射场强",value: setting(\.echoGain),range: 0...0.8,initial: 0,step: 0.01,digits: 0,percent: true)
                        RadioRotaryParameter(name: "反射额外延迟",value: setting(\.echoDelayMicroseconds),range: 0...1000,initial: 30,step: 1,unit: "µs",digits: 0)
                    }
                    RadioRotaryParameter(name: "基准载波",value: setting(\.referenceCarrierMHz),range: 1...1000,initial: 10,step: 1,unit: "MHz",digits: 1)
                    Text("各台频率以基准载波的 kHz 偏移表示。场强按距离衰减，距离在 1 km 处校准；反射产生实际复数叠加和频率选择性衰落。")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                }
            }
    }
    private func txBinding(_ id: UUID) -> Binding<RadioSceneTX> {
        Binding(get: { model.settings.transmitters.first { $0.id == id } ?? RadioSceneTX(id: id) },
                set: { value in model.editTX(id) { $0 = value } })
    }
    private func rxBinding(_ id: UUID) -> Binding<RadioSceneRX> {
        Binding(get: { model.settings.receivers.first { $0.id == id } ?? RadioSceneRX(id: id) },
                set: { value in model.editRX(id) { $0 = value } })
    }
    /// A global scene knob: writes through `edit`, which refreshes the markers.
    private func setting<T>(_ keyPath: WritableKeyPath<RadioSceneSettings,T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.edit { $0[keyPath: keyPath] = value } })
    }
}

@MainActor
private struct RadioSceneTransport: View {
    @ObservedObject var model: RadioSceneModel
    var body: some View {
        HStack(spacing: 10) {
            RadioScenePlayButton(model: model).frame(width: 144)
            RadioActionButton(title: "重置时间",symbol: "arrow.counterclockwise",action: model.resetTime).frame(width: 128)
            RadioSelectionStrip(options: RadioSceneMonitor.allCases,selection: $model.monitor,label: { $0.rawValue })
                .frame(width: 252).accessibilityLabel("监听 RX；L / R 分别发送到左右声道")
            TVRotaryParameter(name: "监听音量",value: $model.volume,range: 0...1,initial: 0.4,step: 0.01,digits: 0,percent: true,horizontal: true).frame(width: 106)
            Button { model.muted.toggle() } label: { Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .buttonStyle(.plain).accessibilityLabel(model.muted ? "取消静音" : "静音")
            Spacer()
            RadioSceneTimer(clock: model.clock)
        }
    }
}
/// Only the play button and the clock text observe the clock. Keeping them out
/// of the transport body is what stops the volume knob, the selection strip and
/// the buttons from being rebuilt twenty times a second.
@MainActor
private struct RadioScenePlayButton: View {
    @ObservedObject var model: RadioSceneModel
    @ObservedObject var clock: RadioSceneClock
    init(model: RadioSceneModel) { self.model = model; clock = model.clock }
    var body: some View {
        RadioActionButton(title: clock.playing ? "暂停场景" : "启动场景",symbol: clock.playing ? "pause.fill" : "play.fill",action: model.toggle)
            .frame(width: 144).keyboardShortcut(.space,modifiers: []).disabled(model.settings.receivers.isEmpty)
    }
}
@MainActor
private struct RadioSceneTimer: View {
    @ObservedObject var clock: RadioSceneClock
    var body: some View {
        Text(String(format: "%02d:%02d",Int(clock.seconds)/60,Int(clock.seconds)%60))
            .font(.system(size: 12,design: .monospaced)).monospacedDigit()
            .accessibilityLabel("场景时间").accessibilityValue(String(format: "%.1f 秒",clock.seconds))
    }
}
@MainActor
private struct RadioSceneStatus: View {
    @ObservedObject var clock: RadioSceneClock
    var body: some View {
        HStack {
            Text(clock.status).font(.system(size: 10)).textSelection(.enabled)
            Spacer()
            Text(String(format: "DSP %.2f · 调度 %.2f / 21.33 ms · FIFO %lld · 欠载 %lld",
                clock.processingMS,clock.scheduleMS,
                clock.fifoMinimum == Int.max ? -1 : Int64(clock.fifoMinimum),clock.underruns))
                .font(.system(size: 9,design: .monospaced))
        }.foregroundStyle(TVPropagationPalette.muted)
    }
}

@MainActor
private struct RadioSceneTXCard: View {
    @ObservedObject var model: RadioSceneModel
    @ObservedObject var signal: RadioSceneStationSignal
    @Binding var station: RadioSceneTX
    let index: Int
    @State private var details = false
    private var color: Color { stationColor(index) }
    var body: some View {
        RadioSceneTelemetry.cardBodies += 1
        return VStack(spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 4,height: 4)
                Text("TX \(index+1)").font(.system(size: 10,weight: .bold,design: .monospaced))
                Spacer(minLength: 2)
                Button { station.enabled.toggle() } label: { Image(systemName: "power").foregroundStyle(station.enabled ? color : TVPropagationPalette.muted) }
                    .accessibilityLabel("TX \(index+1) 电源")
            }.buttonStyle(.plain).font(.system(size: 10))
            Picker("调制",selection: $station.mode) { ForEach(RadioSceneMode.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
                .labelsHidden().font(.system(size: 10)).frame(height: 22).accessibilityLabel("TX \(index+1) 调制方式")
            RadioTXVerticalSpectrum(display: model.txDisplay(station.id),station: $station,color: color)
                .frame(height: 156).opacity(station.enabled ? 1 : 0.3)
            RadioRotaryParameter(name: "载波偏移",value: $station.carrierHz,range: -250_000...250_000,initial: 0,scale: 1000,step: 0.1,unit: "kHz",digits: 1)
                .frame(height: 68)
            TVRotaryParameter(name: "发射功率",value: $station.powerDB,range: -60...12,initial: 0,step: 0.5,unit: "dB",digits: 1,horizontal: true).frame(height: 50)
            Button { details = true } label: {
                Text(station.mode == .cw ? "Morse / 参数…" : model.sourceNames[station.id] ?? "\(Int(station.toneHz)) Hz / 音源…")
                    .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).frame(height: 20)
                    .background(.white.opacity(0.06)).overlay(Rectangle().stroke(.white.opacity(0.12),lineWidth: 0.5))
            }.buttonStyle(.plain)
        }.padding(8).modifier(RadioPanelSurface())
            .popover(isPresented: $details) {
                TVServicePanel(title: "TX \(index+1) · \(station.mode.rawValue)") {
                    RadioRotaryParameter(name: "位置",value: $station.positionKm,range: -10...10,initial: 1,step: 0.1,unit: "km")
                    if station.mode == .cw {
                        TextField("Morse 文本",text: Binding(get: { station.morseText },set: { station.morseText = String($0.prefix(140)) })).textFieldStyle(.roundedBorder)
                        Text("支持英文字母、数字及 Morse 标点；无效文本不发射。")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                        RadioRotaryParameter(name: "Morse 速度",value: $station.wordsPerMinute,range: 5...60,initial: 20,step: 1,unit: "WPM",digits: 0)
                    } else {
                        HStack {
                            Button(model.loading == station.id ? "导入中…" : "导入独立音频…") { model.chooseSource(station.id) }.disabled(model.loading != nil)
                            Button("使用测试音") { model.clearSource(station.id) }
                        }
                        if let name = model.sourceNames[station.id] { Text(name).font(.system(size: 10)).lineLimit(2) }
                        else { RadioRotaryParameter(name: "测试音频率",value: $station.toneHz,range: 100...5000,initial: 440,step: 10,unit: "Hz",digits: 0) }
                    }
                    RadioSceneModeParameters(parameters: $station.parameters,mode: station.mode,receiver: false)
                }
            }
    }
}

@MainActor
private struct RadioTXVerticalSpectrum: View {
    @ObservedObject var display: RadioSceneTXDisplay
    @Binding var station: RadioSceneTX
    let color: Color
    private let floor: Float = -100, ceiling: Float = 16, footer: CGFloat = 12
    private nonisolated var span: Double { RadioSceneSettings.sampleRate }
    var body: some View {
        RadioSceneTelemetry.spectrumBodies += 1
        return GeometryReader { geometry in
            Canvas { context,size in
                RadioSceneTelemetry.canvasDraws += 1
                let plot = max(1,size.height-footer), width = max(1,size.width)
                func y(_ hz: Double) -> CGFloat { CGFloat(0.5-hz/span)*plot }
                func x(_ db: Float) -> CGFloat { width*CGFloat(min(1,max(0,(db-floor)/(ceiling-floor)))) }
                // Frequency grid every 48 kHz, brighter on the scene reference.
                for step in -8...8 {
                    let line = CGFloat(step)*48_000
                    var path = Path()
                    path.move(to: CGPoint(x: 0,y: y(Double(line))))
                    path.addLine(to: CGPoint(x: width,y: y(Double(line))))
                    context.stroke(path,with: .color(.white.opacity(step == 0 ? 0.20 : 0.06)),lineWidth: 0.5)
                }
                for n in 1...3 {
                    let column = width*CGFloat(n)/4
                    var path = Path()
                    path.move(to: CGPoint(x: column,y: 0)); path.addLine(to: CGPoint(x: column,y: plot))
                    context.stroke(path,with: .color(.white.opacity(0.05)),lineWidth: 0.5)
                }
                // Occupied bandwidth of the selected modulation, drawn behind the trace.
                let half = station.parameters.bandwidth(station.mode)/2
                let top = y(station.carrierHz+half), bottom = y(station.carrierHz-half)
                if bottom > 0, top < plot {
                    context.fill(Path(CGRect(x: 0,y: top,width: width,height: max(1,bottom-top))),
                        with: .color(color.opacity(0.16)))
                }
                // The profile is computed once per measurement, not per frame.
                let profile = display.profile
                if !profile.isEmpty {
                    let step = plot/CGFloat(max(1,profile.count))
                    var xs = [CGFloat](repeating: 0,count: profile.count)
                    for (row,power) in profile.enumerated() { xs[row] = x(power) }
                    var fill = Path(); fill.move(to: CGPoint(x: 0,y: 0))
                    for row in xs.indices { fill.addLine(to: CGPoint(x: xs[row],y: CGFloat(row)*step)) }
                    fill.addLine(to: CGPoint(x: 0,y: CGFloat(xs.count-1)*step)); fill.closeSubpath()
                    context.fill(fill,with: .linearGradient(Gradient(colors: [color.opacity(0.06),color.opacity(0.45)]),
                        startPoint: .zero,endPoint: CGPoint(x: width,y: 0)))
                    var trace = Path()
                    for row in xs.indices {
                        let point = CGPoint(x: xs[row],y: CGFloat(row)*step)
                        if row == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace,with: .color(color),lineWidth: 1)
                    if let peak = xs.indices.max(by: { xs[$0] < xs[$1] }), xs[peak] > 2 {
                        let peakY = CGFloat(peak)*step
                        var pointer = Path()
                        pointer.move(to: CGPoint(x: width-5,y: peakY))
                        pointer.addLine(to: CGPoint(x: width,y: peakY-3))
                        pointer.addLine(to: CGPoint(x: width,y: peakY+3))
                        pointer.closeSubpath()
                        context.fill(pointer,with: .color(color.opacity(0.9)))
                    }
                }
                var guide = Path()
                guide.move(to: CGPoint(x: 0,y: y(station.carrierHz)))
                guide.addLine(to: CGPoint(x: width,y: y(station.carrierHz)))
                context.stroke(guide,with: .color(color.opacity(0.5)),style: StrokeStyle(lineWidth: 0.5,dash: [3,3]))
                // Power legend: the horizontal axis is dB, not linear amplitude.
                let bar = CGPoint(x: 20,y: size.height-5), barWidth = max(10,width-58)
                context.fill(Path(CGRect(x: bar.x,y: bar.y-3,width: barWidth,height: 5)),
                    with: .linearGradient(Gradient(colors: [.black,color.opacity(0.35),color]),
                        startPoint: CGPoint(x: bar.x,y: bar.y),endPoint: CGPoint(x: bar.x+barWidth,y: bar.y)))
            }.background(.black.opacity(0.45))
                // Fixed labels belong to retained text views. Drawing them as
                // Text inside Canvas re-typesets forty labels on every RF update
                // and every scroll-driven canvas invalidation in the full app.
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading,spacing: 0) {
                        Text("+384")
                        Spacer(minLength: 0)
                        Text("0")
                        Spacer(minLength: 0)
                        Text("−384")
                    }.font(.system(size: 6,design: .monospaced))
                        .foregroundStyle(TVPropagationPalette.muted.opacity(0.8))
                        .frame(height: max(1,geometry.size.height-footer)).padding(.leading,2)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    HStack {
                        Text("\(Int(floor))")
                        Spacer(minLength: 0)
                        Text("+\(Int(ceiling))")
                    }.font(.system(size: 6,design: .monospaced))
                        .foregroundStyle(TVPropagationPalette.muted)
                        .frame(height: footer).padding(.horizontal,2).allowsHitTesting(false)
                }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let plot = max(1,geometry.size.height-footer)
                    station.carrierHz = min(250_000,max(-250_000,(0.5-value.location.y/plot)*span))
                })
        }.overlay(Rectangle().stroke(.white.opacity(0.08),lineWidth: 0.5))
            .help("频率为纵轴，功率为横轴（−100 至 +16 dB）。阴影为当前调制方式的占用带宽；拖动改变载波位置，旋钮可精细调整。")
    }
}

@MainActor
private struct RadioSceneRXCard: View {
    @ObservedObject var model: RadioSceneModel
    @ObservedObject var signal: RadioSceneStationSignal
    @Binding var station: RadioSceneRX
    let index: Int
    @State private var details = false
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("RX \(index+1)").font(.system(size: 10,weight: .bold,design: .monospaced))
                Picker("解调",selection: $station.mode) { ForEach(RadioSceneMode.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 90).font(.system(size: 10)).accessibilityLabel("RX \(index+1) 解调方式")
                Spacer()
                RadioSceneRFIndicator(display: model.rxDisplay(station.id),enabled: station.enabled)
                Button("监听") { model.monitor = index == 0 ? .first : .second }.buttonStyle(.bordered).font(.system(size: 9))
                Button { details = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("RX \(index+1) 参数")
                Button { station.enabled.toggle() } label: { Image(systemName: "power").foregroundStyle(station.enabled ? EditingTool.radio.logoAccentColor : TVPropagationPalette.muted) }
                Button { model.removeRX(station.id) } label: { Image(systemName: "xmark") }.accessibilityLabel("移除 RX \(index+1)")
            }.buttonStyle(.plain).font(.system(size: 10))
            RadioSceneWaterfall(history: model.rxDisplay(station.id).history,station: $station,
                transmitters: model.settings.transmitters,receivers: model.settings.receivers).frame(height: 156).opacity(station.enabled ? 1 : 0.3)
            RadioSceneLevelMeter(display: model.rxDisplay(station.id),enabled: station.enabled).frame(height: 30)
            HStack(spacing: 8) {
                RadioRotaryParameter(name: "调谐",value: $station.tuningHz,range: -250_000...250_000,initial: 0,scale: 1000,step: 0.01,unit: "kHz",digits: 2)
                RadioRotaryParameter(name: bandwidthLabel,value: bandwidth,range: bandwidthRange,
                    initial: initialBandwidth,scale: 1000,step: 0.1,unit: "kHz",digits: 1)
                TVRotaryParameter(name: "RF 增益",value: $station.gainDB,range: -24...24,initial: 0,step: 0.5,unit: "dB",digits: 1)
            }.frame(height: 68)
        }.padding(.horizontal,16).padding(.vertical,10).modifier(RadioPanelSurface())
            .popover(isPresented: $details) {
                TVServicePanel(title: "RX \(index+1) · 独立解调") {
                    RadioRotaryParameter(name: "位置",value: $station.positionKm,range: -10...10,initial: 0,step: 0.1,unit: "km")
                    Toggle("RF 前端过载 / AM-PM 非线性",isOn: $station.overloadEnabled)
                    RadioSceneModeParameters(parameters: $station.parameters,mode: station.mode,receiver: true)
                }
            }
    }
    private var bandwidthLabel: String {
        switch station.mode {
        case .cw: "接收带宽"
        case .usb,.lsb: "边带带宽"
        case .fm: "音频带宽 / IF"
        default: "音频带宽"
        }
    }
    private var bandwidthRange: ClosedRange<Double> {
        switch station.mode {
        case .cw: 100...2000
        case .usb,.lsb: 1500...5000
        default: 2000...15000
        }
    }
    private var initialBandwidth: Double {
        switch station.mode {
        case .am: 5000
        case .fm: 15000
        case .usb, .lsb: 3000
        case .cw: 800
        case .pm: 10000
        }
    }
    private var bandwidth: Binding<Double> {
        Binding(get: {
            switch station.mode {
            case .am: station.parameters.am.audioBandwidthHz
            case .fm: station.parameters.fm.audioBandwidthHz
            case .usb, .lsb: station.parameters.ssb.audioBandwidthHz
            case .cw: station.parameters.cw.receiveBandwidthHz
            case .pm: station.parameters.pm.audioBandwidthHz
            }
        },set: { value in
            switch station.mode {
            case .am: station.parameters.am.audioBandwidthHz = value
            case .fm: station.parameters.fm.audioBandwidthHz = value
            case .usb, .lsb: station.parameters.ssb.audioBandwidthHz = value
            case .cw: station.parameters.cw.receiveBandwidthHz = value
            case .pm: station.parameters.pm.audioBandwidthHz = value
            }
        })
    }
}

@MainActor
private struct RadioSceneRFIndicator: View {
    @ObservedObject var display: RadioSceneRXDisplay
    let enabled: Bool
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(enabled && display.overloaded ? Color.orange : TVPropagationPalette.muted.opacity(0.35)).frame(width: 4,height: 4)
            Text("OVER").font(.system(size: 7,design: .monospaced)).foregroundStyle(TVPropagationPalette.muted)
        }.help("RF 前端过载状态").accessibilityLabel("RF 前端过载").accessibilityValue(enabled && display.overloaded ? "过载" : "正常")
    }
}

/// Shows what the demodulator actually produced. Two transmitters sharing a
/// channel appear here as a beat and fading envelope, because the interference
/// happens in the summed RF before the detector, not in this audio path.
@MainActor
private struct RadioSceneLevelMeter: View {
    @ObservedObject var display: RadioSceneRXDisplay
    let enabled: Bool
    private let accent = EditingTool.radio.logoAccentColor
    var body: some View {
        HStack(spacing: 8) {
            Text("解调输出").font(.system(size: 7,design: .monospaced)).foregroundStyle(TVPropagationPalette.muted)
            Canvas { context,size in
                var grid = Path()
                for n in 0...4 {
                    let x = size.width*CGFloat(n)/4
                    grid.move(to: CGPoint(x: x,y: 0)); grid.addLine(to: CGPoint(x: x,y: size.height))
                }
                context.stroke(grid,with: .color(.white.opacity(0.08)),lineWidth: 0.5)
                let values = display.scope
                guard values.count > 1 else { return }
                var envelope = Path()
                envelope.move(to: CGPoint(x: 0,y: size.height/2))
                for (n,value) in values.enumerated() {
                    envelope.addLine(to: CGPoint(x: CGFloat(n)/CGFloat(values.count-1)*size.width,
                        y: size.height/2-CGFloat(min(1,value))*size.height*0.46))
                }
                for (n,value) in values.enumerated().reversed() {
                    envelope.addLine(to: CGPoint(x: CGFloat(n)/CGFloat(values.count-1)*size.width,
                        y: size.height/2+CGFloat(min(1,value))*size.height*0.46))
                }
                envelope.closeSubpath()
                context.fill(envelope,with: .color(accent.opacity(enabled ? 0.5 : 0.15)))
                context.stroke(envelope,with: .color(accent.opacity(enabled ? 0.95 : 0.3)),lineWidth: 0.75)
            }.frame(width: 128,height: 26).background(.black.opacity(0.5))
                .overlay(Rectangle().stroke(.white.opacity(0.1),lineWidth: 0.5))
            GeometryReader { geometry in
                let fraction = CGFloat(min(1,max(0,(display.levelDB+60)/60)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.5))
                    Rectangle().fill(accent.opacity(0.85)).frame(width: geometry.size.width*fraction)
                }.overlay(Rectangle().stroke(.white.opacity(0.12),lineWidth: 0.5))
            }.frame(height: 9)
            Circle().fill(enabled && display.levelDB > -0.5 ? Color.orange : Color.white.opacity(0.1)).frame(width: 6,height: 6)
            Text(String(format: "%+.0f",Double(display.levelDB))).font(.system(size: 9,design: .monospaced)).monospacedDigit()
                .foregroundStyle(enabled ? TVPropagationPalette.ink : TVPropagationPalette.muted).frame(width: 26,alignment: .trailing)
            Text("dB").font(.system(size: 7)).foregroundStyle(TVPropagationPalette.muted)
        }.help("解调后的音频电平与 21.33 ms 包络。近频串台表现为周期性差拍；这一电平只反映解调结果，信号本身在 RF 中叠加。")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("解调输出电平")
            .accessibilityValue(enabled ? String(format: "%.0f dBFS",Double(display.levelDB)) : "已关闭")
    }
}

@MainActor
private struct RadioSceneWaterfall: View {
    @ObservedObject var history: TVSpectrumHistory
    @Binding var station: RadioSceneRX
    let transmitters: [RadioSceneTX]
    let receivers: [RadioSceneRX]
    @State private var dragCenter: Double?
    private var rate: Double { history.spectrum?.sampleRate ?? station.parameters.sampleRate(station.mode) }
    private var center: Double { history.spectrum?.centerHz ?? station.tuningHz }
    private let accent = EditingTool.radio.logoAccentColor
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text("RX · kHz")
                Spacer(minLength: 2)
                Text(String(format: "±%.1f",rate/2000))
                Spacer(minLength: 2)
                Text(history.spectrum.map { String(format: "RBW %.2f kHz",$0.resolutionHz/1000) } ?? "dBFS/bin")
            }.font(.system(size: 8,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted).lineLimit(1)
            GeometryReader { geometry in
                let traceHeight: CGFloat = 32, width = max(1,geometry.size.width)
                // Captured for the nonisolated Canvas renderer below.
                let axisCenter = center, axisRate = rate
                ZStack(alignment: .topLeading) {
                    TVInstrumentPalette.screen
                    if let image = history.image {
                        Image(decorative: image,scale: 1).resizable().interpolation(.none)
                            .frame(width: geometry.size.width,height: max(1,geometry.size.height-traceHeight))
                            .offset(y: traceHeight)
                    }
                    Canvas { context,size in
                        for tick in 0...4 {
                            let column = size.width*CGFloat(tick)/4
                            var grid = Path()
                            grid.move(to: CGPoint(x: column,y: 0)); grid.addLine(to: CGPoint(x: column,y: size.height))
                            context.stroke(grid,with: .color(.white.opacity(0.12)),lineWidth: 0.5)
                        }
                        var trace = Path()
                        for (index,db) in history.trace.enumerated() {
                            let point = CGPoint(x: size.width*(CGFloat(index)+0.5)/CGFloat(max(1,history.trace.count)),
                                y: traceHeight*(1-CGFloat(min(0,max(-100,db))+100)/100))
                            if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                        }
                        context.stroke(trace,with: .color(accent),lineWidth: 2)
                        var separator = Path()
                        separator.move(to: CGPoint(x: 0,y: traceHeight)); separator.addLine(to: CGPoint(x: size.width,y: traceHeight))
                        context.stroke(separator,with: .color(.white.opacity(0.3)),lineWidth: 0.5)
                    }
                    // The same LCD face as the television receiver keeps the two
                    // instruments visually identical.
                    TVLCDSurface()
                    // Shared scene overlay: this receiver's bracket and tuning
                    // marker, the other receiver, and every transmitter in view.
                    Canvas { context,size in
                        RadioSceneMarkerOverlay.draw(&context,
                            geometry: .init(center: axisCenter,span: max(1,axisRate),size: size,traceHeight: traceHeight),
                            transmitters: transmitters,receivers: receivers,
                            owner: station.id,shadeOwnerBand: true)
                    }.allowsHitTesting(false)
                    if history.image == nil {
                        Text("等待接收样本").font(.system(size: 9,design: .monospaced))
                            .foregroundStyle(TVInstrumentPalette.muted).frame(maxWidth: .infinity,maxHeight: .infinity)
                    }
                    VStack(alignment: .leading) { Text("0 dB"); Spacer(); Text("−100 dB") }
                        .font(.system(size: 8,design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(height: traceHeight)
                    VStack(alignment: .trailing) { Text("现在"); Spacer(); Text("−10 s") }
                        .font(.system(size: 8,design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(width: geometry.size.width,height: max(1,geometry.size.height-traceHeight),alignment: .trailing)
                        .offset(y: traceHeight)
                    Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: width,height: geometry.size.height)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragCenter == nil { dragCenter = center }
                            station.tuningHz = min(250_000,max(-250_000,(dragCenter ?? axisCenter)+(value.location.x/width-0.5)*axisRate))
                        }.onEnded { _ in dragCenter = nil })
                }.clipped().overlay(Rectangle().stroke(.black,lineWidth: 2))
                    .overlay(Rectangle().stroke(.white.opacity(0.07),lineWidth: 0.5).padding(1))
            }
            HStack(spacing: 0) {
                ForEach(0...4,id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    let frequency = (center+(Double(tick)/4-0.5)*rate)/1000
                    Text(String(format: "%+.1f",frequency))
                }
            }.font(.system(size: 8,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted).lineLimit(1)
            HStack(spacing: 4) {
                Text("−100")
                LinearGradient(colors: [Color(red: 2/255,green: 4/255,blue: 10/255),Color(red: 15/255,green: 36/255,blue: 94/255),
                    Color(red: 16/255,green: 150/255,blue: 181/255),Color(red: 232/255,green: 198/255,blue: 88/255),Color(red: 1,green: 1,blue: 239/255)],
                    startPoint: .leading,endPoint: .trailing)
                    .frame(width: 54,height: 4).border(.black.opacity(0.5))
                Text("0 dBFS/bin"); Spacer()
                Text("↓ 10 s")
            }.font(.system(size: 7,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("RX 频谱 / 瀑布图")
            .accessibilityValue(history.image == nil ? "等待接收样本"
                : String(format: "%.2f s · RBW %.2f kHz",history.latestTime ?? 0,(history.spectrum?.resolutionHz ?? 0)/1000))
            .help("调谐后、解调前的窄带 I/Q 频谱；瀑布图最新一行在顶部，显示最近 10 秒。括号为当前 IF / 边带，虚线为调谐位置，T1–T8 为发射台载波。点击或拖动调谐。")
    }
}

@MainActor
private struct RadioSceneModeParameters: View {
    @Binding var parameters: RadioStationParameters
    let mode: RadioSceneMode
    let receiver: Bool
    var body: some View {
        VStack(spacing: 12) {
            switch mode {
            case .am:
                HStack {
                    RadioRotaryParameter(name: "调制度标定",value: $parameters.am.modulationIndex,range: 0.05...1,initial: 0.8,step: 0.01,digits: 0,percent: true)
                    RadioRotaryParameter(name: "音频带宽",value: $parameters.am.audioBandwidthHz,range: 2000...15000,initial: 5000,scale: 1000,unit: "kHz")
                }
            case .fm:
                RadioRotaryParameter(name: "峰值频偏 / IF",value: $parameters.fm.deviationHz,range: 1000...90000,initial: 75000,scale: 1000,unit: "kHz")
                RadioSelectionStrip(options: [0.0,50e-6,75e-6],selection: $parameters.fm.emphasisSeconds,label: { $0 == 0 ? "OFF" : String(format: "%.0f µs",$0*1e6) },height: 24)
            case .usb, .lsb:
                RadioRotaryParameter(name: "音频带宽",value: $parameters.ssb.audioBandwidthHz,range: 1500...5000,initial: 3000,scale: 1000,unit: "kHz")
            case .cw:
                if receiver {
                    RadioRotaryParameter(name: "BFO 音调",value: $parameters.cw.pitchHz,range: 300...1200,initial: 700,step: 10,unit: "Hz",digits: 0)
                } else {
                    RadioRotaryParameter(name: "键控平滑",value: $parameters.cw.riseMilliseconds,range: 1...20,initial: 5,unit: "ms")
                }
            case .pm:
                RadioRotaryParameter(name: "峰值相偏",value: $parameters.pm.phaseDeviationRadians,range: 0.1...4,initial: 1,step: 0.01,unit: "rad",digits: 2)
                RadioRotaryParameter(name: "音频带宽",value: $parameters.pm.audioBandwidthHz,range: 2000...15000,initial: 10000,scale: 1000,unit: "kHz")
            }
        }
    }
}

