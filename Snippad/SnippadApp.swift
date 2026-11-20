import SwiftUI

/// Snippad sits in the menu bar, records what is copied, and opens .snippad
/// files: edited in the Clipboard History window, and each in a window of
/// snippet buttons. The windows are SnippadLibrary's and HistoryWindow's;
/// SwiftUI only provides the
/// menu bar shown while one of them is open.
struct SnippadApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = SnippadLibrary.shared

    var body: some Scene {
        // A scene SwiftUI does not open on its own; its menu item is removed
        // below, so the app has no Settings window at all. Settings live in
        // the menu bar item.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Snippad File…") { HistoryWindow.newSnippadFile() }
                        .keyboardShortcut("n")
                    Button("Open…") { library.showOpenPanel() }
                        .keyboardShortcut("o")
                    Menu("Open Recent") {
                        ForEach(library.recentURLs, id: \.self) { url in
                            Button(url.lastPathComponent) { library.show(url) }
                        }
                        Divider()
                        Button("Clear Menu") { library.clearRecents() }
                            .disabled(library.recentURLs.isEmpty)
                    }
                    Divider()
                    Button("Edit Snippets…") {
                        HistoryWindow.show(file: library.frontFileURL)
                    }
                    .keyboardShortcut("e")
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindow.show() }
                        .keyboardShortcut(",")
                }
                CommandGroup(after: .windowArrangement) {
                    Button("Snippad Organizer") { HistoryWindow.show() }
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Finder, the Dock's recent items and `open file.snippad` all land here,
    /// whether the app was running already or is being launched for them.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(SnippadLibrary.shared.show)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileTypeRegistration.claimSnippadFiles()

        // Not when hosting the unit tests: they drive the pasteboard and the
        // history themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // What happens at every start, also at login (see the README's
        // "Startup"): the menu bar item, the clipboard watch, the MCP socket,
        // and a scan of the installed applications. No keyboard tap: that
        // comes only with a restricted value on the clipboard.
        AppActivation.startWatchingWindows()
        SettingsStore.shared.onChange = {
            StatusMenu.shared.settingsChanged()
            ClipboardHistory.shared.startMonitoring()  // follows the poll interval
            PasteInterceptor.update()
        }
        // Not from inside the tap's own callback, hence async.
        let updateTap = { DispatchQueue.main.async { MainActor.assumeIsolated { PasteInterceptor.update() } } }
        PasteEngine.shared.onStateChange = updateTap
        ClipboardHistory.shared.onCurrentChange = updateTap
        StatusMenu.shared.install()
        ClipboardHistory.shared.activate()
        PasteInterceptor.start()
        MCPServer.shared.start()
        SnippadLibrary.shared.restore()
        Task { await AppCatalog.shared.scanInstalled(settings: .shared) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SnippadLibrary.shared.terminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServer.shared.stop()
        ClipboardHistory.shared.flush()
        SnippadLibrary.shared.saveAll()
        AppCatalog.shared.save()
        // Without Snippad nothing takes a paste-once or chained value off
        // the clipboard, or puts the next one; or ends an expiry. Safer to
        // take it off now than to leave a password there.
        if PasteEngine.shared.holdsOwnValue,
           let rules = PasteEngine.shared.current?.rules,
           rules.needsPasteDetection || rules.expires != nil {
            PasteEngine.shared.clear()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            HistoryWindow.show()
        }
        return false
    }

    /// Closing the last window leaves Snippad in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
