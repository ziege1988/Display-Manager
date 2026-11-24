import AppKit
import CoreGraphics

/// Ein aktuell angeschlossener Bildschirm.
struct DisplayInfo: Identifiable, Equatable {
    var id: String { uuid }
    let displayID: CGDirectDisplayID
    /// Stabile Kennung über Neustarts hinweg (aus Hersteller, Modell und Seriennummer).
    let uuid: String
    let name: String
    /// Rahmen in globalen Koordinaten (Ursprung oben links am Hauptbildschirm) – identisch zum AX-Koordinatensystem.
    let bounds: CGRect
    let isBuiltin: Bool
    let isMain: Bool
}

/// Ein jemals gesehener Bildschirm (dauerhaft gespeichert).
struct KnownDisplay: Codable, Identifiable, Equatable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var width: Double
    var height: Double
    var originX: Double
    var originY: Double
    var isBuiltin: Bool
    var firstSeen: Date
    var lastSeen: Date
}

/// Merkt sich dauerhaft alle Bildschirme und kennt die aktuell angeschlossenen.
final class DisplayRegistry: ObservableObject {
    static let shared = DisplayRegistry()

    @Published private(set) var connected: [DisplayInfo] = []
    @Published private(set) var known: [KnownDisplay] = []

    private init() {
        load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    /// Kennung der aktuellen Bildschirm-Kombination. Fensterpositionen werden je Kombination
    /// gespeichert, damit z. B. „MacBook allein“ und „MacBook + 2 Monitore“ getrennt bleiben.
    var configurationKey: String {
        connected.map(\.uuid).sorted().joined(separator: "+")
    }

    func isConnected(_ uuid: String) -> Bool { connected.contains { $0.uuid == uuid } }

    func display(uuid: String) -> DisplayInfo? { connected.first { $0.uuid == uuid } }

    /// Bildschirm, auf dem der größte Teil des Rechtecks liegt (sonst der nächstgelegene).
    func display(for rect: CGRect) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in connected {
            let i = d.bounds.intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > 0, area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let best { return best.0 }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return connected.min { a, b in
            hypot(a.bounds.midX - c.x, a.bounds.midY - c.y) < hypot(b.bounds.midX - c.x, b.bounds.midY - c.y)
        }
    }

    /// Wandelt einen gespeicherten Rahmen in globale Koordinaten um und hält ihn auf dem Bildschirm.
    func globalRect(for frame: SavedFrame) -> CGRect? {
        guard let d = display(uuid: frame.displayUUID) else { return nil }
        let b = d.bounds
        let w = min(CGFloat(frame.width), b.width)
        let h = min(CGFloat(frame.height), b.height)
        var x = b.minX + CGFloat(frame.relX)
        var y = b.minY + CGFloat(frame.relY)
        x = min(max(x, b.minX), b.maxX - w)
        y = min(max(y, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Nutzbare Fläche eines Bildschirms (ohne Menüleiste/Dock) in globalen AX-Koordinaten.
    func visibleRect(for display: DisplayInfo) -> CGRect {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
              }) else { return display.bounds }
        let vf = screen.visibleFrame
        return CGRect(x: vf.minX, y: primary.frame.height - vf.maxY, width: vf.width, height: vf.height)
    }

    func refresh() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }

        let mainID = CGMainDisplayID()
        var result: [DisplayInfo] = []
        for id in ids.prefix(Int(count)) {
            // Gespiegelte Zweitbildschirme überspringen – sie zeigen denselben Inhalt.
            if CGDisplayMirrorsDisplay(id) != 0 { continue }
            guard let uuid = Self.uuidString(for: id) else { continue }
            let builtin = CGDisplayIsBuiltin(id) != 0
            let name = names[id] ?? (builtin ? "Integrierter Bildschirm" : "Bildschirm \(id)")
            result.append(DisplayInfo(displayID: id, uuid: uuid, name: name, bounds: CGDisplayBounds(id),
                                      isBuiltin: builtin, isMain: id == mainID))
        }
        result.sort { ($0.isMain ? 0 : 1, $0.bounds.minX) < ($1.isMain ? 0 : 1, $1.bounds.minX) }

        if result != connected {
            Log.displays.info("Bildschirme: \(result.map(\.name).joined(separator: ", "), privacy: .public)")
        }
        connected = result
        remember(result)
    }

    func forget(uuid: String) {
        known.removeAll { $0.uuid == uuid && !isConnected($0.uuid) }
        save()
    }

    func forgetAll() {
        known.removeAll { !isConnected($0.uuid) }
        save()
    }

    // MARK: - Persistenz

    private func remember(_ displays: [DisplayInfo]) {
        let now = Date()
        var list = known
        for d in displays {
            if let i = list.firstIndex(where: { $0.uuid == d.uuid }) {
                list[i].name = d.name
                list[i].width = d.bounds.width
                list[i].height = d.bounds.height
                list[i].originX = d.bounds.minX
                list[i].originY = d.bounds.minY
                list[i].isBuiltin = d.isBuiltin
                list[i].lastSeen = now
            } else {
                list.append(KnownDisplay(uuid: d.uuid, name: d.name, width: d.bounds.width, height: d.bounds.height,
                                         originX: d.bounds.minX, originY: d.bounds.minY, isBuiltin: d.isBuiltin,
                                         firstSeen: now, lastSeen: now))
            }
        }
        list.sort { $0.lastSeen > $1.lastSeen }
        known = list
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.displaysFile),
              let list = try? JSON.decoder.decode([KnownDisplay].self, from: data) else { return }
        known = list
    }

    private func save() {
        do {
            try JSON.encoder.encode(known).write(to: Paths.displaysFile, options: .atomic)
        } catch {
            Log.displays.error("Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
