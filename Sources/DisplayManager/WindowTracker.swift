import AppKit
import ApplicationServices

/// Beobachtet alle laufenden Apps, speichert Fensterpositionen und stellt sie wieder her.
final class WindowTracker {
    static let shared = WindowTracker()

    /// Apps, die keine eigenen Fenster im üblichen Sinn haben.
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.screencaptureui",
    ]

    let store = WindowStore.shared
    let displays = DisplayRegistry.shared
    let prefs = Preferences.shared

    private(set) var isRunning = false
    private var observers: [pid_t: AppObserver] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var snapshotTimer: Timer?

    /// Während Bildschirm-Umbauten/Ruhezustand verschiebt macOS Fenster selbst – das darf nicht gespeichert werden.
    private var displayChangeInProgress = false
    private var isAsleep = false
    private var suppressSavingUntil = Date.distantPast
    private var displaySettleWork: DispatchWorkItem?

    var savingAllowed: Bool {
        !prefs.paused && !displayChangeInProgress && !isAsleep && Date() >= suppressSavingUntil
    }

    func restoreAllowed(for bundleID: String) -> Bool {
        prefs.restoreEnabled && !prefs.paused && !store.isExcluded(bundleID)
    }

    func suppressSaving(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if until > suppressSavingUntil { suppressSavingUntil = until }
    }

    // MARK: - Start/Stopp

    func start() {
        guard !isRunning else { return }
        isRunning = true
        displays.refresh()

        let ws = NSWorkspace.shared.notificationCenter
        notificationTokens = [
            ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.attach(app, inLaunchPhase: true)
            },
            ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.detach(pid: app.processIdentifier)
            },
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.snapshot()
                self?.isAsleep = true
                self?.store.saveNow()
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            },
            ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                self?.snapshot()
                self?.store.saveNow()
            },
        ]

        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())

        // Direkt nach dem Hochfahren/Anmelden: auch bereits laufende Apps korrigieren,
        // denn macOS stellt Fenster beim Anmelden oft falsch wieder her.
        let freshLogin = ProcessInfo.processInfo.systemUptime < 600
        for app in NSWorkspace.shared.runningApplications {
            attach(app, inLaunchPhase: freshLogin)
        }

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.snapshot()
        }
        Log.windows.info("Fensterüberwachung gestartet (\(self.observers.count) Apps)")
    }

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              app.processIdentifier != getpid(),
              !Self.ignoredBundleIDs.contains(bundleID) else { return false }
        return true
    }

    private func attach(_ app: NSRunningApplication, inLaunchPhase: Bool) {
        guard shouldTrack(app), observers[app.processIdentifier] == nil else { return }
        let observer = AppObserver(app: app, tracker: self, inLaunchPhase: inLaunchPhase)
        observers[app.processIdentifier] = observer
        observer.start()
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        observer.stop()
        store.scheduleSave()
    }

    // MARK: - Aktionen

    /// Speichert die aktuellen Rahmen aller offenen Fenster und findet neue Fenster.
    func snapshot() {
        for observer in observers.values { observer.snapshot() }
    }

    /// Setzt alle offenen Fenster an ihre gespeicherte Position (z. B. nach Anstecken eines Monitors).
    func restoreAll(force: Bool = false) {
        guard force || (prefs.restoreEnabled && !prefs.paused) else { return }
        displays.refresh()
        suppressSaving(for: 2)
        for observer in observers.values { observer.restoreOpenWindows() }
    }

    // MARK: - Bildschirm-Änderungen & Ruhezustand

    fileprivate func displayReconfiguration(begin: Bool) {
        if begin {
            displayChangeInProgress = true
            displaySettleWork?.cancel()
            return
        }
        // Mehrere Ereignisse kommen kurz hintereinander – erst nach Ruhe reagieren.
        displaySettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.displaysSettled() }
        displaySettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func displaysSettled() {
        displays.refresh()
        displayChangeInProgress = false
        suppressSaving(for: 5)
        Log.displays.info("Bildschirm-Konfiguration geändert: \(self.displays.configurationKey, privacy: .public)")
        guard prefs.restoreOnDisplayChange else { return }
        restoreAll()
        // Manche Apps/macOS verschieben verspätet – ein zweiter Durchgang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restoreAll() }
    }

    private func handleWake() {
        suppressSaving(for: 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.isAsleep = false
            self.displays.refresh()
            if self.prefs.restoreOnDisplayChange { self.restoreAll() }
        }
    }
}

