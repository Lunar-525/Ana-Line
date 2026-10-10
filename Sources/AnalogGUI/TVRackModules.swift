import SwiftUI
import AnalogCore

struct TVEncoderRack: View {
    @ObservedObject var state: TVControlState
    @State private var service = false
    private var on: Bool { state.tvChannel.transmitter.encoder.enabled }
    var body: some View {
        VStack(spacing: 3) {
            TVRackHeader(name: "ENCODER",subtitle: "ANA-LINE · COMPOSITE VIDEO",service: $service)
            HStack(spacing: 8) {
                TVRackSwitch(enabled: $state.tvChannel.transmitter.encoder.enabled,label: "Encoder aging")
                TVRotaryParameter(name: "Differential gain",value: $state.tvChannel.transmitter.encoder.differentialGain,
                    range: -1...1,initial: 0,step: 0.01,digits: 0,percent: true,active: on,horizontal: true)
                TVRotaryParameter(name: "Differential phase · °",value: $state.tvChannel.transmitter.encoder.differentialPhaseDegrees,
                    range: -90...90,initial: 0,step: 1,unit: "°",digits: 0,active: on,horizontal: true)
                TVRotaryParameter(name: "Burst drift · °",value: $state.tvChannel.transmitter.encoder.burstDriftDegrees,
                    range: 0...90,initial: 0,step: 1,unit: "°",digits: 0,active: on,horizontal: true)
            }
        }.padding(.horizontal,23).padding(.vertical,4).frame(height: 80)
            .background(TVRackHousing(finish: .encoder))
            .popover(isPresented: $service) {
                TVServicePanel(title: "Encoder calibration") {
                    HStack {
                        TVRotaryParameter(name: "Burst amplitude",value: $state.tvChannel.transmitter.encoder.burstAmplitude,
                            range: 0...2,initial: 1,step: 0.01,digits: 2,active: on)
                        TVRotaryParameter(name: "Burst phase · °",value: $state.tvChannel.transmitter.encoder.burstPhaseDegrees,
                            range: -180...180,initial: 0,step: 1,unit: "°",digits: 0,active: on)
                        TVRotaryParameter(name: "Burst drift · Hz",value: $state.tvChannel.transmitter.encoder.burstDriftHz,
                            range: 0...3,initial: 0.25,step: 0.01,unit: "Hz",digits: 2,active: on)
                    }
                }
            }
    }
}

struct TVFilterRack: View {
    @ObservedObject var state: TVControlState
    @State private var service = false
    private var on: Bool { state.tvChannel.transmitter.vsb.enabled }
    var body: some View {
        VStack(spacing: 4) {
            TVRackHeader(name: "VSB / GROUP DELAY",subtitle: "2U",gold: true,service: $service)
            HStack(spacing: 8) {
                TVRackSwitch(enabled: $state.tvChannel.transmitter.vsb.enabled,label: "Filter damage")
                TVRotaryParameter(name: "Filter transition · MHz",value: $state.tvChannel.transmitter.vsb.transitionMHz,
                    range: 0.03...1.5,initial: 0.2,step: 0.01,unit: "MHz",digits: 2,active: on,horizontal: true)
                TVRotaryParameter(name: "Excess group delay · ns",value: $state.tvChannel.transmitter.vsb.groupDelayNS,
                    range: -500...500,initial: 0,step: 5,unit: "ns",digits: 0,active: on,horizontal: true)
                TVRotaryParameter(name: "HF peaking · dB",value: $state.tvChannel.transmitter.vsb.peakingDB,
                    range: 0...12,initial: 0,step: 0.1,unit: "dB",active: on,horizontal: true)
            }
            Rectangle().fill(Color(red: 0.7,green: 0.55,blue: 0.27).opacity(0.35)).frame(height: 1)
        }.padding(.horizontal,23).padding(.vertical,5).frame(height: 84)
            .background(TVRackHousing(finish: .filter))
            .popover(isPresented: $service) {
                TVServicePanel(title: "VSB filter / group delay") {
                    Text(L("VSB service explanation")).font(.system(size: 11))
                    Button(L("Restore filter calibration")) {
                        let enabled = state.tvChannel.transmitter.vsb.enabled
                        state.tvChannel.transmitter.vsb = TVVSBFilterSettings()
                        state.tvChannel.transmitter.vsb.enabled = enabled
                    }.buttonStyle(.bordered)
                }
            }
    }
}

