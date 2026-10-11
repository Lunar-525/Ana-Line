import Foundation
import Accelerate
import Dispatch

public enum TVExecution: String, Codable, Equatable, Sendable { case reference, accelerated }

/// Diagnostic bypass for A/B runs with identical rendering/reporting overhead.
/// Immutable for the process lifetime; normal apps keep the optimized path.
enum TVOptimizationDiagnostics {
    static let baseline = ProcessInfo.processInfo.arguments.contains("--benchmark-baseline")
}

/// Process-wide ceiling on every parallel DSP stage. Immutable for the process
/// lifetime and read from the launch arguments, so a device sweep needs one
/// build. The default is no ceiling, which leaves every existing worker count
/// exactly as it was; a diagnostic run caps it to test whether spreading work
/// over efficiency cores costs more than it buys on a given device.
enum TVParallelDiagnostics {
    static let workerLimit: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--benchmark-workers"), index+1 < arguments.count,
              let value = Int(arguments[index+1]), value > 0 else { return Int.max }
        return value
    }()
    /// Human-readable value for reports.
    static var workerLimitDescription: String {
        workerLimit == Int.max ? "unlimited" : String(workerLimit)
    }
}

/// Apply the diagnostic ceiling to a stage's own worker count.
@inline(__always) func cappedWorkers(_ requested: Int) -> Int {
    min(requested,TVParallelDiagnostics.workerLimit)
}

/// Each worker owns disjoint elements. The owning array keeps this buffer alive
/// until synchronous concurrentPerform returns; no pointer escapes that scope.
private struct TVOutput<Value>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Value>
    func store(_ value: Value, at index: Int) { buffer.baseAddress![index] = value }
}

