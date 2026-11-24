import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Whether the front window of a web browser is a private (incognito) one.
///
/// Browsers do not tell this the same way. Chromium browsers (Chrome, Brave,
/// Edge, Vivaldi, Chromium) answer an AppleScript question, which macOS lets
/// through after asking the user once per browser (Automation permission).
/// Firefox and its relatives put "Private Browsing" in the window title,
/// read through Accessibility. Tor Browser is always private. Safari offers
/// neither, so its windows are `unknown`.
enum BrowserPrivacy {
    enum State: Equatable { case privateWindow, normalWindow, unknown }

    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]
    static let firefox: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "net.waterfox.waterfox", "io.gitlab.librewolf-community", "app.zen-browser.zen",
    ]
    static let alwaysPrivate: Set<String> = ["org.torproject.torbrowser"]

    /// Every app that can open web pages, asked of LaunchServices once.
    @MainActor private static let webApps: Set<String> = {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        return Set(urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    @MainActor
    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return chromium.contains(id) || firefox.contains(id) || alwaysPrivate.contains(id) || webApps.contains(id)
    }

    @MainActor
    static func state(of app: NSRunningApplication) -> State {
        guard let id = app.bundleIdentifier else { return .unknown }
        if alwaysPrivate.contains(id) { return .privateWindow }
        if chromium.contains(id) {
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application id \"\(id)\" to return mode of front window")
            guard let mode = script?.executeAndReturnError(&error).stringValue else { return .unknown }
            return mode == "incognito" ? .privateWindow : .normalWindow
        }
        if firefox.contains(id) {
            guard let title = focusedWindowTitle(of: app.processIdentifier) else { return .unknown }
            return title.localizedCaseInsensitiveContains("Private Browsing") ? .privateWindow : .normalWindow
        }
        return .unknown
    }

    private static func focusedWindowTitle(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

/// Decides whether the clipboard's content may be pasted into an app,
/// following the rules of the list the content belongs to.
enum PasteGuard {
    /// Which lists may be pasted into an app, for showing only what can be
    /// pasted there. Everything, while the Paste Guard is off. A browser is
    /// asked about its window at most once.
    @MainActor
    static func allowedLists(into app: NSRunningApplication?, settings: SnippadSettings) -> Set<String> {
        let all = Set(settings.lists.map(\.id))
        guard settings.pasteGuardEnabled, let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return all }
        var privacy: BrowserPrivacy.State?
        let isBrowser = BrowserPrivacy.isBrowser(app.bundleIdentifier)
        return Set(settings.lists.filter { list in
            verdict(list: list, bundleID: app.bundleIdentifier, appName: app.localizedName ?? "this app", isBrowser: isBrowser) {
                if privacy == nil { privacy = BrowserPrivacy.state(of: app) }
                return privacy!
            } == .allow
        }.map(\.id))
    }

    enum Verdict: Equatable {
        case allow
        case deny(String)
    }

    /// `privacy` is asked only when the answer depends on it.
    static func verdict(list: ClipList, bundleID: String?, appName: String, isBrowser: Bool,
                        privacy: () -> BrowserPrivacy.State) -> Verdict {
        let id = bundleID ?? ""
        switch list.guardMode {
        case .anyApp:
            break
        case .onlyListed:
            if !list.guardApps.contains(id) {
                return .deny("\u{201C}\(list.name)\u{201D} can only be pasted into the apps it allows, and \(appName) is not one of them.")
            }
        case .allExceptListed:
            if list.guardApps.contains(id) {
                return .deny("\u{201C}\(list.name)\u{201D} cannot be pasted into \(appName).")
            }
        }
        if list.privateBrowsingOnly && isBrowser {
            switch privacy() {
            case .privateWindow: break
            case .normalWindow:
                return .deny("\u{201C}\(list.name)\u{201D} can only be pasted into private browser windows.")
            case .unknown:
                return .deny("\u{201C}\(list.name)\u{201D} can only be pasted into private browser windows, and \(appName) does not say whether this one is private.")
            }
        }
        return .allow
    }
}

/// Whether Snippad's keyboard tap is installed, and why, for the menu and
/// the settings.
@MainActor
@Observable
final class KeyboardTapStatus {
    static let shared = KeyboardTapStatus()
    /// The tap is installed.
    var active = false
    /// The tap is wanted, but Accessibility is not allowed.
    var blocked = false
    /// What it is installed for, e.g. "the Paste Guard".
    var reason = ""
}

