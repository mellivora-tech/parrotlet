import Foundation

/// 解析后的界面语言（AppLanguage.auto 已按系统首选语言展开）
enum UILanguage: Sendable, Equatable {
    case zh, en
}

/// 界面文案表：zh/en 双值，Key 枚举保证穷尽检查（加新文案必须补双语）。
///
/// 刻意不本地化的部分：
/// - 输入区（模式标签 English/Chat、占位符、悬停提示）与欢迎语：英文沉浸设计，恒定英文
/// - LLM prompt（会话总结）：内容生成而非界面文案，保持中文
/// - LLMError 等错误描述：技术信息，保持原文
enum L10n {
    /// AppKit 侧（菜单栏等无 environment 注入处）用的当前界面语言快照，
    /// 由 AppEnvironment 在启动与切换时刷新（AppKit 桥接，同 WindowOpenerBridge 模式）
    @MainActor static var current: UILanguage = .zh

    enum Key {
        // 菜单栏 / 窗口
        case appMenuChat, appMenuWordBook, appMenuSettings, appMenuQuit, chatWindowTitle
        // 聊天
        case defaultChatTitle, helpSettings, helpClose
        case newChat, helpProvider, helpSend, ok, readAloud
        case replyInterrupted, continueReply
        // 会话侧栏
        case toggleSidebar, searchChats, deleteChat, emptyChats
        // 生词本（取词面板收藏）
        case saveWord, wordSaved, continueLookup
        // 设置
        case search, noResults, paneGeneral, paneServices, paneAbout
        case sectionAppearance, appearanceSub, sectionLanguage, languageSub
        case sectionLaunch, launchAtLogin, sectionData, dataFolder, dataFolderSub, revealInFinder, runLog, runLogSub
        case sectionUpdate, updateAutoCheck, updateCurrentVersion, updateCheckNow
        case wordBookTitle, emptyWordBook, copyExplanation, exportWordBook
        case sectionVoice, voiceSystem, voiceSystemHint
        case speechRate, rateSlow, rateStandard, rateFast
        case sectionServices, servicesFootnote, addService, inUse, setActive, noKey, serviceDeleted
        case unsavedChanges, sectionBasics, name, namePlaceholder
        case openAICompatible, sectionConnection, baseURLPlaceholder
        case model, modelSub, fetchModelsHint, reloadModels
        case sectionParams, sectionActions, testConnection, testConnectionSub, test, notTested
        case save, deleteService, keyPlaceholder, enterKeyFirst
        case alertLeaveMessage, discard, cancel, deleteServiceTitle, delete, aboutTagline
        case connectedEmpty, customServiceName
        // 模型服务页（参考 workstation 交互重设计）
        case infoProviders, providerInfoText, addProvider, emptyProviders, customPreset
        case notConfigured, configureProviderFirst, apiKeyRequired
        // 国际化补全（2026-09 审查）：外观/语言选项、语音、URL 校验错误、生成中占位
        case appearanceAuto, appearanceLight, appearanceDark, languageAuto, voiceAuto
        case voiceQualityCompact, voiceQualityEnhanced, voiceQualityPremium
        case endpointEmpty, endpointInvalid, endpointScheme, endpointInsecure, endpointComponents
        case replyGenerating
        // 用户可见错误文案（UserFacingError 上屏用；技术详情走 detail/日志，不上屏）
        case storageSaveFailed, storageRecoveryRequired
        case errorNotConfigured, errorInvalidKey, errorRateLimited, errorBadEndpoint
        case errorServerBusy, errorNetwork, errorEmptyResponse, errorBadResponse
        case goToSettings
        // 取词讲解（原型）
        case lookupLoading, lookupPronounce, lookupExplain
    }

