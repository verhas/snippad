import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Writes the entries of a list -- or of all lists -- to a file as TOML, XML,
/// JSON or YAML.
///
/// Each entry has its date, list, kind, source application, pinned state and
/// label, and its content: the text, the file paths, or a PNG image in
/// base64. Rich text is exported with its plain text and its RTF. Password
/// values are never written: such an entry has `password = true` and no
/// value.
enum ListExport {
    enum Format: String, CaseIterable, Identifiable {
        case toml, xml, json, yaml
        var id: Self { self }
        var title: String { rawValue.uppercased() }
        var fileExtension: String { rawValue }
        var contentType: UTType {
            switch self {
            case .toml: UTType(filenameExtension: "toml") ?? .plainText
            case .xml: .xml
            case .json: .json
            case .yaml: .yaml
            }
        }
    }

    /// One exported entry: an ordered list of fields.
    struct Record {
        var fields: [(key: String, value: Value)]
    }

    enum Value {
        case string(String)
        case bool(Bool)
        case strings([String])
    }

    @MainActor
    static func records(_ items: [ClipItem], settings: SettingsStore) -> [Record] {
        let iso = ISO8601DateFormatter()
        return items.map { item in
            var f: [(String, Value)] = [
                ("date", .string(iso.string(from: item.date))),
                ("list", .string(settings.list(item.list).name)),
                ("kind", .string(item.kind.rawValue)),
            ]
            if let app = item.sourceApp { f.append(("source_app", .string(app))) }
            if item.pinned { f.append(("pinned", .bool(true))) }
            if let label = item.label { f.append(("label", .string(label))) }
            if item.isPassword {
                f.append(("password", .bool(true)))
            } else {
                switch item.kind {
                case .files:
                    f.append(("files", .strings(item.fileURLs.map(\.path))))
                case .image:
                    if let png = item.pngData { f.append(("image_png_base64", .string(png.base64EncodedString()))) }
                default:
                    if let s = item.string { f.append(("text", .string(s))) }
                    if item.kind == .richText, let rich = item.attributedString,
                       let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]),
                       let rtfText = String(data: rtf, encoding: .utf8) {
                        f.append(("rtf", .string(rtfText)))
                    }
                }
                if let m = item.metadata { f.append(("image_metadata", .string(m))) }
            }
            return Record(fields: f)
        }
    }

    static func text(_ records: [Record], as format: Format, listName: String) -> String {
        switch format {
        case .toml: toml(records, listName)
        case .xml: xml(records, listName)
        case .json: json(records, listName)
        case .yaml: yaml(records, listName)
        }
    }

    // MARK: - The formats

    private static func toml(_ records: [Record], _ name: String) -> String {
        var out = "# Snippad export of \(name)\n"
        for r in records {
            out += "\n[[entry]]\n"
            for (k, v) in r.fields {
                switch v {
                case .string(let s): out += "\(k) = \(SnippadWriter.quoted(s))\n"
                case .bool(let b): out += "\(k) = \(b)\n"
                case .strings(let a): out += "\(k) = [" + a.map(SnippadWriter.quoted).joined(separator: ", ") + "]\n"
                }
            }
        }
        return out
    }

    private static func xmlEscaped(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\t", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20: out += "&#x\(String(scalar.value, radix: 16));"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func xml(_ records: [Record], _ name: String) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<snippad-export list=\"\(xmlEscaped(name))\">\n"
        for r in records {
            out += "  <entry>\n"
            for (k, v) in r.fields {
                switch v {
                case .string(let s): out += "    <\(k)>\(xmlEscaped(s))</\(k)>\n"
                case .bool(let b): out += "    <\(k)>\(b)</\(k)>\n"
                case .strings(let a):
                    out += "    <\(k)>\n" + a.map { "      <file>\(xmlEscaped($0))</file>\n" }.joined() + "    </\(k)>\n"
                }
            }
            out += "  </entry>\n"
        }
        return out + "</snippad-export>\n"
    }

    private static func jsonObject(_ r: Record) -> [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in r.fields {
            switch v {
            case .string(let s): o[k] = s
            case .bool(let b): o[k] = b
            case .strings(let a): o[k] = a
            }
        }
        return o
    }

    private static func json(_ records: [Record], _ name: String) -> String {
        let root: [String: Any] = ["list": name, "entries": records.map(jsonObject)]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    /// A YAML string: JSON's double-quoted form, which YAML reads as is.
    private static func yamlString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func yaml(_ records: [Record], _ name: String) -> String {
        var out = "# Snippad export\nlist: \(yamlString(name))\nentries:\n"
        if records.isEmpty { return out.replacingOccurrences(of: "entries:\n", with: "entries: []\n") }
        for r in records {
            var first = true
            for (k, v) in r.fields {
                out += first ? "  - " : "    "
                first = false
                switch v {
                case .string(let s): out += "\(k): \(yamlString(s))\n"
                case .bool(let b): out += "\(k): \(b)\n"
                case .strings(let a): out += "\(k):\n" + a.map { "      - \(yamlString($0))\n" }.joined()
                }
            }
        }
        return out
    }

    /// Asks where, then writes the file.
    @MainActor
    static func export(listID: String?, as format: Format) {
        let settings = SettingsStore.shared
        let name = listID.map { settings.list($0).name } ?? "All Lists"
        let items = ClipboardHistory.shared.items.filter { listID == nil || $0.list == listID }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.message = "Export the \(items.count) entries of \u{201C}\(name)\u{201D} as \(format.title). Password values are not exported."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text(records(items, settings: settings), as: format, listName: name).utf8).write(to: url, options: .atomic)
        } catch {
            presentError(error, title: "The list could not be exported")
        }
    }
}

/// "Export ▸ TOML / XML / JSON / YAML" for a list's context menu.
struct ExportMenu: View {
    let listID: String?

    var body: some View {
        Menu("Export") {
            ForEach(ListExport.Format.allCases) { format in
                Button("\(format.title)…") { ListExport.export(listID: listID, as: format) }
            }
        }
    }
}
