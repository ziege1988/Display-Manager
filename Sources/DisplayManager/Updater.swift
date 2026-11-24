import AppKit
import CryptoKit
import Security

/// Ein Release auf GitHub.
struct GitHubRelease: Decodable, Identifiable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case id, name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    var version: Version { Version(tagName) }
    var displayName: String { (name?.isEmpty == false ? name! : tagName) }
    func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

enum UpdateError: LocalizedError {
    case notInstalledAsApp
    case missingAsset
    case checksumMismatch
    case unzipFailed
    case invalidBundle(String)
    case signatureMismatch
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .notInstalledAsApp: return "Die App läuft nicht als .app-Paket – Updates sind nicht möglich."
        case .missingAsset: return "Das Release enthält keine Datei „\(Updater.assetName)“."
        case .checksumMismatch: return "Die Prüfsumme des Downloads stimmt nicht – Update verworfen."
        case .unzipFailed: return "Das Update konnte nicht entpackt werden."
        case .invalidBundle(let reason): return "Ungültiges Update-Paket: \(reason)"
        case .signatureMismatch: return "Das Update ist nicht mit demselben Zertifikat signiert – Update verworfen."
        case .notWritable(let path): return "Keine Schreibrechte für \(path). Bitte die App in den Ordner „Programme“ verschieben."
        }
    }
}

