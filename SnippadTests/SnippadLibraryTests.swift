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
}
