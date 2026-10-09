import XCTest
import SwiftUI
import AppKit
import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVWeatherSceneTests: XCTestCase {
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

    func testLightningHasShortBurstsAndStrengthControlsRecurrence() {
        XCTAssertEqual(TVWeatherMotion.lightning(seconds: 0.08,activity: 0).opacity,0)
        XCTAssertGreaterThan(TVWeatherMotion.lightning(seconds: 0.08,activity: 1).opacity,0.4)
        XCTAssertEqual(TVWeatherMotion.lightning(seconds: 0.4,activity: 1).opacity,0)
        XCTAssertGreaterThan(TVWeatherMotion.lightning(seconds: 2.58,activity: 1).opacity,0.4)
        XCTAssertEqual(TVWeatherMotion.lightning(seconds: 2.58,activity: 0.2).opacity,0)
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 1200,height: 950),
                              styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for width in [1200,1000] {
            window.contentView = NSHostingView(rootView: TVPropagationView(model: model)
                .padding(20).frame(width: CGFloat(width),height: 950,alignment: .top).background(Color.black))
            window.setContentSize(NSSize(width: width,height: 950)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
            try png.write(to: root.appendingPathComponent("build/TV-weather-\(width).png"))
            if width == 1200 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try await Task.sleep(for: .milliseconds(150))
                view.cacheDisplay(in: view.bounds,to: bitmap)
                let next = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
                XCTAssertNotEqual(png,next,"Native weather drawing must advance without a configuration or video frame update")
                try next.write(to: root.appendingPathComponent("build/TV-weather-1200-animated.png"))
            }
        }
    }
}
