import Foundation

enum TranslationError: LocalizedError {
    case missingAPIKey
    case badEndpoint
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.lang == .zh ? "未配置 API Key" : "API key not configured"
        case .badEndpoint:
            return L10n.lang == .zh ? "接口地址无效" : "Invalid endpoint"
        case .badResponse:
            return L10n.lang == .zh ? "响应格式异常" : "Unexpected response"
        case let .http(code, body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "HTTP \(code)\(detail)"
        }
    }
}

/// Streams AI translations. OpenAI / DeepSeek / Custom share the OpenAI
/// chat-completions SSE format; Claude uses the Anthropic Messages SSE format.
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
