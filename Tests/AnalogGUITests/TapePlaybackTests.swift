import XCTest
import AVFoundation
import SwiftUI
import AnalogCore
@testable import AnalogGUI

final class TapePlaybackTests: XCTestCase {
    private func fixture(rate: Double,channels: AVAudioChannelCount,seconds: Double = 0.3) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".caf")
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate,channels: channels))
        let file=try AVAudioFile(forWriting: url,settings: format.settings)
        let count=AVAudioFrameCount(rate*seconds)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: count))
        buffer.frameLength=count
        for c in 0..<Int(channels) { for n in 0..<Int(count) {
            buffer.floatChannelData![c][n]=Float(0.1*sin(2*Double.pi*Double(c+1)*440*Double(n)/rate))
        } }
        try file.write(from: buffer); return url
    }
    @MainActor
    func testFF8TransportCounterMuteAndRecordFaders() async throws {
        let url=try fixture(rate: 44100,channels: 2,seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let model=TapeModel(); model.load(url)
        defer { model.stop() }
        model.seek(to: 6)
        model.wind(.rewinding)
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertLessThan(model.position,5)
        XCTAssertEqual(model.transport,.rewinding)
        model.stop(reset: false)
        let stopped=model.position
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(model.position,stopped)
        model.wind(.fastForwarding)
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertGreaterThan(model.position,stopped+1)
        model.togglePause()
        XCTAssertEqual(model.transport,.paused)
        let paused=model.position
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(model.position,paused)
        model.resetCounter(); XCTAssertEqual(model.counterSeconds,0)
        model.seek(to: paused-1); XCTAssertEqual(model.counterSeconds,-1,accuracy: 0.001)
        model.seek(to: paused+1); XCTAssertEqual(model.counterSeconds,1,accuracy: 0.001)
        model.setRecordLevel(-6,channel: 0)
        XCTAssertEqual(model.recordLevel(1),-6)
        model.linkedInput=false; model.setRecordLevel(-12,channel: 1)
        XCTAssertEqual(model.recordLevel(0),-6); XCTAssertEqual(model.recordLevel(1),-12)
        model.muted=true; model.play()
        XCTAssertTrue(model.playing,model.message)
        XCTAssertEqual(model.monitorVolume,0)
        let start=model.position
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertGreaterThan(model.position,start)
        XCTAssertGreaterThan(model.meters.left,-55,"Meters must continue while monitoring is muted")
        model.muted=false; XCTAssertEqual(model.monitorVolume,1)
        model.stop(reset: false)
        let position=model.position
        model.play()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertGreaterThan(model.position,position,"PLAY after STOP must resume, not rewind")
    }
    func testStereoPeakMeterBallistics() {
        var meters=TapeMeterState()
        meters.advance(left: pow(10,-18.0/20),right: pow(10,-38.0/20),seconds: 0.033)
        XCTAssertGreaterThan(meters.left,-3)
        XCTAssertLessThan(meters.right,-20)
        let peak=meters.holdLeft,initial=meters.left
        meters.advance(left: 0,right: 0,seconds: 0.033)
        XCTAssertLessThan(meters.left,initial)
        XCTAssertGreaterThan(meters.left,-10,"Release must be slower than attack")
        XCTAssertEqual(meters.holdLeft,peak)
        for _ in 0..<90 { meters.advance(left: 0,right: 0,seconds: 0.033) }
        XCTAssertLessThan(meters.holdLeft,peak-20)
        XCTAssertLessThan(meters.left,-55)
    }
    @MainActor
    func testTapeBrandColorMatchesDesign() throws {
        let color=try XCTUnwrap(NSColor(EditingTool.tape.logoAccentColor).usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent,130.0/255,accuracy: 0.001)
        XCTAssertEqual(color.greenComponent,168.0/255,accuracy: 0.001)
        XCTAssertEqual(color.blueComponent,245.0/255,accuracy: 0.001)
    }
    func testStreamingDecodeAndDrainAtDifferentSampleRates() throws {
        for (rate,channels) in [(44100.0,AVAudioChannelCount(1)),(96000.0,AVAudioChannelCount(2))] {
            let url=try fixture(rate: rate,channels: channels)
            defer { try? FileManager.default.removeItem(at: url) }
            var settings=TapeSettings(); settings.hiss=false
            let worker=try TapePlaybackWorker(url: url,settings: settings)
            var l=[Float](repeating: 0,count: 8192),r=l,frames=0,peak: Float=0
            for _ in 0..<30 {
                worker.start(); worker.pause()
                XCTAssertNil(worker.snapshot.error)
                let count=worker.left.snapshot.pending
                XCTAssertEqual(count,worker.right.snapshot.pending)
                if count>0 {
                    l.withUnsafeMutableBufferPointer { worker.left.read(into: $0.baseAddress!,count: count) }
                    r.withUnsafeMutableBufferPointer { worker.right.read(into: $0.baseAddress!,count: count) }
                    XCTAssertTrue(l.prefix(count).allSatisfy(\.isFinite))
                    peak=max(peak,l.prefix(count).map(abs).max() ?? 0); frames += count
                }
                if worker.drained { break }
            }
            XCTAssertTrue(worker.drained)
            XCTAssertEqual(Double(frames),14400+64,accuracy: 128)
            XCTAssertGreaterThan(peak,0.01)
            XCTAssertEqual(worker.seconds,worker.duration,accuracy: 0.001)
        }
    }
    @MainActor
    func testAudioDevicePauseResumeRewindAndModeExit() async throws {
        let probeEngine=AVAudioEngine()
        let deviceRate=withExtendedLifetime(probeEngine) { probeEngine.outputNode.outputFormat(forBus: 0).sampleRate }
        guard deviceRate > 0 else {
            throw XCTSkip("No audio output device")
        }
        let url=try fixture(rate: 48000,channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview=PreviewModel(); preview.tool = .tape
        let model=preview.tape
        model.load(url); model.play()
        defer { model.stop() }
        XCTAssertTrue(model.playing,model.message)
        try await Task.sleep(for: .milliseconds(120))
        model.pause()
        let paused=model.position
        XCTAssertGreaterThan(paused,0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.position,paused)
        model.play()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(model.playing)
        XCTAssertEqual(model.position,model.duration,accuracy: 0.001)
        model.stop(); XCTAssertEqual(model.position,0)
        model.play(); XCTAssertTrue(model.playing)
        preview.tool = .radio
        XCTAssertFalse(model.playing)
        XCTAssertTrue(model.message.isEmpty,model.message)
    }
    @MainActor
    func testModeSwitchPausesTapeAndRenders() throws {
        let model=PreviewModel(); model.tool = .tape
        XCTAssertFalse(model.rendering)
        let view=TapeView(model: model.tape).frame(width: 1000,height: 680)
            .environment(\.colorScheme,.dark).background(Color(white: 0.08))
        // ImageRenderer does not render AppKit-backed ScrollView content.
        let host=NSHostingView(rootView: view)
        let window=NSWindow(contentRect: NSRect(x: -10000,y: -10000,width: 1000,height: 680),
                            styleMask: [.borderless],backing: .buffered,defer: false)
        window.contentView=host
        host.frame=NSRect(x: 0,y: 0,width: 1000,height: 680)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/analine-tape-preview.png"))
        var bright=0
        for y in stride(from: 0,to: bitmap.pixelsHigh,by: 4) {
            for x in stride(from: 0,to: bitmap.pixelsWide,by: 4) {
                if let color=bitmap.colorAt(x: x,y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent,color.greenComponent,color.blueComponent)>0.4 { bright += 1 }
            }
        }
        XCTAssertGreaterThan(bright,500,"Tape controls must actually render")
        window.orderOut(nil)
        model.tool = .film
        XCTAssertFalse(model.tape.playing)
    }
}
