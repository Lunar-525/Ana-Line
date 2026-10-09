import Foundation
import Accelerate
import Dispatch

/// Borrowed buffers live only through synchronous concurrentPerform. Workers
/// read shared inputs and write disjoint sample ranges; no pointer escapes.
private struct TVPASamples: @unchecked Sendable {
    let i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>
    let table: UnsafeBufferPointer<SIMD2<Float>>
    let other: UnsafeBufferPointer<Float>, coupling: Float
    let re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>
    func process(_ range: Range<Int>, previous: SIMD2<Float>) -> Float {
        var peak: Float = 0
        var prior = range.lowerBound == 0 ? previous : SIMD2(i[range.lowerBound-1],q[range.lowerBound-1])
        let constantPower = other.count == 1 ? coupling*other[0] : 0
        let otherScale = Double(other.count)/Double(i.count)
        for n in range {
            let external = other.count > 1 ? coupling*other[min(other.count-1,Int(Double(n)*otherScale))] : constantPower
            let current = SIMD2(i[n],q[n])
            for half in 0...1 {
                let x = half == 0 ? (prior+current)*0.5 : current
                let power = x.x*x.x+x.y*x.y+external
                peak = max(peak,power)
                let position = min(8192,max(0,Double(power)*512))
                let index = min(8191,Int(position)), fraction = Float(position-Double(index))
                let c = table[index]+(table[index+1]-table[index])*fraction
                re[n*2+half] = x.x*c.x-x.y*c.y; im[n*2+half] = x.x*c.y+x.y*c.x
            }
            prior = current
        }
        return peak
    }
}

/// One disjoint reduction slot per synchronous worker.
private struct TVPAPeaks: @unchecked Sendable {
    let values: UnsafeMutableBufferPointer<Float>
}

private final class TVPADecimator: @unchecked Sendable {
    var filter: TelevisionFIR
    let input: [Float]
    var output = [Float]()
    var energy: Float = 0
    init(_ filter: TelevisionFIR, input: [Float]) { self.filter = filter; self.input = input }
    func run() {
        output = filter.decimate(input,factor: 2,phase: 1)
        vDSP_svesq(output,1,&energy,vDSP_Length(output.count))
    }
}

public struct TVTransmitterSettings: Equatable, Sendable {
    public var enabled = false
    /// Nominal RF drive power relative to the original sync-carrier reference.
    /// Actual forward power is measured after any PA compression.
    public var powerDB: Float = 0
    public var powerGain: Float { pow(10,powerDB/10) }
    /// Sync carrier relative to saturation. Positive backoff adds headroom.
    public var backoffDB: Float = 6
    public var hardness: Float = 0.5
    public var phaseDegrees: Float = 0
    /// Rotating-wave in-band cross-compression, not a full-channel RF spectrum.
    public var sharedCoupling: Float = 0
    public var audioDriveDB: Float = 0
    /// Scalar load mismatch at the TX feed point; matched source, no load-pull.
    public var loadVSWR: Float = 1
    public var reflectedFraction: Float {
        let reflection = (loadVSWR-1)/(loadVSWR+1)
        return reflection*reflection
    }
    public var encoder = TVEncoderDamageSettings()
    public var vsb = TVVSBFilterSettings()
    public init() {}
    static func drive(i: inout [Float],q: inout [Float],settings: TVTransmitterSettings) {
        guard settings.powerDB != 0 else { return }
        scale(i: &i,q: &q,amplitude: pow(10,settings.powerDB/20))
    }
    static func deliver(i: inout [Float],q: inout [Float],settings: TVTransmitterSettings) {
        guard settings.loadVSWR != 1 else { return }
        scale(i: &i,q: &q,amplitude: sqrt(1-settings.reflectedFraction))
    }
    private static func scale(i: inout [Float],q: inout [Float],amplitude: Float) {
        guard !i.isEmpty, !q.isEmpty else { return }
        var amplitude = amplitude
        i.withUnsafeMutableBufferPointer { p in
            vDSP_vsmul(p.baseAddress!,1,&amplitude,p.baseAddress!,1,vDSP_Length(p.count))
        }
        q.withUnsafeMutableBufferPointer { p in
            vDSP_vsmul(p.baseAddress!,1,&amplitude,p.baseAddress!,1,vDSP_Length(p.count))
        }
    }
    func validate() throws {
        try encoder.validate(); try vsb.validate()
        guard powerDB.isFinite, (-60...12).contains(powerDB),
              backoffDB.isFinite, (-6...24).contains(backoffDB),
              hardness.isFinite, (0...1).contains(hardness),
              phaseDegrees.isFinite, (-45...45).contains(phaseDegrees),
              sharedCoupling.isFinite, (0...1).contains(sharedCoupling),
              audioDriveDB.isFinite, (0...24).contains(audioDriveDB),
              loadVSWR.isFinite, (1...5).contains(loadVSWR) else { throw TVError.invalidSettings }
    }
}