struct TVPowerAmplifierRack: View {
    @ObservedObject var state: TVControlState
    let instruments: TVTXInstrumentState
    @State private var service = false
    var body: some View {
        VStack(spacing: 0) {
            TVRackHeatsink()
            face
        }
            .popover(isPresented: $service) {
                servicePanel
            }
    }
    private var face: some View {
        VStack(spacing: 3) {
            TVRackHeader(name: "TRANSMITTER",subtitle: "3U · RF POWER AMPLIFIER",service: $service)
            TVTXMeters(state: instruments)
            HStack(spacing: 8) {
                TVRackSwitch(enabled: $state.tvChannel.transmitter.enabled,label: "PA nonlinearity")
                TVRotaryParameter(name: "Carrier · MHz",value: $state.tvChannel.propagation.frequencyMHz,
                    range: 50...860,initial: 600,step: 1,unit: "MHz",digits: 0)
                TVRotaryParameter(name: "TX power · dB",value: $state.tvChannel.transmitter.powerDB,
                    range: -60...12,initial: 0,step: 0.1,unit: "dB")
                    .help(L("Nominal transmit power relative to the 0 dB reference, before PA compression. Applies to vision and sound; meters show actual output."))
                TVRotaryParameter(name: "PA backoff · dB",value: $state.tvChannel.transmitter.backoffDB,
                    range: -6...24,initial: 6,step: 0.1,unit: "dB",active: state.tvChannel.transmitter.enabled)
                TVRotaryParameter(name: "Audio drive · dB",value: $state.tvChannel.transmitter.audioDriveDB,
                    range: 0...24,initial: 0,step: 0.1,unit: "dB")
            }
        }.padding(.horizontal,23).padding(.vertical,5).frame(height: 162)
            .background(TVRackHousing(finish: .transmitter))
    }
    private var servicePanel: some View {
                TVServicePanel(title: "Transmitter service") {
                    HStack {
                        TVRotaryParameter(name: "Compression hardness",value: $state.tvChannel.transmitter.hardness,
                            range: 0...1,initial: 0.5,step: 0.01,digits: 0,percent: true,active: state.tvChannel.transmitter.enabled)
                        TVRotaryParameter(name: "AM/PM shift · °",value: $state.tvChannel.transmitter.phaseDegrees,
                            range: -45...45,initial: 0,step: 1,unit: "°",digits: 0,active: state.tvChannel.transmitter.enabled)
                        TVRotaryParameter(name: "Carrier cross-compression",value: $state.tvChannel.transmitter.sharedCoupling,
                            range: 0...1,initial: 0,step: 0.01,digits: 0,percent: true,active: state.tvChannel.transmitter.enabled)
                    }
                    HStack {
                        TVRotaryParameter(name: "Load VSWR",value: $state.tvChannel.transmitter.loadVSWR,
                            range: 1...5,initial: 1,step: 0.05,unit: ":1",digits: 2).frame(width: 90)
                        Text(L("Power meters show relative RF power. Load VSWR controls the reflected fraction and delivered power."))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    }
                }
    }
}

private struct TVTXMeters: View {
    @ObservedObject var state: TVTXInstrumentState
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                warning("PA SATURATION",lit: state.reading?.saturated == true)
                warning("OVERMODULATION",lit: state.reading?.overmodulated == true)
            }
            HStack(spacing: 8) {
                TVPowerMeter(name: "PA POWER",value: state.reading.map { $0.forwardPower/$0.referencePower })
                TVPowerMeter(name: "REFLECTED",value: state.reading.map { $0.reflectedPower/$0.referencePower })
            }
        }.help(L("Power meters show relative RF power. Load VSWR controls the reflected fraction and delivered power."))
    }
    private func warning(_ text: String,lit: Bool) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    Circle().fill(lit ? Color.red : Color(red: 0.22,green: 0.03,blue: 0.03)).frame(width: 4,height: 4)
                        .shadow(color: .red.opacity(lit ? 0.7 : 0),radius: 2)
                }
            }
            Text(text).font(.system(size: 6.5,weight: .bold,design: .monospaced)).lineLimit(1)
                .foregroundStyle(lit ? .red : .white.opacity(0.5))
        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
            .accessibilityLabel(text).accessibilityValue(lit ? L("Warning") : L("Normal"))
    }
}

