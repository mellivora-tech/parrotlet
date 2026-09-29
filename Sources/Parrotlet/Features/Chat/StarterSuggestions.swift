import Foundation

/// 空态建议胶囊动态生成（纯逻辑可单测）：从最近会话的总结里长出个性化开场，
/// 取代写死的通用话题——「英语陪练」和通用聊天框的差距就体现在这里。
///
/// 优先级：复习向（上次错句的修正版，亲口再说一遍）> 续聊向（上次会话标题）>
/// 兜底池（通用开场，按日轮换不重复）。胶囊点击即以用户身份发送该句：
/// 复习向用英文修正句、续聊向用中文标题，两种语言都是合法用户输入（对话模式双语）。
enum StarterSuggestions {
    /// 兜底池：新用户或近期会话无总结时的通用开场。
    /// 原 ChatPartner.conversationStarters 3 条 + 扩充，按「一年中的第几天」轮换起点，
    /// 连兜底也不永远一样
    static let fallbackPool = [
        "Let's talk about my day.",
        "Help me practice a job interview.",
        "I want to describe my weekend plans.",
        "Can we role-play ordering food at a restaurant?",
        "Help me write an email to a colleague.",
        "Let's talk about a movie I watched recently.",
    ]

    /// 生成最多 3 条胶囊文案。sessions 须按 updatedAt 降序（ChatViewModel.sessions 天然就是）；
    /// 当前空会话无 turns 无 summary，会被自然跳过，无需特判
    static func make(sessions: [ChatSession], today: Date = Date()) -> [String] {
        var result: [String] = []

        // 复习向：最近一场「原话+修正」齐全的错句 → 让用户亲口把修正版再说一遍
        // （只取一条：胶囊位有限，且复习最需要聚焦）
        for session in sessions.prefix(3) {
            guard let correction = session.summary?.mistakes?.first?.correction?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !correction.isEmpty else { continue }
            result.append("Let me try again: " + clipped(correction, to: 80))
            break
        }

        // 续聊向：最近一场有 LLM 标题的会话 → 标题作话题锚点
        for session in sessions.prefix(3) {
            guard let title = session.summary?.title?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            appendUnique("继续聊「\(title)」", to: &result)
            break
        }

        // 兜底池按日轮换补齐到 3 条
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: today) ?? 0
        for i in fallbackPool.indices {
            guard result.count < 3 else { break }
            appendUnique(fallbackPool[(i + dayOfYear) % fallbackPool.count], to: &result)
        }
        return result
    }

    private static func clipped(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    private static func appendUnique(_ s: String, to result: inout [String]) {
        guard result.count < 3, !result.contains(s) else { return }
        result.append(s)
    }
}
