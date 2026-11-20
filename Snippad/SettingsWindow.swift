import AppKit
import ServiceManagement
import SwiftUI

/// The settings, in a window of their own. Everything is saved to
/// `~/.snippad/settings.json` as it changes.
@MainActor
enum SettingsWindow {
    private static var controller: NSWindowController?

    static func show(tab: SettingsTab = .general, appsOfList: String? = nil) {
        SettingsModel.shared.tab = tab
        SettingsModel.shared.appsOfList = appsOfList
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
    /// Settings > Applications shows only the apps whose copies go here.
    var appsOfList: String?
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
                Toggle("Open the history menu with ⌃⌘V", isOn: $store.value.hotKeyEnabled)
                Toggle("Open the preferred list\u{2019}s entries with ⇧⌘V", isOn: $store.value.pickerHotKeyEnabled)
                Text("⇧⌘V is Paste and Match Style in many apps, and other clipboard managers use it too; while this is on, Snippad takes it everywhere. Switch it off if it gets in the way.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Paste after choosing an entry from the menu or the ⇧⌘V window", isOn: $store.value.pasteAfterChoosing)
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
    @State private var model = SettingsModel.shared

    private var missingCount: Int { catalog.apps.values.filter { $0.missing == true }.count }

    private var rows: [AppRecord] {
        catalog.sorted.filter { app in
            (model.appsOfList.map { store.listID(for: app.bundleID) == $0 } ?? true)
                && (!onlyCopiedFrom || (app.copies ?? 0) > 0)
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
                if let list = model.appsOfList {
                    Toggle("Only apps going to \u{201C}\(store.list(list).name)\u{201D}", isOn: Binding(
                        get: { model.appsOfList != nil }, set: { if !$0 { model.appsOfList = nil } }))
                }
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
