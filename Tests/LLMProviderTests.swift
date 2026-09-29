import Foundation

let llmProviderTests: [TestCase] = [
    TestCase(name: "provider.request builds endpoint, auth, body, and max tokens") {
        let config = ProviderConfig(
            id: "deepseek",
            kind: .openAICompatible,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1/",
            model: "deepseek-chat",
            apiKey: "secret",
            maxTokens: 123)
        let request = try OpenAICompatibleProvider.makeRequest(
            config: config,
            messages: [.system("sys"), .user("hello")],
            options: .init(maxTokens: 456))

        try expectEqual(request.url?.absoluteString,
                        "https://api.deepseek.com/v1/chat/completions")
        try expectEqual(request.httpMethod, "POST")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        try expectEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = try JSONDecoder().decode(RequestBodyProbe.self, from: request.httpBody ?? Data())
        try expectEqual(body.model, "deepseek-chat")
        try expectEqual(body.stream, true)
        try expectEqual(body.maxTokens, 456)
        try expectEqual(body.messages.map(\.role), ["system", "user"])
    },

    TestCase(name: "provider.request falls back to provider max tokens") {
        let config = ProviderConfig(
            id: "x", kind: .openAICompatible, name: "X",
            baseURL: "https://api.example.com/v1", model: "m",
            apiKey: nil, maxTokens: 99)
        let request = try OpenAICompatibleProvider.makeRequest(
            config: config, messages: [], options: .standard)
        let body = try JSONDecoder().decode(RequestBodyProbe.self, from: request.httpBody ?? Data())
        try expectEqual(body.maxTokens, 99)
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    },

    TestCase(name: "provider.response limits are bounded") {
        try expectEqual(OpenAICompatibleProvider.maxEventBytes, 64 * 1024)
        try expectEqual(OpenAICompatibleProvider.maxContentBytes, 256 * 1024)
        try expectEqual(OpenAICompatibleProvider.maxResponseBytes, 64 * 1024)
        try expectEqual(OpenAICompatibleProvider.maxErrorBodyBytes, 16 * 1024)
    },

    TestCase(name: "provider.stream 胖信封不受线路字节误伤（DeepSeek 事故回归）") {
        // 每个 delta 的 JSON 信封 ~250B：300 个事件线路 ~100KB 但正文只有 300 字符。
        // 旧的整流 64KB 闸门会误杀这种正常长回复；现在只数正文
        let envelope = String(repeating: "p", count: 200)
        let event = "data: {\"id\":\"\(envelope)\",\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"
        let payload = Data(String(repeating: event, count: 300).utf8)
        try expect(payload.count > 64 * 1024, "线路字节必须超过旧闸门才能当回归")
        MockURLProtocol.reset { _ in .init(status: 200, data: payload) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)

        let output = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
        try expectEqual(output.count, 300, "正文应完整收到")
    },

    TestCase(name: "provider.stream rejects runaway content") {
        // 正文累计超 maxContentBytes 仍要拦：3000 个事件 × 100 字符 = 300KB 正文
        let chunk = String(repeating: "c", count: 100)
        let event = "data: {\"choices\":[{\"delta\":{\"content\":\"\(chunk)\"}}]}\n\n"
        let payload = Data(String(repeating: event, count: 3000).utf8)
        MockURLProtocol.reset { _ in .init(status: 200, data: payload) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)
        do {
            _ = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
            throw TestFailure(message: "正文超限应抛错", file: "LLMProviderTests", line: 118)
        } catch {
            try expect(error.localizedDescription.contains("exceeds"))
        }
    },

    TestCase(name: "provider.stream parses SSE through URLSession") {
        let payload = Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n".utf8)
        MockURLProtocol.reset { _ in .init(status: 200, data: payload) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)

        let output = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
        try expectEqual(output, "Hello")
        try expectEqual(MockURLProtocol.requests().count, 1)
    },

    TestCase(name: "provider.stream maps non-2xx to bounded HTTP error") {
        MockURLProtocol.reset { _ in .init(status: 401, data: Data("invalid key".utf8)) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)

        do {
            _ = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
            throw TestFailure(message: "401 应抛错", file: "LLMProviderTests", line: 72)
        } catch {
            let description = error.localizedDescription
            try expect(description.contains("HTTP 401"), "应保留状态码：\(description)")
            try expect(description.contains("invalid key"), "应保留截断后的错误体")
        }
    },

    TestCase(name: "provider.stream reports malformed SSE") {
        MockURLProtocol.reset { _ in .init(status: 200, data: Data("data: not-json\n\n".utf8)) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)
        do {
            _ = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
            throw TestFailure(message: "malformed SSE 应抛错", file: "LLMProviderTests", line: 92)
        } catch {
            try expect(error.localizedDescription.contains("流式响应解析失败"))
        }
    },

    TestCase(name: "provider.stream reports empty response") {
        MockURLProtocol.reset { _ in .init(status: 200, data: Data("data: [DONE]\n\n".utf8)) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)
        do {
            _ = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
            throw TestFailure(message: "空响应应抛错", file: "LLMProviderTests", line: 105)
        } catch {
            try expect(error.localizedDescription.contains("没有返回任何内容"))
        }
    },

    TestCase(name: "provider.stream rejects an oversized event") {
        let oversized = Data((0..<(70 * 1024)).map { _ in UInt8(ascii: "a") })
        MockURLProtocol.reset { _ in .init(status: 200, data: oversized) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)
        do {
            _ = try awaitAsync { try await provider.complete([.user("hi")], options: .standard) }
            throw TestFailure(message: "超限响应应抛错", file: "LLMProviderTests", line: 118)
        } catch {
            try expect(error.localizedDescription.contains("exceeds"))
        }
    },

    TestCase(name: "provider.stream stops upstream after consumer cancellation") {
        let json = #"{"choices":[{"delta":{"content":"a"}}]}"#
        let payload = Data(("data: \(json)\n\ndata: \(json)\n\n").utf8)
        MockURLProtocol.reset { _ in .init(status: 200, data: payload) }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)

        // Give the detached task a deterministic cancellation point before provider startup.
        let task: Task<Int, Never> = Task.detached {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return 0 }
            do {
                var received = 0
                for try await _ in provider.stream([.user("hi")], options: .standard) {
                    received += 1
                }
                return received
            } catch {
                return -1
            }
        }
        task.cancel()

        let received = try awaitAsync { await task.value }
        try expectEqual(received, 0, "消费任务取消后不应启动 upstream 请求")
    },

    TestCase(name: "provider.listModels parses model ids") {
        MockURLProtocol.reset { _ in
            .init(status: 200, data: Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8))
        }
        let provider = OpenAICompatibleProvider(
            config: ProviderConfig(id: "x", kind: .openAICompatible, name: "X",
                                   baseURL: "https://api.example.com/v1", model: "m"),
            session: MockURLProtocol.session)

        let models = try awaitAsync { try await provider.listModels() }
        try expectEqual(models, ["a", "b"])
    },
]

private struct RequestBodyProbe: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
    }
}

private final class ProviderMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var state = ProviderMockState()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> MockResponse)?

    struct MockResponse: Sendable {
        let status: Int
        let data: Data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(handler: @escaping @Sendable (URLRequest) -> MockResponse) {
        state = ProviderMockState()
        self.handler = handler
    }

    static func requests() -> [URLRequest] {
        state.requests()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let mock = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mock.data.isEmpty ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    enum Outcome {
        case success(T)
        case failure(Error)
    }

    var outcome: Outcome?
}

private func awaitAsync<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = AsyncResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.outcome = .success(try await operation()) }
        catch { box.outcome = .failure(error) }
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(10)
    while semaphore.wait(timeout: .now()) != .success && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let outcome = box.outcome else { throw TestFailure(message: "async test timed out", file: "LLMProviderTests", line: 198) }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}
