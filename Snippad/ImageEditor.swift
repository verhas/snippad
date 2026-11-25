import AppKit
import SwiftUI

/// The image editor's state: the edits, the tool, what is selected, and the
/// undo history. Every finished change is handed to `onChange` with the new
/// result image; the caller keeps both.
@MainActor
@Observable
final class ImageEditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case pointer, hand, area, crop, shape, line, text, marker
        var id: Self { self }

        var title: String {
            switch self {
            case .pointer: "Move and Resize"
            case .hand: "Move the Picture"
            case .area: "Select an Area"
            case .crop: "Crop"
            case .shape: "Shape"
            case .line: "Line or Arrow"
            case .text: "Text"
            case .marker: "Numbered Marker"
            }
        }

        var symbol: String {
            switch self {
            case .pointer: "cursorarrow"
            case .hand: "hand.raised"
            case .area: "rectangle.dashed"
            case .crop: "crop"
            case .shape: "square.on.circle"
            case .line: "line.diagonal.arrow"
            case .text: "textformat"
            case .marker: "1.circle.fill"
            }
        }

        var help: String {
            switch self {
            case .pointer: "Click an object to select it (⌥-click for the one behind it, ⌘-click to select more or fewer, or drag a rectangle over them); drag it to move it, drag its handles to resize it. Delete removes it."
            case .hand: "Drag the picture to move it in the window; or hold Space, or drag with the middle button, with any tool"
            case .area: "Drag to select an area (a polygon: click its corners, double-click to finish), then delete it, apply an effect or crop to it"
            case .crop: "Drag the part of the image to keep. Nothing is lost: Remove Crop brings the rest back."
            case .shape: "Drag to draw a shape, outlined or filled; a polygon: click its corners, double-click or Return to finish"
            case .line: "Drag to draw a line; a polyline: click its points, double-click or Return to finish. Choose the heads at either end."
            case .text: "Click where the text goes, then type it in the Text field"
            case .marker: "Click, or drag the marker from the bar onto the picture: each one gets the next number"
            }
        }
    }

    private(set) var edits: ImageEdits
    var tool: Tool = .pointer {
        didSet {
            canvas?.finishBuilding()
            // Moving the picture keeps what is selected.
            if tool != .area && tool != .hand { area = nil }
            if ![.pointer, .hand, .text, .marker].contains(tool) { selection = [] }
            if let canvas {
                canvas.window?.invalidateCursorRects(for: canvas)
                canvas.needsDisplay = true
            }
        }
    }
    /// The selected layers: what is moved, copied, removed and restyled
    /// together.
    var selection: Set<UUID> = [] {
        didSet {
            if selection != oldValue {
                editingPoints = false
                canvas?.needsDisplay = true
            }
        }
    }
    /// The one selected layer: the one the handles, the points, the text
    /// and the number work on. Nil when none or several are selected.
    var selected: UUID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    /// The selected line or shape shows its points to drag one by one,
    /// instead of its box.
    var editingPoints = false {
        didSet { canvas?.needsDisplay = true }
    }
    /// A selected area, waiting for an action.
    var area: ImageArea?
    /// A crop being dragged.
    var cropDrag: CGRect?
    /// A polygon or polyline is being clicked point by point.
    var isBuilding = false
    /// How new shapes, lines, arrows and texts look, and the shape of new
    /// areas.
    var style: ImageLayer = {
        var s = ImageLayer(kind: .shape, start: .zero, end: .zero)
        s.marker = .circle
        s.endHead = .solid
        return s
    }()
    /// How big the picture is shown: image pixels per screen pixel (1 is
    /// 1:1); nil fits it in the window.
    var zoom: Double?
    /// How big it is shown now, also when it fits: set by the canvas.
    var shownZoom: Double = 1

    /// The zooms the buttons step through.
    static let zoomSteps: [Double] = [0.05, 0.1, 0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]
    static let zoomRange = 0.02...32.0

    static func zoom(after zoom: Double, up: Bool) -> Double {
        up ? zoomSteps.first { $0 > zoom * 1.001 } ?? zoomRange.upperBound
            : zoomSteps.last { $0 < zoom / 1.001 } ?? zoomRange.lowerBound
    }

    /// Zooms to a size (nil: to fit), about the middle of what is shown.
    func setZoom(_ new: Double?) {
        let clamped = new.map { min(max($0, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }
        if let canvas { canvas.setZoom(clamped) } else { zoom = clamped }
    }

    func zoomIn() { setZoom(Self.zoom(after: shownZoom, up: true)) }
    func zoomOut() { setZoom(Self.zoom(after: shownZoom, up: false)) }

    /// The width of the next marker: that of the last one placed or
    /// resized, so that one resized marker sets the size of all after it.
    var markerWidth: Double?
    /// Bumped to put the cursor in the Text field.
    var focusText = 0
    /// The number the next marker gets.
    var nextNumber = 1
    /// The grid and snapping, kept in the settings.
    @ObservationIgnored let settings = SettingsStore.shared
    /// Where copied objects are read from, and how they are put there (with
    /// the history, into the list the settings name).
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored var putOnClipboard: ([String: Data], String) -> Void = { types, label in
        ClipboardHistory.shared.addImageObjects(types, label: label)
    }

    @ObservationIgnored let base: CGImage
    @ObservationIgnored private let onChange: (ImageEdits, Data) -> Void
    @ObservationIgnored weak var canvas: ImageCanvasView?
    @ObservationIgnored private var undoStack: [ImageEdits] = []
    @ObservationIgnored private var redoStack: [ImageEdits] = []
    /// Changes in a row to the same thing (typing, a colour being picked)
    /// are undone together.
    @ObservationIgnored private var lastUndoKey: (key: String, time: Date)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Changed since the result was last handed over.
    @ObservationIgnored private var dirty = false
    private(set) var canUndo = false
    private(set) var canRedo = false

    init?(edits: ImageEdits, onChange: @escaping (ImageEdits, Data) -> Void) {
        guard let base = ImageCompositor.cgImage(edits.original) else { return nil }
        self.base = base
        self.edits = edits
        self.onChange = onChange
        nextNumber = highestNumber + 1
        markerWidth = edits.layers.last { $0.kind == .marker }.map { Double($0.rect.width) }
    }

    var size: CGSize { CGSize(width: base.width, height: base.height) }

    private var highestNumber: Int {
        edits.layers.compactMap { $0.kind == .marker ? $0.number : nil }.max() ?? 0
    }

    var selectedLayer: ImageLayer? {
        selected.flatMap { id in edits.layers.first { $0.id == id } }
    }

    /// The selected layers, the bottom one first.
    var selectedLayers: [ImageLayer] {
        edits.layers.filter { selection.contains($0.id) }
    }

    var hasSelection: Bool { !selection.isEmpty }

    // MARK: Changing

    /// Records the state before a change, for Undo. `key` merges a run of
    /// changes of the same kind into one step.
    func checkpoint(_ key: String? = nil) {
        if let key, let last = lastUndoKey, last.key == key, Date().timeIntervalSince(last.time) < 1.5 {
            lastUndoKey = (key, Date())
            return
        }
        lastUndoKey = key.map { ($0, Date()) }
        undoStack.append(edits)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        canUndo = true
        canRedo = false
    }

    /// Changes the edits without a checkpoint: the drags in between.
    func live(_ change: (inout ImageEdits) -> Void) {
        change(&edits)
        canvas?.needsDisplay = true
    }

    /// A finished change: shown, and saved a moment later.
    func commit() {
        canvas?.needsDisplay = true
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Hands over the result now, if anything changed.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        guard let png = ImageCompositor.png(edits) else { return }
        onChange(edits, png)
    }

    /// A change with its own undo step.
    func change(_ key: String? = nil, _ change: (inout ImageEdits) -> Void) {
        checkpoint(key)
        live(change)
        commit()
    }

    /// Changes every selected layer, or those of `kinds`; an old arrow
    /// counts as a line.
    func updateSelected(_ key: String, only kinds: Set<ImageLayer.Kind>? = nil, _ change: (inout ImageLayer) -> Void) {
        let indices = edits.layers.indices.filter { i in
            let layer = edits.layers[i]
            return selection.contains(layer.id) && (kinds?.contains(Self.kind(of: layer)) ?? true)
        }
        guard !indices.isEmpty else { return }
        let ids = indices.map { edits.layers[$0].id.uuidString }.sorted().joined()
        self.change(key + ids) {
            for index in indices {
                let center = $0.layers[index].center
                change(&$0.layers[index])
                $0.layers[index].fitText()
                $0.layers[index].reanchor(from: center)
            }
        }
    }

    static func kind(of layer: ImageLayer) -> ImageLayer.Kind {
        layer.kind == .arrow ? .line : layer.kind
    }

    /// A press that changed nothing (a click on an object) leaves no undo
    /// step.
    /// True when there was nothing to keep.
    @discardableResult
    func dropCheckpointIfUnchanged() -> Bool {
        guard let last = undoStack.last, last == edits else { return false }
        undoStack.removeLast()
        lastUndoKey = nil
        canUndo = !undoStack.isEmpty
        return true
    }

    /// Drops the change since the last checkpoint, leaving no undo step.
    func cancelChange() {
        guard let previous = undoStack.popLast() else { return }
        edits = previous
        lastUndoKey = nil
        canUndo = !undoStack.isEmpty
        canvas?.needsDisplay = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        edits = previous
        afterHistoryStep()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        edits = next
        afterHistoryStep()
    }

    private func afterHistoryStep() {
        lastUndoKey = nil
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        let ids = Set(edits.layers.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        nextNumber = highestNumber + 1
        commit()
    }

    // MARK: Commands

    func add(_ layer: ImageLayer, checkpoint wanted: Bool = true) {
        if wanted { checkpoint() }
        live { $0.layers.append(layer) }
        selected = layer.id
    }

    func removeSelected() {
        guard hasSelection else { return }
        let ids = selection
        change { $0.layers.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// Applies an effect to the selected area. The effect stays an object:
    /// it can be moved, resized or removed later.
    func apply(_ effect: ImageEffect) {
        guard let area else { return }
        var layer = ImageLayer(kind: .effect, start: area.start, end: area.end, shape: area.shape)
        if area.shape.usesPoints, let points = area.points { layer.setPoints(points) }
        layer.effect = effect
        layer.effectSize = effect.defaultSize
        self.area = nil
        tool = .pointer
        add(layer)
        commit()
    }

    func cropToArea() {
        guard let area else { return }
        self.area = nil
        setCrop(area.rect)
    }

    func setCrop(_ rect: CGRect?) {
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.map { $0.integral.intersection(bounds) }
        change { $0.crop = (clipped?.width ?? 0) >= 2 && (clipped?.height ?? 0) >= 2 ? clipped : nil }
    }

    /// Removes every layer and the crop; Undo brings them back.
    func revertToOriginal() {
        selection = []
        area = nil
        change { $0.layers = []; $0.crop = nil }
    }

    /// Pastes what is on the clipboard into the picture: an image, or text.
    @discardableResult
    func paste() -> Bool {
        let pb = pasteboard
        if pasteObjects() { return true }
        let visible = visibleRect
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            var w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
            let fit = min(1, visible.width * 0.6 / max(w, 1), visible.height * 0.6 / max(h, 1))
            w *= fit; h *= fit
            var layer = ImageLayer(kind: .image, start: CGPoint(x: visible.midX - w / 2, y: visible.midY - h / 2),
                                   end: CGPoint(x: visible.midX + w / 2, y: visible.midY + h / 2))
            layer.image = png
            tool = .pointer
            add(layer)
            commit()
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            var layer = newText(at: .zero)
            layer.text = text
            layer.fitText()
            layer.move(by: visible.midX - layer.rect.width / 2, visible.midY - layer.rect.height / 2)
            tool = .pointer
            add(layer)
            commit()
            return true
        }
        return false
    }

    // MARK: Copying objects

    /// What copied objects are on the clipboard as: Snippad's own, to paste
    /// into any image editor, also another one.
    static let objectsType = NSPasteboard.PasteboardType("dev.verhas.snippad.image-objects")

    /// Copies the selected area if there is one, else the selected
    /// objects.
    @discardableResult
    func copy() -> Bool {
        area != nil ? copyArea() : copySelected()
    }

    /// Copies, then deletes what was copied: the area (made transparent,
    /// as Delete does) or the objects.
    @discardableResult
    func cut() -> Bool {
        if area != nil {
            guard copyArea() else { return false }
            apply(.erase)
            return true
        }
        guard copySelected() else { return false }
        removeSelected()
        return true
    }

    var canCopy: Bool { area != nil || hasSelection }

    /// Puts the selected objects on the clipboard: as objects for the
    /// image editors, and as one picture for everything else. They go into
    /// the history list the settings name for them.
    @discardableResult
    func copySelected() -> Bool {
        let layers = selectedLayers
        guard !layers.isEmpty, let json = try? JSONEncoder().encode(layers) else { return false }
        var types = [Self.objectsType.rawValue: json]
        if let png = ImageCompositor.png(of: layers) { types[NSPasteboard.PasteboardType.png.rawValue] = png }
        putOnClipboard(types, layers.count == 1 ? Self.title(of: layers[0]) : "\(layers.count) objects")
        return true
    }

    @discardableResult
    func cutSelected() -> Bool {
        guard copySelected() else { return false }
        removeSelected()
        return true
    }

    /// The selected area as it looks now, with everything drawn on it, as
    /// a picture; outside a shape that is not a rectangle it is
    /// transparent.
    func areaImage() -> Data? {
        guard let area, let image = ImageCompositor.render(edits, base: base, cropped: false) else { return nil }
        let r = area.rect.integral.intersection(CGRect(origin: .zero, size: size))
        let width = Int(r.width), height = Int(r.height)
        guard width >= 1, height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The image's pixels, y down, from the area's corner.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        if area.shape != .rectangle {
            let path = ImageCompositor.path(area.shape, in: area.rect, points: area.points)
            ctx.addPath(path.cgPath)
            ctx.clip()
        }
        // Drawn upright in a flipped space.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
        return ctx.makeImage().flatMap(ImageCompositor.png)
    }

    /// Puts the selected area on the clipboard as a picture, into the
    /// history list the settings name for copies from the editor.
    @discardableResult
    func copyArea() -> Bool {
        guard let png = areaImage() else { return false }
        putOnClipboard([NSPasteboard.PasteboardType.png.rawValue: png], "Part of an image")
        return true
    }

    /// Pastes objects copied from an image editor; false when there are
    /// none on the clipboard.
    @discardableResult
    func pasteObjects() -> Bool {
        guard let data = pasteboard.data(forType: Self.objectsType),
              let layers = try? JSONDecoder().decode([ImageLayer].self, from: data), !layers.isEmpty else { return false }
        insertCopies(of: layers)
        return true
    }

    /// Copies of the selected objects, a little off them.
    func duplicateSelected() {
        let layers = selectedLayers
        guard !layers.isEmpty else { return NSSound.beep() }
        insertCopies(of: layers)
    }

    /// Adds copies with ids of their own; moved a little while they would
    /// cover an object of the same kind exactly. Pasted markers keep their
    /// numbers; the next one counts on from the highest.
    private func insertCopies(of layers: [ImageLayer]) {
        var copies = layers.map { layer -> ImageLayer in
            var copy = layer
            copy.id = UUID()
            return copy
        }
        let step = max(8, Double(min(size.width, size.height)) / 50)
        var tries = 0
        while tries < 50, copies.contains(where: { c in edits.layers.contains { $0.kind == c.kind && $0.rect == c.rect } }) {
            for i in copies.indices { copies[i].move(by: step, step) }
            tries += 1
        }
        if tool != .pointer { tool = .pointer }
        area = nil
        checkpoint()
        live { $0.layers.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
        nextNumber = max(nextNumber, highestNumber + 1)
        commit()
    }

    /// Turns the selected objects by an angle, in degrees clockwise, each
    /// about its own centre.
    func rotate(by degrees: Double) {
        updateSelected("rotate") { $0.rotation = Self.normalized($0.rotation + degrees) }
    }

    /// The angle shown for the selection: the topmost selected object's.
    var rotation: Double { selectedLayers.last?.rotation ?? 0 }

    static func normalized(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a <= -180 { a += 360 }
        return a
    }

    /// The part of the image the result keeps.
    var visibleRect: CGRect { edits.crop ?? CGRect(origin: .zero, size: size) }

    func newText(at point: CGPoint) -> ImageLayer {
        var layer = ImageLayer(kind: .text, start: point, end: point)
        layer.text = "Text"
        layer.stroke = style.stroke
        layer.fill = style.fill
        layer.fontSize = style.fontSize
        layer.fitText()
        return layer
    }

    /// A numbered marker centred on a point, with the next number.
    func newMarker(at center: CGPoint) -> ImageLayer {
        let shape = style.marker ?? .circle
        let width = markerWidth ?? max(24, Double(min(size.width, size.height)) / 16)
        let height = width * shape.aspect
        var layer = ImageLayer(kind: .marker, start: CGPoint(x: center.x - width / 2, y: center.y - height / 2),
                               end: CGPoint(x: center.x + width / 2, y: center.y + height / 2))
        layer.marker = shape
        layer.number = nextNumber
        layer.stroke = style.stroke
        return layer
    }

    /// Drops a marker: it gets the next number, and the counter goes up.
    @discardableResult
    func dropMarker(at center: CGPoint) -> ImageLayer {
        let layer = newMarker(at: center)
        add(layer)
        nextNumber = max(nextNumber, layer.number ?? 0) + 1
        commit()
        return layer
    }

    /// A new shape, line or arrow, styled as the last one.
    func newLayer(_ kind: ImageLayer.Kind, at point: CGPoint) -> ImageLayer {
        var layer = style
        layer.id = UUID()
        layer.kind = kind
        layer.start = point
        layer.end = point
        layer.points = nil
        if kind != .shape { layer.fill = nil }
        if kind != .line { layer.form = .straight }
        return layer
    }

    /// The one selected layer's kind, an old arrow counted as a line.
    var selectedKind: ImageLayer.Kind? {
        selectedLayer.map(Self.kind)
    }

    /// The kinds of the selected layers.
    var selectedKinds: Set<ImageLayer.Kind> {
        Set(selectedLayers.map(Self.kind))
    }

    /// Every selected layer is one of these kinds (and one is selected).
    func selectionIs(_ kinds: Set<ImageLayer.Kind>) -> Bool {
        let selected = selectedKinds
        return !selected.isEmpty && selected.isSubset(of: kinds)
    }

    /// The inspector changed a style: the next layers take it, and so do
    /// the selected ones of `kinds`.
    func setStyle(_ key: String, for kinds: Set<ImageLayer.Kind>, _ change: @escaping (inout ImageLayer) -> Void) {
        change(&style)
        updateSelected(key, only: kinds, change)
    }

    /// The shape of new shapes and areas, of the area being selected, and
    /// of the selected shape or effect. A polygon gets corners from the
    /// shape it was, so they can be dragged.
    func setShape(_ shape: ImageShape) {
        style.shape = shape
        if var a = area {
            if !shape.usesPoints {
                a.points = nil
            } else if a.points == nil {
                a.setPoints(ImageCompositor.outlinePoints(a.shape, in: a.rect))
            }
            a.shape = shape
            area = a
        }
        do {
            updateSelected("shape", only: [.shape, .effect]) { layer in
                // Points are kept while unused, and fitted to the box when
                // used again; a shape that never had any gets its outline.
                if shape.usesPoints && layer.activePoints == nil {
                    if layer.points?.isEmpty ?? true {
                        layer.points = layer.shape == .oval || layer.shape == .circle
                            ? ImageCompositor.controlPoints(around: layer.rect)
                            : ImageCompositor.outlinePoints(layer.shape, in: layer.rect)
                    }
                    layer.fitKeptPoints()
                }
                layer.shape = shape
                if let points = layer.activePoints { layer.setPoints(points) }
            }
        }
        canvas?.needsDisplay = true
    }

    /// How new lines run, and the selected one.
    func setForm(_ form: LineForm) {
        style.form = form
        updateSelected("form", only: [.line]) { layer in
            // A straight line keeps its points, unused; they come back,
            // fitted between its ends, when it is no longer straight.
            if form != .straight && layer.activePoints == nil {
                if layer.points?.isEmpty ?? true { layer.points = [layer.start, layer.end] }
                layer.fitKeptPoints()
            }
            layer.form = form
            if let points = layer.activePoints { layer.setPoints(points) }
        }
    }

    /// Selects layers, as from the list of objects.
    func select(_ ids: Set<UUID>) {
        if !ids.isEmpty {
            if tool != .pointer { tool = .pointer }
            area = nil
        }
        selection = ids
        canvas?.needsDisplay = true
    }

    func select(_ id: UUID?) {
        select(id.map { [$0] } ?? [])
    }

    /// Every object, as ⌘A does with the pointer.
    func selectAllObjects() {
        select(Set(edits.layers.map(\.id)))
    }

    enum Order { case front, forward, backward, back }

    /// Moves layers up or down the pile, keeping their order among
    /// themselves: forward and backward pass one other layer each.
    func reorder(_ ids: Set<UUID>, _ order: Order) {
        var layers = edits.layers
        let moving = layers.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        switch order {
        case .front:
            layers = layers.filter { !ids.contains($0.id) } + moving
        case .back:
            layers = moving + layers.filter { !ids.contains($0.id) }
        case .forward:
            for i in stride(from: layers.count - 2, through: 0, by: -1)
            where ids.contains(layers[i].id) && !ids.contains(layers[i + 1].id) {
                layers.swapAt(i, i + 1)
            }
        case .backward:
            for i in layers.indices.dropFirst() where ids.contains(layers[i].id) && !ids.contains(layers[i - 1].id) {
                layers.swapAt(i, i - 1)
            }
        }
        guard layers != edits.layers else { return }
        change { $0.layers = layers }
    }

    func reorder(_ id: UUID, _ order: Order) {
        reorder([id], order)
    }

    /// Reorders from the list of objects, which shows the topmost first.
    func moveInList(_ offsets: IndexSet, to destination: Int) {
        var top = Array(edits.layers.reversed())
        top.move(fromOffsets: offsets, toOffset: destination)
        let layers = Array(top.reversed())
        guard layers != edits.layers else { return }
        change { $0.layers = layers }
    }

    /// How a layer is named in the list of objects.
    static func title(of layer: ImageLayer) -> String {
        switch layer.kind {
        case .shape:
            return layer.shape.title + (layer.fill != nil ? ", filled" : "")
        case .line, .arrow:
            let heads = [layer.startHead, layer.endHead].filter { $0 != .none }.count
            let name = heads == 0 ? "Line" : heads == 2 ? "Double Arrow" : "Arrow"
            return layer.form == .straight ? name : "\(layer.form.title) \(name.lowercased())"
        case .text:
            let first = (layer.text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "Text “\(first.prefix(30))”"
        case .image:
            return "Pasted Image"
        case .effect:
            guard let effect = layer.effect, effect != .erase else { return "Deleted Area" }
            return effect.title
        case .marker:
            return "Marker \(layer.number ?? 1)"
        }
    }

    static func symbol(of layer: ImageLayer) -> String {
        switch layer.kind {
        case .shape: layer.shape.symbol
        case .line, .arrow:
            layer.form == .freehand ? "scribble"
                : layer.startHead == .none && layer.endHead == .none ? "line.diagonal" : "arrow.up.right"
        case .text: "textformat"
        case .image: "photo"
        case .effect: layer.effect == .erase ? "eraser" : "wand.and.stars"
        case .marker: (layer.marker ?? .circle).symbol
        }
    }
}

/// A selected area, waiting for an action.
struct ImageArea: Equatable {
    var shape: ImageShape
    var start: CGPoint
    var end: CGPoint
    /// The corners of a polygon, the line of a freehand area.
    var points: [CGPoint]?

    init(shape: ImageShape, start: CGPoint, end: CGPoint, points: [CGPoint]? = nil) {
        self.shape = shape
        self.start = start
        self.end = end
        if let points { setPoints(points) }
    }

    var rect: CGRect {
        if let points, !points.isEmpty { return ImageLayer.bounds(points) }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    mutating func setPoints(_ new: [CGPoint]) {
        points = new
        let r = ImageLayer.bounds(new)
        start = r.origin
        end = CGPoint(x: r.maxX, y: r.maxY)
    }
}

/// The editor: tools, the selected layer's style, the picture and the list
/// of what is on it. Every control keeps its place; what does not apply is
/// disabled, never hidden.
struct ImageEditorView: View {
    @Bindable var model: ImageEditorModel
    @FocusState private var textFocused: Bool
    @State private var settings = SettingsStore.shared
    @State private var showObjects = true

    /// Anything about the grid that changes how the canvas looks.
    private var gridKey: String {
        "\(settings.value.imageGridShown) \(settings.value.imageGridSize)"
    }

    var body: some View {
        VStack(spacing: 0) {
            row { commandRow }.labelStyle(.iconOnly)
            Divider()
            row { styleRow }
            Divider()
            row { objectRow }
            Divider()
            HStack(spacing: 0) {
                ImageCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .dropDestination(for: String.self) { items, location in
                        guard items.contains(ImageCanvasView.markerDrag) else { return false }
                        return model.canvas?.dropMarker(atView: location) ?? false
                    }
                if showObjects {
                    Divider()
                    ImageLayerList(model: model)
                        .frame(width: 210)
                }
            }
            Divider()
            HStack(spacing: 10) {
                zoomControls
                separator
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onChange(of: model.focusText) { textFocused = true }
        .onChange(of: gridKey) { model.canvas?.needsDisplay = true }
        .onDisappear { model.saveNow() }
    }

    /// A row of controls from the left; it scrolls when the window is too
    /// narrow, so nothing moves.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
    }

    private var separator: some View { Divider().frame(height: 16) }

    // MARK: What applies

    /// What the controls show: the selected object, the topmost of the
    /// selected ones, or how new ones look.
    private var current: ImageLayer { model.selectedLayers.last ?? model.style }

    /// The kinds of object the style controls work on with nothing
    /// selected: what the tool draws. With the pointer, they set how new
    /// objects look.
    private var targets: Set<ImageLayer.Kind> {
        switch model.tool {
        case .pointer: return [.shape, .line, .text, .marker]
        case .shape: return [.shape]
        case .line: return [.line]
        case .text: return [.text]
        case .marker: return [.marker]
        case .area: return [.effect]
        case .crop, .hand: return []
        }
    }

    /// A control works on the selection when every selected object has
    /// what it sets; with nothing selected, when the tool's objects do.
    private func applies(_ kinds: ImageLayer.Kind...) -> Bool {
        if model.hasSelection { return model.selectionIs(Set(kinds)) }
        return !targets.isDisjoint(with: kinds)
    }

    // MARK: Rows

    /// Tools, and the commands.
    @ViewBuilder private var commandRow: some View {
        Picker("Tool", selection: $model.tool) {
            ForEach(ImageEditorModel.Tool.allCases) { tool in
                Image(systemName: tool.symbol).help(tool.title + ": " + tool.help).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        separator
        Group {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        separator
        Group {
            Button("Cut", systemImage: "scissors") { model.cut() }
                .disabled(!model.canCopy)
                .help("Cut the selected objects, or the selected area: copy it, then delete it (⌘X)")
            Button("Copy", systemImage: "doc.on.doc") { model.copy() }
                .disabled(!model.canCopy)
                .help("Copy the selected objects (⌘C): they paste into this or any other image, and as a picture into other apps. With an area selected, copy the area as it looks now, as a picture. Settings name the history list copies go to.")
            Button("Paste", systemImage: "doc.on.clipboard") { if !model.paste() { NSSound.beep() } }
                .help("Paste copied objects, or the image or text on the clipboard, into the picture (⌘V)")
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateSelected() }
                .disabled(!model.hasSelection)
                .help("Copies of the selected objects, a little off them (⌘D)")
            Button("Remove", systemImage: "trash") { model.removeSelected() }
                .disabled(!model.hasSelection)
                .help("Remove the selected objects from the picture (Delete)")
        }
        separator
        Toggle(isOn: $model.editingPoints) { Image(systemName: "point.topleft.down.to.point.bottomright.curvepath") }
            .toggleStyle(.button)
            .disabled(!(model.selectedLayer?.canEditPoints ?? false))
            .help("Edit Points: drag the points of the selected line or shape one by one, instead of resizing its box. Double-click the object does the same.")
        Stepper(value: Binding(get: { model.rotation }, set: { model.rotate(by: $0 - model.rotation) }), step: 15) {
            Text(model.hasSelection ? "\(Int(model.rotation.rounded()))°" : "–°")
                .monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .disabled(!model.hasSelection)
        .help("Turn the selected objects by 15°, each about its centre; or drag the round handle above one selected object (with Shift, in steps of 15°)")
        separator
        Group {
            Button("Delete Area", systemImage: "eraser") { model.apply(.erase) }
                .help("Make the selected area transparent (Delete)")
            Menu {
                ForEach(ImageEffect.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(ImageEffect.inGroup(group), id: \.self) { effect in
                            Button(effect.title) { model.apply(effect) }
                        }
                    }
                }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .fixedSize()
            .help("Hide, distort or recolour the selected area. The effect stays an object you can move, resize, change or remove.")
            Button("Crop to Area", systemImage: "crop") { model.cropToArea() }
                .help("Keep only the selected area (its bounding rectangle)")
        }
        .disabled(model.area == nil)
        separator
        gridControls
        separator
        Menu {
            Button("Remove Crop") { model.setCrop(nil) }
                .disabled(model.edits.crop == nil)
            Button("Remove Everything Added") {
                model.selection = []
                model.change { $0.layers = [] }
            }
            .disabled(model.edits.layers.isEmpty)
            Divider()
            Button("Back to the Original Image") { model.revertToOriginal() }
                .disabled(model.edits.isUnchanged)
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .fixedSize()
        .help("The original image is always kept: remove the crop, everything added, or both")
        Toggle(isOn: $showObjects) { Image(systemName: "sidebar.right") }
            .toggleStyle(.button)
            .help("Show the list of objects on the picture, to select one hidden behind another or to change their order")
        Spacer(minLength: 0)
    }

    /// How things look: colour, fill, line, shape, the heads, text size.
    @ViewBuilder private var styleRow: some View {
        ColorPicker("Color", selection: Binding(
            get: { Color(nsColor: current.stroke.nsColor) },
            set: { color in model.setStyle("stroke", for: [.shape, .line, .text, .marker]) { $0.stroke = RGBA(NSColor(color)) } }))
            .disabled(!applies(.shape, .line, .text, .marker))
            .help("The colour of lines, outlines, text and markers")
        Toggle(isOn: Binding(get: { current.fill != nil },
                             set: { on in model.setStyle("fillOn", for: [.shape, .text]) { $0.fill = on ? ($0.fill ?? RGBA.white) : nil } })) {
            Text(model.selectedKinds == [.text] || (!model.hasSelection && model.tool == .text) ? "Background" : "Fill")
                .frame(width: 66, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .disabled(!applies(.shape, .text))
        .help("Fill shapes; a background behind texts")
        ColorPicker("Fill color", selection: Binding(
            get: { Color(nsColor: (current.fill ?? .white).nsColor) },
            set: { color in model.setStyle("fill", for: [.shape, .text]) { $0.fill = RGBA(NSColor(color)) } }))
            .labelsHidden()
            .disabled(!applies(.shape, .text) || current.fill == nil)
        separator
        Stepper(value: Binding(get: { current.lineWidth },
                               set: { w in model.setStyle("width", for: [.shape, .line]) { $0.lineWidth = w } }), in: 1...60) {
            Text("Line \(Int(current.lineWidth)) px").monospacedDigit().frame(width: 62, alignment: .leading)
        }
        .disabled(!applies(.shape, .line))
        Picker("Line style", selection: Binding(get: { current.lineStyle },
                                                set: { s in model.setStyle("lineStyle", for: [.shape, .line]) { $0.lineStyle = s } })) {
            ForEach(LineStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(width: 118)
        .disabled(!applies(.shape, .line))
        separator
        iconMenu("The shape of new shapes and areas, and of the selected one",
                 selection: Binding(get: { model.area?.shape ?? current.shape }, set: { model.setShape($0) }),
                 options: ImageShape.allCases, title: \.title, icon: { Image(systemName: $0.symbol) })
            .disabled(!applies(.shape, .effect))
        iconMenu("How new lines run, and the selected one: straight, point by point, or freehand",
                 selection: Binding(get: { current.form }, set: { model.setForm($0) }),
                 options: LineForm.allCases, title: \.title, icon: { Image(systemName: $0.symbol) })
            .disabled(!applies(.line))
        iconMenu("What is at the start of the line",
                 selection: Binding(get: { current.startHead },
                                    set: { h in model.setStyle("startHead", for: [.line]) { $0.startHead = h } }),
                 options: ArrowHead.allCases, title: \.title,
                 icon: { Image(nsImage: ImageCompositor.headImage($0, atStart: true)) })
            .disabled(!applies(.line))
        iconMenu("What is at the end of the line",
                 selection: Binding(get: { current.endHead },
                                    set: { h in model.setStyle("endHead", for: [.line]) { $0.endHead = h } }),
                 options: ArrowHead.allCases, title: \.title,
                 icon: { Image(nsImage: ImageCompositor.headImage($0, atStart: false)) })
            .disabled(!applies(.line))
        separator
        Stepper(value: Binding(get: { current.fontSize },
                               set: { s in model.setStyle("fontSize", for: [.text]) { $0.fontSize = s } }), in: 6...400, step: 2) {
            Text("Text \(Int(current.fontSize))").monospacedDigit().frame(width: 52, alignment: .leading)
        }
        .disabled(!applies(.text))
        .help("The text's size, in pixels of the image")
        Spacer(minLength: 0)
    }

    /// What belongs to one kind of object: markers, the text, the effect.
    @ViewBuilder private var objectRow: some View {
        let layer = model.selectedLayer
        let markers = model.selectionIs([.marker]) ? model.selectedLayers.last : nil
        let markerShape = markers?.marker ?? model.style.marker ?? .circle
        // In the colour of the markers: the selected ones', or the next one's.
        let markerColor = markers?.stroke ?? model.style.stroke
        iconMenu("The shape of new markers, and of the selected ones",
                 selection: Binding(get: { markerShape },
                                    set: { new in model.setStyle("marker", for: [.marker]) { $0.marker = new; Self.reshape(&$0) } }),
                 options: MarkerShape.allCases, title: \.title,
                 icon: { Image(nsImage: ImageCompositor.markerImage($0, number: model.nextNumber, color: markerColor, height: 16)) })
            .disabled(model.hasSelection && markers == nil)
        Image(nsImage: ImageCompositor.markerImage(model.style.marker ?? .circle, number: model.nextNumber,
                                                   color: model.style.stroke, height: 20))
            .frame(width: 24, height: 22)
            .onDrag { NSItemProvider(object: ImageCanvasView.markerDrag as NSString) }
            .help("Drag this marker onto the picture; the next one gets the next number, and the size of the last one")
        Stepper(value: $model.nextNumber, in: 0...9999) {
            Text("Next \(model.nextNumber)").monospacedDigit().frame(width: 58, alignment: .leading)
        }
        .help("The number the next marker gets")
        Stepper(value: Binding(get: { layer?.number ?? 1 },
                               set: { n in model.updateSelected("number") { $0.number = n } }), in: 0...9999) {
            Text(model.selectedKind == .marker ? "Marker \(layer?.number ?? 1)" : "Marker –")
                .monospacedDigit().frame(width: 74, alignment: .leading)
        }
        .disabled(model.selectedKind != .marker)
        .help("The selected marker's number")
        separator
        TextField("Text", text: Binding(
            get: { model.selectedKind == .text ? layer?.text ?? "" : "" },
            set: { text in model.updateSelected("text") { $0.text = text } }), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .frame(width: 170)
            .focused($textFocused)
            .disabled(model.selectedKind != .text)
            .help("The selected text")
        separator
        effectControls(model.selectionIs([.effect]) ? model.selectedLayers.last : nil)
        Spacer(minLength: 0)
    }

    /// A pull-down showing the chosen option's icon, with a checkmark at
    /// the chosen one in the menu.
    private func iconMenu<T: Hashable>(_ help: String, selection: Binding<T>, options: [T],
                                       title: @escaping (T) -> String, icon: @escaping (T) -> Image) -> some View {
        Menu {
            Picker(help, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Label { Text(title(option)) } icon: { icon(option) }.tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            icon(selection.wrappedValue)
        }
        .fixedSize()
        .help(help)
    }

    /// A marker keeps its width when its shape changes; its height follows
    /// the new shape.
    private static func reshape(_ layer: inout ImageLayer) {
        guard layer.kind == .marker else { return }
        let r = layer.rect
        let height = r.width * (layer.marker ?? .circle).aspect
        layer.start = CGPoint(x: r.minX, y: r.midY - height / 2)
        layer.end = CGPoint(x: r.maxX, y: r.midY + height / 2)
    }

    /// How big the picture is shown: smaller, the size, bigger, 1:1, to
    /// fit. 100 % is one pixel of the image on one pixel of the screen.
    @ViewBuilder private var zoomControls: some View {
        Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoomOut() }
            .labelStyle(.iconOnly)
            .disabled(model.shownZoom <= ImageEditorModel.zoomRange.lowerBound * 1.001)
            .help("Zoom out (⌘−; or ⌘-scroll, or pinch)")
        Menu {
            Button("Zoom to Fit") { model.setZoom(nil) }
            Button("Actual Size (1:1)") { model.setZoom(1) }
            Divider()
            ForEach(ImageEditorModel.zoomSteps, id: \.self) { z in
                Button(Self.percent(z)) { model.setZoom(z) }
            }
        } label: {
            Text(Self.percent(model.shownZoom)).monospacedDigit()
        }
        .fixedSize()
        .help("How big the picture is shown: 100 % puts one pixel of the image on one pixel of the screen")
        Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoomIn() }
            .labelStyle(.iconOnly)
            .disabled(model.shownZoom >= ImageEditorModel.zoomRange.upperBound / 1.001)
            .help("Zoom in (⌘+; or ⌘-scroll, or pinch)")
        Button("1:1") { model.setZoom(1) }
            .disabled(model.zoom == 1)
            .help("Actual size: one pixel of the image on one pixel of the screen (⌘0)")
        Button("Fit") { model.setZoom(nil) }
            .disabled(model.zoom == nil)
            .help("The whole picture in the window (⌘9)")
    }

    static func percent(_ zoom: Double) -> String {
        let p = zoom * 100
        return p < 10 ? String(format: "%.1f %%", p) : "\(Int(p.rounded())) %"
    }

    /// The grid sizes the stepper goes through; a typed size steps to the
    /// next one up or down.
    static let gridSizes = [2, 4, 5, 8, 10, 15, 16, 20, 25, 30, 32, 40, 50, 64, 75, 100, 128, 150, 200, 250, 256, 500, 1000]

    static func gridSize(after size: Int, up: Bool) -> Int {
        up ? gridSizes.first { $0 > size } ?? size : gridSizes.last { $0 < size } ?? size
    }

    /// The grid and snapping, each one click away.
    @ViewBuilder private var gridControls: some View {
        Toggle(isOn: $settings.value.imageGridShown) { Image(systemName: "grid") }
            .toggleStyle(.button)
            .help("Show the grid")
        TextField("Grid size", value: Binding(get: { settings.value.imageGridSize },
                                              set: { settings.value.imageGridSize = max(2, min(1000, $0)) }),
                  format: .number)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 40)
            .help("The grid's size, in pixels of the image")
        Stepper("Grid size", onIncrement: {
            settings.value.imageGridSize = Self.gridSize(after: settings.value.imageGridSize, up: true)
        }, onDecrement: {
            settings.value.imageGridSize = Self.gridSize(after: settings.value.imageGridSize, up: false)
        })
        .labelsHidden()
        .help("A bigger or smaller grid: " + Self.gridSizes.map(String.init).joined(separator: ", ") + " px")
        Text("px").foregroundStyle(.secondary)
        Toggle(isOn: $settings.value.imageSnapToGrid) { Image(systemName: "dot.squareshape.split.2x2") }
            .toggleStyle(.button)
            .help("Snap to the grid: drawing, moving and resizing land on its lines, shown or not. Hold ⌘ while dragging to snap to nothing.")
        Toggle(isOn: $settings.value.imageSnapToObjects) { Image(systemName: "align.horizontal.center") }
            .toggleStyle(.button)
            .help("Snap to other objects: edges and centres line up with those of the other objects and of the image; a line shows when they do. Hold ⌘ while dragging to snap to nothing.")
    }

    /// The selected effect's kind, size and strength; disabled without one.
    @ViewBuilder private func effectControls(_ layer: ImageLayer?) -> some View {
        let effect = layer?.effect ?? .mosaic
        Picker("Effect", selection: Binding(get: { effect },
                                            set: { e in
                                                model.updateSelected("effect") {
                                                    if $0.effect != e { $0.effectSize = e.defaultSize }
                                                    $0.effect = e
                                                }
                                            })) {
            Text(ImageEffect.erase.title).tag(ImageEffect.erase)
            ForEach(ImageEffect.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ImageEffect.inGroup(group), id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .labelsHidden()
        .frame(width: 130)
        .disabled(layer == nil)
        .help("The selected effect")
        Stepper(value: Binding(get: { layer?.effectSize ?? effect.defaultSize },
                               set: { s in model.updateSelected("size") { $0.effectSize = s } }), in: 1...200) {
            Text(layer != nil && effect.usesSize ? "Size \(Int(layer?.effectSize ?? 0)) px" : "Size –")
                .monospacedDigit().frame(width: 62, alignment: .leading)
        }
        .disabled(layer == nil || !effect.usesSize)
        .help("The size of the blocks, crystals, dots or blur, in pixels of the image")
        Text("Strength")
            .foregroundStyle(layer != nil && effect.usesStrength ? .primary : .tertiary)
        Slider(value: Binding(get: { layer?.strength ?? 0.5 },
                              set: { v in model.updateSelected("strength") { $0.strength = v } }), in: 0.02...1)
            .frame(width: 120)
            .disabled(layer == nil || !effect.usesStrength)
            .help("How strongly the area is distorted")
    }

    private var hint: String {
        if model.isBuilding {
            return "Click the next point; double-click, press Return or click the first point to finish."
        }
        if model.area != nil {
            return "Choose what to do with the selected area: ⌘C copies it as it looks, ⌘X copies and deletes it, Delete deletes it."
        }
        if model.selection.count > 1 {
            return "\(model.selection.count) objects selected: drag one to move them all; the controls change what they all have. ⌘-click adds or removes one."
        }
        if let layer = model.selectedLayer {
            switch layer.kind {
            case .text: return "Type in the Text field; drag the text to move it, a corner to make it bigger. Delete removes it."
            case .marker: return "Drag to move, a corner to resize: the next markers get this size. Delete removes it."
            default:
                if model.editingPoints {
                    return "Drag a point to move it; double-click or Escape goes back to the box."
                }
                return "Drag to move, a corner to resize, the round handle to turn it" + (layer.canEditPoints ? "; double-click to drag its points one by one" : "")
                    + ". ⌥-click selects what is behind, ⌘-click selects more."
            }
        }
        return model.tool.help + ". The original image is kept; everything added stays editable."
    }
}

/// The objects on the picture, the topmost first: to select one that is
/// hidden behind another, and to change their order.
struct ImageLayerList: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Objects")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(Array(model.edits.layers.reversed())) { layer in
                    Label {
                        Text(ImageEditorModel.title(of: layer)).lineLimit(1)
                    } icon: {
                        Image(systemName: ImageEditorModel.symbol(of: layer))
                            .foregroundStyle(layer.kind == .image || layer.kind == .effect
                                             ? Color.secondary : Color(nsColor: layer.stroke.nsColor))
                    }
                    .tag(layer.id)
                }
                .onMove { model.moveInList($0, to: $1) }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty { orderButtons(ids) }
            }
            .overlay {
                if model.edits.layers.isEmpty {
                    Text("Nothing added yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 6) {
                let ids = model.selection
                Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") { model.reorder(ids, .front) }
                    .help("Bring the selected objects to the front")
                Button("Bring Forward", systemImage: "chevron.up") { model.reorder(ids, .forward) }
                    .help("Bring the selected objects one step forward")
                Button("Send Backward", systemImage: "chevron.down") { model.reorder(ids, .backward) }
                    .help("Send the selected objects one step backward")
                Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") { model.reorder(ids, .back) }
                    .help("Send the selected objects to the back")
                Spacer(minLength: 0)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.hasSelection)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder private func orderButtons(_ ids: Set<UUID>) -> some View {
        Button("Bring to Front") { model.reorder(ids, .front) }
        Button("Bring Forward") { model.reorder(ids, .forward) }
        Button("Send Backward") { model.reorder(ids, .backward) }
        Button("Send to Back") { model.reorder(ids, .back) }
        Divider()
        Button(ids.count == 1 ? "Remove" : "Remove \(ids.count) Objects") {
            model.select(ids)
            model.removeSelected()
        }
    }
}

/// The picture, drawn from the edits, and the mouse and keys that change it.
struct ImageCanvas: NSViewRepresentable {
    let model: ImageEditorModel

    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let view = ImageCanvasView()
        view.model = model
        scroll.documentView = view
        model.canvas = view
        return scroll
    }

    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        guard let view = scroll.documentView as? ImageCanvasView else { return }
        view.model = model
        model.canvas = view
        view.updateSize()
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

/// Scrolls the picture when it is zoomed in; the canvas follows its size.
final class ImageScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? ImageCanvasView)?.updateSize()
    }
}

final class ImageCanvasView: NSView, NSMenuItemValidation {
    weak var model: ImageEditorModel?

    private enum Drag {
        case creating(UUID)
        /// From where the mouse went down, and the layers as they were then,
        /// so snapping never drifts. `clicked`: one of several selected,
        /// which alone stays selected if the mouse goes up without moving.
        case moving(origin: CGPoint, originals: [ImageLayer], clicked: UUID?)
        /// A rectangle dragged over the objects to select, added to `base`.
        case selecting(start: CGPoint, base: Set<UUID>)
        /// A corner of the box.
        case resizing(UUID, handle: Int)
        /// One point of a line or shape.
        case point(UUID, index: Int)
        /// The rotation handle: the angle of the mouse when it went down,
        /// and the rotation then.
        case rotating(UUID, from: Double, original: Double)
        case area(start: CGPoint)
        case crop(start: CGPoint)
        /// A line or shape drawn with the mouse.
        case freehand(UUID)
        case freehandArea
        /// The picture grabbed: where the mouse went down, in the window,
        /// and what was scrolled to then.
        case panning(start: CGPoint, origin: CGPoint)
    }

    private enum Handle {
        case corner(Int), point(Int), rotate
    }

    /// A polygon, polyline or polygon area being clicked point by point.
    /// Its last point follows the mouse until the next click.
    private enum Building {
        case layer(UUID, closed: Bool)
        case area
    }

    /// What a marker dragged from the editor's bar carries.
    static let markerDrag = "dev.verhas.snippad.image-marker"

    private var drag: Drag?
    private var building: Building? {
        didSet { model?.isBuilding = building != nil }
    }
    /// Snapping is on for this drag (⌘ turns it off).
    private var snapping = true
    /// Space is held: the mouse moves the picture, whatever the tool.
    private var spaceHeld = false {
        didSet { if spaceHeld != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// The lines, in pixels of the image, that something just snapped to.
    private var guides: (x: [CGFloat], y: [CGFloat]) = ([], [])
    /// The rectangle being dragged to select objects, in pixels of the
    /// image.
    private var marquee: CGRect?
    /// A cached picture for the screen, redrawn when the edits change.
    private var cached: (edits: ImageEdits, scale: CGFloat, image: CGImage)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Geometry

    private static let inset: CGFloat = 16

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The part of the canvas the window shows, and its size.
    private var viewport: CGRect { enclosingScrollView?.contentView.bounds ?? bounds }

    /// Points of the view per pixel of the image: the zoom, or what fits.
    private var scale: CGFloat {
        guard let model else { return 1 }
        if let zoom = model.zoom { return CGFloat(zoom) / backing }
        let size = viewport.size, inset = Self.inset
        let fit = min((size.width - 2 * inset) / model.size.width, (size.height - 2 * inset) / model.size.height, 4)
        return max(fit, 0.01)
    }

    /// Points of the view per pixel of the image, and where the image sits:
    /// in the middle while it is smaller than the window.
    private var placement: (scale: CGFloat, origin: CGPoint) {
        guard let model else { return (1, .zero) }
        let scale = scale
        return (scale, CGPoint(x: (bounds.width - model.size.width * scale) / 2,
                               y: (bounds.height - model.size.height * scale) / 2))
    }

    /// The canvas is the window's size, or the zoomed picture's if that is
    /// bigger: then it scrolls.
    func updateSize() {
        guard let model else { return }
        let s = scale, view = viewport.size
        let size = CGSize(width: max(view.width, (model.size.width * s + 2 * Self.inset).rounded(.up)),
                          height: max(view.height, (model.size.height * s + 2 * Self.inset).rounded(.up)))
        if frame.size != size { setFrameSize(size) }
        let shown = Double(s * backing)
        if abs(model.shownZoom - shown) > 1e-9 { model.shownZoom = shown }
    }

    /// Zooms (nil: to fit), keeping the point under `anchor` (a point of
    /// the canvas; the middle of what is shown when nil) where it is.
    func setZoom(_ zoom: Double?, around anchor: CGPoint? = nil) {
        guard let model else { return }
        guard let scroll = enclosingScrollView else {
            model.zoom = zoom
            return
        }
        let clip = scroll.contentView
        let visible = clip.bounds
        let at = anchor ?? CGPoint(x: visible.midX, y: visible.midY)
        let fromCorner = CGPoint(x: at.x - visible.minX, y: at.y - visible.minY)
        let p = toImage(at)
        model.zoom = zoom
        updateSize()
        let v = toView(p)
        let target = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: v.x - fromCorner.x, y: v.y - fromCorner.y),
                                                     size: visible.size))
        clip.setBoundsOrigin(target.origin)
        scroll.reflectScrolledClipView(clip)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSize()
    }

    /// Scrolls to a point of the canvas, as far as it goes.
    private func scroll(toOrigin origin: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.setBoundsOrigin(clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let (s, o) = placement
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let (s, o) = placement
        return CGRect(x: o.x + r.minX * s, y: o.y + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let (s, o) = placement
        return CGPoint(x: o.x + p.x * s, y: o.y + p.y * s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let imageRect = toView(CGRect(origin: .zero, size: model.size))
        drawCheckerboard(in: imageRect, only: dirtyRect)

        let backing = window?.backingScaleFactor ?? 2
        let scale = min(1, placement.scale * backing)
        if cached == nil || cached!.edits != model.edits || abs(cached!.scale - scale) > 0.01 {
            if let image = ImageCompositor.render(model.edits, base: model.base, scale: scale, cropped: false) {
                cached = (model.edits, scale, image)
            }
        }
        if let image = cached?.image, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // The view is flipped; the image is not.
            ctx.translateBy(x: imageRect.minX, y: imageRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            // Zoomed in past 1:1: the pixels, sharp, as they are.
            ctx.interpolationQuality = model.shownZoom > 1.001 ? .none : .high
            ctx.draw(image, in: CGRect(origin: .zero, size: imageRect.size))
            ctx.restoreGState()
        }

        if model.settings.value.imageGridShown {
            drawGrid(in: imageRect, only: dirtyRect)
        }

        // Outside the crop: dimmed, still visible, so the crop can be changed.
        if let crop = model.cropDrag ?? model.edits.crop {
            let keep = toView(crop)
            let dim = NSBezierPath(rect: imageRect)
            dim.append(NSBezierPath(rect: keep).reversed)
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let frame = NSBezierPath(rect: keep)
            frame.lineWidth = 1
            frame.stroke()
        }

        if let area = model.area {
            antsStroke(ImageCompositor.path(area.shape, in: toView(area.rect), points: area.points?.map(toView)))
        }

        // The points put down so far; the first one closes a polygon.
        if let points = buildingPoints, points.count > 1 {
            for (i, point) in points.dropLast().enumerated() {
                let v = toView(point)
                let r: CGFloat = i == 0 ? 5 : 3
                let dot = NSBezierPath(ovalIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
                NSColor.white.setFill()
                dot.fill()
                NSColor.controlAccentColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }

        if building == nil {
            if let layer = model.selectedLayer {
                drawSelection(of: layer, points: model.editingPoints && layer.canEditPoints)
            } else {
                // Several: each one's box, without handles.
                for layer in model.selectedLayers { drawOutline(of: layer) }
            }
        }

        if let marquee {
            let path = NSBezierPath(rect: toView(marquee))
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            antsStroke(path)
        }

        // Where something snapped to another object.
        if !guides.x.isEmpty || !guides.y.isEmpty {
            NSColor.systemPink.setStroke()
            let path = NSBezierPath()
            for x in guides.x {
                let vx = toView(CGPoint(x: x, y: 0)).x
                path.move(to: CGPoint(x: vx, y: bounds.minY)); path.line(to: CGPoint(x: vx, y: bounds.maxY))
            }
            for y in guides.y {
                let vy = toView(CGPoint(x: 0, y: y)).y
                path.move(to: CGPoint(x: bounds.minX, y: vy)); path.line(to: CGPoint(x: bounds.maxX, y: vy))
            }
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// One of several selected objects: its turned box.
    private func drawOutline(of layer: ImageLayer) {
        let corners = layer.worldCorners.map(toView)
        guard let first = corners.first else { return }
        let outline = NSBezierPath()
        outline.move(to: first)
        corners.dropFirst().forEach { outline.line(to: $0) }
        outline.close()
        outline.lineWidth = 1.5
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    /// The selected object: its turned box with corner handles and the
    /// rotation handle; or, editing points, its points.
    private func drawSelection(of layer: ImageLayer, points editing: Bool) {
        let outline = NSBezierPath()
        let corners = editing ? layer.editablePoints.map { toView(layer.toWorld($0)) } : layer.worldCorners.map(toView)
        guard let first = corners.first else { return }
        outline.move(to: first)
        corners.dropFirst().forEach { outline.line(to: $0) }
        if !(editing && layer.isLine) { outline.close() }
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        let all = handles(of: layer)
        if !editing, let rotate = all.first(where: { if case .rotate = $0.1 { true } else { false } })?.0 {
            let r = layer.rect
            let stem = NSBezierPath()
            stem.move(to: toView(layer.toWorld(CGPoint(x: r.midX, y: r.minY))))
            stem.line(to: rotate)
            stem.lineWidth = 1
            stem.stroke()
        }
        let small = all.count > 40
        for (point, kind) in all {
            let size: CGFloat = small ? 5 : 8
            let r = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let path: NSBezierPath
            switch kind {
            case .corner: path = NSBezierPath(rect: r)
            case .point, .rotate: path = NSBezierPath(ovalIn: r)
            }
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// The grid over the image, only where it is drawn now: zoomed in, the
    /// image is far bigger than the window.
    private func drawGrid(in rect: CGRect, only dirty: CGRect) {
        guard let model else { return }
        let step = CGFloat(max(2, model.settings.value.imageGridSize)) * placement.scale
        // Too dense to see anything but grey.
        guard step >= 4 else { return }
        let area = rect.intersection(dirty.insetBy(dx: -1, dy: -1))
        guard !area.isNull else { return }
        let path = NSBezierPath()
        var x = rect.minX + ((area.minX - rect.minX) / step).rounded(.down) * step
        while x <= min(rect.maxX, area.maxX) + 0.5 {
            path.move(to: CGPoint(x: x, y: area.minY)); path.line(to: CGPoint(x: x, y: area.maxY))
            x += step
        }
        var y = rect.minY + ((area.minY - rect.minY) / step).rounded(.down) * step
        while y <= min(rect.maxY, area.maxY) + 0.5 {
            path.move(to: CGPoint(x: area.minX, y: y)); path.line(to: CGPoint(x: area.maxX, y: y))
            y += step
        }
        path.lineWidth = 0.5
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.stroke()
        path.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Snapping

    /// The x and y lines to snap to: the edges and centres of the image, of
    /// the crop, and of every other object.
    private func snapLines(excluding id: UUID?) -> (x: [CGFloat], y: [CGFloat]) {
        snapLines(excluding: id.map { [$0] } ?? [])
    }

    private func snapLines(excluding ids: Set<UUID>) -> (x: [CGFloat], y: [CGFloat]) {
        guard let model else { return ([], []) }
        var xs: [CGFloat] = [0, model.size.width / 2, model.size.width]
        var ys: [CGFloat] = [0, model.size.height / 2, model.size.height]
        if let crop = model.edits.crop {
            xs += [crop.minX, crop.midX, crop.maxX]
            ys += [crop.minY, crop.midY, crop.maxY]
        }
        for layer in model.edits.layers where !ids.contains(layer.id) {
            if layer.isLine {
                let ends = [layer.linePoints.first, layer.linePoints.last].compactMap { $0 }.map(layer.toWorld)
                xs += ends.map(\.x)
                ys += ends.map(\.y)
            } else {
                let r = layer.worldBounds
                xs += [r.minX, r.midX, r.maxX]
                ys += [r.minY, r.midY, r.maxY]
            }
        }
        return (xs, ys)
    }

    /// How far to move along one axis so that one of `values` lands on a
    /// line of another object (preferred) or, failing that, the first of
    /// them on the grid.
    private func snapOffset(_ values: [CGFloat], lines: [CGFloat], guide: inout [CGFloat]) -> CGFloat {
        guard snapping, let model, let first = values.first else { return 0 }
        let settings = model.settings.value
        if settings.imageSnapToObjects {
            let reach = 6 / placement.scale
            var best: (delta: CGFloat, line: CGFloat)?
            for v in values {
                for line in lines where abs(line - v) <= reach && abs(line - v) < abs(best?.delta ?? .infinity) {
                    best = (line - v, line)
                }
            }
            if let best {
                guide.append(best.line)
                return best.delta
            }
        }
        if settings.imageSnapToGrid {
            let g = CGFloat(max(2, settings.imageGridSize))
            return (first / g).rounded() * g - first
        }
        return 0
    }

    /// A point being drawn, snapped.
    private func snap(_ p: CGPoint, excluding id: UUID?) -> CGPoint {
        guides = ([], [])
        let lines = snapLines(excluding: id)
        return CGPoint(x: p.x + snapOffset([p.x], lines: lines.x, guide: &guides.x),
                       y: p.y + snapOffset([p.y], lines: lines.y, guide: &guides.y))
    }

    /// Layers being moved, snapped: one by its edges and centre (a line by
    /// its ends), several by the edges and centre of the box round them.
    private func snapped(_ layers: [ImageLayer]) -> [ImageLayer] {
        guides = ([], [])
        guard let first = layers.first else { return layers }
        let lines = snapLines(excluding: Set(layers.map(\.id)))
        let xs: [CGFloat], ys: [CGFloat]
        if layers.count == 1 && first.isLine {
            let ends = [first.linePoints.first, first.linePoints.last].compactMap { $0 }.map(first.toWorld)
            xs = ends.map(\.x)
            ys = ends.map(\.y)
        } else {
            let r = layers.map(\.worldBounds).reduce(CGRect.null) { $0.union($1) }
            xs = [r.minX, r.midX, r.maxX]
            ys = [r.minY, r.midY, r.maxY]
        }
        let dx = snapOffset(xs, lines: lines.x, guide: &guides.x), dy = snapOffset(ys, lines: lines.y, guide: &guides.y)
        return layers.map { layer in
            var moved = layer
            moved.move(by: dx, dy)
            return moved
        }
    }

    /// The objects a rectangle touches.
    private func layers(touching rect: CGRect) -> Set<UUID> {
        guard let model else { return [] }
        return Set(model.edits.layers.filter { $0.worldBounds.insetBy(dx: -0.5, dy: -0.5).intersects(rect) }.map(\.id))
    }

    /// A marker dragged from the editor's bar and dropped here.
    /// `point` is in the picture's frame in the window, from its top left.
    func dropMarker(atView point: CGPoint) -> Bool {
        guard let model else { return false }
        let shown = viewport
        let p = toImage(CGPoint(x: shown.minX + point.x, y: shown.minY + point.y))
        guard CGRect(origin: .zero, size: model.size).contains(p) else { return false }
        snapping = true
        model.dropMarker(at: snap(p, excluding: nil))
        guides = ([], [])
        window?.makeFirstResponder(self)
        needsDisplay = true
        return true
    }

    /// Behind the image's transparent parts; only where it is drawn now.
    private func drawCheckerboard(in rect: CGRect, only dirty: CGRect) {
        let area = rect.intersection(dirty)
        guard !area.isNull else { return }
        NSColor.white.setFill()
        area.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        let size: CGFloat = 8
        var row = Int(((area.minY - rect.minY) / size).rounded(.down))
        var y = rect.minY + CGFloat(row) * size
        while y < area.maxY {
            let column = Int(((area.minX - rect.minX) / size).rounded(.down) / 2) * 2
            var x = rect.minX + CGFloat(column) * size + (row % 2 == 0 ? 0 : size)
            while x < area.maxX {
                CGRect(x: x, y: y, width: min(size, rect.maxX - x), height: min(size, rect.maxY - y)).fill()
                x += 2 * size
            }
            y += size
            row += 1
        }
    }

    private func antsStroke(_ path: NSBezierPath) {
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
    }

    /// The handles, in view points: the corners of the turned box and the
    /// rotation handle above it; editing points, the points.
    private func handles(of layer: ImageLayer) -> [(CGPoint, Handle)] {
        if model?.editingPoints == true && layer.canEditPoints {
            return layer.editablePoints.enumerated().map { (toView(layer.toWorld($1)), .point($0)) }
        }
        var result: [(CGPoint, Handle)] = layer.worldCorners.enumerated().map { (toView($1), .corner($0)) }
        let r = layer.rect
        let top = toView(layer.toWorld(CGPoint(x: r.midX, y: r.minY)))
        // Straight up from the box, turned with it.
        let a = (layer.rotation - 90) * .pi / 180
        result.append((CGPoint(x: top.x + 24 * cos(a), y: top.y + 24 * sin(a)), .rotate))
        return result
    }

    // MARK: Mouse

    override func resetCursorRects() {
        let cursor: NSCursor = spaceHeld || model?.tool == .hand ? .openHand
            : model?.tool == .pointer ? .arrow : model?.tool == .text ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    /// The layers under a point, the topmost first.
    private func layers(at p: CGPoint) -> [ImageLayer] {
        guard let model else { return [] }
        let tolerance = 6 / placement.scale
        return model.edits.layers.reversed().filter { layer in
            let p = layer.toLocal(p)
            if layer.isLine {
                let points = layer.linePoints
                let reach = max(tolerance, layer.lineWidth / 2 + tolerance / 2)
                return zip(points, points.dropFirst()).contains { distance(p, $0, $1) <= reach }
            }
            return layer.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    private func layer(at p: CGPoint) -> ImageLayer? { layers(at: p).first }

    // MARK: Point by point

    private var buildingPoints: [CGPoint]? {
        guard let model, let building else { return nil }
        switch building {
        case .layer(let id, _): return model.edits.layers.first { $0.id == id }?.points
        case .area: return model.area?.points
        }
    }

    private func setBuildingPoints(_ points: [CGPoint]) {
        guard let model, let building else { return }
        switch building {
        case .layer(let id, _):
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }) else { return }
                edits.layers[i].setPoints(points)
            }
        case .area:
            model.area?.setPoints(points)
        }
        needsDisplay = true
    }

    private var buildingID: UUID? {
        if case .layer(let id, _) = building { return id }
        return nil
    }

    /// Starts a polygon, polyline or polygon area at a point.
    private func startBuilding(_ kind: ImageLayer.Kind?, at p: CGPoint) {
        guard let model else { return }
        if let kind {
            var layer = model.newLayer(kind, at: p)
            if kind == .shape { layer.shape = .polygon } else { layer.form = .polyline }
            layer.setPoints([p, p])
            model.add(layer)
            building = .layer(layer.id, closed: kind == .shape)
        } else {
            model.area = ImageArea(shape: .polygon, start: p, end: p, points: [p, p])
            building = .area
        }
    }

    /// The last point follows the mouse.
    private func moveLastPoint(to p: CGPoint) {
        guard var points = buildingPoints, !points.isEmpty else { return }
        points[points.count - 1] = snap(p, excluding: buildingID)
        setBuildingPoints(points)
    }

    /// A click while building: the next point, or the end.
    private func buildingClick(at p: CGPoint, view viewPoint: CGPoint, clicks: Int) {
        guard var points = buildingPoints, !points.isEmpty else { return finishBuilding() }
        let closed: Bool
        switch building {
        case .layer(_, let c): closed = c
        default: closed = true
        }
        let first = toView(points[0])
        if clicks >= 2 || (closed && points.count >= 4 && hypot(first.x - viewPoint.x, first.y - viewPoint.y) <= 8) {
            return finishBuilding()
        }
        let point = snap(p, excluding: buildingID)
        points[points.count - 1] = point
        points.append(point)
        setBuildingPoints(points)
    }

    /// Ends a polygon or polyline: what has fewer than its points is
    /// dropped.
    func finishBuilding() {
        guard let model, let building, var points = buildingPoints else {
            self.building = nil
            return
        }
        guides = ([], [])
        // The point following the mouse is not one of them.
        points.removeLast()
        points = points.reduce(into: []) { kept, p in
            if let last = kept.last, hypot(last.x - p.x, last.y - p.y) < 0.5 { return }
            kept.append(p)
        }
        switch building {
        case .layer(let id, let closed):
            if points.count < (closed ? 3 : 2) {
                model.selected = nil
                model.cancelChange()
            } else {
                setBuildingPoints(points)
                model.selected = id
                model.commit()
            }
        case .area:
            if points.count < 3 { model.area = nil } else { model.area?.setPoints(points) }
        }
        self.building = nil
        needsDisplay = true
    }

    var isBuilding: Bool { building != nil }

    override func mouseMoved(with event: NSEvent) {
        guard building != nil else { return }
        snapping = !event.modifierFlags.contains(.command)
        moveLastPoint(to: toImage(convert(event.locationInWindow, from: nil)))
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        snapping = !event.modifierFlags.contains(.command)
        let p = toImage(viewPoint)

        if spaceHeld || model.tool == .hand {
            startPanning(event)
            return
        }

        if building != nil {
            buildingClick(at: p, view: viewPoint, clicks: event.clickCount)
            return
        }

        // A handle of the selected layer, whatever the tool.
        if let layer = model.selectedLayer,
           let handle = handles(of: layer).last(where: { hypot($0.0.x - viewPoint.x, $0.0.y - viewPoint.y) <= 7 })?.1 {
            model.checkpoint()
            switch handle {
            case .corner(let i):
                drag = .resizing(layer.id, handle: i)
            case .point(let i):
                drag = .point(layer.id, index: i)
            case .rotate:
                let c = layer.center
                drag = .rotating(layer.id, from: atan2(p.y - c.y, p.x - c.x), original: layer.rotation)
            }
            return
        }

        switch model.tool {
        case .hand:
            break
        case .pointer:
            let flags = event.modifierFlags
            // ⌘- or ⇧-click: one more selected, or one less.
            let adding = flags.contains(.command) || flags.contains(.shift)
            // ⌥-click: the next one down under the mouse.
            let hits = layers(at: p)
            var found = hits.first
            if flags.contains(.option), let i = hits.firstIndex(where: { model.selection.contains($0.id) }) {
                found = hits[(i + 1) % hits.count]
            }
            guard let hit = found else {
                // On nothing: a rectangle to select what it touches.
                if !adding { model.selection = [] }
                drag = .selecting(start: p, base: model.selection)
                break
            }
            var clicked: UUID?
            if adding {
                if model.selection.contains(hit.id) {
                    model.selection.remove(hit.id)
                    break
                }
                model.selection.insert(hit.id)
            } else if flags.contains(.option) || !model.selection.contains(hit.id) {
                model.selection = [hit.id]
            } else if model.selection.count > 1 {
                clicked = hit.id
            }
            model.checkpoint()
            drag = .moving(origin: p, originals: model.selectedLayers, clicked: clicked)
            // A double-click: the text to type in, or the points of a
            // line or shape to drag one by one (and back to the box).
            if event.clickCount == 2 && !adding {
                model.selection = [hit.id]
                drag = .moving(origin: p, originals: [hit], clicked: nil)
                if hit.kind == .text {
                    model.focusText += 1
                } else if hit.canEditPoints {
                    model.editingPoints.toggle()
                }
            }
        case .text:
            if let hit = layer(at: p), hit.kind == .text {
                model.selected = hit.id
                model.checkpoint()
                drag = .moving(origin: p, originals: [hit], clicked: nil)
            } else {
                model.add(model.newText(at: snap(p, excluding: nil)))
                model.commit()
            }
            model.focusText += 1
        case .marker:
            if let hit = layer(at: p), hit.kind == .marker {
                model.selected = hit.id
                model.checkpoint()
                drag = .moving(origin: p, originals: [hit], clicked: nil)
            } else {
                // Placed at once; dragging before letting go moves it.
                let layer = model.dropMarker(at: snap(p, excluding: nil))
                drag = .moving(origin: p, originals: [layer], clicked: nil)
            }
        case .shape, .line:
            let kind: ImageLayer.Kind = model.tool == .shape ? .shape : .line
            let polygon = kind == .shape ? model.style.shape == .polygon : model.style.form == .polyline
            let freehand = kind == .shape ? model.style.shape == .freehand : model.style.form == .freehand
            if polygon {
                startBuilding(kind, at: snap(p, excluding: nil))
            } else if freehand {
                var layer = model.newLayer(kind, at: p)
                if kind == .shape { layer.shape = .freehand } else { layer.form = .freehand }
                layer.setPoints([p])
                model.add(layer)
                drag = .freehand(layer.id)
            } else {
                let layer = model.newLayer(kind, at: snap(p, excluding: nil))
                model.add(layer)
                drag = .creating(layer.id)
            }
        case .area:
            switch model.style.shape {
            case .polygon:
                startBuilding(nil, at: snap(p, excluding: nil))
            case .freehand:
                model.area = ImageArea(shape: .freehand, start: p, end: p, points: [p])
                drag = .freehandArea
            default:
                let start = snap(p, excluding: nil)
                model.area = ImageArea(shape: model.style.shape, start: start, end: start)
                drag = .area(start: start)
            }
        case .crop:
            let start = snap(p, excluding: nil)
            model.cropDrag = CGRect(origin: start, size: .zero)
            drag = .crop(start: start)
        }
        needsDisplay = true
    }

    // MARK: Moving the picture

    /// The mouse grabs the picture.
    private func startPanning(_ event: NSEvent) {
        drag = .panning(start: event.locationInWindow, origin: viewport.origin)
        NSCursor.closedHand.push()
    }

    /// The middle button moves the picture, whatever the tool.
    override func otherMouseDown(with event: NSEvent) {
        guard drag == nil, building == nil else { return }
        startPanning(event)
    }

    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    override func otherMouseUp(with event: NSEvent) {
        if case .panning = drag {
            drag = nil
            NSCursor.pop()
        }
    }

    /// Scrolling moves the picture (with Shift, sideways, also with a
    /// mouse's wheel); with ⌘ or ⌥ it zooms about the mouse.
    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.option) {
            guard let model else { return }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            guard delta != 0 else { return }
            let zoom = model.shownZoom * pow(1.01, Double(delta))
            let clamped = min(max(zoom, ImageEditorModel.zoomRange.lowerBound), ImageEditorModel.zoomRange.upperBound)
            return setZoom(clamped, around: convert(event.locationInWindow, from: nil))
        }
        if flags.contains(.shift), event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 {
            // A wheel that macOS did not turn sideways itself.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            let origin = viewport.origin
            return scroll(toOrigin: CGPoint(x: origin.x - delta, y: origin.y))
        }
        super.scrollWheel(with: event)
    }

    /// Pinching zooms about the fingers.
    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let zoom = model.shownZoom * (1 + Double(event.magnification))
        let clamped = min(max(zoom, ImageEditorModel.zoomRange.lowerBound), ImageEditorModel.zoomRange.upperBound)
        setZoom(clamped, around: convert(event.locationInWindow, from: nil))
    }

    /// A double tap with two fingers: 1:1 there, or back to fit.
    override func smartMagnify(with event: NSEvent) {
        guard let model else { return }
        setZoom(model.zoom == nil ? 1 : nil, around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        if case .panning(let start, let origin) = drag {
            let now = event.locationInWindow
            // The window's y goes up, the canvas's down.
            return scroll(toOrigin: CGPoint(x: origin.x - (now.x - start.x), y: origin.y + (now.y - start.y)))
        }
        // Dragged past the edge of the window: the picture follows.
        if drag != nil || building != nil { autoscroll(with: event) }
        if building != nil { return mouseMoved(with: event) }
        guard let model, let drag else { return }
        snapping = !event.modifierFlags.contains(.command)
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        var p = raw
        switch drag {
        case .creating(let id):
            p = snap(raw, excluding: id)
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }) else { return }
                let layer = edits.layers[i]
                edits.layers[i].end = constrained(p, from: layer.start, square: layer.shape == .circle && layer.kind == .shape || shift && !layer.isLine)
            }
        case .moving(let origin, let originals, _):
            let moved = snapped(originals.map { layer in
                var l = layer
                l.move(by: raw.x - origin.x, raw.y - origin.y)
                return l
            })
            model.live { edits in
                for layer in moved {
                    guard let i = edits.layers.firstIndex(where: { $0.id == layer.id }) else { continue }
                    edits.layers[i] = layer
                }
            }
        case .selecting(let start, let base):
            let rect = CGRect(x: min(start.x, raw.x), y: min(start.y, raw.y), width: abs(raw.x - start.x), height: abs(raw.y - start.y))
            marquee = rect
            model.selection = base.union(layers(touching: rect))
        case .resizing(let id, let handle):
            p = snap(raw, excluding: id)
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }) else { return }
                let center = edits.layers[i].center
                resize(&edits.layers[i], handle: handle, to: edits.layers[i].toLocal(p), shift: shift)
                edits.layers[i].reanchor(from: center)
            }
        case .point(let id, let index):
            p = snap(raw, excluding: id)
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }) else { return }
                let center = edits.layers[i].center
                edits.layers[i].setPoint(index, to: edits.layers[i].toLocal(p))
                edits.layers[i].reanchor(from: center)
            }
        case .rotating(let id, let from, let original):
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }) else { return }
                let c = edits.layers[i].center
                var degrees = original + (atan2(raw.y - c.y, raw.x - c.x) - from) * 180 / .pi
                // Shift: in steps of 15°.
                if shift { degrees = (degrees / 15).rounded() * 15 }
                degrees = degrees.truncatingRemainder(dividingBy: 360)
                if degrees > 180 { degrees -= 360 }
                if degrees <= -180 { degrees += 360 }
                edits.layers[i].rotation = degrees
            }
        case .area(let start):
            p = snap(raw, excluding: nil)
            let square = model.style.shape == .circle || shift
            p = constrained(p, from: start, square: square)
            model.area = ImageArea(shape: model.style.shape, start: start, end: p)
        case .crop(let start):
            p = snap(raw, excluding: nil)
            model.cropDrag = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .freehand(let id):
            model.live { edits in
                guard let i = edits.layers.firstIndex(where: { $0.id == id }), var points = edits.layers[i].points,
                      let last = points.last, hypot(raw.x - last.x, raw.y - last.y) * placement.scale >= 2 else { return }
                points.append(raw)
                edits.layers[i].setPoints(points)
            }
        case .panning:
            break
        case .freehandArea:
            guard var points = model.area?.points, let last = points.last,
                  hypot(raw.x - last.x, raw.y - last.y) * placement.scale >= 2 else { break }
            points.append(raw)
            model.area?.setPoints(points)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let drag else { return }
        self.drag = nil
        guides = ([], [])
        let tiny = { (r: CGRect) in max(r.width, r.height) * self.placement.scale < 3 }
        switch drag {
        case .panning:
            NSCursor.pop()
            return
        case .creating(let id):
            // A click without a drag draws nothing.
            if let layer = model.edits.layers.first(where: { $0.id == id }),
               hypot(layer.end.x - layer.start.x, layer.end.y - layer.start.y) * placement.scale < 3 {
                model.selected = nil
                model.cancelChange()
                return
            }
            model.commit()
        case .moving(_, _, let clicked):
            if model.dropCheckpointIfUnchanged() {
                // A click on one of several selected: that one alone.
                if let clicked { model.selection = [clicked] }
            } else {
                model.commit()
            }
        case .selecting:
            marquee = nil
        case .resizing, .point, .rotating:
            if !model.dropCheckpointIfUnchanged() { model.commit() }
            // The next markers take the size of one just resized.
            if case .resizing(let id, _) = drag, let layer = model.edits.layers.first(where: { $0.id == id }), layer.kind == .marker {
                model.markerWidth = layer.rect.width
            }
        case .area:
            if let area = model.area, hypot(area.end.x - area.start.x, area.end.y - area.start.y) * placement.scale < 3 {
                model.area = nil
            }
        case .freehand(let id):
            if let layer = model.edits.layers.first(where: { $0.id == id }), (layer.points?.count ?? 0) >= 3, !tiny(layer.rect) {
                // Fewer points, as many as the drawing needs: fewer to drag.
                let tolerance = 0.8 / placement.scale
                model.live { edits in
                    guard let i = edits.layers.firstIndex(where: { $0.id == id }), let points = edits.layers[i].points else { return }
                    edits.layers[i].setPoints(Self.simplified(points, tolerance: tolerance))
                }
                model.commit()
            } else {
                model.selected = nil
                model.cancelChange()
            }
        case .freehandArea:
            if let area = model.area, (area.points?.count ?? 0) < 3 || tiny(area.rect) {
                model.area = nil
            } else if let points = model.area?.points {
                model.area?.setPoints(Self.simplified(points, tolerance: 0.8 / placement.scale))
            }
        case .crop:
            let rect = model.cropDrag
            model.cropDrag = nil
            if let rect, rect.width * placement.scale >= 3, rect.height * placement.scale >= 3 {
                model.setCrop(rect)
                model.tool = .pointer
            }
        }
        needsDisplay = true
    }

    /// Drops the points a line would pass within `tolerance` of anyway
    /// (Ramer-Douglas-Peucker).
    static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        var farthest = 0, distance: CGFloat = 0
        let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let d = length > 0 ? abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length : hypot(p.x - a.x, p.y - a.y)
            if d > distance { distance = d; farthest = i }
        }
        guard distance > tolerance else { return [a, b] }
        let left = simplified(Array(points[...farthest]), tolerance: tolerance)
        let right = simplified(Array(points[farthest...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    private func constrained(_ p: CGPoint, from start: CGPoint, square: Bool) -> CGPoint {
        guard square else { return p }
        let side = max(abs(p.x - start.x), abs(p.y - start.y))
        return CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
    }

    /// Drags a corner of the box to `p`, in the layer's own positions.
    private func resize(_ layer: inout ImageLayer, handle: Int, to p: CGPoint, shift: Bool) {
        let r = layer.rect
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        let fixed = corners[(handle + 2) % 4]
        if layer.kind == .text {
            // A text grows by its font size; its box follows the text.
            let height = max(abs(p.y - fixed.y), 4)
            layer.fontSize = max(4, layer.fontSize * height / max(r.height, 1))
            let size = ImageLayer.textSize(layer.text ?? "", font: layer.font)
            let x = p.x < fixed.x ? fixed.x - size.width : fixed.x
            let y = p.y < fixed.y ? fixed.y - size.height : fixed.y
            layer.start = CGPoint(x: x, y: y)
            layer.end = CGPoint(x: x + size.width, y: y + size.height)
            return
        }
        let circle = (layer.kind == .shape || layer.kind == .effect) && layer.shape == .circle
        var end = constrained(p, from: fixed, square: circle || (shift && !layer.keepsProportions))
        if layer.keepsProportions, !(shift && layer.kind == .image), r.width > 0, r.height > 0 {
            // Pasted images (unless Shift is held) and markers keep their
            // proportions.
            let ratio = r.width / r.height
            let w = abs(end.x - fixed.x), h = abs(end.y - fixed.y)
            let fit = max(w / ratio, h)
            end = CGPoint(x: fixed.x + (end.x < fixed.x ? -fit * ratio : fit * ratio), y: fixed.y + (end.y < fixed.y ? -fit : fit))
        }
        if layer.activePoints != nil || layer.isLine {
            // Lines, polygons and freehand shapes are stretched.
            layer.scale(from: r, to: CGRect(x: min(fixed.x, end.x), y: min(fixed.y, end.y),
                                            width: abs(end.x - fixed.x), height: abs(end.y - fixed.y)))
            return
        }
        layer.start = fixed
        layer.end = end
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) / max(placement.scale, 0.01)
        if building != nil, [36, 76, 53].contains(Int(event.keyCode)) {  // Return, Enter, Escape
            return finishBuilding()
        }
        if event.keyCode == 49 {  // Space: held, the mouse moves the picture.
            spaceHeld = true
            return
        }
        switch Int(event.keyCode) {
        case 51, 117:  // Delete, Forward Delete
            if model.area != nil {
                model.apply(.erase)
            } else if model.hasSelection {
                model.removeSelected()
            } else {
                NSSound.beep()
            }
        case 53:  // Escape
            if model.editingPoints {
                model.editingPoints = false
            } else {
                model.area = nil
                model.selection = []
            }
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, step)
        case 126: nudge(0, -step)
        default:
            super.keyDown(with: event)
        }
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        spaceHeld = false
        return super.resignFirstResponder()
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let model, model.hasSelection else { return NSSound.beep() }
        model.updateSelected("nudge") { $0.move(by: dx, dy) }
    }

    @objc func paste(_ sender: Any?) {
        if model?.paste() != true { NSSound.beep() }
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        if model?.copy() != true { NSSound.beep() }
    }

    /// Copy, then delete: the area or the objects.
    @objc func cut(_ sender: Any?) {
        if model?.cut() != true { NSSound.beep() }
        needsDisplay = true
    }

    @objc func duplicate(_ sender: Any?) {
        model?.duplicateSelected()
    }

    /// ⌘D duplicates; the app's menus have no Duplicate of their own here.
    /// ⌘+ (or ⌘=) and ⌘− zoom, ⌘0 is 1:1, ⌘9 fits.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift)
        if window?.firstResponder === self, flags == .command, let model {
            switch event.charactersIgnoringModifiers {
            case "d": duplicate(nil)
            case "+", "=": model.zoomIn()
            case "-": model.zoomOut()
            case "0": model.setZoom(1)
            case "9": model.setZoom(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func undo(_ sender: Any?) {
        model?.undo()
    }

    @objc func redo(_ sender: Any?) {
        model?.redo()
    }

    /// With the pointer, every object; with the other tools, the whole
    /// image as an area.
    @objc override func selectAll(_ sender: Any?) {
        guard let model else { return }
        if model.tool == .pointer && !model.edits.layers.isEmpty {
            model.selectAllObjects()
            return
        }
        model.tool = .area
        model.area = ImageArea(shape: .rectangle, start: .zero, end: CGPoint(x: model.size.width, y: model.size.height))
        needsDisplay = true
    }

    @objc func delete(_ sender: Any?) {
        guard let model else { return }
        if model.area != nil { model.apply(.erase) } else { model.removeSelected() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)): return model.canCopy
        case #selector(copy(_:)), #selector(cut(_:)): return model.canCopy
        case #selector(duplicate(_:)): return model.hasSelection
        default: return true
        }
    }
}

/// The editor for an image that may change from outside while it is open:
/// the model is made once, from the edits it is first given.
struct ImageEditorHost: View {
    let edits: ImageEdits
    /// What it edits, so agents (MCP) can change it while it is open.
    var target: ImageTarget? = nil
    let onChange: (ImageEdits, Data) -> Void
    @State private var model: ImageEditorModel?
    @State private var failed = false

    var body: some View {
        if let model {
            ImageEditorView(model: model)
                .onAppear { if let target { OpenImageEditors.register(model, for: target) } }
                .onDisappear {
                    model.saveNow()
                    if let target { OpenImageEditors.unregister(model, for: target) }
                }
        } else if failed {
            ContentUnavailableView("The image cannot be read", systemImage: "photo.badge.exclamationmark")
        } else {
            Color.clear.onAppear {
                model = ImageEditorModel(edits: edits, onChange: onChange)
                failed = model == nil
                // Objects copied out of a history image inherit its category.
                if case .history(let id) = target {
                    model?.putOnClipboard = { types, label in
                        ClipboardHistory.shared.inheriting(from: [id]) {
                            ClipboardHistory.shared.addImageObjects(types, label: label)
                        }
                    }
                }
            }
        }
    }
}

/// An image being edited: a history entry, or a snippet of a file.
enum ImageTarget: Hashable, Sendable {
    case history(UUID)
    /// The file (its library key) and the snippet's draft.
    case snippet(URL, UUID)
}

/// The image editors that are open, so that changes from agents go
/// through them -- shown at once, and undoable -- instead of being
/// overwritten by them.
@MainActor
enum OpenImageEditors {
    private final class Weak { weak var model: ImageEditorModel?; init(_ m: ImageEditorModel) { model = m } }
    private static var open: [ImageTarget: Weak] = [:]
    /// The one opened last, of those still open.
    private(set) static var last: ImageTarget?

    static func register(_ model: ImageEditorModel, for target: ImageTarget) {
        open[target] = Weak(model)
        last = target
    }

    static func unregister(_ model: ImageEditorModel, for target: ImageTarget) {
        guard open[target]?.model === model else { return }
        open[target] = nil
        if last == target { last = open.first { $0.value.model != nil }?.key }
    }

    static func model(for target: ImageTarget) -> ImageEditorModel? {
        open[target]?.model
    }

    /// The open editor in front: the last one opened that is still there.
    static var current: (target: ImageTarget, model: ImageEditorModel)? {
        open = open.filter { $0.value.model != nil }
        if let last, let m = open[last]?.model { return (last, m) }
        return open.first.flatMap { e in e.value.model.map { (e.key, $0) } }
    }
}
