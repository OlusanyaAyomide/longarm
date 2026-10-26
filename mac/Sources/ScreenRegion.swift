import AppKit

/// A part of a Mac display the phone is shown, kept relative to that display in points with a
/// top-left origin (the way ScreenCaptureKit measures), so it stays put when other displays come
/// and go. Remote control shows a whole display.
struct ScreenRegion: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var display: String   // the display's UUID: stable across reboots, unlike its display ID
    var rect: CGRect

    init(id: UUID = UUID(), name: String, frame: CGRect, on screen: NSScreen) {
        self.id = id
        self.name = name
        display = screen.displayUUID ?? ""
        rect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    /// Its display, or the main one if that display isn't connected.
    var screen: NSScreen? { NSScreen.screens.first { $0.displayUUID == display } ?? NSScreen.main }

    /// Where the area is now, in AppKit screen coordinates (bottom-left origin).
    var screenFrame: CGRect? {
        guard let screen else { return nil }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
