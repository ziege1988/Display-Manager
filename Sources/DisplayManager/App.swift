import AppKit

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

        if AX.isTrusted {
            WindowTracker.shared.start()
        } else {
            AX.requestTrust()
            // Warten, bis der Zugriff in den Systemeinstellungen erteilt wurde.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AX.isTrusted else { return }
                timer.invalidate()
                self?.permissionTimer = nil
                WindowTracker.shared.start()
            }
        }

        Updater.shared.start()
        Log.general.info("Display Manager \(Bundle.main.shortVersion, privacy: .public) gestartet")
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
