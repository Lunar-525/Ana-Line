import SwiftUI

enum TapeTransport: String {
    case stopped, playing, paused, rewinding, fastForwarding
    var isWinding: Bool { self == .rewinding || self == .fastForwarding }
}

/// Peak-reading display, not a VU meter: 10 ms attack, 550 ms release,
/// 900 ms peak hold followed by 14 dB/s fall. 0 dB = nominal tape reference.
struct TapeMeterState {
    var left = -60.0, right = -60.0
    var holdLeft = -60.0, holdRight = -60.0
    private var leftTime=0.0, rightTime=0.0
    mutating func advance(left: Double,right: Double,seconds: Double) {
        let dt=min(max(seconds,0),0.25)
        func update(_ input: Double,_ level: inout Double,_ hold: inout Double,_ time: inout Double) {
            let target=min(12,max(-60,20*log10(max(input.isFinite ? input : 0,1e-9))+18))
            let tau=target>level ? 0.01 : 0.55
            level += (target-level)*(1-exp(-dt/tau))
            if level>=hold { hold=level; time=0.9 }
            else if time>0 { time=max(0,time-dt) }
            else { hold=max(level,hold-14*dt) }
        }
        update(left,&self.left,&holdLeft,&leftTime)
        update(right,&self.right,&holdRight,&rightTime)
    }
}

