import Foundation

/// What the phone is shown: one screen region at a time, streamed live by `ScreenCapture`. Each
/// change bumps a generation that the video frames carry, so the phone can drop late frames of
/// the previous region.
final class ScreenShare {
    /// The region changed (or went away): tell the phone (`message()`).
    var onChange: (() -> Void)?
    let capture = ScreenCapture()
    private(set) var region: ScreenRegion?
    private(set) var generation: UInt32 = 0

    func show(_ region: ScreenRegion?) {
        guard region != self.region else { return }
        if region != nil, self.region == nil { capture.start() }
        self.region = region
        generation &+= 1
        DebugLog.write("showing: \(region?.name ?? "nothing")")
        capture.show(region, generation: generation)
        if region == nil { capture.stop() }
        onChange?()
    }

    /// {type: screen, generation, region: {id, name, width, height} or null}
    func message() -> [String: Any] {
        guard let region else { return ["type": "screen", "region": NSNull()] }
        return ["type": "screen", "generation": generation, "region": [
            "id": region.id.uuidString, "name": region.name,
            "width": Int(region.rect.width), "height": Int(region.rect.height),
        ] as [String: Any]]
    }
}
