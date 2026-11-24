import AppKit
import SwiftUI

/// Fenster für die Einstellungen (die App hat sonst keine Fenster).
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: SettingsTab = .general) {
        SettingsState.shared.tab = tab
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Display Manager – Einstellungen"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable { case general, displays, apps, updates }

final class SettingsState: ObservableObject {
    static let shared = SettingsState()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject private var state = SettingsState.shared

    var body: some View {
        TabView(selection: $state.tab) {
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag(SettingsTab.general)
            DisplaysTab().tabItem { Label("Bildschirme", systemImage: "display.2") }.tag(SettingsTab.displays)
            AppsTab().tabItem { Label("Apps", systemImage: "macwindow.on.rectangle") }.tag(SettingsTab.apps)
            UpdatesTab().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.updates)
        }
        .padding()
        .frame(width: 660, height: 500)
    }
}

// MARK: - Allgemein

private struct GeneralTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var trusted = AX.isTrusted
    @State private var confirmReset = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 52, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Display Manager").font(.title2.bold())
                        Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Berechtigung") {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Bedienungshilfen-Zugriff erteilt"
                                 : "Bedienungshilfen-Zugriff fehlt – ohne ihn können keine Fenster verschoben werden.")
                    Spacer()
                    if !trusted {
                        Button("Freigeben …") {
                            AX.requestTrust()
                            AX.openAccessibilitySettings()
                        }
                    }
                }
            }
            Section("Verhalten") {
                Toggle("Beim Anmelden automatisch starten", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { if $0 != LoginItem.isEnabled { LoginItem.setEnabled($0) } }
                if LoginItem.requiresApproval {
                    Text("Bitte in den Systemeinstellungen › Allgemein › Anmeldeobjekte bestätigen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Fenster beim Öffnen an letzte Position und Größe setzen", isOn: $prefs.restoreEnabled)
                Toggle("Fenster zurückholen, wenn Bildschirme an-/abgesteckt werden", isOn: $prefs.restoreOnDisplayChange)
                Toggle("Pausiert", isOn: $prefs.paused)
            }
            Section("Daten") {
                HStack {
                    Text("Gespeichert in „~/Library/Application Support/Display Manager“")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.windowsFile]) }
                    Button("Alles vergessen …", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            trusted = AX.isTrusted
            loginEnabled = LoginItem.isEnabled
        }
        .confirmationDialog("Alle gespeicherten Fensterpositionen löschen?", isPresented: $confirmReset) {
            Button("Löschen", role: .destructive) {
                WindowStore.shared.forgetAll()
                DisplayRegistry.shared.forgetAll()
            }
        }
    }
}

// MARK: - Bildschirme

private struct DisplaysTab: View {
    @ObservedObject private var registry = DisplayRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alle Bildschirme, die jemals an diesem Mac angeschlossen waren. Fensterpositionen werden je Bildschirm-Kombination gemerkt.")
                .font(.callout).foregroundStyle(.secondary)
            List(registry.known) { display in
                let connected = registry.isConnected(display.uuid)
                HStack(spacing: 12) {
                    Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                        .font(.title2).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.name).font(.headline)
                        Text("\(Int(display.width)) × \(Int(display.height)) Punkte · Position \(Int(display.originX)), \(Int(display.originY))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(connected ? "Zuerst gesehen \(display.firstSeen.formatted(date: .abbreviated, time: .omitted))"
                                       : "Zuletzt gesehen \(display.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connected {
                        Label("Verbunden", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                            .foregroundStyle(.green).font(.caption)
                    } else {
                        Button("Vergessen") { registry.forget(uuid: display.uuid) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { registry.refresh() }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @ObservedObject private var store = WindowStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps, deren Fenster gemerkt wurden. Ignorierte Apps werden weder gespeichert noch verschoben.")
                .font(.callout).foregroundStyle(.secondary)
            if store.apps.isEmpty {
                Spacer()
                Text("Noch keine Fenster gemerkt.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(store.sortedApps) { app in
                    HStack(spacing: 12) {
                        AppIconView(bundleID: app.bundleID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline)
                            Text("\(app.windows.count) Fenster · zuletzt \(app.lastUsed.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Ignorieren", isOn: Binding(
                            get: { app.excluded },
                            set: { store.setExcluded(app.bundleID, name: app.name, excluded: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        Button("Vergessen") { store.forget(app.bundleID) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct AppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.dashed").font(.title2).frame(width: 28, height: 28)
        }
    }
}

// MARK: - Updates

private struct UpdatesTab: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installiert: Version \(updater.currentVersion)").font(.headline)
                    Text(updater.statusText).foregroundStyle(.secondary)
                    if let last = updater.lastCheck {
                        Text("Zuletzt geprüft: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if updater.isBusy { ProgressView().controlSize(.small) }
                Button("Jetzt prüfen") { updater.check(userInitiated: false) }.disabled(updater.isBusy)
            }

            HStack {
                if updater.stagedVersion != nil {
                    Button("Jetzt installieren und neu starten") { updater.installNow() }
                        .buttonStyle(.borderedProminent)
                } else if updater.updateAvailable, let latest = updater.latestRelease {
                    Button("Version \(latest.version.description) laden") { updater.download(latest) }
                        .buttonStyle(.borderedProminent).disabled(updater.isBusy)
                }
            }

            Toggle("Automatisch nach Updates suchen (alle 6 Stunden)", isOn: $prefs.autoCheckUpdates)
            Toggle("Updates automatisch laden und beim nächsten Start installieren", isOn: $prefs.autoInstallUpdates)

            Divider()
            Text("Versionen").font(.headline)
            if updater.releases.isEmpty {
                Text("Noch keine Versionen geladen – „Jetzt prüfen“ klicken.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(updater.releases) { release in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(release.displayName).font(.headline)
                            if release.prerelease { Text("Vorabversion").font(.caption).foregroundStyle(.orange) }
                            if release.version == Version(updater.currentVersion) {
                                Text("installiert").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            if let date = release.publishedAt {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            Link("GitHub", destination: release.htmlURL).font(.caption)
                        }
                        if let body = release.body, !body.isEmpty {
                            Text(Self.markdown(body)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { if updater.releases.isEmpty { updater.check(userInitiated: false) } }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
