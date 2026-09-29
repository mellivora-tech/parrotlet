import Foundation

/// OpenAI 兼容协议 provider（DeepSeek / GLM / Kimi / Ollama / OpenAI…）。
/// POST {baseURL}/chat/completions，SSE 流式。
struct OpenAICompatibleProvider: LLMProvider {
    static let maxEventBytes = 64 * 1024
    /// 正文累计上限：只数解码后的内容字节，不数 SSE 线路字节——
    /// 每个 token 的 JSON 信封约 250B，若按线路计 64KB 只够 ~230 token，
    /// 正常长回复会被误杀（malformedSSE 事故）。256KB 正文 ≈ 6 万+ token，纯防失控
    static let maxContentBytes = 256 * 1024
    /// 非流式 GET（/models）的整体响应上限
    static let maxResponseBytes = 64 * 1024
    static let maxErrorBodyBytes = 16 * 1024

    let id: String

    private let config: ProviderConfig
    private let session: URLSession

    init(config: ProviderConfig, session: URLSession = Self.defaultSession) {
        self.config = config
        self.id = config.id
        self.session = session
    }

    private static let defaultSession: URLSession = {
        URLSession(configuration: defaultConfiguration)
    }()

    /// `request` is URLSession's idle timeout; `resource` bounds the whole stream.
    private static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return configuration
    }

    func stream(_ messages: [ChatMessage], options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(config: config, messages: messages, options: options)
                    let (bytes, response) = try await session.bytes(for: request)

                    // 关键：bytes(for:) 对 4xx/5xx 不抛错，必须手动查状态码并读全错误体
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.network("非 HTTP 响应")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        var body = Data()
                        outer: for try await line in bytes.lines {
                            let lineBytes = Data(line.utf8)
                            if body.count + lineBytes.count > Self.maxErrorBodyBytes { break }
                            body.append(lineBytes)
                            body.append(0x0A)
                        }
                        continuation.finish(throwing: LLMError.http(
                            status: http.statusCode,
                            body: String(decoding: body.prefix(500), as: UTF8.self)))
                        return
                    }

                    let parser = SSEParser()
                    var receivedAny = false
                    var contentBytes = 0

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.utf8.count + 1 <= Self.maxEventBytes else {
                            throw LLMError.malformedSSE("SSE event exceeds \(Self.maxEventBytes) bytes")
                        }
                        if let output = parser.consume(line),
                           let delta = try Self.handle(output) {
                            receivedAny = true
                            contentBytes += delta.utf8.count
                            guard contentBytes <= Self.maxContentBytes else {
                                throw LLMError.malformedSSE("SSE content exceeds \(Self.maxContentBytes) bytes")
                            }
                            continuation.yield(delta)
                        }
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if !receivedAny { throw LLMError.emptyResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: LLMError.network(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 请求构造

    static func makeRequest(
        config: ProviderConfig, messages: [ChatMessage], options: LLMRequestOptions
    ) throws -> URLRequest {
        let url: URL
        do {
            url = try APIEndpoint.endpoint(baseURL: config.baseURL, path: "/chat/completions")
        } catch let error as APIEndpoint.ValidationError {
            throw LLMError.notConfigured(error.message)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: config.model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: true,
            maxTokens: options.maxTokens ?? config.maxTokens ?? 4096
        ))
        return request
    }

    private struct RequestBody: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    // MARK: - 模型列表

    /// GET {baseURL}/models（OpenAI 兼容协议各家一致：DeepSeek / GLM / Kimi / Ollama）
    func listModels() async throws -> [String] {
        let url: URL
        do {
            url = try APIEndpoint.endpoint(baseURL: config.baseURL, path: "/models")
        } catch let error as APIEndpoint.ValidationError {
            throw LLMError.notConfigured(error.message)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.network("非 HTTP 响应") }
        guard (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                if body.count >= Self.maxErrorBodyBytes { break }
                body.append(byte)
            }
            throw LLMError.http(status: http.statusCode,
                                body: String(decoding: body.prefix(500), as: UTF8.self))
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.maxResponseBytes else {
                throw LLMError.malformedSSE("Models response exceeds \(Self.maxResponseBytes) bytes")
            }
        }

        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data).data.map(\.id).sorted()
        } catch let error as DecodingError {
            throw LLMError.malformedSSE(describeDecodingError(error))
        }
    }

    // MARK: - 响应解析

    /// SSE 事件 → 文本增量；返回 nil 表示本事件无正文（首帧 role、keep-alive 等）
    static func handle(_ output: SSEParser.Output) throws -> String? {
        switch output {
        case .done:
            return nil // 结束由流自然收尾表达
        case .data(let json):
            guard let data = json.data(using: .utf8) else {
                throw LLMError.malformedSSE(json)
            }
            do {
                let chunk = try JSONDecoder().decode(Chunk.self, from: data)
                // 只取 delta.content；显式忽略 reasoning_content（DeepSeek R1 系）等字段
                return chunk.choices?.first?.delta?.content
            } catch let error as DecodingError {
                // 解码错误详情放前面（LLMError 描述会截断，错误类型+路径才是定位关键）
                throw LLMError.malformedSSE("\(describeDecodingError(error))｜\(json.prefix(300))")
            }
        }
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
        }
        let choices: [Choice]?
    }
}
