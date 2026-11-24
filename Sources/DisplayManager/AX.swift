import AppKit
import ApplicationServices

/// Dünne Hülle um die Accessibility-API (AXUIElement).
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Zeigt den System-Dialog zur Freigabe in „Bedienungshilfen“ an.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        (copy(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = copy(element, kAXPositionAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = copy(element, kAXSizeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Fensterrahmen in globalen Koordinaten (Ursprung oben links am Hauptbildschirm).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = position(element), let s = size(element) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    /// Setzt Position und Größe. Position wird doppelt gesetzt, weil manche Apps die Größe
    /// erst akzeptieren, wenn das Fenster auf dem Zielbildschirm liegt.
    static func setFrame(_ window: AXUIElement, _ rect: CGRect, app: AXUIElement) {
        // Bei aktivem „AXEnhancedUserInterface“ (z. B. Chromium/Electron) werden Fenster
        // animiert und unzuverlässig verschoben – daher kurz deaktivieren.
        let enhanced = bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        setPosition(window, rect.origin)
        setSize(window, rect.size)
        setPosition(window, rect.origin)
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// Nur „normale“ Fenster – keine Dialoge, Paletten, Sheets, Vollbild- oder minimierten Fenster.
    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute as String) == (kAXWindowRole as String),
              string(element, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String) else { return false }
        if bool(element, kAXMinimizedAttribute as String) == true { return false }
        if bool(element, "AXFullScreen") == true { return false }
        if let s = size(element), s.width < 60 || s.height < 40 { return false }
        return true
    }

    static func title(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute as String) ?? ""
    }

    /// Dokument-URL des Fensters (z. B. Vorschau, TextEdit, Pages), falls vorhanden.
    static func document(_ element: AXUIElement) -> String? {
        guard let doc = string(element, kAXDocumentAttribute as String), !doc.isEmpty else { return nil }
        return doc
    }
}

/// Hashbarer Schlüssel für AXUIElement (CF-Gleichheit statt Objektidentität).
struct WindowKey: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
