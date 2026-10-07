import SwiftUI

/// A viewer-only document app: Finder opens a .snippad file here, and each
/// file gets its own window of snippet buttons.
@main
struct SnippadApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(viewing: SnippadDocument.self) { file in
            SnippetBoard(snippets: file.document.snippets)
        }
        .defaultSize(width: 480, height: 320)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FileTypeRegistration.claimSnippadFiles()
    }
}
