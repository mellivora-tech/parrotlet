import Foundation
import Observation

/// 全局依赖容器：通过 .environment() 注入，不用全局单例。
@MainActor
@Observable
final class AppEnvironment {
    let configStore: ConfigStore
    let llm: LLMService
    let chat: ChatViewModel
    let settings: SettingsViewModel
    /// 朗读（消息点读 + 取词发音共用，互斥打断）
    let speech = SpeechService()
    /// 生词本（取词讲解收藏沉淀）
    let words = WordBookStore()
    /// 自动更新（Sparkle）：HAS_SPARKLE 的 SPM app 构建用生产实现，其余（测试等）noop
    let update: any UpdateProviding

    /// 界面语言（设置页可改）：写回 config.json；@Observable 存储属性，
    /// body 读取（直接或经 t()）即订阅，改动实时刷新全部窗口
    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            var next = configStore.value
            next.language = language
            configStore.save(next)
            L10n.current = language.resolved
        }
    }

    /// 会话侧栏展开（header 侧栏按钮切换）：写回 config.json，跨启动记住开合
    var sidebarPinned: Bool {
        didSet {
            guard sidebarPinned != oldValue else { return }
            var next = configStore.value
            next.sidebarPinned = sidebarPinned
            configStore.save(next)
        }
    }

    /// 系统 TTS 音色；写回 config.json，同步给 SpeechService
    var systemVoiceID: String? {
        didSet {
            guard systemVoiceID != oldValue else { return }
            var next = configStore.value
            next.systemVoiceID = systemVoiceID
            configStore.save(next)
            speech.voiceID = systemVoiceID
        }
    }

    /// 朗读语速（设置 → 朗读语音区，系统语音）；写回 config.json，同步给 SpeechService
    var speechRate: SpeechRate {
        didSet {
            guard speechRate != oldValue else { return }
            var next = configStore.value
            next.speechRate = speechRate
            configStore.save(next)
            speech.rate = speechRate
        }
    }

    init() {
        let config = ConfigStore()
        self.configStore = config
        self.llm = LLMService(configStore: config)
        self.chat = ChatViewModel(llm: llm)
        self.settings = SettingsViewModel(configStore: config, llm: llm)
        #if HAS_SPARKLE
        self.update = SparkleUpdateController()
        #else
        self.update = NoopUpdateProvider()
        #endif
        self.language = config.value.language
        self.sidebarPinned = config.value.sidebarPinned
        self.systemVoiceID = config.value.systemVoiceID
        self.speechRate = config.value.speechRate
        speech.voiceID = config.value.systemVoiceID
        speech.rate = config.value.speechRate
        // 全局外观（自动/浅色/深色）按 config.json 应用；设置页改动实时生效。
        // App 结构体在 main() 早期初始化，此处先于 applicationDidFinishLaunching 执行
        config.value.appearance.apply()
        L10n.current = config.value.language.resolved
        if case .recoveryRequired = configStore.persistenceState {
            chat.error = UserFacingError(
                style: .failure,
                message: L10n.s(.storageRecoveryRequired, L10n.current),
                action: nil,
                detail: "config.json requires recovery")
        } else if case .failed(let detail) = configStore.persistenceState {
            chat.error = UserFacingError(
                style: .failure,
                message: L10n.s(.storageSaveFailed, L10n.current),
                action: nil,
                detail: detail)
        }
    }

    /// 当前界面语言（auto 已解析）
    var uiLanguage: UILanguage { language.resolved }

    /// 文案翻译入口：Text(env.t(.newChat))
    func t(_ key: L10n.Key) -> String { L10n.s(key, language.resolved) }
}
