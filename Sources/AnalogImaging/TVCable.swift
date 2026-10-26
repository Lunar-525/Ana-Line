import Foundation

/// Signal path between the terrestrial receiver and the CRT.
///
/// AV/BNC carry one CVBS line; Component carries Y/Pb/Pr; S-Video carries Y/C.
/// One line can be unplugged independently, and every line has its own
/// connector impedance, health and tightness.
public struct TVCableSettings: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case off, av, bnc, component, sVideo

        public var title: String {
            switch self {
            case .off: return "Off"
            case .av: return "AV"
            case .bnc: return "BNC"
            case .component: return "Component (Y/Pb/Pr)"
            case .sVideo: return "S-Video"
            }
        }
        public var shortTitle: String {
            switch self {
            case .off: return "Off"
            case .av: return "AV"
            case .bnc: return "BNC"
            case .component: return "Y/Pb/Pr"
            case .sVideo: return "S-Video"
            }
        }
        public var lineCount: Int {
            switch self {
            case .off: return 0
            case .av, .bnc: return 1
            case .sVideo: return 2
            case .component: return 3
            }
        }
        public var lineNames: [String] {
            switch self {
            case .off: return []
            case .av, .bnc: return ["CVBS"]
            case .sVideo: return ["Y", "C"]
            case .component: return ["Y", "Pb", "Pr"]
            }
        }
    }

    public struct Line: Codable, Equatable, Sendable {
        public var connected: Bool
        public var connectorImpedance: Double
        public var connectorHealth: Double
        public var tightness: Double

        public init(connected: Bool = true, connectorImpedance: Double = 75,
                    connectorHealth: Double = 1, tightness: Double = 1) {
            self.connected = connected
            self.connectorImpedance = Self.clamp(connectorImpedance, 50, 100)
            self.connectorHealth = Self.clamp(connectorHealth, 0, 1)
            self.tightness = Self.clamp(tightness, 0, 1)
        }
        static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            min(high, max(low, value.isFinite ? value : low))
        }
    }

    public struct Interference: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case mains, microwave, compressor, transformer, groundPotential
            public var title: String {
                switch self {
                case .mains: return "220V mains cable"
                case .microwave: return "Microwave oven"
                case .compressor: return "Compressor"
                case .transformer: return "Transformer"
                case .groundPotential: return "Ground potential difference"
                }
            }
        }
        public var id: UUID
        public var kind: Kind
        public var enabled: Bool
        public var intensity: Double
        public var distance: Double

        public init(id: UUID = UUID(), kind: Kind, enabled: Bool = true,
                    intensity: Double = 0.5, distance: Double = 0.3) {
            self.id = id
            self.kind = kind
            self.enabled = enabled
            self.intensity = Line.clamp(intensity, 0, 1)
            self.distance = Line.clamp(distance, 0, 1)
        }
    }

    public var kind: Kind
    public var lines: [Line]
    public var cableImpedance: Double
    public var cableHealth: Double
    public var interferences: [Interference]

    public init(kind: Kind = .off, lines: [Line] = [],
                cableImpedance: Double = 75, cableHealth: Double = 1,
                interferences: [Interference] = []) {
        self.kind = kind
        self.lines = lines
        self.cableImpedance = Line.clamp(cableImpedance, 50, 100)
        self.cableHealth = Line.clamp(cableHealth, 0, 1)
        self.interferences = interferences
        normalize()
    }

    public static let off = TVCableSettings()

    public mutating func normalize() {
        cableImpedance = Line.clamp(cableImpedance, 50, 100)
        cableHealth = Line.clamp(cableHealth, 0, 1)
        let count = kind.lineCount
        if count == 0 { lines = []; return }
        while lines.count < count { lines.append(Line()) }
        if lines.count > count { lines.removeLast(lines.count - count) }
        for index in lines.indices {
            lines[index].connectorImpedance = Line.clamp(lines[index].connectorImpedance, 50, 100)
            lines[index].connectorHealth = Line.clamp(lines[index].connectorHealth, 0, 1)
            lines[index].tightness = Line.clamp(lines[index].tightness, 0, 1)
        }
        for index in interferences.indices {
            interferences[index].intensity = Line.clamp(interferences[index].intensity, 0, 1)
            interferences[index].distance = Line.clamp(interferences[index].distance, 0, 1)
        }
    }

    private static let storageKey = "tvCableSettings"
    public static func load(from defaults: UserDefaults = .standard) -> TVCableSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TVCableSettings.self, from: data) else {
            return .off
        }
        var value = decoded
        value.normalize()
        return value
    }
    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

public enum TVCableProcessor {
    private static func hash(_ index: Int, _ frame: Int64) -> Float {
        var x = UInt64(bitPattern: Int64(index) &* 2_654_435_761)
        x ^= UInt64(bitPattern: frame &* 40_503)
        x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
        return Float(x & 0xffff) / 65535
    }

    private static func gain(_ line: TVCableSettings.Line, cable: TVCableSettings) -> Float {
        guard line.connected else { return 0 }
        let cableHealth = Float(cable.cableHealth)
        let health = Float(line.connectorHealth)
        let tight = 0.35 + 0.65 * Float(line.tightness)
        let cablePenalty = max(0.15, 1 - Float(abs(cable.cableImpedance - 75)) / 50)
        let connectorPenalty = max(0.15, 1 - Float(abs(line.connectorImpedance - 75)) / 50)
        return min(1.2, max(0, 0.08 + 0.92 * cableHealth * health * tight * cablePenalty * connectorPenalty))
    }

