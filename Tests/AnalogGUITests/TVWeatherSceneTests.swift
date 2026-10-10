import XCTest
import SwiftUI
import AppKit
import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVWeatherSceneTests: XCTestCase {
    func testLightningAxesAdjustIndependentlyWithoutAccumulatingDrag() {
        let model = PreviewModel(); model.tvControlState.bind(model)
        var weather = TVWeatherSettings(); weather.lightning = 0.4
        TVWeatherElement.adjustLightning(&weather,from: 0.4,rate: 30,translation: CGSize(width: 0,height: -20))
        XCTAssertEqual(weather.lightning,0.6,accuracy: 1e-6)
        XCTAssertEqual(weather.lightningRatePerMinute,30)
        TVWeatherElement.adjustLightning(&weather,from: 0.4,rate: 30,translation: CGSize(width: 50,height: 0))
        XCTAssertEqual(weather.lightning,0.4)
        XCTAssertEqual(weather.lightningRatePerMinute,90)
        TVWeatherElement.adjustLightning(&weather,from: 0.4,rate: 30,translation: CGSize(width: 60,height: 0))
        XCTAssertEqual(weather.lightningRatePerMinute,102)
        model.tvControlState.tvChannel.propagation.weather = weather
        XCTAssertEqual(model.tvChannel.propagation.weather.lightningRatePerMinute,102)
        XCTAssertEqual(model.tvChannel.propagation.weather.lightning,0.4)
        let previous = weather
        TVWeatherElement.adjustLightning(&weather,from: 0.4,rate: 30,translation: CGSize(width: CGFloat.nan,height: 0))
        XCTAssertEqual(weather,previous)
        TVWeatherElement.adjustLightning(&weather,from: 0.4,rate: 30,translation: CGSize(width: -10_000,height: 0))
        XCTAssertEqual(weather.lightningRatePerMinute,0)
        XCTAssertEqual(weather.lightning,0.4)
        TVWeatherElement.lightning.reset(&weather)
        XCTAssertEqual(weather.lightning,0)
        XCTAssertEqual(weather.lightningRatePerMinute,30)
    }

    func testChangingStrikeIntensityDoesNotRestartItsVisualClock() throws {
        var settings = TVPropagationSettings(); settings.enabled = true; settings.weather.enabled = true
        settings.weather.lightning = 0.25; settings.weather.lightningRatePerMinute = 120
        let weak = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 4,seed: 42,settings: settings).first)
        settings.weather.lightning = 1
        let strong = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 4,seed: 42,settings: settings).first)
        let state = TVLightningState(); state.present(events: [weak],time: weak.time)
        let dim = try XCTUnwrap(state.flash).panelOpacity
        state.present(events: [strong],time: weak.time+0.01)
        XCTAssertEqual(try XCTUnwrap(state.flash).age,0.01,accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(state.flash).panelOpacity,dim)
    }
    func testSkyDragEnablesWeatherAndReachesRFConfiguration() {
        let model = PreviewModel()
        model.tvControlState.bind(model)
        var weather = model.tvControlState.tvChannel.propagation.weather
        let clear = TVPropagationModel.evaluate(model.tvChannel.propagation)
        TVWeatherElement.rain.adjust(&weather,from: 0,translation: -50)
        TVWeatherElement.humidity.adjust(&weather,from: 50,translation: -40)
        model.tvControlState.tvChannel.propagation.weather = weather
        XCTAssertTrue(model.tvChannel.propagation.weather.enabled)
        XCTAssertEqual(model.tvChannel.propagation.weather.rainMMHour,60)
        XCTAssertEqual(model.tvChannel.propagation.weather.humidityPercent,90)
        XCTAssertGreaterThan(TVPropagationModel.evaluate(model.tvChannel.propagation).weatherLossDB,clear.weatherLossDB)
        // Continuing the same drag applies its total translation, not a delta
        // on top of the last redraw's configuration.
        TVWeatherElement.rain.adjust(&weather,from: 0,translation: -60)
        XCTAssertEqual(weather.rainMMHour,72)
        TVWeatherElement.rain.reset(&weather)
        XCTAssertEqual(weather.rainMMHour,0)
        XCTAssertEqual(weather.humidityPercent,90)
    }

    func testSkyGesturesClampEveryPhenomenonAndRejectInvalidInput() {
        var weather = TVWeatherSettings()
        for element in TVWeatherElement.allCases {
            let initial = weather[keyPath: element.keyPath]
            element.adjust(&weather,from: initial,translation: -10_000)
            XCTAssertEqual(weather[keyPath: element.keyPath],element.range.upperBound)
            element.adjust(&weather,from: initial,translation: 10_000)
            XCTAssertEqual(weather[keyPath: element.keyPath],element.range.lowerBound)
            element.adjust(&weather,from: initial,translation: .nan)
            XCTAssertEqual(weather[keyPath: element.keyPath],element.range.lowerBound)
            element.reset(&weather)
            XCTAssertEqual(weather[keyPath: element.keyPath],initial)
        }
    }

    func testRainMovesWithoutEscapingTheProfileOrAccumulatingState() {
        let size = CGSize(width: 600,height: 230)
        let first = TVWeatherMotion.rainPosition(index: 0,seconds: 0,size: size,strength: 0.5)
        let next = TVWeatherMotion.rainPosition(index: 0,seconds: 0.1,size: size,strength: 0.5)
        XCTAssertGreaterThan(next.y,first.y)
        XCTAssertLessThan(next.x,first.x)
        for seconds in [0.0,0.1,50,800_000_000] {
            for index in 0..<90 {
                let p = TVWeatherMotion.rainPosition(index: index,seconds: seconds,size: size,strength: 1)
                XCTAssertTrue((0..<size.width).contains(p.x))
                XCTAssertTrue((24..<(size.height-40)).contains(p.y))
            }
        }
    }

    func testLightningLatchesShortPulseAndUsesOnlyPresentedMediaTime() throws {
        var settings = TVPropagationSettings(); settings.enabled = true
        settings.weather.enabled = true; settings.weather.lightning = 1; settings.weather.lightningRatePerMinute = 120
        let event = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 4,seed: 42,settings: settings).first)
        let state = TVLightningState()
        let frameTime = floor(event.time/0.04)*0.04
        // An impulse inside the frame is visible immediately, even though it is
        // much shorter than the rain animation's 83 ms update interval.
        state.present(events: [event],time: frameTime)
        XCTAssertEqual(state.flash?.opacity,1)
        let initial = state.flash
        state.present(events: [event],time: frameTime)
        XCTAssertEqual(state.flash,initial,"Paused/repeated frames must neither advance nor retrigger lightning")
        state.present(events: [event],time: frameTime+0.04)
        XCTAssertEqual(try XCTUnwrap(state.flash).age,0.04,accuracy: 1e-9,"A pulse crossing two frames must not restart the flash")
        XCTAssertLessThan(try XCTUnwrap(state.flash).opacity,1)
        state.present(events: [],time: frameTime+0.36)
        XCTAssertNil(state.flash)
        state.present(events: [],time: 0)
        XCTAssertNil(state.flash,"Seeking backwards cannot show a stale strike")
        state.present(events: [event],time: frameTime)
        XCTAssertNotNil(state.flash,"Replaying the same event must show it again")
        state.reset()
        XCTAssertNil(state.flash,"Explicit seeks/source changes clear the afterglow")
    }

    func testNativeWeatherSceneSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["ANALINE_CAPTURE_WEATHER"] == "1" else {
            throw XCTSkip("Opt-in: opens an owned native window for diagram visual verification")
        }
        _ = NSApplication.shared
        let model = PreviewModel()
        model.tvChannel.propagation.distanceKm = 32
        model.tvChannel.propagation.ridgeEnabled = true
        model.tvChannel.propagation.weather.enabled = true
        model.tvChannel.propagation.weather.rainMMHour = 65
        model.tvChannel.propagation.weather.snowMMHour = 8
        model.tvChannel.propagation.weather.fogGramsM3 = 0.3
        model.tvChannel.propagation.weather.humidityPercent = 80
        model.tvChannel.propagation.weather.temperatureC = 32
        model.tvChannel.propagation.weather.sunlight = 0.8
        model.tvChannel.propagation.weather.lightning = 0.65
        model.tvChannel.propagation.weather.ionization = 0.6
        model.tvChannel.propagation.groundReflection = 0.3
        model.tvChannel.echoGain = 0.45
        model.tvChannel.echoDelayMicroseconds = 8
        let event = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 8,
            seed: model.tvChannel.seed,settings: model.tvChannel.propagation).first)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 1200,height: 950),
                              styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for width in [420,300] {
            model.tvLightningState.reset()
            window.contentView = NSHostingView(rootView: TVPropagationView(model: model)
                .frame(width: CGFloat(width),height: 420).padding(12).background(Color.black))
            window.setContentSize(NSSize(width: width+24,height: 444)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
            try png.write(to: root.appendingPathComponent("build/TV-weather-\(width).png"))
            // An empty portion of the header verifies the whole panel is black,
            // and later receives the same flash as the diagram below it.
            let x = bitmap.pixelsWide/2, y = Int(20*Double(bitmap.pixelsHigh)/Double(view.bounds.height))
            func luminance() throws -> CGFloat {
                let color = try XCTUnwrap(bitmap.colorAt(x: x,y: y)?.usingColorSpace(.sRGB))
                return (color.redComponent+color.greenComponent+color.blueComponent)/3
            }
            let dark = try luminance()
            XCTAssertLessThan(dark,0.12,"Unlit Propagation header must use the black theme")
            if width == 420 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try await Task.sleep(for: .milliseconds(150))
                view.cacheDisplay(in: view.bounds,to: bitmap)
                let next = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
                XCTAssertNotEqual(png,next,"Native weather drawing must advance without a configuration or video frame update")
                try next.write(to: root.appendingPathComponent("build/TV-weather-420-animated.png"))
            }
            model.tvLightningState.present(events: [event],time: floor(event.time/0.04)*0.04)
            try await Task.sleep(for: .milliseconds(80))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            XCTAssertGreaterThan(try luminance(),dark+0.07,"The strike must illuminate the header as well as the diagram")
            try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
                .write(to: root.appendingPathComponent("build/TV-weather-\(width)-lightning.png"))
            model.tvLightningState.present(events: [],time: floor(event.time/0.04)*0.04+0.2)
            try await Task.sleep(for: .milliseconds(80))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            XCTAssertEqual(try luminance(),dark,accuracy: 0.02,"Panel illumination must end before the longer bolt afterglow")
            model.tvLightningState.present(events: [event],time: 0)
            model.tvControlState.setPropagationEnabled(false)
            try await Task.sleep(for: .milliseconds(80))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            XCTAssertEqual(try luminance(),dark,accuracy: 0.02,"Scene bypass must suppress a pending panel flash")
            model.tvControlState.setPropagationEnabled(true)

        }
    }
}
