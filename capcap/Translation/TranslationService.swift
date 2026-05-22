import Foundation

enum TranslationError: LocalizedError {
    case missingAPIKey
    case badEndpoint
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.translationErrMissingAPIKey
        case .badEndpoint:
            return L10n.translationErrBadEndpoint
        case .badResponse:
            return L10n.translationErrBadResponse
        case let .http(code, body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "HTTP \(code)\(detail)"
        }
    }
}

/// Streams translations. OpenAI / DeepSeek / Custom share the OpenAI
/// chat-completions SSE format; Claude uses Anthropic Messages SSE; DeepL
/// returns a single JSON payload that is yielded as one chunk.
enum TranslationService {

    /// Yields translated text deltas as they arrive. Cancelling the consuming
    /// task cancels the underlying network request.
    static func stream(
        text: String,
        target: TranslationLanguage,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    if kind.isDeepL {
                        let translated = try await translateWithDeepL(text: text, target: target, config: config)
                        if !translated.isEmpty {
                            continuation.yield(translated)
                        }
                        continuation.finish()
                        return
                    }

                    let request = try buildRequest(text: text, target: target, kind: kind, config: config)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw TranslationError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 600 { break }
                        }
                        throw TranslationError.http(http.statusCode, body)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = kind.isClaude
                            ? parseClaudeDelta(data)
                            : parseOpenAIDelta(data) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Sends a tiny translation request to confirm the API key, endpoint and
    /// model actually work. Returns `nil` on success, or the failure reason.
    static func verify(
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) async -> Error? {
        do {
            for try await _ in stream(text: "hello", target: .chinese, kind: kind, config: config) {
                return nil   // first delta arrived — credentials work
            }
            return nil       // finished without error
        } catch {
            return error
        }
    }

    // MARK: - Request building

    private static func systemPrompt(for target: TranslationLanguage) -> String {
        """
        You are a professional translation engine. Translate the text the user \
        provides into \(target.promptName). If the text is already written in \
        \(target.promptName), translate it into English instead. Output only the \
        final translation — no explanations, no notes, no quotation marks, no \
        language labels. Preserve the original line breaks.
        """
    }

    private static func buildRequest(
        text: String,
        target: TranslationLanguage,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard let url = URL(string: config.resolvedEndpoint(for: kind)),
              url.scheme != nil else {
            throw TranslationError.badEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let model = config.resolvedModel(for: kind)
        let system = systemPrompt(for: target)
        let body: [String: Any]

        if kind.isClaude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 4096,
                "temperature": 0.3,
                "stream": true,
                "system": system,
                "messages": [["role": "user", "content": text]],
            ]
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "temperature": 0.3,
                "stream": true,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - DeepL

    private struct DeepLTranslationResult {
        let text: String
        let detectedSourceLanguage: String?
    }

    private static func translateWithDeepL(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> String {
        let result = try await requestDeepLTranslation(text: text, target: target, config: config)
        if target != .english,
           deepLSourceMatchesTarget(result.detectedSourceLanguage, target: target) {
            let fallback = try await requestDeepLTranslation(text: text, target: .english, config: config)
            return fallback.text
        }
        return result.text
    }

    private static func requestDeepLTranslation(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> DeepLTranslationResult {
        let request = try buildDeepLRequest(text: text, target: target, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.http(http.statusCode, String(body.prefix(600)))
        }
        return try parseDeepLResponse(data)
    }

    private static func buildDeepLRequest(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard let url = URL(string: config.resolvedEndpoint(for: .deepl)),
              url.scheme != nil else {
            throw TranslationError.badEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "text": [text],
            "target_lang": target.deepLTargetCode,
            "preserve_formatting": true,
        ]

        let model = config.resolvedModel(for: .deepl)
        if !model.isEmpty {
            body["model_type"] = model
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseDeepLResponse(_ data: Data) throws -> DeepLTranslationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String else {
            throw TranslationError.badResponse
        }
        return DeepLTranslationResult(
            text: text,
            detectedSourceLanguage: first["detected_source_language"] as? String
        )
    }

    private static func deepLSourceMatchesTarget(
        _ sourceLanguage: String?,
        target: TranslationLanguage
    ) -> Bool {
        guard let sourceLanguage else { return false }
        return deepLBaseLanguage(sourceLanguage) == deepLBaseLanguage(target.deepLTargetCode)
    }

    private static func deepLBaseLanguage(_ code: String) -> String {
        code.uppercased().split(separator: "-").first.map(String.init) ?? code.uppercased()
    }

    // MARK: - SSE parsing

    /// OpenAI chunk: `{ "choices": [ { "delta": { "content": "…" } } ] }`
    private static func parseOpenAIDelta(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Claude chunk: `{ "type": "content_block_delta", "delta": { "text": "…" } }`
    private static func parseClaudeDelta(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