/// Watches ⌘V (and ⇧⌘V, ⌥⇧⌘V) in every app through a keyboard event tap --
/// but only while something needs it:
///
/// - the Paste Guard is on and the clipboard's content belongs to a list
///   with paste restrictions, or
/// - a paste-once or chained value is waiting on the clipboard.
///
/// The rest of the time no tap exists. The Accessibility permission is
/// granted once in System Settings; installing and removing the tap after
/// that asks nothing. While installed, it tells PasteEngine about the paste,
/// and, with the Paste Guard on, swallows the keystroke if the clipboard's
/// list does not allow pasting into the app in front.
@MainActor
enum PasteInterceptor {
    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    private static var localMonitor: Any?
    private static var waitTimer: Timer?
    /// Marks the ⌘V Snippad sends itself, so the tap lets it through.
    nonisolated static let marker: Int64 = 0x534E_5044

    static var isTrusted: Bool { AXIsProcessTrusted() }
    static var isRunning: Bool { tap != nil }

    /// What the tap is needed for now; empty when it is not.
    static var neededFor: [String] {
        var reasons: [String] = []
        if let list = guardedList(SettingsStore.shared, ClipboardHistory.shared) {
            reasons.append("the Paste Guard (\u{201C}\(list.name)\u{201D} is on the clipboard)")
        }
        if PasteEngine.shared.awaitsPaste {
            reasons.append(PasteEngine.shared.current?.rules.next != nil ? "a chained value" : "a paste-once value")
        }
        return reasons
    }

    /// The paste-detection half of `neededFor`, for the tests.
    static func neededForRules(_ engine: PasteEngine) -> Bool { engine.awaitsPaste }

    /// The list whose rules the Paste Guard has to enforce right now: the
    /// guard is on and the clipboard's content belongs to a restricted list.
    static func guardedList(_ settings: SettingsStore, _ history: ClipboardHistory) -> ClipList? {
        guard settings.value.pasteGuardEnabled else { return nil }
        let list = history.currentList
        return list.isRestricted ? list : nil
    }

