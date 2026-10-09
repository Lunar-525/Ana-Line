import Foundation

/// Protocol timing in seconds, never rounded separately to sample counts.
public enum SSTVMode: String, CaseIterable, Hashable, Sendable {
    case robot36 = "Robot36", martinM1 = "Martin M1", scottieS1 = "Scottie S1", pd120 = "PD120"
    public var width: Int { self == .pd120 ? 640 : 320 }
    public var height: Int { self == .robot36 ? 240 : self == .pd120 ? 496 : 256 }
    public var vis: Int { switch self { case .robot36: 8; case .martinM1: 44; case .scottieS1: 60; case .pd120: 95 } }
    public var rowsPerLine: Int { self == .pd120 ? 2 : 1 }
    public var commitRows: Int { self == .robot36 || self == .pd120 ? 2 : 1 }
    public var lineSeconds: Double { segments(row: 0).reduce(0) { $0+$1.seconds } }
    public var duration: Double { SSTVEngine.headerSeconds+Double(height/rowsPerLine)*lineSeconds }
    public var syncSeconds: Double { switch self { case .martinM1: 0.004862; case .pd120: 0.020; default: 0.009 } }
    public var syncOffset: Double { self == .scottieS1 ? 2*(0.13674+0.003) : 0 }
    public var dimensions: String { "\(width) × \(height)" }
    enum Component { case red, green, blue, y, yNext, cr, cb }
    struct Segment {
        let seconds: Double
        let frequency: Float
        let component: Component?
        static func tone(_ hz: Float,_ seconds: Double) -> Self { Self(seconds: seconds,frequency: hz,component: nil) }
        static func scan(_ c: Component,_ seconds: Double) -> Self { Self(seconds: seconds,frequency: 0,component: c) }
    }
    func segments(row: Int) -> [Segment] {
        switch self {
        case .robot36:
            return [.tone(1200,0.009),.tone(1500,0.003),.scan(.y,0.088),.tone(row%2 == 0 ? 1500 : 2300,0.0045),.tone(1900,0.0015),.scan(row%2 == 0 ? .cr : .cb,0.044)]
        case .martinM1:
            return [.tone(1200,0.004862),.tone(1500,0.000572),.scan(.green,0.146432),.tone(1500,0.000572),.scan(.blue,0.146432),.tone(1500,0.000572),.scan(.red,0.146432),.tone(1500,0.000572)]
        case .scottieS1:
            // PySSTV-compatible sweep/gap convention: 136.74ms data plus
            // 1.5ms before/after each component; sync is before red, not line start.
            return [.tone(1500,0.0015),.scan(.green,0.13674),.tone(1500,0.0015),.tone(1500,0.0015),.scan(.blue,0.13674),.tone(1500,0.0015),.tone(1200,0.009),.tone(1500,0.0015),.scan(.red,0.13674),.tone(1500,0.0015)]
        case .pd120:
            return [.tone(1200,0.020),.tone(1500,0.00208),.scan(.y,0.1216),.scan(.cr,0.1216),.scan(.cb,0.1216),.scan(.yNext,0.1216)]
        }
    }
}
