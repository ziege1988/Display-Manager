import Foundation
import os

/// Zentrales Logging (sichtbar in der Konsole-App unter dem Subsystem der App).
enum Log {
    private static let subsystem = "io.github.ziege1988.displaymanager"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let windows = Logger(subsystem: subsystem, category: "windows")
    static let displays = Logger(subsystem: subsystem, category: "displays")
    static let update = Logger(subsystem: subsystem, category: "update")
}

/// Ablageorte der App-Daten.
enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Display Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var windowsFile: URL { appSupport.appendingPathComponent("windows.json") }
    static var displaysFile: URL { appSupport.appendingPathComponent("displays.json") }

    static var updates: URL {
        let url = appSupport.appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// JSON-Hilfen mit einheitlichem Datumsformat.
enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Semantische Versionsnummer, z. B. "1.2.3" oder "v1.2.3".
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Alles ab "-" oder "+" (Pre-Release/Build-Metadaten) ignorieren.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        parts = s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<count {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
