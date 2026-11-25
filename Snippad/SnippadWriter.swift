import Foundation

/// Writes snippets back as a .snippad file that SnippadParser reads to the
/// same snippets.
///
/// The file is regenerated, not patched: only the comment block at the top of
/// the old file survives; other comments and keys Snippad does not know are
/// dropped.
enum SnippadWriter {

    static func text(for snippets: [Snippet], header: String = "") -> String {
        var out = header
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        for snippet in snippets {
            if !out.isEmpty { out += "\n" }
            out += "[[snippet]]\n"
            out += "name = \(quoted(snippet.name))\n"
            if snippet.kind != .text {
                out += "kind = \(quoted(snippet.kind.rawValue))\n"
            }
            out += "value = \(quoted(snippet.value))\n"
            if let expires = snippet.expires {
                out += "expires = \(quoted(SnippetDuration.text(expires)))\n"
            }
            if snippet.once {
                out += "once = true\n"
            }
            if snippet.password {
                out += "password = true\n"
            }
            if let next = snippet.next {
                out += "next = \(quoted(next))\n"
            }
            if let list = snippet.list {
                out += "list = \(quoted(list))\n"
            }
            if let classification = snippet.classification {
                out += "classification = \(quoted(classification.rawValue))\n"
            }
            if let shortcut = snippet.shortcut {
                out += "shortcut = \(quoted(shortcut))\n"
            }
            if let color = snippet.color {
                out += "color = \(quoted(color))\n"
            }
            if let icon = snippet.icon {
                out += "icon = \(quoted(icon))\n"
                if snippet.iconCorner != .topTrailing {
                    out += "icon_corner = \(quoted(snippet.iconCorner.rawValue))\n"
                }
            }
            if let origin = snippet.origin {
                out += "x = \(origin.x)\ny = \(origin.y)\n"
            }
            if let size = snippet.size {
                out += "width = \(size.width)\nheight = \(size.height)\n"
            }
            // The original image and what was added to it, so the edits stay
            // changeable; the value above is the result.
            if snippet.kind == .image, let edits = snippet.edits {
                out += "edits = \(quoted(edits.json))\n"
            }
        }
        return out
    }

    /// The comment lines (and blank lines between them) at the top of a file,
    /// kept when the editor saves it.
    static func header(of text: String) -> String {
        var lines: [Substring] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
            lines.append(line)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// A basic string, or a multi-line basic string when the text has line
    /// breaks, so the file stays readable.
    static func quoted(_ s: String) -> String {
        guard s.contains("\n") else { return "\"" + escaped(s, keepNewlines: false) + "\"" }
        // The line break right after the opening quotes is dropped by the
        // reader, so a value starting with a line break keeps it.
        return "\"\"\"\n" + escaped(s, keepNewlines: true) + "\"\"\""
    }

    private static func escaped(_ s: String, keepNewlines: Bool) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += keepNewlines ? "\n" : "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Writes the file, keeping the comment block at the top of what was
    /// there before.
    static func save(_ snippets: [Snippet], to url: URL) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let text = text(for: snippets, header: header(of: old))
        // Read back before writing, so a bug here can never leave a file
        // Snippad itself cannot open.
        _ = try SnippadParser.parse(text)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
