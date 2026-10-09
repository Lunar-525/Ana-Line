import Foundation

/// A deterministic time-varying channel, evaluated in signal time (not UI time).
public struct SSTVChannelState: Sendable {
    public let noise: Float
    public let offset: Float
    public let clockPPM: Float
    public let gain: Float
    public let dropout: Float
    public let interference: Float
    public let interferenceHz: Float

    public static func at(sample: Int,total: Int,settings: SSTVSettings) -> Self {
        let s = settings.validated, amount = s.variation
        // 10ms control grid makes chunking and playback speed irrelevant to the trajectory.
        let controlSample = max(0,sample)/120*120
        let time = Float(controlSample)/12000
        let t = time/s.variationSeconds
        func noise(_ coordinate: Float,_ stream: UInt32) -> Float {
            let cell = UInt32(max(0,Int(floor(coordinate)))), f = coordinate-floor(coordinate)
            let smooth = f*f*(3-2*f)
            let salt = s.seed &* 0x9e3779b9 &+ stream &* 0x85ebca6b
            let a = SSTVEngine.hash(cell &+ salt), b = SSTVEngine.hash(cell &+ 1 &+ salt)
            return (a+(b-a)*smooth)*2-1
        }
        let fast = noise(t,1), slow = noise(t*0.19,2), clock = noise(t*0.11,3)
        // Sparse smooth pulses: intermittent local interference/noise and correlated fades.
        let event = UInt32(max(0,Int(floor(t*0.5))))
        let eventPosition = t*0.5-floor(t*0.5)
        let active = SSTVEngine.hash(event &+ s.seed &* 73) > 0.65
        let pulse = active ? pow(max(0,1-abs(eventPosition-0.5)*4),2) : 0
        let fade = amount*min(0.9,0.45*(noise(t*0.7,4)+1)+0.3*pulse)
        let baseDrift = s.drift*(Float(controlSample)/Float(max(1,total))-0.5)
        return Self(
            noise: max(0,s.noise*(1+amount*fast*0.8)+amount*pulse*0.3),
            offset: s.frequencyOffset+baseDrift+amount*(fast*(10+abs(s.frequencyOffset)*0.3)+slow*(50+abs(s.drift)*0.5)),
            clockPPM: s.clockPPM+amount*clock*(120+abs(s.clockPPM)*0.3),
            gain: 1-fade,
            dropout: min(0.95,max(0,s.dropout*(1+amount*noise(t*0.8,5)))),
            interference: max(0,s.interference*(1+amount*noise(t*1.3,6))+amount*pulse*0.2),
            interferenceHz: s.interferenceHz+amount*noise(t*0.4,7)*80)
    }
}
