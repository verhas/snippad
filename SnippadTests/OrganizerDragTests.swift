import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Snippad

/// What an entry or snippet dragged out of the Organizer gives other apps.
@MainActor
final class OrganizerDragTests: XCTestCase {

    private func provider(_ drag: ClipDrag) -> NSItemProvider {
        let p = NSItemProvider()
        p.register(drag)
        return p
    }

    private func text(of provider: NSItemProvider) async -> String? {
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
                done.resume(returning: data)
            }
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func testTextDragsIntoOtherAppsAndStillOntoLists() async throws {
        let item = ClipItem.text("hello")
        let drags = ClipDrag.items(for: item)
        XCTAssertEqual(drags.count, 1)
        let p = provider(drags[0])
        XCTAssertTrue(p.hasItemConformingToTypeIdentifier(UTType.snippadHistoryItem.identifier), "onto lists and files")
        let text = await self.text(of: p)
        XCTAssertEqual(text, "hello")
    }

    /// Dragged out, the first type becomes the file the drop is promised:
    /// never Snippad's own list of entries, which reached Diptych as a file
    /// holding `{"ids":[…]}` in place of the picture.
    func testWhatOtherAppsTakeComesBeforeTheEntries() {
        for item in [ClipItem.text("hello")] {
            let types = provider(ClipDrag.items(for: item)[0]).registeredTypeIdentifiers
            XCTAssertEqual(types.first, UTType.utf8PlainText.identifier, "\(types)")
            XCTAssertEqual(types.last, UTType.snippadHistoryItem.identifier, "\(types)")
        }
    }

    func testAPasswordStaysInsideSnippad() {
        var item = ClipItem.text("secret")
        item.password = true
        XCTAssertTrue(DragExport.exports(for: item).isEmpty)
        let drags = ClipDrag.items(for: item)
        XCTAssertEqual(drags.count, 1)
        XCTAssertNil(drags[0].export)
        let p = provider(drags[0])
        XCTAssertFalse(p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
        XCTAssertTrue(p.hasItemConformingToTypeIdentifier(UTType.snippadHistoryItem.identifier))
    }

    func testEveryCopiedFileIsAnItemOfItsOwnAndTheEntryCountsOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrganizerDrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["a.txt", "b.txt"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        let gone = folder.appendingPathComponent("gone.txt")
        let item = ClipItem(items: (urls + [gone]).map { [NSPasteboard.PasteboardType.fileURL.rawValue: $0.dataRepresentation] })

        let drags = ClipDrag.items(for: item)
        XCTAssertEqual(drags.map { $0.export?.file?.lastPathComponent }, ["a.txt", "b.txt"], "a vanished file is left out")
        XCTAssertEqual(drags.map(\.history.ids.count), [1, 0])
        XCTAssertFalse(provider(drags[1]).hasItemConformingToTypeIdentifier(UTType.snippadHistoryItem.identifier))
    }

    func testSnippetsWithRulesStayInsideSnippad() {
        XCTAssertEqual(DragExport.export(for: SnippetDraft(name: "n", value: "v"))?.text, "v")
        XCTAssertNil(DragExport.export(for: SnippetDraft(name: "n", value: "v", password: true)))
        XCTAssertNil(DragExport.export(for: SnippetDraft(name: "n", value: "v", once: true)))
        XCTAssertNil(DragExport.export(for: SnippetDraft(name: "n", value: "v", expires: 30)))
        let chained = SnippetDraft(name: "n", value: "v")
        chained.nextID = UUID()
        XCTAssertNil(DragExport.export(for: chained))
    }

    func testFileNamesAreSafeForFinder() {
        XCTAssertEqual(DragExport.fileName("a/b:c"), "a b c")
        XCTAssertEqual(DragExport.fileName("  "), "Snippad")
    }
}
