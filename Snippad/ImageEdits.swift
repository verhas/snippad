import AppKit
import CoreImage
import ImageIO

/// A colour as it is saved: sRGB components, 0...1.
struct RGBA: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let red = RGBA(r: 0.92, g: 0.16, b: 0.12)
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// White or black, whichever reads better on this colour.
    var contrasting: RGBA {
        0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 ? .black : .white
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

/// The outline of a shape or of a selected area.
enum ImageShape: String, Codable, CaseIterable, Sendable {
    case rectangle, oval, circle, triangle
    /// Clicked corner by corner; the outline goes back to the first.
    case polygon
    /// Drawn with the mouse; closed.
    case freehand

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .circle: "circle"
        case .triangle: "triangle"
        case .polygon: "pentagon"
        case .freehand: "scribble"
        }
    }

    /// Made of the points the user put down, not of a box.
    var usesPoints: Bool { self == .polygon || self == .freehand }
}

/// How a line runs between its ends.
enum LineForm: String, Codable, CaseIterable, Sendable {
    case straight
    /// Clicked point by point.
    case polyline
    /// Drawn with the mouse.
    case freehand

    var title: String {
        switch self {
        case .straight: "Straight"
        case .polyline: "Polyline"
        case .freehand: "Freehand"
        }
    }

    var symbol: String {
        switch self {
        case .straight: "line.diagonal"
        case .polyline: "point.3.connected.trianglepath.dotted"
        case .freehand: "scribble"
        }
    }
}

/// What is at an end of a line. A line with none at either end is a plain
/// line; with one, an arrow.
enum ArrowHead: String, Codable, CaseIterable, Sendable {
    case none
    case solid, hollow, open
    case solidCircle, hollowCircle
    case bar
    case solidSquare, hollowSquare
    case solidDiamond, hollowDiamond

    var title: String {
        switch self {
        case .none: "None"
        case .solid: "Arrow"
        case .hollow: "Hollow Arrow"
        case .open: "Open Arrow"
        case .solidCircle: "Dot"
        case .hollowCircle: "Circle"
        case .bar: "Bar"
        case .solidSquare: "Square"
        case .hollowSquare: "Hollow Square"
        case .solidDiamond: "Diamond"
        case .hollowDiamond: "Hollow Diamond"
        }
    }

    var isFilled: Bool { self == .solid || self == .solidCircle || self == .solidSquare || self == .solidDiamond }
}

/// The shape of a numbered marker.
enum MarkerShape: String, Codable, CaseIterable, Sendable {
    case circle, roundedSquare, square, diamond, hexagon, pin, cloud, bubble

    var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Rounded Square"
        case .square: "Square"
        case .diamond: "Diamond"
        case .hexagon: "Hexagon"
        case .pin: "Map Pin"
        case .cloud: "Cloud"
        case .bubble: "Speech Bubble"
        }
    }

    var symbol: String {
        switch self {
        case .circle: "circle.fill"
        case .roundedSquare: "app.fill"
        case .square: "square.fill"
        case .diamond: "diamond.fill"
        case .hexagon: "hexagon.fill"
        case .pin: "mappin"
        case .cloud: "cloud.fill"
        case .bubble: "bubble.left.fill"
        }
    }

    /// Height over width of a new marker.
    var aspect: Double {
        switch self {
        case .pin: 1.35
        case .bubble: 1.15
        case .cloud: 0.75
        default: 1
        }
    }
}

/// What is done to a selected area.
enum ImageEffect: String, Codable, CaseIterable, Sendable {
    /// Made transparent.
    case erase
    // Hiding what is there.
    case mosaic, hexagons, crystallize, pointillize, blur
    // Bending it.
    case swirl, vortex, bulge, pinch, hole, kaleidoscope, tunnel
    // Its colours.
    case invert, monochrome, sepia, posterize, comic, edges, thermal, xray

    enum Group: String, CaseIterable {
        case hide = "Hide"
        case distort = "Distort"
        case color = "Colors"
    }

    var group: Group? {
        switch self {
        case .erase: nil
        case .mosaic, .hexagons, .crystallize, .pointillize, .blur: .hide
        case .swirl, .vortex, .bulge, .pinch, .hole, .kaleidoscope, .tunnel: .distort
        case .invert, .monochrome, .sepia, .posterize, .comic, .edges, .thermal, .xray: .color
        }
    }

    static func inGroup(_ group: Group) -> [ImageEffect] { allCases.filter { $0.group == group } }

