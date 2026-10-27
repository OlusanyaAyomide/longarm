import AppKit
import ApplicationServices

/// While remote control is on, watches what has keyboard focus on the Mac and reports whether it's
/// somewhere you can type: a text field or text area (`text`), a password field (`secure`), or
/// neither. The phone shows it on its keyboard button, so you know before opening the keyboard
/// whether typing will land anywhere.
///
/// It asks Accessibility a few times a second. Native apps and Safari answer as they are; Chrome
/// and Electron apps (Slack, VS Code, …) only describe their web content once asked to, so each
/// app is asked once when it first comes to the front.
final class FocusWatcher {
    enum Kind: String {
        case none, text, secure
    }

    var onChange: ((Kind) -> Void)?
    private(set) var kind = Kind.none
    private var timer: Timer?

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        set(.none)
    }

    private func check() {
        guard AXIsProcessTrusted() else { return set(.none) }
        if let app = NSWorkspace.shared.frontmostApplication { askToDescribe(app) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return set(.none) }
        set(Self.kind(of: value as! AXUIElement))
    }

    private static func kind(of element: AXUIElement) -> Kind {
        let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole { return .secure }
        if let role, textRoles.contains(role) { return .text }
        // Anything else that holds editable text with a cursor, like a web page's rich text editor.
        var settable: DarwinBoolean = false
        var range: CFTypeRef?
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return .text
        }
        return .none
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private var asked: Set<pid_t> = []
    private static let chromiumBrowsers = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser",
                                           "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    /// Chrome-based browsers and Electron apps describe their contents fully only to apps that look
    /// like assistive tools: Electron listens for AXManualAccessibility, Chrome for
    /// AXEnhancedUserInterface. Others ignore both.
    private func askToDescribe(_ app: NSRunningApplication) {
        guard asked.insert(app.processIdentifier).inserted else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if Self.chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func set(_ kind: Kind) {
        guard kind != self.kind else { return }
        self.kind = kind
        onChange?(kind)
    }
}
