import SwiftUI
import AnalogCore

/// Static controls observe configuration changes, rather than every video
/// frame, clock tick and receiver metric emitted by PreviewModel.
@MainActor
final class TVControlState: ObservableObject {
    weak var owner: PreviewModel?
    @Published var tvChannel: TerrestrialSettings = {
        var s = TerrestrialSettings(system: .palDK); s.propagation.enabled = true; return s
    }() { didSet { if let owner, owner.tvChannel != tvChannel { owner.tvChannel = tvChannel } } }
    @Published var tvStandard: TVStandard = .pal {
        didSet { if let owner, owner.tvStandard != tvStandard { owner.tvStandard = tvStandard } }
    }
    @Published var busy = false
    @Published var tvDuration: Double = 0
    var terrestrialSystem: TerrestrialSystem { TerrestrialSystem(video: tvStandard) }
    func bind(_ owner: PreviewModel) {
        guard self.owner !== owner else { return }
        self.owner = owner
        if tvChannel != owner.tvChannel { tvChannel = owner.tvChannel }
        if tvStandard != owner.tvStandard { tvStandard = owner.tvStandard }
        if busy != owner.busy { busy = owner.busy }
        if tvDuration != owner.tvDuration { tvDuration = owner.tvDuration }
    }
}