struct TapePeakMeter: View {
    let meters: TapeMeterState
    private let thresholds: [Double] = [-40,-35,-30,-27,-24,-22,-20,-18,-16,-14,-12,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1,-0.5,0,0.5,1,1.5,2,2.5,3,3.5,4,4.5,5,5.5,6,6.5,7,7.5,8]
    var body: some View {
        Canvas { context,size in
            let left: CGFloat=40, right: CGFloat=24
            let width=size.width-left-right
            let step=width/CGFloat(thresholds.count), h: CGFloat=7
            for (row,level,hold) in [(0,meters.left,meters.holdLeft),(1,meters.right,meters.holdRight)] {
                let y: CGFloat=row==0 ? 32 : 78
                context.draw(Text(row==0 ? "LEFT" : "RIGHT").font(.system(size: 7,weight: .medium)).foregroundColor(.white.opacity(0.8)),at: CGPoint(x: 19,y: y+h/2))
                for (i,threshold) in thresholds.enumerated() {
                    let color: Color=threshold>=3 ? .red : threshold>=0 ? .yellow : Color(red: 0.55,green: 0.9,blue: 0.25)
                    let rect=CGRect(x: left+CGFloat(i)*step,y: y,width: max(1,step-2),height: h)
                    context.fill(Path(roundedRect: rect,cornerRadius: 1),with: .color(color.opacity(level>=threshold ? 1 : 0.10)))
                    if hold>=threshold && (i==thresholds.count-1 || hold<thresholds[i+1]) {
                        context.stroke(Path(rect),with: .color(color.opacity(0.9)),lineWidth: 1)
                    }
                    let tickY=y+(row==0 ? -8 : 16)
                    var tick=Path(); tick.move(to: CGPoint(x: rect.midX,y: tickY)); tick.addLine(to: CGPoint(x: rect.midX,y: tickY+(row==0 ? -4 : 4)))
                    context.stroke(tick,with: .color(.white.opacity(0.35)),lineWidth: 0.5)
                    if [-40.0,-30,-20,-10,-6,-3,0,3,6,8].contains(threshold) {
                        context.draw(Text(threshold>0 ? "+\(Int(threshold))" : "\(Int(threshold))").font(.system(size: 6,design: .monospaced)).foregroundColor(.white.opacity(0.7)),at: CGPoint(x: rect.midX,y: tickY+(row==0 ? -9 : 10)))
                    }
                }
            }
            context.draw(Text("PEAK dB").font(.system(size: 6)).foregroundColor(.white.opacity(0.5)),at: CGPoint(x: size.width-20,y: 58))
            context.draw(Text("0 dB = TAPE REFERENCE LEVEL").font(.system(size: 6,design: .monospaced)).foregroundColor(.white.opacity(0.42)),at: CGPoint(x: size.width/2,y: 119))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Stereo peak meter"))
        .accessibilityValue(String(format: "L %.1f dB, R %.1f dB",meters.left,meters.right))
    }
}

struct TapeTimeCounter: View {
    let seconds: Double
    var body: some View {
        let value=abs(Int(seconds))
        let text=(seconds < -0.5 ? "−" : "")+String(format: "%02d:%02d",value/60,value%60)
        HStack(spacing: 3) {
            ForEach(Array(text.enumerated()),id: \.offset) { _,character in
                if character == "−" {
                    Rectangle().fill(.mint.opacity(0.8)).frame(width: 8,height: 2)
                } else if character == ":" {
                    VStack(spacing: 10) { Circle(); Circle() }.foregroundStyle(.mint.opacity(0.8)).frame(width: 3,height: 19)
                } else {
                    SevenSegmentDigit(value: Int(String(character)) ?? 0).frame(width: 17,height: 31)
                }
            }
        }
        .padding(.horizontal,9).padding(.vertical,7)
        .background(.black.opacity(0.7),in: RoundedRectangle(cornerRadius: 2))
        .accessibilityLabel(L("Time counter"))
        .accessibilityValue(text)
    }
}

private struct SevenSegmentDigit: View {
    let value: Int
    private let masks: [Int] = [0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f]
    var body: some View {
        Canvas { context,size in
            let segments: [CGRect] = [CGRect(x: 3,y: 0,width: 11,height: 2),CGRect(x: 15,y: 3,width: 2,height: 11),CGRect(x: 15,y: 17,width: 2,height: 11),CGRect(x: 3,y: 29,width: 11,height: 2),CGRect(x: 0,y: 17,width: 2,height: 11),CGRect(x: 0,y: 3,width: 2,height: 11),CGRect(x: 3,y: 14.5,width: 11,height: 2)]
            for (i,rect) in segments.enumerated() {
                let scaled=rect.applying(CGAffineTransform(scaleX: size.width/17,y: size.height/31))
                context.fill(Path(roundedRect: scaled,cornerRadius: 1),with: .color(Color(red: 0.48,green: 0.92,blue: 0.77).opacity(masks[min(max(value,0),9)] & (1<<i) != 0 ? 0.95 : 0.07)))
            }
        }
    }
}

/// Two independent record faders. The engraved scale is a control position,
/// with 5 corresponding to nominal 0 dB; it is not a measured FF8 taper.
struct TapeRecordFader: View {
    @Binding var db: Double
    let channel: String
    private var position: Double { db<=0 ? (db+24)/24*5 : 5+db/18*5 }
    private func set(_ position: Double) {
        let p=min(max(position,0),10)
        db=p<=5 ? (p/5*24-24) : (p-5)/5*18
    }
    var body: some View {
        HStack(spacing: 7) {
            Text(channel).font(.system(size: 8,weight: .bold)).frame(width: 10)
            GeometryReader { geometry in
                let available=max(1,geometry.size.width-42)
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.8)).frame(height: 3).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.8)).frame(height: 1) }
                    RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.90,green: 0.88,blue: 0.85))
                        .frame(width: 42,height: 16)
                        .overlay { Rectangle().fill(.black.opacity(0.7)).frame(width: 2,height: 12) }
                        .offset(x: CGFloat(position/10)*available)
                }.frame(height: 20).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { set(Double(($0.location.x-21)/available)*10) })
            }.frame(height: 20)
        }.foregroundStyle(.black)
        .accessibilityElement(children: .ignore).accessibilityLabel(L("Record level")+" "+channel)
        .accessibilityValue(String(format: "%+.1f dB",db))
        .accessibilityAdjustableAction { direction in
            db=min(max(db+(direction == .increment ? 0.5 : -0.5),-24),18)
        }
    }
}
