import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// What an entry or a snippet dragged out of the Organizer gives other
/// applications: text, rich text, a picture or a file. Finder makes a file of
/// it; a text field takes the text.
///
/// Nothing that has rules about where or how often it may be pasted leaves
/// Snippad this way, since a drop is no paste and the rules could not be
/// kept: passwords, entries of lists with Paste Guard rules, and snippets
/// that are pasted once, expire, or chain to another. Those still drag onto
/// lists and files inside Snippad.
struct DragExport: Sendable {
    /// The file name Finder gives what is dropped, without extension.
    var name: String
    var text: String?
    var rtf: Data?
    var png: Data?
    /// A copied file: Finder gets a copy of it, never the original moved.
    var file: URL?

    /// What a history entry gives other apps: one export per copied file,
    /// none for what stays inside Snippad.
    @MainActor
    static func exports(for item: ClipItem) -> [DragExport] {
        guard !item.isPassword, item.pending != true,
              !SettingsStore.shared.list(item.list).isRestricted else { return [] }
        let name = fileName(item.label ?? item.title)
        switch item.kind {
        case .files:
            return item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map {
                DragExport(name: $0.lastPathComponent, text: $0.path, file: $0)
            }
        case .image:
            return item.pngData.map { [DragExport(name: name, png: $0)] } ?? []
        case .richText:
            let rich = item.attributedString
            let rtf = rich.flatMap { $0.rtf(from: NSRange(location: 0, length: $0.length), documentAttributes: [:]) }
            return [DragExport(name: name, text: item.string ?? rich?.string, rtf: rtf)]
        case .text, .url:
            return item.string.map { [DragExport(name: name, text: $0)] } ?? []
        case .color, .other:
            return []
        }
    }

    /// What a snippet gives other apps; nil for one with rules.
    @MainActor
    static func export(for d: SnippetDraft) -> DragExport? {
        guard !d.password, !d.once, d.expires == nil, d.nextID == nil else { return nil }
        if let list = d.list, let found = SettingsStore.shared.value.lists.first(where: { $0.name == list }), found.isRestricted {
            return nil
        }
        let name = fileName(d.name)
        switch d.kind {
        case .text:
            return DragExport(name: name, text: d.value)
        case .rich:
            let rtf = Data(d.value.utf8)
            return DragExport(name: name, text: NSAttributedString(rtf: rtf, documentAttributes: nil)?.string, rtf: rtf)
        case .file:
            let url = URL(fileURLWithPath: (d.value as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return DragExport(name: url.lastPathComponent, text: url.path, file: url)
        case .image:
            return Data(base64Encoded: d.value, options: .ignoreUnknownCharacters).map { DragExport(name: name, png: $0) }
        }
    }

    /// A name Finder can use: no slashes or colons, not too long.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Snippad" : String(cleaned.prefix(60))
    }

    /// The picture as a file of its own, for the drop to copy.
    func pngFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippadDrag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".png")
        try (png ?? Data()).write(to: url)
        return url
    }
}

/// One dragged history entry (or one file of it): inside Snippad, the
/// entries for the lists and files of the sidebar; outside, what other apps
/// take.
struct ClipDrag: Transferable, Sendable {
    /// The entry it comes from.
    var entry: UUID
    /// The entries a drop inside Snippad works on; empty for the second and
    /// later files of an entry, so the entry counts once.
    var history: HistoryDrag
    var export: DragExport?

    /// One drag item per entry, and one per file of an entry with several.
    @MainActor
    static func items(for item: ClipItem) -> [ClipDrag] {
        let exports = DragExport.exports(for: item)
        guard !exports.isEmpty else { return [ClipDrag(entry: item.id, history: HistoryDrag(ids: [item.id]))] }
        return exports.enumerated().map { i, export in
            ClipDrag(entry: item.id, history: HistoryDrag(ids: i == 0 ? [item.id] : []), export: export)
        }
    }

    /// What other apps take comes first, the entries for Snippad's own lists
    /// last. Dragged out, the first representation becomes the file the drop
    /// is promised, and `.visibility(.ownProcess)` does not keep it in: with
    /// the entries first, Diptych was promised a file of them -- a picture
    /// arrived as `{"ids":[…]}` -- and the PNG came only as data behind it.
    /// Snippad's own drops ask for the entries by their type, wherever they are.
    static var transferRepresentation: some TransferRepresentation {
        // A file: a copy of it where it is dropped.
        FileRepresentation(exportedContentType: .data) { drag in
            SentTransferredFile(drag.export?.file ?? URL(fileURLWithPath: "/dev/null"), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.export?.file != nil }
        .suggestedFileName { $0.export?.file?.lastPathComponent }
        FileRepresentation(exportedContentType: .png) { drag in
            SentTransferredFile(try (drag.export ?? DragExport(name: "Snippad")).pngFile())
        }
        .exportingCondition { $0.export?.png != nil }
        .suggestedFileName { $0.export.map { $0.name + ".png" } }
        DataRepresentation(exportedContentType: .rtf) { $0.export?.rtf ?? Data() }
            .exportingCondition { $0.export?.rtf != nil }
        DataRepresentation(exportedContentType: .utf8PlainText) { Data(($0.export?.text ?? "").utf8) }
            .exportingCondition { $0.export?.text != nil }
        // Inside Snippad only, and last, so never the promised file.
        ProxyRepresentation(exporting: \ClipDrag.history)
            .visibility(.ownProcess)
            .exportingCondition { !$0.history.ids.isEmpty }
    }
}

extension View {
    /// macOS 26 and later drag every selected entry as an item of its own,
    /// so several entries, and an entry's several files, arrive as several
    /// in other apps. Before, a drag is one item.
    @ViewBuilder
    func historyDragContainer(selected: @escaping () -> [UUID], items: @escaping ([UUID]) -> [ClipDrag]) -> some View {
        if #available(macOS 26.0, *) {
            self.dragContainer(for: ClipDrag.self, itemID: \.entry) { (ids: [UUID]) in items(ids) }
                .dragContainerSelection(selected())
        } else {
            self
        }
    }

    /// A history row, dragged: in a drag container from macOS 26, else with
    /// its payload (the selected entries inside Snippad; this one outside).
    @ViewBuilder
    func historyDragSource<Preview: View>(_ id: UUID, payload: @escaping () -> ClipDrag,
                                           @ViewBuilder preview: @escaping () -> Preview) -> some View {
        if #available(macOS 26.0, *) {
            self.draggable(containerItemID: id)
        } else {
            self.draggable(payload(), preview: preview)
        }
    }
}
