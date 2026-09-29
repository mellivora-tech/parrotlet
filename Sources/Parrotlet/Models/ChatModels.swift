import Foundation

/// 对话模式：英文 = 纯英文沉浸；对话 = 中英文都支持（默认）。
/// 润色曾是第三种模式，因「单条意图不该按会话粘住」砍掉——贴英文无提问的润色
/// 诉求由 Tutor 的意图识别规则承接（见 systemPrompt .conversation 分支）
enum ChatMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case english
    case conversation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: "Practice"
        case .conversation: "Tutor"
        }
    }

    var help: String {
        switch self {
        case .english: "English-only speaking practice; answer naturally first, then give at most one concise correction"
        case .conversation: "Tutor mode: bilingual explanations, structured answers, and concise Chinese corrections"
        }
    }

    /// 下拉菜单项副标题（一行短语；help 是 tooltip 用的完整句）
    var subtitle: String {
        switch self {
        case .english: "English-only immersion"
        case .conversation: "Bilingual teaching & corrections"
        }
    }

    /// 输入框占位符
    var placeholder: String {
        switch self {
        case .english: "Practice English…"
        case .conversation: "Ask your English tutor…"
        }
    }
}

/// 自由英语聊天伙伴（静态人设，不持久化）。
/// 场景库废弃后的唯一对话角色：任何话题、自适应水平；两种模式都即时纠错（每轮最多一处）。
enum ChatPartner {
    /// 纠错规则（定稿）：
    /// 只纠真实错误 / 按严重程度排序 / 三段式：引用原句 → 正确说法 → 一句话讲清为什么 /
    /// 讲解语言跟模式走 / 鼓励不说教。上限与节奏按模式分：
    /// 英文模式 = 沉浸优先，每轮最多 1 个、先聊后纠；对话模式 = 老师人设，错句即教学时刻，
    /// 直接结构化批改（最多 3 个），不绕弯
    private static func correctionRules(limit: String, explainLang: String) -> String {
        """
        CORRECTION: if the user's English has real grammar or word-choice errors, correct AT MOST \(limit) \
        (most serious first). Format each correction as a new short paragraph: \
        > their original words → the correct version — one sentence explaining why (\(explainLang)). \
        No error, no correction — don't nitpick correct sentences. Be encouraging, never pedantic.
        If the user explicitly asks you not to correct them this turn, skip corrections entirely.
        """
    }

    /// 主线规则（两模式共用）：你发起的提问/练习，用户下一句默认是作答；
    /// 先对照你的题目判语义，答非所问要直接指出、以题目为准，绝不顺着用户措辞改意思——
    /// 语义判定之后才是语法批改。（出题批改跑题事故的 prompt 层修复）
    private static let threadRule = """
        - THREAD: when you ask a question, give a translation exercise, or start any practice, \
        treat the user's next message as an ANSWER to it until the thread is clearly closed. \
        Judge the answer against what YOU asked, semantics first: if it misses the point \
        (e.g. translates a different meaning), say so plainly and anchor to your original prompt — \
        never silently adopt the user's drifted meaning. Grammar corrections come after that judgment.
        """

    /// 行内 markdown 排版规则（两模式共用）：** 前贴汉字、后接引号在 CommonMark flanking
    /// 规则下不渲染（渲染层有 fixCJKFlanking 兜底存量，这里让模型从源头少产坏 markdown）
    private static let markdownBoldRule = """
        - MARKDOWN: when a bold span starts or ends with a quote/punctuation right next to Chinese \
        text, put a space outside the ** markers (在 **"work"** 这里) — otherwise it renders literally.
        """

