import AppKit
import IOKit.ps

/// Schaltet eine Steckdose über Kurzbefehle (z. B. Apple Home) – beim Ausschalten des Mac
/// und abhängig vom Akkustand. Display Manager führt dafür die Kurzbefehle „Strom ein“ und
/// „Strom aus“ (Namen einstellbar) mit dem Systemwerkzeug /usr/bin/shortcuts aus.
final class PowerManager: ObservableObject {
    static let shared = PowerManager()

    struct BatteryState: Equatable {
        let level: Int        // Prozent
        let onAC: Bool        // Netzteil liefert Strom (Steckdose an)
        let isCharging: Bool
    }

    @Published private(set) var battery: BatteryState?
    @Published private(set) var availableShortcuts: [String] = []
    @Published private(set) var lastAction = "Noch nichts geschaltet"
    @Published private(set) var isRunningShortcut = false

    private let prefs = Preferences.shared
    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var lastOnRequest = Date.distantPast
    private var lastOffRequest = Date.distantPast
    /// Nach einem Schaltbefehl so lange warten, bevor erneut geschaltet wird (Home braucht etwas).
    private let requestCooldown: TimeInterval = 180

    var hasBattery: Bool { battery != nil }

    // MARK: - Start

    func start() {
        refreshBattery()
        refreshShortcutList()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.evaluate() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.evaluate() }
        // Nach dem Start/Neustart einmal nach Akkustand entscheiden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.evaluate() }
    }

    // MARK: - Akku

    func refreshBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let max = description["Max Capacity"] as? Int, max > 0 else { continue }
            let state = BatteryState(level: Int((Double(current) / Double(max) * 100).rounded()),
                                     onAC: (description["Power Source State"] as? String) == "AC Power",
                                     isCharging: (description["Is Charging"] as? Bool) ?? false)
            if battery != state { battery = state }
            return
        }
        battery = nil
    }

    /// Entscheidet anhand des Akkustands, ob ein- oder ausgeschaltet wird.
    func evaluate() {
        refreshBattery()
        guard prefs.batteryControlEnabled, !prefs.paused, let battery else { return }
        let now = Date()
        if battery.level <= prefs.batteryLowThreshold, !battery.onAC,
           now.timeIntervalSince(lastOnRequest) > requestCooldown {
            lastOnRequest = now
            Log.general.info("Akku \(battery.level) % – Strom ein")
            switchPower(on: true, reason: "Akku \(battery.level) %")
        } else if battery.level >= prefs.batteryHighThreshold, battery.onAC,
                  now.timeIntervalSince(lastOffRequest) > requestCooldown {
            lastOffRequest = now
            Log.general.info("Akku \(battery.level) % – Strom aus")
            switchPower(on: false, reason: "Akku \(battery.level) %")
        }
    }

    // MARK: - Schalten

    func switchPower(on: Bool, reason: String, completion: ((Bool) -> Void)? = nil) {
        let name = on ? prefs.powerOnShortcut : prefs.powerOffShortcut
        guard !name.isEmpty else {
            lastAction = "Kein Kurzbefehl für „Strom \(on ? "ein" : "aus")“ eingestellt."
            completion?(false)
            return
        }
        isRunningShortcut = true
        runShortcut(name, timeout: 20) { [weak self] success, output in
            guard let self else { return }
            self.isRunningShortcut = false
            let time = Date().formatted(date: .omitted, time: .shortened)
            self.lastAction = success
                ? "\(time): „\(name)“ ausgeführt (\(reason))."
                : "\(time): „\(name)“ fehlgeschlagen – \(output.isEmpty ? "Kurzbefehl prüfen" : output)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refreshBattery() }
            completion?(success)
        }
    }

    /// Führt einen Kurzbefehl aus. Abschluss immer auf dem Hauptthread.
    private func runShortcut(_ name: String, timeout: TimeInterval, completion: @escaping (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        var finished = false
        let finish: (Bool, String) -> Void = { success, message in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(success, message)
            }
        }
        process.terminationHandler = { p in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(p.terminationStatus == 0, message)
        }
        do {
            try process.run()
        } catch {
            finish(false, error.localizedDescription)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                finish(false, "Zeitüberschreitung")
            }
        }
    }

    func refreshShortcutList() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async { self.availableShortcuts = names }
        }
    }

    // MARK: - Ausschalten des Mac

    enum QuitReason { case shutdown, restart, logout, other }

    /// Grund des Beendens aus dem Quit-Apple-Event (Ausschalten, Neustart, Abmelden).
    static func currentQuitReason() -> QuitReason {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
            return .other
        }
        switch reason {
        case OSType(kAEShutDown): return .shutdown
        case OSType(kAERestart): return .restart
        case OSType(kAEReallyLogOut), OSType(kAELogOut), OSType(kAEShowRestartDialog): return .logout
        default: return .other
        }
    }

    /// Wird beim Beenden aufgerufen. Gibt `true` zurück, wenn erst noch geschaltet wird –
    /// dann ruft `done` das Beenden fort (der Mac wartet so lange mit dem Herunterfahren).
    func handleTermination(done: @escaping () -> Void) -> Bool {
        let reason = Self.currentQuitReason()
        let shouldSwitchOff: Bool
        switch reason {
        case .shutdown: shouldSwitchOff = prefs.powerOffOnShutdown
        case .restart: shouldSwitchOff = prefs.powerOffOnRestart
        case .logout, .other: shouldSwitchOff = false
        }
        guard shouldSwitchOff, !prefs.powerOffShortcut.isEmpty else { return false }
        Log.general.info("Mac wird \(reason == .shutdown ? "ausgeschaltet" : "neu gestartet") – Strom aus")
        switchPower(on: false, reason: reason == .shutdown ? "Mac ausgeschaltet" : "Neustart") { _ in
            // Kurz warten, damit der Befehl sicher bei der Steckdose ankommt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done() }
        }
        return true
    }
}
