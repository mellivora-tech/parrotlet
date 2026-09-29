import Foundation

/// Provider Base URL 的唯一解析/规范化入口。
/// 规则：
/// - 只接受 HTTP(S)；
/// - 远程 endpoint 必须使用 HTTPS；
/// - 明文 HTTP 只允许 loopback 本地服务（例如 Ollama）；
/// - 拒绝 userinfo / query / fragment；
/// - 统一去掉 trailing slash，再拼接 API path。
enum APIEndpoint {
    struct Validated: Equatable {
        let url: URL
        let isLocal: Bool
    }

    enum ValidationError: Error, Equatable {
        case empty
        case invalid
        case unsupportedScheme
        case insecureRemote
        case unsupportedComponents

        var message: String {
            switch self {
            case .empty: "Base URL 不能为空"
            case .invalid: "Base URL 无效"
            case .unsupportedScheme: "Base URL 只支持 HTTP(S)"
            case .insecureRemote: "远程服务必须使用 HTTPS；明文 HTTP 仅允许本机地址"
            case .unsupportedComponents: "Base URL 不能包含用户名、密码、query 或 fragment"
            }
        }

        /// 上屏文案走 L10n（message 仅日志/兼容用）
        var l10nKey: L10n.Key {
            switch self {
            case .empty: .endpointEmpty
            case .invalid: .endpointInvalid
            case .unsupportedScheme: .endpointScheme
            case .insecureRemote: .endpointInsecure
            case .unsupportedComponents: .endpointComponents
            }
        }
    }

    static func validate(_ rawValue: String) throws -> Validated {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard var components = URLComponents(string: trimmed) else { throw ValidationError.invalid }

        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { throw ValidationError.unsupportedScheme }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ValidationError.unsupportedComponents
        }
        guard let host = components.host, !host.isEmpty else { throw ValidationError.invalid }

        let isLocal = isLoopback(host: host)
        if scheme == "http", !isLocal { throw ValidationError.insecureRemote }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path

        guard let url = components.url else { throw ValidationError.invalid }
        return Validated(url: url, isLocal: isLocal)
    }

    static func endpoint(baseURL: String, path: String) throws -> URL {
        let validated = try validate(baseURL)
        guard path.hasPrefix("/") else { throw ValidationError.invalid }
        var components = URLComponents(url: validated.url, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path += path
        guard let url = components.url else { throw ValidationError.invalid }
        return url
    }

    static func isLoopback(host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered == "::1" || lowered == "[::1]" { return true }
        guard lowered.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              lowered.split(separator: ".").first == "127" else { return false }
        return lowered.split(separator: ".").dropFirst().allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isNumber)
        }
    }
}
