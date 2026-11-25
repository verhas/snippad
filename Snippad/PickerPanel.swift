import AppKit
import SwiftUI

/// The ⇧⌘V window: the entries of the preferred list, to pick one with the
/// mouse (or the arrow keys and Return). Picking does what choosing from the
/// menu bar does: the entry goes on the clipboard, and is pasted into the
/// app in front when "Paste after choosing" is on.
///
/// A non-activating panel, so the app you were typing in stays in front and
/// gets the paste.
@MainActor
enum PickerPanel {
    private static var panel: NSPanel?
    /// The app that was in front when ⇧⌘V was pressed: the one to paste into.
    private(set) static var target: NSRunningApplication?

    static func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    /// - Parameter list: the list to show; nil shows the preferred list.
    static func show(list: String? = nil) {
        let panel = Self.panel ?? make()
        Self.panel = panel
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        let allowed = PasteGuard.allowedLists(into: target, settings: SettingsStore.shared.value)
        panel.contentViewController = NSHostingController(rootView: PickerView(target: target, allowedLists: allowed, shownList: list, close: close))
        panel.setContentSize(NSSize(width: 420, height: 460))
        // Near the mouse, on its screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            var origin = NSPoint(x: mouse.x - 210, y: mouse.y - 460 + 20)
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 428)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 468)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
    }

    private static func make() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "Clipboard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = PanelDelegate.shared
        return panel
    }

    /// Puts the entry on the clipboard, then pastes it if wanted.
    static func choose(_ id: UUID) {
        close()
        guard ClipboardHistory.shared.copy(id) else { return NSSound.beep() }
        PasteInterceptor.pasteIfWanted(activating: target)
    }

    /// Several entries: their texts as one, a line break between them, then
    /// pasted if wanted.
    static func choose(_ ids: [UUID]) {
        guard ids.count > 1 else { return ids.first.map(choose) ?? () }
        close()
        do {
            try ClipboardHistory.shared.copyJoined(ids)
        } catch {
            PasteNotice.show(error.localizedDescription, prefix: "Not joined.")
            return
        }
        PasteInterceptor.pasteIfWanted(activating: target)
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Clicking elsewhere closes the panel.
private final class PanelDelegate: NSObject, NSWindowDelegate {
    @MainActor static let shared = PanelDelegate()
    func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { PickerPanel.close() }
    }
}

private struct PickerView: View {
    let target: NSRunningApplication?
    /// Lists the Paste Guard lets into the target; entries of the others are
    /// not offered.
    let allowedLists: Set<String>
    /// The list asked for; nil means the preferred list.
    var shownList: String?
    let close: () -> Void
    @State private var history = ClipboardHistory.shared
    @State private var settings = SettingsStore.shared
    @State private var query = ""
    @State private var selection: UUID?
    /// Entries added with ⌘-click or ⇧-click, to paste together.
    @State private var marked: [UUID] = []
    @FocusState private var searchFocused: Bool

    private var listID: String? { shownList ?? settings.value.preferredList }

    private var hiddenCount: Int {
        history.items.filter { (listID == nil || $0.list == listID) && !allowedLists.contains($0.list) }.count
    }

    private var entries: [ClipItem] {
        let found = history.search(query, list: listID).filter { !$0.filesGone && allowedLists.contains($0.list) }
        return Array((found.filter(\.pinned) + found.filter { !$0.pinned }).prefix(5000))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: listID.map { settings.list($0).symbol } ?? "tray.full")
                Text(listID.map { settings.list($0).name } ?? "All Lists").font(.headline)
                Spacer()
                if let target {
                    Image(nsImage: target.icon ?? NSImage()).resizable().frame(width: 16, height: 16)
                    Text("→ \(target.localizedName ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onSubmit { submit() }
            if hiddenCount > 0 {
                Label("\(hiddenCount) entries are hidden: the Paste Guard does not let their lists into \(target?.localizedName ?? "this app").",
                      systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List(entries, selection: $selection) { item in
                PickerRow(item: item, listName: listID == nil && settings.value.lists.count > 1 ? settings.list(item.list).name : nil,
                          mark: marked.firstIndex(of: item.id).map { $0 + 1 })
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture { click(item.id) }
            }
            .onKeyPress(.return) {
                submit()
                return .handled
            }
            .overlay {
                if entries.isEmpty {
                    Text(query.isEmpty ? "Nothing in this list yet" : "Nothing found").foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !marked.isEmpty {
                HStack {
                    Text("\(marked.count) marked: Return pastes them together, one per line")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { marked = [] }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
        }
        .onExitCommand { if marked.isEmpty { close() } else { marked = [] } }
        .onAppear {
            selection = entries.first?.id
            searchFocused = true
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
    }

    /// A click chooses; with ⌘ or ⇧ it marks the entry to paste with
    /// others, in the order marked (⇧ marks the entries in between too).
    private func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let from = marked.last ?? selection, let a = entries.firstIndex(where: { $0.id == from }),
           let b = entries.firstIndex(where: { $0.id == id }) {
            let range = a <= b ? Array(entries[a...b]) : Array(entries[b...a].reversed())
            for item in range where !marked.contains(item.id) { marked.append(item.id) }
        } else if flags.contains(.command) {
            if let i = marked.firstIndex(of: id) { marked.remove(at: i) } else { marked.append(id) }
        } else {
            PickerPanel.choose(id)
        }
        selection = id
    }

    private func submit() {
        if !marked.isEmpty {
            PickerPanel.choose(marked)
        } else if let first = selection ?? entries.first?.id {
            PickerPanel.choose(first)
        }
    }

    private func move(_ by: Int) {
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -by
        selection = ids[min(max(index + by, 0), ids.count - 1)]
    }
}

private struct PickerRow: View {
    let item: ClipItem
    let listName: String?
    /// Its place among the marked entries.
    var mark: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if item.isPassword {
                    Image(systemName: "key")
                } else if item.kind == .image, let image = item.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if item.kind == .files, let url = item.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: item.kind == .url ? "link" : "text.alignleft")
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text([listName, item.sourceApp, item.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let mark {
                Image(systemName: "\(min(mark, 50)).circle.fill").foregroundStyle(Color.accentColor)
                    .help("Marked \(mark.formatted(.number)): pasted in this place")
            }
            if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}
