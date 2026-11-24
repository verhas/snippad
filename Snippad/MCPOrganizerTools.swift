import AppKit

/// MCP tools for what the user sees in the Snippad Organizer, the newer
/// history commands, and the image editor: an agent can be asked to "edit
/// the current image" and find out which one that is.
@MainActor
enum MCPOrganizerTools {

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }
    private static func text(_ s: String) -> [String: Any] { MCPTools.text(s) }
    private static func json(_ o: Any) -> [String: Any] { MCPTools.json(o) }

    // MARK: - Which image

    /// How a tool names the image it works on.
    private static let targetProperties: [String: Any] = [
        "id": prop("string", "A history entry's id. Leave out id, path and snippet for the current image: the one open in the image editor, else the image entry or image snippet selected in the Organizer."),
        "path": prop("string", "With snippet: the .snippad file of an image snippet."),
        "snippet": prop("string", "With path: the image snippet's name."),
    ]

    /// The image a call is about.
    static func target(_ args: MCPArguments) throws -> ImageTarget {
        if let id = args.string("id") {
            guard let uuid = UUID(uuidString: id), let item = ClipboardHistory.shared.item(uuid) else {
                throw MCPToolError("No history entry has that id.")
            }
            guard item.kind == .image, !item.isPassword else { throw MCPToolError("That entry is not an image.") }
            return .history(uuid)
        }
        if args.string("path") != nil || args.string("snippet") != nil {
            let url = SnippadLibrary.key(try args.snippadURL())
            let name = try args.requiredString("snippet")
            let model = SnippadLibrary.shared.model(for: url)
            guard let draft = model.drafts.first(where: { $0.name == name }) else {
                throw MCPToolError("\u{201C}\(url.lastPathComponent)\u{201D} has no snippet named \u{201C}\(name)\u{201D}.")
            }
            guard draft.kind == .image else { throw MCPToolError("\u{201C}\(name)\u{201D} is not an image snippet.") }
            return .snippet(url, draft.id)
        }
        if let current = OpenImageEditors.current { return current.target }
        if let selected = selectedImage { return selected }
        throw MCPToolError("No image is open in the image editor, and no image entry or image snippet is selected in the Snippad Organizer. Name one with id, or with path and snippet.")
    }

    /// The image entry or image snippet selected in the Organizer.
    private static var selectedImage: ImageTarget? {
        let nav = HistoryNavigation.shared
        if case .file(let url) = nav.sidebar {
            let model = SnippadLibrary.shared.model(for: url)
            guard let id = model.selection, let draft = model.drafts.first(where: { $0.id == id }), draft.kind == .image else { return nil }
            return .snippet(SnippadLibrary.key(url), id)
        }
        guard nav.selection.count == 1, let id = nav.selection.first, let item = ClipboardHistory.shared.item(id),
              item.kind == .image, !item.isPassword else { return nil }
        return .history(id)
    }

    private static func draft(_ url: URL, _ id: UUID) throws -> (SnippadEditorModel, SnippetDraft) {
        let model = SnippadLibrary.shared.model(for: url)
        guard let draft = model.drafts.first(where: { $0.id == id }) else { throw MCPToolError("The snippet is gone.") }
        return (model, draft)
    }

    /// The edits of an image as they are now: the open editor's, or the
    /// stored ones.
    static func edits(of target: ImageTarget) throws -> ImageEdits {
        if let model = OpenImageEditors.model(for: target) { return model.edits }
        switch target {
        case .history(let id):
            guard let item = ClipboardHistory.shared.item(id) else { throw MCPToolError("The entry is gone.") }
            guard let edits = item.edits ?? item.pngData.map({ ImageEdits(original: $0) }) else {
                throw MCPToolError("The image cannot be read.")
            }
            return edits
        case .snippet(let url, let id):
            let (_, d) = try draft(url, id)
            guard let edits = d.edits ?? Data(base64Encoded: d.value, options: .ignoreUnknownCharacters).map({ ImageEdits(original: $0) }) else {
                throw MCPToolError("The image cannot be read.")
            }
            return edits
        }
    }

    /// Changes an image: through its editor when it is open -- shown at
    /// once, and one Undo there takes it back -- else in the entry or the
    /// snippet, which keep their originals.
    @discardableResult
    static func modify(_ target: ImageTarget, _ change: (inout ImageEdits) throws -> Void) throws -> ImageEdits {
        var edits = try edits(of: target)
        try change(&edits)
        if let crop = edits.crop, let base = ImageCompositor.cgImage(edits.original) {
            let clipped = crop.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            edits.crop = clipped.width >= 2 && clipped.height >= 2 ? clipped : nil
        }
        if let model = OpenImageEditors.model(for: target) {
            let result = edits
            model.change { $0 = result }
            let ids = Set(result.layers.map(\.id))
            if !model.selection.isSubset(of: ids) { model.select(model.selection.intersection(ids)) }
            model.saveNow()
            return model.edits
        }
        guard let png = ImageCompositor.png(edits) else { throw MCPToolError("The image could not be drawn.") }
        switch target {
        case .history(let id):
            ClipboardHistory.shared.updateImage(id, png: png, edits: edits)
            ClipboardHistory.shared.flush()
        case .snippet(let url, let id):
            let (model, d) = try draft(url, id)
            d.edits = edits
            d.value = png.base64EncodedString()
            d.editsVersion += 1
            guard model.save() else { throw MCPToolError(model.problem ?? "The .snippad file could not be saved.") }
        }
        return edits
    }

    private static func describe(_ target: ImageTarget) -> [String: Any] {
        switch target {
        case .history(let id):
            var out: [String: Any] = ["kind": "history_entry", "id": id.uuidString]
            if let item = ClipboardHistory.shared.item(id) { out["title"] = item.title }
            return out
        case .snippet(let url, let id):
            let name = SnippadLibrary.shared.model(for: url).drafts.first { $0.id == id }?.name ?? ""
            return ["kind": "snippet", "path": url.path, "snippet": name]
        }
    }

    // MARK: - Objects as JSON

    private static func hex(_ c: RGBA) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
        return c.a < 0.999 ? rgb + String(format: "%02X", byte(c.a)) : rgb
    }

    private static func color(_ value: Any?, _ key: String) throws -> RGBA? {
        guard let text = value as? String else { throw MCPToolError("'\(key)' must be a colour like \"#FF0000\" or \"#FF000080\"") }
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        let named: [String: String] = ["red": "FF3B30", "green": "34C759", "blue": "007AFF", "yellow": "FFCC00", "orange": "FF9500",
                                       "purple": "AF52DE", "pink": "FF2D55", "black": "000000", "white": "FFFFFF", "gray": "8E8E93", "grey": "8E8E93"]
        if let n = named[t.lowercased()] { t = n }
        guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else {
            throw MCPToolError("'\(key)' must be a colour like \"#FF0000\" or \"#FF000080\"")
        }
        let rgba = t.count == 6 ? (v << 8) | 0xFF : v
        return RGBA(r: Double((rgba >> 24) & 0xFF) / 255, g: Double((rgba >> 16) & 0xFF) / 255,
                    b: Double((rgba >> 8) & 0xFF) / 255, a: Double(rgba & 0xFF) / 255)
    }

    private static func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }

    static func json(_ layer: ImageLayer) -> [String: Any] {
        let rect = layer.rect
        var out: [String: Any] = [
            "id": layer.id.uuidString,
            "kind": ImageEditorModel.kind(of: layer).rawValue,
            "title": ImageEditorModel.title(of: layer),
            "rect": [r(rect.minX), r(rect.minY), r(rect.width), r(rect.height)],
        ]
        if layer.rotation != 0 { out["rotation"] = layer.rotation }
        switch ImageEditorModel.kind(of: layer) {
        case .line, .arrow:
            out["from"] = [r(layer.start.x), r(layer.start.y)]
            out["to"] = [r(layer.end.x), r(layer.end.y)]
            out["form"] = layer.form.rawValue
            out["start_head"] = layer.startHead.rawValue
            out["end_head"] = layer.endHead.rawValue
            out["color"] = hex(layer.stroke)
            out["line_width"] = layer.lineWidth
            out["line_style"] = layer.lineStyle.rawValue
        case .shape:
            out["shape"] = layer.shape.rawValue
            out["color"] = hex(layer.stroke)
            out["fill"] = layer.fill.map(hex) ?? NSNull()
            out["line_width"] = layer.lineWidth
            out["line_style"] = layer.lineStyle.rawValue
        case .text:
            out["text"] = layer.text ?? ""
            out["color"] = hex(layer.stroke)
            out["fill"] = layer.fill.map(hex) ?? NSNull()
            out["font_size"] = layer.fontSize
        case .marker:
            out["number"] = layer.number ?? 1
            out["marker"] = (layer.marker ?? .circle).rawValue
            out["color"] = hex(layer.stroke)
        case .effect:
            out["effect"] = (layer.effect ?? .erase).rawValue
            out["shape"] = layer.shape.rawValue
            if layer.effect?.usesSize == true { out["effect_size"] = layer.effectSize }
            if layer.effect?.usesStrength == true { out["strength"] = layer.strength }
        case .image:
            break
        }
        if let points = layer.activePoints {
            out["points"] = points.prefix(400).map { [r($0.x), r($0.y)] }
        }
        return out
    }

    private static func point(_ value: Any?, _ key: String) throws -> CGPoint {
        guard let a = value as? [Any], a.count == 2, let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue else {
            throw MCPToolError("'\(key)' must be [x, y]")
        }
        return CGPoint(x: x, y: y)
    }

    private static func rect(_ value: Any?, _ key: String) throws -> CGRect {
        guard let a = value as? [Any], a.count == 4 else { throw MCPToolError("'\(key)' must be [x, y, width, height]") }
        let n = try a.map { v -> Double in
            guard let d = (v as? NSNumber)?.doubleValue else { throw MCPToolError("'\(key)' must be [x, y, width, height]") }
            return d
        }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).standardized
    }

    private static func points(_ value: Any?, _ key: String) throws -> [CGPoint] {
        guard let a = value as? [Any], a.count >= 2 else { throw MCPToolError("'\(key)' must be at least two [x, y] points") }
        return try a.map { try point($0, key) }
    }

    private static func choice<T: RawRepresentable>(_ value: Any?, _ key: String, _ type: T.Type) throws -> T where T.RawValue == String, T: CaseIterable {
        guard let s = value as? String, let v = T(rawValue: s) else {
            throw MCPToolError("'\(key)' must be one of: " + T.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return v
    }

    private static func number(_ value: Any?, _ key: String) throws -> Double {
        guard let d = (value as? NSNumber)?.doubleValue else { throw MCPToolError("'\(key)' must be a number") }
        return d
    }

    /// Sets what a description names on a layer. Unknown keys are errors,
    /// so a typo is not silently ignored.
    static func apply(_ spec: [String: Any], to layer: inout ImageLayer, imageSize: CGSize) throws {
        let known: Set<String> = ["kind", "shape", "rect", "from", "to", "points", "form", "start_head", "end_head", "color", "fill",
                                  "line_width", "line_style", "text", "font_size", "effect", "effect_size", "strength", "number",
                                  "marker", "center", "size", "rotation", "move_by"]
        if let unknown = spec.keys.first(where: { !known.contains($0) }) {
            throw MCPToolError("Unknown property '\(unknown)'. Known: " + known.sorted().joined(separator: ", "))
        }
        let center = layer.center
        if let v = spec["shape"] {
            layer.shape = try choice(v, "shape", ImageShape.self)
            if layer.shape.usesPoints, layer.activePoints == nil { layer.makePointsEditable() }
        }
        if let v = spec["form"] { layer.form = try choice(v, "form", LineForm.self) }
        if let v = spec["rect"] {
            let box = try rect(v, "rect")
            if layer.activePoints != nil {
                layer.scale(from: layer.rect, to: box)
            } else {
                layer.start = box.origin
                layer.end = CGPoint(x: box.maxX, y: box.maxY)
            }
        }
        if let v = spec["from"] { layer.start = try point(v, "from") }
        if let v = spec["to"] { layer.end = try point(v, "to") }
        if let v = spec["points"] {
            let p = try points(v, "points")
            if layer.isLine, spec["form"] == nil, layer.form == .straight { layer.form = p.count > 2 ? .polyline : .straight }
            if !layer.isLine, spec["shape"] == nil, !layer.shape.usesPoints { layer.shape = .polygon }
            layer.setPoints(p)
        }
        if let v = spec["center"] {
            let c = try point(v, "center")
            let w = try spec["size"].map { try number($0, "size") } ?? Double(layer.rect.width > 0 ? layer.rect.width : max(24, min(imageSize.width, imageSize.height) / 16))
            let h = w * (layer.kind == .marker ? (layer.marker ?? .circle).aspect : Double(layer.rect.height > 0 && layer.rect.width > 0 ? layer.rect.height / layer.rect.width : 1))
            layer.start = CGPoint(x: c.x - w / 2, y: c.y - h / 2)
            layer.end = CGPoint(x: c.x + w / 2, y: c.y + h / 2)
        } else if let v = spec["size"], layer.kind == .marker {
            let w = try number(v, "size")
            let c = layer.center
            let h = w * (layer.marker ?? .circle).aspect
            layer.start = CGPoint(x: c.x - w / 2, y: c.y - h / 2)
            layer.end = CGPoint(x: c.x + w / 2, y: c.y + h / 2)
        }
        if let v = spec["start_head"] { layer.startHead = try choice(v, "start_head", ArrowHead.self) }
        if let v = spec["end_head"] { layer.endHead = try choice(v, "end_head", ArrowHead.self) }
        if let v = spec["color"] { layer.stroke = try color(v, "color") ?? layer.stroke }
        if let v = spec["fill"] { layer.fill = v is NSNull || (v as? String) == "none" ? nil : try color(v, "fill") }
        if let v = spec["line_width"] { layer.lineWidth = max(0.5, try number(v, "line_width")) }
        if let v = spec["line_style"] { layer.lineStyle = try choice(v, "line_style", LineStyle.self) }
        if let v = spec["text"] {
            guard let t = v as? String else { throw MCPToolError("'text' must be a string") }
            layer.text = t
        }
        if let v = spec["font_size"] { layer.fontSize = max(4, try number(v, "font_size")) }
        if let v = spec["effect"] {
            let e = try choice(v, "effect", ImageEffect.self)
            if layer.effect != e && spec["effect_size"] == nil { layer.effectSize = e.defaultSize }
            layer.effect = e
        }
        if let v = spec["effect_size"] { layer.effectSize = max(1, try number(v, "effect_size")) }
        if let v = spec["strength"] { layer.strength = min(1, max(0, try number(v, "strength"))) }
        if let v = spec["number"] { layer.number = Int(try number(v, "number")) }
        if let v = spec["marker"] { layer.marker = try choice(v, "marker", MarkerShape.self) }
        if let v = spec["rotation"] { layer.rotation = ImageEditorModel.normalized(try number(v, "rotation")) }
        if let v = spec["move_by"] {
            let d = try point(v, "move_by")
            layer.move(by: d.x, d.y)
        }
        layer.fitText()
        if spec["rect"] == nil && spec["center"] == nil && spec["points"] == nil && spec["from"] == nil && spec["to"] == nil
            && spec["move_by"] == nil {
            layer.reanchor(from: center)
        }
    }

    /// A new object from its description.
    static func newLayer(_ spec: [String: Any], in edits: ImageEdits) throws -> ImageLayer {
        guard let kindName = spec["kind"] as? String else {
            throw MCPToolError("Each object needs a 'kind': shape, line, text, marker or effect")
        }
        let kind: ImageLayer.Kind
        switch kindName {
        case "shape", "line", "text", "marker", "effect": kind = ImageLayer.Kind(rawValue: kindName)!
        case "arrow": kind = .line
        default: throw MCPToolError("'kind' must be shape, line, text, marker or effect")
        }
        let size = ImageCompositor.cgImage(edits.original).map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        var layer = ImageLayer(kind: kind, start: .zero, end: .zero)
        switch kind {
        case .line:
            guard spec["from"] != nil && spec["to"] != nil || spec["points"] != nil else {
                throw MCPToolError("A line needs 'from' and 'to', or 'points'")
            }
            if kindName == "arrow" { layer.endHead = .solid }
        case .text:
            guard spec["text"] != nil else { throw MCPToolError("A text needs 'text'") }
            guard let place = spec["rect"] ?? spec["center"] else { throw MCPToolError("A text needs 'rect' (its top left corner counts) or 'center'") }
            _ = place
            layer.fill = nil
        case .marker:
            guard spec["center"] != nil || spec["rect"] != nil else { throw MCPToolError("A marker needs 'center' (and 'size'), or 'rect'") }
            layer.marker = .circle
            let used = edits.layers.compactMap { $0.kind == .marker ? $0.number : nil }.max() ?? 0
            layer.number = used + 1
        case .effect:
            guard spec["effect"] != nil else { throw MCPToolError("An effect needs 'effect'") }
            guard spec["rect"] != nil || spec["points"] != nil else { throw MCPToolError("An effect needs its area: 'rect', or 'points' with 'shape'") }
        case .shape:
            guard spec["rect"] != nil || spec["points"] != nil || spec["center"] != nil else {
                throw MCPToolError("A shape needs 'rect', or 'points'")
            }
        default:
            break
        }
        // Markers and effects take their size from their kind first.
        var spec = spec
        if kind == .marker, let shape = spec["marker"] { layer.marker = try choice(shape, "marker", MarkerShape.self); spec["marker"] = nil }
        try apply(spec.filter { $0.key != "kind" }, to: &layer, imageSize: size)
        if kind == .text, let c = spec["center"], spec["rect"] == nil {
            // Centred on the point, now that its size is known.
            let p = try point(c, "center")
            layer.move(by: p.x - layer.center.x, p.y - layer.center.y)
        }
        if kind == .effect, layer.effect == nil { throw MCPToolError("An effect needs 'effect'") }
        return layer
    }

    /// The image as it looks now, at most `maxSize` pixels on its longer
    /// side.
    private static func picture(_ edits: ImageEdits, maxSize: Int) -> [String: Any]? {
        guard let base = ImageCompositor.cgImage(edits.original) else { return nil }
        let visible = edits.crop ?? CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let scale = min(1, CGFloat(max(64, maxSize)) / max(visible.width, visible.height))
        guard let image = ImageCompositor.render(edits, base: base, scale: scale), let png = ImageCompositor.png(image) else { return nil }
        return ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]
    }

    private static func state(_ target: ImageTarget, _ edits: ImageEdits, withImage: Bool, maxSize: Int = 1024) -> [[String: Any]] {
        let base = ImageCompositor.cgImage(edits.original)
        var info: [String: Any] = [
            "image": describe(target),
            "width": base?.width ?? 0,
            "height": base?.height ?? 0,
            "crop": edits.crop.map { [r($0.minX), r($0.minY), r($0.width), r($0.height)] } ?? NSNull(),
            "objects": edits.layers.map(json),
            "editor_open": OpenImageEditors.model(for: target) != nil,
        ]
        if let model = OpenImageEditors.model(for: target) {
            info["selected"] = model.selectedLayers.map(\.id.uuidString)
            info["can_undo"] = model.canUndo
        }
        var out = [json(info)]
        if withImage, let p = picture(edits, maxSize: maxSize) { out.append(p) }
        return out
    }

    private static func ids(_ args: MCPArguments, in edits: ImageEdits) throws -> Set<UUID> {
        guard let raw = args.raw["ids"] as? [String], !raw.isEmpty else { throw MCPToolError("'ids' must list the objects' ids (see image_get)") }
        let wanted = Set(raw.compactMap(UUID.init(uuidString:)))
        let have = Set(edits.layers.map(\.id))
        let missing = raw.filter { UUID(uuidString: $0).map { !have.contains($0) } ?? true }
        guard missing.isEmpty else { throw MCPToolError("The image has no objects with these ids: " + missing.joined(separator: ", ")) }
        return wanted
    }

    private static func with(_ extra: [String: Any]) -> [String: Any] {
        targetProperties.merging(extra) { a, _ in a }
    }

    private static let objectSchema: [String: Any] = [
        "type": "object",
        "description": """
            An object on the image. kind: shape, line (or arrow: a line with a head at its end), text, marker (a numbered circle or other shape), effect (on an area of the image). \
            Positions in pixels of the original image, from its top left, y down. \
            Shapes and effects: rect [x, y, width, height], or points [[x, y], ...] for a polygon or freehand outline; shape: rectangle, oval, circle, triangle, polygon, freehand. \
            Lines: from [x, y] and to [x, y], or points for a polyline; form: straight, polyline, freehand; start_head, end_head: none, solid, hollow, open, solidCircle, hollowCircle, bar, solidSquare, hollowSquare, solidDiamond, hollowDiamond. \
            Text: text, rect (its top left corner places it; the box fits the text) or center, font_size, color, fill (a background, or "none"). \
            Markers: center [x, y], size (width in pixels), number (default the next), marker: circle, roundedSquare, square, diamond, hexagon, pin, cloud, bubble. \
            Effects: effect: erase (delete the area), mosaic, hexagons, crystallize, pointillize, blur, swirl, vortex, bulge, pinch, hole, kaleidoscope, tunnel, invert, monochrome, sepia, posterize, comic, edges, thermal, xray; effect_size (pixels, for mosaic, blur and the like), strength (0 to 1, for distortions). \
            Style: color ("#RRGGBB", "#RRGGBBAA" or red, green, blue, yellow, orange, purple, pink, black, white, gray), fill, line_width, line_style (solid, dashed, longDashed, dotted, dashDotted), rotation (degrees clockwise).
            """,
        "properties": [:] as [String: Any],
        "additionalProperties": true,
    ]

    // MARK: - The tools

    static let tools: [MCPTool] = [
        MCPTool(name: "organizer_state", title: "What the Organizer shows",
                description: "What the user has in front of them in the Snippad Organizer: whether it is open, the list or .snippad file chosen in its sidebar, the selected history entries or snippet, and the images open in the image editor. \"The current image\" (or entry, or snippet) is what this names.",
                properties: [:], required: [], readOnly: true) { _ in
            let nav = HistoryNavigation.shared
            var out: [String: Any] = ["organizer_open": NSApp.windows.contains { $0.title == "Snippad Organizer" && $0.isVisible }]
            switch nav.sidebar {
            case .all:
                out["sidebar"] = ["kind": "all_lists"]
            case .list(let id):
                out["sidebar"] = ["kind": "list", "list_id": id, "list": SettingsStore.shared.list(id).name]
            case .file(let url):
                out["sidebar"] = ["kind": "snippad_file", "path": url.path]
                let model = SnippadLibrary.shared.model(for: url)
                if let id = model.selection, let d = model.drafts.first(where: { $0.id == id }) {
                    out["selected_snippet"] = ["path": url.path, "snippet": d.name, "kind": d.kind.rawValue]
                }
            }
            if case .file = nav.sidebar {} else {
                let selected = ClipboardHistory.shared.items.filter { nav.selection.contains($0.id) }
                out["selected_entries"] = selected.map(MCPTools.summary)
            }
            if let list = nav.editingList { out["editing_list"] = SettingsStore.shared.list(list).name }
            if let current = OpenImageEditors.current {
                var editor = describe(current.target)
                editor["objects"] = current.model.edits.layers.count
                editor["selected_objects"] = current.model.selectedLayers.map(\.id.uuidString)
                out["image_editor"] = editor
            }
            if let target = OpenImageEditors.current?.target ?? selectedImage {
                out["current_image"] = describe(target)
            } else {
                out["current_image"] = NSNull()
            }
            if let batch = ClipboardHistory.shared.undoableDelete {
                out["undo_delete"] = "\(batch.items.count) entries can be brought back with history_undo_delete"
            }
            return [json(out)]
        },

        MCPTool(name: "organizer_show", title: "Show something in the Organizer",
                description: "Opens the Snippad Organizer on a history entry (id) or a snippet (path and snippet), selected, and with edit_image opens its image in the image editor, so the user sees the changes the image_* tools make.",
                properties: [
                    "id": prop("string", "A history entry's id."),
                    "path": prop("string", "With snippet: a .snippad file."),
                    "snippet": prop("string", "With path: the snippet's name."),
                    "edit_image": prop("boolean", "Open the image editor on it (an image entry or image snippet)."),
                ],
                required: []) { args in
            let nav = HistoryNavigation.shared
            let edit = args.bool("edit_image") ?? false
            if let id = args.string("id") {
                guard let uuid = UUID(uuidString: id), let item = ClipboardHistory.shared.item(uuid) else { throw MCPToolError("No history entry has that id.") }
                HistoryWindow.show()
                if case .file = nav.sidebar { nav.sidebar = .all }
                if case .list(let l) = nav.sidebar, l != item.list { nav.sidebar = .all }
                nav.editingList = nil
                nav.selection = [uuid]
                if edit {
                    guard item.kind == .image, !item.isPassword else { throw MCPToolError("That entry is not an image.") }
                    nav.openImageEditor = uuid
                }
                return [text("The Organizer shows \u{201C}\(item.title)\u{201D}" + (edit ? " in the image editor." : "."))]
            }
            let url = SnippadLibrary.key(try args.snippadURL())
            let name = try args.requiredString("snippet")
            SnippadLibrary.shared.add(url)
            let model = SnippadLibrary.shared.model(for: url)
            guard let d = model.drafts.first(where: { $0.name == name }) else { throw MCPToolError("No snippet is named \u{201C}\(name)\u{201D}.") }
            HistoryWindow.show(file: url)
            model.selection = d.id
            if edit {
                guard d.kind == .image else { throw MCPToolError("\u{201C}\(name)\u{201D} is not an image snippet.") }
                nav.openImageEditor = d.id
            }
            return [text("The Organizer shows \u{201C}\(name)\u{201D}" + (edit ? " in the image editor." : "."))]
        },

        MCPTool(name: "image_get", title: "Look at an image",
                description: "An image being edited -- the current one, a history entry, or an image snippet: its size, crop, and every object on it (with ids for the other image_* tools), and the picture as it looks now.",
                properties: [
                    "id": prop("string", "A history entry's id; leave out for the current image."),
                    "path": prop("string", "With snippet: the .snippad file of an image snippet."),
                    "snippet": prop("string", "With path: the image snippet's name."),
                    "include_image": prop("boolean", "Also return the picture; default true."),
                    "max_size": prop("integer", "The picture's longer side at most this many pixels; default 1024."),
                ],
                required: [], readOnly: true) { args in
            let target = try target(args)
            return state(target, try edits(of: target), withImage: args.bool("include_image") ?? true, maxSize: args.int("max_size") ?? 1024)
        },

        MCPTool(name: "image_add", title: "Draw on an image",
                description: "Adds objects to an image: shapes, lines and arrows, texts, numbered markers, and effects on areas (blur, mosaic, delete, …). They stay objects that can be changed or removed. With the image open in the editor, one Undo there takes them all back.",
                properties: with([
                    "objects": ["type": "array", "items": objectSchema, "description": "The objects to add, bottom one first."],
                    "select": prop("boolean", "Select them in the open image editor; default true."),
                ]),
                required: ["objects"]) { args in
            let target = try target(args)
            guard let specs = args.raw["objects"] as? [[String: Any]], !specs.isEmpty else { throw MCPToolError("'objects' must list at least one object") }
            var added: [ImageLayer] = []
            let edits = try modify(target) { edits in
                for spec in specs {
                    let layer = try newLayer(spec, in: edits)
                    edits.layers.append(layer)
                    added.append(layer)
                }
            }
            if args.bool("select") ?? true, let model = OpenImageEditors.model(for: target) {
                model.select(Set(added.map(\.id)))
            }
            return [json(["added": added.map(json)])] + state(target, edits, withImage: true).dropFirst()
        },

        MCPTool(name: "image_change", title: "Change objects on an image",
                description: "Changes objects already on an image: their place (rect, from/to, points, center, or move_by [dx, dy]), size, rotation, colours, line, text, effect, marker number or shape -- the same properties image_add takes, except kind.",
                properties: with([
                    "ids": ["type": "array", "items": ["type": "string"], "description": "The objects, by id (see image_get)."],
                    "changes": objectSchema,
                ]),
                required: ["ids", "changes"]) { args in
            let target = try target(args)
            guard var changes = args.raw["changes"] as? [String: Any], !changes.isEmpty else { throw MCPToolError("'changes' must say what to change") }
            changes["kind"] = nil
            let current = try edits(of: target)
            let wanted = try ids(args, in: current)
            let size = ImageCompositor.cgImage(current.original).map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let edits = try modify(target) { edits in
                for i in edits.layers.indices where wanted.contains(edits.layers[i].id) {
                    try apply(changes, to: &edits.layers[i], imageSize: size)
                }
            }
            return [json(["changed": edits.layers.filter { wanted.contains($0.id) }.map(json)])] + state(target, edits, withImage: true).dropFirst()
        },

        MCPTool(name: "image_remove", title: "Remove objects from an image",
                description: "Removes objects from an image. The original image is never touched; image_undo (with the editor open) brings them back.",
                properties: with(["ids": ["type": "array", "items": ["type": "string"], "description": "The objects, by id."]]),
                required: ["ids"], destructive: true) { args in
            let target = try target(args)
            let wanted = try ids(args, in: try edits(of: target))
            let edits = try modify(target) { $0.layers.removeAll { wanted.contains($0.id) } }
            return state(target, edits, withImage: true)
        },

        MCPTool(name: "image_order", title: "Bring objects forward or back",
                description: "Moves objects up or down the pile: front, back, forward (past one other) or backward. An effect works on what is below it.",
                properties: with([
                    "ids": ["type": "array", "items": ["type": "string"], "description": "The objects, by id."],
                    "order": prop("string", "front, back, forward or backward."),
                ]),
                required: ["ids", "order"]) { args in
            let target = try target(args)
            let wanted = try ids(args, in: try edits(of: target))
            let order = try args.requiredString("order")
            guard ["front", "back", "forward", "backward"].contains(order) else { throw MCPToolError("order must be front, back, forward or backward") }
            let edits = try modify(target) { edits in
                var layers = edits.layers
                let moving = layers.filter { wanted.contains($0.id) }
                switch order {
                case "front": layers = layers.filter { !wanted.contains($0.id) } + moving
                case "back": layers = moving + layers.filter { !wanted.contains($0.id) }
                case "forward":
                    for i in stride(from: layers.count - 2, through: 0, by: -1) where wanted.contains(layers[i].id) && !wanted.contains(layers[i + 1].id) {
                        layers.swapAt(i, i + 1)
                    }
                default:
                    for i in layers.indices.dropFirst() where wanted.contains(layers[i].id) && !wanted.contains(layers[i - 1].id) {
                        layers.swapAt(i, i - 1)
                    }
                }
                edits.layers = layers
            }
            return [json(["objects": edits.layers.map(json)])]
        },

        MCPTool(name: "image_crop", title: "Crop an image",
                description: "Crops an image to a rectangle of the original, or removes the crop (rect null). The parts cropped away are kept, so the crop can be changed or removed later.",
                properties: with(["rect": ["type": ["array", "null"], "items": ["type": "number"],
                                           "description": "[x, y, width, height] in pixels of the original; null removes the crop."]]),
                required: ["rect"]) { args in
            let target = try target(args)
            let value = args.raw["rect"]
            let crop: CGRect? = value == nil || value is NSNull ? nil : try rect(value, "rect")
            let edits = try modify(target) { $0.crop = crop }
            return state(target, edits, withImage: true)
        },

        MCPTool(name: "image_revert", title: "Revert an image",
                description: "Removes the crop, every object, or both, going back to the original image. With the editor open, Undo there brings them back.",
                properties: with(["what": prop("string", "crop, objects, or all (default).")]),
                required: [], destructive: true) { args in
            let target = try target(args)
            let what = args.string("what") ?? "all"
            guard ["crop", "objects", "all"].contains(what) else { throw MCPToolError("what must be crop, objects or all") }
            let edits = try modify(target) { edits in
                if what != "objects" { edits.crop = nil }
                if what != "crop" { edits.layers = [] }
            }
            return state(target, edits, withImage: true)
        },

        MCPTool(name: "image_select", title: "Select objects in the image editor",
                description: "Selects objects in the open image editor, to show the user which ones are meant; an empty list selects none.",
                properties: with(["ids": ["type": "array", "items": ["type": "string"], "description": "The objects, by id."]]),
                required: ["ids"]) { args in
            let target = try target(args)
            guard let model = OpenImageEditors.model(for: target) else {
                throw MCPToolError("That image is not open in the image editor; organizer_show with edit_image opens it.")
            }
            let raw = args.raw["ids"] as? [String] ?? []
            let wanted = raw.isEmpty ? [] : try ids(args, in: model.edits)
            model.select(wanted)
            return [text(wanted.isEmpty ? "Nothing is selected." : "\(wanted.count) selected.")]
        },

        MCPTool(name: "image_undo", title: "Undo in the image editor",
                description: "Undoes (or with redo, redoes) the last change in the open image editor -- the user's or an agent's.",
                properties: with(["redo": prop("boolean", "Redo instead of undo.")]),
                required: []) { args in
            let target = try target(args)
            guard let model = OpenImageEditors.model(for: target) else {
                throw MCPToolError("Undo works in the open image editor; that image is not open in it.")
            }
            if args.bool("redo") == true {
                guard model.canRedo else { throw MCPToolError("There is nothing to redo.") }
                model.redo()
            } else {
                guard model.canUndo else { throw MCPToolError("There is nothing to undo.") }
                model.undo()
            }
            model.saveNow()
            return state(target, model.edits, withImage: true)
        },

        // MARK: History

        MCPTool(name: "history_undo_delete", title: "Bring back deleted entries",
                description: "Brings back the entries deleted last (by the user or with history_delete or history_clear), if that was less than five minutes ago.",
                properties: [:], required: []) { _ in
            let back = ClipboardHistory.shared.undoDelete()
            guard !back.isEmpty else { throw MCPToolError("Nothing deleted in the last five minutes can be brought back.") }
            return [json(["restored": back.map(MCPTools.summary)])]
        },

        MCPTool(name: "history_rename", title: "Name a history entry",
                description: "Gives a history entry a name, shown instead of its first line and found by search; an empty name removes it.",
                properties: ["id": prop("string", "The entry's id."), "name": prop("string", "The name; \"\" removes it.")],
                required: ["id", "name"]) { args in
            let id = try args.id()
            guard ClipboardHistory.shared.item(id) != nil else { throw MCPToolError("No history entry has that id.") }
            ClipboardHistory.shared.rename(id, to: try args.requiredString("name"))
            return [json(MCPTools.summary(ClipboardHistory.shared.item(id)!))]
        },

        MCPTool(name: "history_copy_joined", title: "Copy several entries as one",
                description: "Puts the texts of several history entries on the clipboard as one, in the order given, separated by a line break (or `separator`); formatted text stays formatted. Entries without text are left out. Entries of two lists with Paste Guard rules, or a password with anything else, are not joined.",
                properties: ["ids": ["type": "array", "items": ["type": "string"], "description": "The entries, in order."],
                             "separator": prop("string", "Put between the texts; default a line break.")],
                required: ["ids"]) { args in
            let ids = (args.raw["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            guard ids.count >= 1 else { throw MCPToolError("'ids' must list entries") }
            let made = try ClipboardHistory.shared.copyJoined(ids, separator: args.string("separator") ?? "\n")
            return [text("On the clipboard."), json(made.map(MCPTools.summary) ?? [:])]
        },
    ]
}
