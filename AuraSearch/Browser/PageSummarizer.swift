import Foundation
import NaturalLanguage
import Observation
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether pages can be summarized on this iPhone.
enum SummaryAvailability: Equatable {
    case available
    /// Before iOS 26, or an iPhone without Apple Intelligence. Summarize
    /// isn't offered at all.
    case notSupported
    case appleIntelligenceOff
    /// Still downloading, or busy for some other system reason.
    case modelNotReady
    case unavailable
}

/// Summarize Page: a few lines about the page, written on the device by
/// Apple's on-device model, like Arc's pinch to summarize. Nothing about the
/// page leaves the phone.
@MainActor
enum PageSummarizer {
    static var availability: SummaryAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .notSupported
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceOff
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unavailable
            }
        }
        #endif
        return .notSupported
    }

    /// Whether to show Summarize at all. It's shown while Apple Intelligence
    /// is switched off too, so people find out it's there.
    static var isOffered: Bool {
        availability != .notSupported
    }

    /// Whether the model writes in a language, from its code ("en", "zh-Hans").
    static func supportsLanguage(_ code: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let wanted = Locale.Language(identifier: code).languageCode else { return true }
            return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode == wanted }
        }
        #endif
        return false
    }
}

/// One summary being written, for the summary sheet.
@MainActor
@Observable
final class PageSummary {
    enum Phase: Equatable {
        /// Getting the page's text.
        case reading
        /// A long page, read in parts before the summary is written.
        case readingPart(Int, of: Int)
        /// The summary coming in.
        case writing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .reading
    /// The summary so far, as the model writes it.
    private(set) var text = ""
    /// True when a very long page was only read up to a point.
    private(set) var isPartial = false

    var isWorking: Bool {
        switch phase {
        case .reading, .readingPart, .writing:
            return true
        case .done, .failed:
            return false
        }
    }

    func run(on webView: WKWebView?) async {
        phase = .reading
        text = ""
        isPartial = false

        if let message = Self.message(for: PageSummarizer.availability) {
            phase = .failed(message)
            return
        }
        guard let webView else {
            phase = .failed("Open a page to summarize it.")
            return
        }
        let page = await ReaderMode.pageText(from: webView)
        let body = SummaryText.normalized(page.text)
        guard body.count >= 280 else {
            phase = .failed("There isn't enough text on this page to summarize.")
            return
        }
        // Checked up front: the model's own error for this changed name in iOS 27.
        if let language = SummaryText.dominantLanguage(of: body),
           !PageSummarizer.supportsLanguage(language) {
            phase = .failed(Self.message(for: .unsupportedLanguage))
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let wasCut = try await SummaryModel.summarize(
                    title: page.title,
                    text: body,
                    onPart: { part, total in
                        self.phase = .readingPart(part, of: total)
                    },
                    onText: { partial in
                        if self.phase != .writing { self.phase = .writing }
                        self.text = partial
                    }
                )
                isPartial = wasCut
                phase = SummaryText.parse(text).isEmpty ? .failed(Self.message(for: .other)) : .done
            } catch {
                // Closing the sheet cancels the summary; nothing to show then.
                guard !Task.isCancelled else { return }
                phase = .failed(Self.message(for: SummaryText.failure(for: error)))
            }
            return
        }
        #endif
        phase = .failed("Summaries need iOS 26 and Apple Intelligence.")
    }

    private static func message(for availability: SummaryAvailability) -> String? {
        switch availability {
        case .available:
            return nil
        case .notSupported:
            return "Summaries need an iPhone with Apple Intelligence, on iOS 26 or later."
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri to summarize pages."
        case .modelNotReady:
            return "Apple Intelligence is still getting ready on this iPhone. Try again in a little while."
        case .unavailable:
            return "Apple Intelligence isn't available right now. Try again later."
        }
    }

