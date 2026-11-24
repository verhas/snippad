import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snippad

@MainActor
final class ClipboardHistoryTests: XCTestCase {

    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var settings: SettingsStore!
    private var engine: PasteEngine!
    private var history: ClipboardHistory!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("History-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("SnippadHistoryTests-\(UUID().uuidString)"))
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

    private func copy(_ s: String, marker: NSPasteboard.PasteboardType? = nil) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        if let marker { item.setData(Data(), forType: marker) }
        pasteboard.writeObjects([item])
        history.poll()
    }

    private func copyFiles(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        history.poll()
    }

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testRecordsNewestFirstAndDeduplicates() {
        copy("one")
        copy("two")
        copy("one")
        XCTAssertEqual(history.items.map(\.string), ["one", "two"])
        XCTAssertEqual(history.currentItemID, history.items[0].id)
    }

    func testSkipsConcealedAndTransientFromOtherApps() {
        copy("password", marker: .concealed)
        copy("temp", marker: .transient)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testPausedRecordsNothing() {
        history.isCapturing = false
        copy("x")
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertFalse(settings.value.recordHistory)
    }

    func testExcludedAppsAreNotRecorded() throws {
        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        settings.setExcluded(front, true)
        copy("from an excluded app")
        XCTAssertTrue(history.items.isEmpty)
        settings.setExcluded(front, false)
        copy("recorded again")
        XCTAssertEqual(history.items.count, 1)
    }

    func testCopiesGoToTheAppsList() throws {
        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let work = settings.addList(named: "Work")
        settings.value.appLists[front] = work.id
        copy("work text")
        XCTAssertEqual(history.items.first?.list, work.id)
        XCTAssertEqual(history.currentList.id, work.id)
    }

    func testWhatSnippadCopiesIsRecordedAlsoChainedAndPasswords() {
        let snippets = [
            Snippet(id: 0, name: "user", value: "alice", next: "pw"),
            Snippet(id: 1, name: "pw", value: "hunter2", once: true, password: true),
        ]
        engine.put("alice", name: "user", rules: snippets[0].rules(in: snippets))
        engine.put("hunter2", name: "pw", rules: snippets[1].rules(in: snippets))
        history.poll()  // Snippad's own writes are not recorded twice
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items[1].string, "alice")
        let pw = history.items[0]
        XCTAssertTrue(pw.isPassword)
        XCTAssertEqual(pw.title, "pw: ••••••••")
        XCTAssertTrue(history.search("hunter").isEmpty, "a password's value is not searchable")
        XCTAssertEqual(history.search("pw").count, 1)
        XCTAssertTrue(pasteboard.types?.contains(.concealed) ?? false)
    }

    func testImagesAndFilesAreRecognised() throws {
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        history.poll()
        XCTAssertEqual(history.items.first?.kind, .image)
        XCTAssertNotNil(history.items.first?.pngData)

        copyFiles([URL(fileURLWithPath: "/etc/hosts")])
        XCTAssertEqual(history.items.first?.kind, .files)
        XCTAssertEqual(history.items.first?.title, "hosts")
    }

    func testEXIFOfCopiedImageFilesIsSearchable() throws {
        let url = directory.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Snippad Test Lens 50mm"],
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Snippadcam X1"]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        copyFiles([url])
        XCTAssertEqual(history.search("Test Lens").map(\.id), [history.items[0].id])
        XCTAssertEqual(history.search("snippadcam").count, 1)
    }

