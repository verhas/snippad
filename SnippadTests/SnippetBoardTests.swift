import SwiftUI
import XCTest
@testable import Snippad

/// The buttons' colours, icons, places and sizes: in the file, on the
/// board, and written back from the board.
@MainActor
final class SnippetBoardTests: XCTestCase {

    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetBoardTests-\(UUID().uuidString).snippad")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    func testTheLookOfAButtonRoundTrips() throws {
        var a = Snippet(id: 0, name: "a", value: "1", color: "#A7FFEB", icon: "star.fill", iconCorner: .bottomLeading,
                        origin: SnippetPoint(x: 20, y: 40), size: SnippetSize(width: 200, height: 60))
        let b = Snippet(id: 1, name: "b", value: "2")
        let text = SnippadWriter.text(for: [a, b])
        XCTAssertTrue(text.contains("color = \"#A7FFEB\"\nicon = \"star.fill\"\nicon_corner = \"bottom-left\"\nx = 20\ny = 40\nwidth = 200\nheight = 60\n"))
        XCTAssertEqual(try SnippadParser.parse(text), [a, b])

        // The default corner is not written.
        a.iconCorner = .topTrailing
        XCTAssertFalse(SnippadWriter.text(for: [a]).contains("icon_corner"))
        // Lower case and no # are read too.
        let parsed = try SnippadParser.parse("[[snippet]]\nname = \"a\"\nvalue = \"\"\ncolor = \"a7ffeb\"\n")
        XCTAssertEqual(parsed[0].color, "#A7FFEB")
    }

    func testBadLookFieldsAreReportedWithTheirLine() {
        func error(_ extra: String) -> String? {
            do { _ = try SnippadParser.parse("[[snippet]]\nname = \"a\"\nvalue = \"\"\n" + extra); return nil }
            catch { return error.localizedDescription }
        }
        XCTAssertEqual(error("color = \"red\"\n"), "Line 4: 'color' must be a colour like \"#A7FFEB\"")
        XCTAssertEqual(error("icon_corner = \"middle\"\n")?.hasPrefix("Line 4: 'icon_corner' must be"), true)
        XCTAssertEqual(error("x = 5\n"), "Line 1: a snippet's position needs both 'x' and 'y'")
        XCTAssertEqual(error("width = 100\n"), "Line 1: a snippet's size needs both 'width' and 'height'")
        XCTAssertEqual(error("width = 5\nheight = 50\n"), "Line 4: 'width' must be a whole number, at least 40")
        XCTAssertEqual(error("x = -1\ny = 0\n"), "Line 4: 'x' must be a whole number, at least 0")
    }

    func testASnippetWithoutAColourAlwaysShowsTheSameOne() {
        let s = Snippet(id: 0, name: "Address", value: "")
        XCTAssertEqual(s.shownColor, SnippetColors.derived(from: "Address"))
        XCTAssertEqual(SnippetColors.derived(from: "Address"), SnippetColors.derived(from: "Address"))
        XCTAssertTrue(SnippetColors.palette.contains(s.shownColor))
        XCTAssertTrue(SnippetColors.palette.contains(SnippetDraft().color), "a new snippet gets a colour of the palette")
        XCTAssertTrue(SnippetColors.isLight("#FFF475"))
        XCTAssertFalse(SnippetColors.isLight("#202060"))
        XCTAssertEqual(SnippetColors.hex(red: 1, green: 0.5, blue: 0), "#FF8000")
    }

    func testTheNearestCornerIsWhereTheIconLands() {
        XCTAssertEqual(SnippetCorner.nearest(to: 5, 5, width: 100, height: 40), .topLeading)
        XCTAssertEqual(SnippetCorner.nearest(to: 95, 5, width: 100, height: 40), .topTrailing)
        XCTAssertEqual(SnippetCorner.nearest(to: 5, 35, width: 100, height: 40), .bottomLeading)
        XCTAssertEqual(SnippetCorner.nearest(to: 130, 90, width: 100, height: 40), .bottomTrailing)
    }

    func testButtonsFlowInRowsAroundTheOnesWithAPlace() {
        let s = CGSize(width: 100, height: 36)
        let p = BoardLayout.padding, g = BoardLayout.spacing
        // Three fit in a row of 400 points: 16 + 100 + 10 + 100 + 10 + 100 + 16 = 352.
        let flow = BoardLayout.frames([(nil, s), (nil, s), (nil, s), (nil, s)], width: 400)
        XCTAssertEqual(flow.map(\.origin), [CGPoint(x: p, y: p), CGPoint(x: p + 110, y: p), CGPoint(x: p + 220, y: p),
                                            CGPoint(x: p, y: p + 36 + g)])

        // One placed where the second would go: the second goes after it.
        let placed = BoardLayout.frames([(nil, s), (CGPoint(x: 130, y: 10), s), (nil, s)], width: 600)
        XCTAssertEqual(placed[1].origin, CGPoint(x: 130, y: 10))
        XCTAssertEqual(placed[2].origin, CGPoint(x: 240, y: p))
        XCTAssertFalse(placed[0].intersects(placed[1]) || placed[2].intersects(placed[1]))

        // A placed button as wide as the window: the flow goes below it.
        let wide = BoardLayout.frames([(CGPoint(x: 0, y: 0), CGSize(width: 400, height: 50)), (nil, s)], width: 400)
        XCTAssertGreaterThanOrEqual(wide[1].minY, 50 + g / 2)
    }

    func testMovesAndResizesInTheWindowAreWrittenToTheFile() throws {
        try SnippadWriter.save([Snippet(id: 0, name: "a", value: "1"), Snippet(id: 1, name: "b", value: "2", icon: "star")], to: file)
        let library = SnippadLibrary.shared

        library.apply(.origin(0, name: "a", SnippetPoint(x: 30, y: 50)), to: file)
        library.apply(.size(1, name: "b", SnippetSize(width: 180, height: 70), origin: SnippetPoint(x: 0, y: 100)), to: file)
        library.apply(.iconCorner(1, name: "b", .bottomLeading), to: file)
        var read = try SnippadContent.read(file).get()
        XCTAssertEqual(read[0].origin, SnippetPoint(x: 30, y: 50))
        XCTAssertNil(read[0].size)
        XCTAssertEqual(read[1].size, SnippetSize(width: 180, height: 70))
        XCTAssertEqual(read[1].origin, SnippetPoint(x: 0, y: 100))
        XCTAssertEqual(read[1].iconCorner, .bottomLeading)
        // The colours shown before are now written, and stay.
        XCTAssertEqual(read[0].color, SnippetColors.derived(from: "a"))
        XCTAssertEqual(library.model(for: file).drafts[1].iconCorner, .bottomLeading, "the Organizer shows it too")

        // A change for a button the file no longer has at that place does nothing.
        library.apply(.origin(1, name: "a", SnippetPoint(x: 1, y: 1)), to: file)
        XCTAssertEqual(try SnippadContent.read(file).get()[1].origin, SnippetPoint(x: 0, y: 100))

        library.apply(.arrangeAll, to: file)
        read = try SnippadContent.read(file).get()
        XCTAssertTrue(read.allSatisfy { $0.origin == nil && $0.size == nil })
        XCTAssertEqual(read[1].icon, "star")
    }

    /// The layout has to see each button's place and size: a layout value
    /// under other modifiers is silently ignored, which put every button
    /// back in the flow after it was moved or resized.
    func testTheWindowDrawsAButtonWhereItWasPutAndAsLargeAsItWasMade() {
        final class Shown { var frames: [String: CGRect] = [:] }
        let shown = Shown()
        let snippets = [Snippet(id: 0, name: "flows", value: ""),
                        Snippet(id: 1, name: "placed", value: "", origin: SnippetPoint(x: 200, y: 120),
                                size: SnippetSize(width: 150, height: 50))]
        let host = NSHostingView(rootView: SnippetBoard(snippets: snippets, change: { _ in }) { snippet, frame in
            shown.frames[snippet.name] = frame
        })
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(shown.frames["placed"], CGRect(x: 200, y: 120, width: 150, height: 50))
        XCTAssertEqual(shown.frames["flows"]?.origin, CGPoint(x: BoardLayout.padding, y: BoardLayout.padding))
    }
}
