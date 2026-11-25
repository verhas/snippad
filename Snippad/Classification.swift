import AppKit
import FoundationModels

/// What an entry holds, for how carefully it is pasted: classified in the
/// background (rules, then Apple Intelligence on this Mac), or set by the
/// user from the Organizer's right-click menu.
enum ClipCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Anything else: code, documentation, ordinary text, links.
    case general = "public"
    /// Personal data: names with contact details, addresses, phone numbers,
    /// account and card numbers, ID numbers, health or salary details.
    case sensitive
    /// Rude words, sexual content: what a censored model refuses.
    case offensive = "private"
    /// Passwords, API keys, tokens, private keys, recovery codes.
    case secret

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: "Public"
        case .sensitive: "Sensitive"
        case .offensive: "Private"
        case .secret: "Secret"
        }
    }

    var explanation: String {
        switch self {
        case .general: "Nothing personal, rude or secret."
        case .sensitive: "Personal data: names, addresses, phone numbers, account or card numbers."
        case .offensive: "Rude words or sexual content."
        case .secret: "A password, key or token."
        }
    }

    var color: NSColor {
        switch self {
        case .general: .systemGreen
        case .sensitive: .systemOrange
        case .offensive: .systemPurple
        case .secret: .systemRed
        }
    }

    /// When two apply, the more careful one stands.
    var rank: Int {
        switch self {
        case .general: 0
        case .sensitive: 1
        case .offensive: 2
        case .secret: 3
        }
    }

    static func careful(_ a: ClipCategory?, _ b: ClipCategory?) -> ClipCategory? {
        guard let a else { return b }
        guard let b else { return a }
        return a.rank >= b.rank ? a : b
    }
}

extension ClipItem {
    /// What is classified: the text, or the text read from the picture.
    /// Files, colours and other data are not.
    var classifiedText: String? {
        switch kind {
        case .text, .url, .richText: string
        case .image: readTextFrom == digest ? (readText ?? "") : nil
        case .files, .color, .other: nil
        }
    }

    /// What the classification was made of: the content, and for a picture
    /// the text read from it. Either changing means classifying again.
    var classificationKey: String {
        kind == .image ? digest + ":" + ClipItem.digest(of: [["text": Data((readText ?? "").utf8)]]) : digest
    }

    /// Whether it is still to be classified -- or again: it changed, or
    /// Apple Intelligence came since. A picture waits for its text, unless
    /// `imageTextIsRead` is off.
    func needsClassification(model: Bool, imageTextIsRead: Bool) -> Bool {
        guard pending != true, [.text, .url, .richText, .image].contains(kind) || isPassword else { return false }
        if kind == .image, imageTextIsRead, !isPassword, readTextFrom != digest { return false }
        return categoryFrom != classificationKey
            || (model && (categoryByModel != true || categoryVersion != ClipClassifier.version))
    }

    /// The category found for it: classified, or Secret for a password.
    var effectiveCategory: ClipCategory? { userCategory ?? category ?? (isPassword ? .secret : nil) }

    /// Why it is never Public, when it is not: a private window, or an
    /// application set so in Settings.
    func neverPublicReason(_ settings: SnippadSettings) -> String? {
        if inPrivateWindow == true { return "copied in a private window" }
        if let id = sourceBundleID, settings.neverPublicApps.contains(id) {
            return "copied from \(sourceApp ?? id), which is never Public"
        }
        return nil
    }

    /// The category it is treated as: the user's; else the one found, where
    /// Public counts as Private for what is never Public -- which is Private
    /// too until it is classified.
    func category(in settings: SnippadSettings) -> ClipCategory? {
        if let userCategory { return userCategory }
        let found = ClipCategory.careful(category ?? (isPassword ? .secret : nil), inheritedCategory)
        return ClipItem.floored(found, neverPublic: neverPublicReason(settings) != nil)
    }

    /// Why it counts as more than it was classified: never Public, or made
    /// from an entry that was more.
    func raisedBecause(_ settings: SnippadSettings) -> String? {
        if let reason = neverPublicReason(settings) { return reason }
        return inheritedCategory.map { "copied from a \($0.name) entry" }
    }