    func testSubsetOfFilesBecomesANewEntry() throws {
        let urls = [URL(fileURLWithPath: "/etc/hosts"), URL(fileURLWithPath: "/etc/shells"), URL(fileURLWithPath: "/etc/passwd")]
        copyFiles(urls)
        let all = history.items[0]
        XCTAssertEqual(all.fileURLs.count, 3)
        try history.copyFiles(all.id, only: [urls[0], urls[2]])
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items[0].fileURLs.map(\.path), ["/etc/hosts", "/etc/passwd"])
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self])?.count, 2)
        XCTAssertThrowsError(try history.copyFiles(all.id, only: []))
    }

    func testVanishedFilesKeepOnlyTheirNamesAndPaths() throws {
        let kept = try tempFile("kept.txt", Data("a".utf8))
        let doomed = try tempFile("doomed.txt", Data("b".utf8))
        settings.value.lists.append(ClipList(id: "work", name: "Work"))
        copyFiles([kept, doomed])
        let entry = history.items[0]
        history.move(entry.id, toList: "work")
        XCTAssertFalse(entry.filesGone)
        XCTAssertEqual(entry.missingFiles, [])

        try history.copyFileText(of: entry.id, .names)
        XCTAssertEqual(pasteboard.string(forType: .string), "kept.txt\ndoomed.txt")
        XCTAssertEqual(history.items[0].list, "work", "the text joins the files' list")

        try FileManager.default.removeItem(at: doomed)
        let partly = try XCTUnwrap(history.item(entry.id))
        XCTAssertEqual(partly.missingFiles.map(\.lastPathComponent), ["doomed.txt"])
        XCTAssertFalse(partly.filesGone)
        XCTAssertThrowsError(try history.copyFiles(entry.id, only: [doomed]))

        try FileManager.default.removeItem(at: kept)
        XCTAssertTrue(try XCTUnwrap(history.item(entry.id)).filesGone)
        let before = pasteboard.changeCount
        history.copy(entry.id)
        XCTAssertEqual(pasteboard.changeCount, before, "vanished files are not put on the clipboard")

        try history.copyFileText(of: entry.id, .paths)
        XCTAssertEqual(pasteboard.string(forType: .string), [kept.path, doomed.path].joined(separator: "\n"))
        XCTAssertThrowsError(try history.copyFileText(of: history.items[0].id, .names), "a text entry has no files")
    }

    func testSnippetListNamesTheEntrysList() {
        settings.value.lists.append(ClipList(id: "w", name: "Work"))
        engine.put("secret", name: "Token", rules: PasteRules(password: true, list: "work"))
        XCTAssertEqual(history.items[0].list, "w", "found by name, case-insensitively")
        XCTAssertTrue(history.items[0].isPassword)
        engine.put("plain", name: "Other", rules: PasteRules(list: "No Such List"))
        XCTAssertEqual(history.items[0].list, ClipList.defaultID)
    }

    func testCopyingPartOfAnEntryStaysInItsList() {
        settings.value.lists.append(ClipList(id: "p", name: "Private", guardMode: .onlyListed))
        pasteboard.clearContents()
        pasteboard.setString("part of it", forType: .string)
        history.captureOwnCopy(list: "p", password: true)
        XCTAssertEqual(history.items[0].string, "part of it")
        XCTAssertEqual(history.items[0].list, "p")
        XCTAssertTrue(history.items[0].isPassword)
        XCTAssertEqual(history.currentList.id, "p", "the Paste Guard sees the restricted list")
        history.poll()
        XCTAssertEqual(history.items.count, 1, "not recorded a second time by the poll")

        settings.value.recordHistory = false
        pasteboard.clearContents()
        pasteboard.setString("while paused", forType: .string)
        history.captureOwnCopy(list: "p")
        XCTAssertEqual(history.currentList.id, "p", "the list applies even while recording is paused")
    }

    func testPasteFormsKeepTheEntryOfRecord() throws {
        let rich = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(rtf, forType: .rtf)
        item.setData(Data("x".utf8), forType: NSPasteboard.PasteboardType("com.example.private"))
        pasteboard.writeObjects([item])
        history.poll()
        let entry = history.items[0]
        XCTAssertTrue(history.hasRichText(entry.id))

        let privateType = NSPasteboard.PasteboardType("com.example.private")
        history.put(entry.id, as: .main)
        XCTAssertTrue(pasteboard.types?.contains(.rtf) == true)
        XCTAssertFalse(pasteboard.types?.contains(privateType) == true, "only the main form")
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.currentItemID, entry.id)

        history.put(entry.id, as: .original)
        XCTAssertTrue(pasteboard.types?.contains(privateType) == true)

        copy("plain")
        XCTAssertFalse(history.hasRichText(history.items[0].id))
        history.put(history.items[0].id, as: .main)
        XCTAssertFalse(pasteboard.types?.contains(.rtf) == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
    }

    func testRemovingAListMovesOrDeletesItsEntries() {
        settings.value.lists.append(ClipList(id: "a", name: "A"))
        settings.value.lists.append(ClipList(id: "b", name: "B"))
        copy("one"); history.move(history.items[0].id, toList: "a")
        copy("two"); history.move(history.items[0].id, toList: "b")
        settings.value.preferredList = "a"
        history.removeList("a", moveTo: "b")
        XCTAssertEqual(history.items.map(\.list), ["b", "b"])
        XCTAssertNil(settings.value.preferredList, "a preferred list that is gone falls back to all lists")
        history.removeList("b", moveTo: nil)
        XCTAssertTrue(history.items.isEmpty)
        history.removeList(ClipList.defaultID, moveTo: nil)
        XCTAssertEqual(settings.value.lists.map(\.id), [ClipList.defaultID])
    }

    func testTextOfAQRCodeImageIsExtracted() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/snippad".utf8), forKey: "inputMessage")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: qr)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        history.poll()
        XCTAssertEqual(history.items[0].kind, .image)
        let made = try history.extractTextNow(from: history.items[0].id)
        XCTAssertEqual(made?.string, "https://example.com/snippad")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/snippad")
    }

    func testNothingIsPutForVanishedFilesSoNothingStaleIsPasted() throws {
        engine.put("hunter2", name: "pw", rules: PasteRules(password: true))
        let doomed = try tempFile("gone.txt", Data("x".utf8))
        copyFiles([doomed])
        let files = history.items[0]
        engine.put("hunter2", name: "pw", rules: PasteRules(password: true))
        try FileManager.default.removeItem(at: doomed)
        let before = pasteboard.changeCount
        XCTAssertFalse(history.copy(files.id))
        XCTAssertFalse(history.put(files.id, as: .main))
        XCTAssertFalse(history.put(files.id, as: .original))
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    func testDeletingThePasswordOnTheClipboardClearsIt() {
        engine.put("hunter2", name: "pw", rules: PasteRules(password: true))
        let pw = history.items[0]
        XCTAssertTrue(pw.isPassword)
        history.delete(pw.id)
        XCTAssertNil(pasteboard.string(forType: .string), "a deleted password is not left to be pasted")

        copy("ordinary")
        history.delete(history.items[0].id)
        XCTAssertEqual(pasteboard.string(forType: .string), "ordinary", "other entries stay on the clipboard")
    }

    func testAChainOfAFileThenTextPutsTheFileFirst() {
        let snippets = [Snippet(id: 0, name: "f", value: "/etc/hosts", next: "t", kind: .file),
                        Snippet(id: 1, name: "t", value: "after")]
        engine.put(types: snippets[0].pasteboardTypes, name: "f", rules: snippets[0].rules(in: snippets))
        XCTAssertEqual(history.items[0].kind, .files)
        XCTAssertEqual(history.items[0].fileURLs.map(\.path), ["/etc/hosts"])
        XCTAssertNotNil(snippets[0].rules(in: snippets).next?()?.types[NSPasteboard.PasteboardType.string.rawValue])
    }

    func testConvertingRichTextToPlainText() throws {
        let rich = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: 4), documentAttributes: [:])), forType: .rtf)
        pasteboard.writeObjects([item])
        history.poll()
        XCTAssertEqual(history.items[0].kind, .richText)
        history.convertToPlainText(history.items[0].id)
        XCTAssertEqual(history.items[0].kind, .text)
        XCTAssertEqual(history.items[0].string, "bold")
    }

    func testPendingEntryBecomesTheText() {
        settings.value.lists.append(ClipList(id: "w", name: "Work"))
        let id = history.insertPending(label: "Image", list: "w")
        XCTAssertEqual(history.items[0].pending, true)
        XCTAssertTrue(history.items[0].title.hasPrefix("Reading text"))
        XCTAssertFalse(history.copy(id), "nothing to put on the clipboard yet")
        let made = history.finishPending(id, text: "found", name: "Text from Image")
        XCTAssertEqual(made?.id, id)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items[0].string, "found")
        XCTAssertEqual(history.items[0].list, "w")
        XCTAssertNil(history.items[0].pending)
        XCTAssertEqual(pasteboard.string(forType: .string), "found")

        let other = history.insertPending(label: "Image", list: "w")
        history.dropPending(other)
        XCTAssertEqual(history.items.count, 1)
    }

    func testExportFormats() throws {
        copy("line one\nline \"two\" <&>")
        engine.put("hunter2", name: "pw", rules: PasteRules(password: true))
        let records = ListExport.records(history.items, settings: settings)
        let json = ListExport.text(records, as: .json, listName: "Clipboard")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(parsed["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0]["text"], "a password value is not exported")
        XCTAssertEqual(entries[0]["password"] as? Bool, true)
        XCTAssertEqual(entries[1]["text"] as? String, "line one\nline \"two\" <&>")

        let toml = ListExport.text(records, as: .toml, listName: "Clipboard")
        XCTAssertTrue(toml.contains("[[entry]]"))
        XCTAssertFalse(toml.contains("hunter2"))
        let xml = ListExport.text(records, as: .xml, listName: "Clipboard")
        XCTAssertTrue(xml.contains("&lt;&amp;&gt;"))
        XCTAssertNotNil(try XMLDocument(xmlString: xml))
        let yaml = ListExport.text(records, as: .yaml, listName: "Clipboard")
        XCTAssertTrue(yaml.contains("  - date: "))
        XCTAssertTrue(yaml.contains("text: \"line one\\nline \\\"two\\\" <&>\""))
    }

    private func copyFromPhone(_ text: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .remoteClipboard)
        item.setData(Data("x".utf8), forType: .uikitAttributedString)
        pasteboard.writeObjects([item])
        history.poll()
    }

    func testCopiesFromOtherDevicesGetOneListAfterAskingOnce() {
        var asked = 0
        var pending: (@MainActor (String?) -> Void)?
        history.askForRemoteList = { answer in asked += 1; pending = answer }
        copyFromPhone("one")
        XCTAssertEqual(history.items[0].sourceApp, "iPhone or iPad")
        XCTAssertNil(history.items[0].sourceBundleID, "not the app in front on the Mac")
        XCTAssertFalse(pasteboard.types?.contains(.remoteClipboard) == true, "put back as the Mac's own copy")
        XCTAssertEqual(pasteboard.string(forType: .string), "one")
        copyFromPhone("two")
        XCTAssertEqual(asked, 1, "one question, however many copies arrive meanwhile")

        pending?("Phones")
        let list = try? XCTUnwrap(settings.value.lists.first { $0.name == "Phones" })
        XCTAssertEqual(settings.value.remoteList, list?.id)
        XCTAssertEqual(list?.icon, "iphone")
        XCTAssertEqual(Set(history.items.map(\.list)), [list?.id])

        copyFromPhone("three")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(history.items[0].list, list?.id)
        XCTAssertEqual(history.currentList.id, list?.id, "the list's Paste Guard rules apply")
    }

    func testOptingOutOfTheDeviceListAndOfPuttingBack() {
        var asked = 0
        history.askForRemoteList = { answer in asked += 1; answer(nil) }
        settings.value.remoteToLocal = false
        copyFromPhone("one")
        XCTAssertTrue(settings.value.remoteListOptOut)
        XCTAssertEqual(history.items[0].list, ClipList.defaultID)
        XCTAssertTrue(pasteboard.types?.contains(.remoteClipboard) == true, "left as it came")
        copyFromPhone("two")
        XCTAssertEqual(asked, 1, "not asked again after opting out")
    }

    func testScreenshotsGoToTheirListAndTheClipboard() throws {
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        history.addScreenshot(png, label: "Screenshot of a window")
        XCTAssertEqual(history.items[0].kind, .image)
        XCTAssertEqual(history.items[0].list, ClipList.defaultID, "the first list unless another is chosen")
        XCTAssertEqual(pasteboard.data(forType: .png), png)

        settings.value.lists.append(ClipList(id: "shots", name: "Shots"))
        settings.value.screenshotList = "shots"
        settings.value.screenshotDelay = 15
        XCTAssertEqual(settings.value.screenshotDelay, 10, "only 10, 20, 30 or 60 seconds")
        copy("between")
        history.addScreenshot(png, label: "Screenshot again")
        XCTAssertEqual(history.items[0].list, "shots", "the same picture moves to the screenshot list")
        XCTAssertEqual(history.items.count, 2)
    }

    func testFileContentsBecomeTextOrImageOrAnError() throws {
        let text = try tempFile("notes.md", Data("# hello\nworld\n".utf8))
        let png = try tempFile("dot.png", NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                                 .representation(using: .png, properties: [:])!)
        let binary = try tempFile("blob.bin", Data([0, 1, 2, 0, 255]))

        try history.copyFileContents([text])
        XCTAssertEqual(pasteboard.string(forType: .string), "# hello\nworld\n")
        XCTAssertEqual(history.items[0].kind, .text)

        try history.copyFileContents([png])
        XCTAssertEqual(history.items[0].kind, .image)
        XCTAssertNotNil(pasteboard.data(forType: .png))

        XCTAssertThrowsError(try history.copyFileContents([binary, text])) { error in
            XCTAssertTrue(error.localizedDescription.contains("blob.bin"))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "# hello\nworld\n", "the readable file still went on the clipboard")
        XCTAssertThrowsError(try history.copyFileContents([directory]))
    }

    func testEditingTextChangesTheEntryAndTheClipboard() throws {
        copy("first draft")
        let id = history.items[0].id
        history.updateText(id, plain: "second draft")
        XCTAssertEqual(history.item(id)?.string, "second draft")
        XCTAssertNotNil(history.item(id)?.edited)
        XCTAssertEqual(pasteboard.string(forType: .string), "second draft", "it is what is on the clipboard")
        history.flush()

        let reloaded = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        XCTAssertEqual(reloaded.item(id)?.string, "second draft")

        copy("something else")
        history.updateText(id, plain: "third draft")
        XCTAssertEqual(pasteboard.string(forType: .string), "something else", "not on the clipboard any more")
    }

    func testRichTextEditKeepsFormatting() throws {
        let rich = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        copy("x")
        history.updateText(history.items[0].id, plain: "bold", rich: rich)
        XCTAssertEqual(history.items[0].kind, .richText)
        XCTAssertEqual(history.items[0].attributedString?.string, "bold")
    }

    func testListsMovesPinsAndPerListTrimming() {
        let work = settings.addList(named: "Work")
        copy("keep")
        history.setPinned(history.items[0].id, true)
        history.limit = 2
        for s in ["a", "b", "c"] { copy(s) }
        XCTAssertEqual(history.items.map(\.string), ["c", "b", "keep"])

        history.move(history.items[0].id, toList: work.id)
        for s in ["d", "e"] { copy(s) }
        XCTAssertEqual(Set(history.items.map { $0.string! }), ["e", "d", "c", "keep"], "Work has its own limit")
        XCTAssertEqual(history.search("", list: work.id).map(\.string), ["c"])

        history.clear(list: ClipList.defaultID)
        XCTAssertEqual(Set(history.items.map { $0.string! }), ["c", "keep"])
        history.listRemoved(work.id)
        XCTAssertEqual(history.items.first { $0.string == "c" }?.list, ClipList.defaultID)
    }

    func testPersists() {
        copy("one")
        let reloaded = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        XCTAssertEqual(reloaded.items.map(\.string), ["one"])
    }

    func testSearch() {
        copy("Hello world")
        copy("other")
        XCTAssertEqual(history.search("WORLD").map(\.string), ["Hello world"])
    }
}