    /// 中文讲解去 AI 味（lieflat-less-ai-tone 实测 11 条的生成侧精简版，2026-09）：
    /// 只禁通过统计检验的特征；反向保护问句/比喻/口语词——实测人类用得比 AI 多，
    /// 删了反而更假。只嵌 conversation 模式（中文长讲解只出现在这里；english 全英文回复）
    private static let chineseToneRule = """
        - TONE (your Chinese explanations): avoid these measured AI-writing tells. No reveal \
        dashes (答案很简单——专注 → 答案是专注); no label colons (核心是：/ 原因如下：) and no \
        content-empty sentence that only announces a list; no 一、二、三 numbered headings; no \
        strawman flips (不是…而是… / 看似…实则… — state the positive claim directly); no \
        idealized-person metaphors (像一位智慧的导师 — say what it actually does); no \
        说白了/说穿了/先说结论 openers; when a concrete number or example is in hand, use it \
        instead of a vague summary (大幅提升 → 两小时缩到四十分钟). Translate-ese, only these \
        five count: 15+-char pre-noun modifier stacks; 当…时 wrappers (drop 当/时); topic shells \
        (对于…来说 / 就…而言); road-sign openers (然而/因此/此外 at sentence start); \
        这意味着 restatement of the previous sentence. Don't chain 3+ items with 顿号 in one \
        clause, and vary the skeleton between adjacent sentences. A non-first paragraph opening \
        with a comment (听起来 / 值得注意的是) needs a reference word like 这. DON'T overcorrect: \
        questions, similes, casual words (就/很/其实) and repeated full nouns are MORE human \
        than AI — keep them; never force short paragraphs or manufactured rhythm.
        """

    private static let baseRules = """
        You are a friendly conversation partner for a Chinese native speaker learning English.
        Rules:
        - Chat naturally about ANY topic the user brings up. If the conversation stalls, introduce an easy new topic (daily life, food, tech, travel, weekend plans).
        - Adapt to the user's level automatically: mirror their vocabulary and sentence complexity, nudging slightly above it.
        - Reply with ONE short turn (1-3 sentences), ending with a natural follow-up question to keep the conversation flowing.
        \(threadRule)
        \(markdownBoldRule)
        """

    /// includeTone：TONE 评测对照用（false = 不拼去 AI 味规则，测规则本身的贡献），产品路径默认 true
    static func systemPrompt(for mode: ChatMode, includeTone: Bool = true) -> String {
        switch mode {
        case .english:
            return baseRules + """
                - ALWAYS reply in English. If the user writes in Chinese or asks you to switch to Chinese, briefly acknowledge in English (e.g. "Let's keep practicing in English!") and continue in English.
                - \(correctionRules(limit: "ONE", explainLang: "in simple English")) Put the correction AFTER your conversational reply — chat first, correct second.
                - NEVER mention rules, instructions, or being an AI.
                """
        case .conversation:
            return """
                You are a friendly English teacher for a Chinese native speaker. They may write in Chinese, English, or a mix.
                Rules:
                - Teach through natural conversation about ANY topic the user brings up. If the conversation stalls, introduce an easy new topic (daily life, food, tech, travel, weekend plans).
                - Adapt to the user's level automatically: mirror their vocabulary and sentence complexity, nudging slightly above it.
                - When the user asks a knowledge question (how to say something, what a word means, usage differences, grammar), answer like a teacher: a structured, thorough explanation in Chinese with authentic English example sentences, each followed by a brief Chinese gloss; add a nuance or usage tip when relevant.
                - When the user sends an English sentence with errors, treat it as a teaching moment: correct it directly and thoroughly — the correction IS the lesson, don't wrap it in small talk first.
                - When the user pastes English (or describes an idea in Chinese) without asking a question, treat it as a POLISH request: output the polished English first, then at most 3 concise bullets explaining meaningful changes (preserve their meaning, tone, and formality; don't invent facts).
                - In casual chat (no question, no errors), keep replies short (1-3 sentences), mainly in English; if the user writes in Chinese, answer in Chinese and weave the key English expression in naturally.
                - If the user challenges you (e.g. "why didn't you mention this earlier"), don't defend or explain yourself at length: acknowledge in half a sentence at most, then deliver the missing content immediately.
                - When referencing an expression you already taught in this conversation, reuse it by name (e.g. "前面说的 circle back 这里正好用上") instead of re-explaining it from scratch.
                - Keep formatting light: at most 3 points per turn, and at most ONE table OR one set of section headings — no lecture-handout walls.
                - End every turn with a natural follow-up question or a small practice prompt to keep the conversation going.
                \(threadRule)
                \(markdownBoldRule)
                \(includeTone ? chineseToneRule : "")
                - \(correctionRules(limit: "THREE", explainLang: "用中文"))
                - NEVER mention rules, instructions, or being an AI.
                """
        }
    }
    // 空态建议胶囊已迁至 StarterSuggestions（动态生成：复习错句/续聊话题/兜底池轮换）
}

