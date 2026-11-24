import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One snippet while it is being edited. The chain points at another draft
/// rather than at a name, so renaming the target keeps the chain.
@MainActor
@Observable
final class SnippetDraft: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    var expires: Int?
    var once: Bool
    var password: Bool
    var nextID: UUID?
    /// The name of the history list its copies go to; nil is the default.
    var list: String?
    /// Only text is edited; rich text, files and images are shown.
    var kind: SnippetKind
    /// The system-wide shortcut, as written in the file.
    var shortcut: String?
    /// An edited image's original and edits; `value` is the result.
    var edits: ImageEdits?
    /// Counts changes to `edits`, so a change is noticed without comparing
    /// images.
    var editsVersion = 0
    /// The button's colour, `"#RRGGBB"`: random for a new snippet.
    var color: String
    var icon: String?
    var iconCorner: SnippetCorner = .topTrailing
    /// Where the button sits in its window, and its size; nil is automatic.
    var origin: SnippetPoint?
    var size: SnippetSize?

    init(name: String = "", value: String = "", expires: Int? = nil, once: Bool = false, password: Bool = false,
         list: String? = nil, kind: SnippetKind = .text, color: String = SnippetColors.random()) {
        self.color = color
        self.kind = kind
        self.name = name
        self.value = value
        self.expires = expires
        self.once = once
        self.password = password
        self.list = list
    }
}

