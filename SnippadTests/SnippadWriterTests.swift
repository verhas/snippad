import AppKit
import XCTest
@testable import Snippad

final class SnippadWriterTests: XCTestCase {

    func testRulesParse() throws {
        let s = try SnippadParser.parse("""
            [[snippet]]
            name = "user"
            value = "me"
            next = "password"
            expires = 30

            [[snippet]]
            name = "password"
            value = "secret"
            once = true
            expires = "1h30m"
            password = true
            """)
        XCTAssertEqual(s[0], Snippet(id: 0, name: "user", value: "me", expires: 30, next: "password"))
        XCTAssertEqual(s[1], Snippet(id: 1, name: "password", value: "secret", expires: 5400, once: true, password: true))
    }

    func testRuleErrors() {
        func fails(_ text: String, line: Int, _ message: String? = nil, file: StaticString = #filePath, l: UInt = #line) {
            XCTAssertThrowsError(try SnippadParser.parse(text), file: file, line: l) { error in
                let e = error as? SnippadParseError
                XCTAssertEqual(e?.line, line, "\(error)", file: file, line: l)
                if let message { XCTAssertEqual(e?.message, message, file: file, line: l) }
            }
        }
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nnext = \"nope\"", line: 4, "there is no snippet named 'nope' to chain to")
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nonce = \"yes\"", line: 4)
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\npassword = 1", line: 4)
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nexpires = \"soon\"", line: 4)
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nexpires = 0", line: 4)
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nexpires = 1.5", line: 4)
        fails("[[snippet]]\nname = true\nvalue = \"b\"", line: 2)
        fails("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nx = [1]", line: 4)
    }

    func testDurations() {
        XCTAssertEqual(SnippetDuration.seconds(from: "45"), 45)
        XCTAssertEqual(SnippetDuration.seconds(from: "45s"), 45)
        XCTAssertEqual(SnippetDuration.seconds(from: "5m"), 300)
        XCTAssertEqual(SnippetDuration.seconds(from: "1h 30m"), 5400)
        XCTAssertEqual(SnippetDuration.seconds(from: "2d"), 172_800)
        XCTAssertNil(SnippetDuration.seconds(from: "5x"))
        XCTAssertNil(SnippetDuration.seconds(from: "m"))
        XCTAssertNil(SnippetDuration.seconds(from: "5m3"))
        XCTAssertEqual(SnippetDuration.text(90), "1m30s")
        XCTAssertEqual(SnippetDuration.text(3600), "1h")
        for n in [1, 59, 61, 3599, 3601, 86_401, 100_000] {
            XCTAssertEqual(SnippetDuration.seconds(from: SnippetDuration.text(n)), n)
        }
    }

    func testRoundTrip() throws {
        let tricky = [
            "plain", "", "with \"quotes\" and \\ backslash", "tab\there", "line\nbreak",
            "\nstarts with a break", "ends with quotes\"\"\"", "\"\"\"", "trailing \\\n", "cr\r\nlf",
            "control \u{01}\u{7F}", "unicode é 😀", "'''", "a\n\n\nb\n",
        ]
        var snippets = tricky.enumerated().map { Snippet(id: $0, name: "n\($0) \($1.prefix(3))", value: $1) }
        snippets[0].expires = 90
        snippets[1].once = true
        snippets[2].next = snippets[3].name
        snippets[4].password = true
        let text = SnippadWriter.text(for: snippets, header: "# top\n")
        XCTAssertTrue(text.hasPrefix("# top\n\n[[snippet]]"))
        XCTAssertEqual(try SnippadParser.parse(text), snippets)
    }

    func testHeaderKeepsOnlyTheLeadingComments() {
        XCTAssertEqual(SnippadWriter.header(of: "# a\n\n# b\n\n[[snippet]]\n# c\n"), "# a\n\n# b\n")
        XCTAssertEqual(SnippadWriter.header(of: "[[snippet]]\n"), "")
    }

    func testSaveKeepsHeaderAndRefusesNothing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID()).snippad")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# mine\n[[snippet]]\nname = \"a\"\nvalue = \"b\"\nnote = \"dropped\"\n".write(to: url, atomically: true, encoding: .utf8)
        try SnippadWriter.save([Snippet(id: 0, name: "x", value: "y", once: true)], to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "# mine\n\n[[snippet]]\nname = \"x\"\nvalue = \"y\"\nonce = true\n")
        XCTAssertThrowsError(try SnippadWriter.save([], to: url))
    }

    func testExampleFileRoundTrips() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("example.snippad")
        let snippets = try SnippadParser.parse(String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(try SnippadParser.parse(SnippadWriter.text(for: snippets)), snippets)
    }

    func testListOfASnippetRoundTrips() throws {
        let snippets = [Snippet(id: 0, name: "Key", value: "k", password: true, list: "Work"),
                        Snippet(id: 1, name: "Plain", value: "p")]
        let text = SnippadWriter.text(for: snippets)
        XCTAssertTrue(text.contains("list = \"Work\""))
        XCTAssertEqual(try SnippadParser.parse(text), snippets)
    }

    func testTextTransformsWorkLineByLine() {
        XCTAssertEqual(TextTransform.stripLeading.apply("  a\n\tb \n"), "a\nb \n")
        XCTAssertEqual(TextTransform.stripTrailing.apply("  a  \nb\t"), "  a\nb")
        XCTAssertEqual(TextTransform.trim.apply(" a \n  b  "), "a\nb")
        XCTAssertEqual(TextTransform.uppercase.apply("aBc"), "ABC")
        XCTAssertEqual(TextTransform.lowercase.apply("aBc"), "abc")
        XCTAssertEqual(TextTransform.removeEmptyLines.apply("a\n\n  \nb\n"), "a\nb\n")
    }

    func testSnippetKindsRoundTripAndGoOnTheClipboard() throws {
        let rich = NSAttributedString(string: "Hi", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try XCTUnwrap(String(data: rich.rtf(from: NSRange(location: 0, length: 2), documentAttributes: [:])!, encoding: .utf8))
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        let snippets = [
            Snippet(id: 0, name: "Rich", value: rtf, kind: .rich),
            Snippet(id: 1, name: "File", value: "/etc/hosts", kind: .file),
            Snippet(id: 2, name: "Image", value: png.base64EncodedString(), kind: .image),
            Snippet(id: 3, name: "Text", value: "plain"),
        ]
        let text = SnippadWriter.text(for: snippets)
        XCTAssertTrue(text.contains("kind = \"image\""))
        XCTAssertEqual(try SnippadParser.parse(text), snippets)

        let t = NSPasteboard.PasteboardType.self
        XCTAssertEqual(snippets[0].pasteboardTypes[t.string.rawValue].flatMap { String(data: $0, encoding: .utf8) }, "Hi")
        XCTAssertNotNil(snippets[0].pasteboardTypes[t.rtf.rawValue])
        XCTAssertEqual(snippets[1].pasteboardTypes[t.fileURL.rawValue].flatMap { String(data: $0, encoding: .utf8) }, "file:///etc/hosts")
        XCTAssertEqual(snippets[2].pasteboardTypes[t.png.rawValue], png)
        XCTAssertEqual(snippets[0].preview, "Hi")

        XCTAssertThrowsError(try SnippadParser.parse("[[snippet]]\nname = \"x\"\nvalue = \"y\"\nkind = \"video\"\n"))
    }

    func testShortcutsParseShowAndRoundTrip() throws {
        let k = try XCTUnwrap(KeyShortcut("Cmd+Ctrl+K"))
        XCTAssertEqual(k.text, "ctrl+cmd+k")
        XCTAssertEqual(k.display, "⌃⌘K")
        XCTAssertTrue(k.isUsable)
        XCTAssertFalse(try XCTUnwrap(KeyShortcut("shift+a")).isUsable, "a plain letter would eat typing")
        XCTAssertTrue(try XCTUnwrap(KeyShortcut("f5")).isUsable)
        XCTAssertNil(KeyShortcut("hyper+k"))
        XCTAssertNil(KeyShortcut("ctrl+"))

        let snippets = [Snippet(id: 0, name: "Sig", value: "Regards", shortcut: "ctrl+opt+s")]
        let text = SnippadWriter.text(for: snippets)
        XCTAssertTrue(text.contains("shortcut = \"ctrl+opt+s\""))
        XCTAssertEqual(try SnippadParser.parse(text), snippets)
        XCTAssertEqual(try SnippadParser.parse("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nshortcut = \"opt+cmd+1\"\n")[0].shortcut,
                       "opt+cmd+1", "written in the canonical order")
        XCTAssertThrowsError(try SnippadParser.parse("[[snippet]]\nname = \"a\"\nvalue = \"b\"\nshortcut = \"k\"\n"))
    }
}
