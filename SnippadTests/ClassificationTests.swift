import AppKit
import XCTest
@testable import Snippad

/// Public, Sensitive, Private, Secret: the rules, the entry's own state,
/// and when pasting asks first.
@MainActor
final class ClassificationTests: XCTestCase {

    private func text(_ s: String) -> ClipItem {
        ClipItem(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(s.utf8)]])
    }

    func testRulesFindSecrets() {
        for secret in ["AKIAIOSFODNN7EXAMPLE",
                       "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE=",
                       "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                       "password: Tr0ub4dor&3",
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"] {
            XCTAssertEqual(ClipClassifier.rules(secret), .secret, secret)
        }
    }

    func testRulesFindPersonalData() {
        XCTAssertEqual(ClipClassifier.rules("IBAN: GB82 WEST 1234 5698 7654 32"), .sensitive)
        XCTAssertNil(ClipClassifier.rules("GB82 WEST 1234 5698 7654 33"), "wrong check digits")
        XCTAssertEqual(ClipClassifier.rules("Card 4111 1111 1111 1111 exp 12/29"), .sensitive)
        XCTAssertNil(ClipClassifier.rules("order 4111 1111 1111 1112"), "fails Luhn")
        XCTAssertEqual(ClipClassifier.rules("Számla: 11773016-11111018"), .sensitive)
        XCTAssertEqual(ClipClassifier.rules("Call me on +36 30 123 4567"), .sensitive)
        XCTAssertEqual(ClipClassifier.rules("Hívj: 06 30 123 4567"), .sensitive)
        XCTAssertNil(ClipClassifier.rules("Total: 1 234 567 Ft"), "an amount")
    }

    func testRulesLeaveOrdinaryThingsAlone() {
        for plain in ["func add(_ a: Int) -> Int { a + 1 }", "let timestamp = 1732530000123",
                      "https://example.com/docs/page?id=42", "Meeting moved to Thursday."] {
            XCTAssertNil(ClipClassifier.rules(plain), plain)
        }
    }

    func testWhatIsClassifiedAndWhen() {
        var item = text("hello")
        XCTAssertTrue(item.needsClassification(model: false, imageTextIsRead: true))
        item.category = .general
        item.categoryFrom = item.classificationKey
        item.categoryByModel = false
        item.categoryVersion = ClipClassifier.version
        XCTAssertFalse(item.needsClassification(model: false, imageTextIsRead: true))
        XCTAssertTrue(item.needsClassification(model: true, imageTextIsRead: true), "again, once Apple Intelligence can say")

        var image = ClipItem(items: [[NSPasteboard.PasteboardType.png.rawValue: Data([1, 2, 3])]])
        XCTAssertFalse(image.needsClassification(model: true, imageTextIsRead: true), "waits for its text")
        XCTAssertTrue(image.needsClassification(model: true, imageTextIsRead: false), "unless no text is read")
        image.readText = "AKIAIOSFODNN7EXAMPLE"
        image.readTextFrom = image.digest
        XCTAssertEqual(image.classifiedText, "AKIAIOSFODNN7EXAMPLE")
        XCTAssertTrue(image.needsClassification(model: true, imageTextIsRead: true))
    }

    func testTheUsersCategoryStands() {
        var item = text("hello")
        item.category = .general
        XCTAssertEqual(item.effectiveCategory, .general)
        item.userCategory = .sensitive
        XCTAssertEqual(item.effectiveCategory, .sensitive)
        var password = text("hunter2")
        password.password = true
        XCTAssertEqual(password.effectiveCategory, .secret, "a password is a secret before it is classified")
    }

    func testPastingAsksForTheChosenCategories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Classification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("ClassificationTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = SettingsStore(url: nil)
        settings.value.classifyEntries = false  // nothing in the background: the test decides
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)

        history.record(text("Meeting moved to Thursday."))
        XCTAssertNil(PasteConfirmation.needed(history, settings.value))
        let id = try XCTUnwrap(history.currentItemID)
        history.setUserCategory(.offensive, of: [id])
        XCTAssertEqual(PasteConfirmation.needed(history, settings.value)?.1, .offensive)
        settings.value.askBeforePasting = [ClipCategory.secret.rawValue]
        XCTAssertNil(PasteConfirmation.needed(history, settings.value), "not asked about Private any more")

        settings.value.classifyEntries = true
        history.record(text("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertEqual(PasteConfirmation.needed(history, settings.value)?.1, .secret,
                       "copied a moment ago: the rules decide until it is classified")
    }

    func testWhatIsNeverPublicIsPrivateWhenFoundPublic() {
        var settings = SnippadSettings()
        settings.neverPublicApps = ["com.example.messenger"]
        var item = text("see you at 8")
        item.sourceBundleID = "com.example.messenger"
        XCTAssertEqual(item.category(in: settings), .offensive, "Private until it is classified")
        item.category = .general
        XCTAssertEqual(item.category(in: settings), .offensive, "Public counts as Private")
        item.category = .sensitive
        XCTAssertEqual(item.category(in: settings), .sensitive, "anything else stays")
        item.category = .secret
        XCTAssertEqual(item.category(in: settings), .secret)
        item.userCategory = .general
        XCTAssertEqual(item.category(in: settings), .general, "the user's choice stands")

        var browsed = text("a page")
        browsed.category = .general
        XCTAssertEqual(browsed.category(in: settings), .general)
        browsed.inPrivateWindow = true
        XCTAssertEqual(browsed.category(in: settings), .offensive, "copied in a private window")
    }

    func testAnAppTakesOnlyTheCategoriesItIsExemptFrom() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exempt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("ExemptTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = SettingsStore(url: nil)
        store.value.classifyEntries = false
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: store, engine: engine)
        history.record(text("something"))
        let id = try XCTUnwrap(history.currentItemID)
        store.value.pasteWithoutAsking = ["com.example.chat": [ClipCategory.offensive.rawValue]]

        history.setUserCategory(.offensive, of: [id])
        XCTAssertNil(PasteConfirmation.needed(history, store.value, into: "com.example.chat"), "Private is let through there")
        XCTAssertNotNil(PasteConfirmation.needed(history, store.value, into: "com.example.other"), "not elsewhere")
        history.setUserCategory(.secret, of: [id])
        XCTAssertEqual(PasteConfirmation.needed(history, store.value, into: "com.example.chat")?.1, .secret,
                       "Private exempt does not make Secret exempt")
    }

    /// Sensitive, Private and Secret never reach the disk: a new entry
    /// waits for its category, and one that becomes such loses its file.
    func testOnlyPublicEntriesAreOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keeping-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("KeepingTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = SettingsStore(url: nil)
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: store, engine: engine)
        func onDisk(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".plist").path)
        }
        func classified(_ id: UUID) async {
            for _ in 0..<100 where history.item(id)?.category == nil { try? await Task.sleep(for: .milliseconds(50)) }
        }

        history.record(text("Meeting moved to Thursday."))
        let plain = try XCTUnwrap(history.currentItemID)
        XCTAssertFalse(onDisk(plain), "not before it is classified")
        await classified(plain)
        XCTAssertTrue(onDisk(plain), "Public: written")

        history.record(text("AKIAIOSFODNN7EXAMPLE"))
        let key = try XCTUnwrap(history.currentItemID)
        await classified(key)
        XCTAssertEqual(history.item(key)?.category, .secret)
        XCTAssertFalse(onDisk(key), "Secret: never written")
        XCTAssertNotNil(history.item(key), "but kept while Snippad runs")

        history.setUserCategory(.sensitive, of: [plain])
        XCTAssertFalse(onDisk(plain), "marked Sensitive: its file is deleted")
        history.setUserCategory(.general, of: [plain])
        XCTAssertTrue(onDisk(plain), "Public again: written again")

        store.value.neverPublicApps = ["com.example.chat"]
        var chat = text("see you at 8")
        chat.sourceBundleID = "com.example.chat"
        chat.category = .general
        chat.categoryFrom = chat.classificationKey
        chat.categoryVersion = ClipClassifier.version
        history.record(chat)
        XCTAssertFalse(onDisk(chat.id), "never Public: counts as Private")
        store.value.neverPublicApps = []
        history.reconcileFiles()
        XCTAssertTrue(onDisk(chat.id), "the app no longer never Public: written")
    }

    /// What is made from an entry -- a part copied, its text, entries
    /// joined -- is at least that entry's category; Public passes nothing on.
    func testWhatIsCopiedFromAnEntryInheritsItsCategory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Inherit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("InheritTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = SettingsStore(url: nil)
        store.value.classifyEntries = false
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        engine.recorder = nil
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: store, engine: engine)
        engine.recorder = { [weak history] in history?.recordOwn($0) }
        func onDisk(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".plist").path)
        }

        history.record(text("Szabó László, 1052 Budapest, Váci utca 12."))
        let source = try XCTUnwrap(history.currentItemID)
        history.setUserCategory(.sensitive, of: [source])

        // ⌘C of a part of it, in the Organizer.
        pasteboard.clearContents()
        pasteboard.setString("Váci utca 12.", forType: .string)
        history.captureOwnCopy(list: nil, from: source)
        let part = try XCTUnwrap(history.items.first { $0.string == "Váci utca 12." })
        XCTAssertEqual(part.inheritedCategory, .sensitive)
        XCTAssertEqual(part.category(in: store.value), .sensitive)
        XCTAssertFalse(onDisk(part.id), "Sensitive: not on disk")
        XCTAssertEqual(PasteConfirmation.asksOnExport(part), .sensitive, "and an export of it asks")

        history.record(text("Meeting moved to Thursday."))
        let plain = try XCTUnwrap(history.currentItemID)
        pasteboard.clearContents()
        pasteboard.setString("Thursday", forType: .string)
        history.captureOwnCopy(list: nil, from: plain)
        let fromPlain = try XCTUnwrap(history.items.first { $0.string == "Thursday" })
        XCTAssertNil(fromPlain.inheritedCategory, "Public passes nothing on")
        XCTAssertNil(PasteConfirmation.asksOnExport(fromPlain))

        let joined = try XCTUnwrap(history.copyJoined([plain, source]))
        XCTAssertEqual(joined.inheritedCategory, .sensitive, "joined: the most careful of them")
    }
}