    var title: String {
        switch self {
        case .erase: "Delete"
        case .mosaic: "Mosaic"
        case .hexagons: "Hexagon Mosaic"
        case .crystallize: "Crystallize"
        case .pointillize: "Pointillize"
        case .blur: "Blur"
        case .swirl: "Swirl"
        case .vortex: "Vortex"
        case .bulge: "Bulge"
        case .pinch: "Pinch"
        case .hole: "Hole"
        case .kaleidoscope: "Kaleidoscope"
        case .tunnel: "Light Tunnel"
        case .invert: "Invert Colors"
        case .monochrome: "Black & White"
        case .sepia: "Sepia"
        case .posterize: "Posterize"
        case .comic: "Comic"
        case .edges: "Edges"
        case .thermal: "Thermal"
        case .xray: "X-Ray"
        }
    }

    /// Has a size in pixels: of blocks, crystals, dots, the blur.
    var usesSize: Bool { group == .hide }
    /// Has a strength.
    var usesStrength: Bool { group == .distort || self == .posterize || self == .edges }

    var defaultSize: Double {
        switch self {
        case .mosaic: 4
        case .hexagons, .pointillize, .blur: 6
        case .crystallize: 8
        default: 4
        }
    }
}

enum LineStyle: String, Codable, CaseIterable, Sendable {
    case solid
    /// Short dashes.
    case dashed
    case longDashed
    case dotted
    case dashDotted

    var title: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Short Dashes"
        case .longDashed: "Long Dashes"
        case .dotted: "Dotted"
        case .dashDotted: "Dash-Dot"
        }
    }
}

