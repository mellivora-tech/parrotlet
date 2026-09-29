import Foundation

/// 生词本条目：取词讲解卡片「收藏」沉淀下来的词/短语 + 语境讲解
struct WordEntry: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 单词/短语原文（去重按 lowercased 比较，这里保留用户选中的原始大小写）
    var text: String
    /// 讲解（LLM 五字段解析前的原始输出原样存——结构化解析可能失败，原文不丢）
    var note: String
    /// 出处：所在 turn 全文（查的就是「这个词在这句话里的意思」）
    var context: String
    var createdAt: Date = Date()
}
