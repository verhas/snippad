import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the history window shows: a list (or all of them) or a .snippad
/// file in the sidebar, the entries selected, and the list being edited.
enum SidebarItem: Hashable {
    case all
    case list(String)
    case file(URL)
}

@MainActor
@Observable
final class HistoryNavigation {
    static let shared = HistoryNavigation()
    var sidebar: SidebarItem = .all
    /// A list whose settings fill the detail pane.
    var editingList: String?
    var selection: Set<UUID> = []
}

/// The whole clipboard history, by list, searchable, with a preview of the
/// selection, text editing, and file commands; the open .snippad files, to
/// edit; and the lists, to set up.
@MainActor
enum HistoryWindow {
    private static var controller: NSWindowController?

    static func show(file: URL? = nil, editingList: String? = nil) {
        SnippadLibrary.shared.refreshFiles()
        let nav = HistoryNavigation.shared
        if let file {
            nav.sidebar = .file(SnippadLibrary.key(file))
            nav.editingList = nil
        }
        if let editingList {
            nav.sidebar = .list(editingList)
            nav.editingList = editingList
        }
        if controller == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1100, height: 620))
            window.title = "Snippad Organizer"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ClipboardHistory")
            window.center()
            controller = NSWindowController(window: window)
        }
        AppActivation.show(controller!.window!)
        // SwiftUI puts the toolbar in a moment later.
        configureToolbar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { configureToolbar() }
    }

    private static var displayModeObservation: NSKeyValueObservation?

    /// The toolbar's right-click menu offers Icon and Text, Icon Only and
    /// Text Only, as in other Mac apps; the choice is kept in the settings.
    private static func configureToolbar() {
        guard let toolbar = controller?.window?.toolbar else { return }
        toolbar.allowsDisplayModeCustomization = true
        let saved = NSToolbar.DisplayMode(rawValue: UInt(max(0, SettingsStore.shared.value.toolbarDisplayMode))) ?? .iconAndLabel
        if toolbar.displayMode != saved { toolbar.displayMode = saved }
        guard displayModeObservation == nil else { return }
        displayModeObservation = toolbar.observe(\.displayMode) { toolbar, _ in
            let mode = Int(toolbar.displayMode.rawValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SettingsStore.shared.value.toolbarDisplayMode = mode }
            }
        }
    }
}

extension HistoryWindow {
    /// Asks for a name, creates the file in ~/.snippad, and shows it.
    static func newSnippadFile() {
        let alert = NSAlert()
        alert.messageText = "New Snippad File"
        alert.informativeText = "The file is created in ~/.snippad, and is always listed in the Snippad Organizer."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let url = try SnippadLibrary.shared.create(named: field.stringValue)
            show(file: url)
        } catch {
            presentError(error, title: "The file could not be created")
        }
    }
}

/// Shows an error the way the rest of the app does.
@MainActor
func presentError(_ error: Error, title: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    NSApp.activate()
    alert.runModal()
}

extension UTType {
    /// History entries dragged inside Snippad; declared in Info.plist.
    static let snippadHistoryItem = UTType(exportedAs: "dev.verhas.snippad.history-item")
}

/// What is dragged when entries are dragged onto a list: every selected
/// entry, when the one dragged is among them.
struct HistoryDrag: Codable, Transferable {
    let ids: [UUID]

    init(ids: [UUID]) { self.ids = ids }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .snippadHistoryItem)
    }
}

private struct HistoryView: View {
    @State private var history = ClipboardHistory.shared
    @State private var settings = SettingsStore.shared
    @State private var library = SnippadLibrary.shared
    @State private var nav = HistoryNavigation.shared
    @State private var query = ""
    @State private var confirmClear = false
    @State private var dropTarget: String?
    @State private var deletingList: String?

    private var listFilter: String? {
        if case .list(let id) = nav.sidebar { return id }
        return nil
    }

    private var shown: [ClipItem] {
        let found = history.search(query, list: listFilter)
        return found.filter(\.pinned) + found.filter { !$0.pinned }
    }

