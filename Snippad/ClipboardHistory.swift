import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One thing that was copied: every representation of every pasteboard item,
/// so putting it back gives apps the same choice of formats as the original.
///
/// Fields added after the first version are optional, so entries saved by an
/// older Snippad still load.
struct ClipItem: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        case text, richText, image, files, url, color, other
    }

    var id = UUID()
    var date = Date()
    var pinned = false
    /// The app that was in front when the copy happened.
    var sourceApp: String?
    var sourceBundleID: String?
    /// Per pasteboard item, the data of each type, keyed by type identifier.
    var items: [[String: Data]]
    /// SHA-256 of the contents, to spot copying the same thing again.
    var digest: String
    /// The list the entry belongs to; nil is the default list.
    var listID: String?
    /// A password snippet: shown as dots.
    var password: Bool?
    /// The snippet name, for entries Snippad put on the clipboard.
    var label: String?
    /// Searchable image metadata (EXIF, TIFF, GPS, IPTC) of a copied image
    /// or of copied image files.
    var metadata: String?
    var edited: Date?
    /// Being made: Extract Text is still reading the image. Never saved.
    var pending: Bool?

    init(items: [[String: Data]], sourceApp: String? = nil, date: Date = Date()) {
        self.items = items
        self.sourceApp = sourceApp
        self.date = date
        digest = Self.digest(of: items)
    }

    static func digest(of items: [[String: Data]]) -> String {
        var hash = SHA256()
        for item in items {
            for key in item.keys.sorted() {
                hash.update(data: Data(key.utf8))
                hash.update(data: item[key]!)
            }
            hash.update(data: Data([0]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ string: String) -> ClipItem {
        ClipItem(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(string.utf8)]])
    }

    var isPassword: Bool { password ?? false }
    var list: String { listID ?? ClipList.defaultID }

    // MARK: - Reading the contents

    private func data(_ type: NSPasteboard.PasteboardType) -> Data? {
        items.lazy.compactMap { $0[type.rawValue] }.first
    }

    var string: String? {
        data(.string).flatMap { String(data: $0, encoding: .utf8) }
    }

    var attributedString: NSAttributedString? {
        if let rtf = data(.rtf) { return NSAttributedString(rtf: rtf, documentAttributes: nil) }
        if let rtfd = data(.rtfd) { return NSAttributedString(rtfd: rtfd, documentAttributes: nil) }
        if let html = data(.html) { return NSAttributedString(html: html, documentAttributes: nil) }
        return nil
    }

    var fileURLs: [URL] {
        items.compactMap { $0[NSPasteboard.PasteboardType.fileURL.rawValue] }
            .compactMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }

    /// The files of the entry that are no longer where they were copied
    /// from: deleted, or moved (to the Trash, for one).
    var missingFiles: [URL] {
        fileURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A files entry none of whose files exist any more. Only its names and
    /// paths can still be copied, as text.
    var filesGone: Bool {
        let urls = fileURLs
        return !urls.isEmpty && urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    var imageData: Data? {
        data(.png) ?? data(.tiff)
            ?? items.lazy.flatMap { $0 }.first { UTType($0.key)?.conforms(to: .image) == true }?.value
    }

    var image: NSImage? { imageData.flatMap(NSImage.init(data:)) }

    var pngData: Data? {
        if let png = data(.png) { return png }
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    var kind: Kind {
        if !fileURLs.isEmpty { return .files }
        if imageData != nil && string == nil { return .image }
        if data(.URL) != nil, string.map({ URL(string: $0)?.scheme != nil }) ?? true { return .url }
        if data(.rtf) != nil || data(.html) != nil || data(.rtfd) != nil { return string == nil ? .other : .richText }
        if string != nil { return .text }
        if imageData != nil { return .image }
        if data(.color) != nil { return .color }
        return .other
    }

    /// The pasteboard types of one paste form; nil when the entry has none.
    func types(for form: ClipboardHistory.PasteForm) -> [String: Data]? {
        typealias T = NSPasteboard.PasteboardType
        var out: [String: Data] = [:]
        func take(_ t: T) { if let d = data(t) { out[t.rawValue] = d } }
        switch form {
        case .original:
            return nil
        case .richText:
            guard let rich = attributedString,
                  let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) else { return nil }
            out[T.rtf.rawValue] = rtf
            out[T.string.rawValue] = Data((string ?? rich.string).utf8)
        case .main:
            switch kind {
            case .text, .url:
                take(.string); take(.URL)
            case .richText:
                take(.rtf); take(.string)
                if out[T.rtf.rawValue] == nil, let rich = attributedString,
                   let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
                    out[T.rtf.rawValue] = rtf
                }
            case .image:
                take(.png); take(.tiff)
                if out.isEmpty, let png = pngData { out[T.png.rawValue] = png }
            case .files:
                return nil  // several items: the original is the files
            case .color, .other:
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Text, rich text, an image or files: what Add to Snippad takes.
    var canBecomeSnippet: Bool {
        pending != true && (string != nil || kind == .image || (kind == .files && !filesGone))
    }

    /// Text that can be edited in the history window.
    var isEditableText: Bool { [.text, .richText, .url].contains(kind) }

    var types: [String] { Array(Set(items.flatMap(\.keys))).sorted() }

    static let mask = "••••••••"

    /// One line for menus and lists; a password shows as dots.
    var title: String {
        if pending == true { return "Reading text\u{2026}" + (label.map { " (\($0))" } ?? "") }
        if isPassword { return (label.map { "\($0): " } ?? "") + Self.mask }
        switch kind {
        case .files:
            let urls = fileURLs
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        case .image:
            if let size = image.flatMap({ $0.representations.first }).map({ NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }) {
                return "Image \(Int(size.width))×\(Int(size.height))"
            }
            return "Image"
        case .color:
            return "Colour"
        case .other:
            return types.first ?? "Empty"
        case .text, .richText, .url:
            let s = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "(blank)" : firstLine
        }
    }

    var byteCount: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    var pasteboardItems: [[NSPasteboard.PasteboardType: Data]] {
        items.map { Dictionary(uniqueKeysWithValues: $0.map { (NSPasteboard.PasteboardType($0.key), $0.value) }) }
    }

    /// Recomputes the image metadata from the contents.
    mutating func scanMetadata() {
        switch kind {
        case .image: metadata = imageData.flatMap(ImageMetadata.text(of:))
        case .files:
            let parts = fileURLs.compactMap { url in ImageMetadata.text(ofFile: url).map { "\(url.lastPathComponent)\n\($0)" } }
            metadata = parts.isEmpty ? nil : parts.joined(separator: "\n")
        default: metadata = nil
        }
    }
}

/// The metadata of images as searchable text, one "Key: value" per line.
enum ImageMetadata {

    static func text(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(text(of:))
    }

    static func text(ofFile url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(text(of:))
    }

    private static func text(of source: CGImageSource) -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        var lines: [String] = []
        flatten(properties, prefix: "", into: &lines)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func flatten(_ dict: [String: Any], prefix: String, into lines: inout [String]) {
        for key in dict.keys.sorted() {
            let name = prefix.isEmpty ? key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) : "\(prefix) \(key)"
            switch dict[key] {
            case let nested as [String: Any]: flatten(nested, prefix: name, into: &lines)
            case let array as [Any]: lines.append("\(name): \(array.map { "\($0)" }.joined(separator: ", "))")
            case let value?: lines.append("\(name): \(value)")
            case nil: break
            }
        }
    }
}

struct ClipboardError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Everything copied, newest first, kept on disk across launches.
///
/// macOS has no notification for clipboard changes, so the pasteboard's
/// change count is polled twice a second, which is what every clipboard
/// manager does. Not recorded: copies from excluded apps, and items another
/// app marked concealed, transient or auto-generated (passwords from password
/// managers). What Snippad itself puts on the clipboard is recorded by
/// Snippad directly (`recordOwn`), password snippets as dots.
@MainActor
@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory(apps: .shared)

    private(set) var items: [ClipItem] = []

    /// The entry on the clipboard now, if it is in the history.
    private(set) var currentItemID: UUID?
    /// The list the clipboard's content belongs to, also when it was not
    /// recorded (an excluded app, a concealed item, recording paused).
    private(set) var currentListID = ClipList.defaultID

    /// Called when what is on the clipboard, or the list it belongs to,
    /// changed: the keyboard tap follows it.
    @ObservationIgnored var onCurrentChange: (() -> Void)?

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let apps: AppCatalog?
    @ObservationIgnored let engine: PasteEngine

    /// Whether new copies are recorded.
    var isCapturing: Bool {
        get { settings.value.recordHistory }
        set { settings.value.recordHistory = newValue }
    }

    /// How many unpinned entries each list keeps.
    var limit: Int {
        get { settings.value.historyLimit }
        set {
            settings.value.historyLimit = newValue
            trim()
        }
    }

    /// Copies larger than this are not recorded.
    static let maxItemBytes = 50 * 1024 * 1024

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var lastChangeCount: Int
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    init(directory: URL? = nil, pasteboard: NSPasteboard = .general,
         settings: SettingsStore? = nil, apps: AppCatalog? = nil, engine: PasteEngine? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippad/History", isDirectory: true)
        self.pasteboard = pasteboard
        self.settings = settings ?? .shared
        self.apps = apps
        self.engine = engine ?? .shared
        lastChangeCount = pasteboard.changeCount
        load()
    }

    /// At launch: record what Snippad puts on the clipboard, and catch up
    /// on metadata.
    func activate() {
        engine.recorder = { [weak self] item in self?.recordOwn(item) }
        scanMissingMetadata()
        startMonitoring()
    }

    // MARK: - Watching the clipboard

    /// How often the clipboard is looked at: faster while the Paste Guard
    /// is on, so a copy has its list -- and the keyboard tap, if the list is
    /// restricted -- before a quick ⌘V.
    private var pollInterval: TimeInterval { settings.value.pasteGuardEnabled ? 0.15 : 0.5 }

    func startMonitoring() {
        if let timer, timer.timeInterval == pollInterval { return }
        if timer == nil { lastChangeCount = pasteboard.changeCount }
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Records the clipboard if it changed since the last look.
    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        engine.clipboardChangedElsewhere()
        capture()
        onCurrentChange?()
    }

    /// What was just copied inside Snippad itself -- ⌘C or ⌘X in a history
    /// entry's or a snippet's text -- goes to the list of what it was copied
    /// from, so copying a part is no way around that list's Paste Guard
    /// rules. A part of a password stays a password.
    func captureOwnCopy(list: String?, password: Bool = false) {
        lastChangeCount = pasteboard.changeCount
        engine.clipboardChangedElsewhere()
        let listID = settings.listID(named: list) ?? ClipList.defaultID
        capture(own: (listID, password))
        if let id = currentItemID, item(id)?.list != listID { move(id, toList: listID) }
        onCurrentChange?()
    }

    private func capture(own: (list: String, password: Bool)? = nil) {
        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else {
            currentItemID = nil
            return
        }
        // Snippad's own writes were recorded when they were made.
        if own == nil, pbItems.contains(where: { $0.types.contains(.snippadSource) }) { return }

        let front = own == nil ? NSWorkspace.shared.frontmostApplication : nil
        let bundleID = own == nil ? front?.bundleIdentifier : Bundle.main.bundleIdentifier
        apps?.noteCopy(from: front)

        var listID = own?.list ?? settings.listID(for: bundleID)
        if own == nil, let privateList = settings.value.privateBrowsingList, let front,
           BrowserPrivacy.isBrowser(bundleID), BrowserPrivacy.state(of: front) == .privateWindow {
            listID = privateList
        }
        currentItemID = nil
        currentListID = listID

        guard isCapturing || own != nil, own != nil || !settings.isExcluded(bundleID) else { return }
        let skip: Set<NSPasteboard.PasteboardType> = [.concealed, .transient, .autoGenerated]
        if own == nil, pbItems.contains(where: { !skip.isDisjoint(with: $0.types) }) { return }

        var items: [[String: Data]] = []
        var total = 0
        for pbItem in pbItems {
            var types: [String: Data] = [:]
            for type in pbItem.types where !type.rawValue.hasPrefix("dyn.") {
                guard let data = pbItem.data(forType: type) else { continue }
                total += data.count
                guard total <= Self.maxItemBytes else { return }
                types[type.rawValue] = data
            }
            if !types.isEmpty { items.append(types) }
        }
        guard !items.isEmpty else { return }

        var item = ClipItem(items: items, sourceApp: own == nil ? front?.localizedName : "Snippad")
        item.sourceBundleID = bundleID
        item.listID = listID == ClipList.defaultID ? nil : listID
        if own?.password == true { item.password = true }
        item.scanMetadata()
        record(item)
    }

    /// Records what Snippad itself just put on the clipboard.
    func recordOwn(_ item: ClipItem) {
        lastChangeCount = pasteboard.changeCount
        var item = item
        item.sourceApp = item.sourceApp ?? "Snippad"
        item.sourceBundleID = item.sourceBundleID ?? Bundle.main.bundleIdentifier
        // A snippet names its list; the history keeps the list's id.
        let wanted = item.listID.map { settings.listID(named: $0) ?? ClipList.defaultID }
        item.listID = wanted == ClipList.defaultID ? nil : wanted
        record(item)
        if let wanted, let id = currentItemID, self.item(id)?.list != wanted { move(id, toList: wanted) }
    }

    // MARK: - Changing the list

    /// Adds an entry at the top. Copying something already in the history
    /// moves that entry up instead of adding a second one; it keeps its list.
    func record(_ item: ClipItem) {
        let recorded: ClipItem
        if let index = items.firstIndex(where: { $0.digest == item.digest }) {
            var existing = items.remove(at: index)
            existing.date = item.date
            existing.sourceApp = item.sourceApp ?? existing.sourceApp
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.label = item.label ?? existing.label
            if item.isPassword { existing.password = true }
            if existing.metadata == nil { existing.metadata = item.metadata }
            recorded = existing
        } else {
            recorded = item
        }
        items.insert(recorded, at: 0)
        save(recorded)
        currentItemID = recorded.id
        currentListID = recorded.list
        trim()
        onCurrentChange?()
    }

    func item(_ id: UUID) -> ClipItem? { items.first { $0.id == id } }

    /// The list the clipboard's content belongs to, for the paste guard.
    var currentList: ClipList {
        settings.list(currentItemID.flatMap(item)?.list ?? currentListID)
    }

    /// Puts an entry back on the clipboard; it moves to the top.
    /// A files entry whose files are all gone is not put back: there is
    /// nothing to paste. Copy its names or paths instead.
    /// Returns whether the entry is now on the clipboard: only then may
    /// anything paste.
    @discardableResult
    func copy(_ id: UUID) -> Bool {
        guard let item = item(id), !item.filesGone, item.pending != true else { return false }
        engine.put(items: item.pasteboardItems, name: item.title, concealed: item.isPassword)
        lastChangeCount = pasteboard.changeCount
        var again = ClipItem(items: item.items, sourceApp: item.sourceApp)
        again.sourceBundleID = item.sourceBundleID
        record(again)
        return true
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
        trim()
    }

    func move(_ id: UUID, toList listID: String) {
        update(id) { $0.listID = listID == ClipList.defaultID ? nil : listID }
        trim()
        if id == currentItemID { onCurrentChange?() }
    }

    /// Deleting the password that is on the clipboard takes it off the
    /// clipboard too: a deleted password must not be pasted afterwards.
    func delete(_ id: UUID) {
        if currentItemID == id, item(id)?.isPassword == true, pasteboard.changeCount == lastChangeCount {
            engine.clear()
            lastChangeCount = pasteboard.changeCount
        }
        items.removeAll { $0.id == id }
        pendingSaves.removeValue(forKey: id)?.cancel()
        if currentItemID == id { currentItemID = nil; onCurrentChange?() }
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Empties the history, or one list of it; pinned entries stay unless
    /// `includingPinned`.
    func clear(includingPinned: Bool = false, list: String? = nil) {
        for item in items where (includingPinned || !item.pinned) && (list == nil || item.list == list) {
            delete(item.id)
        }
    }

    /// A deleted list's entries go to the default list.
    func listRemoved(_ listID: String) {
        for item in items where item.listID == listID {
            update(item.id) { $0.listID = nil }
        }
    }

    /// Replaces the text of an entry, as the history window's editor does on
    /// every change. Rich text keeps its formatting as RTF. When the entry is
    /// what is on the clipboard, the clipboard gets the new text as well.
    func updateText(_ id: UUID, plain: String, rich: NSAttributedString? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var types: [String: Data] = [NSPasteboard.PasteboardType.string.rawValue: Data(plain.utf8)]
        if let rich, let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            types[NSPasteboard.PasteboardType.rtf.rawValue] = rtf
        }
        var item = items[index]
        item.items = [types]
        item.digest = ClipItem.digest(of: item.items)
        item.edited = Date()
        items[index] = item
        saveSoon(item)

        if currentItemID == id && pasteboard.changeCount == lastChangeCount {
            engine.put(items: item.pasteboardItems, name: item.title, concealed: item.isPassword)
            lastChangeCount = pasteboard.changeCount
        }
    }

    /// An entry still being made, shown at once with a spinner.
    func insertPending(label: String, list: String) -> UUID {
        var item = ClipItem(items: [], sourceApp: "Snippad")
        item.pending = true
        item.label = label
        item.listID = list == ClipList.defaultID ? nil : list
        items.insert(item, at: 0)
        return item.id
    }

    /// The text is there: the pending entry becomes a text entry and goes on
    /// the clipboard.
    func finishPending(_ id: UUID, text: String, name: String) -> ClipItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let list = items[index].list
        let digest = ClipItem.text(text).digest
        if items.contains(where: { $0.digest == digest && $0.id != id }) {
            // The same text is in the history already: that entry moves up.
            items.remove(at: index)
            return putText(text, name: name, list: list)
        }
        var item = items[index]
        item.items = ClipItem.text(text).items
        item.digest = digest
        item.pending = nil
        item.label = name
        items[index] = item
        save(item)
        return putText(text, name: name, list: list)
    }

    func dropPending(_ id: UUID) {
        items.removeAll { $0.id == id && $0.pending == true }
    }

    /// Drops a rich text entry's formatting, keeping its text.
    func convertToPlainText(_ id: UUID) {
        guard let item = item(id), item.kind == .richText || item.attributedString != nil else { return }
        updateText(id, plain: item.string ?? item.attributedString?.string ?? "", rich: nil)
    }

    /// What a files entry's files are called, as text: their paths, or only
    /// their names, one per line. Works when the files are gone, too.
    enum FileText { case paths, names }

    func fileText(of id: UUID, _ what: FileText) -> String? {
        guard let item = item(id), item.kind == .files else { return nil }
        return item.fileURLs.map { what == .paths ? $0.path : $0.lastPathComponent }.joined(separator: "\n")
    }

    /// Puts the paths or the names of a files entry's files on the clipboard
    /// as text, which becomes a new entry in the same list.
    @discardableResult
    func copyFileText(of id: UUID, _ what: FileText) throws -> String {
        guard let item = item(id), let text = fileText(of: id, what) else {
            throw ClipboardError("That entry is not a list of files.")
        }
        putText(text, name: (what == .paths ? "Paths of " : "Names of ") + item.title, list: item.list)
        return text
    }

    /// Puts text made from an entry on the clipboard, as a new entry of the
    /// given list.
    @discardableResult
    func putText(_ text: String, name: String, list: String, password: Bool = false) -> ClipItem? {
        engine.put(text, name: name, rules: PasteRules(password: password, list: list))
        let digest = ClipItem.text(text).digest
        if let made = items.first(where: { $0.digest == digest }) {
            if made.list != list { move(made.id, toList: list) }
        } else {
            var made = ClipItem.text(text)
            made.listID = list
            made.password = password ? true : nil
            made.label = name
            recordOwn(made)
        }
        return items.first { $0.digest == digest }
    }

    /// How an entry is put on the clipboard for one paste.
    enum PasteForm {
        /// Every format it was copied in.
        case original
        /// Its main form only: plain text, rich text (with its plain text),
        /// the image, or the files.
        case main
        /// Rich text (RTF, with its plain text).
        case richText
    }

    /// Whether the entry has rich text to paste as such.
    func hasRichText(_ id: UUID) -> Bool {
        item(id)?.attributedString != nil
    }

    /// Puts an entry on the clipboard in one form. It moves to the top of
    /// the history and stays the entry of record, so its list's rules apply.
    @discardableResult
    func put(_ id: UUID, as form: PasteForm) -> Bool {
        guard let item = item(id), !item.filesGone, item.pending != true else { return false }
        guard form != .original, let types = item.types(for: form) else { return copy(id) }
        engine.put(items: [types.reduce(into: [:]) { $0[NSPasteboard.PasteboardType($1.key)] = $1.value }],
                   name: item.title, concealed: item.isPassword)
        lastChangeCount = pasteboard.changeCount
        var again = ClipItem(items: item.items, sourceApp: item.sourceApp)
        again.sourceBundleID = item.sourceBundleID
        record(again)
        return true
    }

    /// Removes a list. Its entries move to `moveTo`, or are deleted when it
    /// is nil. The default list cannot be removed.
    func removeList(_ listID: String, moveTo: String?) {
        guard listID != ClipList.defaultID else { return }
        for item in items where item.list == listID {
            if let moveTo { move(item.id, toList: moveTo) } else { delete(item.id) }
        }
        settings.value.lists.removeAll { $0.id == listID }
    }

    /// A new entry with only some of the files of a files entry, put on the
    /// clipboard.
    @discardableResult
    func copyFiles(_ id: UUID, only urls: Set<URL>) throws -> ClipItem {
        guard let source = item(id) else { throw ClipboardError("That history entry is gone.") }
        let key = NSPasteboard.PasteboardType.fileURL.rawValue
        let kept = source.items.filter { types in
            types[key].flatMap { URL(dataRepresentation: $0, relativeTo: nil) }.map { urls.contains($0) } ?? false
        }
        guard !kept.isEmpty else { throw ClipboardError("Choose at least one file.") }
        let gone = kept.compactMap { $0[key].flatMap { URL(dataRepresentation: $0, relativeTo: nil) } }
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard gone.isEmpty else {
            throw ClipboardError("These files no longer exist: " + gone.map(\.lastPathComponent).joined(separator: ", "))
        }
        var item = ClipItem(items: kept, sourceApp: source.sourceApp)
        item.sourceBundleID = source.sourceBundleID
        item.listID = source.listID
        item.scanMetadata()
        engine.put(items: item.pasteboardItems, name: item.title)
        lastChangeCount = pasteboard.changeCount
        record(item)
        return item
    }

    /// Reads files and puts their contents on the clipboard: an image as an
    /// image, anything readable as text as text. Each file becomes a new
    /// entry; the last one ends up on the clipboard. Files that are neither
    /// are reported in the error, after the others were copied.
    @discardableResult
    func copyFileContents(_ urls: [URL], listID: String? = nil) throws -> [ClipItem] {
        var made: [ClipItem] = []
        var problems: [String] = []
        for url in urls {
            do {
                var item = ClipItem(items: [try Self.contents(of: url)], sourceApp: "Snippad")
                item.label = url.lastPathComponent
                item.listID = listID
                item.scanMetadata()
                if item.kind == .image, item.metadata == nil { item.metadata = ImageMetadata.text(ofFile: url) }
                made.append(item)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if let last = made.last {
            engine.put(items: last.pasteboardItems, name: last.label ?? last.title)
            lastChangeCount = pasteboard.changeCount
            for item in made { record(item) }
        }
        if !problems.isEmpty { throw ClipboardError(problems.joined(separator: "\n")) }
        return made
    }

    /// The pasteboard representation of a file's contents.
    static func contents(of url: URL) throws -> [String: Data] {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClipboardError("\u{201C}\(name)\u{201D} no longer exists.")
        }
        if values?.isDirectory == true {
            throw ClipboardError("\u{201C}\(name)\u{201D} is a folder; only a file\u{2019}s contents can be copied.")
        }
        if let size = values?.fileSize, size > maxItemBytes {
            throw ClipboardError("\u{201C}\(name)\u{201D} is larger than 50 MB.")
        }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else {
                throw ClipboardError("\u{201C}\(name)\u{201D} looks like an image but cannot be read as one.")
            }
            var out = [NSPasteboard.PasteboardType.tiff.rawValue: tiff]
            if type.conforms(to: .png) { out[NSPasteboard.PasteboardType.png.rawValue] = try Data(contentsOf: url) }
            else if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                out[NSPasteboard.PasteboardType.png.rawValue] = png
            }
            return out
        }
        let data = try Data(contentsOf: url)
        if type.conforms(to: .rtf), let a = NSAttributedString(rtf: data, documentAttributes: nil) {
            return [NSPasteboard.PasteboardType.rtf.rawValue: data, NSPasteboard.PasteboardType.string.rawValue: Data(a.string.utf8)]
        }
        if !data.contains(0), let text = String(data: data, encoding: .utf8) ?? (type.conforms(to: .text) ? String(data: data, encoding: .isoLatin1) : nil) {
            return [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]
        }
        throw ClipboardError("\u{201C}\(name)\u{201D} (\(type.localizedDescription ?? "binary data")) cannot be put on the clipboard: only text and images can.")
    }

    func search(_ query: String, list: String? = nil) -> [ClipItem] {
        let inList = list.map { l in items.filter { $0.list == l } } ?? items
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return inList }
        return inList.filter { item in
            if item.isPassword {
                return item.label?.localizedCaseInsensitiveContains(q) ?? false
            }
            return item.title.localizedCaseInsensitiveContains(q)
                || (item.string?.localizedCaseInsensitiveContains(q) ?? false)
                || item.fileURLs.contains { $0.path.localizedCaseInsensitiveContains(q) }
                || (item.sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.label?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.metadata?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func update(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save(items[index])
    }

    private func trim() {
        var counts: [String: Int] = [:]
        for item in items where !item.pinned {
            counts[item.list, default: 0] += 1
            if counts[item.list]! > limit { delete(item.id) }
        }
    }

    /// Entries recorded before metadata was kept get it now.
    private func scanMissingMetadata() {
        for item in items where item.metadata == nil && (item.kind == .image || item.kind == .files) {
            update(item.id) { $0.scanMetadata() }
        }
    }

    // MARK: - Disk

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("plist")
    }

    /// Typing in the editor saves once the typing pauses.
    private func saveSoon(_ item: ClipItem) {
        pendingSaves[item.id]?.cancel()
        pendingSaves[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let current = self.item(item.id) else { return }
            self.pendingSaves[item.id] = nil
            self.save(current)
        }
    }

    /// Writes pending edits now, before quitting.
    func flush() {
        for (id, task) in pendingSaves {
            task.cancel()
            if let item = item(id) { save(item) }
        }
        pendingSaves = [:]
    }

    private func save(_ item: ClipItem) {
        guard item.pending != true else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(item).write(to: file(for: item.id), options: .atomic)
        } catch {
            NSLog("Snippad could not save a clipboard history item: %@", error.localizedDescription)
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        items = files.filter { $0.pathExtension == "plist" }
            .compactMap { try? decoder.decode(ClipItem.self, from: Data(contentsOf: $0)) }
            .filter { $0.pending != true }
            .sorted { $0.date > $1.date }
    }
}
