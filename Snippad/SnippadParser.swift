import Foundation

/// What a snippet's value is.
enum SnippetKind: String, CaseIterable, Sendable {
    /// Plain text, edited in Snippad.
    case text
    /// Formatted text: the value is RTF.
    case rich
    /// A reference to a file: the value is its path; the file goes on the
    /// clipboard as Finder copies it.
    case file
    /// An image: the value is the PNG, base64-encoded.
    case image
}

/// One button on the board: what it is labelled and what it copies, and what
/// happens to the clipboard afterwards.
struct Snippet: Identifiable, Equatable, Sendable {
    /// Position in the file, so two snippets with the same name stay distinct.
    let id: Int
    let name: String
    let value: String
    /// Seconds after which the value is taken off the clipboard again, if it
    /// is still there.
    var expires: Int? = nil
    /// Taken off the clipboard as soon as an app has pasted it once.
    var once: Bool = false
    /// The name of the snippet put on the clipboard once this one is pasted:
    /// user name first, then the password.
    var next: String? = nil
    /// The value is a password: hidden in the editor, shown as dots in the
    /// history, concealed from other clipboard managers.
    var password: Bool = false
    /// The name of the history list the copied value goes to; nil is the
    /// default list (Clipboard).
    var list: String? = nil
    var kind: SnippetKind = .text
}

extension Snippet {
    func with(name: String? = nil, value: String? = nil) -> Snippet {
        Snippet(id: id, name: name ?? self.name, value: value ?? self.value,
                expires: expires, once: once, next: next, password: password, list: list, kind: kind)
    }

    func with(id: Int) -> Snippet {
        Snippet(id: id, name: name, value: value, expires: expires, once: once, next: next, password: password, list: list, kind: kind)
    }
}

struct SnippadParseError: LocalizedError, Equatable {
    /// 1-based; 0 when the problem is the file as a whole.
    let line: Int
    let message: String

    var errorDescription: String? {
        line > 0 ? "Line \(line): \(message)" : message
    }
}

/// Reads a .snippad file: TOML with one `[[snippet]]` table per button, each
/// holding a `name` and a `value` string, and optionally `expires`, `once`
/// and `next`.
///
/// Not a general TOML parser -- only the part of TOML these files use: tables,
/// arrays of tables, comments, and keys whose values are strings in any of the
/// four TOML spellings (basic, literal, and their multi-line forms), decimal
/// integers, or booleans. Anything else is reported with its line number
/// rather than guessed at. Other keys inside a snippet, and tables other than
/// `[[snippet]]`, are skipped, so a file can carry extra fields without
/// breaking.
enum SnippadParser {

    static func parse(_ text: String) throws -> [Snippet] {
        var reader = Reader(text)
        return try reader.parseDocument()
    }
}

private struct Reader {
    private let s: [Unicode.Scalar]
    private var i = 0
    private var line = 1

    init(_ text: String) {
        // CRLF folded to LF up front, so nothing below has to think about \r.
        s = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
    }

    // MARK: - Document

