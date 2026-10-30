import Foundation
import Security

public enum ClaudeError: Error {
    case http(Int, String)
    case refusal
    case empty(String?)
    case badResponse

    public var summary: String {
        switch self {
        case .http(401, _): "Claude rejected the API key"
        case .http(let code, _): "Claude API error \(code)"
        case .refusal: "Claude declined the request"
        case .empty: "Empty reply from Claude"
        case .badResponse: "Unexpected reply from Claude"
        }
    }
}

/// Minimal Messages API client returning JSON that matches a schema (structured outputs).
public struct ClaudeClient: Sendable {
    public let apiKey: String
    public let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    private struct Message: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    /// Opus, Fable and Sonnet 5.5 can re-run a declined request on another model server-side.
    private var supportsDefaultFallback: Bool {
        model.hasPrefix("claude-opus") || model.hasPrefix("claude-fable") || model == "claude-sonnet-5-5"
    }

    public func structured<T: Decodable>(
        _ type: T.Type,
        system: String,
        user: String,
        schema: [String: Any],
        effort: String = "low",
        maxTokens: Int = 4000,
        timeout: TimeInterval = 15
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        // Haiku can skip thinking, which makes the as-you-type checks noticeably faster.
        // Opus and Sonnet 5.5 can't turn it off; low effort keeps it short.
        if model.hasPrefix("claude-haiku") {
            body["thinking"] = ["type": "disabled"]
        }
        if supportsDefaultFallback {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        guard http.statusCode == 200 else {
            throw ClaudeError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        if message.stop_reason == "refusal" { throw ClaudeError.refusal }
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw ClaudeError.empty(message.stop_reason) }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

/// API keys live in the login keychain, never in a file.
public enum Keychain {
    static let service = "com.mattmoglia.typestro"
    public static let anthropic = "anthropic-api-key"
    public static let openAI = "openai-api-key"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read(_ account: String = anthropic) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ value: String, _ account: String = anthropic) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
