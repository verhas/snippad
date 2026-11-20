import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations) with the
    /// `.snippad` extension; the identifier here has to match it.
    static let snippad = UTType(exportedAs: "dev.verhas.snippad")
}

/// The open .snippad files: listed in the history window's sidebar, where
/// they are edited, and each with a read-only window of buttons on request.
///
/// Every .snippad file in ~/.snippad is always open. Files from elsewhere
/// join when they are opened (Finder, File > Open, Open Recent) and stay
/// until closed with the eject button; closing a window closes no file.
///
/// Deliberately not an NSDocument / DocumentGroup app. That machinery treats
/// a file as something the app owns: it puts Rename, Move To, Duplicate and
/// Locked into the title bar and the File menu, and when a file is opened a
/// second time it brings the existing window forward without reading the
/// file again. The board windows only read. Every open -- from Finder,
/// File > Open, Open Recent or the menu bar -- reads the file from disk, also
/// when its window is already showing. Only the editor in the history window
/// (SnippadEditorModel) writes.
@MainActor
@Observable
final class SnippadLibrary {
    static let shared = SnippadLibrary()

    /// Kept by NSDocumentController, which also feeds the Dock menu and the
    /// Apple menu's Recent Items; copied here so the Open Recent menu
    /// redraws when it changes.
    private(set) var recentURLs: [URL] = NSDocumentController.shared.recentDocumentURLs

    @ObservationIgnored private var windows: [URL: SnippadWindowController] = [:]
    @ObservationIgnored private var models: [URL: SnippadEditorModel] = [:]

    /// The open files: those in ~/.snippad by name, then the others.
    private(set) var files: [URL] = []

    var hasWindows: Bool { !windows.isEmpty }

    /// Set while quitting, so the windows closing then stay remembered.
    @ObservationIgnored var terminating = false

    /// At launch: the files open last time, and their windows.
    func restore() {
        refreshFiles()
        let fm = FileManager.default
        for path in SettingsStore.shared.value.openWindows where fm.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
        SettingsStore.shared.value.openWindows.removeAll { !fm.fileExists(atPath: $0) }
    }

    static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    static var home: URL { key(SnippadHome.directory) }

    func isHome(_ url: URL) -> Bool {
        Self.key(url).deletingLastPathComponent().path == Self.home.path
    }

    /// Looks at ~/.snippad again, and drops files that are gone.
    func refreshFiles() {
        let fm = FileManager.default
        let home = (try? fm.contentsOfDirectory(at: Self.home, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "snippad" }
            .map(Self.key)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
        let others = SettingsStore.shared.value.openSnippadFiles
            .map { Self.key(URL(fileURLWithPath: $0)) }
            .filter { !isHome($0) && fm.fileExists(atPath: $0.path) }
        files = home + others.filter { !home.contains($0) }
    }

    /// Puts a file into the sidebar.
    func add(_ url: URL) {
        let key = Self.key(url)
        if !isHome(key), !SettingsStore.shared.value.openSnippadFiles.contains(key.path) {
            SettingsStore.shared.value.openSnippadFiles.append(key.path)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        recentURLs = NSDocumentController.shared.recentDocumentURLs
        refreshFiles()
    }

    /// Opens a file the way Finder and File > Open do: into the sidebar,
    /// shown in the history window.
    func show(_ url: URL) {
        add(url)
        HistoryWindow.show(file: Self.key(url))
    }

    /// Takes a file from outside ~/.snippad off the sidebar. Its window, if
    /// open, closes too.
    func close(_ url: URL) {
        let key = Self.key(url)
        guard !isHome(key) else { return }
        models[key]?.saveIfNeeded()
        models[key] = nil
        windows[key]?.close()
        SettingsStore.shared.value.openSnippadFiles.removeAll { Self.key(URL(fileURLWithPath: $0)) == key }
        refreshFiles()
    }

    /// A new file in ~/.snippad, with one snippet to start from.
    func create(named name: String) throws -> URL {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".snippad") { base = String(base.dropLast(8)) }
        guard !base.isEmpty, !base.contains("/"), !base.hasPrefix(".") else {
            throw ClipboardError("\u{201C}\(name)\u{201D} cannot be a file name.")
        }
        let url = Self.home.appendingPathComponent(base + ".snippad")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ClipboardError("~/.snippad/\(url.lastPathComponent) already exists.")
        }
        try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SnippadWriter.save([Snippet(id: 0, name: "New snippet", value: "")], to: url)
        add(url)
        return Self.key(url)
    }