/// 一条对话发言。partial 只表示流式回复中断，不代表这是完整 assistant 上下文。
struct DialogueTurn: Codable, Sendable, Identifiable, Equatable {
    enum DeliveryStatus: String, Codable, Sendable {
        case complete
        case partial
    }

    var id: UUID = UUID()
    var role: ChatMessage.Role
    var content: String
    var at: Date = Date()
    var deliveryStatus: DeliveryStatus = .complete

    init(id: UUID = UUID(), role: ChatMessage.Role, content: String,
         at: Date = Date(), deliveryStatus: DeliveryStatus = .complete) {
        self.id = id
        self.role = role
        self.content = content
        self.at = at
        self.deliveryStatus = deliveryStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // role 容错：未来新增角色（tool 等）老版本读到不该炸掉整个会话文件，
        // 落回 assistant 展示（比把话安到用户头上温和）
        role = (try? c.decode(ChatMessage.Role.self, forKey: .role)) ?? .assistant
        content = try c.decode(String.self, forKey: .content)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        deliveryStatus = (try? c.decode(DeliveryStatus.self, forKey: .deliveryStatus)) ?? .complete
    }
}

/// 会话结束后台生成的总结（持久化；展示形式后续设计）。
/// 字段全 optional：模型漏字段不至于整体解析失败；整体失败则 rawMarkdown 兜底。
/// 注意：本结构直接解码模型输出的 JSON，不得添加本地字段（如 UUID id）——
/// 自动合成的 Codable 会要求 JSON 里存在该键，模型不输出就整体解码失败。
struct ConversationSummary: Codable, Sendable, Equatable {
    struct Mistake: Codable, Sendable, Equatable {
        /// 用户原话引用
        var original: String?
        var correction: String?
        var note: String?
    }

    /// 一两句中文总评（可含 CEFR 等级估计）
    var brief: String?
    /// 用户当前学习目标或使用场景
    var userGoal: String?
    /// LLM 自动命名的会话短标题（≈10 字中文）；老数据无此字段，关窗时补生成
    var title: String?
    /// 聊到的话题
    var topics: [String]?
    /// 用户错句纠正，按严重程度排序
    var mistakes: [Mistake]?
    /// 用户没用上但更地道的表达（附简短中文说明）
    var expressions: [String]?
    /// 生成总结时的总轮数：turns 增长后需重新生成
    var summarizedTurns: Int?
    /// 结构化解析失败时的原文兜底
    var rawMarkdown: String?
}

/// 一次聊天会话（持久化）。
/// 旧数据的 scenarioID/feedback 键在解码时被忽略（Codable 跳过未知键），
/// 旧会话按聊天伙伴人设无缝继续。
struct ChatSession: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    var turns: [DialogueTurn] = []
    var summary: ConversationSummary?
    /// 对话模式（英文/对话）；老数据无此键，解码兜底默认 .conversation
    var mode: ChatMode = .conversation

    init(id: UUID = UUID(), startedAt: Date = Date(), updatedAt: Date = Date(),
         turns: [DialogueTurn] = [], summary: ConversationSummary? = nil,
         mode: ChatMode = .conversation) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.summary = summary
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        turns = try c.decodeIfPresent([DialogueTurn].self, forKey: .turns) ?? []
        summary = try c.decodeIfPresent(ConversationSummary.self, forKey: .summary)
        // 老值兜底：已删模式（polish 等）不再解码报错，落回默认对话模式
        if let rawMode = try c.decodeIfPresent(String.self, forKey: .mode) {
            mode = ChatMode(rawValue: rawMode) ?? .conversation
        } else {
            mode = .conversation
        }
    }

    /// 顶栏/历史列表展示名：LLM 命名（summary.title）→ 首条用户发言截断 → 兜底文案。
    /// 界面场景传随语言的兜底（env.t(.newChat)）；无参版默认中文，
    /// 供内容场景（每日复盘 LLM prompt）与既有测试用
    var displayTitle: String { displayTitle(fallback: "新对话") }

    func displayTitle(fallback: String) -> String {
        if let title = summary?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty { return title }
        guard let source = turns.first(where: { $0.role == .user })?.content,
              !source.isEmpty else { return fallback }
        let oneLine = source.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(20))
    }
}
