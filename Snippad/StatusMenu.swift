import AppKit
import Carbon.HIToolbox

/// The clipboard icon in the menu bar: the history by list, the snippets of
/// recent .snippad files, and the way to the windows.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var pickerHotKey: HotKey?
    private var organizerHotKey: HotKey?
    /// What is registered now: the keys of each shortcut, nil when off.
    private var registered: [String: KeyShortcut?] = [:]
    /// Shortcuts macOS would not give to Snippad (another app has them).
    private(set) var unavailableHotKeys: Set<KeyShortcut> = []
    /// The app that was in front when the menu opened from the shortcut, to
    /// give focus back to, and paste into.
    private var previousApp: NSRunningApplication?

    /// How many entries a list shows before "Show All History…".
    private let menuItemCount = 25

    private var settings: SettingsStore { .shared }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Snippad")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = tooltip
        // Opened by hand rather than through `item.menu`, so it always hangs
        // from the icon's left edge.
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
        settingsChanged()
    }

    /// A warning triangle instead of the clipboard while the Paste Guard (or
    /// a paste-once value) needs the keyboard tap and cannot have it.
    func updateIcon() {
        let blocked = KeyboardTapStatus.shared.blocked
        let image = NSImage(systemSymbolName: blocked ? "exclamationmark.triangle" : "list.clipboard",
                            accessibilityDescription: "Snippad")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = blocked
            ? "Snippad cannot see ⌘V: allow Accessibility (open this menu)"
            : tooltip
    }

    private var tooltip: String {
        settings.value.hotKeyEnabled ? "Snippad clipboard history (\(settings.value.historyShortcut.display))" : "Snippad clipboard history"
    }

    /// Follows the settings: each shortcut on or off, and its keys.
    func settingsChanged() {
        SnippetShortcuts.refresh()
        let v = settings.value
        let wanted: [String: KeyShortcut?] = [
            "history": v.hotKeyEnabled ? v.historyShortcut : nil,
            "picker": v.pickerHotKeyEnabled ? v.pickerShortcut : nil,
            "organizer": v.organizerHotKeyEnabled ? v.organizerShortcut : nil,
        ]
        guard wanted != registered else { return }
        registered = wanted
        for key in [hotKey, pickerHotKey, organizerHotKey] { key?.unregister() }
        var failed: Set<KeyShortcut> = []
        func register(_ shortcut: KeyShortcut??, _ action: @escaping () -> Void) -> HotKey? {
            guard let shortcut = shortcut ?? nil else { return nil }
            let key = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: action)
            if key == nil { failed.insert(shortcut) }
            return key
        }
        hotKey = register(wanted["history"]) { [weak self] in self?.popUpAtMouse() }
        pickerHotKey = register(wanted["picker"]) { PickerPanel.toggle() }
        organizerHotKey = register(wanted["organizer"]) { HistoryWindow.show() }
        unavailableHotKeys = failed
        updateIcon()
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        button.highlight(true)
        let below = button.isFlipped ? button.bounds.maxY + 5 : button.bounds.minY - 5
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: below), in: button)
        button.highlight(false)
    }

    /// The same menu, opened where the mouse is, from the keyboard shortcut.
    func popUpAtMouse() {
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier { previousApp = nil }
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        // popUp returns after the menu closed, and after the chosen action ran.
        if let previousApp {
            previousApp.activate()
            self.previousApp = nil
        }
    }

    // MARK: - Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sharePickers.removeAll()
        let history = ClipboardHistory.shared
        let lists = settings.value.lists

        let organizer = menu.addItem(withTitle: "Snippad Organizer…", action: #selector(showHistory), keyEquivalent: "")
        if settings.value.organizerHotKeyEnabled, let (key, mask) = settings.value.organizerShortcut.menuKeyEquivalent {
            organizer.keyEquivalent = key
            organizer.keyEquivalentModifierMask = mask
        }
        organizer.target = self
        menu.addItem(.separator())

        if let current = PasteEngine.shared.current, PasteEngine.shared.holdsOwnValue {
            var notes: [String] = []
            if current.rules.password { notes.append("password") }
            if current.rules.next != nil { notes.append("chained") }
            if current.rules.once { notes.append("paste once") }
            if let s = current.rules.expires { notes.append("expires after \(SnippetDuration.text(s))") }
            let header = NSMenuItem(title: "On clipboard: \(Self.short(current.name, 50))" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(withTitle: "Clear Clipboard", action: #selector(clearClipboard), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }

        let pinned = history.items.filter(\.pinned)
        if !pinned.isEmpty {
            menu.addItem(.sectionHeader(title: "Pinned"))
            for item in pinned { menu.addItem(menuItem(for: item, shortcut: nil)) }
            menu.addItem(.separator())
        }

        // The first list in the menu itself, numbered; the others as
        // submenus.
        let first = lists[0]
        let recent = history.items.filter { !$0.pinned && $0.list == first.id }.prefix(menuItemCount)
        menu.addItem(.sectionHeader(title: first.name + (history.isCapturing ? "" : " (recording paused)")))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing copied yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, item) in recent.enumerated() {
            menu.addItem(menuItem(for: item, shortcut: index < 9 ? "\(index + 1)" : index == 9 ? "0" : nil))
        }
        // A line with a submenu has no key equivalent of its own; hidden
        // twins carry the numbers.
        for (index, item) in recent.prefix(10).enumerated() {
            let twin = NSMenuItem(title: Self.short(item.title, 60), action: #selector(chooseHistoryItem(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "0")
            twin.keyEquivalentModifierMask = []
            twin.target = self
            twin.representedObject = item.id
            twin.isHidden = true
            twin.allowsKeyEquivalentWhenHidden = true
            twin.isEnabled = !item.filesGone
            menu.addItem(twin)
        }
        for list in lists.dropFirst() {
            let entries = history.items.filter { !$0.pinned && $0.list == list.id }
            let sub = NSMenuItem(title: "\(list.name) (\(entries.count))", action: nil, keyEquivalent: "")
            sub.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            let submenu = NSMenu()
            if entries.isEmpty {
                let none = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            for item in entries.prefix(menuItemCount) { submenu.addItem(menuItem(for: item, shortcut: nil)) }
            sub.submenu = submenu
            menu.addItem(sub)
        }
        menu.addItem(.separator())

        menu.addItem(screenshotItem())
        let snippets = NSMenuItem(title: "Snippets", action: nil, keyEquivalent: "")
        snippets.submenu = snippetsMenu()
        menu.addItem(snippets)
        menu.addItem(withTitle: "Open .snippad File…", action: #selector(openFile), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "New .snippad File…", action: #selector(newFile), keyEquivalent: "n").target = self
        menu.addItem(.separator())

        let capture = menu.addItem(withTitle: "Record Clipboard History", action: #selector(toggleCapture), keyEquivalent: "")
        capture.target = self
        capture.state = history.isCapturing ? .on : .off
        let size = menu.addItem(withTitle: "History: \(history.diskUsageText)", action: nil, keyEquivalent: "")
        size.isEnabled = false
        size.toolTip = "What the clipboard history takes on disk, in ~/Library/Application Support/Snippad/History"
        if let batch = history.undoableDelete {
            let undo = menu.addItem(withTitle: batch.items.count == 1 ? "Undo Delete of \u{201C}\(Self.short(batch.items[0].title, 40))\u{201D}"
                                        : "Undo Delete of \(batch.items.count) Entries",
                                    action: #selector(undoDelete), keyEquivalent: "")
            undo.target = self
            undo.toolTip = "Deleted entries can be brought back for five minutes"
        }
        let guardItem = menu.addItem(withTitle: "Paste Guard", action: #selector(togglePasteGuard), keyEquivalent: "")
        guardItem.target = self
        guardItem.state = settings.value.pasteGuardEnabled ? .on : .off
        guardItem.toolTip = "Stop ⌘V when the clipboard's list may not be pasted into the app in front"
        let tap = KeyboardTapStatus.shared
        if tap.active {
            let item = menu.addItem(withTitle: "⌨︎ Watching ⌘V for \(tap.reason)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "Snippad's keyboard tap is installed. It is removed again when nothing needs it."
        } else if tap.blocked || (settings.value.pasteAfterChoosing && !PasteInterceptor.isTrusted) {
            accessWarning(in: menu)
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        // No ⌘Q: that only closes the Organizer, so Snippad is not quit by
        // a habit.
        menu.addItem(withTitle: "Quit Snippad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    private func accessWarning(in menu: NSMenu) {
        let item = menu.addItem(withTitle: "⚠︎ Allow Accessibility so Snippad Sees ⌘V…",
                                action: #selector(requestAccess), keyEquivalent: "")
        item.target = self
        item.toolTip = "Paste-once, chains, the Paste Guard and Paste After Choosing need to see ⌘V in other apps, which takes the Accessibility permission."
    }

    @objc private func requestAccess() {
        PasteInterceptor.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func menuItem(for item: ClipItem, shortcut: String?) -> NSMenuItem {
        let title = Self.short(item.title, 60)
        let menuItem = NSMenuItem(title: title, action: #selector(chooseHistoryItem(_:)), keyEquivalent: shortcut ?? "")
        menuItem.keyEquivalentModifierMask = []
        menuItem.target = self
        menuItem.representedObject = item.id
        menuItem.image = thumbnail(for: item)
        menuItem.toolTip = tooltip(for: item)
        // Its commands open beside it. A line with a submenu sends no action
        // when clicked, so a view of its own takes the click.
        menuItem.submenu = actionsMenu(for: item)
        menuItem.view = HistoryMenuItemView(menuItem: menuItem, id: item.id, pinned: item.pinned, gone: item.filesGone)
        return menuItem
    }

    private func thumbnail(for item: ClipItem) -> NSImage? {
        let image: NSImage?
        if item.isPassword {
            image = NSImage(systemSymbolName: "key", accessibilityDescription: "Password")
        } else {
            switch item.kind {
            case .image: image = item.image
            case .files: image = item.fileURLs.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
            case .url: image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            case .richText: image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
            case .color: image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            case .other: image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            case .text: image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
            }
        }
        guard let image else { return nil }
        let size = NSSize(width: 16, height: 16)
        let resized = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        resized.isTemplate = image.isTemplate
        return resized
    }

    private func tooltip(for item: ClipItem) -> String {
        var lines: [String] = []
        if item.isPassword {
            lines.append(ClipItem.mask)
        } else {
            if let s = item.string { lines.append(String(s.prefix(500))) }
            if item.kind == .files { lines.append(item.fileURLs.map(\.path).joined(separator: "\n")) }
        }
        if item.filesGone {
            lines.append("These files no longer exist (deleted, or moved to the Trash). Their names and paths can still be copied, from the commands beside it.")
        } else {
            lines.append("Click to copy. Its commands (pin, move to another list, delete…) open beside it.")
        }
        let when = item.date.formatted(date: .abbreviated, time: .shortened)
        lines.append("— \(item.sourceApp.map { "\($0), " } ?? "")\(when)")
        return lines.joined(separator: "\n")
    }

    private func snippetsMenu() -> NSMenu {
        let menu = NSMenu()
        SnippadLibrary.shared.refreshFiles()
        let urls = SnippadLibrary.shared.files
        if urls.isEmpty {
            let none = NSMenuItem(title: "No .snippad files open", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for url in urls {
            let fileItem = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            switch SnippadContent.read(url) {
            case .success(let snippets):
                for snippet in snippets {
                    let item = NSMenuItem(title: snippet.name, action: #selector(chooseSnippet(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = SnippetChoice(snippet: snippet, all: snippets)
                    item.toolTip = snippet.preview
                    if let shortcut = snippet.shortcut.flatMap(KeyShortcut.init), let (key, mask) = shortcut.menuKeyEquivalent {
                        item.keyEquivalent = key
                        item.keyEquivalentModifierMask = mask
                    }
                    if snippet.password { item.image = NSImage(systemSymbolName: "key", accessibilityDescription: "Password") }
                    sub.addItem(item)
                }
            case .failure(let error):
                let item = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
                item.isEnabled = false
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let open = sub.addItem(withTitle: "Open Window", action: #selector(openRecent(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            let edit = sub.addItem(withTitle: "Edit in Organizer…", action: #selector(editRecent(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = url
            fileItem.submenu = sub
            menu.addItem(fileItem)
        }
        return menu
    }

    // MARK: - Actions

    /// A click, Return, or the entry's number: put it on the clipboard.
    @objc func chooseHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, ClipboardHistory.shared.copy(id) else { return }
        pasteIfWanted()
    }

    // MARK: - Screenshots

    private func screenshotItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Take Screenshot", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        let sub = NSMenu()
        if Screenshots.isCountingDown {
            sub.addItem(withTitle: "Cancel the Delayed Screenshot", action: #selector(cancelScreenshot), keyEquivalent: "").target = self
            sub.addItem(.separator())
        }
        let delay = settings.value.screenshotDelay
        sub.addItem(screensItem("Screen", delay: 0))
        sub.addItem(screensItem("Screen in \(delay) Seconds", delay: delay))
        sub.addItem(.separator())
        sub.addItem(withTitle: "Window", action: #selector(screenshotWindow), keyEquivalent: "").target = self
        sub.addItem(withTitle: "Window with Shadow", action: #selector(screenshotWindowShadow), keyEquivalent: "").target = self
        sub.addItem(withTitle: "Area", action: #selector(screenshotArea), keyEquivalent: "").target = self
        sub.addItem(.separator())
        let target = sub.addItem(withTitle: "Goes to \u{201C}\(settings.list(settings.value.screenshotList).name)\u{201D}",
                                 action: nil, keyEquivalent: "")
        target.isEnabled = false
        item.submenu = sub
        return item
    }

    /// One screen: the item itself. Several: a submenu naming them.
    private func screensItem(_ title: String, delay: Int) -> NSMenuItem {
        let screens = Screenshots.screens
        if screens.count <= 1 {
            let item = NSMenuItem(title: title, action: #selector(screenshotScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ScreenChoice(id: screens.first?.id ?? CGMainDisplayID(), delay: delay)
            return item
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for screen in screens {
            let entry = sub.addItem(withTitle: screen.name + (screen.isMain ? " (main)" : ""),
                                    action: #selector(screenshotScreen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ScreenChoice(id: screen.id, delay: delay)
        }
        item.submenu = sub
        return item
    }

    @objc private func screenshotScreen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ScreenChoice else { return }
        Screenshots.captureScreen(choice.id, delay: choice.delay)
    }
    @objc private func screenshotWindow() { Screenshots.capture(.window) }
    @objc private func screenshotWindowShadow() { Screenshots.capture(.windowWithShadow) }
    @objc private func screenshotArea() { Screenshots.capture(.area) }
    @objc private func cancelScreenshot() { Screenshots.cancelCountdown() }

    /// The seconds left before a delayed screenshot, beside the menu bar
    /// icon; nil puts the icon back.
    func showCountdown(_ seconds: Int?) {
        guard let button = statusItem?.button else { return }
        if let seconds {
            statusItem?.length = NSStatusItem.variableLength
            button.title = " \(seconds)"
            button.imagePosition = .imageLeft
            button.toolTip = "A screenshot in \(seconds) seconds (open the menu to cancel)"
        } else {
            button.title = ""
            statusItem?.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            updateIcon()
        }
    }

    /// Keeps the menu narrow: a long line ends in an ellipsis.
    static func short(_ s: String, _ max: Int) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "\u{2026}" : s
    }

    /// The commands of one history entry: its submenu in the history menu.
    func actionsMenu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        // Otherwise AppKit enables every item whose target answers its
        // action, and the isEnabled set below would be ignored.
        menu.autoenablesItems = false
        let context = EntryContext(id: item.id)

        // What the commands act on, in a line or two.
        let preview: String
        if item.isPassword {
            preview = item.title
        } else if item.kind == .files {
            let missing = Set(item.missingFiles)
            preview = (item.filesGone ? "No longer exists:\n" : "")
                + item.fileURLs.prefix(3).map { Self.short($0.path, 80) + (missing.contains($0) && !item.filesGone ? "  (missing)" : "") }
                    .joined(separator: "\n")
                + (item.fileURLs.count > 3 ? "\n…" : "")
        } else {
            let text = (item.string ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines)
            preview = text.count > 120 ? String(text.prefix(117)) + "…" : text
        }
        let header = NSMenuItem(title: preview, action: nil, keyEquivalent: "")
        header.isEnabled = false
        let when = item.date.formatted(date: .abbreviated, time: .shortened)
        header.attributedTitle = NSAttributedString(
            string: preview.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).map { Self.short(String($0), 80) }.joined(separator: "\n")
                + "\n" + [item.sourceApp, when, settings.list(item.list).name].compactMap { $0 }.joined(separator: " · "),
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, "Put on Clipboard", #selector(entryPut(_:)), context).isEnabled = !item.filesGone
        add(menu, "Paste", #selector(entryPaste(_:)), EntryContext(id: item.id, form: .main)).isEnabled = !item.filesGone
        if ClipboardHistory.shared.hasRichText(item.id) {
            add(menu, "Paste as Rich Text", #selector(entryPaste(_:)), EntryContext(id: item.id, form: .richText))
            if !item.isPassword {
                add(menu, "Paste as Markdown", #selector(entryPaste(_:)), EntryContext(id: item.id, form: .markdown))
            }
        }
        add(menu, "Paste Original", #selector(entryPaste(_:)), EntryContext(id: item.id, form: .original)).isEnabled = !item.filesGone
        menu.addItem(.separator())
        add(menu, item.pinned ? "Unpin" : "Pin", #selector(entryTogglePin(_:)), context)
        add(menu, "Rename\u{2026}", #selector(entryRename(_:)), context)
        let move = NSMenuItem(title: "Move to List", action: nil, keyEquivalent: "")
        let lists = NSMenu()
        for list in settings.value.lists {
            let entry = lists.addItem(withTitle: list.name, action: #selector(entryMove(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = EntryContext(id: item.id, listID: list.id)
            entry.state = item.list == list.id ? .on : .off
        }
        move.submenu = lists
        menu.addItem(move)

        if item.hasImageForText {
            menu.addItem(.separator())
            add(menu, "Extract Text", #selector(entryExtractText(_:)), context)
        }
        if item.canBecomeSnippet {
            let addTo = NSMenuItem(title: "Add to Snippad", action: nil, keyEquivalent: "")
            let files = NSMenu()
            for url in SnippadLibrary.shared.files {
                let f = files.addItem(withTitle: url.deletingPathExtension().lastPathComponent,
                                      action: #selector(entryAddToSnippad(_:)), keyEquivalent: "")
                f.target = self
                f.representedObject = EntryContext(id: item.id, url: url)
            }
            if SnippadLibrary.shared.files.isEmpty {
                let none = files.addItem(withTitle: "No .snippad file is open", action: nil, keyEquivalent: "")
                none.isEnabled = false
            }
            addTo.submenu = files
            menu.addItem(addTo)
        }
        if !item.isPassword, !item.filesGone, case let items = shareItems(for: item), !items.isEmpty {
            // The system's own Share menu, with the apps' icons.
            let picker = NSSharingServicePicker(items: items)
            sharePickers.append(picker)
            menu.addItem(picker.standardShareMenuItem)
        }

        if item.kind == .files {
            menu.addItem(.separator())
            add(menu, "Copy File Contents", #selector(entryFileContents(_:)), context).isEnabled = !item.filesGone
            add(menu, "Copy Names as Text", #selector(entryNames(_:)), context)
            add(menu, "Copy Paths as Text", #selector(entryPaths(_:)), context)
            add(menu, "Show in Finder", #selector(entryReveal(_:)), context).isEnabled = !item.filesGone
        }
        menu.addItem(.separator())
        add(menu, "Delete", #selector(entryDelete(_:)), context)
        return menu
    }

    @objc private func entryPaste(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, let form = c.form else { return }
        // Never send ⌘V unless this entry is what is on the clipboard now.
        guard ClipboardHistory.shared.put(c.id, as: form) else {
            NSSound.beep()
            return
        }
        guard PasteInterceptor.isTrusted else {
            PasteNotice.show("It is on the clipboard: press ⌘V. To paste for you, Snippad needs the Accessibility permission.", prefix: "")
            return
        }
        let target = previousApp
        target?.activate()
        previousApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            PasteInterceptor.pasteIntoFrontApp()
        }
    }

    @objc private func entryExtractText(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        extractText(from: c.id)
    }

    @objc private func entryAddToSnippad(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, let url = c.url,
              let item = ClipboardHistory.shared.item(c.id) else { return }
        do {
            try SnippadLibrary.shared.addSnippet(from: item, to: url)
            PasteNotice.show("Added to \(url.deletingPathExtension().lastPathComponent).", prefix: "")
        } catch {
            presentError(error, title: "The snippet could not be added")
        }
    }

    /// What the Share menu hands over for an entry.
    private func shareItems(for item: ClipItem) -> [Any] {
        switch item.kind {
        case .image: return item.image.map { [$0] } ?? []
        case .files: return item.fileURLs
        case .url: return item.string.flatMap(URL.init(string:)).map { [$0] } ?? []
        case .richText: return item.attributedString.map { [$0] } ?? []
        default: return item.string.map { [$0] } ?? []
        }
    }

    /// Kept while the menu is up: the share menu item needs its picker.
    private var sharePickers: [NSSharingServicePicker] = []

    @objc private func entryPut(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, ClipboardHistory.shared.copy(c.id) else { return }
        pasteIfWanted()
    }
    @objc private func entryTogglePin(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, let item = ClipboardHistory.shared.item(c.id) else { return }
        ClipboardHistory.shared.setPinned(c.id, !item.pinned)
    }
    @objc private func entryMove(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, let listID = c.listID else { return }
        ClipboardHistory.shared.move(c.id, toList: listID)
    }
    @objc private func entryDelete(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        ClipboardHistory.shared.delete(undoably: [c.id])
    }
    @objc private func entryRename(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext, let item = ClipboardHistory.shared.item(c.id) else { return }
        renameEntry(item)
    }
    @objc private func undoDelete() { ClipboardHistory.shared.undoDelete() }
    @objc private func entryFileContents(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        copyFileContents(of: c.id)
    }
    @objc private func entryPaths(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        copyFileText(of: c.id, .paths)
    }
    @objc private func entryNames(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        copyFileText(of: c.id, .names)
    }
    @objc private func entryReveal(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EntryContext else { return }
        reveal(c.id)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ context: EntryContext) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = context
        return item
    }

    @objc private func chooseSnippet(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SnippetChoice else { return }
        let s = choice.snippet
        PasteEngine.shared.put(types: s.pasteboardTypes, name: s.name, rules: s.rules(in: choice.all))
        pasteIfWanted()
    }

    private func pasteIfWanted() {
        let target = previousApp
        previousApp = nil
        PasteInterceptor.pasteIfWanted(activating: target)
    }

    /// Right-click on a files entry: put the contents of its files on the
    /// clipboard, as text or image.
    func copyFileContents(of id: UUID) {
        guard let item = ClipboardHistory.shared.item(id) else { return }
        do {
            try ClipboardHistory.shared.copyFileContents(item.fileURLs, listID: item.listID)
        } catch {
            presentError(error, title: "Some files could not be put on the clipboard")
        }
    }

    func reveal(_ id: UUID) {
        guard let item = ClipboardHistory.shared.item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs)
    }

    @objc private func clearClipboard() { PasteEngine.shared.clear() }
    @objc private func showHistory() { HistoryWindow.show() }
    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func openFile() { SnippadLibrary.shared.showOpenPanel() }
    @objc private func newFile() { HistoryWindow.newSnippadFile() }
    @objc private func toggleCapture() { ClipboardHistory.shared.isCapturing.toggle() }

    @objc private func togglePasteGuard() {
        settings.value.pasteGuardEnabled.toggle()
        if settings.value.pasteGuardEnabled && !PasteInterceptor.isTrusted { requestAccess() }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { SnippadLibrary.shared.open(url) }
    }

    @objc private func editRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { HistoryWindow.show(file: url) }
    }

    static func copyMCPCommand() {
        let exe = Bundle.main.executableURL?.path ?? "/Applications/Snippad.app/Contents/MacOS/Snippad"
        PasteEngine.shared.put("claude mcp add -s user snippad -- '\(exe)' --mcp", name: "MCP setup command")
    }
}

private final class SnippetChoice: NSObject {
    let snippet: Snippet
    let all: [Snippet]
    init(snippet: Snippet, all: [Snippet]) {
        self.snippet = snippet
        self.all = all
    }
}

private final class ScreenChoice: NSObject {
    let id: CGDirectDisplayID
    let delay: Int
    init(id: CGDirectDisplayID, delay: Int) {
        self.id = id
        self.delay = delay
    }
}

/// Which entry a command of its submenu is for.
private final class EntryContext: NSObject {
    let id: UUID
    let listID: String?
    let form: ClipboardHistory.PasteForm?
    let url: URL?
    init(id: UUID, listID: String? = nil, form: ClipboardHistory.PasteForm? = nil, url: URL? = nil) {
        self.id = id
        self.listID = listID
        self.form = form
        self.url = url
    }
}


/// One line of the history menu, drawn like a normal menu item. A view
/// because the line has a submenu (its commands), and a line with a submenu
/// sends no action when clicked: the view takes the click and puts the entry
/// on the clipboard. Hovering, or →, opens the submenu as usual.
@MainActor
private final class HistoryMenuItemView: NSView {
    private weak var menuItem: NSMenuItem?
    private let title: String
    private let image: NSImage?
    private let shortcut: String
    private let pinned: Bool
    /// Its files no longer exist: drawn grey, and a click does nothing.
    private let gone: Bool

    private static let font = NSFont.menuFont(ofSize: 0)

    init(menuItem: NSMenuItem, id: UUID, pinned: Bool, gone: Bool) {
        self.menuItem = menuItem
        self.pinned = pinned
        self.gone = gone
        title = menuItem.title
        image = menuItem.image
        shortcut = menuItem.keyEquivalent
        let textWidth = NSAttributedString(string: title, attributes: [.font: Self.font]).size().width
        let width = min(max(textWidth + 36 + 64, 220), 480)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        autoresizingMask = [.width]
        toolTip = menuItem.toolTip
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var highlighted: Bool { menuItem?.isHighlighted ?? false }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : gone ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = highlighted ? color : .secondaryLabelColor
        if let image {
            let tinted = image.isTemplate ? image.tinted(color) : image
            tinted.draw(in: NSRect(x: 14, y: (bounds.height - 16) / 2, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: gone && !highlighted ? 0.4 : 1)
        }
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        let height = text.size().height
        let y = (bounds.height - height) / 2
        text.draw(with: NSRect(x: 36, y: y, width: bounds.width - 36 - 56, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let arrow = NSAttributedString(string: "›", attributes: [.font: Self.font, .foregroundColor: secondary])
        arrow.draw(at: NSPoint(x: bounds.width - 14 - arrow.size().width, y: y))
        let mark = pinned ? "📌" : shortcut
        if !mark.isEmpty {
            let key = NSAttributedString(string: mark, attributes: [.font: Self.font, .foregroundColor: secondary])
            key.draw(at: NSPoint(x: bounds.width - 30 - key.size().width, y: y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let menuItem, !gone else { return }
        menuItem.menu?.cancelTracking()
        StatusMenu.shared.chooseHistoryItem(menuItem)
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