/// One thing added to an image: a shape, a line or arrow, a text, a pasted
/// image, a numbered marker, or an effect on an area. Layers stay objects:
/// they can be moved, resized, restyled and removed at any time, because the
/// image is always drawn anew from the original and the layers.
///
/// Positions are in pixels of the original image, the origin at the top
/// left, y going down.
struct ImageLayer: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case shape, line, text, image, effect, marker
        /// Only in edits saved before lines had heads at either end: read
        /// as a line with an arrow head at its end.
        case arrow
    }

    var id = UUID()
    var kind: Kind
    /// For lines, the two ends; for the rest, two opposite corners. With
    /// `points`, the first and last point of a line, or the box around a
    /// shape's points.
    var start: CGPoint
    var end: CGPoint
    /// The points of a polyline or freehand line, and of a polygon or
    /// freehand shape or area. Kept, unused, while the line is straight or
    /// the shape a rectangle, oval, circle or triangle, so that switching
    /// back brings them back.
    var points: [CGPoint]?
    /// Degrees clockwise, around the middle of `rect`. Positions are those
    /// before the turn.
    var rotation: Double = 0
    /// Lines: how they run, and what is at their ends.
    var form: LineForm = .straight
    var startHead: ArrowHead = .none
    var endHead: ArrowHead = .none
    /// Shapes and effect areas.
    var shape: ImageShape = .rectangle
    var effect: ImageEffect?
    /// Lines, outlines, text, and the body of a marker.
    var stroke: RGBA = .red
    /// Filled shapes; the background of a text.
    var fill: RGBA?
    var lineWidth: Double = 4
    var lineStyle: LineStyle = .solid
    var text: String?
    var fontSize: Double = 32
    /// A pasted image, as PNG.
    var image: Data?
    /// An effect's size in pixels: mosaic blocks, crystals, dots, blur.
    var effectSize: Double = 4
    /// A distortion's strength, 0...1.
    var strength: Double = 0.5
    /// A marker's number and shape.
    var number: Int?
    var marker: MarkerShape?

    init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint, shape: ImageShape = .rectangle) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.shape = shape
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, start, end, shape, effect, stroke, fill, lineWidth, lineStyle, text, fontSize, image
        case effectSize, strength, number, marker, points, form, startHead, endHead, rotation
    }

    /// Anything left out takes its default, so edits saved by an older
    /// Snippad still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageLayer(kind: .shape, start: .zero, end: .zero)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        start = try c.decode(CGPoint.self, forKey: .start)
        end = try c.decode(CGPoint.self, forKey: .end)
        shape = try c.decodeIfPresent(ImageShape.self, forKey: .shape) ?? d.shape
        effect = try c.decodeIfPresent(ImageEffect.self, forKey: .effect)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? d.stroke
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? d.lineWidth
        lineStyle = try c.decodeIfPresent(LineStyle.self, forKey: .lineStyle) ?? d.lineStyle
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        image = try c.decodeIfPresent(Data.self, forKey: .image)
        effectSize = try c.decodeIfPresent(Double.self, forKey: .effectSize) ?? d.effectSize
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        marker = try c.decodeIfPresent(MarkerShape.self, forKey: .marker)
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points)
        form = try c.decodeIfPresent(LineForm.self, forKey: .form) ?? d.form
        startHead = try c.decodeIfPresent(ArrowHead.self, forKey: .startHead) ?? d.startHead
        endHead = try c.decodeIfPresent(ArrowHead.self, forKey: .endHead) ?? d.endHead
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? d.rotation
        if kind == .arrow {
            kind = .line
            if !c.contains(.endHead) { endHead = .solid }
        }
    }

    /// The points in use: those of a line that is not straight, of a
    /// polygon or freehand shape; nil for the rest.
    var activePoints: [CGPoint]? {
        guard let points, !points.isEmpty else { return nil }
        switch kind {
        case .line, .arrow: return form == .straight ? nil : points
        case .shape, .effect: return shape.usesPoints ? points : nil
        default: return nil
        }
    }

    /// The box, before the rotation.
    var rect: CGRect {
        if let points = activePoints { return Self.bounds(points) }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    var isLine: Bool { kind == .line || kind == .arrow }

    /// A line's points, end to end.
    var linePoints: [CGPoint] { activePoints ?? [start, end] }

    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// From the layer's own positions to the image's: the rotation.
    var transform: CGAffineTransform {
        guard rotation != 0 else { return .identity }
        let c = center
        return CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: rotation * .pi / 180)
            .translatedBy(x: -c.x, y: -c.y)
    }

    func toWorld(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.applying(transform) }
    func toLocal(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.applying(transform.inverted()) }

    /// The corners of the box, turned, clockwise from the top left.
    var worldCorners: [CGPoint] {
        let r = rect
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(toWorld)
    }

    /// The box around the layer as it is drawn, turned.
    var worldBounds: CGRect {
        rotation == 0 ? rect : Self.bounds(isLine ? linePoints.map(toWorld) : worldCorners)
    }

    /// Lines and shapes (and effect areas) can be edited point by point.
    var canEditPoints: Bool { isLine || kind == .shape || kind == .effect }

    /// The points edited one by one: a line's points; a shape's corners,
    /// or for an oval the points a freehand curve round it goes by.
    var editablePoints: [CGPoint] {
        if isLine { return linePoints }
        if let points = activePoints { return points }
        switch shape {
        case .oval, .circle: return ImageCompositor.controlPoints(around: rect)
        default: return ImageCompositor.outlinePoints(shape, in: rect)
        }
    }

    /// Before a point of a rectangle, triangle or oval is moved: it becomes
    /// a polygon (an oval a freehand shape) with the same outline.
    mutating func makePointsEditable() {
        guard !isLine, activePoints == nil else { return }
        let points = editablePoints
        shape = shape == .oval || shape == .circle ? .freehand : .polygon
        setPoints(points)
    }

    /// Moves one of `editablePoints` to `p`, given in the layer's own
    /// positions.
    mutating func setPoint(_ index: Int, to p: CGPoint) {
        if !isLine { makePointsEditable() }
        if var points = activePoints {
            guard points.indices.contains(index) else { return }
            points[index] = p
            setPoints(points)
        } else if index == 0 {
            start = p
        } else {
            end = p
        }
    }

    /// After the box changed: moves the layer so that whatever did not
    /// change stays where it is on the image, although the middle the
    /// rotation turns around has moved.
    mutating func reanchor(from oldCenter: CGPoint) {
        guard rotation != 0 else { return }
        let c = center
        let d = CGPoint(x: c.x - oldCenter.x, y: c.y - oldCenter.y)
        let a = rotation * .pi / 180
        let turned = CGPoint(x: d.x * cos(a) - d.y * sin(a), y: d.x * sin(a) + d.y * cos(a))
        move(by: turned.x - d.x, turned.y - d.y)
    }

    /// Kept points are used again (a line no longer straight, a rectangle
    /// made a polygon again): they are fitted to where the line's ends or
    /// the shape's box are now.
    mutating func fitKeptPoints() {
        guard let points, !points.isEmpty else { return }
        if isLine {
            guard let a = points.first, let b = points.last else { return }
            let from = CGPoint(x: b.x - a.x, y: b.y - a.y), to = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = hypot(from.x, from.y)
            guard length > 0.001 else {
                self.points = points.map { CGPoint(x: $0.x - a.x + start.x, y: $0.y - a.y + start.y) }
                return
            }
            let k = hypot(to.x, to.y) / length
            let phi = atan2(to.y, to.x) - atan2(from.y, from.x)
            self.points = points.map { p in
                let x = (p.x - a.x) * k, y = (p.y - a.y) * k
                return CGPoint(x: start.x + x * cos(phi) - y * sin(phi), y: start.y + x * sin(phi) + y * cos(phi))
            }
        } else {
            let old = Self.bounds(points)
            let new = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            self.points = points.map { p in
                CGPoint(x: new.minX + (old.width > 0 ? (p.x - old.minX) / old.width * new.width : 0),
                        y: new.minY + (old.height > 0 ? (p.y - old.minY) / old.height * new.height : 0))
            }
        }
    }

    /// Sets the points, and the ends or the box with them.
    mutating func setPoints(_ new: [CGPoint]) {
        points = new
        guard let first = new.first, let last = new.last else { return }
        if isLine {
            start = first
            end = last
        } else {
            let r = Self.bounds(new)
            start = r.origin
            end = CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    /// Stretches the layer from one box to another.
    mutating func scale(from old: CGRect, to new: CGRect) {
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: new.minX + (old.width > 0 ? (p.x - old.minX) / old.width * new.width : 0),
                    y: new.minY + (old.height > 0 ? (p.y - old.minY) / old.height * new.height : 0))
        }
        if let points = activePoints {
            setPoints(points.map(map))
        } else {
            start = map(start)
            end = map(end)
        }
    }

    /// Resizing keeps the proportions.
    var keepsProportions: Bool { kind == .image || kind == .marker }

    var font: NSFont { .systemFont(ofSize: max(4, fontSize), weight: .semibold) }

    /// A text's box fits its text.
    mutating func fitText() {
        guard kind == .text else { return }
        let size = Self.textSize(text ?? "", font: font)
        let origin = rect.origin
        start = origin
        end = CGPoint(x: origin.x + size.width, y: origin.y + size.height)
    }

    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = font.pointSize * 0.25
        return CGSize(width: ceil(measured.width + 2 * pad), height: ceil(measured.height + pad))
    }

    mutating func move(by dx: Double, _ dy: Double) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points?.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