/// Sucht über GitHub Releases nach Updates, lädt sie herunter und installiert sie beim nächsten Start.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let owner = "ziege1988"
    static let repo = "Display-Manager"
    static let assetName = "Display-Manager.zip"
    static let checkInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var releases: [GitHubRelease] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "Noch nicht geprüft"
    @Published private(set) var lastCheck: Date?
    @Published private(set) var stagedVersion: String?

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private init() {
        lastCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        stagedVersion = defaults.string(forKey: "stagedUpdateVersion")
        if stagedVersion != nil, !FileManager.default.fileExists(atPath: stagedAppURL.path) {
            clearStaged()
        }
        if let stagedVersion { statusText = "Version \(stagedVersion) ist bereit und wird beim nächsten Start installiert." }
    }

    var currentVersion: String { Bundle.main.shortVersion }
    var latestRelease: GitHubRelease? { releases.first { !$0.draft && !$0.prerelease } }
    var updateAvailable: Bool {
        guard let latest = latestRelease else { return false }
        return latest.version > Version(currentVersion)
    }

    private var stagedAppURL: URL { Paths.updates.appendingPathComponent("Display Manager.app") }
    private var isRunningFromAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - Zeitplan

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Preferences.shared.autoCheckUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    // MARK: - Prüfen

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        statusText = "Suche nach Updates …"
        Task {
            do {
                let list = try await fetchReleases()
                await MainActor.run {
                    self.releases = list
                    self.lastCheck = Date()
                    self.defaults.set(self.lastCheck, forKey: "lastUpdateCheck")
                    self.isBusy = false
                    self.handleCheckResult(userInitiated: userInitiated)
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusText = "Prüfung fehlgeschlagen: \(error.localizedDescription)"
                }
                Log.update.error("Prüfung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleCheckResult(userInitiated: Bool) {
        guard let latest = latestRelease, updateAvailable else {
            statusText = "Display Manager ist aktuell (Version \(currentVersion))."
            return
        }
        if stagedVersion == latest.version.description {
            statusText = "Version \(latest.version) ist bereit und wird beim nächsten Start installiert."
            return
        }
        statusText = "Version \(latest.version) ist verfügbar."
        if Preferences.shared.autoInstallUpdates || userInitiated {
            download(latest)
        }
    }

    private func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DisplayManager-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub antwortet mit Status \(http.statusCode)"])
        }
        return try JSON.decoder.decode([GitHubRelease].self, from: data)
            .filter { !$0.draft }
            .sorted { $0.version > $1.version }
    }

    // MARK: - Herunterladen & vorbereiten

    func download(_ release: GitHubRelease) {
        guard !isBusy else { return }
        guard isRunningFromAppBundle else {
            statusText = UpdateError.notInstalledAsApp.localizedDescription
            return
        }
        isBusy = true
        statusText = "Lade Version \(release.version) …"
        Task {
            do {
                try await stage(release)
                await MainActor.run {
                    self.isBusy = false
                    self.stagedVersion = release.version.description
                    self.defaults.set(self.stagedVersion, forKey: "stagedUpdateVersion")
                    self.statusText = "Version \(release.version) ist bereit und wird beim nächsten Start installiert."
                }
                Log.update.info("Update \(release.version.description, privacy: .public) vorbereitet")
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusText = "Update fehlgeschlagen: \(error.localizedDescription)"
                }
                Log.update.error("Update fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stage(_ release: GitHubRelease) async throws {
        guard let zipAsset = release.asset(named: Self.assetName) else { throw UpdateError.missingAsset }
        let fm = FileManager.default
        let work = Paths.updates.appendingPathComponent("download-\(release.version)", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Herunterladen
        let (tempZip, _) = try await URLSession.shared.download(from: zipAsset.browserDownloadURL)
        let zipURL = work.appendingPathComponent(Self.assetName)
        try fm.moveItem(at: tempZip, to: zipURL)

        // 2. Prüfsumme (SHA-256) vergleichen, falls im Release vorhanden
        if let shaAsset = release.asset(named: Self.assetName + ".sha256") {
            let (shaData, _) = try await URLSession.shared.data(from: shaAsset.browserDownloadURL)
            let expected = String(decoding: shaData, as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zipURL)).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw UpdateError.checksumMismatch }
        }

        // 3. Entpacken
        let unzipDir = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unzipDir.path]) == 0 else { throw UpdateError.unzipFailed }
        guard let appName = try fm.contentsOfDirectory(atPath: unzipDir.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.invalidBundle("keine .app im Archiv")
        }
        let newApp = unzipDir.appendingPathComponent(appName)

        // 4. Paket prüfen
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("falsche Bundle-ID")
        }
        guard Version(bundle.shortVersion) == release.version else {
            throw UpdateError.invalidBundle("Version passt nicht zum Release")
        }
        try Self.verifySameSigner(newApp)

        // 5. Bereitlegen
        try? fm.removeItem(at: stagedAppURL)
        try fm.moveItem(at: newApp, to: stagedAppURL)
    }

    /// Ist die laufende App mit einem Zertifikat signiert, muss das Update dieselbe Signatur-Anforderung erfüllen.
    /// Bei Ad-hoc-Signatur (ändert sich mit jedem Build) entfällt dieser Schritt.
    private static func verifySameSigner(_ url: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else { return }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else { return }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return }
        if (text as String).contains("cdhash") { return } // Ad-hoc-signiert

        var newStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &newStatic) == errSecSuccess, let newStatic,
              SecStaticCodeCheckValidity(newStatic, [], requirement) == errSecSuccess else {
            throw UpdateError.signatureMismatch
        }
    }

    // MARK: - Installieren

    /// Beim App-Start aufrufen. Liegt ein Update bereit, wird es installiert und die App neu gestartet.
    /// Gibt `true` zurück, wenn die App sich deshalb gleich beendet.
    func installStagedUpdateIfNeeded() -> Bool {
        guard let staged = stagedVersion else { return false }
        guard Version(staged) > Version(currentVersion) else {
            clearStaged() // bereits installiert
            return false
        }
        guard Preferences.shared.autoInstallUpdates else { return false }
        // Schutz vor Endlosschleifen, falls die Installation scheitert.
        let attemptsKey = "installAttempts-\(staged)"
        let attempts = defaults.integer(forKey: attemptsKey)
        guard attempts < 2 else {
            Log.update.error("Installation von \(staged, privacy: .public) mehrfach gescheitert – verworfen")
            clearStaged()
            return false
        }
        defaults.set(attempts + 1, forKey: attemptsKey)
        do {
            try launchInstaller()
            return true
        } catch {
            statusText = error.localizedDescription
            return false
        }
    }

    /// Manuell aus den Einstellungen: sofort installieren und neu starten.
    func installNow() {
        do {
            try launchInstaller()
            NSApp.terminate(nil)
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func launchInstaller() throws {
        guard isRunningFromAppBundle else { throw UpdateError.notInstalledAsApp }
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") { throw UpdateError.notWritable(target.path) }
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }

        // Wartet, bis diese App beendet ist, tauscht das Paket aus und startet die neue Version.
        let script = """
        PID="$1"; SRC="$2"; DST="$3"
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        BAK="${DST}.alt-$$"
        mv "$DST" "$BAK" || { open "$DST"; exit 1; }
        if /usr/bin/ditto "$SRC" "$DST"; then
          rm -rf "$BAK" "$SRC"
        else
          rm -rf "$DST"; mv "$BAK" "$DST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        open "$DST"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "display-manager-updater",
                             String(getpid()), stagedAppURL.path, target.path]
        try process.run()
        Log.update.info("Installer gestartet für \(self.stagedVersion ?? "?", privacy: .public)")
    }

    private func clearStaged() {
        try? FileManager.default.removeItem(at: stagedAppURL)
        stagedVersion = nil
        defaults.removeObject(forKey: "stagedUpdateVersion")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