    private static func ghost(_ line: TVCableSettings.Line, cable: TVCableSettings) -> Float {
        let mismatch = max(abs(line.connectorImpedance - 75),
                           abs(cable.cableImpedance - 75)) + (1 - line.tightness) * 25
        return min(0.22, Float(mismatch) / 120)
    }

    private static func interference(_ settings: TVCableSettings, y: Int, height: Int,
                                     index: Int, frame: Int64, noise: Float) -> Float {
        var value: Float = 0
        let row = Float(y) / Float(max(1, height))
        for source in settings.interferences where source.enabled {
            let strength = Float(source.intensity) * (1 - Float(source.distance) * 0.85)
            switch source.kind {
            case .mains:
                value += sin((row * 9 + Float(frame) * 0.035) * .pi * 2) * 0.10 * strength
            case .microwave:
                let band = sin((row * 31 + Float(frame) * 0.7) * .pi * 2)
                value += (band > 0.55 ? noise : noise * 0.35) * 0.30 * strength
            case .compressor:
                let pulse = max(0, sin((Float(frame) * 0.09 + row * 2) * .pi * 2))
                value += (pulse * 0.18 + noise * 0.08) * strength
            case .transformer:
                value += sin((row * 17 + Float(frame) * 0.02) * .pi * 2) * 0.16 * strength
                value += sin((row * 34 + Float(frame) * 0.04) * .pi * 2) * 0.05 * strength
            case .groundPotential:
                let roll = sin((row * 2.5 + Float(frame) * 0.012) * .pi * 2)
                value += (roll * 0.14 + noise * 0.05) * strength
            }
        }
        return value
    }

    public static func apply(_ rgb: [SIMD3<Float>], width: Int, height: Int,
                             settings: TVCableSettings, frameIndex: Int64) -> [SIMD3<Float>] {
        var settings = settings
        settings.normalize()
        guard settings.kind != .off, settings.kind.lineCount > 0,
              rgb.count == width * height else { return rgb }
        let kind = settings.kind
        let lines = settings.lines
        let yGain = kind == .component || kind == .sVideo ? gain(lines[0], cable: settings) : 1
        let cGain: Float
        let pbGain: Float
        let prGain: Float
        switch kind {
        case .component:
            cGain = 1
            pbGain = gain(lines[1], cable: settings)
            prGain = gain(lines[2], cable: settings)
        case .sVideo:
            cGain = gain(lines[1], cable: settings)
            pbGain = cGain; prGain = cGain
        default:
            cGain = 1; pbGain = 1; prGain = 1
        }

        if kind == .av || kind == .bnc {
            guard lines[0].connected else { return [SIMD3<Float>](repeating: .zero, count: rgb.count) }
            let gain = gain(lines[0], cable: settings)
            let ghost = ghost(lines[0], cable: settings)
            var result = [SIMD3<Float>](repeating: .zero, count: rgb.count)
            for y in 0..<height {
                let hum = interference(settings, y: y, height: height, index: 0,
                    frame: frameIndex, noise: 0)
                for x in 0..<width {
                    let i = y * width + x
                    let noise = (hash(i, frameIndex) - 0.5) * (1 - Float(settings.cableHealth)) * 0.22
                    var value = rgb[i] * gain + SIMD3<Float>(repeating: hum + noise)
                    if x > 0, ghost > 0 { value = value * (1 - ghost) + result[i - 1] * ghost }
                    result[i] = SIMD3(min(1, max(0, value.x)), min(1, max(0, value.y)), min(1, max(0, value.z)))
                }
            }
            return result
        }

        guard lines[0].connected else { return [SIMD3<Float>](repeating: .zero, count: rgb.count) }
        var result = [SIMD3<Float>](repeating: .zero, count: rgb.count)
        let ghostY = ghost(lines[0], cable: settings)
        let ghostColor = kind == .component
            ? max(ghost(lines[1], cable: settings), ghost(lines[2], cable: settings))
            : ghost(lines[1], cable: settings)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = rgb[i]
                let Y = 0.299 * p.x + 0.587 * p.y + 0.114 * p.z
                var Cb = (p.z - Y) / 1.772
                var Cr = (p.x - Y) / 1.402
                let noise = (hash(i, frameIndex) - 0.5) * (1 - Float(settings.cableHealth)) * 0.20
                let hum = interference(settings, y: y, height: height, index: i,
                    frame: frameIndex, noise: hash(i + 17, frameIndex) - 0.5)
                var luma = Y * yGain + hum + noise
                if kind == .component {
                    Cb *= pbGain
                    Cr *= prGain
                } else {
                    Cb *= cGain
                    Cr *= cGain
                }
                if x > 0 {
                    let previous = result[i - 1]
                    let previousY = 0.299 * previous.x + 0.587 * previous.y + 0.114 * previous.z
                    luma = luma * (1 - ghostY) + previousY * ghostY
                    Cb = Cb * (1 - ghostColor)
                    Cr = Cr * (1 - ghostColor)
                }
                let R = luma + 1.402 * Cr
                let B = luma + 1.772 * Cb
                let G = (luma - 0.299 * R - 0.114 * B) / 0.587
                result[i] = SIMD3(min(1, max(0, R)), min(1, max(0, G)), min(1, max(0, B)))
            }
        }
        return result
    }
}