/// An edited image: the original, what was added to it, and the crop. The
/// result is drawn from these whenever needed, so every layer stays an
/// object and the crop can be undone or changed. Kept with a clipboard
/// entry, in exports, and in .snippad files (`edits`, as JSON).
struct ImageEdits: Codable, Equatable, Sendable {
    /// The image as it was before any edit, as PNG.
    var original: Data
    /// Drawn in this order; an effect works on what is below it.
    var layers: [ImageLayer] = []
    /// What is kept of the image, in its pixels; nil keeps all of it.
    var crop: CGRect?

    var isUnchanged: Bool { layers.isEmpty && crop == nil }

    /// As one line of JSON, for .snippad files and exports.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init(original: Data, layers: [ImageLayer] = [], crop: CGRect? = nil) {
        self.original = original
        self.layers = layers
        self.crop = crop
    }

    init(json: String) throws {
        self = try JSONDecoder().decode(ImageEdits.self, from: Data(json.utf8))
        guard ImageCompositor.cgImage(original) != nil else {
            throw ClipboardError("the original image in 'edits' cannot be read")
        }
    }
}

/// Draws edited images.
enum ImageCompositor {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The finished image, cropped, as PNG: what is pasted.
    static func png(_ edits: ImageEdits) -> Data? {
        render(edits).flatMap(png)
    }

