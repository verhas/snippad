import AppKit
import UniformTypeIdentifiers
import Vision

/// Reads the text in an image, and the contents of any QR code (or other
/// barcode) in it, on the device with the Vision framework.
enum TextRecognition {

    /// The text found, QR code contents first, then the recognised lines in
    /// reading order. Throws when there is none. With `languages`, read in
    /// those (in order of preference); without, Vision guesses.
    nonisolated static func text(in cgImage: CGImage, languages: [String]? = nil) throws -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        if let languages, !languages.isEmpty {
            textRequest.recognitionLanguages = languages
            textRequest.automaticallyDetectsLanguage = false
        } else {
            textRequest.automaticallyDetectsLanguage = true
        }
        let codeRequest = VNDetectBarcodesRequest()

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([codeRequest, textRequest])

        let codes = (codeRequest.results ?? []).compactMap(\.payloadStringValue)
        let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        var seen = Set<String>()
        let parts = (codes + lines).filter { seen.insert($0).inserted }
        guard !parts.isEmpty else { throw ClipboardError("No text or QR code was found in the image.") }
        return parts.joined(separator: "\n")
    }

    /// The Mac's preferred languages (System Settings › General › Language
    /// & Region) that Vision reads, in their order: "hu-HU" matches Vision's
    /// "hu-HU", or else another region of Hungarian.
    nonisolated static func preferredLanguages(_ preferred: [String] = Locale.preferredLanguages) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        func language(_ id: String) -> String { Locale(identifier: id).language.languageCode?.identifier ?? id }
        var chosen: [String] = []
        for id in preferred {
            let match = supported.first { $0.caseInsensitiveCompare(id) == .orderedSame }
                ?? supported.first { language($0) == language(id) }
            if let match, !chosen.contains(match) { chosen.append(match) }
        }
        return chosen
    }

    /// The languages to read in, as Settings say: nil lets Vision guess.
    nonisolated static func languages(_ settings: SnippadSettings) -> [String]? {
        settings.readTextInPreferredLanguages ? preferredLanguages() : nil
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
    nonisolated static func text(inImages images: [Data], languages: [String]? = nil) throws -> String {
        var found: [String] = []
        var lastError: Error?
        for data in images {
            guard let cg = cgImage(from: data) else { continue }
            do { found.append(try text(in: cg, languages: languages)) } catch { lastError = error }
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
            let languages = TextRecognition.languages(settings.value)
            let text = try await Task.detached(priority: .userInitiated) { try TextRecognition.text(inImages: images, languages: languages) }.value
            return inheriting(from: [id]) { finishPending(pending, text: text, name: name) }
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
        let text = try TextRecognition.text(inImages: images, languages: TextRecognition.languages(settings.value))
        return inheriting(from: [id]) { putText(text, name: "Text from \(item.title)", list: item.list) }
    }
}

extension ClipboardHistory {
    /// Reads the text of every image entry that has not had it read, newest
    /// first, one at a time on a background thread, on the device (Vision,
    /// no network). Each entry gets its text when it is ready, and with it
    /// Paste as Text in the menu. Started when an image arrives or is
    /// edited, at launch, and when the languages in Settings change: then
    /// every image is read again. A reader already running takes the new ones.
    func readImageTexts() {
        guard settings.value.readTextOfImages, textReader == nil else { return }
        textReader = Task { [weak self] in
            while let self, self.settings.value.readTextOfImages {
                let languages = TextRecognition.languages(self.settings.value)
                guard let next = self.items.first(where: { $0.needsTextReading(in: languages) }) else { break }
                let id = next.id, digest = next.digest, image = next.imageData
                let text = await Task.detached(priority: .utility) {
                    image.flatMap(TextRecognition.cgImage(from:)).flatMap { try? TextRecognition.text(in: $0, languages: languages) } ?? ""
                }.value
                self.setReadText(text, of: id, from: digest, in: languages)
            }
            self?.textReader = nil
        }
    }
}
