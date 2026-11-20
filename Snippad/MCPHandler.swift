import AppKit

/// The JSON-RPC side of Snippad's MCP server: initialize, tools/list and
/// tools/call, answered on the main thread.
@MainActor
enum MCPHandler {

    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// One request or notification in, one response out (nil for a
    /// notification).
    static func handle(_ line: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        func result(_ value: [String: Any]) -> Data? {
            encode(["jsonrpc": "2.0", "id": id, "result": value])
        }
        func failure(_ code: Int, _ text: String) -> Data? {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return result([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "snippad",
                               "title": "Snippad",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                "instructions": instructions,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": MCPTools.all.map(\.descriptor)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return failure(-32602, "Unknown tool: \(params["name"] ?? "")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(["content": try tool.run(MCPArguments(arguments)), "isError": false])
            } catch {
                return result(["content": [MCPTools.text(error.localizedDescription)], "isError": true])
            }
        default:
            return failure(-32601, "Method not found: \(method)")
        }
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static let instructions = """
        Snippad is the user's clipboard manager. It records what is copied \
        (text, rich text, images, files), and keeps named snippets in .snippad \
        files. A snippet can expire from the clipboard after a time, leave it \
        after one paste (`once`), or chain to another snippet that replaces it \
        once pasted (`next`), as for a user name followed by a password. \
        Values marked concealed by password managers are neither recorded nor \
        revealed.
        """
}

struct MCPToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Typed access to a tool call's arguments.
struct MCPArguments {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key] as? String }

    func requiredString(_ key: String) throws -> String {
        guard let s = string(key) else { throw MCPToolError("'\(key)' is required and must be a string") }
        return s
    }

    func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber).map(\.boolValue) }

    func int(_ key: String) -> Int? { (raw[key] as? NSNumber).map(\.intValue) }

    /// Seconds, given as a number or as a duration such as "5m".
    func duration(_ key: String) throws -> Int? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        if let n = value as? NSNumber, n.intValue > 0 { return n.intValue }
        if let s = value as? String, let n = SnippetDuration.seconds(from: s), n > 0 { return n }
        throw MCPToolError("'\(key)' must be a positive number of seconds or a duration such as \"30s\" or \"5m\"")
    }

    func id() throws -> UUID {
        guard let s = string("id"), let id = UUID(uuidString: s) else { throw MCPToolError("'id' must be a history item id") }
        return id
    }

    /// A .snippad path; `~` is expanded.
    func snippadURL(_ key: String = "path") throws -> URL {
        let path = (try requiredString(key) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw MCPToolError("'\(key)' must be an absolute path (or start with ~)") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "snippad" else { throw MCPToolError("'\(key)' must name a .snippad file") }
        return url
    }
}

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    var readOnly = false
    var destructive = false
    let run: @MainActor (MCPArguments) throws -> [[String: Any]]

    var descriptor: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required,
                            "additionalProperties": false] as [String: Any],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": readOnly, "openWorldHint": false],
        ]
    }
}

@MainActor
enum MCPTools {

