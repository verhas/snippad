import AppKit
import Carbon.HIToolbox

/// A key combination, as written in a .snippad file (`"ctrl+opt+k"`) and
/// shown in menus (`⌃⌥K`).
struct KeyShortcut: Hashable, Sendable {
    let key: String
    var control = false
    var option = false
    var shift = false
    var command = false

    /// name in the file, virtual key code, how it is shown.
    static let keys: [(name: String, code: Int, display: String)] = {
        var out: [(String, Int, String)] = []
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
            ("/", kVK_ANSI_Slash), ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
        ]
        for (name, code) in letters { out.append((name, code, name.uppercased())) }
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fKeys.enumerated() { out.append(("f\(i + 1)", code, "F\(i + 1)")) }
        out.append(("space", kVK_Space, "Space"))
        return out
    }()

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") }

    /// A function key may stand alone; anything else needs ⌃, ⌥ or ⌘, or it
    /// would take a key you type with.
    var isUsable: Bool { isFunctionKey || control || option || command }

    init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// Reads `"ctrl+opt+shift+cmd+k"`; the parts in any order, any case.
    init?(_ text: String) {
        var parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        // "ctrl++" is ctrl and the plus key, which has no ANSI code here.
        guard let last = parts.popLast(), !last.isEmpty,
              Self.keys.contains(where: { $0.name == last }) else { return nil }
        key = last
        for part in parts {
            switch part {
            case "ctrl", "control", "⌃": control = true
            case "opt", "option", "alt", "⌥": option = true
            case "shift", "⇧": shift = true
            case "cmd", "command", "⌘": command = true
            default: return nil
            }
        }
    }

    /// From a key press, in the recorder.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let entry = Self.keys.first(where: { $0.code == Int(keyCode) }) else { return nil }
        key = entry.name
        control = flags.contains(.control)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        command = flags.contains(.command)
    }

    /// As written in the file.
    var text: String {
        ([control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil, command ? "cmd" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// As shown: ⌃⌥⇧⌘K.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (Self.keys.first { $0.name == key }?.display ?? key)
    }

    var keyCode: Int { Self.keys.first { $0.name == key }?.code ?? 0 }

    var carbonModifiers: Int {
        (control ? controlKey : 0) | (option ? optionKey : 0) | (shift ? shiftKey : 0) | (command ? cmdKey : 0)
    }

    /// For NSMenuItem: a single character key, else nil.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard key.count == 1 else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if control { mask.insert(.control) }
        if option { mask.insert(.option) }
        if shift { mask.insert(.shift) }
        if command { mask.insert(.command) }
        return (key, mask)
    }
}

/// The system-wide shortcuts of snippets: every snippet with a `shortcut`
/// in an open .snippad file. Pressing one puts the snippet on the clipboard,
/// with its rules, and pastes it when "Paste after choosing" is on.
@MainActor
enum SnippetShortcuts {
    private static var hotKeys: [HotKey] = []
    private static var signature = ""
    private static var paused = false
    /// Shortcuts that could not be registered: the system or another app
    /// has them.
    private(set) static var unavailable: Set<KeyShortcut> = []

    /// Snippad's own shortcuts, which a snippet cannot take.
    static var reserved: [KeyShortcut: String] {
        var out: [KeyShortcut: String] = [:]
        let s = SettingsStore.shared.value
        if s.hotKeyEnabled { out[s.historyShortcut] = "Snippad\u{2019}s history menu" }
        if s.pickerHotKeyEnabled { out[s.pickerShortcut] = "Snippad\u{2019}s picker window" }
        if s.organizerHotKeyEnabled { out[s.organizerShortcut] = "the Snippad Organizer" }
        return out
    }

    /// Every snippet with a shortcut, in the open files: (file, snippet, all
    /// snippets of its file).
    static func assigned() -> [(url: URL, snippet: Snippet, all: [Snippet])] {
        SnippadLibrary.shared.files.flatMap { url -> [(URL, Snippet, [Snippet])] in
            guard case .success(let snippets) = SnippadContent.read(url) else { return [] }
            return snippets.filter { $0.shortcut != nil }.map { (url, $0, snippets) }
        }
    }

    /// Who else uses a shortcut: another snippet ("File › name") or Snippad.
    static func conflict(for shortcut: KeyShortcut, except: (url: URL, name: String)?) -> String? {
        if let own = reserved[shortcut] { return own }
        for a in assigned() where a.snippet.shortcut.flatMap(KeyShortcut.init) == shortcut {
            if let except, SnippadLibrary.key(a.url) == SnippadLibrary.key(except.url), a.snippet.name == except.name { continue }
            return "\u{201C}\(a.snippet.name)\u{201D} in \(a.url.deletingPathExtension().lastPathComponent)"
        }
        return nil
    }

    /// Registers the shortcuts of the open files anew, when anything they
    /// depend on changed.
    static func refresh(force: Bool = false) {
        guard !SnippadHome.isTesting, !paused else { return }
        let fm = FileManager.default
        let files = SnippadLibrary.shared.files
        let s = SettingsStore.shared.value
        let sig = files.map { url in
            "\(url.path)@\(((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|") + "|\(s.hotKeyEnabled)\(s.pickerHotKeyEnabled)\(s.organizerHotKeyEnabled)|\(s.historyHotKey)|\(s.pickerHotKey)|\(s.organizerHotKey)"
        guard force || sig != signature else { return }
        signature = sig
        unregisterAll()
        var taken = Set(reserved.keys)
        var failed: Set<KeyShortcut> = []
        for (_, snippet, all) in assigned() {
            guard let shortcut = snippet.shortcut.flatMap(KeyShortcut.init), shortcut.isUsable,
                  taken.insert(shortcut).inserted else { continue }
            if let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: { fire(snippet, all: all) }) {
                hotKeys.append(hotKey)
            } else {
                failed.insert(shortcut)
            }
        }
        unavailable = failed
    }

    /// While a shortcut is being recorded, none of them fires.
    static func pause() {
        paused = true
        unregisterAll()
    }

    static func resume() {
        paused = false
        refresh(force: true)
    }

    private static func unregisterAll() {
        hotKeys.forEach { $0.unregister() }
        hotKeys = []
    }

    private static func fire(_ snippet: Snippet, all: [Snippet]) {
        PasteEngine.shared.put(types: snippet.pasteboardTypes, name: snippet.name, rules: snippet.rules(in: all))
        PasteInterceptor.pasteIfWanted()
    }
}
