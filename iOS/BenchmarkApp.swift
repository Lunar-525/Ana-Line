import SwiftUI
import UIKit
import Darwin

private struct FrameSample: Codable, Sendable {
    var stagesMS: [String: Double]
    var index: Int64
    var elapsedSeconds: Double
    var processingMS: Double
    var encodeMS: Double
    var receiverMS: Double
    var imageConversionMS: Double
    var memoryMB: Double?
    var thermalState: Int
    var locked: Bool
    var recoveredLines: Int
    var audioValid: Bool
    /// P0/P1 telemetry: how this frame related to the previous one, and which
    /// carrier-recovery strategy the receiver actually used. These are the
    /// values that explain a damaged frame's cost.
    var continuity: String
    var carrierTracked: Bool
    var afcDecimation: Int
    var pllStride: Int
    /// Process CPU milliseconds consumed by this frame (all threads).
    var cpuMS: Double = 0
}
/// One measured case. The raw samples stay in the report; the summary below is
/// derived from them and stored as well, so a report can be read without
/// recomputing and so a partial run still carries usable numbers.
private struct CaseReport: Codable, Sendable {
    var system: String
    var scenario: String
    var budgetMS: Double
    /// Nominal frame rate of the standard this case transmits.
    var nominalFPS: Double
    var samples: [FrameSample] = []
    var meanMS: Double = 0
    var medianMS: Double = 0
    /// 95th percentile of the per-frame processing time.
    var p95MS: Double = 0
    var peakMS: Double = 0
    /// Capability rate: nominal frame budget divided by the mean processing
    /// time. Above 100% means the chain processes frames faster than the
    /// standard plays them, independently of whether the loop was paced.
    var rateMeanPercent: Double = 0
    /// Capability rate against the 95th percentile, i.e. the tail-safe rate.
    var rateP95Percent: Double = 0
    var overBudget: Int = 0
    var overBudgetPercent: Double = 0
    /// Frames actually delivered per wall-clock second of the case.
    var effectiveFPS: Double = 0
    /// Delivered frames per second against the standard, what a viewer sees.
    var playbackRatePercent: Double = 0
    /// Milliseconds the loop has fallen behind the ideal frame schedule at the
    /// last sample. Positive means the case could not be delivered on time.
    var lagMS: Double = 0
    var lockedFrames: Int = 0
    var measuredSeconds: Double = 0
    var peakMemoryMB: Double = 0
    /// Share of the case's samples spent in each thermal state, in percent.
    var thermalPercent: [String: Double] = [:]
    /// Mean per-stage time as a percentage of the frame budget: which stage eats
    /// the budget. Keys match FrameSample.stagesMS.
    var stagesBudgetPercent: [String: Double] = [:]
    /// Share of frames the receiver ran with the carrier tracked, and the share
    /// that used the reduced-rate estimate and phase feedback.
    var carrierTrackedPercent: Double = 0
    var afcDecimatedPercent: Double = 0
    var pllDecimatedPercent: Double = 0
    /// Frames that re-ran samples already consumed, and forward gaps. Both cost
    /// a whole frame each, so they belong next to the timing.
    var repeatFrames: Int = 0
    var gapFrames: Int = 0
    /// Engine time not attributed to any named stage: validation, allocation,
    /// the atomic candidate commit, thread dispatch and joins. This is the
    /// overhead P2 has to attack, so it is measured rather than assumed.
    var unattributedMS: Double = 0
    /// Mean CPU milliseconds per frame, and the parallelism that implies.
    var meanCPUMilliseconds: Double = 0
    var achievedParallelism: Double = 0

    static func continuityName(_ value: TVFrameContinuity) -> String {
        switch value {
        case .first: "first"
        case .continuous: "continuous"
        case .forwardGap: "forwardGap"
        case .repeatOrRewind: "repeat"
        }
    }

    private static let thermalNames = ["nominal","fair","serious","critical"]
    static func thermalName(_ state: Int) -> String {
        thermalNames.indices.contains(state) ? thermalNames[state] : "unknown"
    }

