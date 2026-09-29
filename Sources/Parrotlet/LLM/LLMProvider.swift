import Foundation

// MARK: - 消息与选项

struct ChatMessage: Codable, Sendable, Hashable {
    enum Role: String, Codable, Sendable, Hashable {
        case system, user, assistant
    }

    var role: Role
    var content: String

    static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
}

struct LLMRequestOptions: Sendable, Equatable {
    var maxTokens: Int?

    static let standard = LLMRequestOptions(maxTokens: nil)
}

// MARK: - 错误

enum LLMError: Error, Sendable {
    case http(status: Int, body: String)
    case emptyResponse
    case malformedSSE(String)
    case network(String)
    case cancelled
    case notConfigured(String)
}

extension LLMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            let hint: String
            switch status {
            case 401, 403: hint = "API key 无效或没有权限，请检查设置"
            case 429: hint = "请求过于频繁或额度不足"
            case 404: hint = "接口地址或模型名可能有误（baseURL 需含版本前缀）"
            default: hint = "服务端返回错误"
            }
            let preview = body.isEmpty ? "" : "｜\(body.prefix(200))"
            return "HTTP \(status)：\(hint)\(preview)"
        case .emptyResponse:
            return "模型没有返回任何内容，请重试或换一个模型"
        case .malformedSSE(let line):
            return "流式响应解析失败：\(line.prefix(400))"
        case .network(let message):
            return "网络错误：\(message)"
        case .cancelled:
            return "已取消"
        case .notConfigured(let message):
            return message
        }
    }
}

// MARK: - 解码错误描述

/// DecodingError.localizedDescription 是著名的「缺信息」——手动拆出错误类型 + codingPath。
func describeDecodingError(_ error: DecodingError) -> String {
    let path: String
    let detail: String
    switch error {
    case .typeMismatch(let type, let ctx):
        path = ctx.codingPath.pathString
        detail = "类型不符，期望 \(type)"
    case .valueNotFound(let type, let ctx):
        path = ctx.codingPath.pathString
        detail = "意外 null，期望 \(type)"
    case .keyNotFound(let key, let ctx):
        path = (ctx.codingPath + [key]).pathString
        detail = "缺少字段"
    case .dataCorrupted(let ctx):
        path = ctx.codingPath.pathString
        detail = ctx.debugDescription
    @unknown default:
        path = error.localizedDescription
        detail = ""
    }
    return "\(path)：\(detail)"
}

extension [CodingKey] {
    var pathString: String {
        map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
}

// MARK: - Provider 协议

/// 传输统一走 SSE 流式接口（一次性补全 = 聚合流，省一半代码）。
protocol LLMProvider: Sendable {
    var id: String { get }

    /// 流式输出文本增量。取消（Task.cancel / 流终止）会级联取消底层 URLSession 请求。
    func stream(_ messages: [ChatMessage], options: LLMRequestOptions) -> AsyncThrowingStream<String, Error>

    /// 拉取可用模型 id 列表（GET /models），供设置页填完 API Key 后选择
    func listModels() async throws -> [String]
}

extension LLMProvider {
    /// 一次性补全
    func complete(_ messages: [ChatMessage], options: LLMRequestOptions) async throws -> String {
        var out = ""
        for try await delta in stream(messages, options: options) {
            out += delta
        }
        return out
    }
}
