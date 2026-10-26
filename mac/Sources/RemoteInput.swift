import AppKit

/// What remote control can do to the Mac's pointer and keyboard. Points are in global display
/// coordinates (top-left of the main display, y down), the way Core Graphics events use them.
/// One implementation per platform; `MacInput` posts macOS input events.
protocol InputInjector {
    func click(at point: CGPoint, button: CGMouseButton, count: Int)
    func dragStart(at point: CGPoint)
    func dragMove(to point: CGPoint)
    func dragEnd(at point: CGPoint)
    func scroll(at point: CGPoint, dx: Int, dy: Int)
    func type(_ text: String)
    func press(keyCode: CGKeyCode, modifiers: CGEventFlags)
}

/// Posts input events as if from the built-in trackpad and keyboard. Needs the Accessibility
/// permission. Every event carries `marker`, so other tools can tell them from the owner's own.
final class MacInput: InputInjector {
    static let marker: Int64 = 0x4C47_5243   // "LGRC"

    private let source = CGEventSource(stateID: .hidSystemState)

    func click(at point: CGPoint, button: CGMouseButton, count: Int) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        post(mouse: .mouseMoved, at: point, button: button)
        post(mouse: down, at: point, button: button, clicks: count)
        post(mouse: up, at: point, button: button, clicks: count)
    }

    func dragStart(at point: CGPoint) {
        post(mouse: .mouseMoved, at: point, button: .left)
        post(mouse: .leftMouseDown, at: point, button: .left)
    }

    func dragMove(to point: CGPoint) { post(mouse: .leftMouseDragged, at: point, button: .left) }
    func dragEnd(at point: CGPoint) { post(mouse: .leftMouseUp, at: point, button: .left) }

    func scroll(at point: CGPoint, dx: Int, dy: Int) {
        post(mouse: .mouseMoved, at: point, button: .left)   // scrolling goes to what's under the pointer
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else { return }
        event.location = point
        event.flags = []   // see post(mouse:)
        mark(event).post(tap: .cghidEventTap)
    }

    /// Any text, in any language: sent as characters, not keys, so the keyboard layout doesn't matter.
    func type(_ text: String) {
        for character in text {
            if character == "\n" {
                press(keyCode: Keys.code("return")!, modifiers: [])
                continue
            }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.flags = []
                mark(event).post(tap: .cghidEventTap)
            }
        }
    }

    func press(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        // Real arrow and function keys carry these flags; without them macOS ignores shortcuts like
        // ⌃← (previous Space) and ⌃↑ (Mission Control).
        var flags = modifiers
        if (123...126).contains(keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if Keys.isFunctionKey(keyCode) { flags.insert(.maskSecondaryFn) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            mark(event).post(tap: .cghidEventTap)
        }
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        // A new event takes the modifiers the source last saw, and Control from an earlier ⌃← or ⌃↑
        // would turn every click into a right-click (Control-click). Clicks carry no modifiers.
        event.flags = []
        mark(event).post(tap: .cghidEventTap)
    }

    private func mark(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        return event
    }
}

/// Key names the phone sends ("return", "left", "c", …) → macOS virtual key codes (ANSI layout).
enum Keys {
    private static let named: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forward-delete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "page-up": 116, "page-down": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    private static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// Symbols typed with Shift on a US Mac keyboard, and the key they're on: ⌘+ is ⌘⇧=.
    private static let shifted: [Character: Character] = [
        "+": "=", "_": "-", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func code(_ name: String) -> CGKeyCode? { key(name)?.code }

    /// The key for a name or character, and whether it needs Shift (capital letters, + ! ? …).
    static func key(_ name: String) -> (code: CGKeyCode, shift: Bool)? {
        if let code = named[name.lowercased()] { return (code, false) }
        guard name.count == 1, let character = name.first else { return nil }
        if let base = shifted[character], let code = characters[base] { return (code, true) }
        if let code = characters[Character(character.lowercased())] { return (code, character.isUppercase) }
        return nil
    }

    static func isFunctionKey(_ code: CGKeyCode) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 115, 119, 116, 121, 117].contains(code)
    }

    static func modifiers(_ names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }
}
