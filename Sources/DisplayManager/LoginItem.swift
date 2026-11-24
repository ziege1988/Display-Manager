import Foundation
import ServiceManagement

/// Start beim Anmelden über SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.general.error("Anmeldeobjekt: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Beim allerersten Start automatisch aktivieren – die App soll arbeiten, sobald der Mac an ist.
    static func enableOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        setEnabled(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}
