import Foundation

public enum FilmLabStage: Int, Codable, CaseIterable, Sendable {
    case exposure, development, stop, fixation, wash, drying, scan
    public var title: String { ["曝光", "显影", "停显", "定影", "水洗", "干燥", "扫描成像"][rawValue] }
    public var symbol: String { ["sun.max", "flask", "hand.raised", "drop.halffull", "water.waves", "wind", "scanner"][rawValue] }
    public var defaultDuration: Float { [1, 600, 30, 180, 600, 900, 0][rawValue] }
}

public enum FilmDeveloper: String, Codable, CaseIterable, Sendable {
    case id11 = "ILFORD ID-11", perceptol = "ILFORD PERCEPTOL", microphen = "ILFORD MICROPHEN", ddx = "ILFOTEC DD-X"
    public var dilutions: [Int] { self == .ddx ? [4] : [0, 1, 3] }
    public var description: String {
        switch self {
        case .id11: "细颗粒、锐度与层次均衡；保持有效感度。"
        case .perceptol: "超细颗粒；以部分有效感度换取细腻影像。"
        case .microphen: "较高有效感度；适合高速胶片及延长显影。"
        case .ddx: "液体浓缩型；细颗粒并保持充分感度。"
        }
    }
    /// Relative coefficients are model estimates, not published chemical rate constants.
    public var activity: Float { switch self { case .id11: 1; case .perceptol: 0.78; case .microphen: 1.12; case .ddx: 1.08 } }
    public var sensitivity: Float { switch self { case .id11: 1; case .perceptol: 0.65; case .microphen: 1.3; case .ddx: 1.05 } }
    public var grain: Float { switch self { case .id11: 1; case .perceptol: 0.65; case .microphen: 0.95; case .ddx: 0.85 } }
    public var sourceURL: String {
        self == .ddx ? "https://www.ilfordphoto.com/wp/wp-content/uploads/2019/08/ILFOTEC-DDX-AUG19.pdf"
        : "https://www.ilfordphoto.com/amfile/file/download/file/1829/product/2153/"
    }
}

public struct FilmLabRecipe: Codable, Hashable, Sendable {
    public var exposureEV: Float = 0
    public var kelvin: Float = 5500
    public var lightLeak: Float = 0
    public var developer: FilmDeveloper = .id11
    public var dilution: Int = 0
    public var temperature: Float = 20
    public var agitation: Float = 0.6
    public var strength: Float = 1
    public var freshness: Float = 1
    public var flow: Float = 0.6
    public var humidity: Float = 0.45
    public var airflow: Float = 0.5
    public var minerals: Float = 0.05
    public var dust: Float = 0.02
    public init() {}
    public var validated: Self {
        func clamp(_ x: Float,_ a: Float,_ b: Float,_ fallback: Float) -> Float { x.isFinite ? min(b,max(a,x)) : fallback }
        var r = self
        r.exposureEV = clamp(r.exposureEV,-6,6,0); r.kelvin = clamp(r.kelvin,2000,12000,5500)
        r.lightLeak = clamp(r.lightLeak,0,1,0)
        if !r.developer.dilutions.contains(r.dilution) { r.dilution = r.developer.dilutions[0] }
        r.temperature = clamp(r.temperature,10,45,20); r.agitation = clamp(r.agitation,0,1,0.6)
        r.strength = clamp(r.strength,0,2,1); r.freshness = clamp(r.freshness,0,1,1)
        r.flow = clamp(r.flow,0,1,0.6); r.humidity = clamp(r.humidity,0,0.99,0.45)
        r.airflow = clamp(r.airflow,0,1,0.5); r.minerals = clamp(r.minerals,0,1,0.05)
        r.dust = clamp(r.dust,0,1,0.02)
        return r
    }
}

public struct FilmLabOperation: Codable, Hashable, Sendable {
    public var stage: FilmLabStage
    public var seconds: Float
    public var recipe: FilmLabRecipe
    public init(stage: FilmLabStage, seconds: Float, recipe: FilmLabRecipe) {
        self.stage = stage; self.seconds = seconds; self.recipe = recipe.validated
    }
}

public struct FilmLabCheckpoint: Codable, Hashable, Sendable {
    public var stage: FilmLabStage
    public var operationCount: Int
    public var recipe: FilmLabRecipe
    public var scanEV: Float
    public var scanContrast: Float
    public var seed: UInt32
}

