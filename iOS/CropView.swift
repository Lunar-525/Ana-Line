import SwiftUI

/// Crop and rotation editor for an imported video.
///
/// iOS offers no public UI for cropping or rotating a video — the Photos app's own
/// editor is private, and `UIImagePickerController`/`UIVideoEditorController` only
/// trim duration — so the window is drawn here and the geometry is handed to
/// AVFoundation, which applies it in the reader's video composition without
/// re-encoding.
///
/// The window is always 4:3, because that is what the analogue frame is; the
/// editor only chooses *which* 4:3 part of the picture to show.
struct CropView: View {
    var preview: UIImage?
    @State private var crop: MobileCrop
    private let onDone: (MobileCrop?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var committed: MobileCrop

    init(preview: UIImage?, initial: MobileCrop, onDone: @escaping (MobileCrop?) -> Void) {
        self.preview = preview
        self._crop = State(initialValue: initial)
        self._committed = State(initialValue: initial)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                stage
                controls
                Text("取景框固定为 4:3，与模拟电视画面一致。框外部分会被裁掉，画面不重新编码。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("取景与旋转")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(crop); dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("自动（完整画面）") { onDone(nil); dismiss() }
                }
            }
        }
    }

    /// The picture with the 4:3 window over it. The image is turned here so the
    /// editor shows the same rectangle the transform will cut out.
    private var stage: some View {
        GeometryReader { geometry in
            let aspect = pictureAspect
            let box = CGRect(origin: .zero, size: geometry.size).fitted(aspect: aspect)
            ZStack {
                Color.black
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(width: crop.turns % 2 == 0 ? box.width : box.height,
                               height: crop.turns % 2 == 0 ? box.height : box.width)
                        .rotationEffect(.degrees(Double(crop.turns)*90))
                        .position(x: box.midX, y: box.midY)
                } else {
                    ProgressView().position(x: box.midX, y: box.midY)
                }
                windowOverlay(in: box)
            }
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func windowOverlay(in box: CGRect) -> some View {
        let scale = box.width/pictureSize.width   // picture units → view points
        let full = CGRect(origin: .zero, size: pictureSize)
        let window = crop.window(in: full)
        let rect = CGRect(x: box.minX + window.minX*scale, y: box.minY + window.minY*scale,
                          width: window.width*scale, height: window.height*scale)
        return ZStack {
            // Dim everything outside the window with four plain rectangles, which
            // avoids any blend-mode masking.
            Color.black.opacity(0.55).frame(width: box.width, height: max(0, rect.minY-box.minY))
                .position(x: box.midX, y: box.minY + max(0, rect.minY-box.minY)/2)
            Color.black.opacity(0.55).frame(width: box.width, height: max(0, box.maxY-rect.maxY))
                .position(x: box.midX, y: rect.maxY + max(0, box.maxY-rect.maxY)/2)
            Color.black.opacity(0.55).frame(width: max(0, rect.minX-box.minX), height: rect.height)
                .position(x: box.minX + max(0, rect.minX-box.minX)/2, y: rect.midY)
            Color.black.opacity(0.55).frame(width: max(0, box.maxX-rect.maxX), height: rect.height)
                .position(x: rect.maxX + max(0, box.maxX-rect.maxX)/2, y: rect.midY)
            Rectangle().stroke(.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(DragGesture()
                    .onChanged { value in
                        // Anchor on the gesture's start, not the running value: the
                        // translation is cumulative.
                        crop.center = CGPoint(x: committed.center.x + value.translation.width/box.width,
                                              y: committed.center.y + value.translation.height/box.height)
                        crop.center.x = min(1, max(0, crop.center.x))
                        crop.center.y = min(1, max(0, crop.center.y))
                    }
                    .onEnded { _ in committed = crop })
        }
        .gesture(MagnifyGesture()
            .onChanged { value in crop.zoom = min(1, max(0.15, committed.zoom/value.magnification)) }
            .onEnded { _ in committed = crop })
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button { crop.quarterTurns += 1; committed = crop } label: {
                    Label("旋转 90°", systemImage: "rotate.right")
                }
                Spacer()
                Button("复位") { crop = .full; committed = .full }
            }
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: Binding(get: { Double(crop.zoom) },
                                      set: { crop.zoom = CGFloat($0); committed = crop }),
                       in: 0.15...1)
                Image(systemName: "plus.magnifyingglass")
            }
            if let preview {
                Text("源画面 \(Int(pictureSize.width))×\(Int(pictureSize.height)) · 旋转 \(crop.turns*90)°")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The source picture in its own units, already upright; its aspect is what the
    /// stage fits into.
    private var pictureSize: CGSize {
        guard let preview else { return CGSize(width: 4, height: 3) }
        let size = preview.size
        return crop.turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
    private var pictureAspect: CGFloat {
        let size = pictureSize
        return size.height == 0 ? 4.0/3.0 : size.width/size.height
    }
}

private extension CGRect {
    /// The largest rectangle of `aspect` centred inside this rectangle.
    func fitted(aspect: CGFloat) -> CGRect {
        let width = min(self.width, self.height*aspect)
        let height = width/aspect
        return CGRect(x: midX - width/2, y: midY - height/2, width: width, height: height)
    }
}
