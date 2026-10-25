import SwiftUI
import AnalogCore

/// Native, scalable front panel inspired by the user's AIWA FF8 reference.
/// Controls are actual transport/input controls; no photograph is used as a skin.
@MainActor
struct TapeView: View {
    @ObservedObject var model: TapeModel
    private let accent=EditingTool.tape.logoAccentColor
    @State private var scrub=0.0
    @State private var scrubbing=false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("STEREO CASSETTE DECK").font(.system(size: 12,weight: .medium,design: .monospaced)).tracking(3)
                    Spacer()
                    Text("AIWA FF8 / SONY CHF60").font(.system(size: 11,design: .monospaced)).foregroundStyle(accent)
                }.foregroundStyle(.secondary).padding(.top,22)
                GeometryReader { geometry in
                    frontPanel
                        .frame(width: 1440,height: 368)
                        .scaleEffect(geometry.size.width/1440,anchor: .topLeading)
                }.aspectRatio(1440.0/368,contentMode: .fit)
                HStack(spacing: 12) {
                    Image(systemName: "waveform").foregroundStyle(accent)
                    Text(model.fileName.isEmpty ? L("REC opens an audio file") : model.fileName)
                        .lineLimit(1).textSelection(.enabled)
                    Spacer()
                    Text(model.transport.rawValue.uppercased()).foregroundStyle(accent).font(.caption.monospaced())
                }.font(.system(size: 13)).padding(.horizontal,6)
                HStack(spacing: 14) {
                    Text(clock(model.position)).monospacedDigit().frame(width: 65)
                    Slider(value: Binding(get: { scrubbing ? scrub : model.position },set: { scrub=$0 }),
                           in: 0...max(1,model.duration),onEditingChanged: { editing in
                        if editing { scrub=model.position; scrubbing=true }
                        else { scrubbing=false; model.seek(to: scrub) }
                    }).disabled(model.fileName.isEmpty)
                        .accessibilityLabel(L("Tape position"))
                    Text(clock(model.duration)).monospacedDigit().frame(width: 65)
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Text(L("REW / FFWD: 20× · STOP keeps position · REC opens audio"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack {
                        Text(L("Output level")).font(.caption)
                        Slider(value: $model.settings.outputDB,in: -36...6).frame(width: 110)
                        Text(String(format: "%+.1f dB",model.settings.outputDB)).font(.caption.monospaced()).frame(width: 70)
                    }.foregroundStyle(.secondary)
                }
                healthControls
                Text("\(model.settings.formulation.name) approximation · \(model.settings.formulation.sourceNote). Audible differences only; not a verified replica of a specific sample.")
                    .font(.caption2).foregroundStyle(.secondary)
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(.horizontal,8).padding(.bottom,20)
        }.tint(accent).onDisappear { model.pause() }
    }
    private var healthControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            healthSlider("Head health", value: $model.settings.headHealth)
            healthSlider("Tape health", value: $model.settings.tapeHealth)
            Text(L("Lower head health reduces treble and level; lower tape health adds dullness, hiss and level fluctuations."))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func healthSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(L(title)).font(.caption).frame(width: 100, alignment: .leading)
            Slider(value: value, in: 0...1).accessibilityLabel(L(title))
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.caption.monospacedDigit()).frame(width: 45, alignment: .trailing)
        }
    }
    private func clock(_ time: Double) -> String {
        String(format: "%02d:%02d",max(0,Int(time))/60,max(0,Int(time))%60)
    }
    private var frontPanel: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(silver).frame(width: 1440,height: 275)
            brushedMetal.frame(width: 1440,height: 275)
            brand.offset(x: 24,y: 38)
            cassetteBay.frame(width: 345,height: 202).offset(x: 150,y: 40)
            // Smoked glass instrument / transport area.
            Rectangle().fill(Color(red: 0.11,green: 0.10,blue: 0.07))
                .overlay { instrumentMesh }
                .overlay { Rectangle().stroke(.white.opacity(0.3),lineWidth: 1) }
                .frame(width: 916,height: 272).offset(x: 514,y: 2)
            transportPanel.offset(x: 535,y: 30)
            counterPanel.offset(x: 772,y: 164)
            monitorPanel.offset(x: 772,y: 36)
            TapePeakMeter(meters: model.meters).frame(width: 440,height: 130).offset(x: 970,y: 27)
            circuitLegend.offset(x: 990,y: 176)
            Text("Craftsmanship").font(.custom("Snell Roundhand",size: 22)).foregroundStyle(.white.opacity(0.75)).offset(x: 532,y: 234)
            // Lower aluminum rail.
            Rectangle().fill(silver).frame(width: 1440,height: 84).offset(y: 280)
            brushedMetal.frame(width: 1440,height: 84).offset(y: 280)
            Rectangle().fill(.black.opacity(0.8)).frame(width: 1440,height: 5).offset(y: 275)
            Rectangle().fill(.white.opacity(0.8)).frame(width: 1440,height: 1).offset(y: 281)
            lowerControls.offset(x: 24,y: 292)
            recordPanel.frame(width: 410,height: 66).offset(x: 966,y: 291)
            headphoneJack.offset(x: 1387,y: 311)
            Rectangle().fill(.black.opacity(0.6)).frame(width: 1440,height: 3).offset(y: 364)
        }.frame(width: 1440,height: 368)
    }
    private var silver: Color { Color(red: 0.90,green: 0.88,blue: 0.85) }
    private var instrumentMesh: some View {
        Canvas { context,size in
            let step: CGFloat = 16
            var grid = Path()
            var x: CGFloat = 0
            while x <= size.width { grid.move(to: CGPoint(x: x,y: 0)); grid.addLine(to: CGPoint(x: x,y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { grid.move(to: CGPoint(x: 0,y: y)); grid.addLine(to: CGPoint(x: size.width,y: y)); y += step }
            context.stroke(grid,with: .color(Color(white: 0.55).opacity(0.12)),lineWidth: 0.5)
        }.allowsHitTesting(false)
    }
    private var brushedMetal: some View {
        Canvas { context,size in
            for y in stride(from: 0.0,to: size.height,by: 2) {
                var line=Path(); line.move(to: CGPoint(x: 0,y: y)); line.addLine(to: CGPoint(x: size.width,y: y))
                context.stroke(line,with: .color(.black.opacity(Int(y)%6==0 ? 0.035 : 0.012)),lineWidth: 0.5)
            }
        }.allowsHitTesting(false)
    }
    private var brand: some View {
        VStack(alignment: .leading,spacing: 1) {
            Text("AIWA").font(.system(size: 23,weight: .black)).italic()
            Text("STEREO\nCASSETTE DECK\nFF 8").font(.system(size: 12,weight: .bold)).lineSpacing(2)
        }.foregroundStyle(Color(white: 0.08))
    }
    private var cassetteBay: some View {
        ZStack {
            Rectangle().fill(.black).overlay { Rectangle().stroke(Color(white: 0.35),lineWidth: 3) }
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("SONY").font(.system(size: 25,weight: .black))
                    Spacer(); Text(model.settings.formulation.name.replacingOccurrences(of: "SONY ", with: "").replacingOccurrences(of: "TDK ", with: ""))
                        .font(.system(size: 23,weight: .black,design: .monospaced))
                }.foregroundStyle(.black).padding(.horizontal,16).frame(height: 43).background(Color(white: 0.72))
                HStack(spacing: 80) {
                    reel(clockwise: true)
                    reel(clockwise: false)
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
                HStack { Text("NORMAL BIAS"); Spacer(); Text("60 MINUTES") }
                    .font(.system(size: 9,weight: .bold,design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal,14).padding(.vertical,9)
            }.padding(12)
            Rectangle().stroke(.white.opacity(0.12),lineWidth: 1).padding(5).allowsHitTesting(false)
        }
    }
    private func reel(clockwise: Bool) -> some View {
        let angle=model.position*(clockwise ? 45 : 38)
        return ZStack {
            Circle().fill(Color(white: 0.08)).frame(width: 75,height: 75)
            Circle().stroke(Color(white: 0.22),lineWidth: 9).frame(width: clockwise ? 62 : 54)
            Image(systemName: "gearshape.fill").font(.system(size: 38)).foregroundStyle(Color(white: 0.5))
                .rotationEffect(.degrees(angle))
            Circle().fill(.black).frame(width: 10,height: 10)
        }.frame(width: 78,height: 78)
    }
    private var transportPanel: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Text("COMPU BRAIN").font(.system(size: 8,weight: .bold)).foregroundStyle(.black).padding(.horizontal,7).background(.white.opacity(0.8))
                Spacer(); Text("START / RESET").font(.system(size: 6,weight: .bold)).foregroundStyle(.white.opacity(0.55))
            }.padding(.bottom,7)
            HStack(spacing: 7) {
                key("REW",symbol: "backward.fill",active: model.transport == .rewinding,color: .white) { model.wind(.rewinding) }
                key("PLAY",symbol: "play.fill",active: model.playing,color: .green) { model.play() }
                key("FFWD",symbol: "forward.fill",active: model.transport == .fastForwarding,color: .white) { model.wind(.fastForwarding) }
            }
            HStack(spacing: 7) {
                key("REC",symbol: "circle.fill",active: false,color: .red,needsFile: false) { model.choose() }
                key("STOP",symbol: "stop.fill",active: model.transport == .stopped && !model.fileName.isEmpty,color: .white) { model.stop(reset: false) }
                key("PAUSE",symbol: "pause.fill",active: model.transport == .paused,color: .yellow) { model.togglePause() }
            }
            HStack {
                Text("REVIEW ◀  /  CUE ▶").font(.system(size: 7,weight: .medium)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                key("MUTE",symbol: "circle.fill",active: model.muted,color: .red,needsFile: false) { model.muted.toggle() }
            }
        }.frame(width: 212)
    }
    private func key(_ label: String,symbol: String,active: Bool,color: Color,needsFile: Bool=true,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: label=="MUTE" ? 9 : 12,weight: .bold))
                    .foregroundStyle(color.opacity(active || label=="REC" ? 1 : 0.45))
                Text(label).font(.system(size: 11,weight: .bold)).foregroundStyle(label=="REC" ? Color.red.opacity(0.8) : Color(white: 0.8))
            }.frame(width: 66,height: 47)
                .background(active ? Color(white: 0.08) : Color(white: 0.15))
                .overlay { RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(active ? 0.08 : 0.17),lineWidth: 0.7) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(needsFile && model.fileName.isEmpty)
            .accessibilityLabel(label=="REC" ? L("REC opens an audio file") : label)
            .accessibilityAddTraits(active ? .isSelected : [])
            .help(label=="REC" ? L("Choose Audio…") : label)
    }
    private var counterPanel: some View {
        VStack(alignment: .leading,spacing: 5) {
            TapeTimeCounter(seconds: model.counterSeconds)
            Text("TIME COUNTER / TAPE TIME").font(.system(size: 7,weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Button { model.resetCounter() } label: {
                Text("RESET").font(.system(size: 7,weight: .bold)).foregroundStyle(.black)
                    .frame(width: 48,height: 10).background(silver)
            }.buttonStyle(.plain).accessibilityLabel(L("Reset time counter"))
        }
    }
    private var monitorPanel: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("MONITOR").font(.system(size: 8)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 16) {
                indicator("TAPE",on: !model.settings.bypass,color: .yellow)
                indicator("SOURCE",on: model.settings.bypass,color: .yellow)
            }
            Text("COMPU / ERASE SYSTEM").font(.system(size: 7)).foregroundStyle(.white.opacity(0.4))
            indicator(model.playing ? "PLAY" : model.transport.isWinding ? "WIND" : "READY",on: !model.fileName.isEmpty,color: .green)
        }
    }
    private func indicator(_ label: String,on: Bool,color: Color) -> some View {
        Text(label).font(.system(size: 8,weight: .bold,design: .monospaced))
            .foregroundStyle(on ? .black : color.opacity(0.25)).padding(.horizontal,5).padding(.vertical,2)
            .background(on ? color.opacity(0.8) : Color(white: 0.07))
    }
    private var circuitLegend: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 50) { Text("STEREO"); Text("NORMAL BIAS"); Text("TAPE MONITOR") }
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.65))
            Path { p in
                p.move(to: CGPoint(x: 0,y: 10)); p.addLine(to: CGPoint(x: 0,y: 0)); p.addLine(to: CGPoint(x: 105,y: 0)); p.addLine(to: CGPoint(x: 105,y: 16)); p.addLine(to: CGPoint(x: 280,y: 16)); p.addLine(to: CGPoint(x: 280,y: 0)); p.addLine(to: CGPoint(x: 380,y: 0))
            }.stroke(.white.opacity(0.25),lineWidth: 0.8).frame(width: 380,height: 17)
            HStack(spacing: 45) {
                indicator("CHF",on: !model.fileName.isEmpty,color: .red)
                indicator("60",on: !model.fileName.isEmpty,color: .red)
                Text("FF 8").font(.system(size: 13,weight: .bold)).foregroundStyle(.white.opacity(0.25))
            }
        }
    }
    private var lowerControls: some View {
        HStack(alignment: .top,spacing: 22) {
            VStack(alignment: .leading,spacing: 15) {
                Text("POWER\nPUSH ON/OFF").font(.system(size: 8,weight: .bold))
                RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.55,green: 0.15,blue: 0.08)).frame(width: 60,height: 12)
            }
            VStack(spacing: 17) {
                Text("▲ EJECT").font(.system(size: 9,weight: .bold))
                Button { model.choose() } label: { Rectangle().fill(silver).frame(width: 60,height: 12).border(.black.opacity(0.4)) }.buttonStyle(.plain).accessibilityLabel(L("Choose Audio…"))
            }
            VStack(alignment: .leading,spacing: 6) {
                Text("STEREO CASSETTE DECK").font(.system(size: 9,weight: .bold))
                Text("\(model.settings.formulation.name.uppercased()) · NORMAL POSITION").font(.system(size: 8,weight: .medium))
            }.frame(width: 210).padding(.top,28)
            metalToggle("TAPE HISS",active: model.settings.hiss) { model.settings.hiss.toggle() }
            metalToggle("SOURCE / TAPE",active: model.settings.bypass) { model.settings.bypass.toggle() }
            metalToggle("LINK L / R",active: model.linkedInput) { model.linkedInput.toggle() }
            VStack(alignment: .leading,spacing: 12) {
                Text("TAPE SELECTOR").font(.system(size: 8,weight: .medium))
                Menu {
                    ForEach(TapeFormulations.all) { f in
                        Button {
                            model.settings.formulation = f
                        } label: {
                            if model.settings.formulation.id == f.id {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.settings.formulation.name.uppercased())
                            .font(.system(size: 8,weight: .bold,design: .monospaced))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 6,weight: .bold))
                    }
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal,7).padding(.vertical,4)
                    .frame(minWidth: 118)
                    .background(silver)
                    .overlay(alignment: .top) { Rectangle().fill(accent).frame(height: 3) }
                    .overlay { Rectangle().stroke(.black.opacity(0.6),lineWidth: 1) }
                }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L("Tape selector"))
                Text("\(TapeFormulations.all.count) FORMULATIONS").font(.system(size: 6,weight: .medium,design: .monospaced))
                    .foregroundStyle(.black.opacity(0.45))
            }
        }.foregroundStyle(.black.opacity(0.85))
    }
    private func metalToggle(_ label: String,active: Bool,action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(label).font(.system(size: 8,weight: .bold))
            Button(action: action) {
                RoundedRectangle(cornerRadius: 1).fill(silver).frame(width: 65,height: 16)
                    .overlay(alignment: .top) { Rectangle().fill(active ? accent : .black.opacity(0.65)).frame(height: 3) }
                    .overlay { Rectangle().stroke(.black.opacity(0.6),lineWidth: 1) }
            }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
        }
    }
    private var recordPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INPUT / RECORD LEVEL").font(.system(size: 8,weight: .bold))
                Spacer()
                Text(String(format: "L %+.1f   R %+.1f dB",model.recordLevel(0),model.recordLevel(1))).font(.system(size: 7,design: .monospaced))
            }.padding(.bottom,3)
            HStack(spacing: 0) {
                ForEach(0...10,id: \.self) { n in Text("\(n)").frame(maxWidth: .infinity) }
            }.font(.system(size: 7)).padding(.leading,19).padding(.trailing,9)
            TapeRecordFader(db: Binding(get: { model.recordLevel(0) },set: { model.setRecordLevel($0,channel: 0) }),channel: "L")
            TapeRecordFader(db: Binding(get: { model.recordLevel(1) },set: { model.setRecordLevel($0,channel: 1) }),channel: "R")
        }.foregroundStyle(.black)
    }
    private var headphoneJack: some View {
        VStack(spacing: 4) {
            Text("PHONES").font(.system(size: 7,weight: .bold)).foregroundStyle(.black)
            ZStack {
                Circle().fill(Color(white: 0.35)).frame(width: 34,height: 34)
                Circle().stroke(.white.opacity(0.8),lineWidth: 2).frame(width: 28,height: 28)
                Circle().fill(.black).frame(width: 22,height: 22)
                Circle().stroke(Color(white: 0.2),lineWidth: 2).frame(width: 17,height: 17)
            }
        }
    }
}
