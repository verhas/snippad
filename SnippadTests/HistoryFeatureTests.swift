import AppKit
import XCTest
@testable import Snippad

/// Undo Delete, names, the age limit, the size on disk, entries joined, and
/// Markdown.
@MainActor
final class HistoryFeatureTests: XCTestCase {

    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var settings: SettingsStore!
    private var engine: PasteEngine!
    private var history: ClipboardHistory!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryFeatures-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("SnippadFeatureTests-\(UUID().uuidString)"))
        settings = SettingsStore(url: nil)
        engine = PasteEngine()
        engine.pasteboard = pasteboard
        history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        engine.recorder = { [weak history] in history?.recordOwn($0) }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ text: String, rich: NSAttributedString? = nil, list: String? = nil, date: Date = Date(), password: Bool = false) -> UUID {
        var types = [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]
        if let rich, let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            types[NSPasteboard.PasteboardType.rtf.rawValue] = rtf
        }
        var item = ClipItem(items: [types], date: date)
        item.listID = list
        if password { item.password = true }
        history.record(item)
        return history.items.first { $0.digest == item.digest }!.id
    }

    func testDeletedEntriesComeBackWithUndo() throws {
        let a = add("a"), b = add("b"), c = add("c")
        history.delete(undoably: [a, c])
        XCTAssertEqual(history.items.map(\.string), ["b"])
        XCTAssertEqual(history.undoableDelete?.items.count, 2)

        let back = history.undoDelete()
        XCTAssertEqual(Set(back.map(\.id)), [a, c])
        XCTAssertEqual(history.items.map(\.string), ["c", "b", "a"], "back in their places")
        XCTAssertNil(history.undoableDelete)
        // And on disk again: a new history reads them.
        let again = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        XCTAssertEqual(Set(again.items.map(\.id)), [a, b, c])

        // Clearing can be undone too.
        history.clear()
        XCTAssertTrue(history.items.isEmpty)
        history.undoDelete()
        XCTAssertEqual(history.items.count, 3)
    }

    func testANamedEntryShowsAndIsFoundByItsName() {
        let id = add("SELECT * FROM users")
        history.rename(id, to: "  The query  ")
        XCTAssertEqual(history.item(id)?.title, "The query")
        XCTAssertEqual(history.search("query").map(\.id), [id])
        history.rename(id, to: "")
        XCTAssertNil(history.item(id)?.name)
        XCTAssertEqual(history.item(id)?.title, "SELECT * FROM users")
    }

    func testOldEntriesGoButPinnedOnesStay() {
        let old = add("old", date: Date().addingTimeInterval(-10 * 86400))
        let pinned = add("pinned and old", date: Date().addingTimeInterval(-20 * 86400))
        history.setPinned(pinned, true)
        let new = add("new")
        XCTAssertEqual(history.countOlder(thanDays: 7), 1)
        history.maxAgeDays = 7
        XCTAssertNil(history.item(old))
        XCTAssertNotNil(history.item(pinned))
        XCTAssertNotNil(history.item(new))
        history.maxAgeDays = 0
        XCTAssertEqual(history.countOlder(thanDays: 0), 0)
    }

    func testTheSizeOnDiskCountsTheEntries() {
        _ = add(String(repeating: "x", count: 10_000))
        _ = add("y")
        let usage = history.diskUsage()
        XCTAssertEqual(usage.entries, 2)
        XCTAssertGreaterThan(usage.bytes, 10_000)
        XCTAssertTrue(history.diskUsageText.hasPrefix("2 entries, "))
    }

    func testSeveralEntriesAreCopiedAsOne() throws {
        let a = add("first"), b = add("second")
        let bold = NSAttributedString(string: "third", attributes: [.font: NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .boldFontMask)])
        let c = add("third", rich: bold)
        try history.copyJoined([a, b, c])
        XCTAssertEqual(pasteboard.string(forType: .string), "first\nsecond\nthird")
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
        XCTAssertEqual(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string, "first\nsecond\nthird")
        XCTAssertEqual(history.items.first?.string, "first\nsecond\nthird", "the joined text is an entry of its own")

        try history.copyJoined([b, a], separator: ", ")
        XCTAssertEqual(pasteboard.string(forType: .string), "second, first")
    }

    func testEntriesOfTwoGuardedListsOrAPasswordAreNotJoined() throws {
        settings.value.lists += [ClipList(id: "work", name: "Work", guardMode: .onlyListed, guardApps: ["com.example.a"]),
                                 ClipList(id: "bank", name: "Bank", guardMode: .onlyListed, guardApps: ["com.example.b"])]
        let w = add("w", list: "work"), k = add("k", list: "bank"), plain = add("plain")
        XCTAssertThrowsError(try history.copyJoined([w, k]))
        // One guarded list among them: the joined text belongs to it.
        try history.copyJoined([plain, w])
        XCTAssertEqual(history.items.first?.list, "work")

        let p = add("secret", password: true)
        XCTAssertThrowsError(try history.copyJoined([p, plain]))
    }

    func testFormattedTextBecomesMarkdown() {
        let fm = NSFontManager.shared
        let body = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Title\n", attributes: [.font: NSFont.systemFont(ofSize: 26)]))
        text.append(NSAttributedString(string: "Some ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "bold", attributes: [.font: fm.convert(body, toHaveTrait: .boldFontMask)]))
        text.append(NSAttributedString(string: " and ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "italic", attributes: [.font: fm.convert(body, toHaveTrait: .italicFontMask)]))
        text.append(NSAttributedString(string: " text, a ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "link", attributes: [.font: body, .link: URL(string: "https://example.com")!]))
        text.append(NSAttributedString(string: " and ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "code", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        text.append(NSAttributedString(string: ".\n• one\n• two*", attributes: [.font: body]))
        XCTAssertEqual(MarkdownConverter.markdown(from: text), """
            # Title
            Some **bold** and *italic* text, a [link](https://example.com) and `code`.
            - one
            - two\\*
            """)

        let id = add("x", rich: text)
        XCTAssertTrue(history.put(id, as: .markdown))
        XCTAssertEqual(pasteboard.string(forType: .string)?.hasPrefix("# Title\n"), true)
        XCTAssertNil(pasteboard.data(forType: .rtf), "Markdown is plain text")
    }

    func testPlainTextBecomesRichText() {
        let id = add("plain")
        history.makeRichText(id)
        XCTAssertEqual(history.item(id)?.kind, .richText)
        XCTAssertEqual(history.item(id)?.string, "plain")
    }

    func testTheGlobalShortcutsAreSettings() {
        XCTAssertEqual(settings.value.historyShortcut.display, "⌃⌘V")
        settings.value.pickerHotKey = "ctrl+opt+p"
        XCTAssertEqual(settings.value.pickerShortcut, KeyShortcut(key: "p", control: true, option: true))
        // Keys no shortcut can have fall back to the default.
        settings.value.organizerHotKey = "h"
        XCTAssertEqual(settings.value.organizerHotKey, "shift+cmd+h")
        XCTAssertEqual(SnippetShortcuts.reserved[KeyShortcut(key: "p", control: true, option: true)], nil,
                       "reserved reads the shared settings, not these")
    }

    func testRichTextIsFormattedInTheEditor() {
        let view = EditingTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.isEditable = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "Hello world", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleTrait(.boldFontMask)
        let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font!).contains(.boldFontMask))
        let rest = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        XCTAssertFalse(NSFontManager.shared.traits(of: rest!).contains(.boldFontMask))
        view.toggleTrait(.boldFontMask)
        XCTAssertFalse(NSFontManager.shared.traits(of: view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask))

        view.setSelectedRange(NSRange(location: 0, length: 11))
        view.toggleList(numbered: false)
        XCTAssertEqual(view.string, "• Hello world")
        view.toggleList(numbered: false)
        XCTAssertEqual(view.string, "Hello world")
    }
}
