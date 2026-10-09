import Foundation
import Accelerate
import Dispatch

/// Synchronous workers borrow shared inputs and write only disjoint output
/// ranges. The owner keeps every array alive until concurrentPerform returns.
private struct TVPropagationSamples: @unchecked Sendable {
    let x: UnsafeBufferPointer<Float>, y: UnsafeBufferPointer<Float>
    let re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>
    func addRay(_ range: Range<Int>, prefix: Int, delay: Double, amplitude: Float,
                phase: Double, doppler: Double, rate: Double) {
        let whole = Int(ceil(delay)), fraction = Float(Double(whole)-delay)
        let angle = phase+2*Double.pi*doppler*Double(range.lowerBound)/rate
        var c = cos(angle), sine = sin(angle)
        let dc = cos(2*Double.pi*doppler/rate), ds = sin(2*Double.pi*doppler/rate)
        for n in range {
            let j = prefix+n-whole
            if j >= 0, j+1 < x.count {
                let a = x[j]+(x[j+1]-x[j])*fraction, b = y[j]+(y[j+1]-y[j])*fraction
                re[n] += amplitude*(a*Float(c)-b*Float(sine)); im[n] += amplitude*(a*Float(sine)+b*Float(c))
            } else if j == x.count-1 {
                re[n] += amplitude*(x[j]*Float(c)-y[j]*Float(sine)); im[n] += amplitude*(x[j]*Float(sine)+y[j]*Float(c))
            }
            if doppler != 0 { let next = c*dc-sine*ds; sine = c*ds+sine*dc; c = next }
        }
    }
}

/// The remote source is analytic in absolute time. Each worker initializes its
/// own oscillators at its first sample; no feedback state is shared across ranges.
private struct TVInterferenceSamples: @unchecked Sendable {
    let re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>
    func addRemote(_ range: Range<Int>, amplitude: Float, rate: Double, time: Double, sound: Bool) {
        let step = 2*Double.pi*26_000/rate, programmeStep = 2*Double.pi*173/rate
        let phase = 2*Double.pi*26_000*time+step*Double(range.lowerBound)
        let programmePhase = 2*Double.pi*173*time+programmeStep*Double(range.lowerBound)
        var x = cos(phase), y = sin(phase), px = cos(programmePhase), py = sin(programmePhase)
        let c = cos(step), si = sin(step), pc = cos(programmeStep), ps = sin(programmeStep)
        for n in range {
            let envelope = sound ? Float(1/sqrt(10.0)) : Float(0.65+0.25*py)
            let fmPhase = -(12_000.0/173)*px
            let fmCos = sound ? cos(fmPhase) : 1, fmSin = sound ? sin(fmPhase) : 0
            re[n] += amplitude*envelope*Float(x*fmCos-y*fmSin)
            im[n] += amplitude*envelope*Float(y*fmCos+x*fmSin)
            let next = x*c-y*si; y = x*si+y*c; x = next
            let pnext = px*pc-py*ps; py = px*ps+py*pc; px = pnext
        }
    }
}

public enum TVAntennaKind: String, CaseIterable, Sendable {
    case dipole = "Dipole", yagi = "Yagi", logPeriodic = "Log-periodic", bowTie = "Bow-tie array"
    public var nominalGainDB: Float {
        switch self { case .dipole: 2.15; case .yagi: 12; case .logPeriodic: 8; case .bowTie: 10 }
    }
    public var beamwidth: Double {
        switch self { case .dipole: 100; case .yagi: 38; case .logPeriodic: 65; case .bowTie: 50 }
    }
    /// Generic elevation-plane pattern, not a measured antenna product.
    public func lossDB(offAxisDegrees: Double) -> Double {
        var angle = abs(offAxisDegrees.remainder(dividingBy: 360))
        if self == .dipole { angle = min(angle, abs(180-angle)) }
        return min(self == .dipole ? 24 : 30, 12*pow(angle/beamwidth,2))
    }
}

public struct TVWeatherSettings: Equatable, Sendable {
    public var enabled = false
    public var rainMMHour: Float = 0
    public var snowMMHour: Float = 0 // water equivalent, not snow depth
    public var fogGramsM3: Float = 0
    public var humidityPercent: Float = 50
    public var temperatureC: Float = 20
    public var sunlight: Float = 0.5
    public var clutter: Float = 0.5
    public var lightning: Float = 0
    /// A remote co-channel source admitted by anomalous ionospheric propagation.
    public var ionization: Float = 0
    public init() {}
}

