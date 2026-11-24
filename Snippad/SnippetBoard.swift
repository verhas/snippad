import AppKit
import SwiftUI

/// A change made to the buttons in a file's window, written to the file.
enum BoardChange: Equatable {
    /// A button dragged to a place of its own; nil puts it back in the flow.
    case origin(Snippet.ID, name: String, SnippetPoint?)
    /// A button resized, and pinned where it was; nil gives it the size its
    /// name needs.
    case size(Snippet.ID, name: String, SnippetSize?, origin: SnippetPoint?)
    case iconCorner(Snippet.ID, name: String, SnippetCorner)
    /// Every button back in the flow, with the size its name needs.
    case arrangeAll
}

/// One button per snippet; a click puts the snippet's value on the clipboard,
/// under the snippet's rules for expiry, paste-once and chaining.
///
/// A button with a position of its own sits there; the others flow from the
/// top left, row by row, around them. Dragging a button moves it, its
/// bottom-right corner resizes it, and its icon drags to another corner.
struct SnippetBoard: View {
    let snippets: [Snippet]
    /// Writes a move, resize or icon change to the file; nil keeps the
    /// buttons where they are.
    var change: ((BoardChange) -> Void)? = nil
    /// Where each button is drawn, for the Organizer to start from when a
    /// place or size stops being automatic.
    var shown: ((Snippet, CGRect) -> Void)? = nil

