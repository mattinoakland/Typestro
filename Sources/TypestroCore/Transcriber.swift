import Foundation

public enum TranscriptionError: Error {
    case http(Int, String)
    case badResponse

    public var summary: String {
        switch self {
        case .http(401, _): "OpenAI rejected the API key"
        case .http(429, _): "OpenAI rate limit or quota reached"
        case .http(let code, _): "OpenAI error \(code)"
        case .badResponse: "Unexpected reply from OpenAI"
        }
    }
}

/// OpenAI speech-to-text (/v1/audio/transcriptions) with GPT Transcribe, which replaces Whisper:
/// more accurate and cheaper.
public struct Transcriber: Sendable {
    static let model = "gpt-transcribe"

    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Transcribes an audio file. `prompt` is the text already in the box before the cursor, which helps
    /// the model with names, spelling and style.
    public func transcribe(_ file: URL, prompt: String?) async throws -> String {
        let boundary = "typestro-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", Self.model)
        field("response_format", "json")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
        guard http.statusCode == 200 else {
            throw TranscriptionError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }
}