    // MARK: - Schema helpers

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }
    private static let durationProp: [String: Any] = [
        "type": ["integer", "string"],
        "description": "Remove from the clipboard after this long: seconds, or a duration like \"30s\", \"5m\", \"1h30m\".",
    ]
    private static let snippetSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": prop("string", "The button label; unique if other snippets chain to it."),
            "value": prop("string", "The text the snippet copies."),
            "expires": durationProp,
            "once": prop("boolean", "Remove from the clipboard after it is pasted once."),
            "next": prop("string", "Name of the snippet put on the clipboard after this one is pasted."),
            "password": prop("boolean", "The value is a password: hidden in Snippad, shown as dots in the history, never returned by these tools."),
            "list": prop("string", "Name of the history list its copies go to; default the first list (Clipboard)."),
            "kind": prop("string", "text (default); rich: the value is RTF; file: the value is a file path, and the file itself is copied; image: the value is a base64 PNG."),
        ],
        "required": ["name", "value"],
    ]

    static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    static func json(_ object: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return text(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Converting

    private static let iso = ISO8601DateFormatter()

    private static func summary(_ item: ClipItem) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id.uuidString,
            "kind": item.kind.rawValue,
            "title": item.title,
            "date": iso.string(from: item.date),
            "pinned": item.pinned,
            "bytes": item.byteCount,
            "types": item.types,
        ]
        if let app = item.sourceApp { out["source_app"] = app }
        out["list"] = SettingsStore.shared.list(item.list).name
        out["list_id"] = item.list
        if item.isPassword { out["password"] = true }
        if item.kind == .files {
            out["files"] = item.fileURLs.map(\.path)
            let missing = item.missingFiles
            if !missing.isEmpty { out["missing_files"] = missing.map(\.path) }
        }
        if let m = item.metadata { out["image_metadata"] = m }
        return out
    }

    private static func content(of item: ClipItem) -> [[String: Any]] {
        var out: [[String: Any]] = [json(summary(item))]
        if item.isPassword {
            out.append(text("This entry is a password; its value is not revealed."))
            return out
        }
        if let s = item.string { out.append(text(s)) }
        if item.kind == .files {
            out.append(text(item.fileURLs.map(\.path).joined(separator: "\n")))
        }
        if item.kind == .image || item.string == nil, let png = item.pngData {
            out.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
        }
        return out
    }

    /// Password values are written as the mask; writing the mask back keeps
    /// the stored value.
    private static func dictionary(_ s: Snippet) -> [String: Any] {
        var out: [String: Any] = ["name": s.name, "value": s.password ? ClipItem.mask : s.value, "once": s.once,
                                  "kind": s.kind.rawValue]
        if s.kind == .image { out["value"] = imageMarker(s.value) }
        if s.password { out["password"] = true }
        if let e = s.expires { out["expires"] = SnippetDuration.text(e); out["expires_seconds"] = e }
        if let n = s.next { out["next"] = n }
        if let l = s.list { out["list"] = l }
        return out
    }

    private static func snippet(from raw: Any, index: Int) throws -> Snippet {
        guard let dict = raw as? [String: Any] else { throw MCPToolError("snippet \(index + 1) is not an object") }
        let args = MCPArguments(dict)
        var s = Snippet(id: index, name: try args.requiredString("name"), value: try args.requiredString("value"))
        s.expires = try args.duration("expires")
        s.once = args.bool("once") ?? false
        s.next = args.string("next")
        s.password = args.bool("password") ?? false
        s.list = args.string("list").flatMap { $0.isEmpty ? nil : $0 }
        if let k = args.string("kind") {
            guard let kind = SnippetKind(rawValue: k) else { throw MCPToolError("kind must be text, rich, file or image") }
            s.kind = kind
        }
        return s
    }

    /// An image's base64 is not handed to agents; this stands for it.
    static func imageMarker(_ base64: String) -> String {
        "(image, \(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)?.count ?? 0) bytes, not shown; write this back unchanged to keep it)"
    }

    /// A password left as the mask, or an image left as its marker, keeps
    /// its value from the file.
    private static func keepingPasswords(_ snippets: [Snippet], from old: [Snippet]) -> [Snippet] {
        snippets.map { s in
            if s.value == ClipItem.mask, let before = old.first(where: { $0.name == s.name && $0.password }) {
                return s.with(value: before.value)
            }
            if s.value.hasPrefix("(image, "), let before = old.first(where: { $0.name == s.name && $0.kind == .image }) {
                return s.with(value: before.value)
            }
            return s
        }
    }

    /// A list given by id or by name.
    private static func listID(_ ref: String) throws -> String {
        let lists = SettingsStore.shared.value.lists
        if let l = lists.first(where: { $0.id == ref }) ?? lists.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) {
            return l.id
        }
        throw MCPToolError("There is no list \u{201C}\(ref)\u{201D}. Lists: \(lists.map(\.name).joined(separator: ", ")).")
    }

    private static func existing(_ args: MCPArguments) throws -> ClipItem {
        guard let item = ClipboardHistory.shared.item(try args.id()) else { throw MCPToolError("No history entry has that id.") }
        return item
    }

    private static func readFile(_ url: URL) throws -> [Snippet] {
        try SnippadContent.read(url).get()
    }

    private static func writeFile(_ snippets: [Snippet], _ url: URL) throws {
        let numbered = snippets.enumerated().map { i, s in s.with(id: i) }
        try SnippadWriter.save(numbered, to: url)
        SnippadLibrary.shared.reloadIfOpen(url)
        SnippadLibrary.shared.reloadModel(url)
        SnippadLibrary.shared.add(url)
    }

    // MARK: - The tools

    static let all: [MCPTool] = [
        MCPTool(name: "clipboard_read", title: "Read the clipboard",
                description: "What is on the clipboard now: text, file paths, or an image. Values marked concealed (passwords, Snippad's paste-once and chained values) are not revealed.",
                properties: [:], required: [], readOnly: true) { _ in
            let engine = PasteEngine.shared
            if engine.awaitsPaste, let current = engine.current {
                return [text("The clipboard holds Snippad's \u{201C}\(current.name)\u{201D}, a paste-once or chained value. It is not revealed.")]
            }
            let pb = NSPasteboard.general
            guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return [text("The clipboard is empty.")] }
            if pbItems.contains(where: { $0.types.contains(.concealed) }) {
                return [text("The clipboard holds a value marked concealed (for example a password). It is not revealed.")]
            }
            var items: [[String: Data]] = []
            for pbItem in pbItems {
                var types: [String: Data] = [:]
                for type in pbItem.types where !type.rawValue.hasPrefix("dyn.") {
                    if let data = pbItem.data(forType: type) { types[type.rawValue] = data }
                }
                items.append(types)
            }
            var out = content(of: ClipItem(items: items))
            out[0] = json(summary(ClipItem(items: items)).filter { $0.key != "id" && $0.key != "pinned" && $0.key != "date" })
            return out
        },

        MCPTool(name: "clipboard_write", title: "Put text on the clipboard",
                description: "Puts text on the clipboard. Optionally it expires after a time, is removed after one paste, or is followed by more texts, each put on the clipboard after the previous one is pasted (for example a user name, then a password). A paste is the user typing ⌘V, which Snippad can only see with the Accessibility permission.",
                properties: [
                    "text": prop("string", "The text to put on the clipboard."),
                    "expires": durationProp,
                    "once": prop("boolean", "Remove from the clipboard after it is pasted once. With `then`, applies to the last text."),
                    "then": ["type": "array", "items": ["type": "string"],
                             "description": "Texts to put on the clipboard one after the other, each after the previous one is pasted."],
                    "name": prop("string", "A label shown in Snippad's menu while the text is on the clipboard."),
                ],
                required: ["text"]) { args in
            let first = try args.requiredString("text")
            let expires = try args.duration("expires")
            let once = args.bool("once") ?? false
            let then = args.raw["then"] as? [String] ?? []
            let name = args.string("name") ?? "From an agent"
            let chain = [first] + then
            // Built from the end: each step's `next` produces the following
            // step.
            var rules = PasteRules(expires: expires, once: once)
            for index in stride(from: chain.count - 1, to: 0, by: -1) {
                let value = chain[index]
                let stepName = "\(name) (\(index + 1)/\(chain.count))"
                let following = rules
                rules = PasteRules(expires: expires, once: false)
                rules.next = { ([NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)], stepName, following) }
            }
            PasteEngine.shared.put(first, name: chain.count > 1 ? "\(name) (1/\(chain.count))" : name, rules: rules)
            return [text(chain.count > 1 ? "The first of \(chain.count) texts is on the clipboard." : "The text is on the clipboard.")]
        },

        MCPTool(name: "clipboard_clear", title: "Empty the clipboard",
                description: "Empties the clipboard.",
                properties: [:], required: [], destructive: true) { _ in
            PasteEngine.shared.clear()
            return [text("The clipboard is empty.")]
        },

        MCPTool(name: "history_list", title: "List the clipboard history",
                description: "Lists what was copied, newest first, pinned items included. Each entry has an id for the other history tools, its kind (text, richText, image, files, url, color, other), a one-line title, when it was copied and from which app.",
                properties: [
                    "query": prop("string", "Only entries whose text, file paths, image metadata (EXIF), snippet name or source app contain this."),
                    "kind": prop("string", "Only entries of this kind."),
                    "list": prop("string", "Only entries of this list, by id or name (see lists_get)."),
                    "pinned_only": prop("boolean", "Only pinned entries."),
                    "limit": prop("integer", "At most this many entries; default 20."),
                    "offset": prop("integer", "Skip this many entries first; default 0."),
                ],
                required: [], readOnly: true) { args in
            let history = ClipboardHistory.shared
            var found = history.search(args.string("query") ?? "", list: try args.string("list").map(listID))
            if let kind = args.string("kind") { found = found.filter { $0.kind.rawValue == kind } }
            if args.bool("pinned_only") == true { found = found.filter(\.pinned) }
            let offset = max(0, args.int("offset") ?? 0)
            let limit = max(1, args.int("limit") ?? 20)
            let page = found.dropFirst(offset).prefix(limit).map(summary)
            return [json(["total": found.count, "recording": history.isCapturing, "items": Array(page)])]
        },

        MCPTool(name: "history_get", title: "Get a history entry",
                description: "The full content of one history entry: its text, file paths, or image.",
                properties: ["id": prop("string", "The entry's id from history_list.")],
                required: ["id"], readOnly: true) { args in
            guard let item = ClipboardHistory.shared.item(try args.id()) else { throw MCPToolError("No history entry has that id.") }
            return content(of: item)
        },

        MCPTool(name: "history_copy", title: "Copy a history entry",
                description: "Puts a history entry back on the clipboard, in all the formats it was copied in, and moves it to the top of the history.",
                properties: ["id": prop("string", "The entry's id from history_list.")],
                required: ["id"]) { args in
            let id = try args.id()
            guard let item = ClipboardHistory.shared.item(id) else { throw MCPToolError("No history entry has that id.") }
            if item.filesGone {
                throw MCPToolError("Its files no longer exist. history_copy_file_names can still copy their names or paths as text.")
            }
            ClipboardHistory.shared.copy(id)
            return [text("\u{201C}\(item.title)\u{201D} is on the clipboard.")]
        },

        MCPTool(name: "history_add", title: "Add text to the history",
                description: "Adds a text entry to the history without changing the clipboard.",
                properties: ["text": prop("string", "The text."),
                             "pinned": prop("boolean", "Pin it, so clearing the history keeps it.")],
                required: ["text"]) { args in
            var item = ClipItem.text(try args.requiredString("text"))
            item.sourceApp = "MCP"
            ClipboardHistory.shared.record(item)
            let id = ClipboardHistory.shared.items.first?.id ?? item.id
            if args.bool("pinned") == true { ClipboardHistory.shared.setPinned(id, true) }
            return [json(["id": id.uuidString])]
        },

        MCPTool(name: "history_pin", title: "Pin or unpin a history entry",
                description: "Pinned entries are listed first and survive clearing and trimming the history.",
                properties: ["id": prop("string", "The entry's id."),
                             "pinned": prop("boolean", "true to pin, false to unpin; default true.")],
                required: ["id"]) { args in
            let id = try args.id()
            guard ClipboardHistory.shared.item(id) != nil else { throw MCPToolError("No history entry has that id.") }
            let pinned = args.bool("pinned") ?? true
            ClipboardHistory.shared.setPinned(id, pinned)
            return [text(pinned ? "Pinned." : "Unpinned.")]
        },

        MCPTool(name: "history_delete", title: "Delete a history entry",
                description: "Deletes one entry from the history.",
                properties: ["id": prop("string", "The entry's id.")],
                required: ["id"], destructive: true) { args in
            let id = try args.id()
            guard ClipboardHistory.shared.item(id) != nil else { throw MCPToolError("No history entry has that id.") }
            ClipboardHistory.shared.delete(id)
            return [text("Deleted.")]
        },

        MCPTool(name: "history_clear", title: "Clear the history",
                description: "Deletes every history entry except pinned ones, or all of them with include_pinned.",
                properties: ["include_pinned": prop("boolean", "Delete pinned entries too; default false.")],
                required: [], destructive: true) { args in
            ClipboardHistory.shared.clear(includingPinned: args.bool("include_pinned") ?? false)
            return [text("The history is cleared.")]
        },

        MCPTool(name: "history_settings", title: "History settings",
                description: "Reads, and optionally changes, whether copies are recorded and how many unpinned entries are kept.",
                properties: ["recording": prop("boolean", "Record new copies (true) or pause (false)."),
                             "limit": prop("integer", "How many unpinned entries to keep.")],
                required: []) { args in
            let history = ClipboardHistory.shared
            if let recording = args.bool("recording") { history.isCapturing = recording }
            if let limit = args.int("limit") {
                guard limit > 0 else { throw MCPToolError("'limit' must be positive") }
                history.limit = limit
            }
            return [json(["recording": history.isCapturing, "limit": history.limit, "count": history.items.count])]
        },

        MCPTool(name: "snippad_files", title: "List .snippad files",
                description: "The open .snippad files: every one in ~/.snippad, and those opened from elsewhere.",
                properties: [:], required: [], readOnly: true) { _ in
            SnippadLibrary.shared.refreshFiles()
            return [json(SnippadLibrary.shared.files.map(\.path))]
        },

        MCPTool(name: "snippad_read", title: "Read a .snippad file",
                description: "The snippets of a .snippad file, in order, with their clipboard rules.",
                properties: ["path": prop("string", "Absolute path of the .snippad file (~ allowed).")],
                required: ["path"], readOnly: true) { args in
            [json(try readFile(try args.snippadURL()).map(dictionary))]
        },

        MCPTool(name: "snippad_write", title: "Write a .snippad file",
                description: "Replaces all snippets of a .snippad file, creating it if needed. The comment block at the top of the file is kept; other comments are not.",
                properties: ["path": prop("string", "Absolute path of the .snippad file (~ allowed)."),
                             "snippets": ["type": "array", "items": snippetSchema, "description": "The snippets, in order."]],
                required: ["path", "snippets"], destructive: true) { args in
            let url = try args.snippadURL()
            guard let raw = args.raw["snippets"] as? [Any] else { throw MCPToolError("'snippets' must be an array") }
            let old = (try? readFile(url)) ?? []
            let snippets = keepingPasswords(try raw.enumerated().map { try snippet(from: $1, index: $0) }, from: old)
            try writeFile(snippets, url)
            return [text("Wrote \(snippets.count) snippets to \(url.path).")]
        },

        MCPTool(name: "snippad_set_snippet", title: "Add or change a snippet",
                description: "Adds a snippet to a .snippad file, or changes the one with that name. Fields left out keep their value; to remove a rule pass expires: 0, once: false or next: \"\".",
                properties: [
                    "path": prop("string", "Absolute path of the .snippad file (~ allowed); created if missing."),
                    "name": prop("string", "The snippet's name."),
                    "new_name": prop("string", "Rename it to this; snippets chaining to it follow."),
                    "value": prop("string", "The text it copies; required for a new snippet."),
                    "expires": ["type": ["integer", "string"], "description": "Seconds or a duration like \"5m\"; 0 for never."],
                    "once": prop("boolean", "Remove from the clipboard after one paste."),
                    "next": prop("string", "Name of the snippet that follows it on the clipboard; \"\" for none."),
                    "password": prop("boolean", "Mark the value as a password."),
                    "list": prop("string", "The history list its copies go to, by name; \"\" for the default list."),
                    "kind": prop("string", "text, rich (value is RTF), file (value is a path) or image (value is base64 PNG)."),
                ],
                required: ["path", "name"]) { args in
            let url = try args.snippadURL()
            var snippets = FileManager.default.fileExists(atPath: url.path) ? try readFile(url) : []
            let name = try args.requiredString("name")
            let index: Int
            if let i = snippets.firstIndex(where: { $0.name == name }) {
                index = i
            } else {
                snippets.append(Snippet(id: snippets.count, name: name, value: try args.requiredString("value")))
                index = snippets.count - 1
            }
            var s = snippets[index]
            if let value = args.string("value"), value != ClipItem.mask, !(s.kind == .image && value.hasPrefix("(image, ")) {
                s = s.with(value: value)
            }
            if let k = args.string("kind") {
                guard let kind = SnippetKind(rawValue: k) else { throw MCPToolError("kind must be text, rich, file or image") }
                s.kind = kind
            }
            if let password = args.bool("password") { s.password = password }
            if let n = args.raw["expires"] as? NSNumber, n.intValue == 0 { s.expires = nil } else if let e = try args.duration("expires") { s.expires = e }
            if let once = args.bool("once") { s.once = once }
            if let next = args.string("next") { s.next = next.isEmpty ? nil : next }
            if let list = args.string("list") { s.list = list.isEmpty ? nil : list }
            if let newName = args.string("new_name"), newName != name {
                s = s.with(name: newName)
                for i in snippets.indices where snippets[i].next == name { snippets[i].next = newName }
            }
            snippets[index] = s
            try writeFile(snippets, url)
            return [json(dictionary(s))]
        },

        MCPTool(name: "snippad_delete_snippet", title: "Delete a snippet",
                description: "Removes the snippet with that name from a .snippad file. Chains pointing at it are removed too.",
                properties: ["path": prop("string", "Absolute path of the .snippad file (~ allowed)."),
                             "name": prop("string", "The snippet's name.")],
                required: ["path", "name"], destructive: true) { args in
            let url = try args.snippadURL()
            let name = try args.requiredString("name")
            var snippets = try readFile(url)
            guard snippets.contains(where: { $0.name == name }) else { throw MCPToolError("No snippet is named \u{201C}\(name)\u{201D}.") }
            snippets.removeAll { $0.name == name }
            for i in snippets.indices where snippets[i].next == name { snippets[i].next = nil }
            guard !snippets.isEmpty else { throw MCPToolError("That is the file's only snippet; a .snippad file needs at least one.") }
            try writeFile(snippets, url)
            return [text("Deleted \u{201C}\(name)\u{201D}.")]
        },

        MCPTool(name: "snippad_copy", title: "Copy a snippet",
                description: "Puts a snippet on the clipboard, with its rules: expiry, paste-once, and the chain to the next snippet.",
                properties: ["path": prop("string", "Absolute path of the .snippad file (~ allowed)."),
                             "name": prop("string", "The snippet's name.")],
                required: ["path", "name"]) { args in
            let snippets = try readFile(try args.snippadURL())
            let name = try args.requiredString("name")
            guard let s = snippets.first(where: { $0.name == name }) else { throw MCPToolError("No snippet is named \u{201C}\(name)\u{201D}.") }
            PasteEngine.shared.put(types: s.pasteboardTypes, name: s.name, rules: s.rules(in: snippets))
            return [text("\u{201C}\(name)\u{201D} is on the clipboard.")]
        },

        MCPTool(name: "snippad_open", title: "Show a .snippad file",
                description: "Opens a .snippad file in Snippad: in the Snippad Organizer's editor, or as its window of buttons.",
                properties: ["path": prop("string", "Absolute path of the .snippad file (~ allowed)."),
                             "editor": prop("boolean", "Open the editor instead of the buttons.")],
                required: ["path"]) { args in
            let url = try args.snippadURL()
            guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError("There is no file at \(url.path).") }
            if args.bool("editor") == true {
                SnippadLibrary.shared.show(url)
            } else {
                SnippadLibrary.shared.add(url)
                SnippadLibrary.shared.open(url)
            }
            return [text("Opened \(url.lastPathComponent).")]
        },

        MCPTool(name: "history_update_text", title: "Change a text entry",
                description: "Replaces the text of a text history entry, as editing it in the history window does. If the entry is what is on the clipboard, the clipboard changes too. Password entries cannot be changed here.",
                properties: ["id": prop("string", "The entry's id."), "text": prop("string", "The new text.")],
                required: ["id", "text"]) { args in
            let item = try existing(args)
            guard item.isEditableText, !item.isPassword else { throw MCPToolError("Only text entries that are not passwords can be changed.") }
            ClipboardHistory.shared.updateText(item.id, plain: try args.requiredString("text"))
            ClipboardHistory.shared.flush()
            return [text("Changed.")]
        },

        MCPTool(name: "history_move", title: "Move an entry to another list",
                description: "Moves a history entry to another list.",
                properties: ["id": prop("string", "The entry's id."), "list": prop("string", "The list's id or name.")],
                required: ["id", "list"]) { args in
            let item = try existing(args)
            let target = try listID(try args.requiredString("list"))
            ClipboardHistory.shared.move(item.id, toList: target)
            return [text("Moved to \u{201C}\(SettingsStore.shared.list(target).name)\u{201D}.")]
        },

        MCPTool(name: "history_copy_files", title: "Copy some of an entry's files",
                description: "From a history entry of copied files, makes a new entry with only the given files and puts it on the clipboard.",
                properties: ["id": prop("string", "The files entry's id."),
                             "paths": ["type": "array", "items": ["type": "string"], "description": "The paths to keep, from the entry's `files`."]],
                required: ["id", "paths"]) { args in
            let item = try existing(args)
            let paths = Set((args.raw["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            let keep = Set(item.fileURLs.filter { paths.contains($0.standardizedFileURL.path) })
            let made = try ClipboardHistory.shared.copyFiles(item.id, only: keep)
            return [json(summary(ClipboardHistory.shared.items.first { $0.digest == made.digest } ?? made))]
        },

        MCPTool(name: "history_copy_file_names", title: "Copy an entry's file names or paths as text",
                description: "Puts the names, or the full paths, of a files entry's files on the clipboard as text, one per line. Works even when the files no longer exist.",
                properties: ["id": prop("string", "The files entry's id."),
                             "paths": prop("boolean", "Full paths instead of names. Default false.")],
                required: ["id"]) { args in
            let item = try existing(args)
            let copied = try ClipboardHistory.shared.copyFileText(of: item.id, args.raw["paths"] as? Bool == true ? .paths : .names)
            return [text("On the clipboard:\n" + copied)]
        },

        MCPTool(name: "history_copy_file_contents", title: "Copy the contents of an entry's files",
                description: "Reads the files of a history entry of copied files and puts their contents on the clipboard: images as images, text as text, one new entry per file. Other kinds of files are reported as errors.",
                properties: ["id": prop("string", "The files entry's id."),
                             "paths": ["type": "array", "items": ["type": "string"], "description": "Only these of its files; default all."]],
                required: ["id"]) { args in
            let item = try existing(args)
            var urls = item.fileURLs
            if let paths = args.raw["paths"] as? [String] {
                let wanted = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                urls = urls.filter { wanted.contains($0.standardizedFileURL.path) }
            }
            guard !urls.isEmpty else { throw MCPToolError("The entry has none of those files.") }
            let made = try ClipboardHistory.shared.copyFileContents(urls, listID: item.listID)
            return [json(made.map(summary))]
        },

        MCPTool(name: "lists_get", title: "The history lists",
                description: "The lists the history is divided into, with their paste rules, and which list each application's copies go to.",
                properties: [:], required: [], readOnly: true) { _ in
            let s = SettingsStore.shared.value
            let lists: [[String: Any]] = s.lists.map { l in
                ["id": l.id, "name": l.name, "paste_into": l.guardMode.rawValue, "apps": l.guardApps,
                 "private_browsing_only": l.privateBrowsingOnly,
                 "entries": ClipboardHistory.shared.items.filter { $0.list == l.id }.count]
            }
            return [json(["lists": lists, "app_lists": s.appLists, "private_browsing_list": s.privateBrowsingList ?? NSNull(),
                          "paste_guard_enabled": s.pasteGuardEnabled, "excluded_apps": s.excludedApps])]
        },

        MCPTool(name: "lists_create", title: "Create a history list",
                description: "Adds a list to the history.",
                properties: ["name": prop("string", "The list's name.")],
                required: ["name"]) { args in
            let list = SettingsStore.shared.addList(named: try args.requiredString("name"))
            return [json(["id": list.id, "name": list.name])]
        },

        MCPTool(name: "lists_delete", title: "Delete a history list",
                description: "Deletes a list. Its entries move to another list, or are deleted. The first list (Clipboard) cannot be deleted.",
                properties: ["list": prop("string", "The list, by id or name."),
                             "move_to": prop("string", "Where its entries go, by id or name. Leave out to delete them.")],
                required: ["list"], destructive: true) { args in
            let id = try listID(try args.requiredString("list"))
            guard id != ClipList.defaultID else { throw MCPToolError("The first list cannot be deleted.") }
            let target = try args.string("move_to").map(listID)
            guard target != id else { throw MCPToolError("move_to is the list being deleted.") }
            ClipboardHistory.shared.removeList(id, moveTo: target)
            return [text("Deleted.")]
        },

        MCPTool(name: "history_extract_text", title: "Read the text in an image entry",
                description: "Reads the text, and the contents of QR codes, in an image entry (or the image files of a files entry), on the Mac with Vision. The text becomes a new entry in the same list and goes on the clipboard.",
                properties: ["id": prop("string", "The image entry's id.")],
                required: ["id"]) { args in
            let made = try ClipboardHistory.shared.extractTextNow(from: try existing(args).id)
            return [json(made.map(summary) ?? [:]), text(made?.string ?? "")]
        },

        MCPTool(name: "apps_list", title: "Known applications",
                description: "The installed applications and those copies came from, with how many copies each made, whether their copies are recorded, and their list.",
                properties: ["copied_from_only": prop("boolean", "Only apps something was copied from.")],
                required: [], readOnly: true) { args in
            let store = SettingsStore.shared
            let only = args.bool("copied_from_only") ?? false
            let apps: [[String: Any]] = AppCatalog.shared.sorted.filter { !only || ($0.copies ?? 0) > 0 }.map { a in
                ["bundle_id": a.bundleID, "name": a.name, "copies": a.copies ?? 0, "recorded": !store.isExcluded(a.bundleID),
                 "list": store.listID(for: a.bundleID), "installed": a.installed ?? false,
                 "missing": a.missing ?? false]
            }
            return [json(apps)]
        },
    ]
}
