import AppKit
import ApplicationServices

/// Erzeugt per Knopfdruck eine zweite Ansicht („Neues Fenster für …“) des aktuellen Photoshop-Dokuments,
/// löst sie als schwebendes Fenster, legt sie auf den gewählten Bildschirm und lässt sie ihn ganz ausfüllen.
///
/// Es wird ausschließlich über die Photoshop-Menüs gearbeitet (wie ein Klick von Hand):
///   Fenster › Anordnen › Neues Fenster für „…“
///   Fenster › Anordnen › In Fenster verschiebbar machen
///   Ansicht › Ganzes Bild (optional)
/// Es wird KEIN neues Dokument und KEINE Ebene erzeugt – das Duplikat ist nur eine zweite Ansicht.
final class PhotoshopDuplicator: ObservableObject {
    static let shared = PhotoshopDuplicator()
    static let urlCommand = "displaymanager://photoshop-duplikat"

    @Published private(set) var lastResult = "Noch nicht ausgeführt"
    @Published private(set) var isRunning = false

    /// Bereits erzeugte Duplikate (für erneutes Platzieren nach Bildschirmwechsel).
    private var duplicates: [AXUIElement] = []

    /// Dauerhafter Wächter: Photoshop setzt Dokumentfenster nach manchen Aktionen
    /// (Verflüssigen, Filter, Zoom) wieder auf Bildgröße zurück.
    private final class Guarded {
        let window: AXUIElement
        let appElement: AXUIElement
        var target: CGRect
        var lastFrame: CGRect?
        var stableSince = Date()
        var userAdjusting = false
        var recentCorrections: [Date] = []
        var pausedUntil = Date.distantPast

        init(window: AXUIElement, appElement: AXUIElement, target: CGRect) {
            self.window = window
            self.appElement = appElement
            self.target = target
        }
    }
    private var guarded: [Guarded] = []
    private var guardTimer: Timer?

    private let prefs = Preferences.shared
    private let displays = DisplayRegistry.shared

    // MARK: - Menü-Bezeichnungen (Deutsch und Englisch, klein geschrieben)

    private enum Titles {
        static let windowMenu = ["fenster", "window"]
        static let viewMenu = ["ansicht", "view"]
        static let arrange = ["anordnen", "arrange"]
        static let newWindowPrefix = ["neues fenster für", "new window for"]
        static let floatInWindow = ["in fenster verschiebbar machen", "nur in fenster verschiebbar machen", "float in window"]
        static let fitOnScreen = ["ganzes bild", "fit on screen"]
    }

    enum DuplicateError: LocalizedError {
        case notTrusted, photoshopNotRunning, noDocument, menuNotFound(String), noNewWindow, noTargetDisplay

        var errorDescription: String? {
            switch self {
            case .notTrusted: return "Bedienungshilfen-Zugriff fehlt."
            case .photoshopNotRunning: return "Photoshop ist nicht geöffnet."
            case .noDocument: return "In Photoshop ist kein Dokument geöffnet."
            case .menuNotFound(let name): return "Menüpunkt „\(name)“ nicht gefunden. Bitte „Diagnose kopieren“ nutzen."
            case .noNewWindow:
                return "Das Duplikat ließ sich nicht als eigenes Fenster lösen (bleibt Reiter). Diagnose liegt in „Application Support/Display Manager/photoshop-diagnose.txt“."
            case .noTargetDisplay: return "Kein zweiter Bildschirm angeschlossen."
            }
        }
    }

    // MARK: - Öffentliche Aktionen

