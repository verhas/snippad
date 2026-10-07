import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations) with the
    /// `.snippad` extension; the identifier here has to match it.
    static let snippad = UTType(exportedAs: "dev.verhas.snippad")
}

/// The open .snippad files, one window each.
///
/// Deliberately not an NSDocument / DocumentGroup app. That machinery treats
/// a file as something the app owns and may write: it puts Rename, Move To,
/// Duplicate and Locked into the title bar and the File menu, and when a file
/// is opened a second time it brings the existing window forward without
/// reading the file again. Snippad only ever reads. Every open -- from
/// Finder, File > Open, Open Recent or the Dock -- reads the file from disk,
/// also when its window is already showing.
@MainActor
@Observable
final class SnippadLibrary {
    static let shared = SnippadLibrary()

    /// Kept by NSDocumentController, which also feeds the Dock menu and the
    /// Apple menu's Recent Items; copied here so the Open Recent menu
    /// redraws when it changes.
    private(set) var recentURLs: [URL] = NSDocumentController.shared.recentDocumentURLs

    @ObservationIgnored private var windows: [URL: SnippadWindowController] = [:]

    var hasWindows: Bool { !windows.isEmpty }

    func open(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = windows[key] {
            existing.content.load()
            existing.showWindow(nil)
        } else {
            let controller = SnippadWindowController(content: SnippadContent(url: key)) { [weak self] in
                self?.windows[key] = nil
            }
            windows[key] = controller
            controller.showWindow(nil)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        recentURLs = NSDocumentController.shared.recentDocumentURLs
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.snippad]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
    }

    /// For the tests: what the window of a file currently shows.
    func content(for url: URL) -> SnippadContent? {
        windows[url.standardizedFileURL.resolvingSymlinksInPath()]?.content
    }
}

/// What one window shows: the snippets of its file as last read, or why the
/// file could not be read.
@MainActor
@Observable
final class SnippadContent {
    let url: URL
    private(set) var snippets: Result<[Snippet], any Error>

    init(url: URL) {
        self.url = url
        snippets = Self.read(url)
    }

    func load() {
        snippets = Self.read(url)
    }

    /// The only access Snippad makes to a file: one read, nothing written.
    private static func read(_ url: URL) -> Result<[Snippet], any Error> {
        Result {
            let data = try Data(contentsOf: url, options: .uncached)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SnippadParseError(line: 0, message: "The file is not UTF-8 text.")
            }
            return try SnippadParser.parse(text)
        }
    }
}

final class SnippadWindowController: NSWindowController, NSWindowDelegate {
    let content: SnippadContent
    private let onClose: () -> Void

    private static var cascadePoint = NSPoint.zero

    init(content: SnippadContent, onClose: @escaping () -> Void) {
        self.content = content
        self.onClose = onClose

        let hosting = NSHostingController(rootView: SnippadWindowView(content: content))
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 480, height: 320))
        // Only a title. A representedURL would bring back the title-bar menu
        // with Rename and Move To.
        window.title = content.url.lastPathComponent
        window.subtitle = content.url.deletingLastPathComponent().path
        window.isRestorable = false
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        if Self.cascadePoint == .zero {
            window.center()
            Self.cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct SnippadWindowView: View {
    let content: SnippadContent

    var body: some View {
        switch content.snippets {
        case .success(let snippets):
            SnippetBoard(snippets: snippets)
        case .failure(let error):
            ContentUnavailableView {
                Label("Cannot read this file", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
            .frame(minWidth: 240, minHeight: 120)
        }
    }
}