    /// Draws the original and the layers; `scale` below 1 draws a smaller
    /// image, for the screen while editing. `cropped: false` keeps the parts
    /// outside the crop, which the editor shows dimmed.
    static func render(_ edits: ImageEdits, base: CGImage? = nil, scale: CGFloat = 1, cropped: Bool = true) -> CGImage? {
        guard let base = base ?? cgImage(edits.original) else { return nil }
        let width = max(1, Int((CGFloat(base.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(base.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sx = CGFloat(width) / CGFloat(base.width)
        let sy = CGFloat(height) / CGFloat(base.height)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From here on the image's own pixels, y down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: sx, y: -sy)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for layer in edits.layers {
            draw(layer, in: ctx, scale: CGSize(width: sx, height: sy))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        guard cropped, let crop = edits.crop else { return image }
        let device = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !device.isEmpty else { return image }
        return image.cropping(to: device) ?? image
    }

    /// The outline of a shape in a rectangle, y down. A polygon or a
    /// freehand shape goes through its points; without them it is the
    /// rectangle.
    static func path(_ shape: ImageShape, in rect: CGRect, points: [CGPoint]? = nil) -> NSBezierPath {
        switch shape {
        case .rectangle:
            return NSBezierPath(rect: rect)
        case .oval, .circle:
            return NSBezierPath(ovalIn: rect)
        case .triangle:
            return polygon(outlinePoints(.triangle, in: rect))
        case .polygon, .freehand:
            guard let points, points.count >= 2 else { return NSBezierPath(rect: rect) }
            return shape == .freehand ? smoothed(points, closed: true) : polygon(points)
        }
    }

    /// The outline of a layer that is a shape or an effect's area.
    static func path(of layer: ImageLayer) -> NSBezierPath {
        path(layer.shape, in: layer.rect, points: layer.activePoints)
    }

    /// Eight points round an oval such that the smooth curve through them
    /// (as a freehand shape is drawn) touches the oval at eight places and
    /// stays close to it in between.
    static func controlPoints(around rect: CGRect) -> [CGPoint] {
        let n = 8.0
        let out = 1 / cos(.pi / n)
        return (0..<8).map { k in
            let a = (Double(k) + 0.5) / n * 2 * .pi
            return CGPoint(x: rect.midX + rect.width / 2 * out * cos(a), y: rect.midY + rect.height / 2 * out * sin(a))
        }
    }

    /// Objects copied from the editor as a picture of their own, on a
    /// transparent background: what pastes in other applications.
    static func png(of layers: [ImageLayer]) -> Data? {
        guard !layers.isEmpty else { return nil }
        var box = layers.map(\.worldBounds).reduce(CGRect.null) { $0.union($1) }
        let pad = (layers.map { $0.lineWidth * 4 }.max() ?? 0) + 4
        box = box.insetBy(dx: -pad, dy: -pad).integral
        let width = Int(min(max(box.width, 1), 8000)), height = Int(min(max(box.height, 1), 8000))
        guard let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])
        else { return nil }
        let moved = layers.map { layer -> ImageLayer in
            var l = layer
            l.move(by: -box.minX, -box.minY)
            return l
        }
        return png(ImageEdits(original: blank, layers: moved))
    }

    /// Corners along a shape's outline, to turn it into a polygon.
    static func outlinePoints(_ shape: ImageShape, in rect: CGRect) -> [CGPoint] {
        switch shape {
        case .triangle:
            return [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .oval, .circle:
            return (0..<16).map { k in
                let a = Double(k) / 16 * 2 * .pi
                return CGPoint(x: rect.midX + rect.width / 2 * cos(a), y: rect.midY + rect.height / 2 * sin(a))
            }
        default:
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
    }

    /// A smooth curve through the middles of the segments between the
    /// points, as a freehand line is drawn.
    static func smoothed(_ points: [CGPoint], closed: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        guard points.count > 2 else {
            return closed ? polygon(points) : open(points)
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func quad(to target: CGPoint, control c: CGPoint) {
            let from = p.currentPoint
            p.curve(to: target,
                    controlPoint1: CGPoint(x: from.x + 2 / 3 * (c.x - from.x), y: from.y + 2 / 3 * (c.y - from.y)),
                    controlPoint2: CGPoint(x: target.x + 2 / 3 * (c.x - target.x), y: target.y + 2 / 3 * (c.y - target.y)))
        }
        let n = points.count
        if closed {
            p.move(to: mid(points[n - 1], points[0]))
            for i in 0..<n { quad(to: mid(points[i], points[(i + 1) % n]), control: points[i]) }
            p.close()
        } else {
            p.move(to: points[0])
            for i in 1..<(n - 1) { quad(to: mid(points[i], points[i + 1]), control: points[i]) }
            p.line(to: points[n - 1])
        }
        return p
    }

    private static func open(_ points: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.line(to: $0) }
        return p
    }

    private static func polygon(_ points: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.line(to: $0) }
        p.close()
        return p
    }

    /// A marker's parts (filled one after the other, so overlapping parts do
    /// not cancel out), and where its number goes and how big it may be.
    static func markerParts(_ shape: MarkerShape, in r: CGRect) -> (parts: [NSBezierPath], center: CGPoint, room: CGFloat) {
        let w = r.width, h = r.height
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        switch shape {
        case .circle:
            return ([NSBezierPath(ovalIn: r)], CGPoint(x: r.midX, y: r.midY), min(w, h))
        case .roundedSquare:
            let radius = min(w, h) * 0.22
            return ([NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)], CGPoint(x: r.midX, y: r.midY), min(w, h))
        case .square:
            return ([NSBezierPath(rect: r)], CGPoint(x: r.midX, y: r.midY), min(w, h))
        case .diamond:
            return ([polygon([at(0.5, 0), at(1, 0.5), at(0.5, 1), at(0, 0.5)])], CGPoint(x: r.midX, y: r.midY), min(w, h) * 0.7)
        case .hexagon:
            let points = (0..<6).map { k -> CGPoint in
                let a = (-90 + 60 * Double(k)) * .pi / 180
                return CGPoint(x: r.midX + w / 2 * cos(a), y: r.midY + h / 2 * sin(a))
            }
            return ([polygon(points)], CGPoint(x: r.midX, y: r.midY), min(w, h) * 0.85)
        case .pin:
            // A round head with a point below, like a map's pin.
            let radius = min(w / 2, h / 2.7)
            let center = CGPoint(x: r.midX, y: r.minY + radius)
            let tip = CGPoint(x: r.midX, y: r.maxY)
            let d = max(tip.y - center.y, radius + 0.001)
            let a = acos(radius / d)
            // The head's outline from the right tangent point over the top
            // to the left one.
            var points = [tip]
            let steps = 48
            for i in 0...steps {
                // Angles measured from straight down, going round anticlockwise.
                let angle = a + (2 * .pi - 2 * a) * Double(i) / Double(steps)
                points.append(CGPoint(x: center.x + radius * sin(angle), y: center.y + radius * cos(angle)))
            }
            return ([polygon(points)], center, radius * 2)
        case .cloud:
            let puffs: [(CGFloat, CGFloat, CGFloat)] = [(0.27, 0.62, 0.23), (0.47, 0.40, 0.30), (0.72, 0.52, 0.25),
                                                        (0.55, 0.70, 0.22), (0.36, 0.73, 0.2)]
            let parts = puffs.map { x, y, radius in
                NSBezierPath(ovalIn: CGRect(x: r.minX + (x - radius) * w, y: r.minY + (y - radius * w / max(h, 1)) * h,
                                            width: 2 * radius * w, height: 2 * radius * w))
            }
            return (parts, at(0.5, 0.58), min(w * 0.5, h * 0.7))
        case .bubble:
            let body = CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.8)
            let radius = min(w, body.height) * 0.25
            let tail = polygon([at(0.22, 0.7), at(0.48, 0.7), at(0.16, 1)])
            return ([NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius), tail],
                    CGPoint(x: body.midX, y: body.midY), min(w, body.height))
        }
    }

    /// A marker as a picture, for the editor's drag source.
    static func markerImage(_ shape: MarkerShape, number: Int, color: RGBA, height: CGFloat) -> NSImage {
        let size = CGSize(width: height / shape.aspect, height: height)
        return NSImage(size: size, flipped: true) { rect in
            var layer = ImageLayer(kind: .marker, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY))
            layer.marker = shape
            layer.number = number
            layer.stroke = color
            drawMarker(layer)
            return true
        }
    }