/// Snippets carry a classification: in the file, into the history when
/// copied, and from the entry they were added from.
@MainActor
final class SnippetClassificationTests: XCTestCase {

    func testTheFileKeepsTheClassification() throws {
        let text = """
            [[snippet]]
            name = "IBAN"
            value = "GB82 WEST 1234 5698 7654 32"
            classification = "sensitive"

            [[snippet]]
            name = "Greeting"
            value = "Hello"
            """
        let snippets = try SnippadParser.parse(text)
        XCTAssertEqual(snippets[0].classification, .sensitive)
        XCTAssertNil(snippets[1].classification)
        XCTAssertEqual(try SnippadParser.parse(SnippadWriter.text(for: snippets)).map(\.classification), [.sensitive, nil])
        XCTAssertThrowsError(try SnippadParser.parse("[[snippet]]\nname = \"x\"\nvalue = \"y\"\nclassification = \"top secret\"\n"))
    }

    func testACopiedSnippetIsAtLeastItsClassification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnippetClass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("SnippetClassTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = SettingsStore(url: nil)
        store.value.classifyEntries = false
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: store, engine: engine)
        engine.recorder = { [weak history] in history?.recordOwn($0) }

        var snippet = Snippet(id: 0, name: "Home", value: "1052 Budapest, Váci utca 12.")
        snippet.classification = .sensitive
        engine.put(snippet.value, name: snippet.name, rules: snippet.rules(in: [snippet]))
        let entry = try XCTUnwrap(history.currentItemID.flatMap(history.item))
        XCTAssertEqual(entry.category(in: store.value), .sensitive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id.uuidString + ".plist").path))
    }
}
