import AppKit

/// Kleine Befehls-Apps zum Auslösen von Display-Manager-Funktionen aus anderer Software
/// (z. B. Loupedeck „Befehl ausführen“ mit einem Pfad). Jede App sendet nur einen
/// displaymanager://-Befehl und beendet sich sofort – ohne Fenster, Dock-Symbol oder Terminal.
///
/// Die Apps werden lokal erzeugt (nicht heruntergeladen) und daher von Gatekeeper nicht blockiert.
enum CommandApps {
    struct Command {
        let appName: String
        let url: String
    }

    static let photoshopDuplicate = Command(appName: "Photoshop-Duplikat", url: PhotoshopDuplicator.urlCommand)
    static let restoreAll = Command(appName: "Fenster wiederherstellen", url: "displaymanager://wiederherstellen")
    static let all = [photoshopDuplicate, restoreAll]

    static var folder: URL {
        let url = Paths.appSupport.appendingPathComponent("Befehle", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for command: Command) -> URL {
        folder.appendingPathComponent("\(command.appName).app", isDirectory: true)
    }

    /// Legt alle Befehls-Apps an bzw. aktualisiert sie (wird bei jedem Start aufgerufen).
    static func installAll() {
        for command in all {
            do {
                try install(command)
            } catch {
                Log.general.error("Befehls-App \(command.appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func install(_ command: Command) throws {
        let fm = FileManager.default
        let app = url(for: command)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        # Erzeugt von Display Manager – sendet den Befehl an Display Manager.
        exec /usr/bin/open -g "\(command.url)"
        """
        let identifier = "io.github.ziege1988.displaymanager.befehl." +
            command.appName.lowercased().filter { $0.isLetter || $0.isNumber }
        let plist: [String: Any] = [
            "CFBundleExecutable": "run",
            "CFBundleIdentifier": identifier,
            "CFBundleName": command.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Bundle.main.shortVersion,
            "CFBundleVersion": "1",
            "LSBackgroundOnly": true, // kein Dock-Symbol, nimmt Photoshop nicht den Fokus
            "LSMinimumSystemVersion": "13.0",
        ]

        let scriptURL = macOS.appendingPathComponent("run")
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistURL = contents.appendingPathComponent("Info.plist")

        // Nur schreiben, wenn sich etwas geändert hat.
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        if (try? Data(contentsOf: plistURL)) != plistData {
            try plistData.write(to: plistURL, options: .atomic)
        }
    }

    static func revealInFinder(_ command: Command) {
        installAll()
        NSWorkspace.shared.activateFileViewerSelecting([url(for: command)])
    }

    static func copyPath(_ command: Command) {
        installAll()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url(for: command).path, forType: .string)
    }
}
