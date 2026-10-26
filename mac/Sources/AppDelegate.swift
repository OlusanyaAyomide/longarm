import AppKit
import CoreImage

/// Menu bar app: the phone link, the screen it's shown, and remote control. Off until the owner
/// allows remote control from the menu; the icon turns orange and says "Remote" while it's on.
/// The menu also switches each way of connecting on or off: home Wi-Fi, and the internet over
/// Tailscale with a join code.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let port: UInt16 = 47900
    static let internetPort: UInt16 = 47901

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let share = ScreenShare()
    private lazy var remote = RemoteControl(share: share)
    private let macName = Host.current().localizedName ?? "Mac"
    private var pairing: Pairing?
    private var server: LinkServer?
    private var serverError: String?
    private var listenerProblems: [LinkServer.Network: String] = [:]
    private let joinCode = JoinCode()
    private var tailscaleWatch: Timer?
    private var phones: [String] = []
    private var pairWindow: NSWindow?
    private var quitSignal: DispatchSourceSignal?

    private static let deepgramKey = ApiKeyKind(
        name: "Deepgram", account: SpeechEngine.deepgram.keyAccount,
        usedFor: "Used to turn what you say into the phone into text",
        keyPage: SpeechEngine.deepgram.keyPage, looksValid: { $0.count >= 32 && !$0.contains(" ") })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` / `pkill` quits like the menu does, so screen capture is stopped first. From the run
        // loop, not this main-queue handler: quitting waits for an answer that arrives on the main queue.
        signal(SIGTERM, SIG_IGN)
        let quitSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        quitSignal.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        quitSignal.resume()
        self.quitSignal = quitSignal

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()

        share.onChange = { [weak self] in
            guard let self else { return }
            self.server?.broadcast(self.share.message())
        }
        share.capture.onFrame = { [weak self] frame, keyFrame in
            guard let self, let server = self.server else { return }
            if server.broadcastFrame(frame, keyFrame: keyFrame) { self.share.capture.requestKeyFrame() }
        }
        share.capture.onProblem = { [weak self] problem in
            if let problem { self?.server?.broadcast(["type": "notice", "text": problem]) }
        }
        remote.broadcast = { [weak self] message in self?.server?.broadcast(message) }
        remote.onChange = { [weak self] in self?.refreshIcon() }

        do {
            let pairing = try Pairing()
            let server = LinkServer(ports: [.home: Self.port, .internet: Self.internetPort],
                                    pairing: pairing, joinCode: joinCode, macName: macName)
            server.greeting = { [weak self] in
                guard let self else { return [] }
                return [self.remote.stateMessage(), self.share.message()]
            }
            server.onMessage = { [weak self] message, reply in self?.remote.handle(message, reply: reply) ?? false }
            server.onBinary = { [weak self] data in self?.remote.audio(data) }
            server.onPhonesChanged = { [weak self] names in
                self?.phones = names
                if names.isEmpty { self?.remote.stop(because: nil) }
                self?.refreshIcon()
            }
            server.onListenerProblem = { [weak self] network, problem in
                self?.listenerProblems[network] = problem
                self?.refreshIcon()
            }
            try server.setHome(homeOn)
            self.pairing = pairing
            self.server = server
        } catch {
            serverError = error.localizedDescription
        }
        refreshInternet()
        refreshIcon()
        askForPermissions()
        if pairing != nil, UserDefaults.standard.object(forKey: "paired") == nil { showPairWindow() }   // first run
    }

    /// Stops screen capture before quitting (up to 1 s), or macOS keeps showing Longarm as sharing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard share.capture.isCapturing else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        share.capture.stop(done: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reply)
        return .terminateLater
    }

    /// A menu bar app has no visible main menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z in text fields (like the API key
    /// dialog) only work if an Edit menu exists to route them. It never shows.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: - Menu bar

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if remote.isActive {   // unmistakable but out of the way: in the menu bar, not over the screen
            statusItem.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: "Longarm: remote control")
            button.image?.isTemplate = true
            button.contentTintColor = .systemOrange
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " Remote", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.menuBarFont(ofSize: 0),
            ])
            button.alphaValue = 1
            return
        }
        statusItem.length = NSStatusItem.squareLength
        button.title = ""
        let symbol = serverError != nil || !listenerProblems.isEmpty ? "exclamationmark.triangle" : "iphone"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Longarm")
        button.image?.isTemplate = true
        button.contentTintColor = nil
        button.alphaValue = phones.isEmpty ? 0.5 : 1   // dimmed until a phone connects
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) { let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: ""); item.isEnabled = false }
        func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self
            return item
        }

        info(phones.isEmpty ? "No phone connected" : "Connected: \(phones.joined(separator: ", "))")
        if let serverError { info("⚠︎ \(serverError)") }
        if remote.isActive {
            info("📱 Your phone is controlling this Mac")
            action("Stop Remote Control", #selector(RemoteControl.stopFromMac)).target = remote
        }
        if let problem = share.capture.problem { info("⚠︎ \(problem)") }
        menu.addItem(.separator())
        // Each way in is on only when switched on here: the phone doesn't fall back from one to the other.
        info("Connect from")
        let home = action("Home Wi-Fi (or USB)", #selector(toggleHome))
        home.state = homeOn ? .on : .off
        home.indentationLevel = 1
        if let problem = listenerProblems[.home] { info("    ⚠︎ \(problem)") }
        let internet = action("Internet, over Tailscale", #selector(toggleInternet))
        internet.state = internetOn ? .on : .off
        internet.indentationLevel = 1
        if internetOn {
            if let lockedUntil = joinCode.lockedUntil {
                info("    ⚠︎ Locked after wrong codes, until \(lockedUntil.formatted(date: .omitted, time: .shortened))")
            }
            if let problem = listenerProblems[.internet] {
                info("    ⚠︎ \(problem)")
            } else if let address = server?.internet?.host {
                info("    \(address) · the phone needs your join code")
            } else {
                info("    ⚠︎ Tailscale isn't connected on this Mac")
            }
        }
        action(joinCode.isSet ? "Change Join Code…" : "Set Join Code…", #selector(setJoinCode)).indentationLevel = 1
        menu.addItem(.separator())
        // Both are needed before the phone can see and use the Mac.
        if AXIsProcessTrusted() { info("✓ Accessibility (to click and type)") } else {
            _ = action("Allow Accessibility… (to click and type)", #selector(openAccessibilitySettings))
        }
        if CGPreflightScreenCaptureAccess() { info("✓ Screen Recording (to show the screen)") } else {
            _ = action("Allow Screen Recording… (to show the screen)", #selector(openScreenRecordingSettings))
        }
        menu.addItem(.separator())
        let allow = action("Allow Remote Control", #selector(toggleRemoteAllowed))
        allow.state = remote.allowed ? .on : .off
        _ = action("Deepgram API Key… (dictation)", #selector(setDeepgramKey))
        menu.addItem(.separator())
        _ = action("Pair a Phone…", #selector(showPairWindow))
        _ = action("Copy Pairing Link", #selector(copyPairingLink))
        _ = action("Reset Pairing…", #selector(resetPairing))
        menu.addItem(.separator())
        action("Quit Longarm", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @objc private func toggleRemoteAllowed() { remote.allowed.toggle() }

    // MARK: - Ways to connect

    private var homeOn: Bool {
        get { UserDefaults.standard.object(forKey: "homeOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "homeOn") }
    }

    private var internetOn: Bool {
        get { UserDefaults.standard.bool(forKey: "internetOn") }
        set { UserDefaults.standard.set(newValue, forKey: "internetOn") }
    }

    @objc private func toggleHome() {
        homeOn.toggle()
        do { try server?.setHome(homeOn) } catch { listenerProblems[.home] = error.localizedDescription }
        refreshIcon()
    }

    @objc private func toggleInternet() {
        if !internetOn {
            if !joinCode.isSet { askForJoinCode() }
            guard joinCode.isSet else { return }
            if Tailscale.address() == nil { explainTailscale() }
        }
        internetOn.toggle()
        refreshInternet()
    }

    /// Listens on the Tailscale address while internet connections are on, following it as Tailscale
    /// connects, disconnects or changes it.
    private func refreshInternet() {
        let host = internetOn ? Tailscale.address() : nil
        if host != server?.internet?.host {
            DebugLog.write(host.map { "internet connections: listening on \($0)" } ?? "internet connections: off")
            do { try server?.setInternet(host: host) } catch { listenerProblems[.internet] = error.localizedDescription }
        }
        if internetOn, tailscaleWatch == nil {
            tailscaleWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshInternet() }
        } else if !internetOn {
            tailscaleWatch?.invalidate()
            tailscaleWatch = nil
        }
        refreshIcon()
    }

    private func explainTailscale() {
        let alert = NSAlert()
        alert.messageText = "Longarm reaches your Mac over Tailscale"
        alert.informativeText = """
            Tailscale is a free private network between your own devices, so the Mac never has to be \
            open to the whole internet. Install it on this Mac and on your phone, and sign in to the same \
            account on both. Longarm starts listening as soon as Tailscale connects.
            """
        alert.addButton(withTitle: "Get Tailscale")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download")!) }
    }

    @objc private func setJoinCode() { askForJoinCode() }

    /// The code is typed twice and never shown. Changing it drops phones joined with the old one.
    private func askForJoinCode() {
        let code = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 220, height: 24))
        code.placeholderString = "\(JoinCode.lengths.lowerBound) to \(JoinCode.lengths.upperBound) digits"
        let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        again.placeholderString = "The same again"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 54))
        accessory.addSubview(code)
        accessory.addSubview(again)
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = joinCode.isSet ? "Change the join code" : "Choose a join code"
            alert.informativeText = (problem.map { "⚠︎ \($0)\n\n" } ?? "")
                + "Your phone asks for this code each time it connects over the internet, on top of being paired. "
                + "Five wrong codes in a row lock internet connections for 15 minutes."
            alert.accessoryView = accessory
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = code
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !JoinCode.isAcceptable(code.stringValue) {
                problem = "Use \(JoinCode.lengths.lowerBound) to \(JoinCode.lengths.upperBound) digits."
            } else if code.stringValue != again.stringValue {
                problem = "The two codes don't match."
            } else {
                joinCode.set(code.stringValue)
                server?.disconnect(.internet)
                return
            }
            again.stringValue = ""
        }
    }

    // MARK: - Permissions

    /// On launch, asks macOS for what remote control needs, so the prompts come up front rather
    /// than the first time the phone connects. macOS shows each prompt only once; after that the
    /// menu links to the right Settings page.
    private func askForPermissions() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        guard !CGPreflightScreenCaptureAccess() else { return }
        // macOS shows its own Screen Recording prompt only once per app; after that, ours.
        if UserDefaults.standard.bool(forKey: "screenRecordingAsked") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.askForScreenRecording() }
        } else {
            UserDefaults.standard.set(true, forKey: "screenRecordingAsked")
            CGRequestScreenCaptureAccess()
        }
    }

    /// Like macOS's own prompt for Accessibility: says why, and goes straight to the right Settings page.
    private func askForScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let alert = NSAlert()
        alert.messageText = "Allow Longarm to record this screen"
        alert.informativeText = "Longarm shows your Mac's screen on your phone. Turn on Longarm in Screen & System Audio Recording, then let macOS quit and reopen it."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingPane() }
    }

    private func openScreenRecordingPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() { askForScreenRecording() }
    @objc private func setDeepgramKey() { askForApiKey(Self.deepgramKey) }

    private func askForApiKey(_ kind: ApiKeyKind) {
        let hasKey = Keychain.read(kind.account) != nil
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 26, width: 250, height: 24))
        field.placeholderString = hasKey ? "Saved. Paste a new key to replace it" : "Your \(kind.name) API key"
        // Feedback on what was entered, without revealing it.
        let check = NSTextField(labelWithString: "")
        check.frame = NSRect(x: 0, y: 0, width: 320, height: 18)
        check.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        check.textColor = .secondaryLabelColor
        let updateCheck = {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            check.stringValue = key.isEmpty ? "" : "\(key.count) characters · "
                + (kind.looksValid(key) ? "looks like a \(kind.name) key ✓" : "doesn't look like a \(kind.name) key")
        }
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
                                                              object: field, queue: .main) { _ in updateCheck() }
        defer { NotificationCenter.default.removeObserver(observer) }
        // Reads the clipboard directly, so it works even where ⌘V doesn't reach the field.
        let paste = ClosureButton(title: "Paste") {
            field.stringValue = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            updateCheck()
        }
        paste.frame = NSRect(x: 256, y: 23, width: 64, height: 30)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 50))
        accessory.addSubview(field)
        accessory.addSubview(paste)
        accessory.addSubview(check)
        let alert = NSAlert()
        alert.messageText = "\(kind.name) API Key"
        alert.informativeText = "\(kind.usedFor), and kept in your Mac's Keychain. Create one at \(kind.keyPage)."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if hasKey { alert.addButton(withTitle: "Remove Key") }
        alert.window.initialFirstResponder = field
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.save(key, account: kind.account) }
        case .alertThirdButtonReturn:
            Keychain.delete(kind.account)
        default:
            break
        }
    }

    // MARK: - Pairing

    @objc private func copyPairingLink() {
        guard let link = pairingLink() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    @objc private func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "Reset pairing?"
        alert.informativeText = "Every paired phone is disconnected and must scan the new QR code."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? pairing?.resetToken()
        server?.disconnectAll()
        if pairWindow?.isVisible == true { showPairWindow() }
    }

    private func pairingLink() -> String? {
        pairing?.link(host: Self.primaryIPv4() ?? "127.0.0.1", port: Self.port, internet: server?.internet, macName: macName)
    }

    @objc private func showPairWindow() {
        guard let link = pairingLink() else { return }
        UserDefaults.standard.set(true, forKey: "paired")
        pairWindow?.close()

        let qr = NSImageView(image: Self.qrImage(link, size: 280))
        let title = NSTextField(labelWithString: "Scan with the Longarm app on your phone")
        title.font = .boldSystemFont(ofSize: 14)
        let detail = NSTextField(wrappingLabelWithString: """
            \(macName) · \(Self.primaryIPv4() ?? "no Wi-Fi address"):\(Self.port)
            Phone and Mac on the same Wi-Fi, or over USB with:
            adb reverse tcp:\(Self.port) tcp:\(Self.port)
            \(server?.internet.map { "Over the internet: Tailscale, \($0.host):\($0.port)" } ?? "")
            """)
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, qr, detail])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a Phone"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        pairWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func qrImage(_ message: String, size: CGFloat) -> NSImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let code = filter.outputImage!
        let scale = (size / code.extent.width).rounded(.down)
        let scaled = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cgImage = CIContext().createCGImage(scaled, from: scaled.extent)!
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    /// Wi-Fi / Ethernet IPv4 address, preferring en0.
    static func primaryIPv4() -> String? {
        var found: [(name: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((name, String(cString: host)))
            }
        }
        return (found.first { $0.name == "en0" } ?? found.first)?.ip
    }
}

/// An NSButton that runs a closure, for one-off buttons in alerts.
private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(run)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
