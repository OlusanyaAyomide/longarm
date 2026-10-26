import AppKit
import IOKit.pwr_mgt

/// Remote control: the phone shows the whole Mac display live (through `ScreenShare`), and its
/// touches and keys become the Mac's pointer and keyboard (through an `InputInjector`).
///
/// Off unless the owner allows it from the menu ("Allow Remote Control"). While the phone is in
/// control, the menu bar icon turns orange and says "Remote" (Stop is in its menu), and a notice
/// shows for a few seconds when it starts. It also stops when the phone disconnects and after 10
/// minutes without input from it.
///
/// Phone → Mac:  remote {on}, pointer {action: click | drag-start | drag-move | drag-end,
///               x, y (0…1 of the screen), button: left | right, count}, scroll {x, y, dx, dy in
///               points}, type {text}, key {key, modifiers: [cmd, shift, option, control]},
///               keyframe (the phone's video decoder needs one), dictate {on}, then binary audio:
///               0x03 + 16 kHz mono 16-bit PCM
/// Mac → phone:  state {on, allowed, error}, screen (see `ScreenShare`), dictation {text: words in
///               progress | final: a finished phrase, done, error}, and binary video frames:
///               0x02, generation (UInt32), key frame (UInt8), width, height (UInt16), H.264
final class RemoteControl: NSObject {
    static let idleLimit: TimeInterval = 600
    private static let screenID = UUID(uuidString: "6D2B3F0E-0000-4000-8000-52454D4F5445")!
    private static let allowedKey = "remoteControlAllowed"

    var broadcast: (([String: Any]) -> Void)?
    /// On and off, for the menu bar icon.
    var onChange: (() -> Void)?
    /// The speech-to-text service dictation from the phone goes through.
    var dictationEngine: () -> SpeechEngine = { .deepgram }
    private(set) var isActive = false

    private let share: ScreenShare
    private let input: InputInjector
    private let dictation = PhoneDictation()
    private var banner: NSPanel?
    private var idleTimer: Timer?
    private var keepAwake: IOPMAssertionID = 0
    private var lastInput = Date()

    init(share: ScreenShare, input: InputInjector = MacInput()) {
        self.share = share
        self.input = input
        super.init()
        // Dictated words go to the phone's keyboard, which types them on the Mac when the owner presses ↵.
        dictation.onPhrase = { [weak self] text in
            self?.broadcast?(["type": "dictation", "final": text])
        }
        dictation.onLive = { [weak self] text, done in
            self?.broadcast?(["type": "dictation", "text": text, "done": done])
        }
        dictation.onError = { [weak self] message in
            self?.broadcast?(["type": "dictation", "text": "", "done": true, "error": message])
        }
    }

    /// The phone's microphone: 0x03, then PCM. Only while remote control is on and dictating.
    func audio(_ data: Data) {
        guard isActive, dictation.isOn, data.first == 3 else { return }
        lastInput = Date()
        dictation.audio(data.dropFirst())
    }