private func displayReconfigurationCallback(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags,
                                            userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(userInfo).takeUnretainedValue()
    let begin = flags.contains(.beginConfigurationFlag)
    DispatchQueue.main.async { tracker.displayReconfiguration(begin: begin) }
}

// MARK: - Beobachter je App

private func axObserverCallback(observer: AXObserver, element: AXUIElement, notification: CFString,
                                refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let appObserver = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.handle(notification as String, element: element)
}

/// Beobachtet die Fenster einer einzelnen App über AXObserver.
final class AppObserver {
    /// Zustand eines aktuell offenen Fensters.
    final class TrackedWindow {
        let element: AXUIElement
        var recordID: UUID?
        /// Bis zu diesem Zeitpunkt läuft die Wiederherstellung; Bewegungen werden nicht gespeichert.
        var graceUntil: Date
        var userTookOver = false
        var lastSaved: CGRect?
        var saveWork: DispatchWorkItem?

        init(element: AXUIElement, graceUntil: Date) {
            self.element = element
            self.graceUntil = graceUntil
        }

        var inGrace: Bool { Date() < graceUntil }
    }

    /// Prüfzeitpunkte nach dem Öffnen eines Fensters. Mehrfach, weil manche Apps ihre
    /// eigene (evtl. falsche) Position erst nachträglich setzen.
    static let restoreDelays: [TimeInterval] = [0.25, 0.9, 2.0, 3.5]
    static let graceDuration: TimeInterval = 4.2
    static let launchPhaseDuration: TimeInterval = 20

    let pid: pid_t
    let bundleID: String
    let name: String
    let appElement: AXUIElement
    private var launchPhaseUntil: Date
    private weak var tracker: WindowTracker?
    private var axObserver: AXObserver?
    private var windows: [WindowKey: TrackedWindow] = [:]
    private var setupAttempts = 0
    private var stopped = false