    /// The snippet just copied, for the confirmation at the bottom. The token
    /// changes on every click, so the hide timer of an earlier click cannot
    /// cut a later confirmation short.
    @State private var copied: (name: String, token: Int)?
    @State private var clicks = 0
    /// Where each button is, in the board's coordinates.
    @State private var frames: [Snippet.ID: CGRect] = [:]
    @State private var moving: (id: Snippet.ID, start: CGRect, offset: CGSize)?
    @State private var resizing: (id: Snippet.ID, start: CGRect, size: CGSize)?

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                BoardLayout(width: viewport.size.width) {
                    ForEach(snippets) { snippet in
                        button(for: snippet)
                    }
                }
                .coordinateSpace(.named(BoardLayout.space))
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .contextMenu {
                    if let change {
                        Button("Arrange All Automatically") { change(.arrangeAll) }
                            .disabled(!snippets.contains { $0.origin != nil || $0.size != nil })
                    }
                }
            }
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
                    .allowsHitTesting(false)
            }
        }
    }

    private func button(for snippet: Snippet) -> some View {
        let id = snippet.id
        let liveSize = resizing?.id == id ? resizing?.size : snippet.size.map { CGSize(width: $0.width, height: $0.height) }
        let liveOrigin = resizing?.id == id ? resizing?.start.origin : snippet.origin.map { CGPoint(x: $0.x, y: $0.y) }
        return BoardButton(snippet: snippet, editable: change != nil, active: moving?.id == id || resizing?.id == id,
                           copy: { copy(snippet) },
                           moved: { t in
                               guard let start = moving?.start ?? frames[id] else { return }
                               moving = (id, start, t)
                           },
                           moveEnded: { t in
                               guard let start = moving?.start ?? frames[id] else { return }
                               moving = nil
                               change?(.origin(id, name: snippet.name, Self.point(start.origin, t)))
                           },
                           resized: { t in
                               guard let start = resizing?.start ?? frames[id] else { return }
                               resizing = (id, start, Self.size(start.size, t))
                           },
                           resizeEnded: { t in
                               guard let start = resizing?.start ?? frames[id] else { return }
                               resizing = nil
                               let s = Self.size(start.size, t)
                               change?(.size(id, name: snippet.name, SnippetSize(width: Int(s.width), height: Int(s.height)),
                                             origin: Self.point(start.origin, .zero)))
                           },
                           iconMoved: { corner in change?(.iconCorner(id, name: snippet.name, corner)) },
                           backToFlow: snippet.origin == nil ? nil : { change?(.origin(id, name: snippet.name, nil)) },
                           naturalSize: snippet.size == nil ? nil : {
                               change?(.size(id, name: snippet.name, nil, origin: snippet.origin))
                           })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardLayout.space)) } action: { frame in
                frames[id] = frame
                if moving?.id != id { shown?(snippet, frame) }
            }
            .offset(moving?.id == id ? moving?.offset ?? .zero : .zero)
            .zIndex(moving?.id == id || resizing?.id == id ? 1 : 0)
            // Last: the layout reads only the outermost modifier's value, and
            // ignores one under .offset or .onGeometryChange.
            .layoutValue(key: BoardPlacement.self, value: BoardPlacement(origin: liveOrigin, size: liveSize))
    }

    /// Where a dragged button lands: on whole points, not off the top or left.
    static func point(_ origin: CGPoint, _ t: CGSize) -> SnippetPoint {
        SnippetPoint(x: max(0, Int((origin.x + t.width).rounded())), y: max(0, Int((origin.y + t.height).rounded())))
    }

    static func size(_ size: CGSize, _ t: CGSize) -> CGSize {
        CGSize(width: max(CGFloat(SnippetSize.minimum.width), (size.width + t.width).rounded()),
               height: max(CGFloat(SnippetSize.minimum.height), (size.height + t.height).rounded()))
    }

    private func copy(_ snippet: Snippet) {
        PasteEngine.shared.put(types: snippet.pasteboardTypes, name: snippet.name, rules: snippet.rules(in: snippets))

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

/// A snippet's place and size on the board, when it has them.
struct BoardPlacement: LayoutValueKey {
    static let defaultValue = BoardPlacement(origin: nil, size: nil)
    var origin: CGPoint?
    var size: CGSize?
}

/// Places the buttons: those with a position there, the others in rows from
/// the top left, wrapping at the window's width, around the placed ones.
struct BoardLayout: Layout {
    static let space = "snippet-board"
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 10
    /// Sizes for a button that has none of its own: its name on one line, or
    /// on two when it is long.
    static let minimumSize = CGSize(width: 140, height: 36)
    static let wrapWidth: CGFloat = 260

    /// The window's width, where the rows wrap.
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = Self.frames(subviews.map(Self.item), width: width)
        return CGSize(width: (frames.map(\.maxX).max() ?? 0) + Self.padding,
                      height: (frames.map(\.maxY).max() ?? 0) + Self.padding)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(subviews.map(Self.item), width: width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private static func item(_ subview: LayoutSubview) -> (origin: CGPoint?, size: CGSize) {
        let placement = subview[BoardPlacement.self]
        if let size = placement.size { return (placement.origin, size) }
        var natural = subview.sizeThatFits(.unspecified)
        if natural.width > wrapWidth { natural = subview.sizeThatFits(ProposedViewSize(width: wrapWidth, height: nil)) }
        return (placement.origin, CGSize(width: max(minimumSize.width, natural.width.rounded(.up)),
                                         height: max(minimumSize.height, natural.height.rounded(.up))))
    }

    /// Where each button goes. Placed buttons keep their place; the others
    /// fill rows left to right, skipping what is in the way.
    static func frames(_ items: [(origin: CGPoint?, size: CGSize)], width: CGFloat) -> [CGRect] {
        let placed = items.compactMap { item in item.origin.map { CGRect(origin: $0, size: item.size) } }
        let right = max(width - padding, padding + minimumSize.width)
        var x = padding, y = padding, rowHeight: CGFloat = 0
        var flowed: [CGRect] = []
        var out: [CGRect] = []
        for item in items {
            if let origin = item.origin {
                out.append(CGRect(origin: origin, size: item.size))
                continue
            }
            var tries = 0
            while true {
                tries += 1
                if x > padding, x + item.size.width > right {
                    x = padding
                    y += rowHeight > 0 ? rowHeight + spacing : spacing
                    rowHeight = 0
                }
                let candidate = CGRect(x: x, y: y, width: item.size.width, height: item.size.height)
                let room = candidate.insetBy(dx: -spacing / 2, dy: -spacing / 2)
                guard tries < 10_000, let blocking = (placed + flowed).first(where: { $0.intersects(room) }) else {
                    flowed.append(candidate)
                    out.append(candidate)
                    x = candidate.maxX + spacing
                    rowHeight = max(rowHeight, candidate.height)
                    break
                }
                x = blocking.maxX + spacing
            }
        }
        return out
    }
}

/// One snippet's button, in its colour, with its icon in a corner.
private struct BoardButton: View {
    let snippet: Snippet
    let editable: Bool
    /// Being moved or resized: drawn raised.
    let active: Bool
    let copy: () -> Void
    let moved: (CGSize) -> Void
    let moveEnded: (CGSize) -> Void
    let resized: (CGSize) -> Void
    let resizeEnded: (CGSize) -> Void
    let iconMoved: (SnippetCorner) -> Void
    let backToFlow: (() -> Void)?
    let naturalSize: (() -> Void)?

    @State private var pressed = false
    @State private var dragging = false
    @State private var hovering = false
    @State private var iconOffset = CGSize.zero
    @State private var boxSize = CGSize.zero

    private var fill: Color { Color(snippadHex: snippet.shownColor) }
    private var light: Bool { SnippetColors.isLight(snippet.shownColor) }
    private var ink: Color { light ? .black.opacity(0.85) : .white }

    var body: some View {
        HStack(spacing: 4) {
            Text(snippet.name)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            RuleBadges(expires: snippet.expires, once: snippet.once, next: snippet.next, password: snippet.password,
                       tint: ink.opacity(0.7))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, snippet.icon == nil ? 14 : 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(fill)
                .brightness(pressed && !dragging ? -0.12 : hovering ? -0.04 : 0)
                .shadow(color: .black.opacity(active ? 0.3 : 0.12), radius: active ? 6 : 1, y: active ? 3 : 0.5)
        }
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)) }
        .overlay(alignment: alignment(snippet.iconCorner)) { icon }
        .overlay(alignment: .bottomTrailing) { grip }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { boxSize = $0 }
        .onHover { hovering = $0 }
        .gesture(press)
        .help(snippet.preview + (editable ? "\n\nDrag to move it, its bottom right corner to resize it, its icon to another corner." : ""))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, copy)
        .contextMenu {
            Button("Put on Clipboard", action: copy)
            if editable {
                Divider()
                Button("Back to Automatic Place") { backToFlow?() }.disabled(backToFlow == nil)
                Button("Back to Automatic Size") { naturalSize?() }.disabled(naturalSize == nil)
                if snippet.icon != nil {
                    Menu("Icon Corner") {
                        ForEach(SnippetCorner.allCases, id: \.self) { corner in
                            Toggle(corner.title, isOn: Binding(get: { snippet.iconCorner == corner },
                                                               set: { if $0 { iconMoved(corner) } }))
                        }
                    }
                }
            }
        }
    }

    /// A click copies; a drag, past a few points, moves the button.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                pressed = true
                let t = value.translation
                if editable, dragging || hypot(t.width, t.height) > 4 {
                    dragging = true
                    moved(t)
                }
            }
            .onEnded { value in
                defer { pressed = false; dragging = false }
                if dragging {
                    moveEnded(value.translation)
                } else if hypot(value.translation.width, value.translation.height) < 6 {
                    copy()
                }
            }
    }

    @ViewBuilder private var icon: some View {
        if let name = snippet.icon {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink.opacity(0.8))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .padding(3)
                .offset(iconOffset)
                .pointerStyle(editable ? .grabIdle : nil)
                .gesture(editable ? iconDrag : nil)
        }
    }

    /// The icon follows the pointer and settles in the nearest corner.
    private var iconDrag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { iconOffset = $0.translation }
            .onEnded { value in
                let inset: CGFloat = 12
                let start = CGPoint(x: snippet.iconCorner.isLeading ? inset : boxSize.width - inset,
                                    y: snippet.iconCorner.isTop ? inset : boxSize.height - inset)
                let corner = SnippetCorner.nearest(to: start.x + value.translation.width, start.y + value.translation.height,
                                                   width: boxSize.width, height: boxSize.height)
                iconOffset = .zero
                if corner != snippet.iconCorner { iconMoved(corner) }
            }
    }

    /// Drag to resize; shown while the pointer is over the button.
    @ViewBuilder private var grip: some View {
        if editable {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .opacity(hovering || active ? 1 : 0)
                .pointerStyle(.frameResize(position: .bottomTrailing))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { resized($0.translation) }
                    .onEnded { resizeEnded($0.translation) })
                .help("Drag to resize")
        }
    }

    private func alignment(_ corner: SnippetCorner) -> Alignment {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

extension Color {
    /// A colour written as `"#RRGGBB"`; grey when it cannot be read.
    init(snippadHex hex: String) {
        let c = SnippetColors.components(hex) ?? (0.8, 0.8, 0.8)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    /// `"#RRGGBB"`, in sRGB.
    var snippadHex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return SnippetColors.hex(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}
