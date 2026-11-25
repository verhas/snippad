import AppKit
import XCTest
@testable import Snippad

/// The history menu must open at once: what it learns about its entries it
/// learns without waiting on WebKit, and from the disk on all cores.
final class StatusMenuFactsTests: XCTestCase {

    func testHTMLIsFormattingWithoutBeingRead() {
        let html = ClipItem(items: [[NSPasteboard.PasteboardType.html.rawValue: Data("<b>Hi</b>".utf8),
                                     NSPasteboard.PasteboardType.string.rawValue: Data("Hi".utf8)]])
        XCTAssertTrue(html.hasFormatting)
        XCTAssertNil(html.attributedStringWithoutWebKit, "HTML is left to WebKit, when asked for")
        let plain = ClipItem(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("Hi".utf8)]])
        XCTAssertFalse(plain.hasFormatting)
    }

    func testFactsGatheredTogetherAreTheFactsOfEach() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = folder.appendingPathComponent("here.png")
        try Data([1]).write(to: here)
        let gone = folder.appendingPathComponent("gone.png")
        func files(_ urls: [URL]) -> ClipItem {
            ClipItem(items: urls.map { [NSPasteboard.PasteboardType.fileURL.rawValue: $0.dataRepresentation] })
        }
        let items = [files([here]), files([gone]), files([here, gone]),
                     ClipItem(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("x".utf8)]])]
        let facts = EntryFacts.gather(items)
        XCTAssertEqual(facts.count, items.count)
        for item in items {
            let f = try XCTUnwrap(facts[item.id])
            XCTAssertEqual(f.gone, item.filesGone)
            XCTAssertEqual(f.missing, Set(item.missingFiles))
            XCTAssertEqual(f.imageForText, item.hasImageForText)
            XCTAssertEqual(f.snippet, item.canBecomeSnippet)
        }
    }
}

/// Text in images is read in the Mac's languages that Vision knows.
final class ReadingLanguagesTests: XCTestCase {

    func testTheMacsLanguagesAreMatchedToVisionsByLanguage() {
        XCTAssertEqual(TextRecognition.preferredLanguages(["en-GB", "en-CH", "hu"]), ["en-US"],
                       "English once, whatever the region; Hungarian is not read")
        XCTAssertEqual(TextRecognition.preferredLanguages(["de-AT", "fr", "en-US"]), ["de-DE", "fr-FR", "en-US"])
        XCTAssertEqual(TextRecognition.preferredLanguages(["hu"]), [])
    }

    func testOtherLanguagesMeanReadingAgain() {
        var item = ClipItem(items: [[NSPasteboard.PasteboardType.png.rawValue: Data([1, 2, 3])]])
        XCTAssertTrue(item.needsTextReading(in: ["en-US"]))
        item.readText = "x"
        item.readTextFrom = item.digest
        item.readTextLanguages = []
        XCTAssertFalse(item.needsTextReading(in: nil), "read with the language guessed, and still guessed")
        XCTAssertTrue(item.needsTextReading(in: ["en-US"]), "now read in English")
        XCTAssertEqual(item.textOfImage, "x", "the old text serves until then")
    }
}

/// HTML goes through WebKit, which once kept Snippad waiting for good: it
/// is converted in the background, never read on the main thread.
@MainActor
final class HTMLConversionTests: XCTestCase {

    func testHTMLIsNotReadOnTheMainThreadButConvertedInTheBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HTML-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("HTMLConversionTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = SettingsStore(url: nil)
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)

        let item = ClipItem(items: [[NSPasteboard.PasteboardType.html.rawValue: Data("<p>Hello <b>bold</b></p>".utf8),
                                     NSPasteboard.PasteboardType.string.rawValue: Data("Hello bold".utf8)]])
        XCTAssertNil(item.attributedString, "not on the main thread")
        XCTAssertTrue(item.needsHTMLConversion)
        history.record(item)
        let id = try XCTUnwrap(history.currentItemID)
        var converted: NSAttributedString?
        for _ in 0..<300 where converted == nil {
            converted = history.item(id)?.attributedString
            if converted == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(converted?.string.trimmingCharacters(in: .whitespacesAndNewlines), "Hello bold")
        XCTAssertFalse(try XCTUnwrap(history.item(id)).needsHTMLConversion)
    }
}
