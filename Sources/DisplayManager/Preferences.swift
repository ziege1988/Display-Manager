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

    private enum Keys {
        static let restoreEnabled = "restoreEnabled"
        static let restoreOnDisplayChange = "restoreOnDisplayChange"
        static let paused = "paused"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let autoInstallUpdates = "autoInstallUpdates"
    }

    private init() {
        defaults.register(defaults: [
            Keys.restoreEnabled: true,
            Keys.restoreOnDisplayChange: true,
            Keys.paused: false,
            Keys.autoCheckUpdates: true,
            Keys.autoInstallUpdates: true,
        ])
        restoreEnabled = defaults.bool(forKey: Keys.restoreEnabled)
        restoreOnDisplayChange = defaults.bool(forKey: Keys.restoreOnDisplayChange)
        paused = defaults.bool(forKey: Keys.paused)
        autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        autoInstallUpdates = defaults.bool(forKey: Keys.autoInstallUpdates)
    }
}
