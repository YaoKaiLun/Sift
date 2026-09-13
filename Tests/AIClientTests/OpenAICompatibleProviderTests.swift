import XCTest
@testable import AIClient

final class OpenAICompatibleProviderTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testChatCompletionsURLAcceptsRootOrFullPath() {
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: "https://api.example.com/v1")?.absoluteString,
            "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: "https://api.example.com/v1/")?.absoluteString,
            "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(
            OpenAICompatibleProvider.chatCompletionsURL(from: "https://api.example.com/v1/chat/completions")?.absoluteString,
            "https://api.example.com/v1/chat/completions")
    }

    func testStreamsDeltaContentUntilDone() async throws {
        StubURLProtocol.responseBody = Data("""
        data: {"choices":[{"delta":{"content":"Hel"}}]}
        data: {"choices":[{"delta":{"content":"lo"}}]}
        data: [DONE]
        """.utf8)

        let chunks = try await collect(configuredProvider().stream(Self.sampleRequest))
        XCTAssertEqual(chunks, ["Hel", "lo"])
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testEmptyConfigurationDoesNotRequest() async {
        await assertNotConfigured(baseURL: "", apiKey: "sk-test", model: "gpt-test")
        await assertNotConfigured(baseURL: "   ", apiKey: "sk-test", model: "gpt-test")
        await assertNotConfigured(baseURL: "https://api.example.com/v1", apiKey: "", model: "gpt-test")
        await assertNotConfigured(baseURL: "https://api.example.com/v1", apiKey: "  \n", model: "gpt-test")
        await assertNotConfigured(baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "")
        await assertNotConfigured(baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: " \t")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testNon2xxResponseThrowsWithoutYielding() async {
        StubURLProtocol.responseStatusCode = 429
        StubURLProtocol.responseBody = Data("""
        {"error":{"message":"Rate limit exceeded"}}
        """.utf8)

        do {
            _ = try await collect(configuredProvider().stream(Self.sampleRequest))
            XCTFail("expected ExplainError.httpStatus")
        } catch ExplainError.httpStatus(429) {
            // 预期：4xx 以 HTTP 状态错误结束流，不 yield 内容
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNonJSONLinesAreSkipped() async throws {
        StubURLProtocol.responseBody = Data("""
        : keep-alive
        data: not-json
        event: ping
        data: {"choices":[{"delta":{"role":"assistant"}}]}
        data: {"choices":[{"delta":{"content":"ok"}}]}
        data: [DONE]
        """.utf8)

        let chunks = try await collect(configuredProvider().stream(Self.sampleRequest))
        XCTAssertEqual(chunks, ["ok"])
    }

    func testMemoryKeychainRoundTrip() throws {
        let store = MemoryKeychain()
        XCTAssertNil(try store.get("api-key"))
        try store.set("sk-test", account: "api-key")
        XCTAssertEqual(try store.get("api-key"), "sk-test")
        try store.delete("api-key")
        XCTAssertNil(try store.get("api-key"))
    }

    func testSystemKeychainMissingItemIsNilNotError() throws {
        let store = SystemKeychain(service: "app.sift.test.\(UUID().uuidString)")
        XCTAssertNil(try store.get("missing-account"))
    }

    private func configuredProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-test",
            model: "gpt-test",
            session: session)
    }

    private func assertNotConfigured(baseURL: String, apiKey: String, model: String) async {
        let provider = OpenAICompatibleProvider(
            baseURL: baseURL, apiKey: apiKey, model: model, session: session)
        do {
            _ = try await collect(provider.stream(Self.sampleRequest))
            XCTFail("expected ExplainError.notConfigured")
        } catch ExplainError.notConfigured {
            // 预期：未配置时立即失败
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private static let sampleRequest = ExplainRequest(
        path: "a.swift",
        selectedText: "let x = 1",
        surroundingText: "let x = 1\n",
        fileDiff: "+let x = 1",
        history: [])
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        var requests: [URLRequest] = []
        var responseBody = Data()
        var responseStatusCode = 200
        let lock = NSLock()
    }

    private static let state = State()

    static var requests: [URLRequest] {
        state.lock.withLock { state.requests }
    }

    static var requestCount: Int {
        state.lock.withLock { state.requests.count }
    }

    static var responseBody: Data {
        get { state.lock.withLock { state.responseBody } }
        set { state.lock.withLock { state.responseBody = newValue } }
    }

    static var responseStatusCode: Int {
        get { state.lock.withLock { state.responseStatusCode } }
        set { state.lock.withLock { state.responseStatusCode = newValue } }
    }

    static func reset() {
        state.lock.withLock {
            state.requests = []
            state.responseBody = Data()
            state.responseStatusCode = 200
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.withLock { Self.state.requests.append(request) }
        let body = Self.responseBody
        let statusCode = Self.state.lock.withLock { Self.state.responseStatusCode }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.example.com/")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
