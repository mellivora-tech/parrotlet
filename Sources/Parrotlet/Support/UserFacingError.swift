import Foundation
import SwiftUI

/// 用户可见错误的统一模型：友好文案 + 可选引导动作 + 技术详情（仅日志，永不上屏）。
/// 任何界面不得直接渲染 Error.localizedDescription——必须经 present() 翻译。
struct UserFacingError: Equatable {
    enum Style: Equatable {
        case guidance   // 引导（未配置/凭据类）：蓝色 info，不是「错误」
        case failure    // 真失败：红色警告
    }

    enum Action: Equatable {
        case openSettings
    }

    var style: Style
    var message: String
    var action: Action?
    /// 技术详情（HTTP status/body 等），只进日志
    var detail: String

    /// 唯一的错误翻译入口。返回 nil = 不该上屏（如用户取消）。
    /// detail 在此落日志——调用方拿到的模型不含技术信息，想渲染错都难。
    static func present(_ error: Error, language: UILanguage) -> UserFacingError? {
        // Remote bodies and SSE payloads are untrusted input and may echo user content or credentials.
        // Only safe category/status details enter the persisted model and log.
        let detail = Self.logDetail(for: error)
        AppLog.log(.error, "error.present", ["detail": detail])

        guard let llmError = error as? LLMError else {
            return UserFacingError(style: .failure, message: L10n.s(.errorBadResponse, language),
                                   action: nil, detail: detail)
        }
        switch llmError {
        case .cancelled:
            return nil
        case .notConfigured:
            return UserFacingError(style: .guidance, message: L10n.s(.errorNotConfigured, language),
                                   action: .openSettings, detail: detail)
        case .http(let status, _):
            switch status {
            case 401, 403:
                return UserFacingError(style: .guidance, message: L10n.s(.errorInvalidKey, language),
                                       action: .openSettings, detail: detail)
            case 429:
                return UserFacingError(style: .failure, message: L10n.s(.errorRateLimited, language),
                                       action: nil, detail: detail)
            case 404:
                return UserFacingError(style: .guidance, message: L10n.s(.errorBadEndpoint, language),
                                       action: .openSettings, detail: detail)
            default:
                return UserFacingError(style: .failure, message: L10n.s(.errorServerBusy, language),
                                       action: nil, detail: detail)
            }
        case .network:
            return UserFacingError(style: .failure, message: L10n.s(.errorNetwork, language),
                                   action: nil, detail: detail)
        case .emptyResponse:
            return UserFacingError(style: .failure, message: L10n.s(.errorEmptyResponse, language),
                                   action: nil, detail: detail)
        case .malformedSSE:
            return UserFacingError(style: .failure, message: L10n.s(.errorBadResponse, language),
                                   action: nil, detail: detail)
        }
    }
}

extension UserFacingError {
    private static func logDetail(for error: Error) -> String {
        if let llmError = error as? LLMError {
            switch llmError {
            case .http(let status, _): return "HTTP \(status)"
            case .malformedSSE: return "Malformed SSE response"
            case .emptyResponse: return "Empty response"
            case .network: return "Network error"
            case .cancelled: return "Cancelled"
            case .notConfigured: return "Not configured"
            }
        }
        return error.localizedDescription
    }
}

/// 全局唯一错误横幅：图标 + 友好文案 + 可选引导按钮 + 关闭。
/// 不透明（.regularMaterial）——半透明 overlay 盖在输入栏上重影的教训（401 事故现场）。
/// 动作走 WindowOpenerBridge 而非 @Environment(\.openWindow)：浮层 NSPanel 的 SwiftUI 树
/// 不在 Scene 环境里（见 LookupPanelController），桥接器两处都能开设置窗
struct ErrorBanner: View {
    @Environment(AppEnvironment.self) private var env
    let error: UserFacingError
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: error.style == .guidance
                  ? "info.circle.fill" : "exclamationmark.triangle.fill")
            Text(error.message)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if error.action != nil {
                Button(env.t(.goToSettings)) {
                    WindowOpenerBridge.open(SceneID.settings)
                }
                .buttonStyle(.borderless)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.eaFont(10, .caption, weight: .semibold))
            }
            .buttonStyle(.borderless)
        }
        .font(.eaFont(12, .callout))
        .foregroundStyle(error.style == .guidance ? Color.accentColor : Color.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(error.style == .guidance ? Color.accentColor.opacity(0.3)
                        : Color.red.opacity(0.3), lineWidth: 1)
        }
    }
}