/// Separate vision/sound PAs, before linear combining. A 2x interpolated
/// complex envelope and anti-alias FIR reduce in-band folding; this is a
/// bounded memoryless compression model, not a full transistor/spectral mask.
struct TVTransmitterAmplifier: Sendable {
    private(set) var peakDrivePower: Float = 0
    private(set) var meanOutputPower: Float = 0
    private var cached: SIMD3<Float>?
    private var factors = [SIMD2<Float>]()
    private var previous = SIMD2<Float>(0,0)
    private var realFilter: TelevisionFIR?
    private var imaginaryFilter: TelevisionFIR?
    static func coefficient(power: Double, settings: TVTransmitterSettings) -> SIMD2<Float> {
        let saturationPower = pow(10,Double(settings.backoffDB)/10)
        let ratio = power/saturationPower, p = 1+3*Double(settings.hardness)
        let compression = pow(1+pow(ratio,p),-1/(2*p))
        let phase = Double(settings.phaseDegrees)*Double.pi/180*ratio/(1+ratio)
        return SIMD2(Float(compression*cos(phase)),Float(compression*sin(phase)))
    }
    mutating func apply(i: [Float], q: [Float], settings: TVTransmitterSettings, execution: TVExecution, otherPower: [Float] = []) -> ([Float],[Float]) {
        guard settings.enabled, !i.isEmpty else {
            peakDrivePower = 0
            meanOutputPower = TVTransmitterTelemetry.meanPower(i: i,q: q)
            previous = SIMD2(i.last ?? 0,q.last ?? 0)
            realFilter = nil; imaginaryFilter = nil
            return (i,q)
        }
        let curve = SIMD3(settings.backoffDB,settings.hardness,settings.phaseDegrees)
        if cached != curve {
            factors = (0...8192).map { Self.coefficient(power: Double($0)/512,settings: settings) }
            cached = curve
        }
        if realFilter == nil {
            let radius = 12, fc = 0.225 // relative to the 2x sampling rate
            var kernel = (-radius...radius).map { n in
                let sinc = n == 0 ? 2 * fc : sin(2 * Double.pi * fc * Double(n)) / (Double.pi * Double(n))
                let taper = 0.54 + 0.46 * cos(Double.pi * Double(n) / Double(radius))
                return Float(sinc * taper)
            }
            let sum = kernel.reduce(0,+); for n in kernel.indices { kernel[n] /= sum }
            realFilter = TelevisionFIR(kernel); imaginaryFilter = TelevisionFIR(kernel)
        }
        var re = [Float](repeating: 0,count: i.count*2), im = re
        let count = i.count, initial = previous
        let workers = execution == .accelerated ? min(8,max(1,count/32_768)) : 1
        var peaks = [Float](repeating: 0,count: workers)
        peaks.withUnsafeMutableBufferPointer { peakBuffer in
        let reduction = TVPAPeaks(values: peakBuffer)
        i.withUnsafeBufferPointer { ip in q.withUnsafeBufferPointer { qp in
            otherPower.withUnsafeBufferPointer { other in
            factors.withUnsafeBufferPointer { table in
                re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { mp in
                    let samples = TVPASamples(i: ip,q: qp,table: table,other: other,coupling: 2*settings.sharedCoupling,re: rp,im: mp)
                    DispatchQueue.concurrentPerform(iterations: workers) { worker in
                        reduction.values[worker] = samples.process(worker*count/workers..<(worker+1)*count/workers,previous: initial)
                    }
                } }
            }
        } } }
        }
        peakDrivePower = peaks.max() ?? 0
        previous = SIMD2(i.last!,q.last!)
        if execution == .reference {
            let filtered = TelevisionFIR.together([realFilter!,imaginaryFilter!],inputs: [re,im],execution: execution)
            realFilter = filtered.0[0]; imaginaryFilter = filtered.0[1]
            let output = (stride(from: 1,to: re.count,by: 2).map { filtered.1[0][$0] },
                          stride(from: 1,to: im.count,by: 2).map { filtered.1[1][$0] })
            meanOutputPower = TVTransmitterTelemetry.meanPower(i: output.0,q: output.1)
            return output
        }
        let work = [TVPADecimator(realFilter!,input: re),TVPADecimator(imaginaryFilter!,input: im)]
        DispatchQueue.concurrentPerform(iterations: 2) { work[$0].run() }
        realFilter = work[0].filter; imaginaryFilter = work[1].filter
        meanOutputPower = (work[0].energy+work[1].energy)/Float(count)
        return (work[0].output,work[1].output)
    }
}

public struct TVTransmitterTelemetry: Equatable, Sendable {
    /// Relative mean I/Q power. Vision sync-carrier power is one reference unit.
    public var forwardPower: Float = 0
    public var reflectedPower: Float = 0
    public var saturated = false
    public var overmodulated = false
    public var referencePower: Float = 1
    public var deliveredPower: Float { forwardPower-reflectedPower }
    public init() {}
    static func meanPower(i: [Float],q: [Float]) -> Float {
        guard !i.isEmpty else { return 0 }
        var a: Float = 0, b: Float = 0
        vDSP_svesq(i,1,&a,vDSP_Length(i.count))
        vDSP_svesq(q,1,&b,vDSP_Length(q.count))
        return (a+b)/Float(i.count)
    }
}
