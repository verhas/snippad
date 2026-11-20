import AppKit
import Foundation

/// `~/.snippad`: the settings and the applications Snippad knows, as JSON
/// files a person can read (and, with Snippad not running, edit).
enum SnippadHome {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".snippad", isDirectory: true)

    /// Running the unit tests: nothing may touch the real ~/.snippad.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Which applications may get a paste from a list.
enum GuardMode: String, Codable, CaseIterable, Sendable {
    /// No restriction.
    case anyApp
    /// Only the listed applications (an allow list).
    case onlyListed
    /// Every application but the listed ones (a deny list).
    case allExceptListed
}

/// A named list the history is divided into. Every history entry belongs to
/// one list.
struct ClipList: Codable, Identifiable, Hashable, Sendable {
    /// The list that always exists and cannot be deleted.
    static let defaultID = "clipboard"

    var id: String
    var name: String
    var guardMode: GuardMode
    /// Bundle identifiers for `guardMode`.
    var guardApps: [String]
    /// In web browsers, entries of this list may only be pasted into private
    /// (incognito) windows.
    var privateBrowsingOnly: Bool
    /// SF Symbol shown for the list in the history window; nil is a tray.
    var icon: String?

    var symbol: String { icon ?? "tray" }

    /// The Paste Guard can stop a paste from this list. Only then does
    /// Snippad need its keyboard tap for it.
    var isRestricted: Bool {
        privateBrowsingOnly || (guardMode != .anyApp && !(guardMode == .allExceptListed && guardApps.isEmpty))
    }

    init(id: String = UUID().uuidString, name: String, guardMode: GuardMode = .anyApp,
         guardApps: [String] = [], privateBrowsingOnly: Bool = false, icon: String? = nil) {
        self.icon = icon
        self.id = id
        self.name = name
        self.guardMode = guardMode
        self.guardApps = guardApps
        self.privateBrowsingOnly = privateBrowsingOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        guardMode = try c.decodeIfPresent(GuardMode.self, forKey: .guardMode) ?? .anyApp
        guardApps = try c.decodeIfPresent([String].self, forKey: .guardApps) ?? []
        privateBrowsingOnly = try c.decodeIfPresent(Bool.self, forKey: .privateBrowsingOnly) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

/// Everything `~/.snippad/settings.json` holds. Keys missing from the file
/// take their default, so an old or hand-written file still loads.
struct SnippadSettings: Codable, Equatable, Sendable {
    var recordHistory = true
    /// Unpinned entries kept per list.
    var historyLimit = 200
    var hotKeyEnabled = true
    var pasteAfterChoosing = false
    /// Bundle identifiers whose copies are not recorded.
    var excludedApps: [String] = []
    var lists: [ClipList] = [ClipList(id: ClipList.defaultID, name: "Clipboard")]
    /// Bundle identifier -> list id: where copies from that app go.
    var appLists: [String: String] = [:]
    /// Where copies made in a private browser window go; nil follows
    /// `appLists`.
    var privateBrowsingList: String?
    /// Check every ⌘V against the lists' rules.
    var pasteGuardEnabled = false
    /// "off", "absolute" or "relative", in the history window's editor.
    var lineNumbers = "absolute"
    /// Long lines wrap in the text editors; off scrolls sideways.
    var wordWrap = true
    /// The organizer's toolbar: NSToolbar.DisplayMode (1 icon and text,
    /// 2 icon only, 3 text only), as chosen from its right-click menu.
    var toolbarDisplayMode = 1
    /// ⇧⌘V opens a window with the preferred list's entries.
    var pickerHotKeyEnabled = true
    /// The list the history window highlights and ⇧⌘V shows; nil is all
    /// lists.
    var preferredList: String?
    /// .snippad files opened from outside ~/.snippad, kept in the history
    /// window's sidebar until closed there. Those in ~/.snippad are always
    /// listed.
    var openSnippadFiles: [String] = []
    /// The .snippad button windows open when Snippad last ran; opened again
    /// at launch.
    var openWindows: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnippadSettings()
        recordHistory = try c.decodeIfPresent(Bool.self, forKey: .recordHistory) ?? d.recordHistory
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? d.hotKeyEnabled
        pasteAfterChoosing = try c.decodeIfPresent(Bool.self, forKey: .pasteAfterChoosing) ?? d.pasteAfterChoosing
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
        lists = try c.decodeIfPresent([ClipList].self, forKey: .lists) ?? d.lists
        appLists = try c.decodeIfPresent([String: String].self, forKey: .appLists) ?? d.appLists
        privateBrowsingList = try c.decodeIfPresent(String.self, forKey: .privateBrowsingList)
        pasteGuardEnabled = try c.decodeIfPresent(Bool.self, forKey: .pasteGuardEnabled) ?? d.pasteGuardEnabled
        lineNumbers = try c.decodeIfPresent(String.self, forKey: .lineNumbers) ?? d.lineNumbers
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? d.wordWrap
        toolbarDisplayMode = try c.decodeIfPresent(Int.self, forKey: .toolbarDisplayMode) ?? d.toolbarDisplayMode
        pickerHotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .pickerHotKeyEnabled) ?? d.pickerHotKeyEnabled
        preferredList = try c.decodeIfPresent(String.self, forKey: .preferredList)
        openSnippadFiles = try c.decodeIfPresent([String].self, forKey: .openSnippadFiles) ?? d.openSnippadFiles
        openWindows = try c.decodeIfPresent([String].self, forKey: .openWindows) ?? d.openWindows
        normalize()
    }