    mutating func parseDocument() throws -> [Snippet] {
        var tables: [(line: Int, fields: [String: (line: Int, value: Value)])] = []
        var inSnippet = false

        while true {
            while let c = peek(), c == " " || c == "\t" || c == "\n" { advance() }
            guard let c = peek() else { break }

            if c == "#" {
                skipComment()
            } else if c == "[" {
                let headerLine = line
                let isArray = peek(1) == "["
                i += isArray ? 2 : 1
                skipBlanks()
                let name = try parseKey()
                skipBlanks()
                for _ in 0..<(isArray ? 2 : 1) {
                    guard peek() == "]" else { throw fail("expected ']' to close the table header") }
                    i += 1
                }
                try expectLineEnd()
                if name == "snippet" && !isArray {
                    throw SnippadParseError(line: headerLine,
                                            message: "write [[snippet]], with double brackets, for each snippet")
                }
                inSnippet = isArray && name == "snippet"
                if inSnippet { tables.append((headerLine, [:])) }
            } else {
                let keyLine = line
                let key = try parseKey()
                skipBlanks()
                guard peek() == "=" else { throw fail("expected '=' after '\(key)'") }
                i += 1
                skipBlanks()
                let value = try parseValue(for: key)
                try expectLineEnd()
                if inSnippet {
                    let last = tables.count - 1
                    guard tables[last].fields[key] == nil else {
                        throw SnippadParseError(line: keyLine, message: "'\(key)' is set twice in this snippet")
                    }
                    tables[last].fields[key] = (keyLine, value)
                }
            }
        }

        guard !tables.isEmpty else {
            throw SnippadParseError(line: 0, message: "The file has no [[snippet]] sections.")
        }
        let snippets = try tables.enumerated().map { index, table in
            let fields = table.fields
            func string(_ key: String) throws -> String? {
                guard let field = fields[key] else { return nil }
                guard case .string(let s) = field.value else {
                    throw SnippadParseError(line: field.line, message: "'\(key)' must be a string")
                }
                return s
            }
            guard let name = try string("name") else {
                throw SnippadParseError(line: table.line, message: "this [[snippet]] has no name")
            }
            guard let value = try string("value") else {
                throw SnippadParseError(line: table.line, message: "this [[snippet]] has no value")
            }
            var snippet = Snippet(id: index, name: name, value: value)
            snippet.next = try string("next")
            snippet.list = try string("list").flatMap { $0.isEmpty ? nil : $0 }
            if let k = try string("kind") {
                guard let kind = SnippetKind(rawValue: k) else {
                    throw SnippadParseError(line: fields["kind"]!.line,
                                            message: "'kind' must be \"text\", \"rich\", \"file\" or \"image\"")
                }
                snippet.kind = kind
                if kind == .image, Data(base64Encoded: value, options: .ignoreUnknownCharacters) == nil {
                    throw SnippadParseError(line: fields["value"]!.line, message: "the value of an image snippet must be base64")
                }
            }
            for key in ["once", "password"] {
                guard let field = fields[key] else { continue }
                guard case .bool(let b) = field.value else {
                    throw SnippadParseError(line: field.line, message: "'\(key)' must be true or false")
                }
                if key == "once" { snippet.once = b } else { snippet.password = b }
            }
            if let field = fields["expires"] {
                let seconds: Int?
                switch field.value {
                case .integer(let n): seconds = n
                case .string(let s): seconds = SnippetDuration.seconds(from: s)
                case .bool: seconds = nil
                }
                guard let seconds, seconds > 0 else {
                    throw SnippadParseError(line: field.line,
                                            message: "'expires' must be a number of seconds or a duration such as \"30s\", \"5m\" or \"1h30m\"")
                }
                snippet.expires = seconds
            }
            return (snippet, nextLine: fields["next"]?.line ?? table.line)
        }

        let names = Set(snippets.map(\.0.name))
        for (snippet, line) in snippets {
            if let next = snippet.next, !names.contains(next) {
                throw SnippadParseError(line: line, message: "there is no snippet named '\(next)' to chain to")
            }
        }
        return snippets.map(\.0)
    }

    // MARK: - Keys

    private mutating func parseKey() throws -> String {
        let key: String
        switch peek() {
        case "\"":
            i += 1
            key = try singleLineString(quote: "\"", escapes: true)
        case "'":
            i += 1
            key = try singleLineString(quote: "'", escapes: false)
        default:
            var out = String.UnicodeScalarView()
            while let c = peek(), c.isBareKeyCharacter {
                out.append(c)
                i += 1
            }
            guard !out.isEmpty else {
                throw fail(peek().map { "unexpected '\($0)'" } ?? "unexpected end of file")
            }
            key = String(out)
        }
        skipBlanks()
        if peek() == "." { throw fail("dotted keys are not supported") }
        return key
    }

    // MARK: - Values

    enum Value {
        case string(String)
        case integer(Int)
        case bool(Bool)
    }

    private mutating func parseValue(for key: String) throws -> Value {
        switch peek() {
        case "\"", "'":
            return .string(try parseString(for: key))
        case "t", "f":
            var word = String.UnicodeScalarView()
            while let c = peek(), c.isBareKeyCharacter { word.append(c); i += 1 }
            switch String(word) {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw fail("the value of '\(key)' must be a string, a whole number, true or false")
            }
        case let c? where c == "+" || c == "-" || ("0"..."9").contains(c):
            var digits = String.UnicodeScalarView()
            if c == "+" || c == "-" { digits.append(c); i += 1 }
            while let d = peek(), ("0"..."9").contains(d) || d == "_" {
                if d != "_" { digits.append(d) }
                i += 1
            }
            if let n = Int(String(digits)), peek().map({ !$0.isBareKeyCharacter && $0 != "." }) ?? true {
                return .integer(n)
            }
            throw fail("the value of '\(key)' must be a string, a whole number, true or false")
        default:
            throw fail("the value of '\(key)' must be a string, a whole number, true or false")
        }
    }

    // MARK: - Strings

    private mutating func parseString(for key: String) throws -> String {
        guard let quote = peek(), quote == "\"" || quote == "'" else {
            throw fail("the value of '\(key)' must be a string")
        }
        let escapes = quote == "\""
        if peek(1) == quote && peek(2) == quote {
            i += 3
            return try multiLineString(quote: quote, escapes: escapes)
        }
        i += 1
        return try singleLineString(quote: quote, escapes: escapes)
    }

