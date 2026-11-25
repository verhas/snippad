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
                // ⌘Q only closes the Organizer: Snippad keeps recording in
                // the menu bar. Quitting is in the menu bar menu (and here,
                // without a shortcut).
                CommandGroup(replacing: .appTermination) {
                    Button("Close Snippad Organizer") { HistoryWindow.close() }
                        .keyboardShortcut("q")
                    Button("Quit Snippad") { NSApp.terminate(nil) }
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
        guard onlyCopyRunning() else { return }
        AppActivation.startWatchingWindows()
        SettingsStore.shared.onChange = {
            StatusMenu.shared.settingsChanged()
            ClipboardHistory.shared.startMonitoring()  // follows the poll interval
            PasteInterceptor.update()
            ClipboardHistory.shared.readImageTexts()  // the languages may have changed
            ClipboardHistory.shared.classifyEntries()  // or classifying was switched on
            ClipboardHistory.shared.reconcileFiles()  // Never Public apps, classifying off
        }
        // Not from inside the tap's own callback, hence async.
        let updateTap = { DispatchQueue.main.async { MainActor.assumeIsolated { PasteInterceptor.update() } } }
        PasteEngine.shared.onStateChange = updateTap
        ClipboardHistory.shared.onCurrentChange = updateTap
        ClipboardHistory.shared.askForRemoteList = RemoteListPrompt.ask
        StatusMenu.shared.install()
        ClipboardHistory.shared.activate()
        PasteInterceptor.start()
        MCPServer.shared.start()
        SnippadLibrary.shared.restore()
        Task { await AppCatalog.shared.scanInstalled(settings: .shared) }
    }

    /// Two Snippads would both record every copy, fight over ⌃⌘V, ⇧⌘V and
    /// the snippets' shortcuts, and over the agents' socket. Asks which one
    /// stays; false when this one quits.
    @MainActor private func onlyCopyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard let other = others.first else { return true }
        let alert = NSAlert()
        alert.messageText = "Snippad is already running"
        alert.informativeText = "Another copy is running from \(other.bundleURL?.path ?? "elsewhere"). "
            + "This one is \(Bundle.main.bundlePath).\n\n"
            + "Two copies would both record every copy and compete for the shortcuts. Which one should keep running?"
        alert.addButton(withTitle: "Use This One")
        alert.addButton(withTitle: "Keep the Other One")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }
        for app in others { app.terminate() }
        // Give them a moment to let go of the shortcuts and the socket.
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
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