    private var selectedItems: [ClipItem] {
        shown.filter { nav.selection.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .labelStyle(.titleAndIcon)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } content: {
            Group {
                if case .file(let url) = nav.sidebar {
                    SnippetListColumn(model: library.model(for: url))
                        .id(url)
                } else {
                    entries
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Toggle(isOn: $history.isCapturing) {
                    Label(history.isCapturing ? "Recording" : "Paused",
                          systemImage: history.isCapturing ? "record.circle" : "pause.circle")
                }
                .help(history.isCapturing ? "New copies are recorded. Click to pause." : "Recording is paused. Click to record new copies.")
                if !isFile {
                    Button("Clear Unpinned…", systemImage: "trash.slash") { confirmClear = true }
                        .help("Delete every entry that is not pinned\(listFilter.map { " from \u{201C}\(settings.list($0).name)\u{201D}" } ?? "")")
                }
            }
        }
        .confirmationDialog(clearTitle, isPresented: $confirmClear) {
            Button("Delete Unpinned Entries", role: .destructive) { history.clear(list: listFilter) }
        } message: {
            Text("Pinned entries stay. This cannot be undone.")
        }
        .sheet(item: Binding(get: { deletingList.map(ListRef.init) }, set: { deletingList = $0?.id })) { ref in
            DeleteListSheet(listID: ref.id) { moveTo in
                history.removeList(ref.id, moveTo: moveTo)
                if nav.sidebar == .list(ref.id) { nav.sidebar = .all }
                if nav.editingList == ref.id { nav.editingList = nil }
            }
        }
        .onChange(of: nav.sidebar) { query = "" }
        .onChange(of: nav.selection) { if !nav.selection.isEmpty { nav.editingList = nil } }
        .onAppear { library.refreshFiles() }
        .frame(minWidth: 900, minHeight: 400)
    }

    private var isFile: Bool {
        if case .file = nav.sidebar { return true }
        return false
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<SidebarItem?>(get: { nav.sidebar },
                                              set: { if let v = $0 { nav.sidebar = v; nav.editingList = nil } })) {
            sidebarRow("All Lists", symbol: "tray.full", count: history.items.count, preferred: settings.value.preferredList == nil)
                .tag(SidebarItem.all)
                .contextMenu {
                    Button("Make Preferred") { settings.value.preferredList = nil }
                        .disabled(settings.value.preferredList == nil)
                    Button("New List") { newList() }
                    ExportMenu(listID: nil)
                }
            Section("Lists") {
                ForEach(settings.value.lists) { list in
                    listRow(list)
                }
            }
            Section("Snippad Files") {
                ForEach(library.files, id: \.self) { url in
                    fileRow(url)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New List") { newList() }
                    Button("New Snippad File…") { HistoryWindow.newSnippadFile() }
                    Button("Open Snippad File…") { library.showOpenPanel() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a list, or create or open a .snippad file")
                Spacer()
            }
            .padding(8)
        }
    }

    private func listRow(_ list: ClipList) -> some View {
        sidebarRow(list.name, symbol: list.symbol, count: history.items.filter { $0.list == list.id }.count,
                   preferred: settings.value.preferredList == list.id, restricted: list.isRestricted,
                   privateWindows: settings.value.privateBrowsingList == list.id)
            .tag(SidebarItem.list(list.id))
            .listRowBackground(dropTarget == list.id ? Color.accentColor.opacity(0.25) : nil)
            .dropDestination(for: HistoryDrag.self) { drags, _ in
                let ids = drags.flatMap(\.ids)
                for id in ids { history.move(id, toList: list.id) }
                return !ids.isEmpty
            } isTargeted: { over in
                dropTarget = over ? list.id : (dropTarget == list.id ? nil : dropTarget)
            }
            .help(list.isRestricted ? "Has Paste Guard rules. Drop entries here to move them." : "Drop entries here to move them")
            .contextMenu {
                Button("Edit List…") {
                    nav.sidebar = .list(list.id)
                    nav.editingList = list.id
                }
                Button("Make Preferred") { settings.value.preferredList = list.id }
                    .disabled(settings.value.preferredList == list.id)
                Divider()
                Button("Delete List…", role: .destructive) { deletingList = list.id }
                    .disabled(list.id == ClipList.defaultID)
                Divider()
                Button("New List") { newList() }
                ExportMenu(listID: list.id)
            }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack {
            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                .help(url.path)
            Spacer()
            if !library.isHome(url) {
                Button("Close", systemImage: "eject") { close(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close this file (it is not in ~/.snippad, so it is listed only while open)")
            }
        }
        .tag(SidebarItem.file(url))
        .contextMenu {
            Button("Open Window") { library.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if !library.isHome(url) {
                Divider()
                Button("Close") { close(url) }
            }
        }
    }

    private func sidebarRow(_ name: String, symbol: String, count: Int, preferred: Bool, restricted: Bool = false,
                            privateWindows: Bool = false) -> some View {
        HStack {
            Label {
                Text(name).fontWeight(preferred ? .semibold : .regular)
            } icon: {
                Image(systemName: symbol)
            }
            if restricted {
                Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.secondary)
                    .help("This list has Paste Guard rules")
            }
            if privateWindows {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    .help("Copies made in private browser windows go to this list")
            }
            Spacer()
            if preferred {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.green)
                    .help("The preferred list: shown by ⇧⌘V")
            }
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func newList() {
        let list = settings.addList(named: "New List")
        nav.sidebar = .list(list.id)
        nav.editingList = list.id
    }

    private func close(_ url: URL) {
        if nav.sidebar == .file(url) { nav.sidebar = .all }
        library.close(url)
    }

    // MARK: - Entries

    private var entries: some View {
        List(shown, selection: $nav.selection) { item in
            HistoryRow(item: item, listName: listFilter == nil && settings.value.lists.count > 1
                       ? settings.list(item.list).name : nil)
                .tag(item.id)
                .draggable(drag(for: item.id)) {
                    let count = nav.selection.contains(item.id) ? max(selectedItems.count, 1) : 1
                    Label(count > 1 ? "\(count) entries" : item.title, systemImage: "doc.on.clipboard").padding(6)
                }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemsActions(ids: ids, select: { nav.selection = [$0] })
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { history.copy(id) }
        }
        .searchable(text: $query, prompt: "Search text, files, EXIF")
        .onKeyPress(.return) {
            if selectedItems.count == 1 { history.copy(selectedItems[0].id) }
            return .handled
        }
        .onDeleteCommand { delete(Set(selectedItems.map(\.id))) }
    }

    private func drag(for id: UUID) -> HistoryDrag {
        if nav.selection.contains(id) {
            let ids = selectedItems.map(\.id)
            return HistoryDrag(ids: ids.isEmpty ? [id] : ids)
        }
        return HistoryDrag(ids: [id])
    }

    @ViewBuilder private var detail: some View {
        if let listID = nav.editingList {
            ListEditor(listID: listID)
                .labelStyle(.titleAndIcon)
                .id(listID)
        } else if case .file(let url) = nav.sidebar {
            let model = library.model(for: url)
            if let id = model.selection, let draft = model.drafts.first(where: { $0.id == id }) {
                SnippetDetail(draft: draft, model: model)
                    .id(draft.id)
            } else {
                ContentUnavailableView("No snippet selected", systemImage: "square.and.pencil",
                                       description: Text("Add one with the + button below the snippets."))
            }
        } else if selectedItems.count == 1, let item = selectedItems.first {
            HistoryDetail(item: item, select: { nav.selection = [$0] }, delete: { delete([item.id]) })
                .id(item.id)
        } else if selectedItems.count > 1 {
            MultipleDetail(items: selectedItems, delete: { delete(Set(selectedItems.map(\.id))) })
        } else {
            ContentUnavailableView(history.items.isEmpty ? "Nothing copied yet" : "No selection",
                                   systemImage: "list.clipboard",
                                   description: Text("Select entries with ⌘-click or ⇧-click, and drag them onto a list on the left to move them there."))
        }
    }

    private var clearTitle: String {
        if let l = listFilter { return "Delete every unpinned entry of \u{201C}\(settings.list(l).name)\u{201D}?" }
        return "Delete every unpinned entry of the history?"
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let list = shown
        let after = list.drop { !ids.contains($0.id) }.first { !ids.contains($0.id) }
        let before = list.last { !ids.contains($0.id) && (list.firstIndex(of: $0) ?? 0) < (list.firstIndex { ids.contains($0.id) } ?? 0) }
        nav.selection = (after ?? before).map { [$0.id] } ?? []
        for id in ids { history.delete(id) }
    }
}

private struct ListRef: Identifiable {
    let id: String
}

/// Asks where the entries of a list being deleted go.
private struct DeleteListSheet: View {
    let listID: String
    let remove: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: String? = ClipList.defaultID
    private var settings: SettingsStore { .shared }

    var body: some View {
        let count = ClipboardHistory.shared.items.filter { $0.list == listID }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete the list \u{201C}\(settings.list(listID).name)\u{201D}?").font(.headline)
            if count > 0 {
                Picker("Its \(count) entries", selection: $target) {
                    ForEach(settings.value.lists.filter { $0.id != listID }) { list in
                        Text("Move to \u{201C}\(list.name)\u{201D}").tag(Optional(list.id))
                    }
                    Divider()
                    Text("Delete them, pinned ones too").tag(String?.none)
                }
                .pickerStyle(.radioGroup)
            } else {
                Text("The list is empty.").foregroundStyle(.secondary)
            }
            Text("Applications assigned to this list send their copies to \u{201C}\(settings.value.lists[0].name)\u{201D} again. Snippets naming it do the same.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete List", role: .destructive) {
                    remove(count > 0 ? target : ClipList.defaultID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Several entries selected: what can be done to all of them.
private struct MultipleDetail: View {
    let items: [ClipItem]
    let delete: () -> Void
    private var history: ClipboardHistory { .shared }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(items.count) entries selected").font(.title3)
            Text("Drag them onto a list in the sidebar to move them all.").foregroundStyle(.secondary)
            HStack {
                Menu("Move to List") {
                    ForEach(SettingsStore.shared.value.lists) { list in
                        Button(list.name) { for item in items { history.move(item.id, toList: list.id) } }
                    }
                }
                .fixedSize()
                Button(items.allSatisfy(\.pinned) ? "Unpin All" : "Pin All") {
                    let pin = !items.allSatisfy(\.pinned)
                    for item in items { history.setPinned(item.id, pin) }
                }
                Button("Delete \(items.count) Entries", role: .destructive, action: delete)
            }
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The context menu of the entries list: one entry's commands, or those
/// for several.
private struct ItemsActions: View {
    let ids: Set<UUID>
    let select: (UUID) -> Void
    private var history: ClipboardHistory { .shared }

    var body: some View {
        let items = history.items.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first {
            ItemActions(item: item, select: select)
        } else if !items.isEmpty {
            Menu("Move \(items.count) Entries to List") {
                ForEach(SettingsStore.shared.value.lists) { list in
                    Button(list.name) { for item in items { history.move(item.id, toList: list.id) } }
                }
            }
            Button("Pin \(items.count) Entries") { for item in items { history.setPinned(item.id, true) } }
            Button("Unpin \(items.count) Entries") { for item in items { history.setPinned(item.id, false) } }
            Divider()
            Button("Delete \(items.count) Entries", role: .destructive) { for item in items { history.delete(item.id) } }
        }
    }
}

/// The commands for one entry, for context menus.
private struct ItemActions: View {
    let item: ClipItem
    let select: (UUID) -> Void
    private var history: ClipboardHistory { .shared }

    var body: some View {
        Button("Put on Clipboard") { history.copy(item.id) }.disabled(item.filesGone)
        Button(item.pinned ? "Unpin" : "Pin") { history.setPinned(item.id, !item.pinned) }
        MoveToListMenu(item: item)
        if item.kind == .files {
            Button("Copy File Contents") { copyContents(of: item.fileURLs, from: item, select: select) }
                .disabled(item.filesGone)
            Button("Copy Names as Text") { try? history.copyFileText(of: item.id, .names) }
            Button("Copy Paths as Text") { try? history.copyFileText(of: item.id, .paths) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
                .disabled(item.filesGone)
        }
        if item.hasImageForText {
            Button("Extract Text") { extractText(from: item.id, select: select) }
        }
        if item.canBecomeSnippet {
            AddToSnippadMenu(item: item)
        }
        Divider()
        Button("Delete", role: .destructive) { history.delete(item.id) }
    }
}

/// Adds a text entry to one of the open .snippad files as a new snippet.
private struct AddToSnippadMenu: View {
    let item: ClipItem

    var body: some View {
        Menu("Add to Snippad") {
            ForEach(SnippadLibrary.shared.files, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    do {
                        try SnippadLibrary.shared.addSnippet(from: item, to: url)
                    } catch {
                        presentError(error, title: "The snippet could not be added")
                    }
                }
            }
            if SnippadLibrary.shared.files.isEmpty {
                Text("No .snippad file is open")
            }
        }
    }
}

/// Reads the text (and QR codes) of an image entry into a new text entry.
@MainActor
func extractText(from id: UUID, select: ((UUID) -> Void)? = nil) {
    Task {
        do {
            if let made = try await ClipboardHistory.shared.extractText(from: id) { select?(made.id) }
        } catch {
            presentError(error, title: "No text could be read")
        }
    }
}

private struct MoveToListMenu: View {
    let item: ClipItem
    var body: some View {
        Menu("Move to List") {
            ForEach(SettingsStore.shared.value.lists) { list in
                Toggle(list.name, isOn: Binding(get: { item.list == list.id },
                                                set: { _ in ClipboardHistory.shared.move(item.id, toList: list.id) }))
            }
        }
    }
}

@MainActor
private func copyContents(of urls: [URL], from item: ClipItem, select: (UUID) -> Void) {
    do {
        let made = try ClipboardHistory.shared.copyFileContents(urls, listID: item.listID)
        if let last = made.last, let id = ClipboardHistory.shared.items.first(where: { $0.digest == last.digest })?.id {
            select(id)
        }
    } catch {
        presentError(error, title: "Some files could not be put on the clipboard")
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let listName: String?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if item.pending == true {
                    ProgressView().controlSize(.small)
                } else {
                    ItemIcon(item: item).opacity(item.filesGone ? 0.4 : 1)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                    .foregroundStyle(item.filesGone ? .tertiary : .primary)
                    .strikethrough(item.filesGone)
                    .help(item.filesGone ? "These files no longer exist. Their names and paths can still be copied." : "")
                Text([listName, item.sourceApp, item.date.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.edited != nil {
                Image(systemName: "pencil").foregroundStyle(.secondary).font(.caption).help("Edited")
            }
            if item.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

private struct ItemIcon: View {
    let item: ClipItem

    var body: some View {
        if item.isPassword {
            Image(systemName: "key")
        } else {
            switch item.kind {
            case .image:
                if let image = item.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                }
            case .files:
                if let url = item.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                }
            case .url: Image(systemName: "link")
            case .richText: Image(systemName: "doc.richtext")
            case .color: Image(systemName: "paintpalette")
            case .other: Image(systemName: "doc")
            case .text: Image(systemName: "text.alignleft")
            }
        }
    }
}

private struct HistoryDetail: View {
    let item: ClipItem
    let select: (UUID) -> Void
    let delete: () -> Void

    @State private var editing = false
    @State private var editor = TextEditorController()
    @State private var chosenFiles: Set<URL> = []
    @State private var settings = SettingsStore.shared
    private var history: ClipboardHistory { .shared }

    /// A password shows only while it is being edited.
    private var hidden: Bool { item.isPassword && !editing }

    private var lineNumbers: LineNumberMode {
        LineNumberMode(rawValue: settings.value.lineNumbers) ?? .absolute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content.frame(maxHeight: .infinity)
            Divider()
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(8)
        }
        .labelStyle(.titleAndIcon)
        .toolbar { toolbar }
        .onAppear { chosenFiles = Set(item.fileURLs).subtracting(item.missingFiles) }
    }

    @ViewBuilder private var content: some View {
        if item.pending == true {
            ProgressView("Reading the text in the image\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hidden {
            ContentUnavailableView {
                Label(ClipItem.mask, systemImage: "key")
            } description: {
                Text("A password. It shows only while you edit it: click Edit in the toolbar.")
            }
        } else if item.isEditableText {
            TextEditorView(documentID: item.id, text: item.string ?? "",
                           rich: item.kind == .richText ? item.attributedString : nil,
                           editable: editing, lineNumbers: lineNumbers, wrap: settings.value.wordWrap, controller: editor,
                           onCopy: { [list = item.list, password = item.isPassword] in
                               ClipboardHistory.shared.captureOwnCopy(list: list, password: password)
                           },
                           concealCopies: item.isPassword) { plain, rich in
                history.updateText(item.id, plain: plain, rich: rich)
            }
        } else {
            switch item.kind {
            case .image:
                if let image = item.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
            case .files:
                filesView
            default:
                ScrollView {
                    Text(item.types.joined(separator: "\n"))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private var filesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let missing = Set(item.missingFiles)
            List(item.fileURLs, id: \.self) { url in
                Toggle(isOn: Binding(get: { chosenFiles.contains(url) },
                                     set: { if $0 { chosenFiles.insert(url) } else { chosenFiles.remove(url) } })) {
                    Label {
                        HStack {
                            Text(url.path).textSelection(.enabled)
                                .foregroundStyle(missing.contains(url) ? .tertiary : .primary)
                            if missing.contains(url) {
                                Text("no longer exists").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .opacity(missing.contains(url) ? 0.4 : 1)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(missing.contains(url))
            }
            HStack {
                let present = Set(item.fileURLs).subtracting(missing)
                Button(chosenFiles == present ? "Select None" : "Select All") {
                    chosenFiles = chosenFiles == present ? [] : present
                }
                .disabled(present.isEmpty)
                Spacer()
                Text("\(chosenFiles.count) of \(item.fileURLs.count) selected").foregroundStyle(.secondary)
            }
            .padding(8)
            if let metadata = item.metadata {
                Divider()
                ScrollView {
                    Text(metadata).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Put on Clipboard", systemImage: "arrow.up.doc.on.clipboard") { history.copy(item.id) }
                .disabled(item.filesGone)
                .help("Put this whole entry back on the clipboard (Return). To copy part of a text, select it and press ⌘C.")
            if item.isEditableText {
                Toggle(isOn: $editing) {
                    Label(editing ? "Editing" : "Edit", systemImage: editing ? "pencil.circle.fill" : "pencil.circle")
                }
                .help(item.isPassword
                      ? (editing ? "The password shows while you edit it. Click to hide it again." : "Click to show and edit the password")
                      : editing ? "Every change is kept as you type. Click to make the text read-only again."
                      : "The text is read-only. Click to edit it; changes are kept as you type, there is no Save.")
                if !hidden {
                    TextCommandsMenu(editor: editor, editing: editing,
                                     convertToPlainText: item.kind == .richText ? { history.convertToPlainText(item.id) } : nil)
                    Button("Export…", systemImage: "square.and.arrow.up") { export() }
                        .help("Save the text to a file")
                }
            }
            if item.hasImageForText {
                Button("Extract Text", systemImage: "text.viewfinder") { extractText(from: item.id, select: select) }
                    .help("Read the text and any QR code in the image into a new text entry of the same list (on this Mac, with Vision)")
            }
            if item.kind == .files {
                Button("Copy Selected Files", systemImage: "doc.on.doc") {
                    do {
                        let made = try history.copyFiles(item.id, only: chosenFiles)
                        select(history.items.first { $0.digest == made.digest }?.id ?? made.id)
                    } catch {
                        presentError(error, title: "The files could not be copied")
                    }
                }
                .disabled(chosenFiles.isEmpty)
                .help("A new entry with only the checked files, put on the clipboard")
                Button("Copy File Contents", systemImage: "doc.text") {
                    copyContents(of: item.fileURLs.filter(chosenFiles.contains), from: item, select: select)
                }
                .disabled(chosenFiles.isEmpty)
                .help("Put what the checked files contain on the clipboard, as text or image; one new entry per file")
                Menu {
                    Button("Copy Names as Text") { try? history.copyFileText(of: item.id, .names) }
                    Button("Copy Paths as Text") { try? history.copyFileText(of: item.id, .paths) }
                } label: {
                    Label("Copy as Text", systemImage: "doc.plaintext")
                }
                .help("Put the files' names, or their full paths, on the clipboard as text, one per line. Works even when the files are gone.")
            }
            Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") {
                history.setPinned(item.id, !item.pinned)
            }
            .help("Pinned entries are listed first and stay when the history is cleared or trimmed")
            Menu {
                MoveToListMenu(item: item)
            } label: {
                Label("List", systemImage: "tray.2")
            }
            .help("Move this entry to another list")
            Button("Delete", systemImage: "trash", action: delete)
                .help("Delete this entry")
        }
    }

    private var details: String {
        var parts = [item.date.formatted(date: .abbreviated, time: .standard)]
        if let app = item.sourceApp { parts.append("from \(app)") }
        if let edited = item.edited { parts.append("edited \(edited.formatted(.relative(presentation: .named)))") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
        if let s = item.string, !hidden { parts.append("\(s.count) characters, \(s.split(separator: "\n", omittingEmptySubsequences: false).count) lines") }
        parts.append(item.types.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func export() {
        let panel = NSSavePanel()
        let rich = item.kind == .richText
        panel.allowedContentTypes = rich ? [.plainText, .rtf] : [.plainText]
        panel.allowsOtherFileTypes = true
        let base = item.title.prefix(40).replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (base.isEmpty ? "Clipboard" : base) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "rtf", let a = item.attributedString,
               let data = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:]) {
                try data.write(to: url, options: .atomic)
            } else {
                try Data((item.string ?? "").utf8).write(to: url, options: .atomic)
            }
        } catch {
            presentError(error, title: "The text could not be exported")
        }
    }
}
