import Foundation

/// One button on the board: what it is labelled and what it copies.
struct Snippet: Identifiable, Equatable, Sendable {
    /// Position in the file, so two snippets with the same name stay distinct.
    let id: Int
    let name: String
    let value: String
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
/// holding a `name` and a `value` string.
///
/// Not a general TOML parser -- only the part of TOML these files use: tables,
/// arrays of tables, comments, and keys whose values are strings in any of the
/// four TOML spellings (basic, literal, and their multi-line forms). Anything
/// else is reported with its line number rather than guessed at. Keys inside a
/// snippet other than `name` and `value`, and tables other than `[[snippet]]`,
/// are skipped, so a file can carry extra string fields without breaking.
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
        var tables: [(line: Int, fields: [String: String])] = []
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
                let value = try parseString(for: key)
                try expectLineEnd()
                if inSnippet {
                    let last = tables.count - 1
                    guard tables[last].fields[key] == nil else {
                        throw SnippadParseError(line: keyLine, message: "'\(key)' is set twice in this snippet")
                    }
                    tables[last].fields[key] = value
                }
            }
        }

        guard !tables.isEmpty else {
            throw SnippadParseError(line: 0, message: "The file has no [[snippet]] sections.")
        }
        return try tables.enumerated().map { index, table in
            guard let name = table.fields["name"] else {
                throw SnippadParseError(line: table.line, message: "this [[snippet]] has no name")
            }
            guard let value = table.fields["value"] else {
                throw SnippadParseError(line: table.line, message: "this [[snippet]] has no value")
            }
            return Snippet(id: index, name: name, value: value)
        }
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
