import Foundation

/// OpenAI 兼容 `/chat/completions` SSE 客户端。未配置时不发网络。
public struct OpenAICompatibleProvider: ExplainProvider {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func stream(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.send(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(
        _ request: ExplainRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty, !modelName.isEmpty else {
            throw ExplainError.notConfigured
        }

        guard let root = URL(string: base) else {
            throw URLError(.badURL)
        }
        let endpoint = root.appending(path: "chat/completions")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: modelName,
                stream: true,
                messages: Self.messages(for: request)))

        // SSE：只处理 `data: ` 行；`[DONE]` 结束；JSON 缺字段或非 JSON 跳过。
        let (bytes, response) = try await session.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse,
           !(200 ... 299).contains(http.statusCode)
        {
            throw ExplainError.httpStatus(http.statusCode)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                return
            }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let content = chunk.choices?.first?.delta?.content
            else { continue }
            continuation.yield(content)
        }
    }

    private static func messages(for request: ExplainRequest) -> [ChatCompletionRequest.Message] {
        var result = [
            ChatCompletionRequest.Message(
                role: "user",
                content: """
                Explain the selected code.

                File: \(request.path)

                Selection:
                \(request.selectedText)

                Surrounding context:
                \(request.surroundingText)

                File diff:
                \(request.fileDiff)
                """)
        ]
        result.append(contentsOf: request.history.map {
            ChatCompletionRequest.Message(role: $0.role.rawValue, content: $0.text)
        })
        return result
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct StreamChunk: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let delta: Delta?
        struct Delta: Decodable {
            let content: String?
        }
    }
}
