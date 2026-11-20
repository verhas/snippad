import AppKit
import UniformTypeIdentifiers
import Vision

/// Reads the text in an image, and the contents of any QR code (or other
/// barcode) in it, on the device with the Vision framework.
enum TextRecognition {

    /// The text found, QR code contents first, then the recognised lines in
    /// reading order. Throws when there is none.
    nonisolated static func text(in cgImage: CGImage) throws -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let codeRequest = VNDetectBarcodesRequest()

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([codeRequest, textRequest])

        let codes = (codeRequest.results ?? []).compactMap(\.payloadStringValue)
        let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        var seen = Set<String>()
        let parts = (codes + lines).filter { seen.insert($0).inserted }
        guard !parts.isEmpty else { throw ClipboardError("No text or QR code was found in the image.") }
        return parts.joined(separator: "\n")
    }

    nonisolated static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

extension ClipItem {
    /// An image entry, or files entry with image files, whose text can be read.
    var hasImageForText: Bool {
        if isPassword { return false }
        if kind == .image { return true }
        return kind == .files && imageFileURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    var imageFileURLs: [URL] {
        fileURLs.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }
}

extension TextRecognition {
    /// The text of several images, separated by a blank line.
    nonisolated static func text(inImages images: [Data]) throws -> String {
        var found: [String] = []
        var lastError: Error?
        for data in images {
            guard let cg = cgImage(from: data) else { continue }
            do { found.append(try text(in: cg)) } catch { lastError = error }
        }
        if found.isEmpty { throw lastError ?? ClipboardError("The image could not be read.") }
        return found.joined(separator: "\n\n")
    }
}

extension ClipboardHistory {
    private func images(of id: UUID) throws -> (ClipItem, [Data]) {
        guard let item = item(id) else { throw ClipboardError("That history entry is gone.") }
        let images = item.kind == .image ? item.imageData.map { [$0] } ?? []
            : item.imageFileURLs.compactMap { try? Data(contentsOf: $0) }
        guard !images.isEmpty else { throw ClipboardError("The entry has no image to read text from.") }
        return (item, images)
    }

    /// Reads the text (and QR codes) of an image entry, or of the image files
    /// of a files entry, and puts it on the clipboard as a new text entry in
    /// the same list.
    @discardableResult
    func extractText(from id: UUID) async throws -> ClipItem? {
        let (item, images) = try images(of: id)
        let name = "Text from \(item.title)"
        let pending = insertPending(label: item.title, list: item.list)
        do {
            let text = try await Task.detached(priority: .userInitiated) { try TextRecognition.text(inImages: images) }.value
            return finishPending(pending, text: text, name: name)
        } catch {
            dropPending(pending)
            throw error
        }
    }

    /// The same, waiting for the result (for agents, whose calls are
    /// answered in one go).
    @discardableResult
    func extractTextNow(from id: UUID) throws -> ClipItem? {
        let (item, images) = try images(of: id)
        return putText(try TextRecognition.text(inImages: images), name: "Text from \(item.title)", list: item.list)
    }
}
