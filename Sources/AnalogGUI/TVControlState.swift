import SwiftUI
import AnalogCore

/// Static controls observe configuration changes, rather than every video
/// frame, clock tick and receiver metric emitted by PreviewModel.
@MainActor
final class TVControlState: ObservableObject {
    weak var owner: PreviewModel?
    @Published private(set) var bypassedSceneEchoGain: Float?
    @Published var tvChannel: TerrestrialSettings = {
        var s = TerrestrialSettings(system: .palDK); s.propagation.enabled = true; return s
    }() { didSet {
        if tvChannel.propagation.enabled, bypassedSceneEchoGain != nil { bypassedSceneEchoGain = nil }
        if let owner, owner.tvChannel != tvChannel { owner.tvChannel = tvChannel }
    } }
    @Published var tvStandard: TVStandard = .pal {
        didSet { if let owner, owner.tvStandard != tvStandard { owner.tvStandard = tvStandard } }
    }
    @Published var busy = false
    @Published var tvDuration: Double = 0
    var terrestrialSystem: TerrestrialSystem { TerrestrialSystem(video: tvStandard) }
    var sceneEchoGain: Float { bypassedSceneEchoGain ?? tvChannel.echoGain }
    func restoreSceneEcho(_ value: Float?) {
        bypassedSceneEchoGain = tvChannel.propagation.enabled ? nil : value
    }
    func resetReceiver() {
        let defaults = TerrestrialSettings(system: terrestrialSystem)
        var next = tvChannel
        next.tuningOffsetKHz = defaults.tuningOffsetKHz
        next.rfBandwidthMHz = defaults.rfBandwidthMHz
        next.automaticFineTuning = defaults.automaticFineTuning
        next.automaticGain = defaults.automaticGain
        next.manualGainDB = defaults.manualGainDB
        next.receiverDamage = defaults.receiverDamage
        next.decoder = defaults.decoder
        next.frontEnd = defaults.frontEnd
        tvChannel = next
    }
    func setSceneEchoGain(_ value: Float) {
        if bypassedSceneEchoGain != nil { bypassedSceneEchoGain = value }
        else { tvChannel.echoGain = value }
    }
    func setPropagationEnabled(_ enabled: Bool) {
        var next = tvChannel
        if enabled {
            next.echoGain = bypassedSceneEchoGain ?? next.echoGain
            bypassedSceneEchoGain = nil
        } else {
            if bypassedSceneEchoGain == nil { bypassedSceneEchoGain = next.echoGain }
            next.echoGain = 0
        }
        next.propagation.enabled = enabled
        tvChannel = next
    }
    func bind(_ owner: PreviewModel) {
        guard self.owner !== owner else { return }
        self.owner = owner
        if tvChannel != owner.tvChannel { tvChannel = owner.tvChannel }
        if tvStandard != owner.tvStandard { tvStandard = owner.tvStandard }
        if busy != owner.busy { busy = owner.busy }
        if tvDuration != owner.tvDuration { tvDuration = owner.tvDuration }
    }
}