    private static func message(for failure: SummaryFailure) -> String {
        switch failure {
        case .tooLong:
            return "This page is too long to summarize."
        case .unsupportedLanguage:
            return "Summaries aren't available in this page's language yet."
        case .sensitive:
            return "Apple Intelligence couldn't summarize this page."
        case .busy:
            return "Apple Intelligence is busy. Try again in a moment."
        case .other:
            return "Couldn't summarize this page. Try again."
        }
    }
}

#if canImport(FoundationModels)
/// The on-device model at work. A long page doesn't fit in what the model
/// can read at once, so it's read in parts: short notes from each part,
/// then the summary written from the notes.
@available(iOS 26.0, *)
@MainActor
enum SummaryModel {
    /// Very long pages are read up to this many parts.
    static var maxParts: Int { 8 }

    private static var instructions: String {
        """
        You summarize web pages for someone reading on their phone. \
        Use only what the text says. Be brief, neutral and concrete. \
        Write in the same language as the text. \
        Don't add a title, an introduction or closing remarks.
        """
    }

    /// Writes the summary, handing it over as it comes in. Returns true if
    /// the page was too long to read in full.
    static func summarize(
        title: String,
        text: String,
        onPart: (Int, Int) -> Void,
        onText: (String) -> Void
    ) async throws -> Bool {
        let contextSize = SystemLanguageModel.default.contextSize
        let tokens = contextSize >= 2048 ? contextSize : 4096
        // Room for the page in one request: the whole context, less the
        // instructions, the prompt around the page and the answer, with a
        // margin because characters per token is only an estimate.
        let pageTokens = Double(tokens - 900) * 0.85
        let limit = max(Int(pageTokens * SummaryText.charactersPerToken(for: text)), 1_000)
        return try await summarize(title: title, text: text, limit: limit, onPart: onPart, onText: onText)
    }

    private static func summarize(
        title: String,
        text: String,
        limit: Int,
        onPart: (Int, Int) -> Void,
        onText: (String) -> Void
    ) async throws -> Bool {
        var parts = SummaryText.chunks(of: text, limit: limit)
        let wasCut = parts.count > maxParts
        if wasCut { parts = Array(parts.prefix(maxParts)) }

        if parts.count == 1 {
            do {
                try await write(from: parts[0], title: title, fromNotes: false, onText: onText)
                return false
            } catch let error where SummaryText.failure(for: error) == .tooLong && limit > 2_000 {
                // The estimate was off for this text: read it in smaller parts.
                return try await summarize(title: title, text: text, limit: limit / 2, onPart: onPart, onText: onText)
            }
        }

        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            onPart(index + 1, parts.count)
            let partNotes = try await takeNotes(on: part, title: title, part: index + 1, of: parts.count)
            notes += partNotes
        }
        try Task.checkCancellation()
        try await write(from: SummaryText.fitted(notes, limit: limit), title: title, fromNotes: true, onText: onText)
        return wasCut
    }

    /// Short notes on one part of a long page.
    private static func takeNotes(
        on chunk: String,
        title: String,
        part: Int,
        of total: Int,
        depth: Int = 0
    ) async throws -> [String] {
        let session = makeSession()
        let prompt = """
        This is part \(part) of \(total) of a web page titled "\(title)". \
        Write its most important facts as up to 5 short notes, one per line.

        \(chunk)
        """
        do {
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 300)
            let response = try await session.respond(to: prompt, options: options)
            return [response.content]
        } catch let error where SummaryText.failure(for: error) == .tooLong && depth < 2 {
            // Still too much for the model: take this part in halves.
            var notes: [String] = []
            for half in SummaryText.chunks(of: chunk, limit: max(chunk.count / 2, 500)) {
                let halfNotes = try await takeNotes(on: half, title: title, part: part, of: total, depth: depth + 1)
                notes += halfNotes
            }
            return notes
        }
    }

    /// The summary itself, streamed so it appears as it's written.
    private static func write(
        from source: String,
        title: String,
        fromNotes: Bool,
        onText: (String) -> Void
    ) async throws {
        let session = makeSession()
        let what = fromNotes ? "these notes from each part of a web page" : "this web page"
        let prompt = """
        Summarize \(what), titled "\(title)". \
        Start with one sentence that sums up the page. \
        Then write 3 to 5 bullet points with the most important details, \
        each starting with "- " and under 25 words.

        \(source)
        """
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 600)
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            onText(snapshot.content)
        }
    }

    /// A fresh session for each request, so nothing from one part counts
    /// against the next one's room.
    private static func makeSession() -> LanguageModelSession {
        // Summarizing news means passing on what the page says, so the
        // guardrails are the ones Apple provides for transforming text.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model) {
            Self.instructions
        }
    }
}
#endif

