import Foundation

public struct TVEncoderDamageSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var differentialGain: Float = 0
    public var differentialPhaseDegrees: Float = 0
    public var burstAmplitude: Float = 1
    public var burstPhaseDegrees: Float = 0
    public var burstDriftDegrees: Float = 0
    public var burstDriftHz: Float = 0.25
    public init() {}
    func validate() throws {
        let values: [(Float,ClosedRange<Float>)] = [(differentialGain,-1...1),
            (differentialPhaseDegrees,-90...90),(burstAmplitude,0...2),(burstPhaseDegrees,-180...180),
            (burstDriftDegrees,0...90),(burstDriftHz,0...3)]
        guard values.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw TVError.invalidSettings }
    }
}

public struct TVVSBFilterSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var transitionMHz: Float = 0.2
    /// Excess group delay at fsc, on top of the causal FIR's constant delay.
    public var groupDelayNS: Float = 0
    public var peakingDB: Float = 0
    public init() {}
    func validate() throws {
        guard transitionMHz.isFinite, (0.03...1.5).contains(transitionMHz),
              groupDelayNS.isFinite, (-500...500).contains(groupDelayNS),
              peakingDB.isFinite, (0...12).contains(peakingDB) else { throw TVError.invalidSettings }
    }
}

public struct TVReceiverDamageSettings: Codable, Equatable, Sendable {
    public var agcEnabled = false
    public var agcResponseMS: Float = 250
    public var agcOvershoot: Float = 0
    public var agcPictureSensitivity: Float = 0
    public var syncEnabled = false
    public var horizontalResponseMS: Float = 1
    public var horizontalDeadZoneUS: Float = 0
    public var horizontalJitterUS: Float = 0
    public var horizontalOscillatorPPM: Float = 0
    public var verticalHoldHz: Float = 0
    public var verticalCaptureLines: Float = 8
    public init() {}
    func validate() throws {
        let values: [(Float,ClosedRange<Float>)] = [(agcResponseMS,10...1000),(agcOvershoot,0...1),
            (agcPictureSensitivity,0...1),(horizontalResponseMS,0.05...50),(horizontalDeadZoneUS,0...5),
            (horizontalJitterUS,0...8),(horizontalOscillatorPPM,-500...500),
            (verticalHoldHz,-2...2),(verticalCaptureLines,0...40)]
        guard values.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw TVError.invalidSettings }
    }
}

/// Analytic second-order log-gain servo, stable at either television frame rate.
/// Overshoot sets damping; it never multiplies the displayed RGB after decoding.
struct TVAGCDynamics: Sendable {
    private var position: Double?, velocity = 0.0
    mutating func step(target: Float, seconds: Double, responseMS: Float, overshoot: Float) -> Float {
        let goal = log(Double(max(0.05,min(10000,target))))
        guard let position else { self.position = goal; return Float(exp(goal)) }
        let omega = 4/(Double(responseMS)*0.001), damping = 1-0.85*Double(overshoot)
        let x = position-goal, decay = exp(-damping*omega*seconds)
        let next: Double, speed: Double
        if damping > 0.9999 {
            let b = velocity+omega*x
            next = decay*(x+b*seconds)
            speed = decay*(velocity-omega*b*seconds)
        } else {
            let wd = omega*sqrt(1-damping*damping), c = cos(wd*seconds), s = sin(wd*seconds)
            next = decay*(x*c+(velocity+damping*omega*x)*s/wd)
            speed = decay*(velocity*c-(damping*omega*velocity+omega*omega*x)*s/wd)
        }
        self.position = max(log(0.05),min(log(10000),goal+next)); velocity = speed
        return Float(exp(self.position!))
    }
    mutating func reset() { position = nil; velocity = 0 }
}

/// Hardware oscillator/phase-detector model, driven by measured sync timing.
/// The raster can depart from detected edges even while a pulse train exists.
struct TVRasterDynamics: Sendable {
    private var horizontalPhase = 0.0
    private var verticalPhase = 0.0
    private var random: UInt64 = 0
    private var initialized = false
    mutating func apply(_ timing: TVSyncTiming, standard: TVStandard, settings: TVReceiverDamageSettings,
                        horizontalDetected: Bool, verticalDetected: Bool, seed: UInt64) -> (TVSyncTiming,Bool,Bool) {
        guard settings.syncEnabled else {
            horizontalPhase = 0; verticalPhase = 0; initialized = false
            return (timing,true,true)
        }
        if !initialized { random = seed ^ 0x504c4c; initialized = true }
        let rate = standard.sampleRate, period = timing.samplesPerLine
        let field = period*Double(standard.totalLines)/2
        verticalPhase += Double(settings.verticalHoldHz)*standard.frameDuration*field
        verticalPhase = (verticalPhase+field/2).truncatingRemainder(dividingBy: field)
        if verticalPhase < 0 { verticalPhase += field }; verticalPhase -= field/2
        let vLocked = verticalDetected && abs(verticalPhase) <= Double(settings.verticalCaptureLines)*period
        if vLocked { verticalPhase *= exp(-standard.frameDuration/0.1) }
        let alpha = 1-exp(-standard.lineDuration/(Double(settings.horizontalResponseMS)*0.001))
        let deadZone = Double(settings.horizontalDeadZoneUS)*1e-6*rate
        let drift = period*Double(settings.horizontalOscillatorPPM)*1e-6
        let jitter = Double(settings.horizontalJitterUS)*1e-6*rate
        var maximum = 0.0
        var previousEdge = 0
        let edges = timing.edges.map { edge -> Int in
            // The horizontal oscillator free-runs over vertical blanking gaps.
            let elapsedLines = max(1,Double(edge-previousEdge)/period)
            previousEdge = edge
            random &+= 0x9e3779b97f4a7c15
            var z = random; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            let noise = Double((z ^ (z >> 31)) >> 40)/Double(1<<24)*2-1
            horizontalPhase += drift*elapsedLines+jitter*noise*0.2*sqrt(elapsedLines)
            if horizontalDetected, abs(horizontalPhase) > deadZone { horizontalPhase *= 1-alpha }
            horizontalPhase = max(-period*0.1,min(period*0.1,horizontalPhase))
            maximum = max(maximum,abs(horizontalPhase))
            return edge+Int(horizontalPhase.rounded())
        }
        return (TVSyncTiming(origin: timing.origin+verticalPhase,samplesPerLine: period,edges: edges,wrapFrame: abs(verticalPhase) > 0.001),
                maximum < rate*2e-6,vLocked)
    }
}
