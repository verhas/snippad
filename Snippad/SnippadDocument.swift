import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations) with the
    /// `.snippad` extension; the identifier here has to match it.
    static let snippad = UTType(exportedAs: "dev.verhas.snippad")
}

/// A .snippad file, read once when it is opened. Snippad only views these
/// files -- they are written in a text editor -- so there is no saving.
struct SnippadDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.snippad]

    let snippets: [Snippet]

    init(snippets: [Snippet]) {
        self.snippets = snippets
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        snippets = try SnippadParser.parse(text)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