public struct TVPropagationSettings: Equatable, Sendable {
    public var enabled = false
    public var frequencyMHz: Float = 600
    public var distanceKm: Float = 10
    public var transmitterHeightM: Float = 120
    public var receiverHeightM: Float = 20
    public var antenna: TVAntennaKind = .yagi
    public var antennaElevationDegrees: Float = 0
    public var antennaGainDB: Float = 12
    public var ridgeEnabled = false
    public var ridgeHeightM: Float = 65
    public var ridgePosition: Float = 0.5
    public var refractionK: Float = 4/3
    public var groundReflection: Float = 0
    public var weather = TVWeatherSettings()
    public init() {}
    func validate() throws {
        let checks: [(Float, ClosedRange<Float>)] = [
            (frequencyMHz,50...860),(distanceKm,3...50),(transmitterHeightM,20...300),
            (receiverHeightM,2...150),(antennaElevationDegrees,-90...90),(antennaGainDB,-5...25),
            (ridgeHeightM,0...500),(ridgePosition,0.1...0.9),(refractionK,0.65...4),
            (groundReflection,0...0.8),(weather.rainMMHour,0...120),(weather.snowMMHour,0...20),
            (weather.fogGramsM3,0...0.5),(weather.humidityPercent,0...100),
            (weather.temperatureC,-30...50),(weather.sunlight,0...1),(weather.clutter,0...1),
            (weather.lightning,0...1),(weather.ionization,0...1)]
        guard checks.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw TVError.invalidSettings }
    }
}

public struct TVPropagationReport: Sendable {
    public let spaceLossDB: Double
    public let diffractionLossDB: Double
    public let antennaLossDB: Double
    public let weatherLossDB: Double
    public let relativeGainDB: Double
    public let refractionK: Double
    public let ridgeClearanceM: Double
    public let diffractionPointDistanceM: Double
    public let obstructionHeightM: Double
    public let fresnelRadiusM: Double
    public let arrivalDegrees: Double
    public let groundDelaySeconds: Double
    public let groundAmplitude: Double
    public let groundArrivalDegrees: Double
    public let clutterAmplitude: Double
    public let thermalNoiseScale: Float
}

