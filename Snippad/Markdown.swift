import AppKit

/// Formatted text written as Markdown: bold, italic, strikethrough, code,
/// links, headings (from larger fonts) and bulleted or numbered lines.
enum MarkdownConverter {

    static func markdown(from text: NSAttributedString) -> String {
        let s = text.string as NSString
        let body = NSFont.systemFontSize
        // The most common font size is the body text; larger lines are
        // headings.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        let bodySize = sizes.max { $0.value < $1.value }?.key ?? body

        var lines: [String] = []
        var location = 0
        while location <= s.length {
            let lineRange = s.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            // Without its line break.
            while content.length > 0, let last = s.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1)).unicodeScalars.first,
                  CharacterSet.newlines.contains(last) {
                content.length -= 1
            }
            lines.append(line(text, content, bodySize: bodySize))
            let next = NSMaxRange(lineRange)
            if next <= location || next >= s.length { break }
            location = next
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ text: NSAttributedString, _ range: NSRange, bodySize: CGFloat) -> String {
        guard range.length > 0 else { return "" }
        var prefix = ""
        var start = range.location
        let raw = (text.string as NSString).substring(with: range)
        // Lists: the bullets and numbers a rich text editor types.
        if let style = text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
           let list = style.textLists.last {
            prefix = list.markerFormat == .decimal ? "1. " : "- "
        }
        for bullet in ["• ", "◦ ", "▪ ", "– ", "\t•\t", "•\t"] where raw.hasPrefix(bullet) {
            prefix = "- "
            start += (bullet as NSString).length
            break
        }
        // Heading: the whole line in a larger, or bold and larger, font.
        if let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont, prefix.isEmpty {
            let ratio = font.pointSize / bodySize
            if ratio >= 1.15 {
                var uniform = true
                text.enumerateAttribute(.font, in: range) { value, _, stop in
                    if (value as? NSFont)?.pointSize != font.pointSize { uniform = false; stop.pointee = true }
                }
                if uniform { prefix = ratio >= 1.8 ? "# " : ratio >= 1.4 ? "## " : "### " }
            }
        }
        let inner = NSRange(location: start, length: NSMaxRange(range) - start)
        var out = prefix
        let headed = prefix.hasPrefix("#")
        text.enumerateAttributes(in: inner) { attrs, r, _ in
            var piece = (text.string as NSString).substring(with: r)
            guard !piece.isEmpty else { return }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let mono = font?.isFixedPitch ?? false
            if mono {
                piece = "`" + piece.replacingOccurrences(of: "`", with: "\\`") + "`"
            } else {
                piece = escape(piece)
            }
            // Spaces stay outside the markers, or they do not count.
            let leading = String(piece.prefix { $0 == " " })
            let trailing = String(piece.reversed().prefix { $0 == " " })
            var core = String(piece.dropFirst(leading.count).dropLast(trailing.count))
            if !core.isEmpty {
                if !mono {
                    if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { core = "~~\(core)~~" }
                    if traits.contains(.italicFontMask) { core = "*\(core)*" }
                    if traits.contains(.boldFontMask) && !headed { core = "**\(core)**" }
                }
                if let link = attrs[.link] {
                    let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !url.isEmpty { core = "[\(core)](\(url))" }
                }
            }
            out += leading + core + trailing
        }
        return out
    }

    /// Characters Markdown would read as formatting.
    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\*_`[]<>".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
