import AppKit

extension Notification.Name {
    static let hotKeyChanged = Notification.Name("DisplayManagerHotKeyChanged")
}

@main
enum DisplayManagerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // nur Menüleiste, kein Dock-Symbol
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var permissionTimer: Timer?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Liegt ein heruntergeladenes Update bereit, wird es jetzt installiert (App startet neu).
        if Updater.shared.installStagedUpdateIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        DisplayRegistry.shared.refresh()
        _ = WindowStore.shared
        statusBar = StatusBarController { SettingsWindowController.shared.show() }
        LoginItem.enableOnFirstLaunch()
        CommandApps.installAll()

        // Erster Start nach einem Update?
        let defaults = UserDefaults.standard
        let previousVersion = defaults.string(forKey: "lastLaunchedVersion")
        let isFirstLaunchAfterUpdate = previousVersion != nil && previousVersion != Bundle.main.shortVersion
        defaults.set(Bundle.main.shortVersion, forKey: "lastLaunchedVersion")

        if AX.isTrusted {
            WindowTracker.shared.start()
        } else {
            if isFirstLaunchAfterUpdate {
                // Der Eintrag in den Bedienungshilfen gehört noch zur vorherigen Version und hilft nicht mehr.
                // Automatisch entfernen und neu anfragen – dann muss nur noch der Schalter umgelegt werden.
                Log.general.notice("Freigabe nach Update von \(previousVersion ?? "?", privacy: .public) fehlt – Eintrag wird erneuert")
                AX.resetAndRequestTrust()
            } else {
                AX.requestTrust()
            }
            // Warten, bis der Zugriff in den Systemeinstellungen erteilt wurde.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AX.isTrusted else { return }
                timer.invalidate()
                self?.permissionTimer = nil
                WindowTracker.shared.start()
            }
        }

        Updater.shared.start()
        registerHotKey()
        NotificationCenter.default.addObserver(forName: .hotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }
        Log.general.info("Display Manager \(Bundle.main.shortVersion, privacy: .public) gestartet")
    }

    /// URL-Befehle, z. B. displaymanager://photoshop-duplikat (für Loupedeck, Kurzbefehle, Terminal).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        let command = (url.host ?? url.path).lowercased()
        switch command {
        case "photoshop-duplikat", "photoshop-duplicate", "duplikat":
            PhotoshopDuplicator.shared.trigger()
        case "wiederherstellen", "restore":
            WindowTracker.shared.restoreAll(force: true)
        case "einstellungen", "settings":
            SettingsWindowController.shared.show()
        default:
            Log.general.notice("Unbekannter URL-Befehl: \(string, privacy: .public)")
        }
    }

    private func registerHotKey() {
        hotKey = nil
        let prefs = Preferences.shared
        guard prefs.hotKeyEnabled else { return }
        hotKey = HotKey(keyCode: prefs.hotKeyCode, carbonModifiers: prefs.hotKeyModifiers) {
            PhotoshopDuplicator.shared.trigger()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if WindowTracker.shared.isRunning { WindowTracker.shared.snapshot() }
        WindowStore.shared.saveNow()
    }

    /// Erneutes Öffnen (z. B. Doppelklick im Programme-Ordner) zeigt die Einstellungen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