struct TVPowerMeter: View {
    let name: String
    let value: Float?
    var body: some View {
        VStack(spacing: 2) {
            Canvas { context,size in
                let face = CGRect(origin: .zero,size: size).insetBy(dx: 2,dy: 2)
                context.fill(Path(face),with: .linearGradient(Gradient(colors: value == nil ?
                    [Color(red: 0.31,green: 0.27,blue: 0.15),Color(red: 0.44,green: 0.36,blue: 0.17)] :
                    [Color(red: 1,green: 0.9,blue: 0.47),Color(red: 0.78,green: 0.6,blue: 0.2)]),
                    startPoint: .zero,endPoint: CGPoint(x: 0,y: size.height)))
                context.stroke(Path(face),with: .color(.black),lineWidth: 3)
                // A flattened scale with its pivot behind the lower bezel keeps
                // the labels apart in a shallow rack-mounted instrument.
                let centre = CGPoint(x: size.width/2,y: size.height+3)
                let rx = min(size.width*0.43,70), ry = max(10,size.height-7)
                for n in 0...20 {
                    let a = (210+Double(n)*6)*Double.pi/180
                    let inset: CGFloat = n%5 == 0 ? 4 : 2
                    var tick = Path(); tick.move(to: CGPoint(x: centre.x+cos(a)*rx,y: centre.y+sin(a)*ry))
                    tick.addLine(to: CGPoint(x: centre.x+cos(a)*(rx-inset),y: centre.y+sin(a)*(ry-inset)))
                    context.stroke(tick,with: .color(.black.opacity(0.8)),lineWidth: 0.6)
                    if n%5 == 0 {
                        context.draw(Text("\(n*5)").font(.system(size: 5.5,design: .monospaced)).foregroundColor(.black.opacity(0.8)),
                            at: CGPoint(x: centre.x+cos(a)*(rx-10),y: centre.y+sin(a)*(ry-10)))
                    }
                }
                context.draw(Text(name).font(.system(size: 6.5,weight: .bold,design: .monospaced)).foregroundColor(.black.opacity(0.7)),
                             at: CGPoint(x: centre.x,y: size.height-8))
                let angle = (210+120*Double(min(1,max(0,value ?? 0))))*Double.pi/180
                var needle = Path(); needle.move(to: centre)
                needle.addLine(to: CGPoint(x: centre.x+cos(angle)*(rx-5),y: centre.y+sin(angle)*(ry-5)))
                context.stroke(needle,with: .color(.black.opacity(value == nil ? 0.4 : 0.85)),lineWidth: 1.1)
                context.fill(Path(ellipseIn: CGRect(x: centre.x-2,y: centre.y-2,width: 4,height: 4)),with: .color(.black))
                // A narrow glass highlight, rather than a shiny overlay over labels.
                context.fill(Path(CGRect(x: 4,y: 4,width: size.width-8,height: 3)),with: .color(.white.opacity(0.25)))
            }.frame(height: 38).clipped()
            HStack(spacing: 4) {
                TVSevenSegmentDisplay(text: value.map { String(format: "%.1f",$0*100) } ?? "--",height: 10)
                Text("% REL").font(.system(size: 7,design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }.padding(.horizontal,4).padding(.vertical,2).background(Color(white: 0.035))
        }.accessibilityElement(children: .ignore).accessibilityLabel(name)
            .accessibilityValue(value.map { String(format: "%.1f%%",$0*100) } ?? L("No signal"))
    }
}