    /// Recompute every derived field from the samples. Called before each save.
    mutating func summarize() {
        guard !samples.isEmpty else { return }
        let values = samples.map(\.processingMS).sorted()
        let count = values.count
        meanMS = values.reduce(0,+)/Double(count)
        medianMS = values[count/2]
        p95MS = values[min(count-1,Int(Double(count-1)*0.95))]
        peakMS = values[count-1]
        rateMeanPercent = meanMS > 0 ? budgetMS/meanMS*100 : 0
        rateP95Percent = p95MS > 0 ? budgetMS/p95MS*100 : 0
        overBudget = values.filter { $0 > budgetMS }.count
        overBudgetPercent = Double(overBudget)/Double(count)*100
        measuredSeconds = samples.last?.elapsedSeconds ?? 0
        effectiveFPS = measuredSeconds > 0 ? Double(count)/measuredSeconds : 0
        playbackRatePercent = nominalFPS > 0 ? effectiveFPS/nominalFPS*100 : 0
        lagMS = max(0,(measuredSeconds-Double(count)/max(1,nominalFPS))*1000)
        lockedFrames = samples.filter(\.locked).count
        peakMemoryMB = samples.compactMap(\.memoryMB).max() ?? 0
        var thermal = [String: Int]()
        for sample in samples { thermal[Self.thermalName(sample.thermalState),default: 0] += 1 }
        thermalPercent = thermal.mapValues { Double($0)/Double(count)*100 }
        // combinationIncluded is already inside modulation, so it must not be
        // added a second time.
        let stageTotal = samples[0].stagesMS.keys.filter { $0 != "combinationIncluded" }.reduce(0.0) { total,key in
            total+samples.reduce(0.0) { $0+($1.stagesMS[key] ?? 0) }/Double(count)
        }
        let encodeTotal = samples.reduce(0.0) { $0+$1.encodeMS }/Double(count)
        let imageTotal = samples.reduce(0.0) { $0+$1.imageConversionMS }/Double(count)
        unattributedMS = meanMS-encodeTotal-imageTotal-stageTotal
        meanCPUMilliseconds = samples.reduce(0.0) { $0+$1.cpuMS }/Double(count)
        achievedParallelism = meanMS > 0 ? meanCPUMilliseconds/meanMS : 0
        carrierTrackedPercent = Double(samples.filter(\.carrierTracked).count)/Double(count)*100
        afcDecimatedPercent = Double(samples.filter { $0.afcDecimation > 1 }.count)/Double(count)*100
        pllDecimatedPercent = Double(samples.filter { $0.pllStride > 1 }.count)/Double(count)*100
        repeatFrames = samples.filter { $0.continuity == "repeat" }.count
        gapFrames = samples.filter { $0.continuity == "forwardGap" }.count
        var stages = [String: Double]()
        for key in samples[0].stagesMS.keys {
            let total = samples.reduce(0.0) { $0+($1.stagesMS[key] ?? 0) }
            stages[key] = total/Double(count)/budgetMS*100
        }
        stagesBudgetPercent = stages
    }

