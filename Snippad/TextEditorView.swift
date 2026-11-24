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

    // MARK: Formatting (rich text)

    func toggleBold() { textView?.toggleTrait(.boldFontMask) }
    func toggleItalic() { textView?.toggleTrait(.italicFontMask) }
    func toggleUnderline() { textView?.toggleLine(.underlineStyle) }
    func toggleStrikethrough() { textView?.toggleLine(.strikethroughStyle) }
    func bigger() { textView?.changeSize(by: 2) }
    func smaller() { textView?.changeSize(by: -2) }
    func setColor(_ color: NSColor?) { textView?.setAttribute(.foregroundColor, color) }
    func setHighlight(_ color: NSColor?) { textView?.setAttribute(.backgroundColor, color) }
    func align(_ alignment: NSTextAlignment) { textView?.align(alignment) }
    func toggleList(numbered: Bool) { textView?.toggleList(numbered: numbered) }
    func setFontFamily(_ family: String?) { textView?.setFamily(family) }
    func heading(_ level: Int) { textView?.heading(level) }
    func link() { textView?.askForLink() }
    func clearFormatting() { textView?.clearFormatting() }
    func showFonts() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

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
        // The Font and Colors panels, the ruler, and Writing Tools work on
        // formatted text.
        textView.usesFontPanel = rich != nil
        textView.writingToolsBehavior = rich != nil && editable ? .complete : .limited
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
        return handleLineKey(event) || handleFormatKey(event) || super.performKeyEquivalent(with: event)
    }

    /// ⌘B, ⌘I and ⌘U in formatted text.
    private func handleFormatKey(_ event: NSEvent) -> Bool {
        guard isRichText, isEditable, event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": toggleTrait(.boldFontMask)
        case "i": toggleTrait(.italicFontMask)
        case "u": toggleLine(.underlineStyle)
        default: return false
        }
        return true
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

    // MARK: Formatting

    /// The selection, or nothing: then the typing attributes change.
    private var formatRange: NSRange? {
        let r = selectedRange()
        return r.length > 0 ? r : nil
    }

    /// Changes the attributes of the selection as one undoable edit, or the
    /// typing attributes when nothing is selected.
    private func format(_ change: (NSTextStorage, NSRange) -> Void, typing: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard isEditable, isRichText else { NSSound.beep(); return }
        guard let range = formatRange, let storage = textStorage else {
            typing(&typingAttributes)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage, range)
        storage.endEditing()
        didChangeText()
    }

    private var defaultFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let all: Bool
        if let range = formatRange, let storage = textStorage {
            var every = true
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                if !fm.traits(of: (value as? NSFont) ?? defaultFont).contains(trait) { every = false; stop.pointee = true }
            }
            all = every
        } else {
            all = fm.traits(of: (typingAttributes[.font] as? NSFont) ?? defaultFont).contains(trait)
        }
        func converted(_ font: NSFont) -> NSFont {
            all ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
        }
        format({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: converted((value as? NSFont) ?? self.defaultFont), range: r)
            }
        }, typing: { $0[.font] = converted(($0[.font] as? NSFont) ?? self.defaultFont) })
    }

    func toggleLine(_ key: NSAttributedString.Key) {
        let on: Bool
        if let range = formatRange, let storage = textStorage {
            var every = true
            storage.enumerateAttribute(key, in: range) { value, _, stop in
                if (value as? Int ?? 0) == 0 { every = false; stop.pointee = true }
            }
            on = !every
        } else {
            on = (typingAttributes[key] as? Int ?? 0) == 0
        }
        let value = NSUnderlineStyle.single.rawValue
        format({ storage, range in
            if on { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
        }, typing: { $0[key] = on ? value : nil })
    }

    func changeSize(by delta: CGFloat) {
        func resized(_ font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toSize: min(288, max(6, font.pointSize + delta)))
        }
        format({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: resized((value as? NSFont) ?? self.defaultFont), range: r)
            }
        }, typing: { $0[.font] = resized(($0[.font] as? NSFont) ?? self.defaultFont) })
    }

    func setFamily(_ family: String?) {
        let fm = NSFontManager.shared
        func changed(_ font: NSFont) -> NSFont {
            guard let family else { return NSFont.systemFont(ofSize: font.pointSize).withTraits(of: font) }
            return fm.convert(font, toFamily: family)
        }
        format({ storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: changed((value as? NSFont) ?? self.defaultFont), range: r)
            }
        }, typing: { $0[.font] = changed(($0[.font] as? NSFont) ?? self.defaultFont) })
    }

    func setAttribute(_ key: NSAttributedString.Key, _ value: Any?) {
        format({ storage, range in
            if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
        }, typing: { $0[key] = value })
    }

    /// The paragraphs the selection touches.
    private var paragraphRange: NSRange {
        (string as NSString).paragraphRange(for: selectedRange())
    }

    func align(_ alignment: NSTextAlignment) {
        guard isEditable, isRichText, let storage = textStorage else { NSSound.beep(); return }
        let range = paragraphRange
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, r, _ in
            let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: r)
        }
        if range.length == 0 {
            let style = ((typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.alignment = alignment
            typingAttributes[.paragraphStyle] = style
        }
        storage.endEditing()
        didChangeText()
    }

    /// A heading: the paragraphs bold and larger (level 1 to 3), or body
    /// text again (level 0).
    func heading(_ level: Int) {
        guard isEditable, isRichText, let storage = textStorage else { NSSound.beep(); return }
        let range = paragraphRange
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        let body = NSFont.systemFontSize
        let size: CGFloat = [body, body * 2, body * 1.6, body * 1.3][min(max(level, 0), 3)]
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, r, _ in
            let font = (value as? NSFont) ?? self.defaultFont
            var changed = NSFontManager.shared.convert(font, toSize: size)
            changed = level > 0 ? NSFontManager.shared.convert(changed, toHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(changed, toNotHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: changed, range: r)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Bullets (•) or numbers (1. 2. …) at the start of the selected lines;
    /// lines that all have them lose them.
    func toggleList(numbered: Bool) {
        guard isEditable, let storage = textStorage else { NSSound.beep(); return }
        let range = paragraphRange
        let text = (string as NSString).substring(with: range)
        var lines = text.components(separatedBy: "\n")
        let endsWithBreak = text.hasSuffix("\n")
        if endsWithBreak { lines.removeLast() }
        let numberPrefix = #/^\d+\. /#
        func marked(_ line: String) -> Bool { line.hasPrefix("• ") || line.firstMatch(of: numberPrefix) != nil }
        func unmarked(_ line: String) -> String {
            if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
            if let m = line.firstMatch(of: numberPrefix) { return String(line[m.range.upperBound...]) }
            return line
        }
        let remove = !lines.isEmpty && lines.allSatisfy { marked($0) && ($0.hasPrefix("• ") != numbered) }
        let changed = lines.enumerated().map { i, line in
            remove ? unmarked(line) : (numbered ? "\(i + 1). " : "• ") + unmarked(line)
        }.joined(separator: "\n") + (endsWithBreak ? "\n" : "")
        guard changed != text, shouldChangeText(in: range, replacementString: changed) else { return }
        let attrs = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: changed, attributes: attrs))
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (changed as NSString).length))
    }

    func askForLink() {
        guard isEditable, isRichText, let range = formatRange else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Link"
        alert.informativeText = "The address the selected text links to. Leave it empty to remove the link."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        if let existing = textStorage?.attribute(.link, at: range.location, effectiveRange: nil) {
            field.stringValue = (existing as? URL)?.absoluteString ?? (existing as? String) ?? ""
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        setSelectedRange(range)
        setAttribute(.link, text.isEmpty ? nil : (URL(string: text) ?? text))
    }

    /// The selection, or everything, in plain body text again.
    func clearFormatting() {
        guard isEditable, isRichText, let storage = textStorage else { NSSound.beep(); return }
        let range = formatRange ?? NSRange(location: 0, length: storage.length)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.setAttributes([.font: defaultFont, .foregroundColor: NSColor.textColor], range: range)
        storage.endEditing()
        didChangeText()
        typingAttributes = [.font: defaultFont, .foregroundColor: NSColor.textColor]
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

private extension NSFont {
    /// The same bold and italic as `other`.
    func withTraits(of other: NSFont) -> NSFont {
        var font = self
        let traits = NSFontManager.shared.traits(of: other)
        for t in [NSFontTraitMask.boldFontMask, .italicFontMask] where traits.contains(t) {
            font = NSFontManager.shared.convert(font, toHaveTrait: t)
        }
        return font
    }
}

/// The formatting buttons above a rich text being edited.
struct RichTextBar: View {
    let editor: TextEditorController
    @State private var color: Color = .primary
    @State private var highlight: Color = .yellow

    private static let families = ["Helvetica Neue", "Times New Roman", "Georgia", "Avenir Next", "Menlo", "Courier New"]

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Title") { editor.heading(1) }
                Button("Heading") { editor.heading(2) }
                Button("Subheading") { editor.heading(3) }
                Button("Body") { editor.heading(0) }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Title, heading, subheading or body text for the selected paragraphs")
            Menu {
                Button("System Font") { editor.setFontFamily(nil) }
                Divider()
                ForEach(Self.families.filter { NSFontManager.shared.availableFontFamilies.contains($0) }, id: \.self) { family in
                    Button(family) { editor.setFontFamily(family) }
                }
                Divider()
                Button("Show Fonts\u{2026}") { editor.showFonts() }
            } label: {
                Image(systemName: "textformat")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The font of the selection; Show Fonts for all of them")
            button("Smaller", "textformat.size.smaller", editor.smaller)
            button("Bigger", "textformat.size.larger", editor.bigger)
            Divider().frame(height: 16)
            button("Bold (⌘B)", "bold", editor.toggleBold)
            button("Italic (⌘I)", "italic", editor.toggleItalic)
            button("Underline (⌘U)", "underline", editor.toggleUnderline)
            button("Strikethrough", "strikethrough", editor.toggleStrikethrough)
            Divider().frame(height: 16)
            ColorPicker("Text colour", selection: Binding(get: { color }, set: { color = $0; editor.setColor(NSColor($0)) }))
                .labelsHidden()
                .help("The colour of the selected text")
            ColorPicker("Highlight", selection: Binding(get: { highlight }, set: { highlight = $0; editor.setHighlight(NSColor($0)) }))
                .labelsHidden()
                .help("Highlight the selected text in this colour")
            button("Remove Highlight", "highlighter", { editor.setHighlight(nil) })
            Divider().frame(height: 16)
            button("Align Left", "text.alignleft", { editor.align(.left) })
            button("Centre", "text.aligncenter", { editor.align(.center) })
            button("Align Right", "text.alignright", { editor.align(.right) })
            button("Justify", "text.justify", { editor.align(.justified) })
            Divider().frame(height: 16)
            button("Bulleted List", "list.bullet", { editor.toggleList(numbered: false) })
            button("Numbered List", "list.number", { editor.toggleList(numbered: true) })
            button("Link…", "link", editor.link)
            button("Clear Formatting", "eraser", editor.clearFormatting)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .help(title)
            .frame(width: 24)
    }
}
