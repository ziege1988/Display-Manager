import AppKit

/// Symbol und Menü in der Menüleiste – die einzige sichtbare Oberfläche neben den Einstellungen.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        super.init()
        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.toolTip = "Display Manager"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
    }

    static func menuBarImage() -> NSImage? {
        if let image = Bundle.main.image(forResource: "MenuBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Display Manager")
        fallback?.isTemplate = true
        return fallback
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let tracker = WindowTracker.shared
        let prefs = Preferences.shared
        let displays = DisplayRegistry.shared

        let header = NSMenuItem(title: "Display Manager \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !AX.isTrusted {
            menu.addItem(item("⚠︎ Bedienungshilfen-Zugriff erteilen …", #selector(grantAccess)))
            menu.addItem(item("Freigabe reparieren (wenn schon aktiviert) …", #selector(repairAccess)))
        } else if prefs.paused {
            menu.addItem(disabled("Pausiert – Fenster werden nicht gemerkt"))
        } else {
            menu.addItem(disabled("Aktiv – Fenster werden gemerkt"))
        }

        menu.addItem(.separator())
        let count = displays.connected.count
        menu.addItem(disabled(count == 1 ? "1 Bildschirm verbunden" : "\(count) Bildschirme verbunden"))
        for d in displays.connected {
            let size = "\(Int(d.bounds.width))×\(Int(d.bounds.height))"
            let entry = disabled("   \(d.name)  (\(size))")
            entry.image = NSImage(systemSymbolName: d.isBuiltin ? "laptopcomputer" : "display", accessibilityDescription: nil)
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let saveItem = item("Fensterpositionen jetzt merken", #selector(saveNow))
        saveItem.isEnabled = AX.isTrusted && tracker.isRunning
        menu.addItem(saveItem)
        let restoreItem = item("Alle Fenster wiederherstellen", #selector(restoreNow))
        restoreItem.isEnabled = AX.isTrusted && tracker.isRunning
        menu.addItem(restoreItem)
        let pauseItem = item("Pausieren", #selector(togglePause))
        pauseItem.state = prefs.paused ? .on : .off
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        let label = prefs.hotKeyEnabled ? "  (\(prefs.hotKeyLabel))" : ""
        let psItem = item("Photoshop-Duplikat auf 2. Bildschirm\(label)", #selector(photoshopDuplicate))
        psItem.isEnabled = AX.isTrusted && PhotoshopDuplicator.shared.runningPhotoshop() != nil
        menu.addItem(psItem)

        menu.addItem(.separator())
        let power = PowerManager.shared
        if let battery = power.battery {
            let source = battery.onAC ? (battery.isCharging ? "lädt" : "Netzteil") : "Akku"
            menu.addItem(disabled("Akku \(battery.level) % · \(source)"))
        }
        menu.addItem(item("Strom ein", #selector(powerOn)))
        menu.addItem(item("Strom aus", #selector(powerOff)))

        menu.addItem(.separator())
        if let staged = Updater.shared.stagedVersion {
            menu.addItem(item("Update \(staged) jetzt installieren", #selector(installUpdate)))
        }
        menu.addItem(item("Einstellungen …", #selector(showSettings), key: ","))
        menu.addItem(item("Display Manager beenden", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func grantAccess() {
        AX.requestTrust()
        AX.openAccessibilitySettings()
    }

    @objc private func repairAccess() { AX.resetAndRequestTrust() }

    @objc private func saveNow() {
        WindowTracker.shared.snapshot()
        WindowStore.shared.saveNow()
    }

    @objc private func restoreNow() { WindowTracker.shared.restoreAll(force: true) }

    @objc private func togglePause() { Preferences.shared.paused.toggle() }

    @objc private func photoshopDuplicate() { PhotoshopDuplicator.shared.trigger() }

    @objc private func powerOn() { PowerManager.shared.switchPower(on: true, reason: "Menüleiste") }

    @objc private func powerOff() { PowerManager.shared.switchPower(on: false, reason: "Menüleiste") }

    @objc private func installUpdate() { Updater.shared.installNow() }

    @objc private func showSettings() { openSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}
