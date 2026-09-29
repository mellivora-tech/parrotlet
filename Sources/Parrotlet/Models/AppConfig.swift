import Foundation

enum ProviderKind: String, Codable, Sendable {
    /// OpenAI 兼容协议（DeepSeek / GLM / Kimi / Ollama / OpenAI…）
    case openAICompatible
}

/// 外观模式：跟随系统 / 浅色 / 深色。
/// 老配置无此键，解码兜底 .dark——沿用初版「全局深色」的默认观感，不擅自改老用户的界面
enum AppAppearance: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    /// 选择器标签：随界面语言（zh/en 双语在 L10n 表）
    func label(_ lang: UILanguage) -> String {
        switch self {
        case .auto: L10n.s(.appearanceAuto, lang)
        case .light: L10n.s(.appearanceLight, lang)
        case .dark: L10n.s(.appearanceDark, lang)
        }
    }
}

/// 界面语言：跟随系统 / 中文 / English。
/// 老配置无此键，解码兜底 .auto——按系统首选语言解析，中文系统仍是中文，观感不变
enum AppLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, zhHans, english

    var id: String { rawValue }

    /// 选择器标签：语言名用各自原生写法（语言选择器惯例），「自动」随界面语言
    func label(_ lang: UILanguage) -> String {
        switch self { case .auto: L10n.s(.languageAuto, lang); case .zhHans: "中文"; case .english: "English" }
    }

    /// 解析为具体界面语言：auto 按系统首选语言（中文系 → 中文，其余 → English）
    var resolved: UILanguage {
        switch self {
        case .zhHans: .zh
        case .english: .en
        case .auto: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
        }
    }
}

/// 系统语音朗读语速：慢/标准/快。
/// 老配置无此键，解码兜底 .standard。
enum SpeechRate: String, Codable, Sendable, CaseIterable, Identifiable {
    case slow, standard, fast

    var id: String { rawValue }

    /// AVSpeechUtterance.rate：系统默认约为 0.5。这里保持轻量映射，不做变速特效。
    var utteranceRate: Float {
        switch self { case .slow: 0.42; case .standard: 0.5; case .fast: 0.62 }
    }
}

struct AppConfig: Codable, Sendable, Equatable {
    /// 落盘 schema 版本锚点：老配置无此键 = 1。
    /// 破坏性变更时版本 +1，并在 init(from:) 里按读到的旧版本号分支迁移（解码即迁移，
    /// 下次 save 自然写成当前版本）。数组文件的锚点在 PersistedArchives.swift
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var activeProviderID: String
    var providers: [ProviderConfig]
    var appearance: AppAppearance
    var language: AppLanguage
    /// 会话侧栏展开（false = 收起的窄窗）；老配置无此键，解码兜底 false
    var sidebarPinned: Bool
    /// 系统 TTS 音色 identifier；nil 表示自动选择默认自然语音
    var systemVoiceID: String?
    /// 朗读语速（系统语音）；老配置无此键，兜底 .standard
    var speechRate: SpeechRate

    init(activeProviderID: String, providers: [ProviderConfig],
         appearance: AppAppearance = .dark, language: AppLanguage = .auto,
         sidebarPinned: Bool = false,
         systemVoiceID: String? = nil, speechRate: SpeechRate = .standard,
         schemaVersion: Int = AppConfig.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.activeProviderID = activeProviderID
        self.providers = providers
        self.appearance = appearance
        self.language = language
        self.sidebarPinned = sidebarPinned
        self.systemVoiceID = systemVoiceID
        self.speechRate = speechRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 读到的旧版本号只供 init 内迁移分支使用；解码完成即迁移完成，
        // 内存值统一标当前版本——save 必须写当前版本（与 PersistedArchives 同一棘轮）
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        schemaVersion = Self.currentSchemaVersion
        activeProviderID = try c.decode(String.self, forKey: .activeProviderID)
        let decodedProviders = try c.decode([ProviderConfig].self, forKey: .providers)
        let ids = decodedProviders.map(\.id)
        if ids.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let context = DecodingError.Context(
                codingPath: [CodingKeys.providers], debugDescription: "provider id cannot be empty")
            throw DecodingError.dataCorrupted(context)
        }
        if Set(ids).count != ids.count {
            let context = DecodingError.Context(
                codingPath: [CodingKeys.providers], debugDescription: "provider ids must be unique")
            throw DecodingError.dataCorrupted(context)
        }
        providers = decodedProviders
        // 枚举一律 try? 容错（kind 已验证过的模式）：未来新版本加的枚举值，
        // 老 app 读到时单字段回默认，而不是整文件解码失败被隔离
        appearance = (try? c.decode(AppAppearance.self, forKey: .appearance)) ?? .dark
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? .auto
        sidebarPinned = try c.decodeIfPresent(Bool.self, forKey: .sidebarPinned) ?? false
        systemVoiceID = try c.decodeIfPresent(String.self, forKey: .systemVoiceID)
        speechRate = (try? c.decode(SpeechRate.self, forKey: .speechRate)) ?? .standard
    }

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }
}

struct ProviderConfig: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var kind: ProviderKind
    var name: String
    /// 含版本前缀；代码只拼 /chat/completions（GLM 的版本段是 v4，不能硬编码 v1）
    var baseURL: String
    var model: String
    var apiKey: String?
    var maxTokens: Int?
    /// 创建来源预设（ProviderPreset.id）；nil = 自定义/老配置（按 id/host 推断图标）
    var preset: String?

    init(id: String, kind: ProviderKind, name: String, baseURL: String, model: String,
         apiKey: String? = nil, maxTokens: Int? = nil, preset: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.preset = preset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // 已删除的 anthropic 原生协议（2026-09 起不再接）：老配置里残留的 "anthropic"
        // 容错成兼容协议——硬解码失败会让整个 config.json 被隔离、所有 provider 和 key 全丢
        kind = (try? c.decode(ProviderKind.self, forKey: .kind)) ?? .openAICompatible
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }
}
