import XCTest
import CoreGraphics
import ImageIO
@testable import AnalogCore
@testable import AnalogImaging

final class SSTVTests: XCTestCase {
    private func bars() -> SSTVFrame {
        let colors: [SIMD3<Float>] = [SIMD3(1,1,1),SIMD3(1,1,0),SIMD3(0,1,1),SIMD3(0,1,0),SIMD3(1,0,1),SIMD3(1,0,0),SIMD3(0,0,1),.zero]
        return SSTVFrame(rgb: (0..<76800).map { colors[($0%320)/40] })
    }
    private func error(_ a: SSTVFrame,_ b: SSTVFrame) -> Float {
        zip(a.rgb,b.rgb).reduce(0) { total,p in
            let d = p.0-p.1; return total+abs(d.x)+abs(d.y)+abs(d.z)
        }/Float(a.rgb.count*3)
    }
    func testRobot36TimingColorAndDamage() throws {
        let input = bars(), start = Date()
        let tx = try SSTVEngine.encode(input), encoded = Date()
        XCTAssertEqual(tx.duration,36.91,accuracy: 1.0/12000)
        let clean = try SSTVEngine.receive(tx,settings: SSTVSettings())
        print(String(format: "SSTV benchmark TX %.1f ms RX %.1f ms MAE %.5f",encoded.timeIntervalSince(start)*1000,Date().timeIntervalSince(encoded)*1000,error(input,clean)))
        XCTAssertLessThan(error(input,clean),0.025)
        for x in stride(from: 20,to: 320,by: 40) {
            for c in 0..<3 { XCTAssertEqual(clean.rgb[100*320+x][c],input.rgb[100*320+x][c],accuracy: 0.025) }
        }
        var s = SSTVSettings(); s.noise = 0.6
        let noisy = try SSTVEngine.receive(tx,settings: s)
        XCTAssertEqual(noisy.rgb,try SSTVEngine.receive(tx,settings: s).rgb)
        s.seed += 1; XCTAssertGreaterThan(error(noisy,try SSTVEngine.receive(tx,settings: s)),0.01)
        let modifications: [(inout SSTVSettings) -> Void] = [
            { $0.noise = 0.5 },{ $0.frequencyOffset = 150 },{ $0.drift = 300 },
            { $0.clockPPM = 2000 },{ $0.dropout = 0.5 },{ $0.interference = 0.8; $0.interferenceHz = 1800 }
        ]
        for modify in modifications {
            var settings = SSTVSettings(); modify(&settings)
            let damaged = try SSTVEngine.receive(tx,settings: settings)
            XCTAssertGreaterThan(error(clean,damaged),0.005)
            XCTAssertTrue(damaged.rgb.allSatisfy { p in (0..<3).allSatisfy { p[$0].isFinite && (0...1).contains(p[$0]) } })
            settings.mix = 0
            XCTAssertEqual(try SSTVEngine.receive(tx,settings: settings).rgb,input.rgb)
        }
        s = SSTVSettings(); s.clockPPM = 400
        let fixed = try SSTVEngine.receive(tx,settings: s)
        s.trackSync = true
        let tracked = try SSTVEngine.receive(tx,settings: s)
        XCTAssertLessThan(error(input,tracked),error(input,fixed))
    }
    func testRendererCachingAndSourceReset() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let renderer = SSTVRenderer()
        try await renderer.loadSource(Data(contentsOf: root.appendingPathComponent("Assets/bliss.jpg")))
        let first = try await renderer.render(SSTVSettings())
        XCTAssertFalse(first.txCached); XCTAssertEqual(first.image.width,320); XCTAssertEqual(first.image.height,240)
        var settings = SSTVSettings(); settings.frequencyOffset = 100
        let cached = try await renderer.render(settings)
        XCTAssertTrue(cached.txCached)
        print(String(format: "SSTV Bliss TX %.1f ms / RX %.1f ms / cached RX %.1f ms",first.txSeconds*1000,first.rxSeconds*1000,cached.rxSeconds*1000))
        // Optional review artifacts, outside normal test runs.
        if let folder = ProcessInfo.processInfo.environment["ANALINE_SSTV_ARTIFACTS"] {
            try FileManager.default.createDirectory(atPath: folder,withIntermediateDirectories: true)
            for (name,image) in [("original",first.original),("clean",first.image),("offset",cached.image)] {
                let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder+"/"+name+".png") as CFURL,"public.png" as CFString,1,nil)!
                CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
        try await renderer.loadSource(Data(contentsOf: root.appendingPathComponent("Assets/bliss.jpg")))
        let reset = try await renderer.render(settings)
        XCTAssertFalse(reset.txCached)
    }
    func testSettingsValidation() {
        var s = SSTVSettings(); s.noise = .nan; s.frequencyOffset = .infinity; s.mix = -2; s.clockPPM = 100000
        s = s.validated
        XCTAssertEqual(s.noise,0); XCTAssertEqual(s.frequencyOffset,0); XCTAssertEqual(s.mix,0); XCTAssertEqual(s.clockPPM,3000)
    }
    func testIndependentPySSTVEncoding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let runs: [[Double]] }
        let fixture = try JSONDecoder().decode(Fixture.self,from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/robot36-pysstv-bars.json")))
        var frequency = [Float](), seconds: Double = 0
        for run in fixture.runs {
            seconds += run[1]
            let count = Int((seconds*12000).rounded())-frequency.count
            frequency.append(contentsOf: repeatElement(Float(run[0]),count: count))
        }
        let input = bars(), tx = try SSTVEngine.encode(input)
        XCTAssertEqual(tx.samples.count,frequency.count)
        let decoded = SSTVEngine.decodeFrequencies(frequency,original: input,settings: SSTVSettings())
        XCTAssertLessThan(error(input,decoded),0.012) // Pillow's integer YCbCr rounding is independent.
        var previous = SIMD2<Float>(1,0), totalError: Float = 0
        for (i,v) in tx.samples.enumerated() {
            let f = 1900+atan2(v.y*previous.x-v.x*previous.y,v.x*previous.x+v.y*previous.y)*12000/(2*Float.pi)
            totalError += abs(f-frequency[i]); previous = v
        }
        // Independent TX reference checks VIS, all porches, sync and alternating Cr/Cb.
        XCTAssertLessThan(totalError/Float(frequency.count),3)
    }
    func testStreamingEquivalenceAndCommittedRows() throws {
        let tx = try SSTVEngine.encode(bars())
        var settings = SSTVSettings(); settings.noise = 0.2; settings.frequencyOffset = 50; settings.clockPPM = 100
        let whole = try SSTVEngine.receive(tx,settings: settings)
        var streaming = SSTVReceiver(transmission: tx)
        for end in stride(from: 1200,to: tx.samples.count,by: 1200) {
            try streaming.advance(to: end,settings: settings)
            _ = streaming.snapshot(settings: settings)
        }
        try streaming.advance(to: tx.samples.count,settings: settings)
        XCTAssertEqual(streaming.snapshot(settings: settings).rgb,whole.rgb)
        XCTAssertEqual(streaming.receivedRows,240); XCTAssertTrue(streaming.complete)
        var session = SSTVReceiver(transmission: tx)
        try session.advance(to: 10920+120*1800,settings: SSTVSettings())
        let before = session.snapshot(settings: SSTVSettings())
        XCTAssertEqual(session.receivedRows,120)
        XCTAssertTrue(before.rgb[(120*320)...].allSatisfy { $0 == .zero })
        var changed = SSTVSettings(); changed.frequencyOffset = 200
        try session.advance(to: tx.samples.count,settings: changed)
        let after = session.snapshot(settings: changed)
        XCTAssertEqual(Array(before.rgb[..<(120*320)]),Array(after.rgb[..<(120*320)]))
        XCTAssertNotEqual(Array(before.rgb[..<(120*320)]),Array(after.rgb[(120*320)...]))
    }
    func testActualMicrophoneWaveformAndResampling() throws {
        let tx = try SSTVEngine.encode(bars())
        func tone(_ hz: Float) -> [Float] { (0..<1200).map { 0.5*sin(2*Float.pi*hz*Float($0)/12000) } }
        let a = tone(1600), b = tone(2200)
        var mixerA = SSTVMicrophoneMixer(), mixerB = SSTVMicrophoneMixer()
        let micA = mixerA.convert(a), micB = mixerB.convert(b)
        var receiverA = SSTVReceiver(transmission: tx), receiverB = SSTVReceiver(transmission: tx)
        try receiverA.advance(to: tx.samples.count,settings: SSTVSettings(),microphone: micA,micGain: 4)
        try receiverB.advance(to: tx.samples.count,settings: SSTVSettings(),microphone: micB,micGain: 4)
        let frameA = receiverA.snapshot(settings: SSTVSettings()), frameB = receiverB.snapshot(settings: SSTVSettings())
        XCTAssertGreaterThan(error(frameA,frameB),0.05) // Similar RMS, distinct actual waveforms.
        XCTAssertGreaterThan(error(frameA,bars()),0.05)
        var zero = SSTVReceiver(transmission: tx)
        try zero.advance(to: tx.samples.count,settings: SSTVSettings(),microphone: micA,micGain: 0)
        XCTAssertEqual(zero.snapshot(settings: SSTVSettings()).rgb,try SSTVEngine.receive(tx,settings: SSTVSettings()).rgb)
        let pcm = (0..<44100).map { Float(sin(2*Double.pi*1600*Double($0)/44100)) }
        var resampler = SSTVPCMResampler(), chunked = SSTVPCMResampler()
        let entire = resampler.convert(pcm,inputRate: 44100)
        var pieces = [Float]()
        for start in stride(from: 0,to: pcm.count,by: 1024) {
            pieces += chunked.convert(Array(pcm[start..<min(start+1024,pcm.count)]),inputRate: 44100)
        }
        XCTAssertEqual(entire,pieces); XCTAssertEqual(entire.count,12000)
        let receiver = SSTVReceiver(transmission: tx)
        let audio = receiver.txAudio(in: 0..<3600)
        for i in stride(from: 0,to: 3600,by: 17) {
            XCTAssertEqual(audio[i],0.2*Float(cos(2*Double.pi*1900*Double(i+1)/12000)),accuracy: 0.0001)
        }
    }
    func testLiveRendererSessionInvalidation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let renderer = SSTVRenderer()
        try await renderer.loadSource(Data(contentsOf: root.appendingPathComponent("Assets/bliss.jpg")))
        let session = try await renderer.beginTransmission()
        let partial = try await renderer.advanceTransmission(session: session,to: 10,settings: SSTVSettings(),microphone: [],micGain: 0,monitor: true)
        XCTAssertFalse(partial.complete); XCTAssertGreaterThan(partial.rows,0); XCTAssertLessThan(partial.rows,240)
        XCTAssertEqual(partial.audio.count,120000)
        await renderer.endTransmission()
        do {
            _ = try await renderer.advanceTransmission(session: session,to: 20,settings: SSTVSettings(),microphone: [],micGain: 0,monitor: false)
            XCTFail("Ended session must reject stale work")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testTimeVaryingChannelReproducibility() throws {
        var settings = SSTVSettings()
        settings.noise = 0.25; settings.frequencyOffset = 30; settings.drift = 100
        settings.clockPPM = 300; settings.interference = 0.2; settings.dropout = 0.15
        settings.variation = 0.8; settings.variationSeconds = 0.7
        let states = stride(from: 0,to: 442920,by: 1200).map {
            SSTVChannelState.at(sample: $0,total: 442920,settings: settings)
        }
        XCTAssertGreaterThan(Set(states.map(\.noise)).count,100)
        XCTAssertGreaterThan(Set(states.map(\.clockPPM)).count,100)
        XCTAssertGreaterThan(Set(states.map(\.gain)).count,100)
        XCTAssertTrue(states.allSatisfy { $0.gain > 0 && $0.gain <= 1 && $0.noise >= 0 })
        let input = bars(), tx = try SSTVEngine.encode(input)
        let whole = try SSTVEngine.receive(tx,settings: settings)
        var streaming = SSTVReceiver(transmission: tx)
        // Deliberately don't align chunks with the 10ms channel control grid.
        for end in stride(from: 7919,to: tx.samples.count,by: 7919) {
            try streaming.advance(to: end,settings: settings)
            _ = streaming.snapshot(settings: settings)
        }
        try streaming.advance(to: tx.samples.count,settings: settings)
        XCTAssertEqual(streaming.snapshot(settings: settings).rgb,whole.rgb)
        XCTAssertEqual(whole.rgb,try SSTVEngine.receive(tx,settings: settings).rgb)
        var other = settings; other.seed += 1
        XCTAssertGreaterThan(error(whole,try SSTVEngine.receive(tx,settings: other)),0.01)
        other = settings; other.variation = 0
        XCTAssertGreaterThan(error(whole,try SSTVEngine.receive(tx,settings: other)),0.01)
        let fixedA = SSTVChannelState.at(sample: 1000,total: 442920,settings: other)
        let fixedB = SSTVChannelState.at(sample: 400000,total: 442920,settings: other)
        XCTAssertEqual(fixedA.noise,fixedB.noise); XCTAssertEqual(fixedA.clockPPM,fixedB.clockPPM)
        XCTAssertEqual(fixedA.gain,1); XCTAssertEqual(fixedB.gain,1)
    }
}
