import Foundation

/// Benutzereinstellungen (persistiert in UserDefaults).
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    /// Fenster beim Öffnen automatisch an die gespeicherte Position/Größe setzen.
    @Published var restoreEnabled: Bool { didSet { defaults.set(restoreEnabled, forKey: Keys.restoreEnabled) } }
    /// Fenster zurückholen, wenn Bildschirme an-/abgesteckt werden oder der Mac aufwacht.
    @Published var restoreOnDisplayChange: Bool { didSet { defaults.set(restoreOnDisplayChange, forKey: Keys.restoreOnDisplayChange) } }
    /// Speichern und Wiederherstellen vorübergehend aussetzen.
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused) } }
    /// Regelmäßig nach Updates suchen.
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) } }
    /// Updates automatisch laden und beim nächsten Start installieren.
    @Published var autoInstallUpdates: Bool { didSet { defaults.set(autoInstallUpdates, forKey: Keys.autoInstallUpdates) } }

    /// Photoshop-Duplikat: Zielbildschirm (UUID, leer = automatisch).
    @Published var photoshopTargetDisplay: String { didSet { defaults.set(photoshopTargetDisplay, forKey: Keys.photoshopTargetDisplay) } }
    /// Im Duplikat „Ganzes Bild“ ausführen, damit die Übersicht zu sehen ist.
    @Published var photoshopFitOnScreen: Bool { didSet { defaults.set(photoshopFitOnScreen, forKey: Keys.photoshopFitOnScreen) } }
    /// Tastenkürzel (Carbon-Tastencode und -Modifier). Standard: F13 ohne Zusatztasten.
    @Published var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: Keys.hotKeyCode) } }
    @Published var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers) } }
    @Published var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: Keys.hotKeyLabel) } }
    @Published var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) } }

    private enum Keys {
        static let photoshopTargetDisplay = "photoshopTargetDisplay"
        static let photoshopFitOnScreen = "photoshopFitOnScreen"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let restoreEnabled = "restoreEnabled"
        static let restoreOnDisplayChange = "restoreOnDisplayChange"
        static let paused = "paused"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let autoInstallUpdates = "autoInstallUpdates"
    }

    private init() {
        // Reste der entfernten Strom-Funktion (0.2.6–0.2.7) aufräumen.
        for key in ["powerOnShortcut", "powerOffShortcut", "powerOffOnShutdown", "powerOffOnRestart",
                    "powerToggleMode", "powerToggleShortcut", "batteryControlEnabled",
                    "batteryLowThreshold", "batteryHighThreshold"] {
            defaults.removeObject(forKey: key)
        }
        defaults.register(defaults: [
            Keys.restoreEnabled: true,
            Keys.restoreOnDisplayChange: true,
            Keys.paused: false,
            Keys.autoCheckUpdates: true,
            Keys.autoInstallUpdates: true,
            Keys.photoshopTargetDisplay: "",
            Keys.photoshopFitOnScreen: true,
            Keys.hotKeyCode: 105, // F13
            Keys.hotKeyModifiers: 0,
            Keys.hotKeyLabel: "F13",
            Keys.hotKeyEnabled: true,
        ])
        restoreEnabled = defaults.bool(forKey: Keys.restoreEnabled)
        restoreOnDisplayChange = defaults.bool(forKey: Keys.restoreOnDisplayChange)
        paused = defaults.bool(forKey: Keys.paused)
        autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        autoInstallUpdates = defaults.bool(forKey: Keys.autoInstallUpdates)
        photoshopTargetDisplay = defaults.string(forKey: Keys.photoshopTargetDisplay) ?? ""
        photoshopFitOnScreen = defaults.bool(forKey: Keys.photoshopFitOnScreen)
        hotKeyCode = defaults.integer(forKey: Keys.hotKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
        hotKeyLabel = defaults.string(forKey: Keys.hotKeyLabel) ?? "F13"
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
    }
}