    static func s(_ key: Key, _ lang: UILanguage) -> String {
        let pair: (zh: String, en: String)
        switch key {
        // 菜单栏 / 窗口
        case .appMenuChat: pair = ("对话", "Chat")
        case .appMenuWordBook: pair = ("生词本", "Word Book")
        case .appMenuSettings: pair = ("设置", "Settings")
        case .wordBookTitle: pair = ("生词本", "Word Book")
        case .emptyWordBook: pair = ("暂无收藏", "No saved words")
        case .copyExplanation: pair = ("复制讲解", "Copy Explanation")
        case .exportWordBook: pair = ("导出 JSON…", "Export JSON…")
        case .appMenuQuit: pair = ("退出", "Quit")
        case .chatWindowTitle: pair = ("对话", "Chat")
        // 聊天
        case .defaultChatTitle: pair = ("英语对话", "English Chat")
        case .helpSettings: pair = ("设置", "Settings")
        case .lookupLoading: pair = ("讲解中…", "Explaining…")
        case .lookupPronounce: pair = ("发音", "Pronounce")
        case .lookupExplain: pair = ("讲解", "Explain")
        case .helpClose: pair = ("关闭 (⌘W)", "Close (⌘W)")
        case .replyInterrupted: pair = ("回复中断，内容可能不完整", "Reply interrupted — content may be incomplete")
        case .continueReply: pair = ("继续生成", "Continue")
        case .newChat: pair = ("新对话", "New Chat")
        // 会话侧栏
        case .toggleSidebar: pair = ("会话列表", "Sessions")
        case .searchChats: pair = ("搜索对话", "Search chats")
        case .deleteChat: pair = ("删除对话", "Delete Chat")
        case .emptyChats: pair = ("暂无对话", "No chats yet")
        case .helpProvider: pair = ("当前模型后端，点击打开设置", "Current backend — click to open Settings")
        case .helpSend: pair = ("发送 (Enter)", "Send (Enter)")
        case .ok: pair = ("好", "OK")
        case .readAloud: pair = ("朗读", "Read aloud")
        // 生词本（取词面板收藏）
        case .saveWord: pair = ("收藏到生词本", "Save to Word Book")
        case .continueLookup: pair = ("在聊天中继续问", "Continue in Chat")
        case .wordSaved: pair = ("已收藏，点击取消", "Saved — click to remove")
        // 设置
        case .search: pair = ("搜索", "Search")
        case .noResults: pair = ("无结果", "No Results")
        case .paneGeneral: pair = ("通用", "General")
        case .paneServices: pair = ("模型", "Models")
        case .paneAbout: pair = ("关于", "About")
        case .sectionAppearance: pair = ("外观", "Appearance")
        case .appearanceSub: pair = ("「自动」跟随系统外观切换", "“Auto” follows the system appearance")
        case .appearanceAuto: pair = ("自动", "Auto")
        case .appearanceLight: pair = ("浅色", "Light")
        case .appearanceDark: pair = ("深色", "Dark")
        case .languageAuto: pair = ("自动", "Auto")
        case .voiceAuto: pair = ("自动", "Auto")
        case .voiceQualityCompact: pair = ("紧凑", "Compact")
        case .voiceQualityEnhanced: pair = ("增强", "Enhanced")
        case .voiceQualityPremium: pair = ("高级", "Premium")
        case .endpointEmpty: pair = ("Base URL 不能为空", "Base URL is required")
        case .endpointInvalid: pair = ("Base URL 无效", "Invalid Base URL")
        case .endpointScheme: pair = ("Base URL 只支持 HTTP(S)", "Base URL must be HTTP(S)")
        case .endpointInsecure: pair = ("远程服务必须使用 HTTPS；明文 HTTP 仅允许本机地址",
                                       "Remote endpoints require HTTPS — plain HTTP is only allowed for localhost")
        case .endpointComponents: pair = ("Base URL 不能包含用户名、密码、query 或 fragment",
                                         "Base URL must not contain user, password, query or fragment")
        case .replyGenerating: pair = ("（回答生成中）", "(Generating…)")
        case .sectionLanguage: pair = ("语言", "Language")
        case .languageSub: pair = ("「自动」跟随系统语言", "“Auto” follows the system language")
        case .sectionLaunch: pair = ("启动", "Launch")
        case .launchAtLogin: pair = ("登录时启动", "Launch at Login")
        case .sectionUpdate: pair = ("软件更新", "Software Update")
        case .updateAutoCheck: pair = ("自动检查更新", "Automatically Check for Updates")
        case .updateCurrentVersion: pair = ("当前版本", "Current Version")
        case .updateCheckNow: pair = ("立即检查…", "Check Now…")
        case .sectionData: pair = ("数据", "Data")
        case .dataFolder: pair = ("数据文件夹", "Data Folder")
        case .dataFolderSub: pair = ("config.json、会话记录等，保存在本机 Application Support",
                                    "config.json, chat history, etc. in local Application Support")
        case .revealInFinder: pair = ("在访达中打开…", "Reveal in Finder…")
        case .runLog: pair = ("运行日志", "Run Log")
        case .runLogSub: pair = ("JSONL 事件流：LLM/朗读。出问题时把这个文件发给开发者",
                                "JSONL event stream: LLM/speech — send it to the developer when reporting issues")
        case .storageSaveFailed: pair = ("本地数据保存失败，请检查磁盘空间和权限；重启前请先备份重要内容",
                                        "Saving local data failed. Check disk space and permissions, and back up important data before restarting.")
        case .storageRecoveryRequired: pair = ("本地数据文件无法读取，已进入只读保护模式。请在数据文件夹中恢复 .corrupt 文件后再继续写入",
                                               "A local data file could not be read and is now read-only. Restore the .corrupt file in the data folder before writing again.")
        case .sectionVoice: pair = ("朗读语音", "Voice")
        case .voiceSystem: pair = ("系统语音", "System Voice")
        case .voiceSystemHint: pair = (
            "想要更自然的声音，可在 系统设置 → 辅助功能 → 朗读内容 → 系统语音 → 管理语音 下载 Enhanced / Premium 音色，然后重启 App。",
            "For a more natural voice, download an Enhanced or Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then restart the app.")
        case .speechRate: pair = ("语速", "Speech Rate")
        case .rateSlow: pair = ("慢", "Slow")
        case .rateStandard: pair = ("标准", "Standard")
        case .rateFast: pair = ("快", "Fast")
        case .sectionServices: pair = ("服务", "Services")
        case .servicesFootnote: pair = ("圆点表示是否已配置 API Key。测试连接在详情页内基于当前表单内容执行。",
                                       "The dot shows whether an API key is set. Test Connection runs against the current form values.")
        case .addService: pair = ("添加服务…", "Add Service…")
        case .inUse: pair = ("使用中", "Active")
        case .setActive: pair = ("设为当前使用", "Set as Active")
        case .noKey: pair = ("· 未配置 Key", "· No API key")
        case .serviceDeleted: pair = ("此服务已被删除", "This service has been deleted")
        case .unsavedChanges: pair = ("有未保存的更改", "Unsaved Changes")
        case .sectionBasics: pair = ("基本信息", "Basics")
        case .name: pair = ("名称", "Name")
        case .namePlaceholder: pair = ("显示名称", "Display name")
        case .openAICompatible: pair = ("OpenAI 兼容", "OpenAI Compatible")
        case .sectionConnection: pair = ("连接", "Connection")
        case .baseURLPlaceholder: pair = ("含版本前缀，如 https://api.deepseek.com/v1",
                                         "Include version prefix, e.g. https://api.deepseek.com/v1")
        case .model: pair = ("模型", "Model")
        case .modelSub: pair = ("填好 API Key 后自动获取可选列表",
                               "Model list loads automatically once an API key is set")
        case .fetchModelsHint: pair = ("填 Key 后点右侧获取", "Enter a key, then fetch")
        case .reloadModels: pair = ("重新获取模型列表", "Reload model list")
        case .sectionParams: pair = ("参数", "Parameters")
        case .sectionActions: pair = ("操作", "Actions")
        case .testConnection: pair = ("测试连接", "Test Connection")
        case .testConnectionSub: pair = ("以当前表单内容发送一条最小请求",
                                        "Sends a minimal request with the current form values")
        case .test: pair = ("测试", "Test")
        case .notTested: pair = ("未测试", "Not tested")
        case .save: pair = ("保存", "Save")
        case .deleteService: pair = ("删除此服务…", "Delete Service…")
        case .keyPlaceholder: pair = ("明文存于本机 config.json", "Stored in plain text in config.json")
        case .enterKeyFirst: pair = ("请先填写 API Key", "Enter an API key first")
        case .alertLeaveMessage: pair = ("离开后将丢失当前修改。", "Your changes will be lost.")
        case .discard: pair = ("放弃更改", "Discard")
        case .cancel: pair = ("取消", "Cancel")
        case .deleteServiceTitle: pair = ("删除此服务？", "Delete This Service?")
        case .delete: pair = ("删除", "Delete")
        case .aboutTagline: pair = ("菜单栏英语陪练",
                                   "Menu-bar English partner")
        case .connectedEmpty: pair = ("✅ 连接成功（空回复）", "✅ Connected (empty reply)")
        case .customServiceName: pair = ("自定义服务", "Custom Service")
        case .infoProviders: pair = ("模型服务说明", "About model providers")
        case .providerInfoText: pair = (
            "模型服务为对话提供后端。开关互斥：启用一个服务会自动关闭其他服务，再点一次可全部停用。点服务行编辑；「+」从预设快速添加。测试连接基于当前表单内容执行。",
            "Model providers power chat. The switches are exclusive: enabling one disables the others; click again to disable all. Click a row to edit; “+” adds from presets. Test Connection runs against the current form values.")
        case .addProvider: pair = ("添加 Provider", "Add Provider")
        case .emptyProviders: pair = ("还没有配置模型 Provider", "No model providers yet")
        case .customPreset: pair = ("自定义", "Custom")
        case .notConfigured: pair = ("未配置", "None")
        case .configureProviderFirst: pair = ("请先在设置中启用一个模型服务并填写 API Key",
                                             "Enable a model provider and set its API key in Settings first")
        case .apiKeyRequired: pair = ("请填写 API Key", "API key is required")
        // 用户可见错误文案
        case .errorNotConfigured: pair = ("还没有配置模型服务，先去设置里添加一个吧",
                                          "No model provider configured yet — add one in Settings")
        case .errorInvalidKey: pair = ("API key 无效或没有权限，请在设置里检查",
                                       "The API key is invalid or unauthorized — check it in Settings")
        case .errorRateLimited: pair = ("请求太频繁或额度不足，请稍后再试",
                                        "Too many requests or insufficient quota — try again later")
        case .errorBadEndpoint: pair = ("接口地址或模型名可能有误，请在设置里检查",
                                        "The endpoint or model name looks wrong — check it in Settings")
        case .errorServerBusy: pair = ("模型服务暂时不可用，请稍后重试",
                                       "The model service is unavailable right now — try again later")
        case .errorNetwork: pair = ("网络连接失败，请检查网络后重试",
                                    "Network connection failed — check your connection and retry")
        case .errorEmptyResponse: pair = ("模型没有返回内容，请重试",
                                          "The model returned nothing — please retry")
        case .errorBadResponse: pair = ("服务响应异常，请重试",
                                        "The service responded abnormally — please retry")
        case .goToSettings: pair = ("去设置", "Open Settings")
        }
        return lang == .zh ? pair.zh : pair.en
    }