    /// The default list exists and comes first; references to lists that are
    /// gone are dropped.
    mutating func normalize() {
        if let i = lists.firstIndex(where: { $0.id == ClipList.defaultID }) {
            if i != 0 { lists.insert(lists.remove(at: i), at: 0) }
        } else {
            lists.insert(ClipList(id: ClipList.defaultID, name: "Clipboard"), at: 0)
        }
        let ids = Set(lists.map(\.id))
        appLists = appLists.filter { ids.contains($0.value) }
        if let p = privateBrowsingList, !ids.contains(p) { privateBrowsingList = nil }
        if let p = preferredList, !ids.contains(p) { preferredList = nil }
        historyLimit = max(1, historyLimit)
    }
}

/// The settings, loaded from and saved to `~/.snippad/settings.json` on
/// every change.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SnippadHome.isTesting ? SettingsStore(url: nil)
        : SettingsStore(url: SnippadHome.directory.appendingPathComponent("settings.json"), migrate: true)

    /// nil keeps the settings in memory only (tests).
    @ObservationIgnored let url: URL?

    var value: SnippadSettings {
        didSet {
            guard value != oldValue else { return }
            value.normalize()
            save()
            onChange?()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?

    init(url: URL?, migrate: Bool = false) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let loaded = try? SnippadHome.decoder.decode(SnippadSettings.self, from: data) {
            value = loaded
        } else {
            var s = SnippadSettings()
            if migrate {
                // The first versions kept these in the user defaults.
                let d = UserDefaults.standard
                if let b = d.object(forKey: "captureClipboard") as? Bool { s.recordHistory = b }
                if let n = d.object(forKey: "historyLimit") as? Int { s.historyLimit = n }
                if let b = d.object(forKey: "hotKeyEnabled") as? Bool { s.hotKeyEnabled = b }
                if let b = d.object(forKey: "pasteAfterChoosing") as? Bool { s.pasteAfterChoosing = b }
            }
            value = s
            // Not from the unit tests, which must leave ~/.snippad alone.
            if migrate && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { save() }
        }
    }

    func save() {
        guard let url else { return }
        do {
            try SnippadHome.write(try SnippadHome.encoder.encode(value), to: url)
        } catch {
            NSLog("Snippad could not save its settings: %@", error.localizedDescription)
        }
    }

    // MARK: - Questions the rest of the app asks

    func list(_ id: String?) -> ClipList {
        value.lists.first { $0.id == id } ?? value.lists[0]
    }

    /// The list a copy from this app goes to.
    func listID(for bundleID: String?) -> String {
        bundleID.flatMap { value.appLists[$0] } ?? ClipList.defaultID
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        bundleID.map(value.excludedApps.contains) ?? false
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        value.excludedApps.removeAll { $0 == bundleID }
        if excluded { value.excludedApps.append(bundleID) }
    }

    /// Whether any setting names this application: excluded, given a list,
    /// or in a list's Paste Guard rules.
    func mentions(_ bundleID: String) -> Bool {
        value.excludedApps.contains(bundleID) || value.appLists[bundleID] != nil
            || value.lists.contains { $0.guardApps.contains(bundleID) }
    }

    /// Removes every setting that names this application.
    func forgetApp(_ bundleID: String) {
        var v = value
        v.excludedApps.removeAll { $0 == bundleID }
        v.appLists[bundleID] = nil
        for i in v.lists.indices { v.lists[i].guardApps.removeAll { $0 == bundleID } }
        value = v
    }

    @discardableResult
    func addList(named name: String) -> ClipList {
        var unique = name
        var n = 2
        while value.lists.contains(where: { $0.name == unique }) { unique = "\(name) \(n)"; n += 1 }
        let list = ClipList(name: unique)
        value.lists.append(list)
        return list
    }

    /// The list a snippet names (by name, or id), or nil for the default.
    func listID(named ref: String?) -> String? {
        guard let ref, !ref.isEmpty else { return nil }
        let lists = value.lists
        return (lists.first { $0.id == ref } ?? lists.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame })?.id
    }
}

/// An application Snippad has seen: installed, or the source of a copy.
struct AppRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var path: String?
    /// Found by the last scan of the application folders.
    var installed: Bool?
    /// How many copies came from it.
    var copies: Int?
    var firstCopy: Date?
    var lastCopy: Date?
    /// The application is nowhere to be found, but settings still name it.
    var missing: Bool?
}

