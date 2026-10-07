import AppKit
import SwiftUI

/// One button per snippet; a click puts the snippet's value on the clipboard.
struct SnippetBoard: View {
    let snippets: [Snippet]

    /// The snippet just copied, for the confirmation at the bottom. The token
    /// changes on every click, so the hide timer of an earlier click cannot
    /// cut a later confirmation short.
    @State private var copied: (name: String, token: Int)?
    @State private var clicks = 0

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(snippets) { snippet in
                    Button {
                        copy(snippet)
                    } label: {
                        Text(snippet.name)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(snippet.value)
                }
            }
            .padding()
        }
        .frame(minWidth: 240, minHeight: 120)
        .overlay(alignment: .bottom) {
            if let copied {
                Text("Copied \u{201C}\(copied.name)\u{201D}")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private func copy(_ snippet: Snippet) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.value, forType: .string)

        clicks += 1
        let token = clicks
        withAnimation { copied = (snippet.name, token) }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied?.token == token {
                withAnimation { copied = nil }
            }
        }
    }
}
