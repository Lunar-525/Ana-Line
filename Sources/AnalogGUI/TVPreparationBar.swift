import SwiftUI

struct TVPreparationBar: View {
    @ObservedObject var model: PreviewModel
    private var label: String {
        switch model.tvPreparationStage {
        case .inspecting: L("Checking video cache…")
        case .video: L("Preparing PAL + NTSC video…")
        case .audio: L("Preparing PCM audio…")
        case .caching: L("Finishing video preparation…")
        case .cached: L("Using cached video")
        }
    }
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(.system(size: 12,weight: .medium))
            TimelineView(.animation(minimumInterval: 1/30)) { timeline in
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let progress = model.tvPreparationProgress
                    let sweep = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3)/1.3
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.14))
                        Rectangle().fill(EditingTool.tv.logoAccentColor)
                            .frame(width: width*min(1,max(0,progress ?? 0)))
                            .animation(.linear(duration: 0.15),value: progress)
                        Rectangle().fill(LinearGradient(colors: [.clear,progress == nil ? EditingTool.tv.logoAccentColor : .white.opacity(0.85),.clear],startPoint: .leading,endPoint: .trailing))
                            .frame(width: max(24,width*0.18))
                            .offset(x: (width+width*0.18)*sweep-width*0.18)
                    }
                    .clipped()
                }
            }.frame(height: 5)
            if let progress = model.tvPreparationProgress {
                Text(String(format: "%.0f%%",progress*100)).font(.system(size: 12,design: .monospaced))
                    .frame(width: 40,alignment: .trailing)
            } else {
                Text("…").font(.system(size: 12,design: .monospaced)).frame(width: 40,alignment: .trailing)
            }
        }
        .foregroundStyle(.black).padding(.horizontal,16).frame(height: 44)
        .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.25),radius: 5,y: 3))
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue(model.tvPreparationProgress.map { String(format: "%.0f%%",$0*100) } ?? L("Inspecting media…"))
    }
}