    /// An arrow's head: its length along the line.
    static func headLength(_ layer: ImageLayer) -> CGFloat {
        max(CGFloat(layer.lineWidth) * 4, 12)
    }

    /// A head on a short line, for the editor's menus.
    static func headImage(_ head: ArrowHead, atStart: Bool) -> NSImage {
        NSImage(size: CGSize(width: 34, height: 14), flipped: true) { _ in
            var layer = ImageLayer(kind: .line, start: CGPoint(x: 3, y: 7), end: CGPoint(x: 31, y: 7))
            layer.lineWidth = 2
            layer.stroke = RGBA(NSColor.labelColor)
            if atStart { layer.startHead = head } else { layer.endHead = head }
            drawLine(layer)
            return true
        }
    }

    private static func styled(_ path: NSBezierPath, _ layer: ImageLayer) {
        let w = CGFloat(layer.lineWidth)
        path.lineWidth = w
        path.lineJoinStyle = .round
        switch layer.lineStyle {
        case .solid:
            path.lineCapStyle = .round
        case .dashed:
            path.lineCapStyle = .butt
            path.setLineDash([w * 2, w * 1.5], count: 2, phase: 0)
        case .longDashed:
            path.lineCapStyle = .butt
            path.setLineDash([w * 6, w * 2.5], count: 2, phase: 0)
        case .dotted:
            // Round caps on dashes of no length are dots.
            path.lineCapStyle = .round
            path.setLineDash([0, w * 2], count: 2, phase: 0)
        case .dashDotted:
            path.lineCapStyle = .round
            path.setLineDash([w * 4, w * 2.2, 0, w * 2.2], count: 4, phase: 0)
        }
    }

