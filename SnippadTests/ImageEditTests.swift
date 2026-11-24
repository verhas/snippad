import AppKit
import XCTest
@testable import Snippad

final class ImageEditTests: XCTestCase {

    /// A PNG of one colour.
    private func png(width: Int = 40, height: Int = 30, _ color: NSColor = .red) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The colour of a pixel, x from the left and y from the top.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
    }

    private func effect(_ effect: ImageEffect, _ rect: CGRect) -> ImageLayer {
        var layer = ImageLayer(kind: .effect, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY))
        layer.effect = effect
        return layer
    }

    func testCropKeepsThePartAndCanBeUndone() throws {
        var edits = ImageEdits(original: png())
        edits.crop = CGRect(x: 5, y: 5, width: 10, height: 8)
        let cropped = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertEqual(cropped.width, 10)
        XCTAssertEqual(cropped.height, 8)
        edits.crop = nil
        let whole = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertEqual(whole.width, 40, "the original is kept, so the crop can be removed")
    }

    func testEffectsWorkOnlyInsideTheirArea() throws {
        var edits = ImageEdits(original: png(.red))
        edits.layers = [effect(.erase, CGRect(x: 0, y: 0, width: 10, height: 10)),
                        effect(.invert, CGRect(x: 20, y: 0, width: 10, height: 10)),
                        effect(.monochrome, CGRect(x: 0, y: 20, width: 10, height: 10))]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertEqual(pixel(image, 5, 5).a, 0, "deleted: transparent")
        let inverted = pixel(image, 25, 5)
        XCTAssertLessThan(inverted.r, 60)
        XCTAssertGreaterThan(inverted.g, 180)
        let grey = pixel(image, 5, 25)
        XCTAssertLessThan(abs(grey.r - grey.g), 12, "black and white: no colour left")
        let untouched = pixel(image, 35, 25)
        XCTAssertGreaterThan(untouched.r, 200)
        XCTAssertLessThan(untouched.g, 60)
    }

    func testShapesAreDrawnWhereTheyAreMeasuredFromTheTop() throws {
        var edits = ImageEdits(original: png(.white))
        var box = ImageLayer(kind: .shape, start: CGPoint(x: 2, y: 2), end: CGPoint(x: 12, y: 8))
        box.fill = RGBA(r: 0, g: 0, b: 1)
        box.stroke = RGBA(r: 0, g: 0, b: 1)
        edits.layers = [box]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        let inside = pixel(image, 7, 5)
        XCTAssertGreaterThan(inside.b, 200)
        XCTAssertLessThan(inside.r, 60)
        let below = pixel(image, 7, 25)
        XCTAssertGreaterThan(below.r, 200, "y goes down: the bottom of the image is untouched")
    }

    func testEditsRoundTripAsJSONAndInASnippadFile() throws {
        var edits = ImageEdits(original: png())
        var text = ImageLayer(kind: .text, start: CGPoint(x: 1, y: 2), end: CGPoint(x: 3, y: 4))
        text.text = "Hello \"quoted\"\nsecond line"
        var arrow = ImageLayer(kind: .line, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 20, y: 20))
        arrow.lineStyle = .dashed
        arrow.startHead = .hollowCircle
        arrow.endHead = .solid
        edits.layers = [text, arrow, effect(.mosaic, CGRect(x: 0, y: 0, width: 9, height: 9))]
        edits.crop = CGRect(x: 1, y: 1, width: 30, height: 20)
        XCTAssertEqual(try ImageEdits(json: edits.json), edits)

        let result = try XCTUnwrap(ImageCompositor.png(edits))
        var snippet = Snippet(id: 0, name: "picture", value: result.base64EncodedString(), kind: .image)
        snippet.edits = edits
        let file = SnippadWriter.text(for: [snippet])
        XCTAssertTrue(file.contains("edits = "))
        XCTAssertEqual(try SnippadParser.parse(file), [snippet])
    }

    func testEditsOnlyBelongToImages() {
        XCTAssertThrowsError(try SnippadParser.parse("""
            [[snippet]]
            name = "a"
            value = "b"
            edits = "{}"
            """))
    }

    @MainActor
    func testAnEditedHistoryImageKeepsItsOriginalAndEditsOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageEdit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("SnippadImageEditTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = SettingsStore(url: nil)
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)

        let original = png()
        pasteboard.clearContents()
        pasteboard.setData(original, forType: .png)
        history.poll()
        let id = try XCTUnwrap(history.items.first?.id)

        var edits = ImageEdits(original: original)
        edits.crop = CGRect(x: 0, y: 0, width: 20, height: 10)
        let result = try XCTUnwrap(ImageCompositor.png(edits))
        history.updateImage(id, png: result, edits: edits)
        XCTAssertEqual(history.item(id)?.pngData, result)
        XCTAssertEqual(pasteboard.data(forType: .png), result, "the clipboard gets the edited image")
        history.flush()

        let reloaded = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        XCTAssertEqual(reloaded.item(id)?.edits, edits)
        XCTAssertEqual(reloaded.item(id)?.edits?.original, original)

        let exported = ListExport.text(ListExport.records(reloaded.items, settings: settings), as: .json, listName: "All")
        XCTAssertTrue(exported.contains("image_edits"))
    }

    @MainActor
    func testEditorUndoesAndRedoesAndSavesTheResult() throws {
        var saved: (ImageEdits, Data)?
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png())) { saved = ($0, $1) })
        model.change { $0.crop = CGRect(x: 0, y: 0, width: 10, height: 10) }
        model.add(model.newLayer(.shape, at: CGPoint(x: 1, y: 1)))
        XCTAssertEqual(model.edits.layers.count, 1)
        model.undo()
        XCTAssertEqual(model.edits.layers.count, 0)
        XCTAssertNotNil(model.edits.crop)
        model.undo()
        XCTAssertNil(model.edits.crop)
        model.redo()
        XCTAssertNotNil(model.edits.crop)
        model.saveNow()
        XCTAssertEqual(saved?.0.crop, CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(saved.flatMap { ImageCompositor.cgImage($0.1) }?.width, 10)
    }

    @MainActor
    func testMarkersCountUpAndUndoGivesTheNumberBack() throws {
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 200, height: 200))) { _, _ in })
        let first = model.dropMarker(at: CGPoint(x: 50, y: 50))
        let second = model.dropMarker(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(model.nextNumber, 3)
        XCTAssertEqual(second.rect.midX, 100, accuracy: 0.001, "centred where it is dropped")
        model.undo()
        XCTAssertEqual(model.nextNumber, 2)

        model.style.marker = .pin
        let pin = model.dropMarker(at: CGPoint(x: 150, y: 150))
        XCTAssertEqual(pin.marker, .pin)
        XCTAssertGreaterThan(pin.rect.height, pin.rect.width, "a pin is taller than wide")
    }

    func testEveryEffectMarkerAndLineStyleDraws() throws {
        var edits = ImageEdits(original: png(width: 120, height: 90, .blue))
        for (i, e) in ImageEffect.allCases.enumerated() {
            var layer = effect(e, CGRect(x: Double(i % 6) * 18, y: Double(i / 6) * 20, width: 16, height: 16))
            layer.effectSize = e.defaultSize
            edits.layers.append(layer)
        }
        for (i, shape) in MarkerShape.allCases.enumerated() {
            var marker = ImageLayer(kind: .marker, start: CGPoint(x: Double(i) * 14, y: 70), end: CGPoint(x: Double(i) * 14 + 12, y: 86))
            marker.marker = shape
            marker.number = i + 1
            edits.layers.append(marker)
        }
        for (i, style) in LineStyle.allCases.enumerated() {
            var line = ImageLayer(kind: .line, start: CGPoint(x: 0, y: Double(i) * 4), end: CGPoint(x: 120, y: Double(i) * 4))
            line.lineStyle = style
            line.lineWidth = 2
            edits.layers.append(line)
        }
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(try ImageEdits(json: edits.json), edits)
        XCTAssertEqual(ImageEffect.mosaic.defaultSize, 4)
    }

    func testAMarkerIsFilledAndCarriesItsNumber() throws {
        var edits = ImageEdits(original: png(width: 60, height: 60, .white))
        var marker = ImageLayer(kind: .marker, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50))
        marker.marker = .circle
        marker.number = 7
        marker.stroke = RGBA(r: 0, g: 0.6, b: 0)
        edits.layers = [marker]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        let edge = pixel(image, 14, 30)
        XCTAssertGreaterThan(edge.g, 120, "the body is filled with the marker's colour")
        XCTAssertLessThan(edge.r, 40)
        XCTAssertGreaterThan(pixel(image, 2, 2).r, 240, "outside stays as it was")
    }

    func testEditsSavedWithoutNewerFieldsStillOpen() throws {
        let old = """
            {"layers":[{"kind":"effect","start":[1,1],"end":[9,9],"effect":"mosaic"},
                       {"kind":"line","start":[0,0],"end":[5,5],"lineStyle":"dashed"}],
             "original":"\(png().base64EncodedString())"}
            """
        let edits = try ImageEdits(json: old)
        XCTAssertEqual(edits.layers[0].effectSize, 4)
        XCTAssertEqual(edits.layers[1].lineStyle, .dashed)
    }

    func testArrowsSavedBeforeHeadsOpenAsLinesWithAHead() throws {
        let old = """
            {"layers":[{"kind":"arrow","start":[0,0],"end":[20,20]}],"original":"\(png().base64EncodedString())"}
            """
        let layer = try XCTUnwrap(ImageEdits(json: old).layers.first)
        XCTAssertEqual(layer.kind, .line)
        XCTAssertEqual(layer.startHead, .none)
        XCTAssertEqual(layer.endHead, .solid)
    }

    func testEveryHeadDrawsAtEitherEnd() throws {
        var edits = ImageEdits(original: png(width: 200, height: 200, .white))
        for (i, head) in ArrowHead.allCases.enumerated() {
            var line = ImageLayer(kind: .line, start: CGPoint(x: 20, y: Double(i) * 16 + 10), end: CGPoint(x: 180, y: Double(i) * 16 + 10))
            line.startHead = head
            line.endHead = head
            line.lineWidth = 2
            edits.layers.append(line)
        }
        XCTAssertNotNil(ImageCompositor.render(edits))
        XCTAssertEqual(try ImageEdits(json: edits.json), edits)
    }

    func testASolidHeadIsFilledAtTheEnd() throws {
        var edits = ImageEdits(original: png(width: 100, height: 40, .white))
        var line = ImageLayer(kind: .line, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 90, y: 20))
        line.lineWidth = 2
        line.stroke = RGBA(r: 0, g: 0, b: 1)
        line.endHead = .solid
        edits.layers = [line]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertGreaterThan(pixel(image, 84, 23).b, 200, "inside the head, off the line")
        XCTAssertGreaterThan(pixel(image, 15, 23).r, 240, "no head at the start")
    }

    func testPolygonsAndFreehandShapesKeepTheirPoints() throws {
        var edits = ImageEdits(original: png(width: 60, height: 60, .white))
        var triangle = ImageLayer(kind: .shape, start: .zero, end: .zero, shape: .polygon)
        triangle.setPoints([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 10, y: 50)])
        triangle.fill = RGBA(r: 0, g: 0, b: 1)
        XCTAssertEqual(triangle.rect, CGRect(x: 10, y: 10, width: 40, height: 40))
        edits.layers = [triangle]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertGreaterThan(pixel(image, 15, 15).b, 200, "inside")
        XCTAssertGreaterThan(pixel(image, 45, 45).r, 240, "the other half of the box stays white")

        triangle.move(by: 5, 5)
        XCTAssertEqual(triangle.points?.first, CGPoint(x: 15, y: 15))
        triangle.scale(from: triangle.rect, to: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(triangle.points?[1], CGPoint(x: 20, y: 0))

        var scribble = ImageLayer(kind: .line, start: .zero, end: .zero)
        scribble.form = .freehand
        scribble.setPoints((0..<20).map { CGPoint(x: Double($0) * 2, y: Double($0 % 3)) })
        scribble.endHead = .open
        edits.layers.append(scribble)
        XCTAssertEqual(scribble.end, CGPoint(x: 38, y: 1), "a line's end is its last point")
        XCTAssertNotNil(ImageCompositor.render(edits))
        XCTAssertEqual(try ImageEdits(json: edits.json), edits)
    }

    @MainActor
    func testAPolygonAreaBecomesAPolygonEffect() throws {
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 100, height: 100))) { _, _ in })
        model.tool = .area
        model.area = ImageArea(shape: .polygon, start: .zero, end: .zero,
                               points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 20), CGPoint(x: 30, y: 70)])
        model.apply(.mosaic)
        let layer = try XCTUnwrap(model.edits.layers.first)
        XCTAssertEqual(layer.shape, .polygon)
        XCTAssertEqual(layer.points?.count, 3)
        XCTAssertEqual(layer.rect, CGRect(x: 10, y: 10, width: 50, height: 60))
    }

    @MainActor
    func testANewMarkerTakesTheSizeOfTheLastOne() throws {
        var edits = ImageEdits(original: png(width: 400, height: 400))
        var big = ImageLayer(kind: .marker, start: .zero, end: CGPoint(x: 70, y: 70))
        big.marker = .circle
        big.number = 1
        edits.layers = [big]
        let model = try XCTUnwrap(ImageEditorModel(edits: edits) { _, _ in })
        XCTAssertEqual(model.dropMarker(at: CGPoint(x: 200, y: 200)).rect.width, 70, accuracy: 0.001)
        model.markerWidth = 30  // what resizing one does
        XCTAssertEqual(model.dropMarker(at: CGPoint(x: 300, y: 300)).rect.width, 30, accuracy: 0.001)
    }

    @MainActor
    func testObjectsCanBeReorderedAndSelectedFromTheList() throws {
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 100, height: 100))) { _, _ in })
        let a = model.newLayer(.shape, at: .zero), b = model.newLayer(.line, at: .zero), c = model.newLayer(.shape, at: .zero)
        [a, b, c].forEach { model.add($0) }
        model.reorder(a.id, .front)
        XCTAssertEqual(model.edits.layers.map(\.id), [b.id, c.id, a.id])
        model.reorder(a.id, .backward)
        XCTAssertEqual(model.edits.layers.map(\.id), [b.id, a.id, c.id])
        // The list shows the topmost first: c, a, b. Moving b to its top:
        model.moveInList(IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.edits.layers.map(\.id), [a.id, c.id, b.id])
        model.undo()
        XCTAssertEqual(model.edits.layers.map(\.id), [b.id, a.id, c.id])

        model.tool = .shape
        model.select(a.id)
        XCTAssertEqual(model.tool, .pointer)
        XCTAssertEqual(model.selected, a.id)
        XCTAssertEqual(ImageEditorModel.title(of: b), "Arrow", "a new line has an arrow head at its end")
    }

    @MainActor
    func testAStraightLineKeepsItsPointsForLater() throws {
        var edits = ImageEdits(original: png(width: 200, height: 200))
        var line = ImageLayer(kind: .line, start: .zero, end: .zero)
        line.form = .polyline
        line.setPoints([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 20), CGPoint(x: 100, y: 0)])
        edits.layers = [line]
        let model = try XCTUnwrap(ImageEditorModel(edits: edits) { _, _ in })
        model.select(line.id)
        model.setForm(.straight)
        XCTAssertEqual(model.selectedLayer?.points?.count, 3, "kept, though not used")
        XCTAssertEqual(model.selectedLayer?.linePoints.count, 2)
        // The straight line's end moves; the kept points follow when they
        // are used again.
        model.change { $0.layers[0].end = CGPoint(x: 200, y: 0) }
        model.setForm(.freehand)
        let points = try XCTUnwrap(model.selectedLayer?.activePoints)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[2].x, 200, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 100, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 40, accuracy: 0.001)
    }

    @MainActor
    func testAPolygonMadeARectangleAndBackKeepsItsCorners() throws {
        var edits = ImageEdits(original: png(width: 200, height: 200))
        var shape = ImageLayer(kind: .shape, start: .zero, end: .zero, shape: .polygon)
        shape.setPoints([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30), CGPoint(x: 10, y: 50)])
        edits.layers = [shape]
        let model = try XCTUnwrap(ImageEditorModel(edits: edits) { _, _ in })
        model.select(shape.id)
        model.setShape(.rectangle)
        XCTAssertEqual(model.selectedLayer?.rect, CGRect(x: 10, y: 10, width: 40, height: 40))
        model.change { $0.layers[0].move(by: 5, 0) }
        model.setShape(.polygon)
        XCTAssertEqual(model.selectedLayer?.activePoints?[1], CGPoint(x: 55, y: 30))
    }

    func testDraggingAPointOfARectangleMakesItAPolygon() {
        var layer = ImageLayer(kind: .shape, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10))
        XCTAssertEqual(layer.editablePoints.count, 4)
        layer.setPoint(2, to: CGPoint(x: 20, y: 15))
        XCTAssertEqual(layer.shape, .polygon)
        XCTAssertEqual(layer.rect, CGRect(x: 0, y: 0, width: 20, height: 15))

        var oval = ImageLayer(kind: .shape, start: .zero, end: CGPoint(x: 10, y: 10), shape: .oval)
        oval.makePointsEditable()
        XCTAssertEqual(oval.shape, .freehand)
        XCTAssertEqual(oval.center.x, 5, accuracy: 0.001, "the outline stays where it was")
    }

    func testATurnedObjectIsDrawnTurnedAndResizesAboutItsFixedCorner() throws {
        var edits = ImageEdits(original: png(width: 100, height: 100, .white))
        var bar = ImageLayer(kind: .shape, start: CGPoint(x: 10, y: 45), end: CGPoint(x: 90, y: 55))
        bar.fill = RGBA(r: 0, g: 0, b: 1)
        bar.stroke = RGBA(r: 0, g: 0, b: 1)
        bar.rotation = 90
        edits.layers = [bar]
        let image = try XCTUnwrap(ImageCompositor.render(edits))
        XCTAssertGreaterThan(pixel(image, 50, 15).b, 200, "upright now")
        XCTAssertGreaterThan(pixel(image, 15, 50).r, 240, "not where it was lying")
        XCTAssertEqual(try ImageEdits(json: edits.json), edits)

        // Its top left corner, turned, stays put while the box changes.
        let corner = bar.worldCorners[0]
        let center = bar.center
        bar.end = CGPoint(x: 120, y: 70)
        bar.reanchor(from: center)
        XCTAssertEqual(bar.worldCorners[0].x, corner.x, accuracy: 0.001)
        XCTAssertEqual(bar.worldCorners[0].y, corner.y, accuracy: 0.001)
    }

    @MainActor
    func testObjectsCopyFromOneEditorAndPasteIntoAnother() throws {
        let pasteboard = NSPasteboard(name: .init("SnippadImageObjects-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var label: String?
        let put: ([String: Data], String) -> Void = { types, name in
            pasteboard.clearContents()
            for (type, data) in types { pasteboard.setData(data, forType: .init(type)) }
            label = name
        }
        let one = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 200, height: 200))) { _, _ in })
        let other = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 300, height: 300))) { _, _ in })
        for model in [one, other] {
            model.pasteboard = pasteboard
            model.putOnClipboard = put
        }
        var marker = one.dropMarker(at: CGPoint(x: 50, y: 50))
        marker.rotation = 30
        one.change { $0.layers[0] = marker }
        XCTAssertTrue(one.copySelected())
        XCTAssertEqual(label, "Marker 1")
        XCTAssertNotNil(pasteboard.data(forType: .png), "a picture for other apps")

        XCTAssertTrue(other.paste())
        let pasted = try XCTUnwrap(other.edits.layers.first)
        XCTAssertNotEqual(pasted.id, marker.id)
        XCTAssertEqual(pasted.rect, marker.rect)
        XCTAssertEqual(pasted.rotation, 30)
        XCTAssertEqual(other.nextNumber, 2)

        // Pasted again where it is: moved off the first copy.
        XCTAssertTrue(other.paste())
        XCTAssertEqual(other.edits.layers.count, 2)
        XCTAssertNotEqual(other.edits.layers[1].rect, other.edits.layers[0].rect)

        XCTAssertTrue(one.cutSelected())
        XCTAssertTrue(one.edits.layers.isEmpty)
    }

    @MainActor
    func testCopiedObjectsGoToTheListTheSettingsName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageObjects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: .init("SnippadImageObjectsList-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let settings = SettingsStore(url: nil)
        let engine = PasteEngine()
        engine.pasteboard = pasteboard
        let history = ClipboardHistory(directory: directory, pasteboard: pasteboard, settings: settings, engine: engine)
        let list = settings.addList(named: "Drawings")
        settings.value.imageObjectsList = list.id

        let types = [ImageEditorModel.objectsType.rawValue: Data("[]".utf8), NSPasteboard.PasteboardType.png.rawValue: png()]
        history.addImageObjects(types, label: "Arrow")
        XCTAssertEqual(history.items.first?.list, list.id)
        XCTAssertNotNil(pasteboard.data(forType: ImageEditorModel.objectsType))

        settings.value.imageObjectsRecorded = false
        history.addImageObjects([NSPasteboard.PasteboardType.png.rawValue: png(.blue)], label: "Text")
        XCTAssertEqual(history.items.count, 1, "on the clipboard only")
    }

    @MainActor
    func testFreehandPointsAreThinnedOut() {
        let straight = (0...100).map { CGPoint(x: Double($0), y: 0) }
        XCTAssertEqual(ImageCanvasView.simplified(straight, tolerance: 0.5).count, 2)
        let corner = straight + (1...100).map { CGPoint(x: 100, y: Double($0)) }
        XCTAssertEqual(ImageCanvasView.simplified(corner, tolerance: 0.5).count, 3)
    }

    /// An editor whose copies go to a private pasteboard.
    @MainActor
    private func editor(_ edits: ImageEdits, pasteboard: NSPasteboard) throws -> ImageEditorModel {
        let model = try XCTUnwrap(ImageEditorModel(edits: edits) { _, _ in })
        model.pasteboard = pasteboard
        model.putOnClipboard = { types, _ in
            pasteboard.clearContents()
            for (type, data) in types { pasteboard.setData(data, forType: .init(type)) }
        }
        return model
    }

    @MainActor
    func testAnAreaCopiesAsItLooksAndCutDeletesIt() throws {
        let pasteboard = NSPasteboard(name: .init("SnippadImageArea-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var edits = ImageEdits(original: png(width: 100, height: 100, .white))
        var box = ImageLayer(kind: .shape, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 50, y: 100))
        box.fill = RGBA(r: 0, g: 0, b: 1)
        box.stroke = RGBA(r: 0, g: 0, b: 1)
        edits.layers = [box]
        let model = try editor(edits, pasteboard: pasteboard)
        model.tool = .area
        model.area = ImageArea(shape: .rectangle, start: CGPoint(x: 40, y: 10), end: CGPoint(x: 60, y: 30))
        XCTAssertTrue(model.copy())
        let copied = try XCTUnwrap(pasteboard.data(forType: .png).flatMap(ImageCompositor.cgImage))
        XCTAssertEqual(copied.width, 20)
        XCTAssertEqual(copied.height, 20)
        XCTAssertGreaterThan(pixel(copied, 2, 10).b, 200, "the shape drawn on it is copied too")
        XCTAssertLessThan(pixel(copied, 2, 10).r, 60)
        XCTAssertGreaterThan(pixel(copied, 17, 10).r, 240, "and the image beside it")
        XCTAssertNil(pasteboard.data(forType: ImageEditorModel.objectsType), "a picture, not objects")

        // An oval area: transparent in its corners.
        model.area = ImageArea(shape: .oval, start: CGPoint(x: 40, y: 10), end: CGPoint(x: 60, y: 30))
        let oval = try XCTUnwrap(model.areaImage().flatMap(ImageCompositor.cgImage))
        XCTAssertEqual(pixel(oval, 0, 0).a, 0)
        XCTAssertEqual(pixel(oval, 10, 10).a, 255)

        // Cut: copied, then deleted as Delete does.
        XCTAssertTrue(model.cut())
        XCTAssertNil(model.area)
        XCTAssertEqual(model.edits.layers.last?.effect, .erase)
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    @MainActor
    func testSeveralObjectsAreCopiedMovedRestyledAndRemovedTogether() throws {
        let pasteboard = NSPasteboard(name: .init("SnippadImageSeveral-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let model = try editor(ImageEdits(original: png(width: 200, height: 200)), pasteboard: pasteboard)
        let shape = model.newLayer(.shape, at: CGPoint(x: 10, y: 10))
        var box = shape
        box.end = CGPoint(x: 40, y: 40)
        var line = model.newLayer(.line, at: CGPoint(x: 50, y: 50))
        line.end = CGPoint(x: 90, y: 60)
        let marker = model.newMarker(at: CGPoint(x: 150, y: 150))
        model.change { $0.layers = [box, line, marker] }
        model.select([box.id, line.id])
        XCTAssertNil(model.selected, "no one object alone")

        // A width they both have changes both; the marker is left alone.
        model.setStyle("width", for: [.shape, .line]) { $0.lineWidth = 9 }
        XCTAssertEqual(model.edits.layers.map(\.lineWidth).prefix(2), [9, 9])
        XCTAssertEqual(model.edits.layers[2].lineWidth, marker.lineWidth)
        // A text size they do not have changes neither.
        model.setStyle("fontSize", for: [.text]) { $0.fontSize = 99 }
        XCTAssertNotEqual(model.edits.layers[0].fontSize, 99)
        XCTAssertFalse(model.selectionIs([.shape]))
        XCTAssertTrue(model.selectionIs([.shape, .line]))

        model.rotate(by: 15)
        XCTAssertEqual(model.edits.layers.map(\.rotation), [15, 15, 0])

        XCTAssertTrue(model.copySelected())
        let other = try editor(ImageEdits(original: png(width: 300, height: 300)), pasteboard: pasteboard)
        XCTAssertTrue(other.paste())
        XCTAssertEqual(other.edits.layers.map(\.kind), [.shape, .line], "both, in their order")
        XCTAssertEqual(other.selection.count, 2, "the pasted ones are selected")

        model.duplicateSelected()
        XCTAssertEqual(model.edits.layers.count, 5)
        XCTAssertEqual(model.selection.count, 2)
        model.removeSelected()
        XCTAssertEqual(model.edits.layers.count, 3)
        XCTAssertTrue(model.selection.isEmpty)

        model.selectAllObjects()
        XCTAssertEqual(model.selection.count, 3)
        model.undo()
        XCTAssertEqual(model.edits.layers.count, 5, "the removed copies are back")
        XCTAssertEqual(model.selection.count, 3, "the selection keeps what is still there")
    }

    @MainActor
    func testSeveralObjectsMoveUpAndDownThePileTogether() throws {
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png())) { _, _ in })
        let layers = (0..<5).map { model.newText(at: CGPoint(x: Double($0), y: 0)) }
        model.change { $0.layers = layers }
        let ids = layers.map(\.id)
        func order() -> [Int] { model.edits.layers.map { ids.firstIndex(of: $0.id)! } }

        model.reorder([ids[0], ids[1]], .forward)
        XCTAssertEqual(order(), [2, 0, 1, 3, 4])
        model.reorder([ids[0], ids[3]], .front)
        XCTAssertEqual(order(), [2, 1, 4, 0, 3])
        model.reorder([ids[4], ids[3]], .back)
        XCTAssertEqual(order(), [4, 3, 2, 1, 0])
        model.reorder([ids[2], ids[0]], .backward)
        XCTAssertEqual(order(), [4, 2, 3, 0, 1])
    }

    @MainActor
    func testTheGridStepperGoesThroughTheSizes() {
        XCTAssertEqual(ImageEditorView.gridSize(after: 10, up: true), 15)
        XCTAssertEqual(ImageEditorView.gridSize(after: 10, up: false), 8)
        XCTAssertEqual(ImageEditorView.gridSize(after: 13, up: true), 15, "a typed size steps to the next one")
        XCTAssertEqual(ImageEditorView.gridSize(after: 13, up: false), 10)
        XCTAssertEqual(ImageEditorView.gridSize(after: 1000, up: true), 1000)
        XCTAssertEqual(ImageEditorView.gridSize(after: 2, up: false), 2)
    }

    @MainActor
    func testZoomingMakesTheCanvasScrollAndFitBringsItBack() throws {
        let model = try XCTUnwrap(ImageEditorModel(edits: ImageEdits(original: png(width: 2000, height: 1000))) { _, _ in })
        let scroll = ImageScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let canvas = ImageCanvasView()
        canvas.model = model
        scroll.documentView = canvas
        model.canvas = canvas
        canvas.updateSize()
        XCTAssertEqual(canvas.frame.size, scroll.contentView.bounds.size, "fits: nothing to scroll")
        XCTAssertLessThan(model.shownZoom, 0.5)

        model.setZoom(2)
        XCTAssertEqual(model.zoom, 2)
        XCTAssertEqual(model.shownZoom, 2, accuracy: 1e-9)
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertEqual(canvas.frame.width, (2000 * 2 / backing + 32).rounded(.up), accuracy: 0.5)
        XCTAssertGreaterThan(canvas.frame.height, scroll.contentView.bounds.height)

        model.zoomIn()
        XCTAssertEqual(model.zoom, 3)
        model.zoomOut()
        model.zoomOut()
        XCTAssertEqual(model.zoom, 1.5)
        model.setZoom(100)
        XCTAssertEqual(model.zoom, 32, "no further than 32 ×")

        model.setZoom(nil)
        XCTAssertNil(model.zoom)
        XCTAssertEqual(canvas.frame.size, scroll.contentView.bounds.size)
    }

    @MainActor
    func testTheZoomStepsGoUpAndDown() {
        XCTAssertEqual(ImageEditorModel.zoom(after: 1, up: true), 1.5)
        XCTAssertEqual(ImageEditorModel.zoom(after: 1, up: false), 2.0 / 3)
        XCTAssertEqual(ImageEditorModel.zoom(after: 0.3, up: true), 1.0 / 3, "from a zoom to fit, the next step")
        XCTAssertEqual(ImageEditorModel.zoom(after: 32, up: true), 32)
    }
}