/// The snippets of one file, as the history window edits them. Changes are
/// written to the file shortly after they are made -- there is no Save, as
/// in the rest of the history window. A change that would make the file
/// unreadable (a snippet without a name) is shown as a problem and not
/// written until it is fixed.
@MainActor
@Observable
final class SnippadEditorModel {
    private(set) var url: URL
    var drafts: [SnippetDraft] = []
    var selection: SnippetDraft.ID?
    var problem: String?
    @ObservationIgnored private var saved: [Snippet] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        load()
    }

    func load() {
        switch SnippadContent.read(url) {
        case .success(let snippets):
            set(snippets)
            problem = nil
        case .failure(let error):
            set([])
            problem = "The file could not be read: \(error.localizedDescription)"
        }
        saved = (try? snippets()) ?? []
    }

    private func set(_ snippets: [Snippet]) {
        let keep = selection.flatMap { id in drafts.firstIndex { $0.id == id } }
        drafts = snippets.map {
            // A file from before snippets had colours keeps the colour its
            // window showed, and is written with it next time it is saved.
            let d = SnippetDraft(name: $0.name, value: $0.value, expires: $0.expires, once: $0.once, password: $0.password,
                                 list: $0.list, kind: $0.kind, color: $0.shownColor)
            d.shortcut = $0.shortcut
            d.edits = $0.edits
            d.icon = $0.icon
            d.iconCorner = $0.iconCorner
            d.origin = $0.origin
            d.size = $0.size
            return d
        }
        for (snippet, draft) in zip(snippets, drafts) {
            if let next = snippet.next {
                draft.nextID = drafts.first { $0.name == next }?.id
            }
        }
        selection = keep.flatMap { drafts.indices.contains($0) ? drafts[$0].id : nil } ?? drafts.first?.id
    }

    /// The drafts as snippets; throws when a chain cannot be written as a
    /// name.
    func snippets() throws -> [Snippet] {
        try drafts.enumerated().map { index, draft in
            var snippet = Snippet(id: index, name: draft.name, value: draft.value, expires: draft.expires, once: draft.once,
                                  password: draft.password, list: draft.list, kind: draft.kind, shortcut: draft.shortcut,
                                  edits: draft.kind == .image ? draft.edits : nil, color: draft.color, icon: draft.icon,
                                  iconCorner: draft.iconCorner, origin: draft.origin, size: draft.size)
            if let nextID = draft.nextID, let target = drafts.first(where: { $0.id == nextID }) {
                guard drafts.filter({ $0.name == target.name }).count == 1 else {
                    throw SnippadParseError(line: 0, message: "Several snippets are named \u{201C}\(target.name)\u{201D}, and \u{201C}\(draft.name)\u{201D} chains to one of them. Chain targets need a name of their own.")
                }
                snippet.next = target.name
            }
            return snippet
        }
    }

    /// Everything the file is written from; a change to it schedules a save.
    var fingerprint: [String] {
        drafts.map { d in
            [d.name, d.value, d.expires.map(String.init) ?? "", d.once ? "1" : "0", d.password ? "1" : "0",
             d.nextID.flatMap { id in drafts.first { $0.id == id }?.name } ?? "", d.list ?? "", d.kind.rawValue,
             d.shortcut ?? "", String(d.editsVersion), d.color, d.icon ?? "", d.iconCorner.rawValue,
             d.origin.map { "\($0.x),\($0.y)" } ?? "", d.size.map { "\($0.width)x\($0.height)" } ?? ""].joined(separator: "\u{0}")
        }
    }

    var isDirty: Bool {
        (try? snippets()).map { $0 != saved } ?? true
    }

    /// Saves a moment after the last change.
    func scheduleSave() {
        guard isDirty else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveIfNeeded()
        }
    }

    func saveIfNeeded() {
        saveTask?.cancel()
        if isDirty { save() }
    }

    @discardableResult
    func save() -> Bool {
        do {
            guard !drafts.isEmpty else {
                throw SnippadParseError(line: 0, message: "A .snippad file needs at least one snippet; this one is not saved until it has one.")
            }
            if drafts.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw SnippadParseError(line: 0, message: "Every snippet needs a name; the file is saved once each has one.")
            }
            let snippets = try snippets()
            try SnippadWriter.save(snippets, to: url)
            saved = snippets
            problem = nil
            SnippadLibrary.shared.reloadIfOpen(url)
            SnippetShortcuts.refresh()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func add() {
        let draft = SnippetDraft(name: uniqueName("New snippet"))
        if let selection, let index = drafts.firstIndex(where: { $0.id == selection }) {
            drafts.insert(draft, at: index + 1)
        } else {
            drafts.append(draft)
        }
        selection = draft.id
    }

    @discardableResult
    func append(name: String, value: String, password: Bool, list: String?, kind: SnippetKind = .text) -> SnippetDraft {
        let draft = SnippetDraft(name: uniqueName(name), value: value, password: password, list: list, kind: kind)
        drafts.append(draft)
        selection = draft.id
        return draft
    }

    /// A snippet that puts a file on the clipboard, chosen in an open panel.
    func addFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "The snippet puts the file itself on the clipboard, as Finder copies it."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { append(name: url.lastPathComponent, value: url.path, password: false, list: nil, kind: .file) }
    }

    /// A snippet holding an image, read from a file and kept in the
    /// .snippad file as base64 PNG.
    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let png = Self.png(fromImageFile: url) else {
                presentError(ClipboardError("\u{201C}\(url.lastPathComponent)\u{201D} cannot be read as an image."), title: "The image could not be added")
                continue
            }
            append(name: url.deletingPathExtension().lastPathComponent, value: png.base64EncodedString(), password: false,
                   list: nil, kind: .image)
        }
    }

    static func png(fromImageFile url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    func duplicate(_ id: SnippetDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let d = drafts[index]
        let copy = SnippetDraft(name: uniqueName(d.name), value: d.value, expires: d.expires, once: d.once,
                                password: d.password, list: d.list, kind: d.kind, color: d.color)
        copy.nextID = d.nextID
        copy.edits = d.edits
        copy.icon = d.icon
        copy.iconCorner = d.iconCorner
        copy.size = d.size
        drafts.insert(copy, at: index + 1)
        selection = copy.id
    }

    func remove(_ id: SnippetDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        for draft in drafts where draft.nextID == id { draft.nextID = nil }
        selection = drafts.indices.contains(index) ? drafts[index].id : drafts.last?.id
    }

    func move(from source: IndexSet, to destination: Int) {
        drafts.move(fromOffsets: source, toOffset: destination)
    }

    /// Puts a snippet on the clipboard with its rules, as the board does.
    func copy(_ id: SnippetDraft.ID) {
        guard let all = try? snippets(), let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let s = all[index]
        PasteEngine.shared.put(types: s.pasteboardTypes, name: s.name, rules: s.rules(in: all))
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(drafts.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// The snippets of a file, in the history window's middle column.
struct SnippetListColumn: View {
    @Bindable var model: SnippadEditorModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.drafts) { draft in
                DraftRow(draft: draft, model: model)
                    .tag(draft.id)
                    // Onto another file in the sidebar: copied there, or
                    // moved with ⌘ held. Into another app, unless it has
                    // rules a drop could not keep.
                    .onDrag { SnippetDrag(file: model.url.path, id: draft.id).itemProvider(export: DragExport.export(for: draft)) }
                    .help("Drag onto another file in the sidebar to copy it there (hold ⌘ when dropping to move it), or into another app")
                    .contextMenu {
                        Button("Put on Clipboard") { model.copy(draft.id) }
                        Divider()
                        Button("New Snippet", action: model.add)
                        Button("New File Snippet…", action: model.addFile)
                        Button("New Image Snippet…", action: model.addImage)
                        Button("Duplicate") { model.duplicate(draft.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.remove(draft.id) }
                    }
            }
            .onMove(perform: model.move)
        }
        .onDeleteCommand {
            if let id = model.selection { model.remove(id) }
        }
        .onKeyPress(.return) {
            if let id = model.selection { model.copy(id) }
            return .handled
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("New Snippet", systemImage: "plus", action: model.add)
                    .labelStyle(.titleAndIcon)
                    .help("Add a text snippet after the selected one")
                Menu {
                    Button("New Text Snippet", action: model.add)
                    Button("New File Snippet…", action: model.addFile)
                    Button("New Image Snippet…", action: model.addImage)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New text, file or image snippet. Rich text snippets come from the history: Add to Snippad.")
                Button("Remove Snippet", systemImage: "minus") {
                    if let id = model.selection { model.remove(id) }
                }
                .disabled(model.selection == nil)
                .help("Remove the selected snippet")
                Spacer()
                Text(model.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .onChange(of: model.fingerprint) { model.scheduleSave() }
    }
}

private struct DraftRow: View {
    let draft: SnippetDraft
    let model: SnippadEditorModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.name.isEmpty ? "(no name)" : draft.name)
                    .foregroundStyle(draft.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(draft.password ? ClipItem.mask : draftPreview(draft).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            RuleBadges(expires: draft.expires, once: draft.once,
                       next: draft.nextID.flatMap { id in model.drafts.first { $0.id == id }?.name },
                       password: draft.password)
        }
    }
}

@MainActor
private func draftPreview(_ d: SnippetDraft) -> String {
    Snippet(id: 0, name: d.name, value: d.value, kind: d.kind).preview
}

/// Small icons for a snippet's clipboard rules, shared by the editor and the
/// board.
struct RuleBadges: View {
    let expires: Int?
    let once: Bool
    let next: String?
    var password = false
    /// Their colour; secondary when nil.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if password {
                Image(systemName: "key").help("A password: hidden, and shown as dots in the history")
            }
            if let expires {
                Image(systemName: "timer").help("Leaves the clipboard after \(SnippetDuration.text(expires))")
            }
            if once {
                Image(systemName: "1.circle").help("Leaves the clipboard after it is pasted once")
            }
            if let next {
                Image(systemName: "link").help("Once pasted, \u{201C}\(next)\u{201D} goes on the clipboard")
            }
        }
        .font(.caption)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }
}

