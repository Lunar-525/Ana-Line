import SwiftUI
import AppKit
import AnalogCore

/// The Radio page is the shared environment only: eight fixed transmitters and
/// two receivers over one summed RF channel. Stations are taken off air with
/// their own power switch, so the page never adds or removes one.
@MainActor
struct RadioView: View {
    @StateObject private var model = RadioSceneModel()
    @State private var scrollProbe: Task<Void,Never>?
    var body: some View {
        ScrollView {
            RadioSceneView(model: model).padding(.bottom, 8)
        }.onAppear {
            // TEMPORARY profiling hook: ANALINE_RADIO_TX=N powers on the first N
            // of the eight fixed stations and starts playback so the real app
            // can be sampled while running.
            if let count = ProcessInfo.processInfo.environment["ANALINE_RADIO_TX"].flatMap(Int.init) {
                let on = min(RadioSceneSettings.transmitterSlots,max(0,count))
                model.configure { settings in
                    for slot in settings.transmitters.indices { settings.transmitters[slot].enabled = slot < on }
                }
                model.muted = ProcessInfo.processInfo.environment["ANALINE_RADIO_MUTE"] != "0"
                model.play()
            }
            if ProcessInfo.processInfo.environment["ANALINE_SCROLL"] == "1", scrollProbe == nil,
               #available(macOS 14.0, *) {
                scrollProbe = Task { await RadioTrackpadProbe.run(model: model) }
            }
        }.onDisappear { scrollProbe?.cancel(); model.pause() }
    }
}
