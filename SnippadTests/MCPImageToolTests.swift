import AppKit
import XCTest
@testable import Snippad

/// The image editor through MCP, and what the Organizer shows.
@MainActor
final class MCPImageToolTests: XCTestCase {

    private var entry: UUID!

    override func setUp() async throws {
        // What Snippad puts on the clipboard is recorded, as in the app.
        PasteEngine.shared.recorder = { ClipboardHistory.shared.recordOwn($0) }
        // A 200×100 white image, in the tests' own history.
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            return true
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 200, height: 100))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        var item = ClipItem(items: [[NSPasteboard.PasteboardType.png.rawValue: png]])
        item.sourceApp = "Test"
        ClipboardHistory.shared.record(item)
        entry = ClipboardHistory.shared.items.first { $0.digest == item.digest }!.id
        HistoryNavigation.shared.sidebar = .all
        HistoryNavigation.shared.selection = [entry]
    }

    override func tearDown() async throws {
        HistoryNavigation.shared.selection = []
        if let entry { ClipboardHistory.shared.delete(entry) }
    }

    private func tool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (json: [String: Any], text: String, isError: Bool, images: Int) {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                  "params": ["name": name, "arguments": arguments]])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MCPHandler.handle(request))) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let texts = content.compactMap { $0["text"] as? String }
        let json = texts.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        return (json, texts.joined(separator: "\n"), result["isError"] as? Bool ?? false, content.filter { $0["type"] as? String == "image" }.count)
    }

    func testTheSelectedImageIsTheCurrentOne() throws {
        let state = try tool("organizer_state")
        XCTAssertEqual((state.json["current_image"] as? [String: Any])?["id"] as? String, entry.uuidString)
        let get = try tool("image_get")
        XCTAssertFalse(get.isError, get.text)
        XCTAssertEqual(get.json["width"] as? Int, 200)
        XCTAssertEqual(get.json["height"] as? Int, 100)
        XCTAssertEqual(get.images, 1)

        HistoryNavigation.shared.selection = []
        XCTAssertTrue(try tool("image_get").isError, "nothing selected, nothing open: no current image")
        XCTAssertFalse(try tool("image_get", ["id": entry.uuidString]).isError)
    }

    func testObjectsAreAddedChangedAndRemoved() throws {
        let added = try tool("image_add", ["objects": [
            ["kind": "shape", "shape": "oval", "rect": [10, 10, 50, 30], "color": "blue", "line_width": 3],
            ["kind": "arrow", "from": [100, 80], "to": [150, 20], "color": "#FF0000"],
            ["kind": "text", "text": "Hi", "rect": [120, 60, 1, 1], "font_size": 20],
            ["kind": "marker", "center": [30, 70], "size": 20],
            ["kind": "effect", "effect": "blur", "rect": [0, 0, 20, 20]],
        ]])
        XCTAssertFalse(added.isError, added.text)
        let objects = try XCTUnwrap(added.json["added"] as? [[String: Any]])
        XCTAssertEqual(objects.map { $0["kind"] as? String }, ["shape", "line", "text", "marker", "effect"])
        XCTAssertEqual(objects[1]["end_head"] as? String, "solid")
        XCTAssertEqual(objects[3]["number"] as? Int, 1)

        var edits = try XCTUnwrap(ClipboardHistory.shared.item(entry)?.edits)
        XCTAssertEqual(edits.layers.count, 5, "kept with the entry, with its original")
        XCTAssertEqual(edits.layers[0].stroke.b, 1, accuracy: 0.01)

        let oval = try XCTUnwrap(objects[0]["id"] as? String)
        let changed = try tool("image_change", ["ids": [oval], "changes": ["move_by": [5, 5], "fill": "#00FF0080", "shape": "rectangle"]])
        XCTAssertFalse(changed.isError, changed.text)
        edits = try XCTUnwrap(ClipboardHistory.shared.item(entry)?.edits)
        XCTAssertEqual(edits.layers[0].rect, CGRect(x: 15, y: 15, width: 50, height: 30))
        XCTAssertEqual(edits.layers[0].shape, .rectangle)
        XCTAssertEqual(edits.layers[0].fill?.a ?? 0, 0.5, accuracy: 0.01)

        XCTAssertTrue(try tool("image_change", ["ids": [oval], "changes": ["colour": "red"]]).isError, "unknown properties are errors")
        XCTAssertTrue(try tool("image_remove", ["ids": [UUID().uuidString]]).isError)

        let ordered = try tool("image_order", ["ids": [oval], "order": "front"])
        XCTAssertEqual((ordered.json["objects"] as? [[String: Any]])?.last?["id"] as? String, oval)

        XCTAssertFalse(try tool("image_remove", ["ids": [oval]]).isError)
        XCTAssertEqual(ClipboardHistory.shared.item(entry)?.edits?.layers.count, 4)

        XCTAssertFalse(try tool("image_crop", ["rect": [50, 0, 100, 100]]).isError)
        let image = try XCTUnwrap(ClipboardHistory.shared.item(entry)?.image)
        XCTAssertEqual(image.representations.first?.pixelsWide, 100, "the entry's picture is cropped")
        XCTAssertFalse(try tool("image_revert", ["what": "crop"]).isError)
        XCTAssertNil(ClipboardHistory.shared.item(entry)?.edits?.crop)
        XCTAssertFalse(try tool("image_revert").isError)
        XCTAssertEqual(ClipboardHistory.shared.item(entry)?.edits?.layers.count, 0)
    }

    func testChangesGoThroughAnOpenEditorAndCanBeUndone() throws {
        let item = try XCTUnwrap(ClipboardHistory.shared.item(entry))
        var handed: ImageEdits?
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: item.pngData!)) { edits, _ in handed = edits })
        OpenImageEditors.register(model, for: .history(entry))
        defer { OpenImageEditors.unregister(model, for: .history(entry)) }

        XCTAssertEqual((try tool("organizer_state").json["image_editor"] as? [String: Any])?["id"] as? String, entry.uuidString)
        let added = try tool("image_add", ["objects": [["kind": "shape", "rect": [1, 1, 10, 10]]]])
        XCTAssertFalse(added.isError, added.text)
        XCTAssertEqual(model.edits.layers.count, 1, "the open editor shows it")
        XCTAssertEqual(model.selection.count, 1, "and selects it")
        XCTAssertEqual(handed?.layers.count, 1, "and saves it")

        XCTAssertFalse(try tool("image_undo").isError)
        XCTAssertEqual(model.edits.layers.count, 0)
        XCTAssertFalse(try tool("image_undo", ["redo": true]).isError)
        XCTAssertEqual(model.edits.layers.count, 1)
    }

    func testHistoryCommandsForAgents() throws {
        var item = ClipItem.text("joined one")
        ClipboardHistory.shared.record(item)
        let one = ClipboardHistory.shared.items[0].id
        item = ClipItem.text("joined two")
        ClipboardHistory.shared.record(item)
        let two = ClipboardHistory.shared.items[0].id
        defer { ClipboardHistory.shared.delete(one); ClipboardHistory.shared.delete(two) }

        XCTAssertFalse(try tool("history_rename", ["id": one.uuidString, "name": "First"]).isError)
        XCTAssertEqual(ClipboardHistory.shared.item(one)?.title, "First")

        XCTAssertFalse(try tool("history_copy_joined", ["ids": [one.uuidString, two.uuidString], "separator": " + "]).isError)
        XCTAssertEqual(PasteEngine.shared.pasteboard.string(forType: .string), "joined one + joined two")
        let joined = try XCTUnwrap(ClipboardHistory.shared.items.first { $0.string == "joined one + joined two" })
        ClipboardHistory.shared.delete(joined.id)

        XCTAssertFalse(try tool("history_delete", ["id": two.uuidString]).isError)
        XCTAssertNil(ClipboardHistory.shared.item(two))
        XCTAssertFalse(try tool("history_undo_delete").isError)
        XCTAssertNotNil(ClipboardHistory.shared.item(two))

        let settings = try tool("history_settings", ["max_age_days": 0])
        XCTAssertNotNil(settings.json["disk_size"])
    }
}