    /// Auslöser für Tastenkürzel, Menüleiste und URL-Befehl.
    func trigger() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            do {
                let message = try await self.run()
                self.finish(message, success: true)
            } catch {
                self.finish(error.localizedDescription, success: false)
            }
        }
    }

    /// Nach Bildschirmwechseln: vorhandene Duplikate wieder auf den Zielbildschirm legen.
    func replaceDuplicates() {
        duplicates = duplicates.filter { AX.copy($0, kAXRoleAttribute as String) != nil }
        guard !duplicates.isEmpty, let app = runningPhotoshop() else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in duplicates {
            guard let target = targetDisplay(excluding: nil) else { return }
            let rect = displays.visibleRect(for: target)
            AX.applyFrame(window, rect, app: appElement)
            keepFilled(window, rect, app: appElement)
        }
    }

    private func finish(_ message: String, success: Bool) {
        isRunning = false
        lastResult = "\(Date().formatted(date: .omitted, time: .shortened)): \(message)"
        if success {
            Log.general.info("Photoshop-Duplikat: \(message, privacy: .public)")
        } else {
            Log.general.error("Photoshop-Duplikat: \(message, privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: - Ablauf

    @MainActor
    private func run() async throws -> String {
        guard AX.isTrusted else { throw DuplicateError.notTrusted }
        guard let app = runningPhotoshop() else { throw DuplicateError.photoshopNotRunning }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        let bundleID = app.bundleIdentifier ?? "com.adobe.Photoshop"

        if !app.isActive {
            app.activate(options: [])
            try await sleep(0.3)
        }

        guard let original = focusedWindow(appElement) else { throw DuplicateError.noDocument }
        let docName = Self.documentName(AX.title(original))

        // Ist das Duplikat schon offen? Dann nur neu platzieren statt ein weiteres zu erzeugen.
        duplicates = duplicates.filter { AX.copy($0, kAXRoleAttribute as String) != nil }
        if duplicates.contains(where: { CFEqual($0, original) }) ||
            !docName.isEmpty && duplicates.contains(where: { Self.documentName(AX.title($0)) == docName }) {
            let existing = duplicates.first { CFEqual($0, original) } ??
                duplicates.first { Self.documentName(AX.title($0)) == docName }!
            let source = CFEqual(existing, original) ? nil : original
            guard let target = targetDisplay(excluding: source.flatMap(AX.frame)) else { throw DuplicateError.noTargetDisplay }
            let existingRect = displays.visibleRect(for: target)
            _ = await AX.applyFrameAndWait(existing, existingRect, app: appElement)
            if let source { focus(source) }
            keepFilled(existing, existingRect, app: appElement)
            return "Vorhandenes Duplikat auf „\(target.name)“ gelegt."
        }

        guard let target = targetDisplay(excluding: AX.frame(original)) else { throw DuplicateError.noTargetDisplay }
        let before = Set(AX.windows(of: appElement).map(WindowKey.init))

        // Der normale Wiederherstellungs-Mechanismus soll das neue Fenster nicht anfassen.
        WindowTracker.shared.suppressRestore(bundleID: bundleID, for: 8)
        WindowTracker.shared.suppressSaving(for: 8)

        // 1. Fenster › Anordnen › Neues Fenster für „…“
        guard let newWindowItem = findArrangeItem(appElement, matching: { title in
            Titles.newWindowPrefix.contains { title.hasPrefix($0) }
        }) else { throw DuplicateError.menuNotFound("Fenster › Anordnen › Neues Fenster für …") }
        press(newWindowItem)
        try await sleep(0.5)

        // 2. Fenster › Anordnen › In Fenster verschiebbar machen (löst das Duplikat aus der Reiterleiste).
        //    Photoshop meldet den Punkt direkt nach Schritt 1 teils fälschlich als inaktiv – daher
        //    ohne Prüfung drücken und bei Bedarf wiederholen.
        var duplicate = findNewWindow(appElement, before: before, docName: docName)
        var floatFound = false
        for attempt in 0..<3 where duplicate == nil {
            if let floatItem = findArrangeItem(appElement, matching: Self.isFloatInWindow) {
                floatFound = true
                press(floatItem)
            }
            // 3. Das neue (schwebende) Fenster finden
            for _ in 0..<(attempt == 0 ? 12 : 8) {
                try await sleep(0.12)
                duplicate = findNewWindow(appElement, before: before, docName: docName)
                if duplicate != nil { break }
            }
        }
        if duplicate == nil {
            saveDiagnosticsFile()
            if !floatFound { throw DuplicateError.menuNotFound("Fenster › Anordnen › In Fenster verschiebbar machen") }
            throw DuplicateError.noNewWindow
        }
        guard let duplicate else { throw DuplicateError.noNewWindow }
        WindowTracker.shared.ignore(duplicate)
        duplicates.append(duplicate)

        // 4. Auf den Zielbildschirm legen und ihn ganz ausfüllen (das Fenster, nicht das Foto)
        let rect = displays.visibleRect(for: target)
        _ = await AX.applyFrameAndWait(duplicate, rect, app: appElement)

        // 5. Optional im Duplikat „Ganzes Bild“, damit dort die Übersicht zu sehen ist.
        //    Ist in Photoshop „Zoomen verändert Fenstergröße“ aktiv, schrumpft das Fenster dabei
        //    auf Bildgröße – bei großen Dateien (RAW, 16 Bit) auch erst nach einigen Sekunden.
        //    Deshalb danach wieder aufziehen und eine Weile darüber wachen (Schritt 7).
        if prefs.photoshopFitOnScreen, let fitItem = findFitOnScreenItem(appElement) {
            focus(duplicate)
            try await sleep(0.2)
            press(fitItem)
            try await waitForSettledFrame(duplicate, maxSeconds: 3)
        }
        var filled = await AX.applyFrameAndWait(duplicate, rect, app: appElement)

        // Notlösung, falls Photoshop die Größe per Bedienungshilfen nicht annimmt: grüne Zoom-Taste.
        if !filled, let zoom = AX.copy(duplicate, kAXZoomButtonAttribute as String),
           CFGetTypeID(zoom) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(zoom as! AXUIElement, kAXPressAction as CFString) // swiftlint:disable:this force_cast
            try await sleep(0.4)
            filled = await AX.applyFrameAndWait(duplicate, rect, app: appElement)
        }
        if !filled { saveDiagnosticsFile() }

        // 6. Zurück zum Original (auf dem Wacom) – dort wird weitergearbeitet
        focus(original)

        // 7. Wächter: Verkleinert Photoshop das Duplikat später wieder (z. B. nach Verflüssigen),
        //    sofort zurück auf Vollbild – solange das Duplikat offen ist.
        keepFilled(duplicate, rect, app: appElement)
        let size = AX.frame(duplicate).map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
        let note = filled ? "" : " – Achtung: Photoshop hat die volle Größe nicht übernommen (\(size) statt \(Int(rect.width))×\(Int(rect.height))). Diagnose gespeichert."
        return "Duplikat von „\(docName.isEmpty ? "Dokument" : docName)“ auf „\(target.name)“ geöffnet\(note)."
    }

    // MARK: - Hilfen

    /// Wartet, bis sich der Fensterrahmen nicht mehr ändert (Photoshop rechnet bei großen Bildern länger).
    private func waitForSettledFrame(_ window: AXUIElement, maxSeconds: Double) async throws {
        var last = AX.frame(window)
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(maxSeconds)
        try await sleep(0.3)
        while Date() < deadline {
            let current = AX.frame(window)
            if current != last {
                last = current
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 0.6 {
                return
            }
            try await sleep(0.15)
        }
    }

    /// Hält das Duplikat dauerhaft bildschirmfüllend, solange es offen ist.
    private func keepFilled(_ window: AXUIElement, _ rect: CGRect, app: AXUIElement) {
        if let existing = guarded.first(where: { CFEqual($0.window, window) }) {
            existing.target = rect
            existing.pausedUntil = .distantPast
        } else {
            guarded.append(Guarded(window: window, appElement: app, target: rect))
        }
        if guardTimer == nil {
            guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkGuarded()
            }
        }
    }

    /// Mauszeiger (in AX-Koordinaten) innerhalb bzw. am Rand des Rahmens?
    private static func pointerIsOver(_ frame: CGRect) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let p = NSEvent.mouseLocation
        let point = CGPoint(x: p.x, y: primary.frame.height - p.y)
        return frame.insetBy(dx: -12, dy: -12).contains(point)
    }

    private func checkGuarded() {
        // Geschlossene Duplikate entfernen.
        guarded.removeAll { AX.copy($0.window, kAXRoleAttribute as String) == nil }
        if guarded.isEmpty {
            guardTimer?.invalidate()
            guardTimer = nil
            return
        }
        let mouseDown = NSEvent.pressedMouseButtons != 0
        let now = Date()
        for item in guarded {
            guard let frame = AX.frame(item.window) else { continue }
            if frame != item.lastFrame {
                // Zieht der Nutzer gerade selbst am Duplikat, gilt seine Größe danach als neues Ziel.
                // (Nur wenn der Zeiger dabei auf dem Duplikat ist – ein Stift-Klick auf dem Wacom,
                // z. B. „OK“ bei Verflüssigen, zählt nicht.)
                if mouseDown, item.lastFrame != nil, Self.pointerIsOver(frame) { item.userAdjusting = true }
                item.lastFrame = frame
                item.stableSince = now
                continue
            }
            if mouseDown { continue }
            if item.userAdjusting {
                item.userAdjusting = false
                item.target = frame
                Log.general.info("Photoshop-Duplikat: neue Größe vom Nutzer übernommen")
                continue
            }
            // Erst eingreifen, wenn Photoshop fertig ist (Rahmen 0,5 s unverändert).
            guard now.timeIntervalSince(item.stableSince) >= 0.5, now >= item.pausedUntil,
                  !frame.isClose(to: item.target, tolerance: 3) else { continue }
            // Schutz vor Endlos-Hin-und-her, falls Photoshop dauerhaft dagegenhält.
            item.recentCorrections = item.recentCorrections.filter { now.timeIntervalSince($0) < 30 } + [now]
            if item.recentCorrections.count > 10 {
                item.pausedUntil = now.addingTimeInterval(60)
                Log.general.notice("Photoshop-Duplikat: Photoshop hält dagegen – Wächter pausiert 60 s")
                continue
            }
            AX.applyFrame(item.window, item.target, app: item.appElement)
            item.lastFrame = nil
        }
    }

    func runningPhotoshop() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").hasPrefix("com.adobe.Photoshop") && $0.activationPolicy == .regular
        }
    }

    /// Zielbildschirm aus den Einstellungen – oder automatisch ein anderer als der des Originals.
    func targetDisplay(excluding originalFrame: CGRect?) -> DisplayInfo? {
        displays.refresh()
        if !prefs.photoshopTargetDisplay.isEmpty, let chosen = displays.display(uuid: prefs.photoshopTargetDisplay) {
            return chosen
        }
        let originalDisplay = originalFrame.flatMap { displays.display(for: $0) }
        let others = displays.connected.filter { $0.uuid != originalDisplay?.uuid }
        return others.first { !$0.isBuiltin } ?? others.first
    }

    /// „Bild.psd @ 33,3% (RGB/8)“ bzw. „Bild.psd bei 50% (RGB/8)“ → „Bild.psd“
    static func documentName(_ title: String) -> String {
        var name = title
        for separator in [" @ ", " bei ", " at "] {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        if let value = AX.copy(app, kAXFocusedWindowAttribute as String), CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) // swiftlint:disable:this force_cast
        }
        if let value = AX.copy(app, kAXMainWindowAttribute as String), CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) // swiftlint:disable:this force_cast
        }
        return nil
    }

    private func findNewWindow(_ app: AXUIElement, before: Set<WindowKey>, docName: String) -> AXUIElement? {
        let candidates = AX.windows(of: app).filter { window in
            guard !before.contains(WindowKey(window)),
                  AX.string(window, kAXRoleAttribute as String) == (kAXWindowRole as String),
                  let size = AX.size(window), size.width > 150, size.height > 100 else { return false }
            return true
        }
        return candidates.first { !docName.isEmpty && Self.documentName(AX.title($0)) == docName } ?? candidates.first
    }

    private func focus(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func press(_ item: AXUIElement) {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Menüs

    private static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (AX.copy(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    /// Menüeinträge unterhalb eines Menüleisten-/Menüpunktes.
    private static func menuItems(of item: AXUIElement) -> [AXUIElement] {
        children(item).flatMap { child -> [AXUIElement] in
            AX.string(child, kAXRoleAttribute as String) == (kAXMenuRole as String) ? children(child) : []
        }
    }

    private func topMenu(_ app: AXUIElement, _ names: [String]) -> AXUIElement? {
        guard let bar = AX.copy(app, kAXMenuBarAttribute as String), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return Self.children(bar as! AXUIElement).first { // swiftlint:disable:this force_cast
            names.contains(Self.normalized(AX.title($0)))
        }
    }

    /// „In Fenster verschiebbar machen“ / „Float in Window“ – aber nicht „Alle in Fenstern …“ / „Float All …“.
    static func isFloatInWindow(_ title: String) -> Bool {
        if Titles.floatInWindow.contains(title) { return true }
        let isFloat = title.contains("verschiebbar") || title.contains("schwebend") || title.hasPrefix("float")
        let isAll = title.hasPrefix("alle") || title.contains(" all") || title.contains("fenstern")
        return isFloat && !isAll
    }

    private func findArrangeItem(_ app: AXUIElement, matching: (String) -> Bool) -> AXUIElement? {
        guard let windowMenu = topMenu(app, Titles.windowMenu),
              let arrange = Self.menuItems(of: windowMenu).first(where: { Titles.arrange.contains(Self.normalized(AX.title($0))) })
        else { return nil }
        return Self.menuItems(of: arrange).first { matching(Self.normalized(AX.title($0))) }
    }

    /// „Ganzes Bild“ – zuerst über das Kürzel ⌘0 (sprachunabhängig), sonst über den Namen.
    private func findFitOnScreenItem(_ app: AXUIElement) -> AXUIElement? {
        guard let viewMenu = topMenu(app, Titles.viewMenu) else { return nil }
        let items = Self.menuItems(of: viewMenu)
        if let byShortcut = items.first(where: {
            AX.string($0, "AXMenuItemCmdChar") == "0" &&
                ((AX.copy($0, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? -1) == 0
        }) { return byShortcut }
        return items.first { Titles.fitOnScreen.contains(Self.normalized(AX.title($0))) }
    }

    // MARK: - Diagnose

    /// Beschreibt Menüs und Fenster von Photoshop – hilft bei der Fehlersuche (wird in die Zwischenablage kopiert).
    func diagnostics() -> String {
        var lines = ["Display Manager \(Bundle.main.shortVersion) – Photoshop-Diagnose",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Bedienungshilfen: \(AX.isTrusted ? "ja" : "NEIN")"]
        guard let app = runningPhotoshop() else {
            lines.append("Photoshop läuft nicht.")
            return lines.joined(separator: "\n")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let version = app.bundleURL.flatMap { Bundle(url: $0)?.shortVersion } ?? "?"
        lines.append("App: \(app.localizedName ?? "?") · \(app.bundleIdentifier ?? "?") · Version \(version)")

        lines.append("\nBildschirme:")
        for d in displays.connected {
            lines.append("  \(d.name) · \(NSStringFromRect(d.bounds)) · nutzbar \(NSStringFromRect(displays.visibleRect(for: d)))\(d.isBuiltin ? " · integriert" : "")")
        }

        lines.append("\nFenster:")
        for w in AX.windows(of: appElement) {
            let role = AX.string(w, kAXRoleAttribute as String) ?? "?"
            let sub = AX.string(w, kAXSubroleAttribute as String) ?? "?"
            let frame = AX.frame(w).map { NSStringFromRect($0) } ?? "?"
            let sizeSettable = AX.isSettable(w, kAXSizeAttribute as String) ? "Größe änderbar" : "Größe NICHT änderbar"
            lines.append("  „\(AX.title(w))“ · \(role)/\(sub) · \(frame) · \(sizeSettable)")
        }

        func dump(_ names: [String], label: String) {
            guard let menu = topMenu(appElement, names) else {
                lines.append("\nMenü „\(label)“ NICHT gefunden. Vorhandene Menüs:")
                if let bar = AX.copy(appElement, kAXMenuBarAttribute as String), CFGetTypeID(bar) == AXUIElementGetTypeID() {
                    for item in Self.children(bar as! AXUIElement) { lines.append("  \(AX.title(item))") } // swiftlint:disable:this force_cast
                }
                return
            }
            lines.append("\nMenü „\(AX.title(menu))“:")
            for item in Self.menuItems(of: menu) {
                let cmd = AX.string(item, "AXMenuItemCmdChar").map { " [⌘\($0)]" } ?? ""
                let enabled = AX.bool(item, kAXEnabledAttribute as String) == false ? " (inaktiv)" : ""
                lines.append("  \(AX.title(item))\(cmd)\(enabled)")
                if Titles.arrange.contains(Self.normalized(AX.title(item))) {
                    for sub in Self.menuItems(of: item) {
                        let subEnabled = AX.bool(sub, kAXEnabledAttribute as String) == false ? " (inaktiv)" : ""
                        lines.append("      \(AX.title(sub))\(subEnabled)")
                    }
                }
            }
        }
        dump(Titles.windowMenu, label: "Fenster")
        dump(Titles.viewMenu, label: "Ansicht")
        return lines.joined(separator: "\n")
    }

    private func saveDiagnosticsFile() {
        try? diagnostics().write(to: Paths.appSupport.appendingPathComponent("photoshop-diagnose.txt"),
                                 atomically: true, encoding: .utf8)
    }

    func copyDiagnosticsToClipboard() {
        let text = diagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try? text.write(to: Paths.appSupport.appendingPathComponent("photoshop-diagnose.txt"), atomically: true, encoding: .utf8)
        lastResult = "Diagnose in die Zwischenablage kopiert."
    }
}