    /// The editing model of an open file, kept while Snippad runs.
    func model(for url: URL) -> SnippadEditorModel {
        let key = Self.key(url)
        if let m = models[key] { return m }
        let m = SnippadEditorModel(url: key)
        models[key] = m
        return m
    }

    /// After something else wrote the file: the editor shows the new
    /// contents unless it has changes of its own not yet saved.
    func reloadModel(_ url: URL) {
        guard let m = models[Self.key(url)], !m.isDirty else { return }
        m.load()
    }

    func saveAll() {
        for m in models.values { m.saveIfNeeded() }
    }

    /// Adds a history entry's text to a file as a new snippet.
    func addSnippet(from item: ClipItem, to url: URL) throws {
        let m = model(for: url)
        let list = item.listID.map { SettingsStore.shared.list($0).name }
        var added: [SnippetDraft] = []
        switch item.kind {
        case .files:
            for file in item.fileURLs {
                added.append(m.append(name: file.lastPathComponent, value: file.path, password: false, list: list, kind: .file))
            }
        case .image:
            guard let png = item.pngData else { throw ClipboardError("The image cannot be read.") }
            added.append(m.append(name: item.label ?? item.title, value: png.base64EncodedString(), password: false,
                                  list: list, kind: .image))
        case .richText:
            guard let rich = item.attributedString,
                  let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]),
                  let source = String(data: rtf, encoding: .utf8) else { throw ClipboardError("The formatted text cannot be read.") }
            added.append(m.append(name: Self.name(for: item, text: rich.string), value: source, password: item.isPassword,
                                  list: list, kind: .rich))
        default:
            guard let text = item.string else { throw ClipboardError("This kind of entry cannot become a snippet.") }
            added.append(m.append(name: Self.name(for: item, text: text), value: text, password: item.isPassword, list: list))
        }
        guard m.save() else {
            for d in added { m.remove(d.id) }
            throw ClipboardError(m.problem ?? "The file could not be saved.")
        }
    }

    private static func name(for item: ClipItem, text: String) -> String {
        let n = item.label ?? String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        return n.isEmpty ? "Snippet" : n
    }

    func open(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = windows[key] {
            existing.content.load()
            AppActivation.show(existing.window!)
        } else {
            let controller = SnippadWindowController(content: SnippadContent(url: key)) { [weak self] in
                self?.windows[key] = nil
                // Closed by the user, not by quitting: not reopened next time.
                if !(self?.terminating ?? false) {
                    SettingsStore.shared.value.openWindows.removeAll { $0 == key.path }
                }
            }
            windows[key] = controller
            if !SettingsStore.shared.value.openWindows.contains(key.path) {
                SettingsStore.shared.value.openWindows.append(key.path)
            }
            AppActivation.show(controller.window!)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        recentURLs = NSDocumentController.shared.recentDocumentURLs
    }

    /// After the editor saved a file, its board shows the new snippets.
    func reloadIfOpen(_ url: URL) {
        windows[url.standardizedFileURL.resolvingSymlinksInPath()]?.content.load()
    }

    /// The file of the board window in front, for the Edit command.
    var frontFileURL: URL? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        if let board = window.windowController as? SnippadWindowController { return board.content.url }
        return nil
    }

    func showOpenPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.snippad]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(show)
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

    /// How Snippad reads a file: once, nothing written.
    static func read(_ url: URL) -> Result<[Snippet], any Error> {
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
        hosting.sceneBridgingOptions = [.toolbars]

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

/// Snippad lives in the menu bar. While one of its windows is open it is also
/// a regular app, with a Dock icon and a menu bar, so the windows behave like
/// any other; when the last one closes it goes back to the menu bar only.
@MainActor
enum AppActivation {

    static func show(_ window: NSWindow) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func startWatchingWindows() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async {
                MainActor.assumeIsolated { settle(ignoring: closing) }
            }
        }
    }

    private static func settle(ignoring closing: NSWindow?) {
        let open = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled)
                && !(window is NSPanel)
        }
        if !open && NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