    static func floored(_ found: ClipCategory?, neverPublic: Bool) -> ClipCategory? {
        guard neverPublic else { return found }
        return found == nil || found == .general ? .offensive : found
    }
}

/// Classifies a text: fixed rules for what has a shape (keys, account and
/// card numbers, addresses), then the on-device model for the rest.
nonisolated enum ClipClassifier {

    /// Raised when the classifying changes: every entry is classified again.
    /// 2: the model's labels no longer say "private", which it took for
    /// personal, and refused harmless text over.
    static let version = 2

    /// Whether Apple Intelligence can be asked on this Mac now.
    static var modelAvailable: Bool {
        // Not while testing: every test's history would ask it, slowly, and
        // answer differently from run to run. The rules still run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The category of `text`, and whether the model was asked.
    static func classify(_ text: String?, password: Bool, useModel: Bool) async -> (ClipCategory, Bool) {
        if password { return (.secret, true) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (.general, true) }
        let ruled = rules(text)
        if ruled == .secret || !useModel { return (ruled ?? .general, useModel) }
        var asked: ClipCategory?
        if #available(macOS 26, *) { asked = await IntelligenceClassifier.category(of: text) }
        return (ClipCategory.careful(ruled, asked) ?? .general, true)
    }

    // MARK: - Rules

    /// What the text's shape alone tells: nil when nothing.
    static func rules(_ text: String) -> ClipCategory? {
        let sample = String(text.prefix(20_000))
        if secretPatterns.contains(where: { matches($0, sample) }) { return .secret }
        if hasIBAN(sample) || hasCardNumber(sample) || matches(hungarianAccount, sample) || hasAddressOrPhone(sample) {
            return .sensitive
        }
        return nil
    }

    private static let secretPatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bsk-[A-Za-z0-9_-]{20,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        #"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|jelsz[óo])\s*[:=]\s*\S{6,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A Hungarian bank account: two or three groups of eight digits.
    private static let hungarianAccount = try! NSRegularExpression(pattern: #"\b\d{8}-\d{8}(-\d{8})?\b"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let ibanShape = try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#)

    /// An IBAN whose check digits are right (ISO 13616, mod 97).
    static func hasIBAN(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return ibanShape.matches(in: text, range: range).contains { match in
            guard let r = Range(match.range, in: text) else { return false }
            let iban = text[r].filter { $0 != " " }
            let moved = iban.dropFirst(4) + iban.prefix(4)
            var remainder = 0
            for ch in moved {
                guard let value = ch.isNumber ? ch.wholeNumberValue : ch.isLetter ? Int(ch.asciiValue!) - 55 : nil else { return false }
                for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
            }
            return remainder == 1
        }
    }

    private static let cardShape = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#)

    /// A card number: 13 to 19 digits that pass the Luhn check.
    static func hasCardNumber(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return cardShape.matches(in: text, range: range).contains { match in
            guard let r = Range(match.range, in: text) else { return false }
            let digits = text[r].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
            let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
                let d = pair.offset % 2 == 1 ? pair.element * 2 : pair.element
                return sum + (d > 9 ? d - 9 : d)
            }
            return sum % 10 == 0
        }
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue
                                                      | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// A postal address, or a phone number written as one: with a +, in
    /// brackets, or from 0, and 7 to 15 digits -- not a run of digits or
    /// digit groups (a timestamp, an id, an amount).
    static func hasAddressOrPhone(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).contains { match in
            if match.resultType == .address { return true }
            guard let r = Range(match.range, in: text) else { return false }
            let found = text[r].trimmingCharacters(in: .whitespaces)
            let digits = found.filter(\.isNumber).count
            return (7...15).contains(digits) && (found.hasPrefix("+") || found.hasPrefix("(") || found.hasPrefix("0"))
        }
    }
}

// MARK: - Apple Intelligence

@available(macOS 26, *)
enum IntelligenceClassifier {
    @Generable
    struct Verdict {
        // Not the names shown: "private" reads as personal to the model, and
        // with it, it refused harmless text as unsafe.
        @Guide(description: "The category of the clipboard contents", .anyOf(["public", "personal", "offensive", "secret"]))
        var category: String
    }

    static let instructions = """
        You sort what someone copied to the clipboard into one category:
        secret: passwords, API keys, tokens, private keys, recovery codes.
        personal: personal data about a person: names with contact details, postal addresses, phone numbers, \
        e-mail addresses, bank account or card numbers, ID numbers, health or salary details.
        offensive: rude or vulgar words, insults, sexual content.
        public: anything else, such as code, documentation, ordinary prose, links.
        """

    /// The model's category, nil when it could not tell (a language it
    /// does not know, too long). A refusal is an answer: Private.
    static func category(of text: String) async -> ClipCategory? {
        // The system model, by name: on this Mac, never Private Cloud Compute.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        do {
            let reply = try await session.respond(to: "Clipboard contents:\n" + String(text.prefix(4000)),
                                                  generating: Verdict.self,
                                                  options: GenerationOptions(samplingMode: .greedy))
            switch reply.content.category {
            case "secret": return .secret
            case "personal": return .sensitive
            case "offensive": return .offensive
            case "public": return .general
            default: return nil
            }
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { return .offensive }
            if case .refusal = error { return .offensive }
            return nil
        } catch {
            if #available(macOS 27, *), let error = error as? LanguageModelError {
                if case .guardrailViolation = error { return .offensive }
                if case .refusal = error { return .offensive }
            }
            return nil
        }
    }
}

