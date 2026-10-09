import Foundation
import CoreGraphics
import ImageIO
import AnalogCore

public actor SSTVRenderer {
    private var sourceData: Data?
    private var mode: SSTVMode = .robot36
    private var frame: SSTVFrame?
    private var original: CGImage?
    private var tx: SSTVTransmission?
    private var receiver: SSTVReceiver?
    private var micMixer = SSTVMicrophoneMixer()
    private var session = 0
    public init() {}
    public struct Preview: @unchecked Sendable {
        public let original: CGImage
        public let image: CGImage
        public let txSeconds: Double
        public let rxSeconds: Double
        public let txCached: Bool
    }
    public func loadSource(_ data: Data) throws {
        sourceData = data
        try prepareSource(mode: mode)
    }
    private func prepareSource(mode: SSTVMode) throws {
        guard let data = sourceData else { throw CocoaError(.fileReadUnknown) }
        let w = mode.width, h = mode.height
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil),
              let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileReadCorruptFile) }
        // Opaque letterbox; no crop, alpha is composited on black for transmission.
        context.setFillColor(CGColor(gray: 0,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: w,height: h))
        let scale = min(Double(w)/Double(image.width),Double(h)/Double(image.height))
        let width = Double(image.width)*scale, height = Double(image.height)*scale
        context.interpolationQuality = .high
        context.draw(image,in: CGRect(x: (Double(w)-width)/2,y: (Double(h)-height)/2,width: width,height: height))
        guard let original = context.makeImage(), let pointer = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CocoaError(.coderInvalidValue)
        }
        var rgb = [SIMD3<Float>](); rgb.reserveCapacity(w*h)
        for i in 0..<w*h { rgb.append(SIMD3(Float(pointer[i*4])/255,Float(pointer[i*4+1])/255,Float(pointer[i*4+2])/255)) }
        self.original = original; self.mode = mode; frame = SSTVFrame(rgb: rgb,mode: mode); tx = nil; receiver = nil; session += 1
    }
    private func image(_ frame: SSTVFrame) throws -> CGImage {
        let w = frame.mode.width, h = frame.mode.height
        var bytes = [UInt8](); bytes.reserveCapacity(w*h*4)
        for p in frame.rgb { bytes.append(contentsOf: [UInt8(min(255,max(0,(p.x*255).rounded()))),UInt8(min(255,max(0,(p.y*255).rounded()))),UInt8(min(255,max(0,(p.z*255).rounded()))),255]) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        return image
    }
    public func render(_ settings: SSTVSettings) throws -> Preview {
        if frame?.mode != settings.mode { try prepareSource(mode: settings.mode) }
        guard let frame, let original else { throw CocoaError(.fileReadUnknown) }
        if settings.validated.mix == 0 {
            return Preview(original: original,image: original,txSeconds: 0,rxSeconds: 0,txCached: tx != nil)
        }
        let cached = tx != nil, start = Date()
        if tx == nil { tx = try SSTVEngine.encode(frame) }
        let txSeconds = Date().timeIntervalSince(start), rxStart = Date()
        let result = try SSTVEngine.receive(tx!,settings: settings)
        try Task.checkCancellation()
        let output = try image(result)
        return Preview(original: original,image: output,txSeconds: txSeconds,rxSeconds: Date().timeIntervalSince(rxStart),txCached: cached)
    }
    public struct LivePreview: @unchecked Sendable {
        public let image: CGImage
        public let progress: Double
        public let rows: Int
        public let complete: Bool
        public let audio: [Float]
        public let channel: SSTVChannelState
    }
    public func beginTransmission(mode: SSTVMode = .robot36) throws -> Int {
        if frame?.mode != mode { try prepareSource(mode: mode) }
        guard let frame else { throw CocoaError(.fileReadUnknown) }
        if tx == nil { tx = try SSTVEngine.encode(frame) }
        session += 1; receiver = SSTVReceiver(transmission: tx!); micMixer = SSTVMicrophoneMixer()
        return session
    }
    public func advanceTransmission(session token: Int,to seconds: Double,settings: SSTVSettings,
                                    microphone: [Float],micGain: Float,monitor: Bool) throws -> LivePreview {
        guard token == session, var receiver else { throw CancellationError() }
        let start = receiver.cursor
        let samples = micMixer.convert(microphone)
        try receiver.advance(to: Int(max(0,min(receiver.transmission.duration,seconds))*12000+0.5),settings: settings,microphone: samples,micGain: micGain)
        let frame = receiver.snapshot(settings: settings)
        let audio = monitor ? receiver.txAudio(in: start..<receiver.cursor) : []
        self.receiver = receiver
        return LivePreview(image: try image(frame),progress: receiver.progress,rows: receiver.receivedRows,complete: receiver.complete,audio: audio,
            channel: SSTVChannelState.at(sample: max(0,receiver.cursor-1),total: receiver.transmission.samples.count,settings: settings))
    }
    public func endTransmission() { session += 1; receiver = nil }
}