/// Why a summary failed, from the model's error.
enum SummaryFailure: Equatable {
    case tooLong
    case unsupportedLanguage
    case sensitive
    case busy
    case other
}

/// A summary split into its opening sentence and bullet points.
struct SummaryOutline: Equatable {
    var headline = ""
    var bullets: [String] = []

    var isEmpty: Bool { headline.isEmpty && bullets.isEmpty }
}

/// Text handling for summaries, kept apart from the model so it can be tested.
enum SummaryText {
    /// Tidies a page's text: trimmed lines, single spaces, at most one blank
    /// line in a row.
    static func normalized(_ text: String) -> String {
        var lines: [String] = []
        var lastWasBlank = true
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty {
                if !lastWasBlank { lines.append("") }
                lastWasBlank = true
            } else {
                lines.append(line)
                lastWasBlank = false
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// About how many characters make a token for the model, from Apple's
    /// guide: three to four in English or Spanish, one in Chinese, Japanese
    /// and Korean. Kept at the low end so pages fit.
    static func charactersPerToken(for text: String) -> Double {
        var total = 0
        var wide = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars.prefix(4_000) {
            total += 1
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                wide += 1
            case 0x0250...:
                nonLatin += 1
            default:
                break
            }
        }
        guard total > 0 else { return 3 }
        if Double(wide) / Double(total) > 0.3 { return 1 }
        if Double(nonLatin) / Double(total) > 0.3 { return 2 }
        return 3
    }

    /// Splits text into pieces of at most `limit` characters, breaking
    /// between paragraphs where it can, then between sentences, then words.
    static func chunks(of text: String, limit: Int) -> [String] {
        let limit = max(limit, 200)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        var result: [String] = []
        var current = ""
        var currentCount = 0
        for piece in pieces(of: trimmed, limit: limit) {
            let count = piece.count
            if currentCount == 0 {
                current = piece
                currentCount = count
            } else if currentCount + 2 + count <= limit {
                current += "\n\n" + piece
                currentCount += 2 + count
            } else {
                result.append(current)
                current = piece
                currentCount = count
            }
        }
        if currentCount > 0 { result.append(current) }
        return result
    }

    /// The text's paragraphs, with any longer than the limit cut up.
    private static func pieces(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        for rawParagraph in text.components(separatedBy: "\n\n") {
            let paragraph = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if paragraph.count <= limit {
                result.append(paragraph)
            } else {
                result += sentencePieces(of: paragraph, limit: limit)
            }
        }
        return result
    }

    private static func sentencePieces(of paragraph: String, limit: Int) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        if sentences.isEmpty { sentences = [paragraph] }

        var result: [String] = []
        var current = ""
        var currentCount = 0
        for sentence in sentences {
            let count = sentence.count
            if count > limit {
                if currentCount > 0 {
                    result.append(current)
                    current = ""
                    currentCount = 0
                }
                result += wordPieces(of: sentence, limit: limit)
            } else if currentCount + count <= limit {
                current += sentence
                currentCount += count
            } else {
                result.append(current)
                current = sentence
                currentCount = count
            }
        }
        if currentCount > 0 { result.append(current) }
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func wordPieces(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var currentCount = 0
        for rawWord in text.split(whereSeparator: \.isWhitespace) {
            var word = String(rawWord)
            // Text with no spaces (Chinese, Japanese) is cut where it must be.
            while word.count > limit {
                if currentCount > 0 {
                    result.append(current)
                    current = ""
                    currentCount = 0
                }
                let cut = word.index(word.startIndex, offsetBy: limit)
                result.append(String(word[..<cut]))
                word = String(word[cut...])
            }
            let count = word.count
            guard count > 0 else { continue }
            if currentCount == 0 {
                current = word
                currentCount = count
            } else if currentCount + 1 + count <= limit {
                current += " " + word
                currentCount += 1 + count
            } else {
                result.append(current)
                current = word
                currentCount = count
            }
        }
        if currentCount > 0 { result.append(current) }
        return result
    }

    /// Notes from each part, trimmed evenly if together they'd be too long.
    static func fitted(_ notes: [String], limit: Int) -> String {
        let joined = notes.joined(separator: "\n\n")
        guard joined.count > limit, !notes.isEmpty else { return joined }
        let share = max(limit / notes.count - 2, 80)
        return notes.map { String($0.prefix(share)) }.joined(separator: "\n\n")
    }

    /// The page's main language as a code like "en", if it's clear.
    static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(3_000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// Reads the summary, finished or still coming in, as its opening
    /// sentence and bullet points.
    static func parse(_ summary: String) -> SummaryOutline {
        var outline = SummaryOutline()
        for rawLine in summary.components(separatedBy: .newlines) {
            var line = rawLine.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines, and a bullet that has only its marker so far.
            guard !line.isEmpty, !bulletMarkers.contains(line) else { continue }

            if var body = bulletBody(of: line) {
                // The model sometimes doubles the marker ("• - point"). Only
                // symbols are stripped again, so "2024. …" keeps its year.
                while let marker = bulletMarkers.first(where: { body.hasPrefix($0 + " ") }) {
                    body = String(body.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
                }
                if !body.isEmpty && !bulletMarkers.contains(body) { outline.bullets.append(body) }
            } else if outline.bullets.isEmpty {
                outline.headline = outline.headline.isEmpty ? line : outline.headline + " " + line
            } else {
                outline.bullets.append(line)
            }
        }
        for label in ["Summary:", "TL;DR:", "TLDR:"]
        where outline.headline.lowercased().hasPrefix(label.lowercased()) {
            outline.headline = String(outline.headline.dropFirst(label.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return outline
    }

    private static let bulletMarkers: Set<String> = ["-", "•", "*", "–", "—"]

    private static func bulletBody(of line: String) -> String? {
        for marker in bulletMarkers where line.hasPrefix(marker + " ") {
            return String(line.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The summary as plain text, for Copy and Share.
    static func plainText(_ outline: SummaryOutline, url: URL?) -> String {
        var lines: [String] = []
        if !outline.headline.isEmpty { lines.append(outline.headline) }
        if !outline.bullets.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += outline.bullets.map { "• " + $0 }
        }
        if let url { lines += ["", url.absoluteString] }
        return lines.joined(separator: "\n")
    }

    /// Why the model failed. Matched by name, because iOS 27 replaced the
    /// error type iOS 26 throws (`LanguageModelSession.GenerationError`)
    /// with `LanguageModelError`, whose cases are named differently.
    static func failure(for error: Error) -> SummaryFailure {
        let description = (String(reflecting: error) + " " + error.localizedDescription)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if description.contains("contextwindow") || description.contains("contextsize") { return .tooLong }
        if description.contains("unsupportedlanguage") { return .unsupportedLanguage }
        if description.contains("guardrail") || description.contains("refusal") { return .sensitive }
        if description.contains("ratelimited") || description.contains("concurrentrequests") { return .busy }
        return .other
    }
}