extension ClipboardHistory {
    /// Classifies every entry not classified yet (or changed since), newest
    /// first, one at a time in the background. Started when an entry comes
    /// or changes, when a picture's text has been read, at launch, and when
    /// Settings change. A classifier already running takes the new ones.
    func classifyEntries() {
        guard settings.value.classifyEntries, classifier == nil else { return }
        classifier = Task { [weak self] in
            while let self, self.settings.value.classifyEntries {
                let model = ClipClassifier.modelAvailable
                let waitForText = self.settings.value.readTextOfImages
                guard let next = self.items.first(where: { $0.needsClassification(model: model, imageTextIsRead: waitForText) })
                else { break }
                let id = next.id, key = next.classificationKey
                let text = next.classifiedText, password = next.isPassword
                let (category, asked) = await Task.detached(priority: .utility) {
                    await ClipClassifier.classify(text, password: password, useModel: model)
                }.value
                self.setCategory(category, byModel: asked, of: id, key: key)
            }
            self?.classifier = nil
        }
    }
}

/// Asks before an entry of a category chosen in Settings is pasted: with
/// ⌘V in any app (through the keyboard tap) and from Snippad's own menu.
@MainActor
enum PasteConfirmation {
    /// The entry the user just said yes to: its ⌘V goes through once.
    static var confirmed: UUID?

    /// The entry on the clipboard and its category, when pasting it (into
    /// the app `target`, when known) asks. Not classified yet (copied a
    /// moment ago): the rules decide. An app may take some categories
    /// without asking -- each on its own.
    static func needed(_ history: ClipboardHistory, _ settings: SnippadSettings,
                       into target: String? = nil) -> (ClipItem, ClipCategory)? {
        guard let item = history.currentItemID.flatMap(history.item) else { return nil }
        var category = item.category(in: settings)
        if item.userCategory == nil, item.category == nil, !item.isPassword, settings.classifyEntries,
           let text = item.classifiedText, let ruled = ClipClassifier.rules(text) {
            category = ClipItem.floored(ClipCategory.careful(ruled, item.inheritedCategory),
                                        neverPublic: item.neverPublicReason(settings) != nil)
        }
        guard let category, settings.askBeforePasting.contains(category.rawValue) else { return nil }
        if let target, settings.pasteWithoutAsking[target]?.contains(category.rawValue) == true { return nil }
        return (item, category)
    }

    enum Answer { case paste, dontPaste, dontPasteAndDelete, pasteAndDelete }

    /// Asks, then pastes into `target` or not, and deletes or not.
    static func ask(about item: ClipItem, _ category: ClipCategory, into target: NSRunningApplication) {
        act(question("Paste", item, category, where: " into \(target.localizedName ?? "this app")"), item: item, target: target)
    }

