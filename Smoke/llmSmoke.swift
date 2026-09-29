import Foundation

/// LLM 冒烟工具（真实 API）：
///   make llm-smoke                    → 单条流式请求
///   make llm-smoke ARGS=chat          → 完整聊天：开新会话 → 对话 → 后台总结（端到端）
///   make llm-smoke ARGS=tone          → TONE 评测：20 用例打 conversation 模式，按 11 条特征扫描输出
///   make llm-smoke ARGS="tone 5"      → 只跑第 5 条
///   make llm-smoke ARGS="tone 5 baseline" → 第 5 条去掉 TONE 规则跑对照（验证规则的贡献）
/// API key：环境变量（apiKeyEnvVar）优先，config.json 兜底。
@main
enum LLMSmoke {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let mode = args.first ?? "stream"
        let ok: Bool
        switch mode {
        case "chat": ok = await chatFlowSmoke()
        case "tone": ok = await toneSmoke(only: args.dropFirst().first.flatMap { Int($0) },
                                          baseline: args.contains("baseline"))
        default: ok = await streamSmoke()
        }
        exit(ok ? 0 : 1)
    }

    // MARK: - 单条流式

    @MainActor
    private static func streamSmoke() async -> Bool {
        let store = ConfigStore()
        guard let provider = store.value.activeProvider else {
            print("❌ config.json 没有 activeProvider"); return false
        }
        let key = provider.apiKey
        print("provider=\(provider.id) model=\(provider.model) key=\(key == nil ? "缺失" : "已配置")")
        if key == nil && provider.id != "ollama" {
            print("❌ 未配置 API key（config.json 的 apiKey 或设置界面填写）")
            return false
        }

        let service = LLMService(configStore: store)
        let messages = [
            ChatMessage.system("You are a helpful English tutor. Reply in one short sentence."),
            ChatMessage.user("Say hi and tell me a fun fact about the word 'serendipity'."),
        ]

        do {
            var received = 0
            print("———— 流式输出 ————")
            for try await delta in service.stream(messages) {
                print(delta, terminator: "")
                fflush(stdout)
                received += delta.count
            }
            print("\n———— 完成，共 \(received) 字符 ————")
            return true
        } catch {
            print("\n❌ \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 聊天端到端：开新会话 → 多轮对话 → 后台总结

    @MainActor
    private static func chatFlowSmoke() async -> Bool {
        // 临时目录隔离，不污染真实数据
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-chat-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let llm = LLMService(configStore: ConfigStore())
        let vm = ChatViewModel(llm: llm,
                               storeURL: dir.appendingPathComponent("sessions.json"))
        vm.openConversation()
        guard vm.activeSession != nil else { print("❌ 未自动开新会话"); return false }

        vm.input = "Hi! I went to a new coffee shop this morning and tried a pour-over for the first time."
        print("学生：\(vm.input)")
        await vm.send()

        if let error = vm.error { print("❌ 对话出错：\(error.message)"); return false }
        guard let turns = vm.activeSession?.turns, turns.count >= 2 else {
            print("❌ 轮数不足"); return false
        }
        if let last = turns.last, last.role == .assistant {
            print("伙伴：\(last.content.prefix(300))")
        }
        print("✓ 多轮对话完成（\(turns.count) turns）")

        await vm.summarizeActiveSessionIfNeeded()
        if let error = vm.error { print("❌ 总结出错：\(error.message)"); return false }
        guard let summary = vm.activeSession?.summary else { print("❌ 没有总结"); return false }

        if let brief = summary.brief {
            print("✓ 总结结构化解析成功")
            print("  总评：\(brief.prefix(120))")
            if let mistake = summary.mistakes?.first {
                print("  首条错句：\(mistake.original ?? "-") → \(mistake.correction ?? "-")")
            }
            return true
        }
        if let raw = summary.rawMarkdown {
            print("△ 总结降级为 rawMarkdown（前 200 字）：\(raw.prefix(200))")
            return true
        }
        print("❌ 总结既无结构化也无兜底")
        return false
    }

    // MARK: - TONE 评测：20 用例 × conversation 模式，按 11 条特征扫描中文讲解

    private struct ToneCase {
        /// 用户输入序列；多轮用例的每一轮 assistant 输出都进检查
        let turns: [String]
        /// 该用例主打的 TONE 风险点（打印标注，便于判读）
        let focus: String
    }

    private static let toneCases: [ToneCase] = [
        // 知识讲解类（诱导长中文讲解）
        .init(turns: ["affect 和 effect 有什么区别？老是搞混。"],
              focus: "词义辨析：翻案腔（不是…而是）/标签冒号/一二三编号"),
        .init(turns: ["英语邮件的开头和结尾怎么写才专业？"],
              focus: "罗列类：顿号串/空转句引列表"),
        .init(turns: ["帮我系统讲一下现在完成时，越详细越好。"],
              focus: "长讲解压测：全家桶（破折号/编号/喻体/翻译腔/同构）"),
        .init(turns: ["literally 这个词老外好像用得很随意，到底什么意思？"],
              focus: "语气词：翻案腔/段首零回指"),
        .init(turns: ["虚拟语气是什么？中文里好像没有对应的东西。"],
              focus: "概念讲解：翻译腔（当…时/对于…来说）/拟人喻体"),
        .init(turns: ["什么时候要加 the，什么时候不加？我总是搞混。"],
              focus: "规则罗列：一二三编号/空转句"),
        .init(turns: ["though、although、even though 有什么不一样？"],
              focus: "三词辨析：平级案例罗列/表格冒号"),
        .init(turns: ["怎么地道地说「我赶时间」？多给我几个场景。"],
              focus: "表达类：顿号串/揭晓式破折号"),
        .init(turns: ["actually 到底怎么用？感觉中文没有完全对应的词。"],
              focus: "副词：段首零回指/翻案腔"),
        .init(turns: ["raise 和 rise 我永远分不清，有没有好记的办法？"],
              focus: "配对动词：拟人喻体/翻案腔"),
        // 错句批改类（Tutor 核心：错句即教学时刻）
        .init(turns: ["I have went to the office yesterday, but my colleague wasn't there."],
              focus: "错句批改：讲解里的破折号/翻案腔"),
        .init(turns: ["He suggested me to go home early."],
              focus: "错句批改：suggest 句型，标签冒号"),
        .init(turns: ["I am agree with you."],
              focus: "错句批改：agree 词性，名词化讲解"),
        .init(turns: ["Despite of the rain, we still went hiking."],
              focus: "错句批改：despite of，翻译腔从句"),
        .init(turns: ["My hobby is listen to music and play basketball."],
              focus: "错句批改：动名词缺失，顿号串/排比"),
        // 多轮上下文类（压测回指与衔接）
        .init(turns: ["literally 到底怎么用？", "再给我两个例句，一个正式的一个日常的。"],
              focus: "两轮追问：段首零回指/编号"),
        .init(turns: ["I have finished this work yesterday.", "这个语法点能展开讲讲吗？"],
              focus: "两轮：回指承接+长讲解风险"),
        .init(turns: ["我们这段对话里我犯了哪些错？帮我总结一下。"],
              focus: "元总结：「这意味着」复述句/概括盖具体"),
        .init(turns: ["用中文给我讲讲 I was born in 1990 为什么用 was？born 不是形容词吗？"],
              focus: "深问：长前置定语/拟人喻体"),
        // 反向保护：TONE 不该矫枉过正
        .init(turns: ["有点无聊，随便陪我聊两句英文吧。"],
              focus: "反向保护：自然闲聊，问句应保留、不强行拆段/口语化"),
    ]

    private struct ToneFinding: CustomStringConvertible {
        enum Level { case hard, info }
        let name: String
        let level: Level
        let excerpt: String
        var description: String {
            "\(level == .hard ? "✗" : "?") \(name)：「\(excerpt)」"
        }
    }

    /// 11 条特征里正则可查的子集。概括盖具体、相邻句同构无法机器判定，汇总里提示人工必查。
    /// 空转句引列表定为 info：教学语境「比如：」+ 列表是常见合法形态，摘录供判读。
    private static let toneHardPatterns: [(name: String, pattern: String)] = [
        ("翻案腔", #"不是[^。!?\n]{1,24}而是|并非[^。!?\n]{1,24}而是|看似[^。!?\n]{1,24}实则"#),
        ("起手式", #"说白了|说穿了|先说结论"#),
        ("揭晓式破折号", #"——"#),
        ("标签冒号", #"(核心是|关键在于|原因如下|一句话总结|本质上|换句话说)[:：]"#),
        ("拟人化喻体", #"像一[位个][^,。!?\n]{0,14}(导师|秘书|助手|顾问|管家|教练|外教|伙伴)"#),
        ("当…时从句", #"当[^。!?\n]{8,40}时[,，。]"#),
        ("前置话题壳", #"(?m)^(对于|就|关于)[^。!?\n]{2,14}(来说|而言)"#),
        ("句首路标", #"(?m)^(然而|因此|此外|与此同时|换言之|总而言之)[,，]"#),
        ("序数词标题", #"(?m)^(?:#{1,6}\s*|\*\*)[一二三四五六七八九十][、.]"#),
    ]

    private static let toneInfoPatterns: [(name: String, pattern: String)] = [
        ("复述句(判读:是否新结论)", #"(?m)^这(意味着|表明|说明)"#),
        ("长前置定语(判读)", #"的[^,。;!?、\n]{16,}的"#),
        ("顿号串(判读:教学列举豁免)", #"、[^、,，。;;\n]{1,20}、"#),
    ]

    private static func toneFindings(in text: String) -> [ToneFinding] {
        var out: [ToneFinding] = []
        for (name, pattern) in toneHardPatterns + toneInfoPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for m in re.matches(in: text, range: range) where m.range.location != NSNotFound {
                let lo = max(0, m.range.location - 10)
                let hi = min(text.count, m.range.location + m.range.length + 20)
                let excerpt = String(text[text.index(text.startIndex, offsetBy: lo)..<text.index(text.startIndex, offsetBy: hi)])
                out.append(.init(name: name,
                                 level: toneHardPatterns.contains { $0.name == name } ? .hard : .info,
                                 excerpt: excerpt))
            }
        }
        // 行级规则：空转句引列表（行以冒号收尾、次行是列表项）
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if (line.hasSuffix(":") || line.hasSuffix("：")), i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let isList = next.hasPrefix("- ") || next.hasPrefix("* ")
                    || (next.count > 2 && next.first?.isNumber == true && next.dropFirst().first.map { "、.".contains($0) } == true)
                if isList {
                    out.append(.init(name: "空转句引列表(判读)", level: .info, excerpt: line))
                }
            }
            // 段首零回指：评论语开头且整行无回指词
            let openers = ["听起来", "看起来", "值得注意的是", "更重要的是", "关键在于", "问题在于", "不难看出"]
            if openers.contains(where: line.hasPrefix),
               !["这", "那", "其", "此"].contains(where: line.contains) {
                out.append(.init(name: "段首零回指", level: .hard, excerpt: line))
            }
        }
        return out
    }

    @MainActor
    private static func toneSmoke(only: Int?, baseline: Bool) async -> Bool {
        let store = ConfigStore()
        guard let provider = store.value.activeProvider else {
            print("❌ config.json 没有 activeProvider"); return false
        }
        if provider.apiKey == nil && provider.id != "ollama" {
            print("❌ 未配置 API key（config.json 的 apiKey 或设置界面填写）"); return false
        }
        print(baseline
            ? "———— TONE 评测（基线：无 TONE 规则）provider=\(provider.id) model=\(provider.model) ————"
            : "———— TONE 评测（conversation 模式）provider=\(provider.id) model=\(provider.model) ————")

        let service = LLMService(configStore: store)
        let system = ChatMessage.system(ChatPartner.systemPrompt(for: .conversation, includeTone: !baseline))
        let indices = only.map { [$0 - 1] } ?? Array(toneCases.indices)
        guard indices.allSatisfy(toneCases.indices.contains) else {
            print("❌ 用例号越界（1…\(toneCases.count)）"); return false
        }

        var hardTotal = 0, infoTotal = 0, turnCount = 0, turnsWithQuestion = 0
        for idx in indices {
            let c = toneCases[idx]
            print("\n———— 用例 \(idx + 1)/\(toneCases.count)：\(c.turns[0].prefix(36))…（\(c.focus)）————")
            var messages = [system]
            for turn in c.turns {
                messages.append(ChatMessage.user(turn))
                print("学生：\(turn)")
                var reply = ""
                do {
                    for try await delta in service.stream(messages) { reply += delta }
                } catch {
                    print("❌ 请求出错：\(error.localizedDescription)"); return false
                }
                messages.append(ChatMessage(role: .assistant, content: reply))
                print("老师：\n\(reply)")

                let findings = toneFindings(in: reply)
                if findings.isEmpty {
                    print("[TONE] ✅ 无命中")
                } else {
                    findings.forEach { print("  \($0)") }
                    hardTotal += findings.filter { $0.level == .hard }.count
                }
                infoTotal += findings.filter { $0.level == .info }.count
                turnCount += 1
                if reply.contains("?") || reply.contains("？") { turnsWithQuestion += 1 }
            }
        }

        print("\n———— 汇总 ————")
        print("用例 \(indices.count)/\(toneCases.count)，assistant 轮 \(turnCount)：hard 命中 \(hardTotal)，判读项 \(infoTotal)")
        print("反向保护：含问句的轮 \(turnsWithQuestion)/\(turnCount)（老师人设每轮应追问，过低说明矫枉过正）")
        print("人工必查（无正则）：概括盖具体（用例 18）、相邻句同构（用例 3/7/15）")
        if hardTotal > 0 {
            print("❌ 存在 hard 命中，TONE 规则未拦住")
            return false
        }
        print("✅ TONE 评测通过")
        return true
    }

}
