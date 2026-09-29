import Foundation
import AppKit

/// LLM 门面：按 activeProvider 构造 provider 分发；请求期间抑制 App Nap。
@MainActor
@Observable
final class LLMService {
    private let configStore: ConfigStore

    /// 测试挂钩：非 nil 时 stream() 直接返回其产物，不碰网络/provider。仅测试用
    var streamOverride: (([ChatMessage]) -> AsyncThrowingStream<String, Error>)?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    var activeProviderName: String {
        configStore.value.activeProvider?.name ?? L10n.s(.notConfigured, uiLanguage)
    }

    private var uiLanguage: UILanguage { configStore.value.language.resolved }

    func stream(
        _ messages: [ChatMessage],
        options: LLMRequestOptions = .standard
    ) -> AsyncThrowingStream<String, Error> {
        if let streamOverride { return streamOverride(messages) }
        let provider: any LLMProvider
        do {
            provider = try makeProvider()
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        // 抑制 App Nap：后台菜单栏 app 的长流式请求可能被系统挂起
        // token 本身线程安全，@Sendable 闭包捕获需要 nonisolated(unsafe) 安抚编译器
        nonisolated(unsafe) let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Parrotlet LLM streaming")

        let upstream = provider.stream(messages, options: options)
        let providerName = configStore.value.activeProvider?.name ?? "none"
        AppLog.log(.info, "llm.streamBegin", ["provider": providerName])
        return AsyncThrowingStream { (continuation: AsyncThrowingStream<String, Error>.Continuation) in
            let started = Date()
            let task = Task {
                do {
                    for try await delta in upstream {
                        continuation.yield(delta)
                    }
                    AppLog.log(.info, "llm.streamEnd",
                               ["ms": Int(Date().timeIntervalSince(started) * 1000)])
                    continuation.finish()
                } catch {
                    AppLog.log(.warn, "llm.streamFail",
                               ["ms": Int(Date().timeIntervalSince(started) * 1000),
                                "error": "\(error)"])
                    continuation.finish(throwing: error)
                }
            }
            // 正常结束、出错、下游取消都会走到这里，统一归还 activity
            continuation.onTermination = { _ in
                task.cancel()
                ProcessInfo.processInfo.endActivity(activity)
            }
        }
    }

    /// 一次性补全
    func complete(
        _ messages: [ChatMessage],
        options: LLMRequestOptions = .standard
    ) async throws -> String {
        var out = ""
        for try await delta in stream(messages, options: options) {
            out += delta
        }
        return out
    }

    private func makeProvider() throws -> any LLMProvider {
        guard let config = configStore.value.activeProvider else {
            throw LLMError.notConfigured(L10n.s(.configureProviderFirst, uiLanguage))
        }
        return OpenAICompatibleProvider(config: config)
    }
}
