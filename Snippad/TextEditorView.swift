import AppKit
import SwiftUI

enum LineNumberMode: String, CaseIterable, Identifiable {
    case off, absolute, relative
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "No Line Numbers"
        case .absolute: "Absolute Line Numbers"
        case .relative: "Relative Line Numbers"
        }
    }
}

/// Lets the toolbar act on the text view inside a TextEditorView.
@MainActor
@Observable
final class TextEditorController {
    @ObservationIgnored weak var textView: EditingTextView?

    func find() { textFinder(.showFindInterface) }
    func findAndReplace() { textFinder(.showReplaceInterface) }
    func moveLinesUp() { textView?.moveLines(by: -1) }
    func moveLinesDown() { textView?.moveLines(by: 1) }
    func duplicateLines() { textView?.duplicateLines() }
    func deleteLines() { textView?.deleteLines() }
    func goToLine(_ n: Int) { textView?.goToLine(n) }
    func transform(_ t: TextTransform) { textView?.transform(t) }

    private func textFinder(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }
}

/// The text commands of the Text menu. Each works on the selection, or on
/// the whole text when nothing is selected; the space commands work line by
/// line.
enum TextTransform: CaseIterable {
    case stripLeading, stripTrailing, trim, lowercase, uppercase, removeEmptyLines

    var title: String {
        switch self {
        case .stripLeading: "Strip Spaces at Line Starts"
        case .stripTrailing: "Strip Spaces at Line Ends"
        case .trim: "Trim Lines (Both Ends)"
        case .lowercase: "Make Lower Case"
        case .uppercase: "Make Upper Case"
        case .removeEmptyLines: "Remove Empty Lines"
        }
    }

    func apply(_ text: String) -> String {
        func lines(_ f: (Substring) -> Substring?) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).compactMap(f).joined(separator: "\n")
        }
        switch self {
        case .stripLeading: return lines { $0.drop { $0 == " " || $0 == "\t" } }
        case .stripTrailing:
            return lines { line in
                var t = line
                while let last = t.last, last == " " || last == "\t" { t = t.dropLast() }
                return t
            }
        case .trim: return lines { Substring($0.trimmingCharacters(in: .whitespaces)) }
        case .lowercase: return text.lowercased()
        case .uppercase: return text.uppercased()
        case .removeEmptyLines:
            let kept = lines { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            // A final line break stays.
            return text.hasSuffix("\n") && !kept.isEmpty ? kept + "\n" : kept
        }
    }
}

/// An NSTextView for history entries: read-only until editing is switched
/// on, with the system find and replace bar, line numbers, and line
/// commands. Every change is handed to `onChange` straight away -- there is
/// no Save.
struct TextEditorView: NSViewRepresentable {
    /// Identifies the entry; a different one reloads the text.
    let documentID: UUID
    let text: String
    let rich: NSAttributedString?
    let editable: Bool
    let lineNumbers: LineNumberMode
    var wrap = true
    let controller: TextEditorController
    /// After ⌘C or ⌘X in the text: what was copied belongs to the list of
    /// what it was copied from.
    var onCopy: (() -> Void)? = nil
    /// Copies are marked concealed, for passwords.
    var concealCopies = false
    let onChange: (String, NSAttributedString?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditingTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.drawsBackground = true

        let ruler = LineNumberRuler(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        guard let textView = c.textView else { return }
        controller.textView = textView
        textView.onCopy = onCopy
        textView.concealCopies = concealCopies
        if c.wrap != wrap {
            c.wrap = wrap
            setWrap(wrap, textView: textView, scroll: scroll)
        }

        if c.documentID != documentID || c.wasRich != (rich != nil) {
            c.documentID = documentID
            c.wasRich = rich != nil
            c.loading = true
            textView.isRichText = rich != nil
            textView.importsGraphics = false
            if let rich {
                textView.textStorage?.setAttributedString(rich)
            } else {
                textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                textView.string = text
                textView.typingAttributes[.font] = textView.font
            }
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            c.loading = false
        }
        textView.isEditable = editable
        textView.isSelectable = true
        textView.backgroundColor = editable ? .textBackgroundColor : .controlBackgroundColor

        c.ruler?.mode = lineNumbers
        scroll.rulersVisible = lineNumbers != .off
    }

    private func setWrap(_ wrap: Bool, textView: NSTextView, scroll: NSScrollView) {
        let huge = CGFloat.greatestFiniteMagnitude
        if wrap {
            scroll.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: huge)
            textView.textContainer?.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
        } else {
            scroll.hasHorizontalScroller = true
            textView.maxSize = NSSize(width: huge, height: huge)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: huge, height: huge)
        }
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var wrap: Bool?
        var wasRich: Bool?
        var textView: EditingTextView?
        var ruler: LineNumberRuler?
        var documentID: UUID?
        var loading = false
        var onChange: ((String, NSAttributedString?) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard !loading, let textView else { return }
            ruler?.needsDisplay = true
            let rich = textView.isRichText ? NSAttributedString(attributedString: textView.attributedString()) : nil
            onChange?(textView.string, rich)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
        }
    }
}

/// The text view, with the line commands on the keys of Xcode and IntelliJ:
/// ⇧⌘↑ ⇧⌘↓, ⌥⇧↑ ⌥⇧↓, ⌥⌘[ and ⌥⌘] move lines, ⇧⌘D duplicates, ⌘⌫ and ⇧⌘K
/// delete.
final class EditingTextView: NSTextView {
    var onCopy: (() -> Void)?
    var concealCopies = false

