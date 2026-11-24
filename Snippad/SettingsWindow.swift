import AppKit
import ServiceManagement
import SwiftUI

/// The settings, in a window of their own. Everything is saved to
/// `~/.snippad/settings.json` as it changes.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?

    static func show(tab: SettingsTab = .general) {
        SettingsModel.shared.tab = tab
        if controller == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 720, height: 520))
            window.title = "Snippad Settings"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("SnippadSettings")
            window.center()
            controller = NSWindowController(window: window)
        }
        AppActivation.show(controller!.window!)
    }
}

enum SettingsTab: Hashable { case general, applications, pasteGuard }

@MainActor
@Observable
final class SettingsModel {
    static let shared = SettingsModel()
    var tab: SettingsTab = .general
}

private struct SettingsView: View {
    @State private var model = SettingsModel.shared

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ApplicationsTab().tabItem { Label("Applications", systemImage: "app.badge") }.tag(SettingsTab.applications)
            PasteGuardTab().tabItem { Label("Paste Guard", systemImage: "hand.raised") }.tag(SettingsTab.pasteGuard)
        }
        .padding()
        .frame(minWidth: 620, minHeight: 440)
    }
}

/// Re-reads permission and login state when the window comes forward,
/// since they are changed in System Settings.
@MainActor
private struct SystemState {
    var trusted = PasteInterceptor.isTrusted
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
}

private struct GeneralTab: View {
    @State private var store = SettingsStore.shared
    @State private var system = SystemState()
    @State private var usage = ClipboardHistory.shared.diskUsageText
    /// An age limit that would delete entries, waiting to be confirmed.
    @State private var pendingAge: (days: Int, count: Int)?