/// The installed applications, scanned at every launch, and every
/// application a copy came from, kept in `~/.snippad/apps.json`.
@MainActor
@Observable
final class AppCatalog {
    static let shared = AppCatalog(url: SnippadHome.isTesting ? nil : SnippadHome.directory.appendingPathComponent("apps.json"))

    private(set) var apps: [String: AppRecord] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let list = try? SnippadHome.decoder.decode([AppRecord].self, from: data) {
            apps = Dictionary(list.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var sorted: [AppRecord] {
        apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func name(for bundleID: String) -> String {
        apps[bundleID]?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
            ?? bundleID
    }

    func icon(for bundleID: String) -> NSImage {
        if let path = apps[bundleID]?.path ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// Looks through the application folders, off the main thread, then
    /// deals with applications that are gone.
    func scanInstalled(settings: SettingsStore? = nil) async {
        defer { if let settings { reconcile(with: settings) } }
        let found = await Task.detached(priority: .utility) { Self.scan() }.value
        let foundIDs = Set(found.map(\.bundleID))
        for (id, var record) in apps {
            record.installed = foundIDs.contains(id)
            apps[id] = record
        }
        for app in found {
            var record = apps[app.bundleID] ?? app
            record.name = app.name
            record.path = app.path
            record.installed = true
            apps[app.bundleID] = record
        }
        scheduleSave()
    }

    nonisolated static let folders: [URL] = {
        let fm = FileManager.default
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }()

    nonisolated static func scan() -> [AppRecord] {
        var out: [AppRecord] = []
        let fm = FileManager.default
        for folder in folders {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                e.skipDescendants()
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                // Some bundles name themselves with invisible characters only.
                let candidates = [bundle.localizedInfoDictionary?["CFBundleDisplayName"], bundle.infoDictionary?["CFBundleDisplayName"],
                                  bundle.infoDictionary?["CFBundleName"]].compactMap { $0 as? String }
                    + [url.deletingPathExtension().lastPathComponent]
                let name = candidates.lazy.map(Self.visible).first { !$0.isEmpty } ?? id
                out.append(AppRecord(bundleID: id, name: name, path: url.path, installed: true))
            }
        }
        return out
    }

    nonisolated static func visible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After a scan: an application that is no longer anywhere is forgotten
    /// when no setting names it, and marked missing when one does.
    func reconcile(with settings: SettingsStore) {
        for (id, var record) in apps {
            if record.installed == true || Self.exists(record.path) {
                record.missing = nil
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), Self.exists(url.path) {
                record.path = url.path
                record.missing = nil
            } else if settings.mentions(id) {
                record.missing = true
            } else {
                apps[id] = nil
                continue
            }
            apps[id] = record
        }
        scheduleSave()
    }

    private nonisolated static func exists(_ path: String?) -> Bool {
        guard let path, !path.contains("/.Trash/") else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// For the tests.
    func set(_ record: AppRecord) { apps[record.bundleID] = record }

    /// Forgets an application and every setting that names it.
    func remove(_ bundleID: String, settings: SettingsStore) {
        apps[bundleID] = nil
        settings.forgetApp(bundleID)
        scheduleSave()
    }

    /// The user says where a missing application is now.
    func locate(_ bundleID: String, at url: URL) throws {
        guard let bundle = Bundle(url: url), let found = bundle.bundleIdentifier else {
            throw ClipboardError("\u{201C}\(url.lastPathComponent)\u{201D} is not an application.")
        }
        guard found == bundleID else {
            throw ClipboardError("\u{201C}\(url.lastPathComponent)\u{201D} is \(found), not \(bundleID). The settings name \(bundleID); remove it and set up \(url.deletingPathExtension().lastPathComponent) instead.")
        }
        var record = apps[bundleID] ?? AppRecord(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent)
        record.path = url.path
        record.missing = nil
        apps[bundleID] = record
        scheduleSave()
    }

    /// Remembers that a copy came from this app.
    func noteCopy(from app: NSRunningApplication?, date: Date = Date()) {
        guard let app, let id = app.bundleIdentifier else { return }
        var record = apps[id] ?? AppRecord(bundleID: id, name: app.localizedName ?? id, path: app.bundleURL?.path)
        record.copies = (record.copies ?? 0) + 1
        record.firstCopy = record.firstCopy ?? date
        record.lastCopy = date
        if let name = app.localizedName { record.name = name }
        apps[id] = record
        scheduleSave()
    }

    private func scheduleSave() {
        guard url != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let url else { return }
        do {
            try SnippadHome.write(try SnippadHome.encoder.encode(sorted), to: url)
        } catch {
            NSLog("Snippad could not save the applications list: %@", error.localizedDescription)
        }
    }
}