    static func start() {
        if localMonitor == nil {
            // Snippad's own windows need no tap and no permission.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if tap == nil, isPaste(keyCode: Int64(event.keyCode), flags: event.cgEvent?.flags ?? [],
                                      characters: event.charactersIgnoringModifiers) {
                    PasteEngine.shared.noticePaste()
                }
                return event
            }
        }
        update()
    }

    /// Installs or removes the tap to match what is needed. Called whenever
    /// the settings or the clipboard change.
    static func update() {
        let reasons = neededFor
        if reasons.isEmpty {
            removeTap()
            stopWaiting()
        } else if isTrusted {
            stopWaiting()
            installTap()
        } else {
            waitForAccess()
        }
        let status = KeyboardTapStatus.shared
        let wasBlocked = status.blocked
        status.active = tap != nil
        status.blocked = !reasons.isEmpty && tap == nil
        status.reason = reasons.joined(separator: " and ")
        StatusMenu.shared.updateIcon()

        // A guard that cannot guard must not keep quiet about it.
        if status.blocked && !wasBlocked && guardedList(SettingsStore.shared, ClipboardHistory.shared) != nil {
            PasteNotice.show("Snippad cannot check this paste: it needs the Accessibility permission (menu bar ⚠︎ › Allow). Until then, \u{201C}\(ClipboardHistory.shared.currentList.name)\u{201D} can be pasted anywhere.",
                             prefix: "Paste Guard is not working.")
        }
    }

    /// Shows the system prompt that leads to Privacy & Security.
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        waitForAccess()
    }

    /// Checks every few seconds whether access was granted, then installs
    /// the tap if it is still needed.
    private static func waitForAccess() {
        guard waitTimer == nil, !isTrusted else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard isTrusted else { return }
                stopWaiting()
                update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waitTimer = timer
    }

    private static func stopWaiting() {
        waitTimer?.invalidate()
        waitTimer = nil
    }

    private static func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: pasteTapCallback, userInfo: nil) else {
            NSLog("Snippad could not install its keyboard tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
    }

    /// Takes the tap out of the system entirely, not just disables it.
    private static func removeTap() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        runLoopSource = nil
    }

    fileprivate static func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    nonisolated static func isPaste(keyCode: Int64, flags: CGEventFlags, characters: String?) -> Bool {
        guard flags.contains(.maskCommand), !flags.contains(.maskControl) else { return false }
        return keyCode == Int64(kVK_ANSI_V) || characters?.lowercased() == "v"
    }

    /// A ⌘V on its way to the app in front: true lets it through.
    fileprivate static func handle() -> Bool {
        let history = ClipboardHistory.shared
        history.poll()  // a copy made a moment ago is not polled yet
        let settings = SettingsStore.shared.value
        let target = NSWorkspace.shared.frontmostApplication
        guard settings.pasteGuardEnabled, let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            PasteEngine.shared.noticePaste()
            return true
        }

        let list = history.currentList
        var needsPrivacy = false
        let quick = PasteGuard.verdict(list: list, bundleID: target.bundleIdentifier, appName: target.localizedName ?? "this app",
                                       isBrowser: BrowserPrivacy.isBrowser(target.bundleIdentifier)) {
            needsPrivacy = true
            return .privateWindow
        }
        switch quick {
        case .deny(let reason):
            PasteNotice.show(reason)
            return false
        case .allow where !needsPrivacy:
            PasteEngine.shared.noticePaste()
            return true
        case .allow:
            // Asking a browser about its window can take longer than an
            // event tap may wait: hold the ⌘V, ask, and send it again if the
            // window is private.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let state = BrowserPrivacy.state(of: target)
                    if state == .privateWindow {
                        sendCommandV()
                        PasteEngine.shared.noticePaste()
                    } else {
                        let verdict = PasteGuard.verdict(list: list, bundleID: target.bundleIdentifier,
                                                         appName: target.localizedName ?? "this app", isBrowser: true) { state }
                        if case .deny(let reason) = verdict { PasteNotice.show(reason) }
                    }
                }
            }
            return false
        }
    }

    /// Paste after choosing, when it is on: pastes into the app in front, or
    /// -- lacking the Accessibility permission -- says that the value is on
    /// the clipboard but could not be pasted, instead of doing nothing.
    static func pasteIfWanted(activating target: NSRunningApplication? = nil) {
        guard SettingsStore.shared.value.pasteAfterChoosing else { return }
        guard isTrusted else {
            PasteNotice.show("Press ⌘V to paste it. To paste for you, this copy of Snippad needs the Accessibility permission (menu bar menu › Allow Accessibility).",
                             prefix: "On the clipboard.")
            return
        }
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteIntoFrontApp()
        }
    }

    /// Paste After Choosing: the same check as a typed ⌘V, then the ⌘V.
    static func pasteIntoFrontApp() {
        if handle() {
            sendCommandV()
            SnippadSound.pasted()
        }
    }

    static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cgSessionEventTap)
        }
    }
}

private func pasteTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { PasteInterceptor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          event.getIntegerValueField(.eventSourceUserData) != PasteInterceptor.marker,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard event.flags.contains(.maskCommand) else { return Unmanaged.passUnretained(event) }
    let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
    guard PasteInterceptor.isPaste(keyCode: keyCode, flags: event.flags, characters: characters) else {
        return Unmanaged.passUnretained(event)
    }
    // ⇧⌘V is Snippad's picker window, while that is its shortcut, not a
    // paste.
    if event.flags.contains(.maskShift), !event.flags.contains(.maskAlternate), !event.flags.contains(.maskControl),
       MainActor.assumeIsolated({
           let v = SettingsStore.shared.value
           return v.pickerHotKeyEnabled && v.pickerShortcut == KeyShortcut(key: "v", shift: true, command: true)
       }) {
        return Unmanaged.passUnretained(event)
    }
    // The tap's run loop source is on the main run loop.
    let allow = MainActor.assumeIsolated { PasteInterceptor.handle() }
    return allow ? Unmanaged.passUnretained(event) : nil
}

/// A short message near the mouse pointer when a paste was stopped.
@MainActor
enum PasteNotice {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, prefix: String = "Paste blocked.") {
        NSSound.beep()
        let label = NSTextField(wrappingLabelWithString: prefix + " " + text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320
        let size = label.fittingSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 16)

        let panel = self.panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            return p
        }()
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        label.frame = frame.insetBy(dx: 12, dy: 8)
        effect.addSubview(label)
        panel.contentView = effect
        let mouse = NSEvent.mouseLocation
        panel.setFrame(NSRect(x: mouse.x + 12, y: mouse.y - frame.height - 12, width: frame.width, height: frame.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 0 }
            panel.orderOut(nil)
        }
    }
}
