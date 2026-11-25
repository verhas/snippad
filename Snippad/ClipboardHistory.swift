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
    /// An edited image: the original, the shapes, texts and effects added,
    /// and the crop. `items` holds the result, which is what is pasted.
    var edits: ImageEdits?
    /// The name the user gave the entry, shown instead of its first line.
    var name: String?
    /// The text read from an image entry in the background, "" when it has
    /// none, and the digest of the picture it was read from: an edited
    /// picture is read again.
    var readText: String?
    var readTextFrom: String?
    /// The languages it was read in; nil or empty: guessed.
    var readTextLanguages: [String]?
    /// Its HTML, converted in the background to RTF, and the digest of the
    /// content it was converted from. Not part of `items`: what is pasted
    /// as Original stays what was copied.
    var converted: Data?
    var convertedFrom: String?
    /// Its category as classified in the background, what it was made of
    /// (`classificationKey`), and whether Apple Intelligence had a say.
    var category: ClipCategory?
    var categoryFrom: String?
    var categoryByModel: Bool?
    var categoryVersion: Int?
    /// The category the user chose; it stands over the classified one.
    var userCategory: ClipCategory?
    /// Copied in a private browser window: never Public.
    var inPrivateWindow: Bool?
    /// The category of the entry it was copied from (a part, its text, its
    /// objects): it is at least that, whatever classifying finds.
    var inheritedCategory: ClipCategory?

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

    /// The formatted text. HTML is read through WebKit, which can keep the
    /// caller waiting -- once for good, and Snippad with it -- so it is read
    /// in the background (`convertFormattedTexts`) and kept as RTF. On the
    /// main thread an entry not converted yet has none: it shows as plain
    /// text until the conversion is done.
    var attributedString: NSAttributedString? {
        if let formatted = attributedStringWithoutWebKit { return formatted }
        guard let html = data(.html), !Thread.isMainThread else { return nil }
        return Self.read(html: html)
    }

    /// HTML as formatted text, through WebKit: never on the main thread.
    nonisolated static func read(html: Data) -> NSAttributedString? {
        try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                      .characterEncoding: String.Encoding.utf8.rawValue],
                                documentAttributes: nil)
    }

    /// HTML copied without RTF, and not converted (for this content) yet.
    var needsHTMLConversion: Bool {
        pending != true && data(.html) != nil && data(.rtf) == nil && data(.rtfd) == nil && convertedFrom != digest
    }

    /// Whether it was copied with formatting, told by what was stored alone:
    /// reading HTML hands it to a WebKit process and waits for the answer,
    /// which can take seconds -- the menu once took 20 to open.
    var hasFormatting: Bool { data(.rtf) != nil || data(.rtfd) != nil || data(.html) != nil }

    /// The formatted text where reading it needs no WebKit (RTF, RTFD); for
    /// HTML, nil -- for what must not wait, such as building a menu.
    var attributedStringWithoutWebKit: NSAttributedString? {
        if let rtf = data(.rtf) { return NSAttributedString(rtf: rtf, documentAttributes: nil) }
        if let rtfd = data(.rtfd) { return NSAttributedString(rtfd: rtfd, documentAttributes: nil) }
        if let converted, convertedFrom == digest { return NSAttributedString(rtf: converted, documentAttributes: nil) }
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
        case .textOfImage:
            guard let text = textOfImage else { return nil }
            out[T.string.rawValue] = Data(text.utf8)
        case .markdown:
            guard let rich = attributedString else { return nil }
            out[T.string.rawValue] = Data(MarkdownConverter.markdown(from: rich).utf8)
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

    /// The text read from the picture as it is now, when there is some.
    var textOfImage: String? {
        guard readTextFrom == digest, let readText, !readText.isEmpty else { return nil }
        return readText
    }

    /// An image whose text has not been read yet, or was read before an
    /// edit, or in other languages than `languages` (nil: guessed).
    func needsTextReading(in languages: [String]?) -> Bool {
        kind == .image && !isPassword && pending != true
            && (readTextFrom != digest || (readTextLanguages ?? []) != (languages ?? []))
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
        if isPassword { return ((name ?? label).map { "\($0): " } ?? "") + Self.mask }
        if let name, !name.isEmpty { return name }
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
    /// In the unit tests, a history of their own in a temporary folder:
    /// the user's history is neither read nor changed.
    static let shared = SnippadHome.isTesting
        ? ClipboardHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SnippadTestHistory-\(UUID().uuidString)"),
                           pasteboard: PasteEngine.shared.pasteboard, apps: .shared)
        : ClipboardHistory(apps: .shared)

    private(set) var items: [ClipItem] = []

    /// The entry on the clipboard now, if it is in the history.
    private(set) var currentItemID: UUID?
    /// The list the clipboard's content belongs to, also when it was not
    /// recorded (an excluded app, a concealed item, recording paused).
    private(set) var currentListID = ClipList.defaultID

    /// Called when what is on the clipboard, or the list it belongs to,
    /// changed: the keyboard tap follows it.
    @ObservationIgnored var onCurrentChange: (() -> Void)?

    /// Asked the first time something comes from another device and there
    /// is no list for such copies: answers with a list name to create, or
    /// nil to opt out. Not set in the tests, which then never ask.
    @ObservationIgnored var askForRemoteList: ((_ answer: @escaping @MainActor (String?) -> Void) -> Void)?
    /// Entries from other devices recorded while the question is open; they
    /// move to the new list once it exists.
    @ObservationIgnored private var awaitingRemoteList: [UUID]?

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

    /// Unpinned entries older than this many days are deleted; 0 never.
    var maxAgeDays: Int {
        get { settings.value.historyMaxAgeDays }
        set {
            settings.value.historyMaxAgeDays = max(0, newValue)
            trim()
        }
    }

    /// Copies larger than this are not recorded.
    static let maxItemBytes = 50 * 1024 * 1024

    @ObservationIgnored private let directory: URL
    /// Reads the text of image entries, one after the other, in the background.
    @ObservationIgnored var textReader: Task<Void, Never>?
    /// While an entry is being made from others: their category, which it
    /// inherits (see `inheriting(from:_:)`).
    @ObservationIgnored private var inheritedForNext: ClipCategory?

    /// Runs `make`, and every entry it records inherits the category of the
    /// entries it is made from -- not Public, which says nothing: what is
    /// made is classified on its own anyway.
    @discardableResult
    func inheriting<T>(from sources: [UUID], also extra: ClipCategory? = nil, _ make: () throws -> T) rethrows -> T {
        let before = inheritedForNext
        let found = (sources.compactMap { item($0)?.category(in: settings.value) } + [extra].compactMap { $0 })
            .filter { $0 != .general }
        inheritedForNext = found.reduce(before) { ClipCategory.careful($0, $1) }
        defer { inheritedForNext = before }
        return try make()
    }

    /// Entries not written because they wait for their category.
    @ObservationIgnored private var heldBack: Set<UUID> = []
    /// Converts copied HTML to formatted text, in the background.
    @ObservationIgnored var htmlConverter: Task<Void, Never>?
    /// Classifies the entries, one after the other, in the background.
    @ObservationIgnored var classifier: Task<Void, Never>?
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
        // Images from before, or copied while Snippad was not running.
        readImageTexts()
        convertFormattedTexts()
        classifyEntries()
        // Files of what is Sensitive, Private or Secret, from before.
        reconcileFiles()
    }

    /// At launch: record what Snippad puts on the clipboard, and catch up
    /// on metadata.
    func activate() {
        engine.recorder = { [weak self] item in self?.recordOwn(item) }
        scanMissingMetadata()
        trim()
        startMonitoring()
        // Entries grow old while Snippad runs, too.
        let ageTimer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trim() }
        }
        RunLoop.main.add(ageTimer, forMode: .common)
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
    func captureOwnCopy(list: String?, password: Bool = false, from source: UUID? = nil, category: ClipCategory? = nil) {
        lastChangeCount = pasteboard.changeCount
        engine.clipboardChangedElsewhere()
        let listID = settings.listID(named: list) ?? ClipList.defaultID
        inheriting(from: source.map { [$0] } ?? [], also: category) { capture(own: (listID, password)) }
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

        // A copy from another device (Universal Clipboard) did not come
        // from the app in front.
        let remote = own == nil && pbItems.contains { $0.types.contains(.remoteClipboard) }
        let front = own == nil && !remote ? NSWorkspace.shared.frontmostApplication : nil
        let bundleID = own != nil ? Bundle.main.bundleIdentifier : front?.bundleIdentifier
        apps?.noteCopy(from: front)

        var listID = own?.list ?? settings.listID(for: bundleID)
        // A private window: for its list, and as never Public.
        var inPrivateWindow = false
        if own == nil, let front, BrowserPrivacy.isBrowser(bundleID),
           settings.value.privateBrowsingList != nil || settings.value.classifyEntries {
            inPrivateWindow = BrowserPrivacy.state(of: front) == .privateWindow
        }
        if inPrivateWindow, let privateList = settings.value.privateBrowsingList {
            listID = privateList
        }
        if remote {
            listID = settings.value.remoteList ?? ClipList.defaultID
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

        let fromPhone = pbItems.contains { $0.types.contains(.uikitAttributedString) }
        var item = ClipItem(items: items, sourceApp: remote ? (fromPhone ? "iPhone or iPad" : "Another device")
                                                     : own == nil ? front?.localizedName : "Snippad")
        item.sourceBundleID = bundleID
        item.listID = listID == ClipList.defaultID ? nil : listID
        if inPrivateWindow { item.inPrivateWindow = true }
        if own?.password == true { item.password = true }
        item.scanMetadata()
        record(item)
        if own == nil { SnippadSound.copied(own: false) }
        if remote { remoteRecorded() }
    }

    /// After a copy from another device: it goes back on the clipboard as
    /// the Mac's own data (unless switched off), and the first one offers a
    /// list for all of them.
    private func remoteRecorded() {
        guard let id = currentItemID, let item = item(id) else { return }
        if settings.value.remoteToLocal {
            // Without the remote marker: the Mac's own copy now.
            let local = item.pasteboardItems.map { $0.filter { $0.key != .remoteClipboard } }
            engine.put(items: local, name: item.title, concealed: false)
            lastChangeCount = pasteboard.changeCount
        }
        guard settings.value.remoteList == nil, !settings.value.remoteListOptOut, let ask = askForRemoteList else { return }
        if awaitingRemoteList != nil {
            awaitingRemoteList?.append(id)
            return
        }
        awaitingRemoteList = [id]
        ask { [weak self] name in
            guard let self else { return }
            let waiting = self.awaitingRemoteList ?? []
            self.awaitingRemoteList = nil
            self.answerRemoteList(name, moving: waiting)
        }
    }

    /// Creates the list for copies from other devices (and moves `ids` into
    /// it), or records that the user does not want one.
    func answerRemoteList(_ name: String?, moving ids: [UUID] = []) {
        guard let name else {
            settings.value.remoteListOptOut = true
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = settings.addList(named: trimmed.isEmpty ? "iPhone & iPad" : trimmed)
        if let index = settings.value.lists.firstIndex(where: { $0.id == list.id }) {
            settings.value.lists[index].icon = "iphone"
        }
        settings.value.remoteList = list.id
        for id in ids { move(id, toList: list.id) }
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
        var recorded: ClipItem
        if let index = items.firstIndex(where: { $0.digest == item.digest }) {
            var existing = items.remove(at: index)
            existing.date = item.date
            existing.sourceApp = item.sourceApp ?? existing.sourceApp
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.label = item.label ?? existing.label
            existing.name = item.name ?? existing.name
            if item.isPassword { existing.password = true }
            if existing.metadata == nil { existing.metadata = item.metadata }
            existing.inheritedCategory = ClipCategory.careful(existing.inheritedCategory, item.inheritedCategory)
            recorded = existing
        } else {
            recorded = item
        }
        if let inherited = inheritedForNext {
            recorded.inheritedCategory = ClipCategory.careful(recorded.inheritedCategory, inherited)
        }
        items.insert(recorded, at: 0)
        save(recorded)
        if recorded.kind == .image { readImageTexts() }
        convertFormattedTexts()
        classifyEntries()
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
        heldBack.remove(id)
        pendingSaves.removeValue(forKey: id)?.cancel()
        if currentItemID == id { currentItemID = nil; onCurrentChange?() }
        try? FileManager.default.removeItem(at: file(for: id))
    }

    // MARK: - Deleting with Undo

    /// Entries deleted together, kept in memory for `undoWindow` so Undo can
    /// bring them back. Never written to disk.
    struct DeletedBatch: Sendable {
        let items: [ClipItem]
        let date: Date
    }

    /// How long a deletion can be undone.
    static let undoWindow: TimeInterval = 5 * 60

    /// The deletions that can still be undone, the latest last.
    private(set) var deleted: [DeletedBatch] = []

    /// What Undo Delete would bring back, if anything.
    var undoableDelete: DeletedBatch? {
        deleted.last { Date().timeIntervalSince($0.date) < Self.undoWindow }
    }

    /// Deletes entries so that `undoDelete` can bring them back.
    func delete(undoably ids: some Sequence<UUID>) {
        let wanted = Set(ids)
        let gone = items.filter { wanted.contains($0.id) && $0.pending != true }
        for item in gone { delete(item.id) }
        guard !gone.isEmpty else { return }
        deleted.removeAll { Date().timeIntervalSince($0.date) >= Self.undoWindow }
        deleted.append(DeletedBatch(items: gone, date: Date()))
        if deleted.count > 50 { deleted.removeFirst() }
    }

    /// Brings back the last deletion: the entries return to their places.
    /// Those copied again since stay where they are now.
    @discardableResult
    func undoDelete() -> [ClipItem] {
        guard let batch = undoableDelete else { return [] }
        deleted.removeAll { $0.date == batch.date }
        let back = batch.items.filter { old in !items.contains { $0.digest == old.digest || $0.id == old.id } }
        for item in back { save(item) }
        items = (items + back).sorted { $0.date > $1.date }
        return back
    }

    // MARK: - Names

    /// Names an entry; an empty name, or nil, shows its contents again.
    func rename(_ id: UUID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    // MARK: - Size

    /// What the history takes on disk, and how many entries it has there.
    func diskUsage() -> (bytes: Int64, entries: Int) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension == "plist" {
            let values = try? file.resourceValues(forKeys: keys)
            bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    var diskUsageText: String {
        let usage = diskUsage()
        return "\(usage.entries) \(usage.entries == 1 ? "entry" : "entries"), "
            + ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
    }

    // MARK: - Several as one

    /// The text of several entries, one after the other, separated by a line
    /// break: plain, and formatted when any of them is. Entries without text
    /// (images, files) are left out. The list is theirs when they share one,
    /// else the one list with Paste Guard rules among them; entries of two
    /// lists with rules are not joined, nor is a password with anything.
    func joined(_ ids: [UUID], separator: String = "\n") throws -> (plain: String, rich: NSAttributedString?, list: String, password: Bool) {
        let chosen = ids.compactMap(item).filter { $0.isEditableText && $0.pending != true }
        guard !chosen.isEmpty else { throw ClipboardError("None of these entries is text.") }
        let lists = Set(chosen.map(\.list))
        let list: String
        if lists.count == 1 {
            list = lists.first!
        } else {
            let restricted = lists.filter { settings.list($0).isRestricted }
            guard restricted.count <= 1 else {
                throw ClipboardError("These entries come from several lists with Paste Guard rules, so they are not joined.")
            }
            list = restricted.first ?? chosen[0].list
        }
        let passwords = chosen.filter(\.isPassword).count
        if passwords > 0 && chosen.count > 1 {
            throw ClipboardError("A password is not joined with other entries.")
        }
        let plain = chosen.map { $0.string ?? $0.attributedString?.string ?? "" }.joined(separator: separator)
        var rich: NSAttributedString?
        if chosen.contains(where: { $0.kind == .richText }) {
            let out = NSMutableAttributedString()
            let plainAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            for (i, item) in chosen.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: separator, attributes: plainAttrs)) }
                out.append(item.kind == .richText ? item.attributedString ?? NSAttributedString()
                           : NSAttributedString(string: item.string ?? "", attributes: plainAttrs))
            }
            rich = out
        }
        return (plain, rich, list, passwords > 0)
    }

    /// Puts several entries on the clipboard as one, joined; the result is a
    /// new entry of their list.
    @discardableResult
    func copyJoined(_ ids: [UUID], separator: String = "\n") throws -> ClipItem? {
        let j = try joined(ids, separator: separator)
        var types = [NSPasteboard.PasteboardType.string.rawValue: Data(j.plain.utf8)]
        if let rich = j.rich, let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            types[NSPasteboard.PasteboardType.rtf.rawValue] = rtf
        }
        let count = ids.count
        inheriting(from: ids) {
            engine.put(types: types, name: "\(count) entries joined", rules: PasteRules(password: j.password, list: j.list))
        }
        let digest = ClipItem.digest(of: [types])
        return items.first { $0.digest == digest }
    }

    /// Empties the history, or one list of it; pinned entries stay unless
    /// `includingPinned`.
    func clear(includingPinned: Bool = false, list: String? = nil) {
        delete(undoably: items.filter { (includingPinned || !$0.pinned) && (list == nil || $0.list == list) }.map(\.id))
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
        classifyEntries()

        if currentItemID == id && pasteboard.changeCount == lastChangeCount {
            engine.put(items: item.pasteboardItems, name: item.title, concealed: item.isPassword)
            lastChangeCount = pasteboard.changeCount
        }
    }

    /// Replaces the image of an entry with an edited one, keeping the
    /// edits (with the original) so they stay changeable. When the entry is
    /// what is on the clipboard, the clipboard gets the new image as well.
    func updateImage(_ id: UUID, png: Data, edits: ImageEdits) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.items = [[NSPasteboard.PasteboardType.png.rawValue: png]]
        item.digest = ClipItem.digest(of: item.items)
        item.edits = edits
        item.edited = Date()
        items[index] = item
        saveSoon(item)
        readImageTexts()

        if currentItemID == id && pasteboard.changeCount == lastChangeCount {
            engine.put(items: item.pasteboardItems, name: item.title, concealed: item.isPassword)
            lastChangeCount = pasteboard.changeCount
        }
    }

    /// A screenshot: on the clipboard, and an image entry of the screenshot
    /// list.
    @discardableResult
    func addScreenshot(_ png: Data, label: String) -> ClipItem? {
        let types = [NSPasteboard.PasteboardType.png.rawValue: png]
        engine.put(items: [[.png: png]], name: label)
        lastChangeCount = pasteboard.changeCount
        var item = ClipItem(items: [types], sourceApp: "Screenshot")
        item.sourceBundleID = Bundle.main.bundleIdentifier
        item.label = label
        let list = settings.value.screenshotList ?? ClipList.defaultID
        item.listID = list == ClipList.defaultID ? nil : list
        record(item)
        if let id = currentItemID, self.item(id)?.list != list { move(id, toList: list) }
        return currentItemID.flatMap(self.item)
    }

    /// Objects copied in the image editor: on the clipboard (as objects for
    /// the editors and as a picture), and an entry of the list the settings
    /// name for them, unless they are not to be kept.
    func addImageObjects(_ types: [String: Data], label: String) {
        engine.put(items: [types.reduce(into: [:]) { $0[NSPasteboard.PasteboardType($1.key)] = $1.value }], name: label)
        lastChangeCount = pasteboard.changeCount
        guard settings.value.imageObjectsRecorded else {
            currentItemID = nil
            return
        }
        var item = ClipItem(items: [types], sourceApp: "Snippad")
        item.sourceBundleID = Bundle.main.bundleIdentifier
        item.label = label
        let list = settings.value.imageObjectsList ?? ClipList.defaultID
        item.listID = list == ClipList.defaultID ? nil : list
        record(item)
        if let id = currentItemID, self.item(id)?.list != list { move(id, toList: list) }
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
        if let inherited = inheritedForNext {
            item.inheritedCategory = ClipCategory.careful(item.inheritedCategory, inherited)
        }
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

    /// Makes a plain text entry formatted text, in the system font, to be
    /// edited with fonts, colours and the rest.
    func makeRichText(_ id: UUID) {
        guard let item = item(id), item.kind != .richText, let text = item.string else { return }
        updateText(id, plain: text, rich: NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.textColor,
        ]))
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
        inheriting(from: [id]) {
            putText(text, name: (what == .paths ? "Paths of " : "Names of ") + item.title, list: item.list)
        }
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
        /// Rich text written as Markdown, as plain text.
        case markdown
        /// The text read from an image, as plain text.
        case textOfImage
    }

    /// Whether the entry has rich text to paste as such.
    func hasRichText(_ id: UUID) -> Bool {
        item(id)?.hasFormatting ?? false
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
                return (item.label?.localizedCaseInsensitiveContains(q) ?? false)
                    || (item.name?.localizedCaseInsensitiveContains(q) ?? false)
            }
            return item.title.localizedCaseInsensitiveContains(q)
                || (item.string?.localizedCaseInsensitiveContains(q) ?? false)
                || item.fileURLs.contains { $0.path.localizedCaseInsensitiveContains(q) }
                || (item.sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.label?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.name?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.metadata?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func update(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save(items[index])
    }

    /// Keeps each list within the limit, and drops entries older than the
    /// age limit; pinned entries stay.
    func trim() {
        let days = settings.value.historyMaxAgeDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
        var counts: [String: Int] = [:]
        for item in items where !item.pinned && item.pending != true {
            counts[item.list, default: 0] += 1
            if counts[item.list]! > limit || (cutoff.map { item.date < $0 } ?? false) { delete(item.id) }
        }
    }

    /// How many entries the age limit would delete now; for the settings,
    /// to ask before it does.
    func countOlder(thanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return items.filter { !$0.pinned && $0.date < cutoff }.count
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

    /// The text read from an entry's picture, unless the picture changed
    /// meanwhile: then it is read again. An entry deleted meanwhile is gone.
    /// Converts the HTML of every entry copied as HTML only, newest first,
    /// one at a time on a background thread. When WebKit does not answer,
    /// only this waits -- never a window or the menu.
    func convertFormattedTexts() {
        guard htmlConverter == nil else { return }
        htmlConverter = Task { [weak self] in
            while let self, let next = self.items.first(where: \.needsHTMLConversion) {
                let id = next.id, digest = next.digest, html = next.items.lazy.compactMap { $0[NSPasteboard.PasteboardType.html.rawValue] }.first
                let rtf = await Task.detached(priority: .utility) { () -> Data? in
                    guard let html, let text = ClipItem.read(html: html) else { return nil }
                    return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
                }.value
                guard let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].digest == digest else { continue }
                self.items[index].converted = rtf
                self.items[index].convertedFrom = digest
                self.save(self.items[index])
            }
            self?.htmlConverter = nil
        }
    }

    /// The category classified, unless the entry changed meanwhile: then
    /// it is classified again.
    func setCategory(_ category: ClipCategory, byModel: Bool, of id: UUID, key: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].classificationKey == key else { return }
        items[index].category = category
        items[index].categoryFrom = key
        items[index].categoryByModel = byModel
        items[index].categoryVersion = ClipClassifier.version
        save(items[index])
        if id == currentItemID { onCurrentChange?() }  // pasting it may now ask
    }

    /// The user's own category for entries; nil goes back to the classified one.
    func setUserCategory(_ category: ClipCategory?, of ids: [UUID]) {
        for id in ids { update(id) { $0.userCategory = category } }
        if let current = currentItemID, ids.contains(current) { onCurrentChange?() }
    }

    func setReadText(_ text: String, of id: UUID, from digest: String, in languages: [String]?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].digest == digest else { return }
        items[index].readText = text
        items[index].readTextFrom = digest
        items[index].readTextLanguages = languages ?? []
        save(items[index])
        classifyEntries()  // what it says decides its category
    }

    /// Whether an entry goes to disk: never when it is Sensitive, Private
    /// or Secret -- then its file goes, and it lives only until Snippad
    /// quits. While classifying is on, a new entry waits for its category
    /// before it is written; one already on disk is left alone meanwhile.
    enum Keeping { case write, delete, wait }

    func keeping(_ item: ClipItem) -> Keeping {
        if let category = item.category(in: settings.value) {
            return category == .general ? .write : .delete
        }
        let classifiable = item.isPassword || [.text, .url, .richText, .image].contains(item.kind)
        return settings.value.classifyEntries && classifiable ? .wait : .write
    }

    /// Writes what may be written and was held back, and deletes the files
    /// of what may not be on disk: after classifying, a choice of the user,
    /// or a change of Settings (Never Public, classifying switched off).
    func reconcileFiles() {
        for item in items where item.pending != true {
            switch keeping(item) {
            case .delete:
                try? FileManager.default.removeItem(at: file(for: item.id))
                heldBack.remove(item.id)
            case .write where heldBack.contains(item.id) || !FileManager.default.fileExists(atPath: file(for: item.id).path):
                save(item)
            default:
                break
            }
        }
    }

    private func save(_ item: ClipItem) {
        guard item.pending != true else { return }
        switch keeping(item) {
        case .delete:
            heldBack.remove(item.id)
            try? FileManager.default.removeItem(at: file(for: item.id))
            return
        case .wait:
            heldBack.insert(item.id)
            return
        case .write:
            heldBack.remove(item.id)
        }
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