    /// The line command a key stands for, if any.
    private func handleLineKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (mods, event.keyCode) {
        case ([.command, .shift], 126), ([.option, .shift], 126): moveLines(by: -1); return true   // ↑
        case ([.command, .shift], 125), ([.option, .shift], 125): moveLines(by: 1); return true    // ↓
        case ([.command], 51): deleteLines(); return true                                          // ⌫
        default: break
        }
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command, .option], "["): moveLines(by: -1); return true
        case ([.command, .option], "]"): moveLines(by: 1); return true
        case ([.command, .shift], "d"): duplicateLines(); return true
        case ([.command, .shift], "k"): deleteLines(); return true
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return handleLineKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleLineKey(event) { super.keyDown(with: event) }
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        afterCopy()
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        afterCopy()
    }

    private func afterCopy() {
        if concealCopies {
            let pb = NSPasteboard.general
            if let text = pb.string(forType: .string) {
                pb.clearContents()
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setData(Data(), forType: .concealed)
                pb.writeObjects([item])
            }
        }
        onCopy?()
    }

    /// One of the Text menu's commands, on the selection or the whole text.
    func transform(_ t: TextTransform) {
        guard isEditable else { NSSound.beep(); return }
        var range = selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: nsString.length) }
        let before = nsString.substring(with: range)
        let after = t.apply(before)
        guard after != before else { return }
        replace(range, with: after, select: NSRange(location: range.location, length: (after as NSString).length))
    }

    private var nsString: NSString { string as NSString }

    /// The whole lines the selection touches, with their line breaks.
    private var selectedLineRange: NSRange {
        nsString.lineRange(for: selectedRange())
    }

    /// Replaces text as an undoable edit that goes through the delegate.
    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        guard isEditable, shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    func moveLines(by direction: Int) {
        guard isEditable else { NSSound.beep(); return }
        let lines = selectedLineRange
        let s = nsString
        var block = s.substring(with: lines)
        let selection = selectedRange()
        if direction < 0 {
            guard lines.location > 0 else { return }
            let above = s.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            var prev = s.substring(with: above)
            if !block.hasSuffix("\n") { block += "\n"; prev = String(prev.dropLast()) }
            let range = NSRange(location: above.location, length: above.length + lines.length)
            replace(range, with: block + prev,
                    select: NSRange(location: selection.location - above.length, length: selection.length))
        } else {
            let end = NSMaxRange(lines)
            guard end < s.length else { return }
            let below = s.lineRange(for: NSRange(location: end, length: 0))
            var next = s.substring(with: below)
            if !next.hasSuffix("\n") { next += "\n"; block = String(block.dropLast()) }
            let range = NSRange(location: lines.location, length: lines.length + below.length)
            replace(range, with: next + block,
                    select: NSRange(location: selection.location + (next as NSString).length, length: selection.length))
        }
    }

    func duplicateLines() {
        guard isEditable else { NSSound.beep(); return }
        let lines = selectedLineRange
        var block = nsString.substring(with: lines)
        if !block.hasSuffix("\n") { block = "\n" + block }
        let at = NSMaxRange(lines)
        let selection = selectedRange()
        replace(NSRange(location: at, length: 0), with: block,
                select: NSRange(location: selection.location + (block as NSString).length, length: selection.length))
    }

    func deleteLines() {
        guard isEditable else { NSSound.beep(); return }
        let lines = selectedLineRange
        replace(lines, with: "", select: NSRange(location: min(lines.location, nsString.length - lines.length), length: 0))
    }

    func goToLine(_ number: Int) {
        let s = nsString
        var index = 0
        var line = 1
        while line < number && index < s.length {
            index = NSMaxRange(s.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        let range = s.lineRange(for: NSRange(location: min(index, s.length), length: 0))
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
        window?.makeFirstResponder(self)
    }
}

/// Line numbers beside the text: absolute, or relative to the line with the
/// cursor (which shows its own number), as in Vim.
final class LineNumberRuler: NSRulerView {
    var mode: LineNumberMode = .off { didSet { if mode != oldValue { needsDisplay = true } } }
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let scrollView else { return }
        let s = textView.string as NSString
        let visible = scrollView.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        /// 1 + the line breaks before `index`.
        func lineNumber(at index: Int) -> Int {
            let end = min(index, s.length)
            guard end > 0 else { return 1 }
            var buffer = [unichar](repeating: 0, count: end)
            s.getCharacters(&buffer, range: NSRange(location: 0, length: end))
            return 1 + buffer.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }

        let cursorLine = lineNumber(at: textView.selectedRange().location)
        var number = lineNumber(at: chars.location)
        let inset = textView.textContainerInset.height
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let currentAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        // Wide enough for the largest number.
        let digits = max(2, String(lineNumber(at: s.length)).count)
        let wanted = CGFloat(digits) * 8 + 14
        if abs(ruleThickness - wanted) > 1 { ruleThickness = wanted }

        func draw(_ n: Int, atY y: CGFloat) {
            let label = mode == .relative && n != cursorLine ? String(abs(n - cursorLine)) : String(n)
            let a = NSAttributedString(string: label, attributes: n == cursorLine ? currentAttrs : attrs)
            let size = a.size()
            let point = convert(NSPoint(x: 0, y: y + inset), from: textView)
            a.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: point.y))
        }

        var index = chars.location
        while index < NSMaxRange(chars) || (index == s.length && index == chars.location) {
            let lineRange = s.lineRange(for: NSRange(location: index, length: 0))
            if s.length == 0 { draw(1, atY: 0); break }
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, atY: fragment.minY)
            number += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
        // The empty line after a final line break.
        if s.length > 0, NSMaxRange(chars) == s.length, s.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            if !extra.isEmpty { draw(number, atY: extra.minY) }
        }
    }
}