public enum TVPropagationModel {
    public static let earthRadiusM = 6_371_000.0
    /// Reference envelope: 10 km, 600 MHz, 12 dBi aligned RX antenna. The
    /// absolute FSPL is diagnostic; the existing envelope has no dBm calibration.
    public static func evaluate(_ s: TVPropagationSettings, carrierOffsetHz: Double = 0) -> TVPropagationReport {
        let f = Double(s.frequencyMHz)*1e6+carrierOffsetHz, wavelength = 299_792_458/f
        let d = Double(s.distanceKm)*1000
        let tx = Double(s.transmitterHeightM), rx = Double(s.receiverHeightM)
        let w = s.weather, wet = w.enabled
        // A selectable weather scenario, not an inferred meteorological profile.
        // Daytime near-ground heating and moisture perturb the assumed gradient.
        let gradientAdjustment = wet ? 24*(Double(w.sunlight)-0.5)-0.12*(Double(w.humidityPercent)-50)
            + 0.15*(Double(w.temperatureC)-20) : 0
        let inverseK = 1/Double(s.refractionK)+earthRadiusM*1e-9*gradientAdjustment
        let k = min(4,max(0.65,1/max(0.25,inverseK)))
        let earthPoint = min(d*0.9,max(d*0.1,d/2+k*earthRadiusM*(tx-rx)/d))
        func fresnelObstruction(_ x: Double, height: Double) -> Double {
            let bulge = x*(d-x)/(2*k*earthRadiusM), line = tx+(rx-tx)*x/d
            return (height+bulge-line)*sqrt(2*d/(wavelength*x*(d-x)))
        }
        let ridgePoint = d*Double(s.ridgePosition)
        let ridgeDominant = s.ridgeEnabled && fresnelObstruction(ridgePoint,height: Double(s.ridgeHeightM))
            >= fresnelObstruction(earthPoint,height: 0)
        let a = ridgeDominant ? ridgePoint : earthPoint
        let b = d-a
        let bulge = a*b/(2*k*earthRadiusM)
        let line = tx+(rx-tx)*a/d
        let obstruction = (ridgeDominant ? Double(s.ridgeHeightM) : 0)+bulge
        let clearance = line-obstruction
        let fresnel = sqrt(wavelength*a*b/d)
        let v = -clearance*sqrt(2*d/(wavelength*a*b))
        let diffraction = v > -0.78 ? 6.9+20*log10(sqrt(pow(v-0.1,2)+1)+v-0.1) : 0
        let arrival = atan2(clearance < 0 ? obstruction-rx : tx-rx,clearance < 0 ? b : d)*180/Double.pi
        let antenna = s.antenna.lossDB(offAxisDegrees: Double(s.antennaElevationDegrees)-arrival)
        let space = 20*log10(4*Double.pi*d/wavelength)
        let reference = 20*log10(4*Double.pi*10_000/(299_792_458/600e6))
        let rain = Double(w.rainMMHour), snow = Double(w.snowMMHour), fog = Double(w.fogGramsM3)
        // Deliberately small sub-GHz bulk absorption. P.838 is not extrapolated
        // below its 1 GHz domain; these are documented illustrative coefficients.
        let bulk = wet ? Double(s.distanceKm)*pow(f/1e9,2)*(0.00012*rain+0.00006*snow+0.002*fog) : 0
        let surface = wet ? 0.7*(rain/120)+0.6*(snow/20)+0.15*max(0,(Double(w.humidityPercent)-70)/30) : 0
        let weatherLoss = bulk+surface
        let directLength = hypot(d,tx-rx), groundLength = hypot(d,tx+rx)
        let groundArrival = -atan2(tx+rx,d)*180/Double.pi
        let groundV = (obstruction-abs(tx-(tx+rx)*a/d))*sqrt(2*d/(wavelength*a*b))
        let groundDiffraction = groundV > -0.78 ? 6.9+20*log10(sqrt(pow(groundV-0.1,2)+1)+groundV-0.1) : 0
        let ground = Double(s.groundReflection)*(wet ? 1+0.4*rain/120 : 1)
            * pow(10,(Double(s.antennaGainDB)-12-groundDiffraction-s.antenna.lossDB(offAxisDegrees: Double(s.antennaElevationDegrees)-groundArrival))/20)
        let clutter = wet ? Double(w.clutter)*min(0.12,0.001*rain+0.002*snow+0.04*fog)
            * pow(10,(Double(s.antennaGainDB)-12-diffraction-s.antenna.lossDB(offAxisDegrees: Double(s.antennaElevationDegrees)+18))/20) : 0
        return TVPropagationReport(spaceLossDB: space,diffractionLossDB: diffraction,antennaLossDB: antenna,
            weatherLossDB: weatherLoss,relativeGainDB: reference-space+Double(s.antennaGainDB)-12-antenna-diffraction-weatherLoss,
            refractionK: k,ridgeClearanceM: clearance,diffractionPointDistanceM: a,obstructionHeightM: obstruction,
            fresnelRadiusM: fresnel,arrivalDegrees: arrival,
            groundDelaySeconds: (groundLength-directLength)/299_792_458,groundAmplitude: ground,
            groundArrivalDegrees: groundArrival,clutterAmplitude: clutter,
            thermalNoiseScale: wet ? Float(sqrt((Double(w.temperatureC)+273.15)/293.15)) : 1)
    }
}

