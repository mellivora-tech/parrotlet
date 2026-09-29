import Foundation

/// StarterSuggestions：空态建议胶囊动态生成（复习错句 > 续聊话题 > 兜底池按日轮换）
let starterSuggestionsTests: [TestCase] = [
    TestCase(name: "starters: 无会话时给 3 条兜底，非空且不重复") {
        let starters = StarterSuggestions.make(sessions: [])
        try expectEqual(starters.count, 3)
        try expectEqual(Set(starters).count, 3, "兜底条目不重复")
        try expect(starters.allSatisfy { StarterSuggestions.fallbackPool.contains($0) },
                   "全部来自兜底池")
    },

    TestCase(name: "starters: 最近错句 → 首条复习向，亲口复述修正版") {
        let summary = ConversationSummary(
            brief: nil, userGoal: nil, title: nil, topics: nil,
            mistakes: [.init(original: "I go to school yesterday",
                             correction: "I went to school yesterday",
                             note: "时态")],
            expressions: nil, summarizedTurns: nil, rawMarkdown: nil)
        let session = ChatSession(summary: summary)
        let starters = StarterSuggestions.make(sessions: [session])
        try expectEqual(starters.first, "Let me try again: I went to school yesterday")
        try expectEqual(starters.count, 3, "不足 3 条由兜底补齐")
    },

    TestCase(name: "starters: 有错句无标题 → 复习向 + 兜底；有标题 → 复习 + 续聊") {
        let noTitle = ChatSession(summary: ConversationSummary(
            brief: nil, userGoal: nil, title: nil, topics: nil,
            mistakes: [.init(original: "a", correction: "b", note: nil)],
            expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        try expect(StarterSuggestions.make(sessions: [noTitle]).allSatisfy { !$0.hasPrefix("继续聊") },
                   "无标题不出续聊胶囊")

        let withTitle = ChatSession(summary: ConversationSummary(
            brief: nil, userGoal: nil, title: "周末徒步计划", topics: nil,
            mistakes: [.init(original: "a", correction: "b", note: nil)],
            expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        let starters = StarterSuggestions.make(sessions: [withTitle])
        try expectEqual(starters.first, "Let me try again: b")
        try expectEqual(starters.count > 1 ? starters[1] : "", "继续聊「周末徒步计划」")
        try expectEqual(starters.count, 3)
    },

    TestCase(name: "starters: 只取最近 3 场会话，更旧的错句/标题不进场") {
        func session(title: String?, correction: String?) -> ChatSession {
            ChatSession(summary: ConversationSummary(
                brief: nil, userGoal: nil, title: title, topics: nil,
                mistakes: correction.map { [.init(original: "x", correction: $0, note: nil)] },
                expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        }
        // sessions 按 updatedAt 降序传入；前 3 场无可用素材，第 4 场有也不取
        let sessions = [session(title: nil, correction: nil),
                        session(title: " ", correction: " "),
                        session(title: nil, correction: nil),
                        session(title: "旧话题", correction: "old")]
        let starters = StarterSuggestions.make(sessions: sessions)
        try expect(starters.allSatisfy { !$0.contains("old") && !$0.contains("旧话题") },
                   "第 4 场及更早的素材不进场")
    },

    TestCase(name: "starters: 超长修正句截断到 80 字符") {
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let session = ChatSession(summary: ConversationSummary(
            brief: nil, userGoal: nil, title: nil, topics: nil,
            mistakes: [.init(original: "x", correction: long, note: nil)],
            expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        let first = StarterSuggestions.make(sessions: [session]).first ?? ""
        try expect(first.hasSuffix("…"), "超长截断带省略号")
        try expectEqual(first.count, "Let me try again: ".count + 80)
    },

    TestCase(name: "starters: 兜底池按日轮换，不同日期起点不同") {
        let day1 = StarterSuggestions.make(sessions: [], today: Date(timeIntervalSince1970: 0))
        let day2 = StarterSuggestions.make(sessions: [], today: Date(timeIntervalSince1970: 86400 * 100))
        try expect(day1 != day2, "不同日期的兜底顺序应不同")
        try expectEqual(Set(day1).count, 3)
        try expectEqual(Set(day2).count, 3)
    },

    TestCase(name: "starters: 复习向与续聊向取自不同会话时按新→旧各自取第一条") {
        // 最新场只有标题，次新场只有错句 → 复习向取次新场、续聊向取最新场
        let newest = ChatSession(summary: ConversationSummary(
            brief: nil, userGoal: nil, title: "面试准备", topics: nil,
            mistakes: nil, expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        let older = ChatSession(summary: ConversationSummary(
            brief: nil, userGoal: nil, title: nil, topics: nil,
            mistakes: [.init(original: "x", correction: "fixed", note: nil)],
            expressions: nil, summarizedTurns: nil, rawMarkdown: nil))
        let starters = StarterSuggestions.make(sessions: [newest, older])
        try expectEqual(starters.first, "Let me try again: fixed")
        try expectEqual(starters.count > 1 ? starters[1] : "", "继续聊「面试准备」")
    },
]