    static let ages: [(days: Int, title: String)] = [
        (0, "Never"), (1, "1 day"), (7, "1 week"), (14, "2 weeks"), (30, "1 month"), (60, "2 months"),
        (90, "3 months"), (180, "6 months"), (365, "1 year"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: store.value.recordHistory ? "record.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(store.value.recordHistory ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record Clipboard History").font(.title3.weight(.semibold))
                        Text(store.value.recordHistory
                             ? "Everything you copy is kept in the history, by list."
                             : "Paused: nothing new is recorded. The history, snippets and Paste Guard keep working.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Record Clipboard History", isOn: $store.value.recordHistory)
                        .toggleStyle(.switch)
                        .controlSize(.large)
                        .labelsHidden()
                }
                .padding(.vertical, 6)
            }
            Section("Clipboard history") {
                Picker("Keep per list", selection: $store.value.historyLimit) {
                    ForEach([50, 100, 200, 500, 1000, 5000], id: \.self) { Text("\($0) unpinned entries").tag($0) }
                }
                Picker("Delete unpinned entries older than", selection: Binding(
                    get: { store.value.historyMaxAgeDays },
                    set: { days in
                        let count = ClipboardHistory.shared.countOlder(thanDays: days)
                        if count > 0 && (days < store.value.historyMaxAgeDays || store.value.historyMaxAgeDays == 0) {
                            pendingAge = (days, count)
                        } else {
                            ClipboardHistory.shared.maxAgeDays = days
                        }
                    })) {
                    ForEach(Self.ages, id: \.days) { Text($0.title).tag($0.days) }
                }
                LabeledContent("On disk") {
                    HStack {
                        Text(usage)
                        Button("Show in Finder") {
                            reveal(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("Snippad/History", isDirectory: true))
                        }
                    }
                }
                Text("Both limits apply to each list. Pinned entries are kept, however many and however old. Deleted entries can be brought back for five minutes with Undo Delete.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Paste after choosing an entry from the menu or the picker window", isOn: $store.value.pasteAfterChoosing)
            }
            Section("Shortcuts") {
                HotKeyRow(title: "Open the history menu", enabled: $store.value.hotKeyEnabled, keys: $store.value.historyHotKey,
                          defaultKeys: SnippadSettings.defaultHotKeys.history)
                HotKeyRow(title: "Open the preferred list\u{2019}s picker", enabled: $store.value.pickerHotKeyEnabled,
                          keys: $store.value.pickerHotKey, defaultKeys: SnippadSettings.defaultHotKeys.picker)
                HotKeyRow(title: "Open the Snippad Organizer", enabled: $store.value.organizerHotKeyEnabled,
                          keys: $store.value.organizerHotKey, defaultKeys: SnippadSettings.defaultHotKeys.organizer)
                Text("Click a shortcut and press the new keys, with ⌃, ⌥ or ⌘ (a function key may stand alone); Escape cancels. While a shortcut is on, Snippad takes it in every app: ⇧⌘V is Paste and Match Style in many apps, and ⇧⌘H opens the home folder in Finder and Safari. Switch it off, or choose other keys, if it gets in the way.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sounds") {
                SoundPicker(title: "When Snippad puts something on the clipboard", name: $store.value.copySound)
                Toggle("Also when something is copied in another app", isOn: $store.value.copySoundForOtherApps)
                    .disabled(store.value.copySound.isEmpty)
                SoundPicker(title: "When Snippad pastes for you", name: $store.value.pasteSound)
            }
            Section("Screenshots") {
                Picker("Delayed screenshots wait", selection: $store.value.screenshotDelay) {
                    ForEach(Screenshots.delays, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Screenshots go to the list", selection: $store.value.screenshotList) {
                    Text(store.value.lists[0].name).tag(String?.none)
                    ForEach(store.value.lists.dropFirst()) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("Take Screenshot is in the menu bar menu. The picture goes on the clipboard and into this list. Snippad needs the Screen Recording permission for it; macOS asks the first time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Image editor") {
                Picker("Copied objects go to", selection: Binding(
                    get: { store.value.imageObjectsRecorded ? (store.value.imageObjectsList ?? ClipList.defaultID) : "" },
                    set: { id in
                        store.value.imageObjectsRecorded = !id.isEmpty
                        store.value.imageObjectsList = id.isEmpty || id == ClipList.defaultID ? nil : id
                    })) {
                    ForEach(store.value.lists) { Text($0.name).tag($0.id) }
                    Divider()
                    Text("Not kept in the history").tag("")
                }
                Text("Shapes, lines, texts, markers and the rest copied in the image editor (⌘C, ⌘X) paste into any image editor, also another image's. On the clipboard they are a picture too, for other apps. A selected area is copied as a picture, as it looks. Copies are kept in this list, or only on the clipboard.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Copies from other devices") {
                Toggle("Keep copies from iPhone, iPad and other Macs in a list of their own", isOn: Binding(
                    get: { !store.value.remoteListOptOut },
                    set: { store.value.remoteListOptOut = !$0 }))
                if !store.value.remoteListOptOut {
                    Picker("The list", selection: $store.value.remoteList) {
                        Text("Ask at the next copy from another device").tag(String?.none)
                        ForEach(store.value.lists) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Toggle("Put them on the Mac\u{2019}s clipboard right away", isOn: $store.value.remoteToLocal)
                Text("A copy from another device arrives through Universal Clipboard as a promise: macOS fetches it from the device when you paste, and only for a short time. With this on, Snippad puts the copy it recorded back on the clipboard as the Mac\u{2019}s own, so it pastes straight away and later too. One list holds the copies of all your devices; macOS does not tell which device a copy came from.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open Snippad at login", isOn: Binding(
                    get: { system.loginEnabled },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            presentError(error, title: "The login item could not be changed")
                        }
                        system = SystemState()
                    }))
                if system.loginNeedsApproval {
                    LabeledContent("Needs approval") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Text("At login macOS starts Snippad in the background: it puts its icon in the menu bar, scans the installed applications, and starts recording. It also starts by itself when you open a .snippad file, and when an agent starts its MCP server.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if system.trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            PasteInterceptor.requestAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                LabeledContent("Keyboard tap") { TapStatusText() }
                Text("Allowing Accessibility (once, with your password) does not install anything. Snippad installs its keyboard tap only while a paste-once or chained value waits on the clipboard, or while the Paste Guard is on and the clipboard holds something from a restricted list -- and removes it as soon as neither is true. No prompt either way.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Files") {
                LabeledContent("Settings") {
                    Button("Show in Finder") { reveal(store.url) }
                }
                LabeledContent("Applications seen") {
                    Button("Show in Finder") { reveal(SnippadHome.directory.appendingPathComponent("apps.json")) }
                }
                LabeledContent("Agents (MCP)") {
                    Button("Copy Setup Command") { StatusMenu.copyMCPCommand() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            system = SystemState()
            usage = ClipboardHistory.shared.diskUsageText
        }
        .onChange(of: ClipboardHistory.shared.items.count) { usage = ClipboardHistory.shared.diskUsageText }
        .confirmationDialog(pendingAge.map { "Delete \($0.count) entries now?" } ?? "",
                            isPresented: Binding(get: { pendingAge != nil }, set: { if !$0 { pendingAge = nil } })) {
            Button("Delete Them", role: .destructive) {
                if let pendingAge { ClipboardHistory.shared.maxAgeDays = pendingAge.days }
                pendingAge = nil
            }
            Button("Cancel", role: .cancel) { pendingAge = nil }
        } message: {
            Text("\(pendingAge?.count ?? 0) unpinned entries are older than that, and are deleted at once. Pinned entries stay.")
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ApplicationsTab: View {
    @State private var store = SettingsStore.shared
    @State private var catalog = AppCatalog.shared
    @State private var query = ""
    @State private var onlyCopiedFrom = false
    @State private var onlyMissing = false

    private var missingCount: Int { catalog.apps.values.filter { $0.missing == true }.count }

    private var rows: [AppRecord] {
        catalog.sorted.filter { app in
            (!onlyCopiedFrom || (app.copies ?? 0) > 0)
                && (!onlyMissing || app.missing == true)
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query) || app.bundleID.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Copies from an application go to its list, unless it is not recorded. Applications are found in the application folders at every launch, and remembered once something was copied from them.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search applications", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Only apps copied from", isOn: $onlyCopiedFrom)
                if missingCount > 0 || onlyMissing {
                    Toggle("Only not found (\(missingCount))", isOn: $onlyMissing)
                }
            }
            Table(rows) {
                TableColumn("Application") { app in
                    HStack {
                        Image(nsImage: catalog.icon(for: app.bundleID)).resizable().frame(width: 16, height: 16)
                            .opacity(app.missing == true ? 0.4 : 1)
                        Text(app.name)
                            .foregroundStyle(app.missing == true ? .secondary : .primary)
                            .help(app.bundleID + (app.path.map { "\n\($0)" } ?? ""))
                    }
                }
                .width(min: 160, ideal: 200)
                TableColumn("Status") { app in
                    if app.missing == true {
                        HStack(spacing: 6) {
                            Text("Not found").foregroundStyle(.red)
                                .help("The application is gone from \(app.path ?? "its folder"), but settings still name it")
                            Button("Locate…") { locate(app) }
                            Button("Remove") { catalog.remove(app.bundleID, settings: store) }
                                .help("Forget the application and every setting that names it")
                        }
                        .controlSize(.small)
                    } else {
                        Text(app.installed == true ? "Installed" : "Found").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 210)
                TableColumn("Copies") { app in
                    Text(app.copies.map(String.init) ?? "–").foregroundStyle(.secondary)
                        .help(app.lastCopy.map { "Last copy \($0.formatted())" } ?? "Nothing copied from it yet")
                }
                .width(60)
                TableColumn("Record") { app in
                    Toggle("", isOn: Binding(get: { !store.isExcluded(app.bundleID) },
                                             set: { store.setExcluded(app.bundleID, !$0) }))
                        .labelsHidden()
                        .help("Off: copies from this application are not recorded")
                }
                .width(56)
                TableColumn("List") { app in
                    Picker("", selection: Binding(get: { store.listID(for: app.bundleID) },
                                                  set: { id in
                                                      store.value.appLists[app.bundleID] = id == ClipList.defaultID ? nil : id
                                                  })) {
                        ForEach(store.value.lists) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                .width(min: 120, ideal: 160)
            }
        }
    }
}

extension ApplicationsTab {
    func locate(_ app: AppRecord) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Where is \(app.name) (\(app.bundleID)) now?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AppCatalog.shared.locate(app.bundleID, at: url)
        } catch {
            presentError(error, title: "That is not the application")
        }
    }
}

private struct PasteGuardTab: View {
    @State private var store = SettingsStore.shared
    @State private var system = SystemState()

    var body: some View {
        Form {
            Section {
                Toggle("Check every paste against the rules of the clipboard\u{2019}s list", isOn: $store.value.pasteGuardEnabled)
                Text("When you type ⌘V, Snippad looks at which list the clipboard\u{2019}s content belongs to and at the application in front. If the list\u{2019}s rules do not allow that application -- or, for a list that is only for private browsing, the browser window is not a private one -- the ⌘V is stopped and a note says why.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Rules") {
                Text("Each list has its own rules: which applications its entries may be pasted into, and whether only private browser windows may get them. Lists and their rules are edited in the Snippad Organizer: right-click a list in its sidebar and choose Edit List.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open the Lists in the Organizer") { HistoryWindow.show(editingList: ClipList.defaultID) }
            }
            Section("What it needs, and what it cannot do") {
                LabeledContent("Accessibility") {
                    if system.trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            PasteInterceptor.requestAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                LabeledContent("Keyboard tap") { TapStatusText() }
                Text("""
                    • The keyboard tap exists only while the clipboard holds something from a list with restrictions; security software may report Snippad as intercepting keystrokes during that time. Lists that allow any application never install it.
                    • Only ⌘V is checked. Paste from an Edit menu, a context menu, or drag and drop is not.
                    • Private windows are recognised in Chrome, Brave, Edge, Vivaldi and Chromium (macOS asks once per browser whether Snippad may control it), in Firefox and its relatives, and in Tor Browser. Safari does not tell, so it counts as not private.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            system = SystemState()
        }
    }
}

private struct TapStatusText: View {
    @State private var status = KeyboardTapStatus.shared

    var body: some View {
        if status.active {
            Label("Installed, for \(status.reason)", systemImage: "keyboard.badge.eye").foregroundStyle(.orange)
        } else if status.blocked {
            Label("Needed for \(status.reason), but Accessibility is not allowed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else {
            Label("Not installed", systemImage: "keyboard").foregroundStyle(.secondary)
        }
    }
}

/// A global shortcut: on or off, and its keys, recorded by pressing them.
private struct HotKeyRow: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var keys: String
    let defaultKeys: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    private var shortcut: KeyShortcut? { KeyShortcut(keys) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(title, isOn: $enabled)
                Spacer()
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Press the keys\u{2026}" : shortcut?.display ?? keys)
                        .monospaced()
                        .frame(minWidth: 90)
                }
                .disabled(!enabled)
                .help("Click, then press the new keys. Escape cancels.")
                Button("Default") { keys = defaultKeys; message = nil }
                    .disabled(keys == defaultKeys)
            }
            if let note = message ?? warning {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    /// Another of Snippad's shortcuts, or a snippet, has the same keys; or
    /// macOS did not give them to Snippad.
    private var warning: String? {
        guard enabled, let shortcut else { return nil }
        let s = SettingsStore.shared.value
        let others = [(s.hotKeyEnabled, s.historyShortcut, "the history menu"), (s.pickerHotKeyEnabled, s.pickerShortcut, "the picker"),
                      (s.organizerHotKeyEnabled, s.organizerShortcut, "the Organizer")]
            .filter { $0.0 && $0.1 == shortcut }
        if others.count > 1 { return "\(shortcut.display) is used twice; only one of them works." }
        if let snippet = SnippetShortcuts.assigned().first(where: { $0.snippet.shortcut.flatMap(KeyShortcut.init) == shortcut }) {
            return "\(shortcut.display) is also the shortcut of \u{201C}\(snippet.snippet.name)\u{201D}; Snippad\u{2019}s own shortcut wins."
        }
        if StatusMenu.shared.unavailableHotKeys.contains(shortcut) {
            return "macOS did not give Snippad \(shortcut.display); another app may have it."
        }
        return nil
    }

    private func start() {
        message = nil
        recording = true
        SnippetShortcuts.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape
                stop()
                return nil
            }
            guard let new = KeyShortcut(keyCode: event.keyCode, flags: event.modifierFlags) else {
                message = "That key cannot be a shortcut; use a letter, digit, punctuation or function key."
                return nil
            }
            guard new.isUsable else {
                message = "Hold ⌃, ⌥ or ⌘ with the key (only function keys may stand alone)."
                return nil
            }
            keys = new.text
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            SnippetShortcuts.resume()
        }
    }
}

/// One of macOS's alert sounds, or none; choosing one plays it.
private struct SoundPicker: View {
    let title: String
    @Binding var name: String

    var body: some View {
        HStack {
            Picker(title, selection: Binding(get: { name }, set: { name = $0; SnippadSound.play($0) })) {
                Text("None").tag("")
                Divider()
                ForEach(SnippadSound.names, id: \.self) { Text($0).tag($0) }
            }
            Button("Play", systemImage: "play.fill") { SnippadSound.play(name) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(name.isEmpty)
                .help("Play it")
        }
    }
}
