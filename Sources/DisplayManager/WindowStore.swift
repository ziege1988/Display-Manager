import Foundation

/// Gespeicherte Position und Größe eines Fensters, relativ zu einem bestimmten Bildschirm.
struct SavedFrame: Codable, Equatable {
    var displayUUID: String
    /// Abstand zur oberen linken Ecke des Bildschirms (Punkte).
    var relX: Double
    var relY: Double
    var width: Double
    var height: Double
    var savedAt: Date
}

/// Ein einzelnes, wiedererkennbares Fenster einer App.
struct WindowRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var document: String?
    /// Rahmen je Bildschirm-Kombination (siehe `DisplayRegistry.configurationKey`).
    var frames: [String: SavedFrame]
    /// Zeitpunkt der letzten Positions-/Größenänderung.
    var lastChanged: Date
    /// Zuletzt aktiv (fokussiert) oder geschlossen – bestimmt das „zuletzt verwendete“ Fenster.
    var lastActive: Date?

    var lastUsed: Date { max(lastChanged, lastActive ?? .distantPast) }
}

/// Alle gespeicherten Fenster einer App.
struct AppRecord: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var excluded: Bool
    var windows: [WindowRecord]
    /// Zuletzt genutzter Rahmen der App je Bildschirm-Kombination (Rückfallebene).
    var lastFrames: [String: SavedFrame]
    var lastUsed: Date
}

/// Dauerhafter Speicher für Fensterpositionen (JSON in „Application Support/Display Manager“).
final class WindowStore: ObservableObject {
    static let shared = WindowStore()
    static let maxWindowsPerApp = 40

    @Published private(set) var apps: [String: AppRecord] = [:]
    private var saveWork: DispatchWorkItem?

    private init() { load() }

    var sortedApps: [AppRecord] { apps.values.sorted { $0.lastUsed > $1.lastUsed } }

    func isExcluded(_ bundleID: String) -> Bool { apps[bundleID]?.excluded ?? false }

    func setExcluded(_ bundleID: String, name: String, excluded: Bool) {
        var app = apps[bundleID] ?? AppRecord(bundleID: bundleID, name: name, excluded: false, windows: [],
                                              lastFrames: [:], lastUsed: Date())
        app.excluded = excluded
        apps[bundleID] = app
        scheduleSave()
    }

    func forget(_ bundleID: String) {
        apps.removeValue(forKey: bundleID)
        scheduleSave()
    }

    func forgetAll() {
        apps.removeAll()
        saveNow()
    }

    // MARK: - Abgleich

    /// Sucht das gespeicherte Fenster, das zu einem neu geöffneten Fenster passt.
    /// Reihenfolge: gleiches Dokument → gleicher Titel → (optional) zuletzt geändertes Fenster.
    func matchRecord(bundleID: String, title: String, document: String?, excluding: Set<UUID>,
                     allowFallback: Bool) -> WindowRecord? {
        guard let app = apps[bundleID] else { return nil }
        let candidates = app.windows.filter { !excluding.contains($0.id) }
        if let document, let r = candidates.first(where: { $0.document == document }) { return r }
        if !title.isEmpty,
           let r = candidates.filter({ $0.title == title }).max(by: { $0.lastUsed < $1.lastUsed }) {
            return r
        }
        if allowFallback { return candidates.max { $0.lastUsed < $1.lastUsed } }
        return nil
    }

    func record(bundleID: String, id: UUID) -> WindowRecord? {
        apps[bundleID]?.windows.first { $0.id == id }
    }

    /// Bester gespeicherter Rahmen für die aktuelle Bildschirm-Kombination.
    /// Bevorzugt den Rahmen genau dieser Kombination, sonst den jüngsten Rahmen auf einem
    /// aktuell angeschlossenen Bildschirm.
    func targetFrame(bundleID: String, recordID: UUID?, configKey: String, useAppFallback: Bool,
                     isConnected: (String) -> Bool) -> SavedFrame? {
        func pick(_ frames: [String: SavedFrame]) -> SavedFrame? {
            if let f = frames[configKey], isConnected(f.displayUUID) { return f }
            return frames.values.filter { isConnected($0.displayUUID) }.max { $0.savedAt < $1.savedAt }
        }
        guard let app = apps[bundleID] else { return nil }
        if let recordID, let record = app.windows.first(where: { $0.id == recordID }), let f = pick(record.frames) {
            return f
        }
        return useAppFallback ? pick(app.lastFrames) : nil
    }

    // MARK: - Speichern

    /// Speichert den Rahmen eines Fensters und liefert die ID des zugehörigen Eintrags.
    @discardableResult
    func save(bundleID: String, appName: String, recordID: UUID?, title: String, document: String?,
              frame: SavedFrame, configKey: String, excluding: Set<UUID>) -> UUID {
        let now = Date()
        var app = apps[bundleID] ?? AppRecord(bundleID: bundleID, name: appName, excluded: false, windows: [],
                                              lastFrames: [:], lastUsed: now)
        app.name = appName
        app.lastUsed = now

        var index: Int?
        if let recordID { index = app.windows.firstIndex { $0.id == recordID } }
        if index == nil, let document {
            index = app.windows.firstIndex { $0.document == document && !excluding.contains($0.id) }
        }
        if index == nil, !title.isEmpty {
            index = app.windows.firstIndex { $0.title == title && !excluding.contains($0.id) }
        }

        let id: UUID
        if let i = index {
            let previous = app.windows[i].frames[configKey]
            let changed = previous.map { !Self.sameGeometry($0, frame) } ?? true
            if !title.isEmpty { app.windows[i].title = title }
            if document != nil { app.windows[i].document = document }
            if changed {
                app.windows[i].frames[configKey] = frame
                app.windows[i].lastChanged = now
                app.lastFrames[configKey] = frame
            }
            id = app.windows[i].id
        } else {
            id = UUID()
            app.windows.append(WindowRecord(id: id, title: title, document: document,
                                            frames: [configKey: frame], lastChanged: now, lastActive: now))
            app.lastFrames[configKey] = frame
        }

        if app.windows.count > Self.maxWindowsPerApp {
            app.windows.sort { $0.lastUsed > $1.lastUsed }
            app.windows = Array(app.windows.prefix(Self.maxWindowsPerApp))
        }
        if apps[bundleID] != app {
            apps[bundleID] = app
            scheduleSave()
        }
        return id
    }

    /// Merkt sich, dass dieses Fenster gerade benutzt (fokussiert/geschlossen) wurde.
    func markActive(bundleID: String, recordID: UUID) {
        guard var app = apps[bundleID], let i = app.windows.firstIndex(where: { $0.id == recordID }) else { return }
        let now = Date()
        app.windows[i].lastActive = now
        app.lastUsed = now
        apps[bundleID] = app
        scheduleSave()
    }

    private static func sameGeometry(_ a: SavedFrame, _ b: SavedFrame) -> Bool {
        a.displayUUID == b.displayUUID && abs(a.relX - b.relX) < 1 && abs(a.relY - b.relY) < 1 &&
            abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    // MARK: - Persistenz

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try JSON.encoder.encode(apps).write(to: Paths.windowsFile, options: .atomic)
        } catch {
            Log.windows.error("Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.windowsFile) else { return }
        do {
            apps = try JSON.decoder.decode([String: AppRecord].self, from: data)
        } catch {
            // Beschädigte Datei sichern statt überschreiben.
            let backup = Paths.appSupport.appendingPathComponent("windows-defekt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Paths.windowsFile, to: backup)
            Log.windows.error("Laden fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
}
