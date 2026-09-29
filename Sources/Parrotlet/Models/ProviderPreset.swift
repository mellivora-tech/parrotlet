import Foundation

/// 内置 provider 预设：「+」添加菜单的选项（对齐参考设计——类型在添加时选定，
/// 之后的表单里没有类型字段：新增不可改，编辑锁定）。
/// 官方品牌图标资源名 = "provider-\(id)"（assets/providers/，随包平铺进 Resources）
struct ProviderPreset: Sendable, Identifiable, Equatable {
    /// 预设 id：deepseek / kimi / glm；新配置 id 以其为前缀
    let id: String
    let kind: ProviderKind
    /// 默认名（表单名称留空保存时自动采用；placeholder 即此名）
    let defaultName: String
    /// 预填 baseURL（可改）
    let baseURL: String
    /// 模型下拉的内置选项（与已保存值 ∪ 在线拉取结果合并）
    let builtinModels: [String]
    /// 老配置（无 preset 标记）按 baseURL host 推断预设的关键词
    let hostKeywords: [String]

    static let deepseek = ProviderPreset(
        id: "deepseek", kind: .openAICompatible, defaultName: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        builtinModels: ["deepseek-chat", "deepseek-reasoner"],
        hostKeywords: ["deepseek"])

    static let kimi = ProviderPreset(
        id: "kimi", kind: .openAICompatible, defaultName: "Kimi",
        baseURL: "https://api.moonshot.cn/v1",
        builtinModels: ["kimi-k2-0905-preview", "moonshot-v1-32k", "moonshot-v1-128k"],
        hostKeywords: ["moonshot", "kimi"])

    static let glm = ProviderPreset(
        id: "glm", kind: .openAICompatible, defaultName: "智谱 GLM",
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        builtinModels: ["glm-4.7", "glm-4.6", "glm-4.5-air"],
        hostKeywords: ["bigmodel", "zhipu", "chatglm"])

    static let all: [ProviderPreset] = [.deepseek, .kimi, .glm]

    /// 配置 → 预设（图标/默认名/内置模型用）：
    /// preset 标记优先；老配置按 id 前缀，再退到 baseURL host 关键词
    static func match(_ config: ProviderConfig) -> ProviderPreset? {
        if let marked = config.preset,
           let p = all.first(where: { $0.id == marked }) { return p }
        if let p = all.first(where: { config.id == $0.id || config.id.hasPrefix($0.id + "-") }) { return p }
        guard let host = URL(string: config.baseURL)?.host?.lowercased() else { return nil }
        return all.first { p in p.hostKeywords.contains { host.contains($0) } }
    }
}