    init(app: NSRunningApplication, tracker: WindowTracker, inLaunchPhase: Bool) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        name = app.localizedName ?? bundleID
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        self.tracker = tracker
        launchPhaseUntil = inLaunchPhase ? Date().addingTimeInterval(Self.launchPhaseDuration) : .distantPast
    }

    private var inLaunchPhase: Bool { Date() < launchPhaseUntil }
    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func start() { setUp() }

    func stop() {
        stopped = true
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        for w in windows.values { w.saveWork?.cancel() }
        windows.removeAll()
    }

    /// Frisch gestartete Apps sind oft noch nicht per AX ansprechbar – daher mit Wiederholungen.
    private func setUp() {
        guard !stopped else { return }
        setupAttempts += 1
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created else {
            retrySetUp()
            return
        }
        let result = AXObserverAddNotification(observer, appElement, "AXWindowCreated" as CFString, refcon)
        guard result == .success || result == .notificationAlreadyRegistered else {
            retrySetUp()
            return
        }
        AXObserverAddNotification(observer, appElement, "AXFocusedWindowChanged" as CFString, refcon)
        AXObserverAddNotification(observer, appElement, "AXMainWindowChanged" as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        scanWindows()
    }

    private func retrySetUp() {
        guard setupAttempts < 20 else {
            Log.windows.notice("\(self.name, privacy: .public): AX nicht verfügbar – wird nur per Abfrage beobachtet")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.setUp() }
    }

    // MARK: - Ereignisse

    func handle(_ notification: String, element: AXUIElement) {
        guard !stopped else { return }
        switch notification {
        case "AXWindowCreated":
            discover(element, allowRestore: true)
        case "AXFocusedWindowChanged", "AXMainWindowChanged":
            // Manche Apps melden neue Fenster nicht – über den Fokus trotzdem finden.
            discover(element, allowRestore: inLaunchPhase)
        case "AXMoved", "AXResized":
            windowChanged(element)
        case "AXUIElementDestroyed":
            windowClosed(element)
        default:
            break
        }
    }

    private func scanWindows() {
        for window in AX.windows(of: appElement) {
            discover(window, allowRestore: inLaunchPhase)
        }
    }

    private func discover(_ element: AXUIElement, allowRestore: Bool, isRetry: Bool = false) {
        let key = WindowKey(element)
        guard windows[key] == nil else { return }
        guard AX.isStandardWindow(element) else {
            // Rolle/Subrolle sind direkt nach dem Erzeugen manchmal noch nicht gesetzt.
            if !isRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.discover(element, allowRestore: allowRestore, isRetry: true)
                }
            }
            return
        }

        let restore = allowRestore && (tracker?.restoreAllowed(for: bundleID) ?? false)
        let tracked = TrackedWindow(element: element,
                                    graceUntil: restore ? Date().addingTimeInterval(Self.graceDuration) : .distantPast)
        windows[key] = tracked

        if let axObserver {
            for n in ["AXMoved", "AXResized", "AXUIElementDestroyed"] {
                AXObserverAddNotification(axObserver, element, n as CFString, refcon)
            }
        }

        if restore {
            for delay in Self.restoreDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tracked] in
                    guard let self, let tracked else { return }
                    self.attemptRestore(tracked)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceDuration + 0.1) { [weak self, weak tracked] in
                guard let self, let tracked else { return }
                tracked.graceUntil = .distantPast
                self.save(tracked)
            }
        } else {
            // Bereits offenes Fenster: nur zuordnen und aktuellen Stand merken.
            tracked.recordID = match(tracked, allowFallback: false)?.id
            save(tracked)
        }
    }

    private func windowChanged(_ element: AXUIElement) {
        guard let tracked = windows[WindowKey(element)] else {
            discover(element, allowRestore: false)
            return
        }
        if tracked.inGrace {
            // Zieht der Nutzer selbst am Fenster, hat er Vorrang.
            guard NSEvent.pressedMouseButtons != 0 else { return }
            tracked.userTookOver = true
            tracked.graceUntil = .distantPast
        }
        tracked.saveWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tracked] in
            guard let self, let tracked else { return }
            self.save(tracked)
        }
        tracked.saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func windowClosed(_ element: AXUIElement) {
        guard let tracked = windows.removeValue(forKey: WindowKey(element)) else { return }
        tracked.saveWork?.cancel()
    }

    // MARK: - Abgleich & Wiederherstellung

    private func otherRecordIDs(than tracked: TrackedWindow) -> Set<UUID> {
        Set(windows.values.compactMap { $0 === tracked ? nil : $0.recordID })
    }

    private func match(_ tracked: TrackedWindow, allowFallback: Bool) -> WindowRecord? {
        guard let store = tracker?.store else { return nil }
        return store.matchRecord(bundleID: bundleID, title: AX.title(tracked.element),
                                 document: AX.document(tracked.element),
                                 excluding: otherRecordIDs(than: tracked), allowFallback: allowFallback)
    }

    private func targetRect(for tracked: TrackedWindow, useAppFallback: Bool) -> CGRect? {
        guard let tracker else { return nil }
        let displays = tracker.displays
        guard let saved = tracker.store.targetFrame(bundleID: bundleID, recordID: tracked.recordID,
                                                    configKey: displays.configurationKey,
                                                    useAppFallback: useAppFallback,
                                                    isConnected: { displays.isConnected($0) }) else { return nil }
        return displays.globalRect(for: saved)
    }

    private func attemptRestore(_ tracked: TrackedWindow) {
        guard !stopped, tracked.inGrace, !tracked.userTookOver,
              windows[WindowKey(tracked.element)] === tracked,
              let tracker, tracker.restoreAllowed(for: bundleID) else { return }
        // Während der Nutzer klickt/zieht, nicht eingreifen.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard AX.isStandardWindow(tracked.element), let current = AX.frame(tracked.element) else { return }

        // Titel ändern sich beim Laden (z. B. Browser) – daher bei jedem Versuch neu zuordnen.
        // Beim Start der App oder wenn es ihr einziges Fenster ist, darf auf das zuletzt
        // genutzte Fenster zurückgegriffen werden.
        let allowFallback = inLaunchPhase || windows.count == 1
        tracked.recordID = match(tracked, allowFallback: allowFallback)?.id
        guard let target = targetRect(for: tracked, useAppFallback: allowFallback) else { return }

        if !current.isClose(to: target) {
            AX.setFrame(tracked.element, target, app: appElement)
            Log.windows.info("\(self.name, privacy: .public): Fenster wiederhergestellt → \(NSStringFromRect(target), privacy: .public)")
        }
    }

    /// Bereits offene Fenster an ihre gespeicherte Position setzen (nach Bildschirmwechsel).
    func restoreOpenWindows() {
        guard !stopped, let tracker, tracker.restoreAllowed(for: bundleID) else { return }
        for tracked in windows.values where !tracked.inGrace {
            guard AX.isStandardWindow(tracked.element), let current = AX.frame(tracked.element) else { continue }
            if tracked.recordID == nil { tracked.recordID = match(tracked, allowFallback: false)?.id }
            guard tracked.recordID != nil, let target = targetRect(for: tracked, useAppFallback: false) else { continue }
            if !current.isClose(to: target) {
                AX.setFrame(tracked.element, target, app: appElement)
                tracked.lastSaved = target
            }
        }
    }

    // MARK: - Speichern

    func snapshot() {
        guard !stopped else { return }
        // Fenster finden, die ohne Benachrichtigung entstanden sind.
        let current = AX.windows(of: appElement)
        for window in current where windows[WindowKey(window)] == nil {
            discover(window, allowRestore: inLaunchPhase)
        }
        // Verschwundene Fenster aufräumen.
        let alive = Set(current.map(WindowKey.init))
        for key in windows.keys where !alive.contains(key) {
            windows[key]?.saveWork?.cancel()
            windows.removeValue(forKey: key)
        }
        for tracked in windows.values where !tracked.inGrace {
            save(tracked)
        }
    }

    private func save(_ tracked: TrackedWindow) {
        guard !stopped, let tracker, tracker.savingAllowed, !tracker.store.isExcluded(bundleID),
              AX.isStandardWindow(tracked.element),
              let frame = AX.frame(tracked.element) else { return }
        if let last = tracked.lastSaved, tracked.recordID != nil, last.isClose(to: frame, tolerance: 0.5) { return }
        guard let display = tracker.displays.display(for: frame) else { return }

        let saved = SavedFrame(displayUUID: display.uuid,
                               relX: Double(frame.minX - display.bounds.minX),
                               relY: Double(frame.minY - display.bounds.minY),
                               width: Double(frame.width), height: Double(frame.height),
                               savedAt: Date())
        tracked.recordID = tracker.store.save(bundleID: bundleID, appName: name, recordID: tracked.recordID,
                                              title: AX.title(tracked.element), document: AX.document(tracked.element),
                                              frame: saved, configKey: tracker.displays.configurationKey,
                                              excluding: otherRecordIDs(than: tracked))
        tracked.lastSaved = frame
    }
}
