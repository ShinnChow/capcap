import AppKit
import ImageIO
@preconcurrency import Vision
import VisionKit

struct RecognizedTextToken: Equatable {
    let text: String
    /// Vision-normalized rectangle with bottom-left origin.
    let boundingBox: CGRect
}

struct RecognizedTextLine: Equatable {
    let text: String
    /// Vision-normalized rectangle with bottom-left origin.
    let boundingBox: CGRect
    let tokens: [RecognizedTextToken]

    init(text: String, boundingBox: CGRect, tokens: [RecognizedTextToken] = []) {
        self.text = text
        self.boundingBox = boundingBox
        self.tokens = tokens
    }
}

/// Apple OCR helpers. Live Text uses VisionKit where available; the fallback
/// path remains `VNRecognizeTextRequest` in accurate mode.
enum OCRService {
    private static let preferredRecognitionLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    ]

    /// Recognizes text in `image` and returns it as newline-joined lines,
    /// ordered top-to-bottom then left-to-right. Returns an empty string when
    /// nothing is found or the image cannot be decoded.
    static func recognize(
        image: NSImage,
        diagnosticID: String? = nil,
        source: String = "recognize"
    ) async -> String {
        let session = diagnosticID ?? makeDiagnosticID()
        let started = CFAbsoluteTimeGetCurrent()
        log(
            "recognize-begin",
            session: session,
            source: source,
            metadata: imageMetadata(image)
        )

        if let analysis = await analyzeText(
            image: image,
            diagnosticID: session,
            source: "\(source).live-text"
        ) {
            let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                log(
                    "recognize-end",
                    session: session,
                    source: source,
                    metadata: [
                        "path": "live-text",
                        "durationMs": durationMS(since: started),
                        "characters": transcript.count,
                    ]
                )
                return transcript
            }
            log(
                "recognize-live-text-empty",
                session: session,
                source: source,
                metadata: ["durationMs": durationMS(since: started)]
            )
        }

        let lines = await recognizeLines(
            image: image,
            diagnosticID: session,
            source: "\(source).vision-fallback"
        )
        let text = lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = lineMetadata(lines)
        metadata["path"] = "vision-fallback"
        metadata["durationMs"] = durationMS(since: started)
        metadata["characters"] = text.count
        log("recognize-end", session: session, source: source, metadata: metadata)
        return text
    }

    /// Runs the same system Live Text analyzer used by Preview. The returned
    /// analysis can be attached to `ImageAnalysisOverlayView` for native text
    /// selection, menus, and keyboard copy.
    static func analyzeText(
        image: NSImage,
        diagnosticID: String? = nil,
        source: String = "analyze-text"
    ) async -> ImageAnalysis? {
        let session = diagnosticID ?? makeDiagnosticID()
        let started = CFAbsoluteTimeGetCurrent()
        var metadata = imageMetadata(image)
        metadata["isSupported"] = ImageAnalyzer.isSupported
        guard ImageAnalyzer.isSupported else {
            metadata["durationMs"] = durationMS(since: started)
            log("live-text-unsupported", session: session, source: source, metadata: metadata)
            return nil
        }

        let configuration = ImageAnalyzer.Configuration(.text)
        log("live-text-begin", session: session, source: source, metadata: metadata)

        do {
            let analysis = try await ImageAnalyzer().analyze(
                image,
                orientation: .up,
                configuration: configuration
            )
            let hasText = analysis.hasResults(for: .text)
            let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata["durationMs"] = durationMS(since: started)
            metadata["hasText"] = hasText
            metadata["characters"] = transcript.count
            log("live-text-end", session: session, source: source, metadata: metadata)
            return hasText ? analysis : nil
        } catch {
            metadata["durationMs"] = durationMS(since: started)
            metadata["error"] = error.localizedDescription
            log("live-text-error", session: session, source: source, metadata: metadata)
            return nil
        }
    }

    /// Recognizes text in `image` and returns ordered text lines with their
    /// source rectangles so result panels can draw per-line copy targets.
    static func recognizeLines(
        image: NSImage,
        diagnosticID: String? = nil,
        source: String = "recognize-lines"
    ) async -> [RecognizedTextLine] {
        let session = diagnosticID ?? makeDiagnosticID()
        let started = CFAbsoluteTimeGetCurrent()
        var metadata = imageMetadata(image)
        metadata["recognitionLevel"] = "accurate"
        metadata["usesLanguageCorrection"] = true
        metadata["automaticallyDetectsLanguage"] = true
        metadata["recognitionLanguages"] = preferredRecognitionLanguages.joined(separator: ",")
        log("vision-lines-begin", session: session, source: source, metadata: metadata)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            metadata["durationMs"] = durationMS(since: started)
            log("vision-lines-cgimage-failed", session: session, source: source, metadata: metadata)
            return []
        }
        metadata["cgImage"] = "\(cgImage.width)x\(cgImage.height)"

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let assembleStarted = CFAbsoluteTimeGetCurrent()
                let lines = Self.assembleLines(observations)
                var completionMetadata = metadata
                completionMetadata["durationMs"] = durationMS(since: started)
                completionMetadata["assembleMs"] = durationMS(since: assembleStarted)
                completionMetadata["observations"] = observations.count
                completionMetadata.merge(lineMetadata(lines)) { _, new in new }
                log(
                    "vision-lines-end",
                    session: session,
                    source: source,
                    metadata: completionMetadata
                )
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Bias toward CJK + Latin scripts; auto-detect still kicks in for
            // anything outside this list.
            request.recognitionLanguages = preferredRecognitionLanguages
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                let performStarted = CFAbsoluteTimeGetCurrent()
                do {
                    try handler.perform([request])
                } catch {
                    // perform() failing means the completion handler never
                    // ran — resume here so the continuation isn't leaked.
                    var failureMetadata = metadata
                    failureMetadata["durationMs"] = durationMS(since: started)
                    failureMetadata["performMs"] = durationMS(since: performStarted)
                    failureMetadata["error"] = error.localizedDescription
                    log(
                        "vision-lines-error",
                        session: session,
                        source: source,
                        metadata: failureMetadata
                    )
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Orders observations into natural reading order. Vision bounding boxes
    /// are normalized with a bottom-left origin, so a larger `midY` means a
    /// higher line on screen.
    private static func assembleLines(_ observations: [VNRecognizedTextObservation]) -> [RecognizedTextLine] {
        let sorted = observations.sorted { a, b in
            // Treat lines whose vertical centers are close as the same row and
            // fall back to horizontal order.
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.012 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let rawText = candidate.string
                guard let contentRange = rawText.nonWhitespaceRange else { return nil }
                let text = String(rawText[contentRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedTextLine(
                    text: text,
                    boundingBox: observation.boundingBox,
                    tokens: Self.tokens(in: rawText, contentRange: contentRange, candidate: candidate)
                )
            }
    }

    private static func tokens(
        in rawText: String,
        contentRange: Range<String.Index>,
        candidate: VNRecognizedText
    ) -> [RecognizedTextToken] {
        var tokens: [RecognizedTextToken] = []
        var index = contentRange.lowerBound

        while index < contentRange.upperBound {
            if rawText[index].isWhitespace {
                index = rawText.index(after: index)
                continue
            }

            let start = index
            if rawText[index].isCJKLike {
                index = rawText.index(after: index)
            } else {
                repeat {
                    index = rawText.index(after: index)
                } while index < contentRange.upperBound
                    && !rawText[index].isWhitespace
                    && !rawText[index].isCJKLike
            }

            let range = start..<index
            guard let observation = try? candidate.boundingBox(for: range) else { continue }
            let text = String(rawText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            tokens.append(RecognizedTextToken(text: text, boundingBox: observation.boundingBox))
        }

        return tokens
    }

    private static func makeDiagnosticID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private static func log(
        _ event: String,
        session: String,
        source: String,
        metadata: [String: Any] = [:]
    ) {
        var fields = metadata
        fields["session"] = session
        fields["source"] = source
        DiagnosticLog.log("ocr", event, metadata: fields)
    }

    private static func imageMetadata(_ image: NSImage) -> [String: Any] {
        var metadata: [String: Any] = [
            "imageSize": diagnosticSize(image.size),
            "representations": image.representations.count,
        ]
        let representationSizes = image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
        if !representationSizes.isEmpty {
            metadata["representationSizes"] = representationSizes.joined(separator: ",")
        }
        return metadata
    }

    private static func lineMetadata(_ lines: [RecognizedTextLine]) -> [String: Any] {
        [
            "lines": lines.count,
            "tokens": lines.reduce(0) { $0 + $1.tokens.count },
            "lineCharacters": lines.reduce(0) { $0 + $1.text.count },
        ]
    }

    private static func diagnosticSize(_ size: NSSize) -> String {
        "w=\(diagnosticNumber(size.width)) h=\(diagnosticNumber(size.height))"
    }

    private static func diagnosticNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func durationMS(since start: CFAbsoluteTime) -> String {
        String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

private extension String {
    var nonWhitespaceRange: Range<String.Index>? {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
              let last = lastIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        return first..<index(after: last)
    }
}

private extension Character {
    var isCJKLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana + Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF: // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }
}
