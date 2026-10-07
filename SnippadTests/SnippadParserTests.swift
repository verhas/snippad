import XCTest
@testable import Snippad

final class SnippadParserTests: XCTestCase {

    private func parse(_ text: String) throws -> [Snippet] {
        try SnippadParser.parse(text)
    }

    private func assertFails(_ text: String, line: Int, file: StaticString = #filePath, lineNo: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: lineNo) { error in
            XCTAssertEqual((error as? SnippadParseError)?.line, line, "\(error)", file: file, line: lineNo)
        }
    }

    func testSnippetsInFileOrder() throws {
        let snippets = try parse("""
            # comment
            [[snippet]]
            name = "A"
            value = "first"

            [[snippet]]
            name = "B"   # trailing comment
            value = "second"
            """)
        XCTAssertEqual(snippets, [Snippet(id: 0, name: "A", value: "first"),
                                  Snippet(id: 1, name: "B", value: "second")])
    }

    func testBasicStringEscapes() throws {
        let s = try parse(#"""
            [[snippet]]
            name = "x"
            value = "a\tb\nc \"q\" \\ \u00E9 \U0001F600"
            """#)
        XCTAssertEqual(s[0].value, "a\tb\nc \"q\" \\ é 😀")
    }

    func testLiteralStringKeepsBackslashes() throws {
        let s = try parse(#"""
            [[snippet]]
            name = 'regex'
            value = '\d+\n'
            """#)
        XCTAssertEqual(s[0].value, #"\d+\n"#)
    }

    func testMultiLineBasicString() throws {
        let s = try parse("[[snippet]]\nname = \"m\"\nvalue = \"\"\"\nline one\nline two\\n   \n   still two\"\"\"\n")
        XCTAssertEqual(s[0].value, "line one\nline two\n   \n   still two")

        let trimmed = try parse("[[snippet]]\nname = \"m\"\nvalue = \"\"\"\none \\\n     two\"\"\"\n")
        XCTAssertEqual(trimmed[0].value, "one two")
    }

    func testMultiLineLiteralString() throws {
        let s = try parse("[[snippet]]\nname = \"m\"\nvalue = '''\nC:\\path\n  indented'''\n")
        XCTAssertEqual(s[0].value, "C:\\path\n  indented")
    }

    func testQuotesBeforeClosingDelimiter() throws {
        let s = try parse("[[snippet]]\nname = \"q\"\nvalue = \"\"\"say \"hi\"\"\"\"\"\n")
        XCTAssertEqual(s[0].value, "say \"hi\"\"")
    }

    func testCRLFLineEndings() throws {
        let s = try parse("[[snippet]]\r\nname = \"a\"\r\nvalue = \"\"\"\r\nx\r\ny\"\"\"\r\n")
        XCTAssertEqual(s[0].value, "x\ny")
    }

    func testOtherTablesAndKeysAreIgnored() throws {
        let s = try parse("""
            title = "my snippets"
            [meta]
            author = "me"
            [[snippet]]
            name = "a"
            value = "b"
            note = "ignored"
            """)
        XCTAssertEqual(s, [Snippet(id: 0, name: "a", value: "b")])
    }

    func testErrors() {
        assertFails("", line: 0)
        assertFails("[[snippet]]\nname = \"a\"\n", line: 1)               // no value
        assertFails("[[snippet]]\nvalue = \"a\"\n", line: 1)              // no name
        assertFails("[[snippet]]\nname = \"a\"\nname = \"b\"\nvalue = \"\"", line: 3)
        assertFails("[[snippet]]\nname = 42\nvalue = \"x\"", line: 2)
        assertFails("[[snippet]]\nname = \"a\nvalue = \"x\"", line: 2)
        assertFails("[[snippet]]\nname = \"a\" x\nvalue = \"x\"", line: 2)
        assertFails("[snippet]\nname = \"a\"\nvalue = \"x\"", line: 1)
        assertFails("[[snippet]]\nname = \"a\"\nvalue = \"\"\"\nopen", line: 3)
        assertFails("[[snippet]]\nname = \"\\q\"\nvalue = \"x\"", line: 2)
    }

    func testExampleFileParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("example.snippad")
        let snippets = try parse(String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(snippets.map(\.name), ["Email", "Greeting", "Signature", "Regex: date"])
        XCTAssertEqual(snippets[3].value, #"\d{4}-\d{2}-\d{2}"#)
    }
}