    /// The headline numbers, for the live status line and the console log.
    var rateLine: String {
        String(format:"速率 平均 %.0f%% · P95 %.0f%% · 交付 %.0f%% · 落后 %.0f ms",
               rateMeanPercent,rateP95Percent,playbackRatePercent,lagMS)
    }
}
private struct BenchmarkReport: Codable, Sendable {
    var schemaVersion = 3
    var optimizationVariant = TVOptimizationDiagnostics.baseline ? "baseline" : "decoder-and-tuner-v1"
    /// Cost/quality profile the chain ran with: "mobile" or "full".
    var chainProfile = "mobile"
    /// Receiver regime this run characterised, when one was selected.
    var regime: String?
    /// Whether the transmit and receive halves ran overlapped on two threads.
    var pipeline = false
    /// Parallel-stage ceiling and the QoS the DSP ran at, for sweeps.
    var parallelWorkers = TVParallelDiagnostics.workerLimitDescription
    var dspQoS = BenchmarkDiagnostics.qosName
    var startedAt = Date()
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var hardware = ""
    var durationPerCase: Double
    var completed = false
    var failure: String?
    var cases: [CaseReport] = []
    /// Present only for a --benchmark-metal run.
    var metalKernels: [MetalKernelMeasurement] = []
}
/// Launch-argument diagnostics. The worker ceiling lives in AnalogCore and is
/// read there; the QoS has to be applied by this app, on the thread that issues
/// the DSP work, because the parallel stages inherit it.
/// Process CPU time (all threads, user + system). Its increment per frame is the
/// real resource cost of a frame: dividing it by the frame time gives the
/// parallelism actually achieved, and dividing it by the usable core count gives
/// the floor that no scheduling change can beat.
func processCPUSeconds() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self,capacity: Int(count)) {
            task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds)+Double(info.user_time.microseconds)/1e6
        + Double(info.system_time.seconds)+Double(info.system_time.microseconds)/1e6
}

private enum BenchmarkDiagnostics {
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index+1 < arguments.count else { return nil }
        return arguments[index+1]
    }
    static let qosName = argument("--benchmark-qos") ?? "userInitiated"
    static let qos: DispatchQoS.QoSClass = {
        switch qosName {
        case "userInteractive": return .userInteractive
        case "default": return .default
        case "utility": return .utility
        case "background": return .background
        default: return .userInitiated
        }
    }()
    /// The DSP runs here so every concurrentPerform worker inherits this QoS.
    static let dspQueue = DispatchQueue.global(qos: qos)
}
private struct Preview: Sendable {
    var bytes: Data
    var width: Int
    var height: Int
}
/// The three receiver operating regimes the measurement plan asks to
/// characterise separately. These are receiver operating points, not changes to
/// the signal model: a settled lock, the capture edge where the reduced-rate
/// policy keeps switching, and sustained loss.
enum BenchmarkRegime: String, CaseIterable, Sendable {
    case lock, edge, loss
    var title: String {
        switch self {
        case .lock: "稳定锁定"
        case .edge: "捕获边缘"
        case .loss: "持续失锁"
        }
    }
    func apply(to settings: inout TerrestrialSettings) {
        switch self {
        case .lock:
            // Carrier centred and quiet: the AFC and PLL stay in the tracked
            // strategy for the whole case.
            settings.carrierToNoiseDB = 60
        case .edge:
            // Just inside the 150 kHz capture limit with echo and noise, so the
            // carrier alternates between captured and dropped and the frame cost
            // should show it.
            settings.tuningOffsetKHz = 140
            settings.carrierToNoiseDB = 26
            settings.echoGain = 0.2; settings.echoDelayMicroseconds = 6
            settings.echoPhaseDegrees = 30
        case .loss:
            // Far outside the capture range: the receiver stays in the dense
            // strategy for the whole case.
            settings.signalDB = -80
            settings.carrierToNoiseDB = 10
        }
    }
}

private struct CasePlan: Sendable {
    let system: TerrestrialSystem
    let title: String
    let scenario: String
    let settings: TerrestrialSettings
}

