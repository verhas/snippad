import AppKit
import XCTest
@testable import Snippad

final class SettingsAndGuardTests: XCTestCase {

    func testSettingsFileFillsGapsWithDefaults() throws {
        let s = try JSONDecoder().decode(SnippadSettings.self, from: Data(#"{"historyLimit": 20, "appLists": {"a.b": "gone"}}"#.utf8))
        XCTAssertEqual(s.historyLimit, 20)
        XCTAssertTrue(s.recordHistory)
        XCTAssertEqual(s.lists.map(\.id), [ClipList.defaultID])
        XCTAssertTrue(s.appLists.isEmpty, "a list that does not exist is forgotten")
    }

    func testNewSettingsHaveDefaultsAndRoundTrip() throws {
        let old = try SnippadHome.decoder.decode(SnippadSettings.self, from: Data("{\"lists\":[{\"id\":\"x\",\"name\":\"X\"}]}".utf8))
        XCTAssertTrue(old.wordWrap)
        XCTAssertEqual(old.toolbarDisplayMode, 1)
        XCTAssertTrue(old.pickerHotKeyEnabled)
        XCTAssertNil(old.preferredList)
        XCTAssertNil(old.lists[1].icon)
        XCTAssertEqual(old.lists[1].symbol, "tray")
        var s = old
        s.wordWrap = false
        s.preferredList = "x"
        s.lists[1].icon = "key"
        s.openSnippadFiles = ["/tmp/a.snippad"]
        let back = try SnippadHome.decoder.decode(SnippadSettings.self, from: SnippadHome.encoder.encode(s))
        XCTAssertEqual(back, s)
    }

    func testSettingsRoundTripThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try MainActor.assumeIsolated {
            let store = SettingsStore(url: url)
            let list = store.addList(named: "Private")
            store.value.privateBrowsingList = list.id
            store.setExcluded("com.example.secret", true)
            let again = SettingsStore(url: url)
            XCTAssertEqual(again.value, store.value)
            let json = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(json.contains("\"excludedApps\""))
        }
    }

    private let list = ClipList(id: "p", name: "Private")

    private func verdict(_ list: ClipList, _ app: String, browser: Bool = false,
                         privacy: BrowserPrivacy.State = .normalWindow) -> PasteGuard.Verdict {
        PasteGuard.verdict(list: list, bundleID: app, appName: app, isBrowser: browser) { privacy }
    }

    func testAllowAndDenyLists() {
        var l = list
        XCTAssertEqual(verdict(l, "x"), .allow)
        l.guardMode = .onlyListed
        l.guardApps = ["ok"]
        XCTAssertEqual(verdict(l, "ok"), .allow)
        XCTAssertNotEqual(verdict(l, "other"), .allow)
        l.guardMode = .allExceptListed
        XCTAssertNotEqual(verdict(l, "ok"), .allow)
        XCTAssertEqual(verdict(l, "other"), .allow)
    }

    func testPrivateBrowsingOnly() {
        var l = list
        l.privateBrowsingOnly = true
        XCTAssertEqual(verdict(l, "chrome", browser: true, privacy: .privateWindow), .allow)
        XCTAssertNotEqual(verdict(l, "chrome", browser: true, privacy: .normalWindow), .allow)
        XCTAssertNotEqual(verdict(l, "safari", browser: true, privacy: .unknown), .allow, "unknown counts as not private")
        XCTAssertEqual(verdict(l, "textedit"), .allow, "apps that are not browsers follow the app rules only")
        var asked = false
        _ = PasteGuard.verdict(list: list, bundleID: "chrome", appName: "Chrome", isBrowser: true) { asked = true; return .unknown }
        XCTAssertFalse(asked, "the browser is only asked when the list needs it")
    }

    func testWhichListsAreRestricted() {
        var l = ClipList(name: "x")
        XCTAssertFalse(l.isRestricted)
        l.guardMode = .allExceptListed
        XCTAssertFalse(l.isRestricted, "a deny list with nobody on it stops nothing")
        l.guardApps = ["a"]
        XCTAssertTrue(l.isRestricted)
        l = ClipList(name: "y", guardMode: .onlyListed)
        XCTAssertTrue(l.isRestricted, "an empty allow list stops everything")
        l = ClipList(name: "z", privateBrowsingOnly: true)
        XCTAssertTrue(l.isRestricted)
    }

    @MainActor
    func testTheGuardNeedsTheTapOnlyForRestrictedContent() throws {
        let settings = SettingsStore(url: nil)
        let pasteboard = NSPasteboard(name: .init("SnippadGuardTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Guard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = ClipboardHistory(directory: dir, pasteboard: pasteboard, settings: settings, engine: engine)
        var changes = 0
        history.onCurrentChange = { changes += 1 }

        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        var secret = settings.addList(named: "Secret")
        secret.privateBrowsingOnly = true
        settings.value.lists[1] = secret
        settings.value.appLists[front] = secret.id

        func copy(_ s: String) {
            pasteboard.clearContents()
            pasteboard.setString(s, forType: .string)
            history.poll()
        }

        copy("from the restricted app")
        XCTAssertNil(PasteInterceptor.guardedList(settings, history), "the guard is off")
        settings.value.pasteGuardEnabled = true
        XCTAssertEqual(PasteInterceptor.guardedList(settings, history)?.id, secret.id)

        // The same app's copies go elsewhere now: not controlled, no tap.
        settings.value.appLists[front] = nil
        copy("ordinary")
        XCTAssertNil(PasteInterceptor.guardedList(settings, history))

        // Moving the clipboard's entry into the restricted list needs it again.
        history.move(history.currentItemID!, toList: secret.id)
        XCTAssertEqual(PasteInterceptor.guardedList(settings, history)?.id, secret.id)
        XCTAssertGreaterThanOrEqual(changes, 3, "each change tells the tap")
    }

    @MainActor
    func testGoneApplicationsAreForgottenOrMarked() throws {
        let settings = SettingsStore(url: nil)
        let catalog = AppCatalog(url: nil)
        let plain = "com.example.gone.\(UUID().uuidString)"
        let excluded = "com.example.excluded.\(UUID().uuidString)"
        let guarded = "com.example.guarded.\(UUID().uuidString)"
        let present = "com.example.present.\(UUID().uuidString)"
        for id in [plain, excluded, guarded] {
            catalog.set(AppRecord(bundleID: id, name: id, path: "/Applications/Nowhere-\(UUID()).app", copies: 3))
        }
        catalog.set(AppRecord(bundleID: present, name: "Present", path: "/System/Applications/TextEdit.app"))
        settings.setExcluded(excluded, true)
        var list = settings.addList(named: "L")
        list.guardMode = .onlyListed
        list.guardApps = [guarded]
        settings.value.lists[1] = list

        catalog.reconcile(with: settings)
        XCTAssertNil(catalog.apps[plain], "no setting names it: forgotten")
        XCTAssertEqual(catalog.apps[excluded]?.missing, true)
        XCTAssertEqual(catalog.apps[guarded]?.missing, true)
        XCTAssertNil(catalog.apps[present]?.missing)

        XCTAssertThrowsError(try catalog.locate(guarded, at: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
                             "TextEdit is a different application")
        catalog.remove(guarded, settings: settings)
        XCTAssertNil(catalog.apps[guarded])
        XCTAssertTrue(settings.value.lists[1].guardApps.isEmpty, "its settings went with it")
        XCTAssertFalse(settings.mentions(guarded))

        let textEdit = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))?.bundleIdentifier)
        catalog.set(AppRecord(bundleID: textEdit, name: "TextEdit", path: "/Old/TextEdit.app", missing: true))
        try catalog.locate(textEdit, at: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        XCTAssertNil(catalog.apps[textEdit]?.missing)
        XCTAssertEqual(catalog.apps[textEdit]?.path, "/System/Applications/TextEdit.app")
    }

    func testHistoryDragRoundTrips() throws {
        let drag = HistoryDrag(ids: [UUID(), UUID()])
        XCTAssertEqual(try JSONDecoder().decode(HistoryDrag.self, from: JSONEncoder().encode(drag)).ids, drag.ids)
    }

    @MainActor func testAllowedListsFollowTheGuard() {
        var s = SnippadSettings()
        s.lists.append(ClipList(id: "x", name: "X", guardMode: .onlyListed, guardApps: ["com.example.only"]))
        let me = NSRunningApplication.current
        XCTAssertEqual(PasteGuard.allowedLists(into: nil, settings: s), [ClipList.defaultID, "x"], "guard off: everything")
        s.pasteGuardEnabled = true
        XCTAssertEqual(PasteGuard.allowedLists(into: me, settings: s), [ClipList.defaultID, "x"], "Snippad itself is not guarded")
        let other = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }
        if let other {
            XCTAssertEqual(PasteGuard.allowedLists(into: other, settings: s), [ClipList.defaultID])
        }
    }
}
