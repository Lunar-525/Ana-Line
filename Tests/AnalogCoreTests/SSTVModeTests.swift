import XCTest
import Foundation
@testable import AnalogCore
@testable import AnalogImaging

final class SSTVModeTests: XCTestCase {
    private let colors: [SIMD3<Float>] = [SIMD3(1,1,1),SIMD3(1,1,0),SIMD3(0,1,1),SIMD3(0,1,0),SIMD3(1,0,1),SIMD3(1,0,0),SIMD3(0,0,1),.zero]
    private func bars(_ mode: SSTVMode) -> SSTVFrame {
        SSTVFrame(rgb: (0..<mode.width*mode.height).map { i in
            colors[((i%mode.width)/(mode.width/8)+(i/mode.width)/32)%8]
        },mode: mode)
    }
    private func mae(_ a: SSTVFrame,_ b: SSTVFrame) -> Float {
        zip(a.rgb,b.rgb).reduce(0) { sum,p in
            let d = p.0-p.1; return sum+abs(d.x)+abs(d.y)+abs(d.z)
        }/Float(a.rgb.count*3)
    }
    func testIndependentModeTimingVISAndColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let runs: [[Double]] }
        for (mode,name,duration) in [(SSTVMode.martinM1,"martin-m1",115.200176),(.scottieS1,"scottie-s1",110.53432),(.pd120,"pd120",127.01304)] {
            let fixture = try JSONDecoder().decode(Fixture.self,from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/\(name)-pysstv-bars.json")))
            var frequency = [Float](), seconds: Double = 0
            for run in fixture.runs {
                seconds += run[1]
                frequency.append(contentsOf: repeatElement(Float(run[0]),count: Int((seconds*12000).rounded())-frequency.count))
            }
            let input = bars(mode), start = Date(), tx = try SSTVEngine.encode(input), encoded = Date()
            XCTAssertEqual(tx.duration,duration,accuracy: 1.0/12000,name)
            XCTAssertEqual(tx.samples.count,frequency.count,name)
            let independent = SSTVEngine.decodeFrequencies(frequency,original: input,settings: SSTVSettings())
            XCTAssertLessThan(mae(input,independent),0.015,name)
            var previous = SIMD2<Float>(1,0), totalError: Float = 0
            for (i,v) in tx.samples.enumerated() {
                let hz = 1900+atan2(v.y*previous.x-v.x*previous.y,v.x*previous.x+v.y*previous.y)*12000/(2*Float.pi)
                totalError += abs(hz-frequency[i]); previous = v
            }
            XCTAssertLessThan(totalError/Float(frequency.count),3,name)
            let rxStart = Date()
            let clean = try SSTVEngine.receive(tx,settings: SSTVSettings())
            XCTAssertLessThan(mae(input,clean),0.01,name)
            print(String(format: "%@ TX %.1f ms RX %.1f ms",name,encoded.timeIntervalSince(start)*1000,Date().timeIntervalSince(rxStart)*1000))
            var receiver = SSTVReceiver(transmission: tx)
            let halfway = Int((SSTVEngine.headerSeconds+Double(mode.height/mode.rowsPerLine/2)*mode.lineSeconds)*12000+0.5)
            try receiver.advance(to: halfway,settings: SSTVSettings())
            let before = receiver.snapshot(settings: SSTVSettings()), committed = receiver.receivedRows*mode.width
            XCTAssertEqual(receiver.receivedRows,mode.height/2)
            XCTAssertTrue(before.rgb[committed...].allSatisfy { $0 == .zero })
            var damaged = SSTVSettings(); damaged.frequencyOffset = 180
            try receiver.advance(to: tx.samples.count,settings: damaged)
            let after = receiver.snapshot(settings: damaged)
            XCTAssertEqual(receiver.receivedRows,mode.height)
            XCTAssertEqual(Array(before.rgb[..<committed]),Array(after.rgb[..<committed]))
            XCTAssertGreaterThan(mae(clean,after),0.02,name)
            var streamed = SSTVReceiver(transmission: tx)
            damaged.variation = 0.7; damaged.noise = 0.2; damaged.clockPPM = 200
            for end in stride(from: 7919,to: tx.samples.count,by: 7919) {
                try streamed.advance(to: end,settings: damaged)
            }
            try streamed.advance(to: tx.samples.count,settings: damaged)
            XCTAssertEqual(streamed.snapshot(settings: damaged).rgb,try SSTVEngine.receive(tx,settings: damaged).rgb,name)
        }
    }
    func testModeSwitchResizesInvalidatesCacheAndSessions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let renderer = SSTVRenderer()
        try await renderer.loadSource(Data(contentsOf: root.appendingPathComponent("Assets/bliss.jpg")))
        for mode in SSTVMode.allCases {
            var settings = SSTVSettings(); settings.mode = mode
            let result = try await renderer.render(settings)
            XCTAssertEqual(result.image.width,mode.width); XCTAssertEqual(result.image.height,mode.height)
            XCTAssertEqual(result.original.width,mode.width); XCTAssertEqual(result.original.height,mode.height)
            XCTAssertFalse(result.txCached)
            let cached = try await renderer.render(settings); XCTAssertTrue(cached.txCached)
            let token = try await renderer.beginTransmission(mode: mode)
            let complete = try await renderer.advanceTransmission(session: token,to: mode.duration+1,settings: settings,microphone: [],micGain: 0,monitor: false)
            XCTAssertTrue(complete.complete); XCTAssertEqual(complete.rows,mode.height)
            var other = settings; other.mode = mode == .robot36 ? .pd120 : .robot36
            _ = try await renderer.render(other)
            do {
                _ = try await renderer.advanceTransmission(session: token,to: 10,settings: settings,microphone: [],micGain: 0,monitor: false)
                XCTFail("Switching modes must invalidate the previous session")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            // Make the next loop's mode a fresh cache miss.
            try await renderer.loadSource(Data(contentsOf: root.appendingPathComponent("Assets/bliss.jpg")))
        }
    }
}