private enum BenchmarkRunner {
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds)+Double(c.attoseconds)/1e18
    }
    static func memoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint)/1_048_576 : nil
    }
    static func hardware() -> String {
        var value = utsname(); uname(&value)
        return withUnsafePointer(to: &value.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
    static func preview(_ frame: TVFrame) -> Preview {
        var data = Data(count: frame.rgb.count*4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for (n,pixel) in frame.rgb.enumerated() {
                for c in 0..<3 { bytes[n*4+c] = UInt8(max(0,min(255,pixel[c]*255))) }
                bytes[n*4+3] = 255
            }
        }
        return Preview(bytes: data,width: frame.standard.width,height: frame.standard.height)
    }
    static func save(_ report: BenchmarkReport, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url,options: .atomic)
    }
    /// The cases a run performs: either the two standards against the default
    /// and damaged scenarios, or the two standards against one regime.
    static func plans(chain: TVChainProfile, regime: BenchmarkRegime?) -> [CasePlan] {
        var plans = [CasePlan]()
        for system in TerrestrialSystem.allCases {
            if let regime {
                var settings = TerrestrialSettings(system: system)
                settings.performance = chain
                regime.apply(to: &settings)
                plans.append(CasePlan(system: system,title: "\(system.rawValue) / \(regime.title)",
                                      scenario: regime.rawValue,settings: settings))
                continue
            }
            for damaged in [false,true] {
                var settings = TerrestrialSettings(system: system)
                settings.performance = chain
                if damaged {
                    settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
                    settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
                    settings.transmitter.enabled = true
                    settings.transmitter.powerDB = 3
                    settings.transmitter.sharedCoupling = 0.15
                    settings.transmitter.encoder.enabled = true
                    settings.transmitter.encoder.differentialGain = 0.05
                    settings.transmitter.vsb.enabled = true
                    settings.receiverDamage.agcEnabled = true
                    settings.receiverDamage.syncEnabled = true
                    settings.propagation.enabled = true
                    settings.propagation.weather.enabled = true
                    settings.propagation.weather.rainMMHour = 10
                }
                plans.append(CasePlan(system: system,
                                      title: system.rawValue + (damaged ? " / 损伤" : " / 默认"),
                                      scenario: damaged ? "damaged" : "default",settings: settings))
            }
        }
        return plans
    }

    static func run(duration: Double, url: URL,
                    update: @escaping @Sendable (String, Preview?) async -> Void) async {
        // The phone-class chain profile is the point of this benchmark; pass
        // --benchmark-full to measure the reference chain for comparison.
        let chain: TVChainProfile = ProcessInfo.processInfo.arguments.contains("--benchmark-full")
            ? .full : .mobile
        let regime = BenchmarkDiagnostics.argument("--benchmark-regime").flatMap(BenchmarkRegime.init(rawValue:))
        var report = BenchmarkReport(hardware: hardware(),durationPerCase: duration)
        report.chainProfile = chain == .full ? "full" : "mobile"
        report.regime = regime?.rawValue
        // P2: run the transmit half of the next frame while this frame is being
        // received. Opt-in so the sequential path stays the reference.
        let usePipeline = ProcessInfo.processInfo.arguments.contains("--benchmark-pipeline")
        report.pipeline = usePipeline
        if ProcessInfo.processInfo.arguments.contains("--benchmark-metal") {
            // CPU-vs-GPU kernel comparison on this device, written into the same
            // report so one pull carries both.
            report.metalKernels = MetalBenchmark.run()
            for measurement in report.metalKernels {
                print("ANALINE_METAL \(measurement.system) \(measurement.kernel) samples=\(measurement.samples) cpu=\(measurement.cpuMS) gpu=\(measurement.gpuMS) error=\(measurement.maxError)")
            }
            try? save(report,to: url)
            await update("Metal 内核对比完成（\(report.metalKernels.count) 项），报告已保存。",nil)
            report.completed = true
            try? save(report,to: url)
            return
        }
        do {
            for plan in plans(chain: chain, regime: regime) {
                    try Task.checkCancellation()
                    let system = plan.system
                    let settings = plan.settings
                    var engine = TVUnifiedChannelEngine(system: system)
                    let pipeline = usePipeline
                        ? TVFramePipeline(system: system,qos: DispatchQoS(qosClass: BenchmarkDiagnostics.qos,relativePriority: 0))
                        : nil
                    var encodedSeconds = [Int64: Double]()
                    let source = TVFrame.colorBars(system.video)
                    let title = plan.title
                    await update(title+"：预热",nil)
                    var current = CaseReport(system: system.rawValue,scenario: plan.scenario,
                                             budgetMS: system.video.frameDuration*1000,
                                             nominalFPS: 1/system.video.frameDuration)
                    // Build one frame's input and audio. The pipeline needs the
                    // next frame's input before this frame's receive finishes.
                    func makeFrame(_ n: Int64) throws -> (CompositeVideo, [Float], Double) {
                        let audioOffset = TVSoundClock.offset(frame: n,standard: system.video)
                        let audio = (0..<TVSoundClock.count(frame: n,standard: system.video)).map {
                            Float(0.25*sin(2 * Double.pi * 1000 * Double(audioOffset+Int64($0))/48_000))
                        }
                        let encodedStart = ContinuousClock.now
                        let cvbs = try TVEngine.encode(source,frameIndex: n,damage: settings.transmitter.encoder)
                        return (cvbs,audio,seconds(encodedStart.duration(to: .now)))
                    }
                    func submit(_ n: Int64) throws {
                        let frame = try BenchmarkDiagnostics.dspQueue.sync { try makeFrame(n) }
                        encodedSeconds[n] = frame.2
                        try pipeline?.submit(frame.0,settings: settings,audio: frame.1)
                    }
                    /// Same frame, but built on the transmit thread so its encode
                    /// time is overlapped rather than serial with the receive pass.
                    func submitRequest(_ pipeline: TVFramePipeline, _ n: Int64) throws {
                        let encodedStart = ContinuousClock.now
                        try pipeline.submit(TVFrameRequest(frameIndex: n,settings: settings) { index in
                            let offset = TVSoundClock.offset(frame: index,standard: system.video)
                            let audio = (0..<TVSoundClock.count(frame: index,standard: system.video)).map {
                                Float(0.25*sin(2 * Double.pi * 1000 * Double(offset+Int64($0))/48_000))
                            }
                            return (try TVEngine.encode(source,frameIndex: index,damage: settings.transmitter.encoder),audio)
                        })
                        encodedSeconds[n] = seconds(encodedStart.duration(to: .now))
                    }
                    var index: Int64 = 0
                    var cpuSeconds = processCPUSeconds()
                    if pipeline != nil { try submit(0) }
                    var start = ContinuousClock.now
                    var lastUpdate = start
                    var lastSave = start
                    var nextDeadline = start
                    report.cases.append(current)
                    while index < 3 || seconds(start.duration(to: .now)) < duration {
                        try Task.checkCancellation()
                        let frameStart = ContinuousClock.now
                        let audioOffset = TVSoundClock.offset(frame: index,standard: system.video)
                        let audio = (0..<TVSoundClock.count(frame: index,standard: system.video)).map {
                            Float(0.25*sin(2 * Double.pi * 1000 * Double(audioOffset+Int64($0))/48_000))
                        }
                        // Encode and the whole RF chain run on the diagnostic QoS
                        // queue so every parallel stage inherits that QoS.
                        let outcome: (ContinuousClock.Instant, TerrestrialReception, ContinuousClock.Instant)
                        if let pipeline {
                            // Hand the next frame's transmit pass over before
                            // waiting for this frame, so the two halves overlap.
                            // Hand the *next* frame's construction to the
                            // transmit thread, where it overlaps this frame's
                            // receive pass instead of sitting on this thread.
                            if pipeline.pendingFrames == 0 {
                                try submitRequest(pipeline,index)
                            } else if pipeline.allowsLookahead {
                                try submitRequest(pipeline,index+1)
                            }
                            outcome = try BenchmarkDiagnostics.dspQueue.sync {
                                let received = ContinuousClock.now
                                let value = try pipeline.receive()
                                return (received,value,ContinuousClock.now)
                            }
                        } else {
                            outcome = try BenchmarkDiagnostics.dspQueue.sync {
                                () throws -> (ContinuousClock.Instant, TerrestrialReception, ContinuousClock.Instant) in
                                let encodedStart = ContinuousClock.now
                                let cvbs = try TVEngine.encode(source,frameIndex: index,damage: settings.transmitter.encoder)
                                let encoded = ContinuousClock.now
                                encodedSeconds[index] = seconds(encodedStart.duration(to: encoded))
                                return (encoded,try engine.process(cvbs,settings: settings,audio: audio),ContinuousClock.now)
                            }
                        }
                        let encoded = outcome.0, result = outcome.1, received = outcome.2
                        let pixels = preview(result.frame)
                        let finished = ContinuousClock.now
                        let valid = result.frame.rgb.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                            && result.audio.count == audio.count && result.audio.allSatisfy(\.isFinite)
                        guard valid else { throw TVError.invalidSignal }
                        let cpuNow = processCPUSeconds()
                        let frameCPUMS = (cpuNow-cpuSeconds)*1000
                        cpuSeconds = cpuNow
                        if index >= 3 {
                            let t = result.timings
                            let stages = ["modulation": t.modulation, "combinationIncluded": t.channelCombination,
                                "channel": t.channel, "tunerIF": t.tuner, "carrierEstimation": t.carrierEstimation,
                                "carrierPLL": t.carrierPLL, "synchronization": t.synchronization,
                                "videoDecode": t.videoDecode, "soundExtraction": t.soundExtraction,
                                "soundDemodulation": result.soundSeconds].mapValues { $0*1000 }
                            current.samples.append(FrameSample(stagesMS: stages,index: index,
                                elapsedSeconds: seconds(start.duration(to: finished)),
                                processingMS: seconds(frameStart.duration(to: finished))*1000,
                                encodeMS: (encodedSeconds[index] ?? 0)*1000,
                                receiverMS: seconds(encoded.duration(to: received))*1000,
                                imageConversionMS: seconds(received.duration(to: finished))*1000,
                                memoryMB: memoryMB(),thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                                locked: result.lock == .locked,recoveredLines: result.recoveredLines,audioValid: valid,
                                continuity: CaseReport.continuityName(result.frameContinuity),
                                carrierTracked: result.carrierTracked,
                                afcDecimation: result.carrierEstimationDecimation,
                                pllStride: result.carrierPLLStrideUsed,
                                cpuMS: frameCPUMS))
                        }
                        if index == 2 { start = .now; lastUpdate = start; lastSave = start; nextDeadline = start }
                        if seconds(lastUpdate.duration(to: finished)) >= 1 {
                            let elapsed = seconds(start.duration(to: finished))
                            current.summarize()
                            let status = String(format: "%@\n%.0f / %.0f 秒 · 平均 %.1f ms · P95 %.1f ms · 峰值 %.1f ms\nCPU %.1f ms/帧（并行度 %.2f×）\n%@\n超预算 %d / %d (%.0f%%) · 热状态 %d",
                                title,elapsed,duration,current.meanMS,current.p95MS,current.peakMS,
                                current.meanCPUMilliseconds,current.achievedParallelism,current.rateLine,
                                current.overBudget,current.samples.count,current.overBudgetPercent,
                                ProcessInfo.processInfo.thermalState.rawValue)
                            await update(status,pixels)
                            report.cases[report.cases.count-1] = current
                            // Saving the whole report is expensive (tens of MB with
                            // every frame sampled). Do it rarely: the measured
                            // per-frame time is unaffected, but the achieved frame
                            // rate is not, and a benchmark must not throttle itself
                            // with its own I/O.
                            if seconds(lastSave.duration(to: finished)) >= 15 {
                                try save(report,to: url)
                                lastSave = .now
                            }
                            lastUpdate = .now
                        }
                        index += 1
                        // Pace to the standard when possible; retain consecutive RF state when overloaded.
                        // Over-budget frames are diagnostics, not measured playback drops.
                        nextDeadline += .seconds(system.video.frameDuration)
                        if nextDeadline > .now { try await Task.sleep(until: nextDeadline,clock: .continuous) }
                    }
                    current.summarize()
                    report.cases[report.cases.count-1] = current
                    try save(report,to: url)
                    print("ANALINE_CASE \(title) mean=\(current.meanMS) p95=\(current.p95MS) peak=\(current.peakMS) overBudget=\(current.overBudget)/\(current.samples.count) rate=\(current.rateMeanPercent) playback=\(current.playbackRatePercent) lag=\(current.lagMS)")
            }
            report.completed = true
            try save(report,to: url)
            await update("测试完成。报告已保存，可分享导出。",nil)
            print("ANALINE_BENCHMARK_COMPLETE")
        } catch {
            report.failure = error.localizedDescription
            try? save(report,to: url)
            await update(error is CancellationError ? "测试已停止，已保存最近一次记录。" : "测试失败：\(error.localizedDescription)",nil)
        }
    }
}
@MainActor private final class BenchmarkModel: ObservableObject {
    @Published var status = "就绪：彩条 + 1 kHz 伴音，统一 RF 信号链"
    @Published var image: UIImage?
    @Published var running = false
    @Published var reportAvailable = false
    var task: Task<Void,Never>?
    let url = URL.documentsDirectory.appendingPathComponent("benchmark.json")
    func start(duration: Double) {
        guard !running else { return }
        running = true; reportAvailable = false
        UIApplication.shared.isIdleTimerDisabled = true
        let reportURL = url
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await BenchmarkRunner.run(duration: duration,url: reportURL) { [weak self] status,preview in
                await self?.receive(status,preview)
            }
            await self?.finish()
        }
    }
    func receive(_ text: String, _ preview: Preview?) {
        status = text
        if let p = preview, let provider = CGDataProvider(data: p.bytes as CFData),
           let cg = CGImage(width: p.width,height: p.height,bitsPerComponent: 8,bitsPerPixel: 32,
                bytesPerRow: p.width*4,space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),provider: provider,
                decode: nil,shouldInterpolate: false,intent: .defaultIntent) { image = UIImage(cgImage: cg) }
    }
    func finish() {
        running = false; reportAvailable = FileManager.default.fileExists(atPath: url.path)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func stop() { task?.cancel() }
}
@main struct AnaLineBenchmarkApp: App {
    @StateObject private var model = BenchmarkModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading,spacing: 20) {
                    Text("AnaLine · iOS Benchmark").font(.title2.bold())
                    if let image = model.image {
                        Image(uiImage: image).resizable().aspectRatio(4.0/3.0,contentMode: .fit)
                    } else { Rectangle().fill(.black).aspectRatio(4.0/3.0,contentMode: .fit) }
                    Text(model.status).font(.system(.body,design: .monospaced))
                    Text("依次测试 PAL／NTSC 的默认与损伤场景。每帧执行编码、统一 RF 音画接收与图像转换。伴音参与计算，暂不播放。预览每秒更新一次。报告里的速率百分比：能力速率 = 帧预算 ÷ 平均耗时（>100% 表示有实时余量），交付速率 = 实际每秒出帧 ÷ 标准帧率，落后 = 相对标准时间轴累计落后毫秒数。启动参数：--benchmark-full 参考档位、--benchmark-workers N 限制并行工作线程、--benchmark-qos userInteractive 调整 DSP 线程 QoS、--benchmark-baseline 旧版 A/B。保持 App 在前台；切到后台会停止测试。").font(.footnote).foregroundStyle(.secondary)
                    if model.running { Button("停止测试",role: .destructive) { model.stop() } }
                    else {
                        Button("快速测试（约 2 分钟）") { model.start(duration: 30) }.buttonStyle(.borderedProminent)
                        Button("持续测试（约 12 分钟）") { model.start(duration: 180) }.buttonStyle(.bordered)
                    }
                    if model.reportAvailable { ShareLink("导出 JSON 报告",item: model.url) }
                }.padding()
            }
            .onChange(of: scenePhase) { _,phase in if phase == .background { model.stop() } }
            .task {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--benchmark-metal") { model.start(duration: 1) }
                if args.contains("--benchmark-profile") { model.start(duration: 8) }
                if args.contains("--benchmark-quick") { model.start(duration: 30) }
                if args.contains("--benchmark-sustained") { model.start(duration: 180) }
            }
        }
    }
}
