import Foundation

// MARK: - Target language

/// Languages the OCR text can be translated into. The model auto-detects the
/// source language, so only the target is configurable.
enum TranslationLanguage: String, CaseIterable {
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var displayName: String {
        switch self {
        case .chinese:  return L10n.lang == .zh ? "中文" : "Chinese"
        case .english:  return L10n.lang == .zh ? "英文" : "English"
        case .japanese: return L10n.lang == .zh ? "日文" : "Japanese"
        case .korean:   return L10n.lang == .zh ? "韩文" : "Korean"
        }
    }

    /// English name fed into the translation prompt.
    var promptName: String {
        switch self {
        case .chinese:  return "Simplified Chinese"
        case .english:  return "English"
        case .japanese: return "Japanese"
        case .korean:   return "Korean"
        }
    }
}

// MARK: - Provider kinds

/// AI translation providers. OpenAI / DeepSeek / Custom all speak the OpenAI
/// chat-completions wire format; Claude uses the Anthropic Messages API.
enum TranslationProviderKind: String, CaseIterable {
    case openai
    case deepseek
    case custom
    case claude

    var displayName: String {
        switch self {
        case .openai:   return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .custom:   return L10n.lang == .zh ? "自定义 (OpenAI 兼容)" : "Custom (OpenAI-compatible)"
        case .claude:   return "Claude"
        }
    }

    /// Claude needs a different request shape and SSE parser.
    var isClaude: Bool { self == .claude }

    var defaultEndpoint: String {
        switch self {
        case .openai:   return "https://api.openai.com/v1/chat/completions"
        case .deepseek: return "https://api.deepseek.com/v1/chat/completions"
        case .custom:   return ""
        case .claude:   return "https://api.anthropic.com/v1/messages"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai:   return "gpt-4o-mini"
        case .deepseek: return "deepseek-v4-flash"
        case .custom:   return ""
        case .claude:   return "claude-3-5-haiku-latest"
        }
    }

    /// Custom must supply its own endpoint; the rest ship a sensible default
    /// but still allow an override (e.g. a proxy).
    var endpointRequired: Bool { self == .custom }
}

// MARK: - Config model

struct TranslationConfig {
    var apiKey: String = ""
    var model: String = ""
    var endpoint: String = ""

    func resolvedModel(for kind: TranslationProviderKind) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultModel : trimmed
    }

    func resolvedEndpoint(for kind: TranslationProviderKind) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultEndpoint : trimmed
    }
}

// MARK: - Persistence

/// Stores one JSON-encoded config plus an enabled flag per provider in
/// UserDefaults — mirrors the upload `ProviderConfigStore` pattern.
enum TranslationConfigStore {
    private static func configKey(for kind: TranslationProviderKind) -> String {
        "translation.\(kind.rawValue).config"
    }

    private static func enabledKey(for kind: TranslationProviderKind) -> String {
        "translation.\(kind.rawValue).enabled"
    }

    static func load(_ kind: TranslationProviderKind) -> TranslationConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey(for: kind)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return TranslationConfig()
        }
        return TranslationConfig(
            apiKey: dict["apiKey"] ?? "",
            model: dict["model"] ?? "",
            endpoint: dict["endpoint"] ?? ""
        )
    }

    static func save(_ config: TranslationConfig, for kind: TranslationProviderKind) {
        let dict = [
            "apiKey": config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "endpoint": config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: configKey(for: kind))
        }
        NotificationCenter.default.post(name: .translationConfigDidChange, object: nil)
    }

    static func clear(_ kind: TranslationProviderKind) {
        UserDefaults.standard.removeObject(forKey: configKey(for: kind))
        NotificationCenter.default.post(name: .translationConfigDidChange, object: nil)
    }

    static func isEnabled(_ kind: TranslationProviderKind) -> Bool {
        let key = enabledKey(for: kind)
        if UserDefaults.standard.object(forKey: key) == nil {
            return isConfigured(kind)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, for kind: TranslationProviderKind) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(for: kind))
        NotificationCenter.default.post(name: .translationConfigDidChange, object: nil)
    }

    /// True when the saved config has the fields a request needs.
    static func isConfigured(_ kind: TranslationProviderKind) -> Bool {
        let cfg = load(kind)
        guard !cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind.endpointRequired {
            return !cfg.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Enabled AND configured — the providers shown in the OCR panel.
    static func isUsable(_ kind: TranslationProviderKind) -> Bool {
        isEnabled(kind) && isConfigured(kind)
    }

    static func usableKinds() -> [TranslationProviderKind] {
        TranslationProviderKind.allCases.filter { isUsable($0) }
    }
}

// MARK: - Target language preference

extension Defaults {
    static var translationTargetLanguage: TranslationLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: "translation.targetLanguage") ?? ""
            return TranslationLanguage(rawValue: raw) ?? .chinese
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "translation.targetLanguage")
        }
    }
}