    private static func drawMarker(_ layer: ImageLayer) {
        let (parts, center, room) = markerParts(layer.marker ?? .circle, in: layer.rect)
        layer.stroke.nsColor.setFill()
        parts.forEach { $0.fill() }
        let text = String(layer.number ?? 1)
        let digits = CGFloat(max(1, text.count))
        let size = room * (digits == 1 ? 0.58 : digits == 2 ? 0.48 : 0.38)
        var font = NSFont.systemFont(ofSize: max(4, size), weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: rounded, size: font.pointSize) ?? font }
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: layer.stroke.contrasting.nsColor])
        let bounds = string.size()
        string.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
    }

    // MARK: Lines and their heads

    private static func length(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Which way a line leaves its last point, as a unit vector: from the
    /// last point at least `reach` away, so that a freehand line's last
    /// wobble does not turn its head.
    private static func direction(_ points: [CGPoint], reach: CGFloat) -> CGPoint? {
        guard let tip = points.last else { return nil }
        var from: CGPoint?
        for p in points.dropLast().reversed() {
            let d = hypot(tip.x - p.x, tip.y - p.y)
            guard d > 0.001 else { continue }
            from = p
            if d >= reach { break }
        }
        guard let from else { return nil }
        let d = hypot(tip.x - from.x, tip.y - from.y)
        return CGPoint(x: (tip.x - from.x) / d, y: (tip.y - from.y) / d)
    }

    /// The line without its last `distance`, so it stops inside its head.
    private static func trimmedEnd(_ points: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        guard distance > 0 else { return points }
        var points = points
        var left = distance
        while points.count >= 2 {
            let a = points[points.count - 2], b = points[points.count - 1]
            let d = hypot(b.x - a.x, b.y - a.y)
            if d > left {
                points[points.count - 1] = CGPoint(x: b.x - (b.x - a.x) / d * left, y: b.y - (b.y - a.y) / d * left)
                return points
            }
            left -= d
            points.removeLast()
        }
        return points
    }

    /// A head with its point at `tip`, the line arriving along `u`; and how
    /// much of the line it hides.
    private static func head(_ head: ArrowHead, tip: CGPoint, u: CGPoint, length l: CGFloat) -> (path: NSBezierPath, trim: CGFloat) {
        let n = CGPoint(x: -u.y, y: u.x)
        func at(_ back: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - u.x * back + n.x * side, y: tip.y - u.y * back + n.y * side)
        }
        switch head {
        case .none:
            return (NSBezierPath(), 0)
        case .solid, .hollow:
            return (polygon([tip, at(l, l / 2), at(l, -l / 2)]), head == .solid ? l * 0.6 : l)
        case .open:
            return (open([at(l, l / 2), tip, at(l, -l / 2)]), 0)
        case .solidCircle, .hollowCircle:
            let d = l * 0.75
            let c = at(d / 2, 0)
            return (NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), head == .solidCircle ? d / 2 : d)
        case .bar:
            return (open([at(0, l / 2), at(0, -l / 2)]), 0)
        case .solidSquare, .hollowSquare:
            let side = l * 0.65
            return (polygon([at(0, side / 2), at(side, side / 2), at(side, -side / 2), at(0, -side / 2)]),
                    head == .solidSquare ? side / 2 : side)
        case .solidDiamond, .hollowDiamond:
            return (polygon([tip, at(l / 2, l * 0.3), at(l, 0), at(l / 2, -l * 0.3)]), head == .solidDiamond ? l / 2 : l)
        }
    }

    /// A line or arrow: straight, through its points or freehand, with
    /// whatever heads it has.
    static func drawLine(_ layer: ImageLayer) {
        var points = layer.linePoints
        guard points.count >= 2 else { return }
        let total = length(points)
        guard total > 0.001 else { return }
        let w = CGFloat(layer.lineWidth)
        let ends = (layer.startHead != .none ? 1 : 0) + (layer.endHead != .none ? 1 : 0)
        let l = min(headLength(layer), ends > 0 ? total / CGFloat(ends) : total)
        let reach = layer.form == .freehand ? l : 0
        var heads: [(ArrowHead, NSBezierPath)] = []
        if layer.endHead != .none, let u = direction(points, reach: reach) {
            let (path, trim) = head(layer.endHead, tip: points[points.count - 1], u: u, length: l)
            heads.append((layer.endHead, path))
            points = trimmedEnd(points, by: min(trim, total * 0.9))
        }
        if layer.startHead != .none, let u = direction(Array(points.reversed()), reach: reach) {
            let (path, trim) = head(layer.startHead, tip: points[0], u: u, length: l)
            heads.append((layer.startHead, path))
            points = Array(trimmedEnd(Array(points.reversed()), by: min(trim, total * 0.9)).reversed())
        }
        if points.count >= 2 {
            let path = layer.form == .freehand ? smoothed(points, closed: false) : open(points)
            styled(path, layer)
            layer.stroke.nsColor.setStroke()
            path.stroke()
        }
        layer.stroke.nsColor.setFill()
        layer.stroke.nsColor.setStroke()
        for (kind, path) in heads {
            if kind.isFilled {
                path.fill()
            } else {
                path.lineWidth = max(1, w)
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.stroke()
            }
        }
    }

    private static func draw(_ layer: ImageLayer, in ctx: CGContext, scale: CGSize) {
        guard layer.rotation != 0, layer.kind != .effect else { return drawUnturned(layer, in: ctx, scale: scale) }
        NSGraphicsContext.saveGraphicsState()
        ctx.concatenate(layer.transform)
        drawUnturned(layer, in: ctx, scale: scale)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws a layer in its own positions; `draw` turns it first. An effect
    /// turns only its outline: the area it works on is on the image.
    private static func drawUnturned(_ layer: ImageLayer, in ctx: CGContext, scale: CGSize) {
        let rect = layer.kind == .effect ? layer.worldBounds : layer.rect
        switch layer.kind {
        case .shape:
            let path = path(of: layer)
            if let fill = layer.fill {
                fill.nsColor.setFill()
                path.fill()
            }
            styled(path, layer)
            layer.stroke.nsColor.setStroke()
            path.stroke()
        case .line, .arrow:
            drawLine(layer)
        case .text:
            if let fill = layer.fill {
                fill.nsColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: layer.fontSize * 0.15, yRadius: layer.fontSize * 0.15).fill()
            }
            let pad = layer.font.pointSize * 0.25
            NSAttributedString(string: layer.text ?? "", attributes: [.font: layer.font, .foregroundColor: layer.stroke.nsColor])
                .draw(with: rect.insetBy(dx: pad, dy: pad * 0.5), options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .image:
            guard let data = layer.image, let image = NSImage(data: data) else { return }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .marker:
            drawMarker(layer)
        case .effect:
            guard let effect = layer.effect, rect.width >= 1, rect.height >= 1 else { return }
            NSGraphicsContext.saveGraphicsState()
            let outline = path(of: layer)
            if layer.rotation != 0 {
                outline.transform(using: AffineTransform(m11: layer.transform.a, m12: layer.transform.b,
                                                         m21: layer.transform.c, m22: layer.transform.d,
                                                         tX: layer.transform.tx, tY: layer.transform.ty))
            }
            outline.addClip()
            if effect == .erase {
                ctx.setBlendMode(.clear)
                ctx.fill(rect)
            } else if let below = ctx.makeImage(), let changed = filtered(below, effect, layer: layer, rect: rect, scale: scale) {
                ctx.setBlendMode(.copy)
                NSImage(cgImage: changed, size: rect.size)
                    .draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The area of what is drawn so far, changed by an effect.
    private static func filtered(_ below: CGImage, _ effect: ImageEffect, layer: ImageLayer, rect: CGRect, scale: CGSize) -> CGImage? {
        let height = CGFloat(below.height)
        // Core Image counts y upwards.
        let area = CGRect(x: rect.minX * scale.width, y: height - rect.maxY * scale.height,
                          width: rect.width * scale.width, height: rect.height * scale.height).integral
        let input = CIImage(cgImage: below).clampedToExtent()
        let center = CIVector(x: area.midX, y: area.midY)
        let radius = max(area.width, area.height) / 2
        let size = max(1, layer.effectSize * scale.width)
        let strength = min(max(layer.strength, 0), 1)
        let output: CIImage
        switch effect {
        case .erase:
            return nil
        case .mosaic:
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, size),
                                                                      kCIInputCenterKey: CIVector(x: area.minX, y: area.minY)])
        case .hexagons:
            output = input.applyingFilter("CIHexagonalPixellate", parameters: [kCIInputScaleKey: max(2, size), kCIInputCenterKey: center])
        case .crystallize:
            output = input.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(1, size), kCIInputCenterKey: center])
        case .pointillize:
            output = input.applyingFilter("CIPointillize", parameters: [kCIInputRadiusKey: max(1, size), kCIInputCenterKey: center])
        case .blur:
            output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size])
        case .swirl:
            output = input.applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: radius,
                                                                            kCIInputAngleKey: strength * 4 * .pi])
        case .vortex:
            output = input.applyingFilter("CIVortexDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: radius,
                                                                             kCIInputAngleKey: strength * 150])
        case .bulge:
            output = input.applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: radius,
                                                                           kCIInputScaleKey: strength])
        case .pinch:
            output = input.applyingFilter("CIPinchDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: radius,
                                                                            kCIInputScaleKey: strength * 2])
        case .hole:
            output = input.applyingFilter("CIHoleDistortion", parameters: [kCIInputCenterKey: center,
                                                                           kCIInputRadiusKey: max(0.1, radius * strength * 0.6)])
        case .kaleidoscope:
            output = input.applyingFilter("CIKaleidoscope", parameters: [kCIInputCenterKey: center, "inputCount": Int(3 + strength * 9),
                                                                         kCIInputAngleKey: 0])
        case .tunnel:
            output = input.applyingFilter("CILightTunnel", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: radius * 0.25,
                                                                        "inputRotation": strength * 10])
        case .invert:
            output = input.applyingFilter("CIColorInvert")
        case .monochrome:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .sepia:
            output = input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1])
        case .posterize:
            output = input.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 2 + (1 - strength) * 10])
        case .comic:
            output = input.applyingFilter("CIComicEffect")
        case .edges:
            output = input.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1 + strength * 10])
        case .thermal:
            output = input.applyingFilter("CIThermal")
        case .xray:
            output = input.applyingFilter("CIXRay")
        }
        return ciContext.createCGImage(output, from: area)
    }
}
