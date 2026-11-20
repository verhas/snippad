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

    init(name: String = "", value: String = "", expires: Int? = nil, once: Bool = false, password: Bool = false,
         list: String? = nil, kind: SnippetKind = .text) {
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
            SnippetDraft(name: $0.name, value: $0.value, expires: $0.expires, once: $0.once, password: $0.password, list: $0.list,
                         kind: $0.kind)
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
                                  password: draft.password, list: draft.list, kind: draft.kind)
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
             d.nextID.flatMap { id in drafts.first { $0.id == id }?.name } ?? "", d.list ?? "", d.kind.rawValue].joined(separator: "\u{0}")
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
                                password: d.password, list: d.list, kind: d.kind)
        copy.nextID = d.nextID
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
                    .contextMenu {
                        Button("Put on Clipboard") { model.copy(draft.id) }
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
                Menu {
                    Button("Text Snippet", action: model.add)
                    Button("File Snippet…", action: model.addFile)
                    Button("Image Snippet…", action: model.addImage)
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    model.add()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a text snippet; hold the button for a file or an image snippet. Rich text snippets come from the history: Add to Snippad.")
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
        .foregroundStyle(.secondary)
    }
}

/// One snippet in the history window's detail pane: the form, or its value
/// alone filling the pane (maximized) with all the text editor's commands.
struct SnippetDetail: View {
    @Bindable var draft: SnippetDraft
    let model: SnippadEditorModel
    @State private var revealed = false
    @State private var maximized = false
    @State private var editor = TextEditorController()
    @State private var settings = SettingsStore.shared

    private var valueVisible: Bool { draft.kind == .text && (!draft.password || revealed) }

    var body: some View {
        Group {
            if maximized && valueVisible {
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
        .toolbar {
            ToolbarItemGroup {
                Button("Put on Clipboard", systemImage: "arrow.up.doc.on.clipboard") { model.copy(draft.id) }
                    .help("Put this snippet on the clipboard, with its rules (Return)")
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
            }
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
    @State private var settings = SettingsStore.shared

    var body: some View {
        Menu {
            if let convertToPlainText {
                Button("Convert to Plain Text", action: convertToPlainText)
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

/// The value of a rich text, file or image snippet: shown, not edited.
private struct SnippetValuePreview: View {
    @Bindable var draft: SnippetDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch draft.kind {
            case .text:
                EmptyView()
            case .rich:
                ScrollView {
                    Text(AttributedString(NSAttributedString(rtf: Data(draft.value.utf8), documentAttributes: nil)
                                          ?? NSAttributedString(string: draft.value)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(minHeight: 80, maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                Text("Formatted text is not edited in Snippad; it is pasted as copied.").font(.caption).foregroundStyle(.secondary)
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
                    Text("\(Int(image.size.width))×\(Int(image.size.height)), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)), kept in the .snippad file")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The image cannot be read.").foregroundStyle(.red)
                }
            }
        }
    }
}
