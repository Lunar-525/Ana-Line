import SwiftUI

struct TVPreparationBar: View {
    @ObservedObject var model: PreviewModel
    private var label: String {
        model.tvPreparationStage == .audio ? L("Preparing PCM audio…") : L("Preparing video with FFmpeg…")
    }
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(.system(size: 12,weight: .medium))
            if let progress = model.tvPreparationProgress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.14))
                        Rectangle().fill(EditingTool.tv.logoAccentColor)
                            .frame(width: geometry.size.width*min(1,max(0,progress)))
                    }
                }.frame(height: 4)
                Text(String(format: "%.0f%%",progress*100)).font(.system(size: 12,design: .monospaced))
                    .frame(width: 40,alignment: .trailing)
            } else {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(.black).padding(.horizontal,16).frame(height: 44)
        .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.25),radius: 5,y: 3))
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue(model.tvPreparationProgress.map { String(format: "%.0f%%",$0*100) } ?? L("Inspecting media…"))
    }
}