    // MARK: - 带参文案

    /// 复盘会话行：「12 轮 · Chat」
    static func turnsAndMode(_ turns: Int, _ mode: String, _ lang: UILanguage) -> String {
        lang == .zh ? "\(turns) 轮 · \(mode)" : "\(turns) turns · \(mode)"
    }

    /// 关于页版本号
    static func version(_ v: String, _ lang: UILanguage) -> String {
        lang == .zh ? "版本 \(v)" : "Version \(v)"
    }

    /// 删除服务确认弹窗正文
    static func deleteServiceMessage(_ name: String, _ lang: UILanguage) -> String {
        lang == .zh ? "「\(name)」的配置与 API Key 将被移除，此操作不可恢复。"
                    : "The configuration and API key for “\(name)” will be permanently removed."
    }

    /// 模态标题：添加 / 编辑
    static func addPresetTitle(_ name: String, _ lang: UILanguage) -> String {
        lang == .zh ? "添加 \(name)" : "Add \(name)"
    }

    static func editProviderTitle(_ name: String, _ lang: UILanguage) -> String {
        lang == .zh ? "编辑 \(name)" : "Edit \(name)"
    }

    /// 测试连接成功：「可用 · 320ms」
    static func availableLatency(_ ms: Int, _ lang: UILanguage) -> String {
        lang == .zh ? "可用 · \(ms)ms" : "Available · \(ms)ms"
    }

    /// 测试连接成功（带回显）
    static func connected(_ echo: String, _ lang: UILanguage) -> String {
        lang == .zh ? "✅ 连接成功：\(echo)" : "✅ Connected: \(echo)"
    }
}
