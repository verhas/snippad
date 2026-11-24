import XCTest
@testable import Snippad

/// Opening a file always reads it from disk, and never writes it.
@MainActor
final class SnippadLibraryTests: XCTestCase {

    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippadLibraryTests-\(UUID().uuidString).snippad")
    }

    override func tearDown() async throws {
        NSApp.windows.filter { $0.title == file.lastPathComponent }.forEach { $0.close() }
        try? FileManager.default.removeItem(at: file)
    }

    private func write(_ name: String) throws {
        try "[[snippet]]\nname = \"\(name)\"\nvalue = \"v\"\n"
            .write(to: file, atomically: true, encoding: .utf8)
    }

    private func shownNames() throws -> [String] {
        let content = try XCTUnwrap(SnippadLibrary.shared.content(for: file))
        return try content.snippets.get().map(\.name)
    }

    func testOpeningAgainRereadsTheFile() throws {
        try write("first")
        SnippadLibrary.shared.open(file)
        XCTAssertEqual(try shownNames(), ["first"])

        try write("second")
        SnippadLibrary.shared.open(file)
        XCTAssertEqual(try shownNames(), ["second"])
        XCTAssertEqual(NSApp.windows.filter { $0.title == file.lastPathComponent && $0.isVisible }.count, 1,
                       "opening an open file again reuses its window")
    }

    func testOpeningNeverWritesTheFile() throws {
        try write("x")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let bytes = try Data(contentsOf: file)

        SnippadLibrary.shared.open(file)
        SnippadLibrary.shared.open(file)

        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testABrokenFileShowsTheErrorAndRecoversOnReopen() throws {
        try "[[snippet]]\nname = \"a\"\n".write(to: file, atomically: true, encoding: .utf8)
        SnippadLibrary.shared.open(file)
        let content = try XCTUnwrap(SnippadLibrary.shared.content(for: file))
        XCTAssertThrowsError(try content.snippets.get()) { error in
            XCTAssertEqual(error.localizedDescription, "Line 1: this [[snippet]] has no value")
        }

        try write("fixed")
        SnippadLibrary.shared.open(file)
        XCTAssertEqual(try shownNames(), ["fixed"])
    }

    func testASnippetIsCopiedOrMovedToAnotherFile() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippadLibraryTests-other-\(UUID().uuidString).snippad")
        defer { try? FileManager.default.removeItem(at: other) }
        try "[[snippet]]\nname = \"a\"\nvalue = \"1\"\nshortcut = \"ctrl+opt+f9\"\nonce = true\n\n[[snippet]]\nname = \"b\"\nvalue = \"2\"\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try "[[snippet]]\nname = \"a\"\nvalue = \"x\"\n".write(to: other, atomically: true, encoding: .utf8)
        let library = SnippadLibrary.shared
        let source = library.model(for: file)
        let a = try XCTUnwrap(source.drafts.first)

        // Copied: a name of its own, its rules, but not the shortcut.
        XCTAssertFalse(try library.transferSnippet(a.id, from: file, to: other, move: false))
        var written = try XCTUnwrap(try SnippadContent.read(other).get())
        XCTAssertEqual(written.map(\.name), ["a", "a 2"])
        XCTAssertEqual(written[1].value, "1")
        XCTAssertTrue(written[1].once)
        XCTAssertNil(written[1].shortcut)
        XCTAssertEqual(source.drafts.count, 2, "still in its own file")

        // Moved: gone from its file, with its shortcut.
        XCTAssertTrue(try library.transferSnippet(a.id, from: file, to: other, move: true))
        written = try SnippadContent.read(other).get()
        XCTAssertEqual(written.map(\.name), ["a", "a 2", "a 3"])
        XCTAssertEqual(written[2].shortcut, "ctrl+opt+f9")
        XCTAssertEqual(try SnippadContent.read(file).get().map(\.name), ["b"])

        // The last snippet of a file is only copied: a file needs one.
        let b = try XCTUnwrap(source.drafts.first)
        XCTAssertFalse(try library.transferSnippet(b.id, from: file, to: other, move: true))
        XCTAssertEqual(try SnippadContent.read(file).get().map(\.name), ["b"])
        XCTAssertFalse(try library.transferSnippet(b.id, from: other, to: other, move: true), "not onto its own file")
    }
}