/// One snippet in the history window's detail pane: the form, or its value
/// alone filling the pane (maximized) with all the text editor's commands.
struct SnippetDetail: View {
    @Bindable var draft: SnippetDraft
    let model: SnippadEditorModel
    @State private var revealed = false
    @State private var maximized = false
    @State private var editingImage = false
    @State private var editor = TextEditorController()
    @State private var settings = SettingsStore.shared

    private var valueVisible: Bool { draft.kind == .text && (!draft.password || revealed) }

    var body: some View {
        Group {
            if editingImage && draft.kind == .image,
               let edits = draft.edits ?? Data(base64Encoded: draft.value, options: .ignoreUnknownCharacters).map({ ImageEdits(original: $0) }) {
                ImageEditorHost(edits: edits, target: .snippet(SnippadLibrary.key(model.url), draft.id)) { [draft] edits, png in
                    draft.edits = edits
                    draft.value = png.base64EncodedString()
                    draft.editsVersion += 1
                }
            } else if maximized && valueVisible {
                VStack(spacing: 0) {
                    HStack {
                        Text(draft.name.isEmpty ? "(no name)" : draft.name).font(.headline)
                        Spacer()
                        Button("Restore", systemImage: "arrow.down.right.and.arrow.up.left") { maximized = false }
                            .help("Back to the snippet's form")
                    }
                    .padding(8)
                    Divider()
                    valueEditor(lineNumbers: LineNumberMode(rawValue: settings.value.lineNumbers) ?? .absolute)
                }
            } else {
                DraftForm(draft: draft, model: model, revealed: $revealed, maximized: $maximized) {
                    valueEditor(lineNumbers: .off)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .onAppear(perform: openEditorIfAsked)
        .onChange(of: HistoryNavigation.shared.openImageEditor) { openEditorIfAsked() }
        .toolbar {
            ToolbarItemGroup {
                Button("Put on Clipboard", systemImage: "arrow.up.doc.on.clipboard") { model.copy(draft.id) }
                    .help("Put this snippet on the clipboard, with its rules (Return)")
                if draft.kind == .image {
                    Toggle(isOn: $editingImage) {
                        Label(editingImage ? "Editing" : "Edit", systemImage: editingImage ? "pencil.circle.fill" : "pencil.circle")
                    }
                    .help(editingImage ? "Every change is saved to the .snippad file as you make it. Click to go back to the snippet's form."
                          : "Draw, write, paste, select areas to delete, invert, make black & white or pixelate, and crop. The original image is kept in the file, and everything added stays editable.")
                }
                if valueVisible {
                    Button(maximized ? "Restore" : "Maximize",
                           systemImage: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        maximized.toggle()
                    }
                    .help(maximized ? "Back to the snippet's form" : "Edit the value in the whole pane, with line numbers and the Text commands")
                    TextCommandsMenu(editor: editor, editing: true)
                }
            }
        }
    }

    /// An agent asked for this snippet's image editor.
    private func openEditorIfAsked() {
        guard HistoryNavigation.shared.openImageEditor == draft.id else { return }
        HistoryNavigation.shared.openImageEditor = nil
        if draft.kind == .image { editingImage = true }
    }

    private func valueEditor(lineNumbers: LineNumberMode) -> some View {
        TextEditorView(documentID: draft.id, text: draft.value, rich: nil, editable: true, lineNumbers: lineNumbers,
                       wrap: settings.value.wordWrap, controller: editor,
                       onCopy: { [list = draft.list, password = draft.password] in
                           ClipboardHistory.shared.captureOwnCopy(list: list, password: password)
                       },
                       concealCopies: draft.password) { plain, _ in
            draft.value = plain
        }
    }
}

private struct DraftForm<ValueEditor: View>: View {
    @Bindable var draft: SnippetDraft
    let model: SnippadEditorModel
    @Binding var revealed: Bool
    @Binding var maximized: Bool
    @ViewBuilder let valueEditor: () -> ValueEditor
    @State private var expiresText = ""
    @State private var settings = SettingsStore.shared

    private var presets: [Int] { [10, 30, 60, 120, 300, 900, 3600] }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("The button\u{2019}s label"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                if draft.kind != .text {
                    LabeledContent(kindTitle) { SnippetValuePreview(draft: draft) }
                } else {
                LabeledContent("Value") {
                    HStack(alignment: .top) {
                        if draft.password && !revealed {
                            Text(String(repeating: "•", count: 12))
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                                .help("Hidden because this is a password; click the eye to show and edit it")
                        } else {
                            valueEditor()
                                .frame(minHeight: draft.password ? 40 : 140)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                        }
                        VStack {
                            if draft.password {
                                Button(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye") {
                                    revealed.toggle()
                                    if !revealed { maximized = false }
                                }
                                .help(revealed ? "Hide the password" : "Show the password to read or edit it")
                            }
                            if !draft.password || revealed {
                                Button("Maximize", systemImage: "arrow.up.left.and.arrow.down.right") { maximized = true }
                                    .help("Edit the value in the whole pane, with line numbers and the Text commands")
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Toggle("Password", isOn: $draft.password)
                    .help("Hidden everywhere -- here until you click the eye, as dots in menus and the history")
                }
                Picker("Copies go to the list", selection: $draft.list) {
                    Text(settings.value.lists[0].name).tag(String?.none)
                    ForEach(settings.value.lists.dropFirst()) { list in
                        Label(list.name, systemImage: list.symbol).tag(Optional(list.name))
                    }
                    if let name = draft.list, settings.listID(named: name) == nil {
                        Text("\(name) (no such list)").tag(Optional(name))
                    }
                }
                .help("The history list the value is recorded in when copied; that list's Paste Guard rules apply to it")
                LabeledContent("Shortcut") {
                    ShortcutRecorder(draft: draft, fileURL: model.url)
                }
            }
            SnippetLookSection(draft: draft, model: model)
            Section("On the clipboard") {
                Toggle("Remove from the clipboard after it is pasted once", isOn: $draft.once)
                HStack {
                    Toggle("Remove from the clipboard after", isOn: Binding(
                        get: { draft.expires != nil },
                        set: { on in
                            draft.expires = on ? (SnippetDuration.seconds(from: expiresText) ?? 30) : nil
                            expiresText = draft.expires.map(SnippetDuration.text) ?? expiresText
                        }))
                    TextField("Duration", text: $expiresText, prompt: Text("30s"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(draft.expires == nil)
                        .onSubmit(applyExpires)
                        .onChange(of: expiresText) { applyExpires() }
                    Menu("Presets") {
                        ForEach(presets, id: \.self) { seconds in
                            Button(SnippetDuration.text(seconds)) {
                                draft.expires = seconds
                                expiresText = SnippetDuration.text(seconds)
                            }
                        }
                    }
                    .fixedSize()
                }
                Picker("Part of a chain. Once pasted, put on the clipboard", selection: $draft.nextID) {
                    Text("Nothing").tag(UUID?.none)
                    Divider()
                    ForEach(model.drafts.filter { $0.id != draft.id }) { other in
                        Text(other.name.isEmpty ? "(no name)" : other.name).tag(Optional(other.id))
                    }
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { expiresText = draft.expires.map(SnippetDuration.text) ?? "30s" }
    }

    private var kindTitle: String {
        switch draft.kind {
        case .text: "Value"
        case .rich: "Rich text"
        case .file: "File"
        case .image: "Image"
        }
    }

    private func applyExpires() {
        guard draft.expires != nil, let seconds = SnippetDuration.seconds(from: expiresText), seconds > 0 else { return }
        draft.expires = seconds
    }

    private var explanation: String {
        var parts: [String] = []
        if let next = draft.nextID.flatMap({ id in model.drafts.first { $0.id == id } }) {
            parts.append("After an app pastes this snippet, \u{201C}\(next.name)\u{201D} replaces it on the clipboard, for a user name followed by its password.")
        } else if draft.once {
            parts.append("After an app pastes this snippet, the clipboard is emptied.")
        }
        if let s = draft.expires {
            parts.append("If it is still on the clipboard after \(SnippetDuration.text(s)), the clipboard is emptied.")
        }
        return parts.isEmpty ? "The value stays on the clipboard until something else is copied." : parts.joined(separator: " ")
    }
}

/// The Text menu of the history window's toolbar: find, line commands, the
/// text transforms, wrapping and line numbers.
struct TextCommandsMenu: View {
    let editor: TextEditorController
    let editing: Bool
    /// For rich text: drops the formatting. Offered also when not editing.
    var convertToPlainText: (() -> Void)? = nil
    /// For plain text: makes it formatted text, to edit with fonts.
    var makeRichText: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared

    var body: some View {
        Menu {
            if let convertToPlainText {
                Button("Convert to Plain Text", action: convertToPlainText)
                Divider()
            }
            if let makeRichText {
                Button("Make Rich Text", action: makeRichText)
                Divider()
            }
            Button("Find…") { editor.find() }
            Button("Find and Replace…") { editor.findAndReplace() }.disabled(!editing)
            Divider()
            Button("Move Line Up  ⇧⌘↑") { editor.moveLinesUp() }.disabled(!editing)
            Button("Move Line Down  ⇧⌘↓") { editor.moveLinesDown() }.disabled(!editing)
            Button("Duplicate Line  ⇧⌘D") { editor.duplicateLines() }.disabled(!editing)
            Button("Delete Line  ⌘⌫") { editor.deleteLines() }.disabled(!editing)
            Divider()
            ForEach(Array(TextTransform.allCases.enumerated()), id: \.offset) { _, t in
                Button(t.title) { editor.transform(t) }.disabled(!editing)
            }
            Divider()
            Toggle("Wrap Lines", isOn: $settings.value.wordWrap)
            Picker("Line Numbers", selection: Binding(get: { LineNumberMode(rawValue: settings.value.lineNumbers) ?? .absolute },
                                                      set: { settings.value.lineNumbers = $0.rawValue })) {
                ForEach(LineNumberMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Text", systemImage: "text.magnifyingglass")
        }
        .help("Find, replace, line commands, case and spaces (on the selection, or all the text), wrapping and line numbers")
    }
}

/// The value of a rich text, file or image snippet: rich text is edited
/// here, with fonts; a file or an image is shown.
private struct SnippetValuePreview: View {
    @Bindable var draft: SnippetDraft
    @State private var richEditor = TextEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch draft.kind {
            case .text:
                EmptyView()
            case .rich:
                let rich = NSAttributedString(rtf: Data(draft.value.utf8), documentAttributes: nil) ?? NSAttributedString(string: draft.value)
                VStack(spacing: 0) {
                    RichTextBar(editor: richEditor)
                    Divider()
                    TextEditorView(documentID: draft.id, text: rich.string, rich: rich, editable: true, lineNumbers: .off,
                                   controller: richEditor) { [draft] _, edited in
                        guard let edited,
                              let rtf = edited.rtf(from: NSRange(location: 0, length: edited.length), documentAttributes: [:]),
                              let text = String(data: rtf, encoding: .utf8) else { return }
                        draft.value = text
                    }
                    .frame(minHeight: 160)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            case .file:
                let url = URL(fileURLWithPath: (draft.value as NSString).expandingTildeInPath)
                let exists = FileManager.default.fileExists(atPath: url.path)
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                        .opacity(exists ? 1 : 0.4)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if !exists { Text("This file no longer exists.").font(.caption).foregroundStyle(.red) }
                    }
                }
                HStack {
                    Button("Choose Another File…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.directoryURL = url.deletingLastPathComponent()
                        if panel.runModal() == .OK, let new = panel.url { draft.value = new.path }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!exists)
                }
            case .image:
                if let data = Data(base64Encoded: draft.value, options: .ignoreUnknownCharacters), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 260)
                    Text("\(Int(image.size.width))×\(Int(image.size.height)), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)), kept in the .snippad file" + (draft.edits.map { $0.isUnchanged ? "" : ", edited (the original is kept too)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The image cannot be read.").foregroundStyle(.red)
                }
            }
        }
    }
}

/// Records a snippet's system-wide shortcut: click, then press the keys.
/// Escape cancels; Delete removes the shortcut.
private struct ShortcutRecorder: View {
    @Bindable var draft: SnippetDraft
    let fileURL: URL
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    private var current: KeyShortcut? { draft.shortcut.flatMap(KeyShortcut.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Press the keys\u{2026}" : current?.display ?? "Record Shortcut")
                        .frame(minWidth: 120)
                }
                .help("A key combination that copies this snippet from any app, with ⌃, ⌥ or ⌘ (a function key may stand alone). Escape cancels, Delete removes it.")
                if draft.shortcut != nil && !recording {
                    Button("Remove", systemImage: "xmark.circle.fill") { draft.shortcut = nil; message = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            if let note = message ?? warning {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    /// Someone else has it, or macOS would not register it.
    private var warning: String? {
        guard let current else { return nil }
        if let other = SnippetShortcuts.conflict(for: current, except: (fileURL, draft.name)) {
            return "\(current.display) is also \(other); only one of them works."
        }
        if SnippetShortcuts.unavailable.contains(current) {
            return "macOS did not give Snippad \(current.display); another app may have it."
        }
        return nil
    }

    private func start() {
        message = nil
        recording = true
        SnippetShortcuts.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53:  // Escape
                stop()
            case 51, 117:  // Delete, Forward Delete
                draft.shortcut = nil
                stop()
            default:
                guard let shortcut = KeyShortcut(keyCode: event.keyCode, flags: event.modifierFlags) else {
                    message = "That key cannot be a shortcut; use a letter, digit, punctuation or function key."
                    return nil
                }
                guard shortcut.isUsable else {
                    message = "Hold ⌃, ⌥ or ⌘ with the key (only function keys may stand alone)."
                    return nil
                }
                draft.shortcut = shortcut.text
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            SnippetShortcuts.resume()
        }
    }
}

/// How a snippet's button looks in its file's window: colour, icon, and
/// where it sits.
private struct SnippetLookSection: View {
    @Bindable var draft: SnippetDraft
    let model: SnippadEditorModel
    @State private var choosingIcon = false

    var body: some View {
        Section("Button") {
            LabeledContent("Colour") {
                HStack {
                    ColorPicker("Colour", selection: Binding(get: { Color(snippadHex: draft.color) },
                                                             set: { draft.color = $0.snippadHex }),
                                supportsOpacity: false)
                        .labelsHidden()
                    Button("Random", systemImage: "dice") {
                        draft.color = SnippetColors.palette.filter { $0 != draft.color }.randomElement() ?? SnippetColors.random()
                    }
                    .help("Another colour, picked at random")
                    Spacer()
                    preview
                }
            }
            LabeledContent("Icon") {
                HStack {
                    Button {
                        choosingIcon = true
                    } label: {
                        if let icon = draft.icon {
                            Label(icon, systemImage: icon)
                        } else {
                            Text("Choose\u{2026}")
                        }
                    }
                    .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
                        IconChooser(icon: $draft.icon) { choosingIcon = false }
                    }
                    if draft.icon != nil {
                        Picker("Corner", selection: $draft.iconCorner) {
                            ForEach(SnippetCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("The corner of the button the icon sits in; in the file\u{2019}s window, drag the icon to another corner")
                        Button("Remove", systemImage: "xmark.circle.fill") { draft.icon = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("No icon")
                    }
                }
            }
            LabeledContent("Place") {
                HStack {
                    Toggle("Automatic", isOn: Binding(get: { draft.origin == nil }, set: { automatic in
                        draft.origin = automatic ? nil : shown.map { SnippetPoint(x: Int($0.minX), y: Int($0.minY)) }
                            ?? SnippetPoint(x: Int(BoardLayout.padding), y: Int(BoardLayout.padding))
                    }))
                    .help("On: the button follows the ones before it. Off: it stays at the place below.")
                    if draft.origin != nil {
                        number("x", Binding(get: { draft.origin?.x ?? 0 }, set: { draft.origin?.x = max(0, $0) }))
                        number("y", Binding(get: { draft.origin?.y ?? 0 }, set: { draft.origin?.y = max(0, $0) }))
                    }
                    Spacer()
                }
            }
            LabeledContent("Size") {
                HStack {
                    Toggle("Automatic", isOn: Binding(get: { draft.size == nil }, set: { automatic in
                        draft.size = automatic ? nil : shown.map { SnippetSize(width: Int($0.width), height: Int($0.height)) }
                            ?? SnippetSize(width: Int(BoardLayout.minimumSize.width), height: Int(BoardLayout.minimumSize.height))
                    }))
                    .help("On: as large as the name needs. Off: the size below.")
                    if draft.size != nil {
                        number("width", Binding(get: { draft.size?.width ?? 0 },
                                                set: { draft.size?.width = max(SnippetSize.minimum.width, $0) }))
                        number("height", Binding(get: { draft.size?.height ?? 0 },
                                                 set: { draft.size?.height = max(SnippetSize.minimum.height, $0) }))
                    }
                    Spacer()
                }
            }
            Text("In the file\u{2019}s window, drag a button to move it and its bottom right corner to resize it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the file's window draws this button now, if it is open.
    private var shown: CGRect? {
        SnippadLibrary.shared.shownFrames[SnippadLibrary.key(model.url)]?[draft.name]
    }

    private func number(_ title: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 56)
        }
    }

    /// The button as the window shows it.
    private var preview: some View {
        Text(draft.name.isEmpty ? "(no name)" : draft.name)
            .lineLimit(1)
            .foregroundStyle(SnippetColors.isLight(draft.color) ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, draft.icon == nil ? 12 : 22)
            .padding(.vertical, 5)
            .background(Color(snippadHex: draft.color), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: {
                switch draft.iconCorner {
                case .topLeading: .topLeading
                case .topTrailing: .topTrailing
                case .bottomLeading: .bottomLeading
                case .bottomTrailing: .bottomTrailing
                }
            }()) {
                if let icon = draft.icon {
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold)).padding(3)
                        .foregroundStyle(SnippetColors.isLight(draft.color) ? Color.black.opacity(0.7) : .white)
                }
            }
            .frame(maxWidth: 200)
    }
}

/// A grid of SF Symbols to choose a snippet's icon from, or any symbol by
/// name.
private struct IconChooser: View {
    @Binding var icon: String?
    let done: () -> Void
    @State private var name = ""

    static let symbols = [
        "star.fill", "heart.fill", "bolt.fill", "flag.fill", "bookmark.fill", "tag.fill", "pin.fill", "bell.fill",
        "key.fill", "lock.fill", "person.fill", "person.2.fill", "envelope.fill", "phone.fill", "message.fill", "at",
        "house.fill", "building.2.fill", "briefcase.fill", "cart.fill", "creditcard.fill", "banknote.fill", "gift.fill", "calendar",
        "clock.fill", "doc.fill", "folder.fill", "paperclip", "link", "globe", "network", "server.rack",
        "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces", "number", "textformat", "signature", "pencil", "hammer.fill",
        "wrench.and.screwdriver.fill", "gearshape.fill", "lightbulb.fill", "exclamationmark.triangle.fill", "checkmark.seal.fill", "questionmark.circle.fill", "info.circle.fill", "sparkles",
        "leaf.fill", "flame.fill", "drop.fill", "sun.max.fill", "moon.fill", "cloud.fill", "car.fill", "airplane",
        "cup.and.saucer.fill", "fork.knife", "music.note", "camera.fill", "photo.fill", "film.fill", "gamecontroller.fill", "cross.case.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        icon = symbol
                        done()
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 26, height: 26)
                            .background(icon == symbol ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.borderless)
                    .help(symbol)
                }
            }
            HStack {
                TextField("Symbol name", text: $name, prompt: Text("Any SF Symbol, such as tortoise.fill"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useName)
                Button("Use", action: useName)
                    .disabled(NSImage(systemSymbolName: name.trimmingCharacters(in: .whitespaces), accessibilityDescription: nil) == nil)
            }
            if icon != nil {
                Button("No Icon") {
                    icon = nil
                    done()
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { name = icon ?? "" }
    }

    private func useName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil else { return }
        icon = n
        done()
    }
}