    private mutating func singleLineString(quote: Unicode.Scalar, escapes: Bool) throws -> String {
        var out = String.UnicodeScalarView()
        while let c = peek(), c != "\n" {
            if c == quote {
                i += 1
                return String(out)
            }
            if escapes && c == "\\" {
                out.append(try escape())
            } else {
                out.append(c)
                i += 1
            }
        }
        throw fail("the string is not closed on this line")
    }

    private mutating func multiLineString(quote: Unicode.Scalar, escapes: Bool) throws -> String {
        let startLine = line
        // A newline straight after the opening delimiter is not content.
        if peek() == "\n" { advance() }

        var out = String.UnicodeScalarView()
        while let c = peek() {
            if c == quote && peek(1) == quote && peek(2) == quote {
                i += 3
                // Up to two more quotes right before the closing three are
                // content: `"""a"""""` is a followed by two quotes.
                var extra = 0
                while extra < 2, peek() == quote {
                    out.append(quote)
                    i += 1
                    extra += 1
                }
                return String(out)
            }
            if escapes && c == "\\" {
                if backslashEndsLine() {
                    // Line-ending backslash: drop it and all whitespace,
                    // newlines included, up to the next visible character.
                    i += 1
                    while let w = peek(), w == " " || w == "\t" || w == "\n" { advance() }
                } else {
                    out.append(try escape())
                }
                continue
            }
            out.append(c)
            advance()
        }
        throw SnippadParseError(line: startLine, message: "the multi-line string is never closed")
    }

    /// Whether the backslash at `i` is followed only by blanks up to the end
    /// of its line.
    private func backslashEndsLine() -> Bool {
        var j = i + 1
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        return j < s.count && s[j] == "\n"
    }

    private mutating func escape() throws -> Unicode.Scalar {
        i += 1
        guard let c = peek(), c != "\n" else { throw fail("a backslash ends the string") }
        i += 1
        switch c {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try hexScalar(digits: 4)
        case "U": return try hexScalar(digits: 8)
        default: throw fail("'\\\(c)' is not a valid escape")
        }
    }

    private mutating func hexScalar(digits: Int) throws -> Unicode.Scalar {
        guard i + digits <= s.count else { throw fail("the unicode escape is cut short") }
        let hex = s[i..<i + digits]
        guard hex.allSatisfy(\.properties.isASCIIHexDigit),
              let code = UInt32(String(String.UnicodeScalarView(hex)), radix: 16),
              let scalar = Unicode.Scalar(code) else {
            throw fail("the unicode escape is not a valid character")
        }
        i += digits
        return scalar
    }

    // MARK: - Low level

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        i + offset < s.count ? s[i + offset] : nil
    }

    private mutating func advance() {
        if s[i] == "\n" { line += 1 }
        i += 1
    }

    private mutating func skipBlanks() {
        while let c = peek(), c == " " || c == "\t" { i += 1 }
    }

    private mutating func skipComment() {
        guard peek() == "#" else { return }
        while let c = peek(), c != "\n" { i += 1 }
    }

    /// After a value or a table header only blanks and a comment may follow.
    private mutating func expectLineEnd() throws {
        skipBlanks()
        skipComment()
        guard let c = peek() else { return }
        guard c == "\n" else { throw fail("unexpected '\(c)' after the value") }
        advance()
    }

    private func fail(_ message: String) -> SnippadParseError {
        SnippadParseError(line: line, message: message)
    }
}

private extension Unicode.Scalar {
    var isBareKeyCharacter: Bool {
        switch self {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
    }
}

/// Durations as the files write them: "45s", "5m", "1h30m", "2d". A bare
/// number is seconds.
enum SnippetDuration {

    static func seconds(from text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(t) { return n }
        var total = 0
        var number = ""
        for c in t where c != " " {
            if c.isASCII && c.isNumber {
                number.append(c)
                continue
            }
            let unit: Int
            switch c {
            case "s": unit = 1
            case "m": unit = 60
            case "h": unit = 3600
            case "d": unit = 86400
            default: return nil
            }
            guard let n = Int(number) else { return nil }
            total += n * unit
            number = ""
        }
        return number.isEmpty && total > 0 ? total : nil
    }

    /// The shortest spelling, as the editor writes it: 90 -> "1m30s".
    static func text(_ seconds: Int) -> String {
        var rest = seconds
        var out = ""
        for (unit, letter) in [(86400, "d"), (3600, "h"), (60, "m"), (1, "s")] where rest >= unit {
            out += "\(rest / unit)\(letter)"
            rest %= unit
        }
        return out.isEmpty ? "0s" : out
    }
}
