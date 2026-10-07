import SwiftUI

/// Finder opens a .snippad file here, and each file gets its own window of
/// snippet buttons. The windows are SnippadLibrary's; SwiftUI only provides
/// the menu bar.
@main
struct SnippadApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = SnippadLibrary.shared

    var body: some Scene {
        // A scene SwiftUI does not open on its own; its menu item is removed
        // below, so the app has no Settings window at all.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open…") { library.showOpenPanel() }
                        .keyboardShortcut("o")
                    Menu("Open Recent") {
                        ForEach(library.recentURLs, id: \.self) { url in
                            Button(url.lastPathComponent) { library.open(url) }
                        }
                        Divider()
                        Button("Clear Menu") { library.clearRecents() }
                            .disabled(library.recentURLs.isEmpty)
                    }
                }
                CommandGroup(replacing: .appSettings) {}
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Finder, the Dock's recent items and `open file.snippad` all land here,
    /// whether the app was running already or is being launched for them.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(SnippadLibrary.shared.open)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileTypeRegistration.claimSnippadFiles()

        // Launched without a file -- from the Dock or Launchpad -- ask for
        // one, rather than leaving nothing but a menu bar. Files given at
        // launch arrive before this runs. Not when hosting the unit tests,
        // where a modal panel would wait for ever.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        DispatchQueue.main.async {
            if !SnippadLibrary.shared.hasWindows {
                SnippadLibrary.shared.showOpenPanel()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SnippadLibrary.shared.showOpenPanel()
        }
        return false
    }
}