    var allowed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.allowedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.allowedKey)
            if newValue { broadcast?(stateMessage()) } else { stop(because: "Remote control was turned off on the Mac") }
        }
    }

    func stateMessage(error: String? = nil) -> [String: Any] {
        ["type": "state", "on": isActive, "allowed": allowed, "error": error ?? NSNull()]
    }

    /// Handles a message from the phone; returns false if it isn't one of these.
    func handle(_ message: [String: Any], reply: ([String: Any]) -> Void) -> Bool {
        guard let type = message["type"] as? String,
              ["remote", "pointer", "scroll", "type", "key", "keyframe", "dictate"].contains(type) else { return false }
        if type == "remote" {
            if message["on"] as? Bool == true { start(reply: reply) } else { stop(because: nil) }
            return true
        }
        guard isActive, let area = share.region else { return true }   // input only counts while it's on
        lastInput = Date()
        if type == "keyframe" {
            share.capture.requestKeyFrame()
            return true
        }
        if type == "dictate" {
            if message["on"] as? Bool == true { dictation.start(engine: dictationEngine()) } else { dictation.finish() }
            return true
        }
        switch type {
        case "pointer":
            guard let point = point(message, in: area) else { break }
            switch message["action"] as? String {
            case "click":
                DebugLog.write("remote click \(message["button"] as? String ?? "left") ×\(message["count"] as? Int ?? 1)")
                input.click(at: point, button: message["button"] as? String == "right" ? .right : .left,
                            count: max(1, (message["count"] as? Int) ?? 1))
            case "drag-start": input.dragStart(at: point)
            case "drag-move": input.dragMove(to: point)
            case "drag-end": input.dragEnd(at: point)
            default: break
            }
        case "scroll":
            guard let point = point(message, in: area) else { break }
            input.scroll(at: point, dx: Int(((message["dx"] as? NSNumber)?.doubleValue ?? 0).rounded()),
                         dy: Int(((message["dy"] as? NSNumber)?.doubleValue ?? 0).rounded()))
        case "type":
            if let text = message["text"] as? String, !text.isEmpty { input.type(text) }
        case "key":
            guard let name = message["key"] as? String, let key = Keys.key(name) else {
                DebugLog.write("remote key not known: \(message["key"] ?? "")")
                break
            }
            var modifiers = Keys.modifiers(message["modifiers"] as? [String] ?? [])
            if key.shift { modifiers.insert(.maskShift) }
            input.press(keyCode: key.code, modifiers: modifiers)
        default:
            break
        }
        return true
    }

    func stop(because reason: String?) {
        guard isActive else { return }
        isActive = false
        share.show(nil)
        if keepAwake != 0 { IOPMAssertionRelease(keepAwake) }
        keepAwake = 0
        dictation.cancel()
        idleTimer?.invalidate()
        idleTimer = nil
        banner?.orderOut(nil)
        banner = nil
        onChange?()
        DebugLog.write("remote control off\(reason.map { ": \($0)" } ?? "")")
        broadcast?(stateMessage(error: reason))
    }

    @objc func stopFromMac() { stop(because: "Stopped on the Mac") }

    private func start(reply: ([String: Any]) -> Void) {
        guard allowed else {
            return reply(stateMessage(error: "Turn on Allow Remote Control in the Longarm menu on the Mac"))
        }
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            return reply(stateMessage(error: "Longarm needs Accessibility access on the Mac to control it"))
        }
        guard !isActive else { return reply(stateMessage()) }
        guard let screen = NSScreen.screens.first else { return reply(stateMessage(error: "No display to show")) }
        isActive = true
        lastInput = Date()
        share.show(ScreenRegion(id: Self.screenID, name: Host.current().localizedName ?? "Mac", frame: screen.frame, on: screen))
        stayAwake()
        showBanner()
        onChange?()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastInput) > Self.idleLimit else { return }
            self.stop(because: "Remote control stopped after 10 minutes without use")
        }
        DebugLog.write("remote control on")
        broadcast?(stateMessage())
    }

    /// The display stays on while the phone is in control (once it sleeps there's nothing to show,
    /// and a locked Mac can't be unlocked remotely), and wakes up now if it was already off.
    private func stayAwake() {
        let reason = "Longarm: remote control from the phone" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &keepAwake)
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activity)
    }

    /// A 0…1 position on the shown screen → global display coordinates, kept on that screen.
    private func point(_ message: [String: Any], in area: ScreenRegion) -> CGPoint? {
        guard let x = (message["x"] as? NSNumber)?.doubleValue, let y = (message["y"] as? NSNumber)?.doubleValue,
              let displayID = area.screen?.displayID else { return nil }
        let bounds = CGDisplayBounds(displayID)
        let rect = area.rect
        return CGPoint(x: bounds.minX + rect.minX + min(max(x, 0) * rect.width, rect.width - 1),
                       y: bounds.minY + rect.minY + min(max(y, 0) * rect.height, rect.height - 1))
    }

    /// "Your phone is now controlling this Mac", top centre for a few seconds, then gone: the menu
    /// bar icon carries on saying so. Clicks go through it, and Longarm's own windows are left out of
    /// the capture, so it never gets in the phone's way.
    private func showBanner() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        let label = NSTextField(labelWithString: "Your phone is now controlling this Mac · Stop it from the Longarm menu")
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.95).cgColor
        stack.layer?.cornerRadius = 10

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        if let screen = NSScreen.screens.first {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                         y: screen.visibleFrame.maxY - panel.frame.height - 8))
        }
        panel.orderFrontRegardless()
        banner = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak panel] in
            guard let panel, self?.banner === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
    }
}