    /// The question, for pasting or exporting ("Paste", "Export"): yes, no,
    /// no and delete it, yes and delete it.
    static func question(_ verb: String, _ item: ClipItem, _ category: ClipCategory, where place: String) -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(verb) \(category == .general ? "this" : "a \(category.name.lowercased())") entry\(place)?"
        let settings = SettingsStore.shared.value
        let why = item.userCategory != nil ? "You marked it \(category.name)."
            : item.category(in: settings) != item.effectiveCategory
                ? "It counts as \(category.name): \(item.raisedBecause(settings) ?? "")."
                : "Snippad classified it \(category.name)."
        alert.informativeText = "\u{201C}\(preview(of: item, category))\u{201D}\n\n\(category.explanation) " + why
            + " Change that in the Organizer: right-click › Classification."
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Don\u{2019}t \(verb)").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Don\u{2019}t \(verb), and Delete It")
        alert.addButton(withTitle: "\(verb), and Delete It")
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .paste
        case .alertThirdButtonReturn: .dontPasteAndDelete
        case NSApplication.ModalResponse(rawValue: 1003): .pasteAndDelete  // the fourth button
        default: .dontPaste
        }
    }

    /// The category an export asks about for this entry, nil when it does
    /// not: as for pasting, in Settings.
    static func asksOnExport(_ item: ClipItem) -> ClipCategory? {
        let settings = SettingsStore.shared.value
        guard let category = item.category(in: settings), settings.askBeforePasting.contains(category.rawValue) else { return nil }
        return category
    }

    /// Before one entry is written to a file: true goes on. A delete asked
    /// for is done after a successful export (`thenDelete`) or at once.
    static func allowsExport(of item: ClipItem, thenDelete: inout Bool) -> Bool {
        guard let category = asksOnExport(item) else { return true }
        switch question("Export", item, category, where: " to a file") {
        case .paste: return true
        case .pasteAndDelete: thenDelete = true; return true
        case .dontPasteAndDelete: forget(item); return false
        case .dontPaste: return false
        }
    }

    enum ListExportAnswer { case all, withoutThem, none }

    /// Before a list is exported: what to do with the entries that ask.
    static func listExport(_ items: [ClipItem], name: String) -> ListExportAnswer {
        let asking = items.compactMap(asksOnExport)
        guard !asking.isEmpty else { return .all }
        let counts = ClipCategory.allCases.compactMap { category -> String? in
            let n = asking.filter { $0 == category }.count
            return n == 0 ? nil : "\(n) \(category.name)"
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export \(asking.count) of the \(items.count) entries of \u{201C}\(name)\u{201D} that are not Public?"
        alert.informativeText = counts.joined(separator: ", ") + ". A file can go anywhere; these would go with it. Settings › Classification says which categories ask."
        alert.addButton(withTitle: "Export Without Them")
        alert.addButton(withTitle: "Don\u{2019}t Export").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Export All")
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .withoutThem
        case .alertThirdButtonReturn: .all
        default: .none
        }
    }

    static func act(_ answer: Answer, item: ClipItem, target: NSRunningApplication) {
        target.activate()
        switch answer {
        case .dontPaste:
            break
        case .dontPasteAndDelete:
            forget(item)
        case .paste, .pasteAndDelete:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                confirmed = item.id
                PasteInterceptor.pasteIntoFrontApp()  // the Paste Guard still decides
                guard answer == .pasteAndDelete else { return }
                // Once the app has read the clipboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { forget(item) }
            }
        }
    }

    /// Off the clipboard, if it is still there, and out of the history (Undo
    /// Delete brings it back for five minutes).
    static func forget(_ item: ClipItem) {
        let history = ClipboardHistory.shared
        if history.currentItemID == item.id { PasteEngine.shared.clear() }
        history.delete(undoably: [item.id])
    }

    /// Enough to know which entry it is; a secret shows only its start.
    private static func preview(of item: ClipItem, _ category: ClipCategory) -> String {
        let text = item.name ?? item.classifiedText ?? item.title
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        if category == .secret || item.isPassword { return String(line.prefix(3)) + "\u{2022}\u{2022}\u{2022}\u{2022}" }
        return line.count > 80 ? String(line.prefix(79)) + "\u{2026}" : line
    }
}
