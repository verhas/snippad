import AppKit
import XCTest
@testable import Snippad

/// Expiry, paste-once and chains, on a private pasteboard. A paste is a ⌘V
/// (noticePaste) followed by the app reading the clipboard.
@MainActor
final class PasteEngineTests: XCTestCase {

    private var engine: PasteEngine!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("SnippadTests-\(UUID().uuidString)"))
        engine = PasteEngine()
        engine.pasteboard = pasteboard
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func paste() -> String? {
        engine.noticePaste()
        return pasteboard.string(forType: .string)
    }

    /// Lets the engine's follow-up after a paste run.
    private func settle(_ seconds: Double = 0.7) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testPlainValueStays() async {
        engine.put("hello", name: "h")
        XCTAssertEqual(paste(), "hello")
        await settle()
        XCTAssertEqual(paste(), "hello")
        XCTAssertFalse(pasteboard.types?.contains(.concealed) ?? true, "plain values may be recorded")
    }

    func testOnceIsGoneAfterOnePaste() async {
        engine.put("secret", name: "s", rules: PasteRules(once: true))
        XCTAssertTrue(pasteboard.types?.contains(.concealed) ?? false)
        XCTAssertEqual(paste(), "secret")
        await settle()
        XCTAssertNil(paste())
        XCTAssertNil(engine.current)
    }

    func testChainPutsTheNextValue() async {
        let snippets = [
            Snippet(id: 0, name: "user", value: "me", next: "password"),
            Snippet(id: 1, name: "password", value: "pw", once: true),
        ]
        engine.put("me", name: "user", rules: snippets[0].rules(in: snippets))
        XCTAssertEqual(paste(), "me")
        await settle()
        XCTAssertEqual(engine.current?.name, "password")
        XCTAssertEqual(paste(), "pw")
        await settle()
        XCTAssertNil(paste())
    }

    func testReadingIsNotPasting() async {
        engine.put("secret", name: "s", rules: PasteRules(once: true))
        // What IDEs and clipboard managers do on every change.
        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
        await settle()
        XCTAssertEqual(engine.current?.name, "s")
        XCTAssertTrue(pasteboard.types?.contains(.string) ?? false)
    }

    func testExpiryClears() async {
        engine.put("short", name: "s", rules: PasteRules(expires: 1))
        XCTAssertEqual(paste(), "short", "a paste does not end an expiry-only value")
        await settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "short")
        await settle(1.5)
        XCTAssertNil(paste())
    }

    func testExpiryLeavesSomeoneElsesCopyAlone() async {
        engine.put("short", name: "s", rules: PasteRules(expires: 1))
        pasteboard.clearContents()
        pasteboard.setString("other", forType: .string)
        await settle(1.5)
        XCTAssertEqual(paste(), "other")
    }

    func testTwoNoticesForOnePasteMoveOnce() async {
        let snippets = [
            Snippet(id: 0, name: "a", value: "1", next: "b"),
            Snippet(id: 1, name: "b", value: "2", next: "c"),
            Snippet(id: 2, name: "c", value: "3"),
        ]
        engine.put("1", name: "a", rules: snippets[0].rules(in: snippets))
        engine.noticePaste()
        engine.noticePaste()
        await settle()
        XCTAssertEqual(engine.current?.name, "b")
    }

    func testANewValueCancelsTheOldTimer() async {
        engine.put("a", name: "a", rules: PasteRules(expires: 1))
        engine.put("b", name: "b")
        await settle(1.5)
        XCTAssertEqual(paste(), "b")
    }

    // MARK: - When the keyboard tap is needed (awaitsPaste)

    func testTapIsNeededOnlyWhileAChainWaits() async {
        var changes = 0
        engine.onStateChange = { changes += 1 }
        let snippets = [
            Snippet(id: 0, name: "user", value: "alice", next: "pw"),
            Snippet(id: 1, name: "pw", value: "hunter2", once: true),
        ]
        engine.put("plain", name: "p")
        XCTAssertFalse(engine.awaitsPaste, "a plain value needs no tap")
        XCTAssertFalse(PasteInterceptor.neededForRules(engine))

        engine.put("alice", name: "user", rules: snippets[0].rules(in: snippets))
        XCTAssertTrue(engine.awaitsPaste)
        engine.noticePaste()
        await settle()
        XCTAssertTrue(engine.awaitsPaste, "the password step still waits")
        engine.noticePaste()
        await settle()
        XCTAssertFalse(engine.awaitsPaste, "the chain is done")
        XCTAssertGreaterThanOrEqual(changes, 4)
    }

    func testACopyElsewhereEndsTheWait() {
        var changes = 0
        engine.onStateChange = { changes += 1 }
        engine.put("secret", name: "s", rules: PasteRules(once: true))
        pasteboard.clearContents()
        pasteboard.setString("someone else", forType: .string)
        XCTAssertFalse(engine.awaitsPaste)
        let before = changes
        engine.clipboardChangedElsewhere()
        XCTAssertNil(engine.current)
        XCTAssertEqual(changes, before + 1, "the tap is told to go")
        engine.clipboardChangedElsewhere()
        XCTAssertEqual(changes, before + 1, "only once")
    }

    func testExpiryOnlyNeedsNoTap() {
        engine.put("x", name: "x", rules: PasteRules(expires: 30))
        XCTAssertFalse(engine.awaitsPaste)
    }
}