/// Causal per-carrier propagation. Only excess delays are retained; absolute
/// link delay and common RF phase are outside this locally tuned envelope model.
struct TVSceneChannel: Sendable {
    private var tailI = [Float](), tailQ = [Float]()
    func noiseScale(_ s: TVPropagationSettings) -> Float {
        s.enabled ? TVPropagationModel.evaluate(s).thermalNoiseScale : 1
    }
    mutating func propagate(i: [Float], q: [Float], rate: Double, carrierOffsetHz: Double,
                            time: Double, settings s: TVPropagationSettings) -> ([Float],[Float]) {
        guard s.enabled else { tailI.removeAll(keepingCapacity: true); tailQ.removeAll(keepingCapacity: true); return (i,q) }
        let report = TVPropagationModel.evaluate(s,carrierOffsetHz: carrierOffsetHz)
        let f = Double(s.frequencyMHz)*1e6+carrierOffsetHz
        let direct = Float(pow(10,report.relativeGainDB/20))
        let distanceScale = pow(10,(20*log10(600e6/f)-20*log10(Double(s.distanceKm)/10)-report.weatherLossDB)/20)
        var rays = [(Double,Float,Double,Double)]() // delay in samples, amplitude, phase, Doppler Hz
        if report.groundAmplitude > 0 {
            let phase = Double.pi-2*Double.pi*f*report.groundDelaySeconds
            rays.append((report.groundDelaySeconds*rate,Float(report.groundAmplitude*distanceScale),phase,0))
        }
        if report.clutterAmplitude > 0 {
            let delay = (0.8+Double(s.distanceKm)*0.04)*1e-6
            let phase = -2*Double.pi*f*delay+2*Double.pi*0.07*time
            rays.append((delay*rate,Float(report.clutterAmplitude*distanceScale),phase,0.07))
        }
        var re = [Float](repeating: 0,count: i.count), im = re
        var scale = direct
        vDSP_vsmul(i,1,&scale,&re,1,vDSP_Length(i.count)); vDSP_vsmul(q,1,&scale,&im,1,vDSP_Length(q.count))
        if !rays.isEmpty {
            let xi = tailI+i, xq = tailQ+q, prefix = tailI.count
            let count = i.count, paths = rays
            xi.withUnsafeBufferPointer { xp in xq.withUnsafeBufferPointer { yp in
                    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { mp in
                        let samples = TVPropagationSamples(x: xp,y: yp,re: rp,im: mp)
                        let workers = min(8,max(1,count/32_768))
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            let range = worker*count/workers..<(worker+1)*count/workers
                            for (delay,amplitude,phase,doppler) in paths {
                                samples.addRay(range,prefix: prefix,delay: delay,amplitude: amplitude,phase: phase,doppler: doppler,rate: rate)
                            }
                        }
                    } }
            } }
        }
        let history = Int(ceil(5e-6*rate))+2
        tailI = i.count >= history ? Array(i.suffix(history)) : Array((tailI+i).suffix(history))
        tailQ = q.count >= history ? Array(q.suffix(history)) : Array((tailQ+q).suffix(history))
        return (re,im)
    }

    /// Common deterministic event timeline, independently sampled by both
    /// envelopes. Lightning is additive RF interference, not a volume effect.
    static func interference(i: inout [Float], q: inout [Float], rate: Double,
                             carrierOffsetHz: Double, time: Double, noiseReferenceRate: Double, seed: UInt64,
                             settings s: TVPropagationSettings, execution: TVExecution = .accelerated) {
        guard s.enabled, s.weather.enabled else { return }
        let w = s.weather, f = Double(s.frequencyMHz)*1e6+carrierOffsetHz
        let ion = Double(w.ionization)*min(1,pow(100e6/f,3.5))*(0.6+0.4*Double(w.sunlight))
            * pow(10,(Double(s.antennaGainDB)-12-s.antenna.lossDB(offAxisDegrees: Double(s.antennaElevationDegrees)-10))/20)
        guard w.lightning > 0 || ion > 0 else { return }
        let count = i.count
        i.withUnsafeMutableBufferPointer { ip in q.withUnsafeMutableBufferPointer { qp in
            if ion > 0 {
                let samples = TVInterferenceSamples(re: ip,im: qp)
                let workers = execution == .accelerated ? min(8,max(1,count/32_768)) : 1
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    samples.addRemote(worker*count/workers..<(worker+1)*count/workers,
                        amplitude: Float(0.7*ion),rate: rate,time: time,sound: carrierOffsetHz > 1e6)
                }
            }
            if w.lightning > 0 {
                let first = Int(floor(time*4))-1, last = Int(floor((time+Double(count)/rate)*4))
                for cell in max(0,first)...max(0,last) {
                    let random = hash(seed &+ UInt64(cell)*0x9e3779b9)
                    guard Double(random & 0xffff)/65535 < Double(w.lightning)*0.5 else { continue }
                    let eventTime = Double(cell)*0.25+0.02+Double((random >> 16)&0xffff)/65535*0.20
                    let begin = max(0,Int(floor((eventTime-time)*rate)))
                    let end = min(count,Int(ceil((eventTime+0.003-time)*rate)))
                    guard begin < end else { continue }
                    let amplitude = Float(1+7*Double(w.lightning))*Float(sqrt(min(1,100e6/f)*rate/noiseReferenceRate))
                    for n in begin..<end {
                        let age = time+Double(n)/rate-eventTime
                        guard age >= 0 else { continue }
                        let decay = Float(exp(-age/0.0006))
                        let key = UInt64(max(0,Int64((time*rate).rounded())+Int64(n)))
                        let noise = hash(random ^ key)
                        ip[n] += amplitude*decay*(Float(noise & 0xffff)/32767.5-1)
                        qp[n] += amplitude*decay*(Float((noise >> 16)&0xffff)/32767.5-1)
                    }
                }
            }
        } }
    }
    private static func hash(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