/// CPU CVBS engine. No RGB-side damage or display overlays.
public enum TVEngine {
    private static func clamp(_ x: Float) -> Float { max(0, min(1, x)) }
    private static func carrier(_ sample: Int64) -> SIMD2<Float> {
        switch Int(sample & 3) {
        case 0: SIMD2(1,0)
        case 1: SIMD2(0,1)
        case 2: SIMD2(-1,0)
        default: SIMD2(0,-1)
        }
    }
    private static func components(_ rgb: SIMD3<Float>, _ standard: TVStandard) -> SIMD3<Float> {
        let r = clamp(rgb.x), g = clamp(rgb.y), b = clamp(rgb.z)
        let y = 0.299*r + 0.587*g + 0.114*b
        if standard == .pal { return SIMD3(y, 0.492*(b-y), 0.877*(r-y)) }
        return SIMD3(y, 0.596*r - 0.274*g - 0.322*b, 0.211*r - 0.523*g + 0.312*b)
    }
    /// Windowed-sinc FIR; odd length, DC-normalized, zero-phase offline filtering.
    private static func kernel(cutoff: Double, rate: Double, radius: Int = 16) -> [Float] {
        let fc = min(0.49, cutoff/rate)
        var k = (-radius...radius).map { i -> Float in
            let x = Double(i)
            let sinc = i == 0 ? 2*fc : sin(2 * .pi * fc*x) / (.pi*x)
            return Float(sinc * (0.54 + 0.46*cos(.pi*x/Double(radius))))
        }
        let sum = k.reduce(0,+); for i in k.indices { k[i] /= sum }; return k
    }
    private static func perform(count: Int, execution: TVExecution, body: @Sendable (Int) -> Void) {
        if execution == .reference || count < 32 {
            for n in 0..<count { body(n) }
        } else {
            let workers = cappedWorkers(min(8, ProcessInfo.processInfo.activeProcessorCount, (count+31)/32))
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let start = worker*count/workers, end = (worker+1)*count/workers
                for n in start..<end { body(n) }
            }
        }
    }
    private static func filter(_ values: [Float], _ k: [Float], execution: TVExecution = .accelerated) -> [Float] {
        guard !values.isEmpty else { return [] }
        let radius = k.count/2
        if execution == .reference {
            return values.indices.map { i in
                var v: Float = 0
                for j in k.indices { v += values[max(0,min(values.count-1,i+j-radius))] * k[j] }
                return v
            }
        }
        // Match the reference's clamped boundary samples, rather than zero padding.
        let padded = [Float](repeating: values[0],count: radius) + values + [Float](repeating: values[values.count-1],count: radius)
        var output = [Float](repeating: 0,count: values.count)
        padded.withUnsafeBufferPointer { x in
            k.withUnsafeBufferPointer { coefficients in
                output.withUnsafeMutableBufferPointer { y in
                    vDSP_conv(x.baseAddress!,1,coefficients.baseAddress!,1,y.baseAddress!,1,
                              vDSP_Length(values.count),vDSP_Length(k.count))
                }
            }
        }
        return output
    }
    public static func encode(_ frame: TVFrame, frameIndex: Int64 = 0, execution: TVExecution = .accelerated,
                              damage: TVEncoderDamageSettings = .init()) throws -> CompositeVideo {
        guard frameIndex >= 0, frameIndex < 1_000_000_000 else { throw TVError.invalidSignal }
        try damage.validate()
        let s = frame.standard, offset = s.sampleOffset(frame: frameIndex)
        let count = Int(s.sampleOffset(frame: frameIndex+1)-offset)
        var samples = [Float](repeating: 0, count: count)
        // Local continuous time → sample index; ceil avoids accumulating line-rounding error.
        @Sendable func index(_ time: Double) -> Int {
            Int(ceil((Double(frameIndex)*s.frameDuration+time)*s.sampleRate-Double(offset)-1e-6))
        }
        func fill(_ start: Double, _ duration: Double, _ value: Float) {
            let a = max(0,index(start)), b = min(count,index(start+duration))
            if a < b { for i in a..<b { samples[i] = value } }
        }
        // Equalizing, broad vertical, equalizing pulses, with a half-line field offset.
        for field in 0..<2 {
            let origin = Double(field)*s.frameDuration/2
            let n = s.equalizingCount
            for half in 0..<n*3 {
                let broad = half >= n && half < n*2
                fill(origin+Double(half)*s.lineDuration/2,
                     broad ? s.lineDuration/2-s.syncDuration : s.syncDuration/2, -0.3)
            }
            // Whole-line sync after VBI, aligned to each field's half-line origin.
            for line in Int(ceil(Double(n*3)/2))..<Int(ceil(Double(s.totalLines)/2)) {
                let t = origin+Double(line)*s.lineDuration
                fill(t,s.syncDuration,-0.3)
                let a = max(0,index(t+s.burstStart)), b = min(count,index(t+s.burstStart+s.burstDuration))
                let linePosition = Double(field) * Double(s.totalLines) / 2 + Double(line)
                let sign = s.palLineSign(linePosition, frameIndex: frameIndex)
                let burstPhase = damage.enabled ? Double(damage.burstPhaseDegrees)*Double.pi/180
                    + Double(damage.burstDriftDegrees)*Double.pi/180*sin(2*Double.pi*Double(damage.burstDriftHz)*(Double(frameIndex)*s.frameDuration+t)) : 0
                let bc = Float(cos(burstPhase)), bs = Float(sin(burstPhase))
                if a < b { for i in a..<b {
                    let c = carrier(offset+Int64(i))
                    let reference = s == .pal ? SIMD2<Float>(-0.15/sqrt(2),0.15*sign/sqrt(2)) : SIMD2(-0.15,0)
                    let burst = SIMD2(reference.x*bc-reference.y*bs,reference.x*bs+reference.y*bc)
                    samples[i] = damage.enabled ? (burst.x*c.x+burst.y*c.y)*damage.burstAmplitude
                        : s == .pal ? 0.15*(-c.x+sign*c.y)/sqrt(2) : -0.15*c.x
                } }
            }
        }
        let yKernel = kernel(cutoff: s == .pal ? 5e6 : 4.2e6, rate: s.sampleRate)
        let uKernel = kernel(cutoff: s == .pal ? 1.3e6 : 1.5e6, rate: s.sampleRate)
        let vKernel = kernel(cutoff: s == .pal ? 1.3e6 : 0.5e6, rate: s.sampleRate)
        let colorTable: [SIMD3<Float>] = damage.enabled ? (0...256).map { n in
            let y = Float(n)/256, phase = damage.differentialPhaseDegrees*Float.pi/180*y
            let gain = 1+damage.differentialGain*y
            return SIMD3(gain*cos(phase),gain*sin(phase),0)
        } : []
        samples.withUnsafeMutableBufferPointer { storage in
            let output = TVOutput(buffer: storage)
            perform(count: s.height, execution: execution) { row in
                let line = s.activeLine(row), t = line*s.lineDuration+s.activeStart
                let a = index(t), b = index(t+s.activeDuration), length = b-a
                var y = [Float](repeating: 0,count: length), u = y, v = y
                for x in 0..<length {
                    let position = (Double(x)+0.5)*Double(s.width)/Double(length)-0.5
                    let left = max(0,min(s.width-1,Int(floor(position)))), right = min(s.width-1,left+1)
                    let f = Float(max(0,position-Double(left)))
                    let p = components(frame.rgb[row*s.width+left]*(1-f)+frame.rgb[row*s.width+right]*f,s)
                    y[x] = p.x; u[x] = p.y; v[x] = p.z
                }
                y = filter(y,yKernel,execution: execution); u = filter(u,uKernel,execution: execution); v = filter(v,vKernel,execution: execution)
                let sign: Float = s == .pal ? s.palLineSign(line, frameIndex: frameIndex) : 1
                for x in 0..<length {
                    let c = carrier(offset+Int64(a+x))
                    var ca = u[x], cb = sign*v[x]
                    if damage.enabled {
                        let p = max(0,min(256,y[x]*256)), n = min(255,Int(p)), f = p-Float(n)
                        let t = colorTable[n]+(colorTable[n+1]-colorTable[n])*f
                        let next = ca*t.x-cb*t.y; cb = ca*t.y+cb*t.x; ca = next
                    }
                    output.store(0.7*(y[x]+ca*c.x+cb*c.y),at: a+x)
                }
            }
        }
        return try CompositeVideo(standard: s,frameIndex: frameIndex,samples: samples)
    }

    public static func channel(_ input: CompositeVideo, settings: TVChannelSettings) throws -> CompositeVideo {
        let s = settings
        guard [s.noise,s.gain,s.bandwidthMHz,s.ghostGain,s.ghostDelayMicroseconds].allSatisfy(\.isFinite),
              s.noise >= 0, s.noise <= 1, s.gain >= 0, s.gain <= 4,
              s.bandwidthMHz >= 0.1, s.bandwidthMHz <= 10,
              abs(s.ghostGain) <= 1, s.ghostDelayMicroseconds >= 0, s.ghostDelayMicroseconds <= 64 else {
            throw TVError.invalidSettings
        }
        var samples = input.samples
        let delay = Double(s.ghostDelayMicroseconds)*1e-6*input.standard.sampleRate
        var rng = s.seed ^ UInt64(input.frameIndex) &* 0x9e3779b97f4a7c15
        func random() -> Float {
            rng &+= 0x9e3779b97f4a7c15
            var z = rng; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return Float((z ^ (z >> 31)) >> 40)/Float(1<<24)
        }
        for i in samples.indices {
            var ghost: Float = 0
            let p = Double(i)-delay
            if s.ghostGain != 0, p >= 0 {
                let j = Int(p), f = Float(p-Double(j))
                ghost = input.samples[j]*(1-f)+input.samples[min(j+1,samples.count-1)]*f
            }
            // Box-Muller Gaussian noise. Deterministic per frame and seed.
            let noise = s.noise == 0 ? 0 : sqrt(-2*log(max(1e-7,random())))*cos(2 * .pi*random())*s.noise
            samples[i] = (samples[i]+s.ghostGain*ghost)*s.gain+noise
        }
        if s.bandwidthMHz < 6 {
            samples = filter(samples,kernel(cutoff: Double(s.bandwidthMHz)*1e6,rate: input.standard.sampleRate))
        }
        return try CompositeVideo(standard: input.standard,frameIndex: input.frameIndex,samples: samples)
    }

    public static func decode(_ input: CompositeVideo, settings: TVDecoderSettings = .init(), timing: TVSyncTiming? = nil, execution: TVExecution = .accelerated) throws -> TVDecodeResult {
        try settings.validate()
        let s = input.standard, samples = input.samples, count = samples.count
        guard samples.allSatisfy(\.isFinite), count == Int(s.sampleOffset(frame: input.frameIndex+1)-s.sampleOffset(frame: input.frameIndex)) else {
            throw TVError.invalidSignal
        }
        let offset = s.sampleOffset(frame: input.frameIndex)
        // Pulse-width discrimination finds ordinary H sync independently of picture pixels.
        var edges = [Int](), broad = [Int](), start: Int?
        if timing == nil {
            for i in 0...count {
                let low = i < count && samples[i] < -0.15
                if low && start == nil { start = i }
                if !low, let a = start {
                    let width = Double(i-a)/s.sampleRate
                    if (3.5e-6...5.8e-6).contains(width) { edges.append(a) }
                    if (20e-6...30e-6).contains(width) { broad.append(a) }
                    start = nil
                }
            }
        }
        if let timing { edges = timing.edges }
        guard !edges.isEmpty else { throw TVError.syncLost }
        if timing == nil, edges.count <= s.height/2 || broad.isEmpty { throw TVError.syncLost }
        // First broad pulse follows n half-lines of equalizing sync.
        let linePeriod = timing?.samplesPerLine ?? s.samplesPerLine
        let origin = timing?.origin ?? (Double(broad[0])-Double(s.equalizingCount)*s.samplesPerLine/2)
        let uKernel = kernel(cutoff: s == .pal ? 1.3e6 : 1.5e6, rate: s.sampleRate)
        let vKernel = kernel(cutoff: s == .pal ? 1.3e6 : 0.5e6, rate: s.sampleRate)
        let yKernel = kernel(cutoff: s == .pal ? 5e6 : 4.2e6, rate: s.sampleRate, radius: 8)
        struct Scanline: Sendable { let row: Int; let line: Double; let edge: Int }
        struct DecodedLine: Sendable {
            let line: Double
            let y: [Float], u: [Float], v: [Float]
            let magnitude: Float
            let colorLock: Bool
        }
        var descriptors = [Scanline]()
        let rows = Array(stride(from: 0,to: s.height,by: 2))+Array(stride(from: 1,to: s.height,by: 2))
        var edgeCursor = 0, priorExpected = -Double.infinity
        for row in rows {
            let line = s.activeLine(row)
            var expected = origin+line*linePeriod
            if timing?.wrapFrame == true {
                expected = expected.truncatingRemainder(dividingBy: Double(count))
                if expected < 0 { expected += Double(count) }
                if expected < priorExpected { edgeCursor = 0 }
            }
            priorExpected = expected
            while edgeCursor+1 < edges.count && abs(Double(edges[edgeCursor+1])-expected) < abs(Double(edges[edgeCursor])-expected) { edgeCursor += 1 }
            let edge = edges[edgeCursor]
            if abs(Double(edge)-expected) < linePeriod*(timing?.wrapFrame == true ? 0.55 : 0.12) {
                descriptors.append(Scanline(row: row,line: line,edge: edge))
            }
        }
        let scanlines = descriptors
        var decodedLines = [DecodedLine?](repeating: nil,count: s.height)
        decodedLines.withUnsafeMutableBufferPointer { storage in
            let output = TVOutput(buffer: storage)
            perform(count: scanlines.count,execution: execution) { n in
                let item = scanlines[n], row = item.row, edge = item.edge, line = item.line
                let sign: Float = s == .pal ? s.palLineSign(line, frameIndex: input.frameIndex) : 1
                let ba = edge+Int((s.burstStart+0.25e-6)*s.sampleRate)
                let bb = edge+Int((s.burstStart+s.burstDuration-0.25e-6)*s.sampleRate)
                guard ba >= 0, bb < count else { return }
                var burst = SIMD2<Float>.zero, energy = SIMD2<Float>.zero
                for i in ba..<bb {
                    let c = carrier(offset+Int64(i)); burst += c*samples[i]; energy += c*c
                }
                burst /= energy
                let magnitude = sqrt(burst.x*burst.x+burst.y*burst.y), colorLock = magnitude > 0.025
                let target: Float = s == .pal ? (sign == 1 ? 3 * .pi/4 : -3 * .pi/4) : .pi
                let phase = atan2(burst.y,burst.x)-target, cp = cos(phase), sp = sin(phase)
                let gain: Float = colorLock ? min(3,0.15/magnitude) : 0
                let a = edge+Int((s.activeStart*s.sampleRate).rounded())
                let length = Int((s.activeDuration*s.sampleRate).rounded())
                guard a >= 3, a+length+3 < count else {
                    output.store(DecodedLine(line: line,y: [],u: [],v: [],magnitude: magnitude,colorLock: colorLock),at: row)
                    return
                }
                var y = [Float](repeating: 0,count: length), u = y, v = y
                let combDelay = Int((s.samplesPerLine * (s == .pal ? 2 : 1)).rounded())
                for x in 0..<length {
                    let i = a+x
                    let notch = 0.25*samples[i-2]+0.5*samples[i]+0.25*samples[i+2]
                    let luma: Float
                    if settings.separation == .comb, row/2 >= (s == .pal ? 2 : 1), i >= combDelay {
                        let comb = (samples[i]+samples[i-combDelay])*0.5
                        let mismatch = min(1,abs(samples[i]-samples[i-combDelay])/0.3)
                        let failure = settings.combFailure*mismatch
                        luma = comb*(1-failure)+notch*failure
                    } else { luma = notch }
                    let separated = luma*(1-settings.chromaLeakage)+samples[i]*settings.chromaLeakage
                    y[x] = separated/0.7
                    let c = carrier(offset+Int64(i)), chroma = (samples[i]-separated)*2/0.7
                    u[x] = chroma*(c.x*cp+c.y*sp)*gain
                    v[x] = chroma*(-c.x*sp+c.y*cp)*sign*gain
                }
                y = filter(y,yKernel,execution: execution)
                u = filter(u,uKernel,execution: execution)
                v = filter(v,vKernel,execution: execution)
                output.store(DecodedLine(line: line,y: y,u: u,v: v,magnitude: magnitude,colorLock: colorLock),at: row)
            }
        }
        // Barrier above completes every line before PAL's delay-line combination.
        // The previous transmitted line is row-2 within each field. Read the original
        // filtered U/V, so averaging does not cascade through successive lines.
        let decoded = decodedLines
        // Every valid active line has the same length. Compute the exact pixel
        // interpolation coordinates once, instead of repeating division/floor
        // for all 720 * height pixels. The scalar path remains the oracle.
        let activeLength = Int((s.activeDuration*s.sampleRate).rounded())
        let interpolation = (0..<s.width).map { x -> (Int,Int,Float) in
            let p = (Double(x)+0.5)*Double(activeLength)/Double(s.width)-0.5
            let j = max(0,min(activeLength-1,Int(floor(p))))
            return (j,min(activeLength-1,j+1),Float(max(0,p-Double(j))))
        }
        var rgb = [SIMD3<Float>](repeating: .zero,count: s.width*s.height)
        rgb.withUnsafeMutableBufferPointer { storage in
            let output = TVOutput(buffer: storage)
            perform(count: s.height,execution: execution) { row in
                guard let current = decoded[row], !current.y.isEmpty else { return }
                let length = current.y.count
                let previous = row >= 2 ? decoded[row-2] : nil
                let delay = s == .pal && settings.palDelayLine && previous?.line == current.line-1 && previous?.u.count == length
                if execution == .accelerated, !TVOptimizationDiagnostics.baseline, length == activeLength {
                    // Valid scanlines and the sampling plan bound every index.
                    // Borrow once per row instead of rechecking every tap/pixel.
                    let priorUValues = delay ? previous!.u : current.u
                    let priorVValues = delay ? previous!.v : current.v
                    current.y.withUnsafeBufferPointer { yp in
                        current.u.withUnsafeBufferPointer { up in
                            current.v.withUnsafeBufferPointer { vp in
                                priorUValues.withUnsafeBufferPointer { priorU in
                                    priorVValues.withUnsafeBufferPointer { priorV in
                                        interpolation.withUnsafeBufferPointer { coordinates in
                                            let y = yp.baseAddress!, u = up.baseAddress!, v = vp.baseAddress!
                                            let pu = priorU.baseAddress!, pv = priorV.baseAddress!
                                            let sample = coordinates.baseAddress!
                                            for x in 0..<s.width {
                                                let (j,k,f) = sample[x]
                                                let yy = y[j]*(1-f)+y[k]*f
                                                let uj = delay ? (u[j]+pu[j])*0.5 : u[j]
                                                let uk = delay ? (u[k]+pu[k])*0.5 : u[k]
                                                let vj = delay ? (v[j]+pv[j])*0.5 : v[j]
                                                let vk = delay ? (v[k]+pv[k])*0.5 : v[k]
                                                let uu = uj*(1-f)+uk*f, vv = vj*(1-f)+vk*f
                                                let pixel: SIMD3<Float>
                                                if s == .pal { pixel = SIMD3(yy+1.14025*vv,yy-0.39473*uu-0.58081*vv,yy+2.03252*uu) }
                                                else { pixel = SIMD3(yy+0.956*uu+0.621*vv,yy-0.272*uu-0.647*vv,yy-1.106*uu+1.703*vv) }
                                                output.store(SIMD3(clamp(pixel.x),clamp(pixel.y),clamp(pixel.z)),at: row*s.width+x)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    for x in 0..<s.width {
                        let p = (Double(x)+0.5)*Double(length)/Double(s.width)-0.5
                        let j = max(0,min(length-1,Int(floor(p)))), k = min(length-1,j+1), f = Float(max(0,p-Double(j)))
                        let yy = current.y[j]*(1-f)+current.y[k]*f
                        let uj = delay ? (current.u[j]+previous!.u[j])*0.5 : current.u[j]
                        let uk = delay ? (current.u[k]+previous!.u[k])*0.5 : current.u[k]
                        let vj = delay ? (current.v[j]+previous!.v[j])*0.5 : current.v[j]
                        let vk = delay ? (current.v[k]+previous!.v[k])*0.5 : current.v[k]
                        let uu = uj*(1-f)+uk*f, vv = vj*(1-f)+vk*f
                        let pixel: SIMD3<Float>
                        if s == .pal { pixel = SIMD3(yy+1.14025*vv,yy-0.39473*uu-0.58081*vv,yy+2.03252*uu) }
                        else { pixel = SIMD3(yy+0.956*uu+0.621*vv,yy-0.272*uu-0.647*vv,yy-1.106*uu+1.703*vv) }
                        output.store(SIMD3(clamp(pixel.x),clamp(pixel.y),clamp(pixel.z)),at: row*s.width+x)
                    }
                }
            }
        }
        let recovered = scanlines.count
        let locked = decoded.compactMap { $0 }.filter { $0.colorLock }.count
        let amplitude = decoded.compactMap { $0 }.reduce(Float(0)) { $0+$1.magnitude }
        if timing == nil, recovered <= s.height/2 { throw TVError.syncLost }
        return TVDecodeResult(frame: try TVFrame(standard: s,rgb: rgb),recoveredLines: recovered,
                              colorLockedLines: locked,meanBurstAmplitude: amplitude/Float(max(1,recovered)))
    }
}