/// A deterministic event log. A changed bath condition only affects future operations.
public struct FilmLabSession: Codable, Hashable, Sendable {
    public var stage: FilmLabStage = .exposure
    public var recipe = FilmLabRecipe()
    public private(set) var operations: [FilmLabOperation] = []
    public private(set) var checkpoints: [FilmLabCheckpoint] = []
    public var scanEV: Float = 0
    public var scanContrast: Float = 1
    public var seed: UInt32 = 137
    public init() {}
    public var elapsed: Float { operations.filter { $0.stage == stage }.reduce(0) { $0+$1.seconds } }
    public var canAdvance: Bool { stage != .scan && elapsed > 0 }
    public var canUndo: Bool { !checkpoints.isEmpty }
    public mutating func advance(seconds: Float) {
        guard stage != .scan, seconds.isFinite, seconds > 0, elapsed < 7200 else { return }
        let amount = min(seconds,7200-elapsed), r = recipe.validated
        if let last = operations.last, last.stage == stage, last.recipe == r {
            operations[operations.count-1].seconds += amount
        } else { operations.append(.init(stage: stage,seconds: amount,recipe: r)) }
    }
    /// Rewind only this stage, removing later conditions and replaying the retained prefix.
    public mutating func rewind(seconds: Float) {
        guard stage != .scan, seconds.isFinite, seconds > 0 else { return }
        var remaining = min(seconds,elapsed)
        guard remaining > 0 else { return }
        while remaining > 0, let last = operations.last, last.stage == stage {
            if last.seconds <= remaining {
                remaining -= last.seconds; operations.removeLast()
            } else {
                operations[operations.count-1].seconds -= remaining; remaining = 0
            }
        }
        recipe = operations.last?.stage == stage ? operations.last!.recipe : entryRecipe
    }
    public mutating func complete() {
        guard canAdvance, let next = FilmLabStage(rawValue: stage.rawValue+1) else { return }
        checkpoints.append(.init(stage: stage,operationCount: entryOperationCount,recipe: entryRecipe,scanEV: entryScanEV,scanContrast: entryScanContrast,seed: entrySeed))
        stage = next
        entryOperationCount = operations.count; entryRecipe = recipe
        entryScanEV = scanEV; entryScanContrast = scanContrast; entrySeed = seed
    }
    private var entryOperationCount = 0
    private var entryRecipe = FilmLabRecipe()
    private var entryScanEV: Float = 0
    private var entryScanContrast: Float = 1
    private var entrySeed: UInt32 = 137
    public mutating func undo() {
        guard let previous = checkpoints.popLast() else { return }
        stage = previous.stage
        operations = Array(operations.prefix(previous.operationCount))
        recipe = previous.recipe
        scanEV = previous.scanEV; scanContrast = previous.scanContrast; seed = previous.seed
        entryScanEV = scanEV; entryScanContrast = scanContrast; entrySeed = seed
        entryOperationCount = previous.operationCount; entryRecipe = previous.recipe
    }
    public var grainScale: Float {
        operations.last(where: { $0.stage == .development })?.recipe.developer.grain ?? 1
    }
}

/// Two finite-volume cells through the emulsion depth. Silver + halide + removed = 1.
public struct FilmLabState: Sendable {
    public var latent: Float = 0
    public var silver = SIMD2<Float>(repeating: 0)
    public var halide = SIMD2<Float>(repeating: 1)
    public var developer = SIMD2<Float>(repeating: 0)
    public var acid = SIMD2<Float>(repeating: 0)
    public var fixer = SIMD2<Float>(repeating: 0)
    public var residue = SIMD2<Float>(repeating: 0)
    public var water: Float = 0
    public var deposit: Float = 0
    public var dust: Float = 0
    public init() {}
    public var silverMean: Float { (silver.x+silver.y)*0.5 }
    public var halideMean: Float { (halide.x+halide.y)*0.5 }
    public var residueMean: Float { (residue.x+residue.y)*0.5 }
}

