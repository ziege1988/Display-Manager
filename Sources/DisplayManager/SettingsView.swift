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

enum SettingsTab: Hashable { case general, displays, apps, photoshop, power, updates }

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
            PhotoshopTab().tabItem { Label("Photoshop", systemImage: "rectangle.on.rectangle") }.tag(SettingsTab.photoshop)
            PowerTab().tabItem { Label("Strom", systemImage: "powerplug") }.tag(SettingsTab.power)
            UpdatesTab().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.updates)
        }
        .padding()
        .frame(width: 720, height: 600)
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
                if !trusted {
                    HStack {
                        Text("Schon aktiviert, aber die Meldung bleibt? Dann gehört der Eintrag noch zur vorherigen Version.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Freigabe reparieren") { AX.resetAndRequestTrust() }
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

// MARK: - Photoshop

private struct PhotoshopTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var registry = DisplayRegistry.shared
    @ObservedObject private var duplicator = PhotoshopDuplicator.shared

    var body: some View {
        Form {
            Section {
                Text("Erzeugt eine zweite Ansicht des aktuellen Dokuments (Fenster › Anordnen › Neues Fenster für …), löst sie als schwebendes Fenster, legt sie auf den gewählten Bildschirm und lässt sie ihn ganz ausfüllen. Es wird kein neues Dokument und keine Ebene erzeugt – Änderungen erscheinen live in beiden Fenstern.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Ziel") {
                Picker("Bildschirm für das Duplikat", selection: $prefs.photoshopTargetDisplay) {
                    Text("Automatisch (anderer Bildschirm als das Original)").tag("")
                    ForEach(registry.known) { display in
                        Text(registry.isConnected(display.uuid) ? display.name : "\(display.name) (nicht verbunden)")
                            .tag(display.uuid)
                    }
                }
                Toggle("Im Duplikat „Ganzes Bild“ anzeigen (Übersicht)", isOn: $prefs.photoshopFitOnScreen)
            }
            Section("Auslöser") {
                Toggle("Tastenkürzel aktiv", isOn: $prefs.hotKeyEnabled)
                    .onChange(of: prefs.hotKeyEnabled) { _ in NotificationCenter.default.post(name: .hotKeyChanged, object: nil) }
                HStack {
                    Text("Taste")
                    Spacer()
                    HotKeyRecorder()
                }
                Text("Eine einzelne Taste reicht. F13 kollidiert mit nichts und lässt sich gut auf eine Loupedeck- oder Wacom-Taste legen. Normale Buchstaben brauchen eine Zusatztaste (⌘, ⌥ oder ⌃).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Loupedeck CT („Befehl ausführen“)") {
                Text("Lege einer Loupedeck-Taste die Aktion „Befehl ausführen“ zu und wähle diese Datei als Pfad. Sie startet unsichtbar, löst das Duplikat aus und beendet sich sofort.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(CommandApps.url(for: CommandApps.photoshopDuplicate).path)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Pfad kopieren") { CommandApps.copyPath(CommandApps.photoshopDuplicate) }
                    Button("Im Finder zeigen") { CommandApps.revealInFinder(CommandApps.photoshopDuplicate) }
                    Spacer()
                }
                Text("Tipp: Im Dateiauswahl-Dialog ⇧⌘G drücken und den kopierten Pfad einfügen. Falls Loupedeck ein Befehlsfeld statt eines Pfads anbietet: open -g \(PhotoshopDuplicator.urlCommand)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Test") {
                HStack {
                    Button("Jetzt ausführen") { duplicator.trigger() }.disabled(duplicator.isRunning)
                    Button("Diagnose kopieren") { duplicator.copyDiagnosticsToClipboard() }
                    Spacer()
                    if duplicator.isRunning { ProgressView().controlSize(.small) }
                }
                Text(duplicator.lastResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { registry.refresh() }
    }
}

/// Nimmt ein Tastenkürzel auf: Klicken, dann die gewünschte Taste drücken (Esc bricht ab).
private struct HotKeyRecorder: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        HStack(spacing: 8) {
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.orange) }
            Button(recording ? "Taste drücken …" : prefs.hotKeyLabel) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            Button("F13") { apply(keyCode: 105, modifiers: 0, label: "F13") }
                .help("Auf Standard zurücksetzen")
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == 53 { stop(); return } // Esc
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let modifiers = HotKey.carbonModifiers(from: flags)
        let isFunctionKey = HotKey.functionKeys[keyCode] != nil
        let hasRealModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard isFunctionKey || hasRealModifier else {
            hint = "Bitte F-Taste oder mit ⌘/⌥/⌃"
            return
        }
        let keyName = HotKey.functionKeys[keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        apply(keyCode: keyCode, modifiers: modifiers, label: HotKey.modifierSymbols(modifiers) + keyName)
        stop()
    }

    private func apply(keyCode: Int, modifiers: Int, label: String) {
        prefs.hotKeyCode = keyCode
        prefs.hotKeyModifiers = modifiers
        prefs.hotKeyLabel = label
        hint = ""
        NotificationCenter.default.post(name: .hotKeyChanged, object: nil)
    }
}

// MARK: - Strom

private struct PowerTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var power = PowerManager.shared

    var body: some View {
        Form {
            Section {
                Text("Schaltet eine Steckdose über deine Kurzbefehle (z. B. Apple Home): beim Ausschalten des Mac und nach Akkustand.")
                    .font(.callout).foregroundStyle(.secondary)
                if let battery = power.battery {
                    HStack {
                        Image(systemName: battery.onAC ? "battery.100.bolt" : "battery.50")
                        Text("Akku \(battery.level) % · \(battery.onAC ? (battery.isCharging ? "lädt am Netzteil" : "am Netzteil") : "auf Akku")")
                    }
                }
            }
            Section("Kurzbefehle") {
                Toggle("Ein Kurzbefehl schaltet ein und aus (Umschalter)", isOn: $prefs.powerToggleMode)
                if prefs.powerToggleMode {
                    shortcutPicker("Umschalter", selection: $prefs.powerToggleShortcut)
                    Text("Der Umschalter wird nur ausgeführt, wenn sich der Zustand ändern muss. Erkannt wird das am Netzteil: liefert es Strom, ist die Steckdose an. Dafür muss das MacBook an dieser Steckdose hängen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    shortcutPicker("Strom ein", selection: $prefs.powerOnShortcut)
                    shortcutPicker("Strom aus", selection: $prefs.powerOffShortcut)
                }
                HStack {
                    Button("Strom ein testen") { power.switchPower(on: true, reason: "Test") }
                    Button("Strom aus testen") { power.switchPower(on: false, reason: "Test") }
                    Button("Liste aktualisieren") { power.refreshShortcutList() }
                    Spacer()
                    if power.isRunningShortcut { ProgressView().controlSize(.small) }
                }
                Text(power.lastAction).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Beim Ausschalten") {
                Toggle("Strom ausschalten, wenn der Mac ausgeschaltet wird", isOn: $prefs.powerOffOnShutdown)
                Toggle("Auch beim Neustart ausschalten", isOn: $prefs.powerOffOnRestart)
                Text("Der Mac wartet beim Herunterfahren, bis der Kurzbefehl ausgeführt wurde (höchstens 20 Sekunden).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if power.hasBattery {
                Section("Nach Akkustand") {
                    Toggle("Automatisch nach Akkustand schalten", isOn: $prefs.batteryControlEnabled)
                    Stepper("Strom ein bei \(prefs.batteryLowThreshold) % oder weniger",
                            value: $prefs.batteryLowThreshold, in: 5...(max(10, prefs.batteryHighThreshold - 10)), step: 5)
                    Stepper("Strom aus bei \(prefs.batteryHighThreshold) % oder mehr",
                            value: $prefs.batteryHighThreshold, in: (min(95, prefs.batteryLowThreshold + 10))...100, step: 5)
                    Text("Ob geschaltet wurde, erkennt Display Manager daran, ob das Netzteil Strom liefert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Befehle für Loupedeck & Co.") {
                Text("displaymanager://strom-ein  ·  displaymanager://strom-aus")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            power.refreshBattery()
            power.refreshShortcutList()
        }
    }

    @ViewBuilder
    private func shortcutPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            if !power.availableShortcuts.contains(selection.wrappedValue) {
                Text(selection.wrappedValue.isEmpty ? "– keiner –" : "\(selection.wrappedValue) (nicht gefunden)")
                    .tag(selection.wrappedValue)
            }
            ForEach(power.availableShortcuts, id: \.self) { Text($0).tag($0) }
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