public enum FilmLabPhysics {
    /// Planck-law three-band approximation normalized to the 5500 K reference.
    public static func spectralWeights(kelvin: Float) -> SIMD3<Float> {
        let t = min(12000,max(2000,kelvin.isFinite ? kelvin : 5500))
        func band(_ nm: Float,_ temp: Float) -> Float {
            let m = nm*1e-9
            return 1 / (pow(nm/550,5)*expm1(0.01438777/(m*temp)))
        }
        var w = SIMD3<Float>(band(610,t)/band(610,5500),band(550,t)/band(550,5500),band(460,t)/band(460,5500))
        w /= (w.x+w.y+w.z)/3
        return w
    }
    public static func hash(_ x: Float,_ y: Float,_ seed: UInt32) -> Float {
        var v = UInt32(bitPattern: Int32(floor(x))) &* 0x9e3779b9
        v ^= UInt32(bitPattern: Int32(floor(y))) &* 0x85ebca6b
        v ^= seed
        v ^= v >> 16; v &*= 0x7feb352d; v ^= v >> 15; v &*= 0x846ca68b; v ^= v >> 16
        return Float(v >> 8)/16777216
    }
    /// The same split diffusion/reaction equations are used by the Metal renderer.
    public static func apply(_ operation: FilmLabOperation, to state: inout FilmLabState,
                             rgb: SIMD3<Float>, position: SIMD2<Float>, seed: UInt32) {
        let r = operation.recipe.validated
        let duration = min(7200,max(0,operation.seconds))
        let w = spectralWeights(kelvin: r.kelvin)
        if operation.stage == .exposure {
            let light = max(0,(rgb.x*w.x*0.28+rgb.y*w.y*0.52+rgb.z*w.z*0.2)*pow(2,r.exposureEV))
            let leak = r.lightLeak*exp(-position.x*12)*2
            state.latent = 1-(1-state.latent)*exp(-(light+leak)*duration*2)
            return
        }
        let steps = max(1,Int(ceil(duration/5)))
        let dt = duration/Float(steps)
        let q = pow(2,(r.temperature-20)/10)
        let streak = 1-pow(1-r.agitation,2)*0.6*hash(floor(position.x*32),0,seed)
        let supply = (0.002+0.07*r.agitation)*q*streak
        func diffuse(_ v: inout SIMD2<Float>,_ bath: Float,_ rate: Float) {
            v.x += (bath-v.x)*(1-exp(-rate*dt))
            let transfer = (v.x-v.y)*0.5*(1-exp(-0.025*q*dt))
            v.x -= transfer; v.y += transfer
        }
        for _ in 0..<steps {
            switch operation.stage {
            case .development:
                let dilution = r.developer == .ddx ? 1 : 1/Float(1+r.dilution)*1.0
                diffuse(&state.developer,r.strength*r.freshness*dilution,supply)
                state.water = 1
            case .stop:
                diffuse(&state.developer,0,supply)
                diffuse(&state.acid,r.strength,supply*2)
                let neutralized = state.developer*(SIMD2<Float>(repeating: 1)-SIMD2(exp(-state.acid.x*0.3*dt),exp(-state.acid.y*0.3*dt)))
                state.developer -= neutralized
                state.acid = SIMD2(max(0,state.acid.x-neutralized.x),max(0,state.acid.y-neutralized.y))
            case .fixation:
                diffuse(&state.developer,0,supply); diffuse(&state.acid,0,supply)
                diffuse(&state.fixer,r.strength*r.freshness,supply)
                let removed = state.halide * (SIMD2<Float>(repeating: 1)-SIMD2(exp(-0.035*q*state.fixer.x*dt),exp(-0.035*q*state.fixer.y*dt)))
                state.halide -= removed; state.residue += removed*0.7
                diffuse(&state.residue,r.strength*0.2,supply*0.3)
            case .wash:
                let exchange = (0.001+0.09*r.flow)*q
                diffuse(&state.developer,0,exchange); diffuse(&state.acid,0,exchange)
                diffuse(&state.fixer,0,exchange); diffuse(&state.residue,0,exchange)
            case .drying:
                let lost = state.water*(1-exp(-0.008*q*(1-r.humidity)*(0.2+r.airflow)*dt))
                state.water -= lost
                state.deposit += lost*(r.minerals*0.4+state.residueMean*0.6)
                state.dust += (1-exp(-r.dust*0.0006*dt))*(0.2+state.water)
            default: break
            }
            if operation.stage.rawValue <= FilmLabStage.drying.rawValue {
                let sensitivity = r.developer.sensitivity
                let rate = 0.012*q*r.developer.activity*max(0,state.water)*(0.015+state.latent*sensitivity)
                let converted = state.halide*(SIMD2<Float>(repeating: 1)-SIMD2(exp(-rate*state.developer.x*dt),exp(-rate*state.developer.y*dt)))
                state.silver += converted; state.halide -= converted
                state.developer = SIMD2(max(0,state.developer.x-converted.x*0.65),max(0,state.developer.y-converted.y*0.65))
            }
        }
    }
    public static func replay(_ session: FilmLabSession,rgb: SIMD3<Float> = SIMD3(repeating: 0.18),position: SIMD2<Float> = SIMD2(repeating: 0.5)) -> FilmLabState {
        var state = FilmLabState()
        for op in session.operations { apply(op,to: &state,rgb: rgb,position: position,seed: session.seed) }
        return state
    }
}
