import SwiftUI

/// 把 markdown 文本切成块级段落：段落 / 标题 / 列表项 / 分隔线 / 引用块 / 围栏代码块。
/// macOS 的 AttributedString 只渲染行内语法（粗体/斜体/行内代码），段落级样式
/// （标题、列表圆点）由 AssistantBody 按块自绘。围栏代码块（```）内的符号不解析。
enum MarkdownBlocks {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedItem(String)
        case orderedItem(Int, String)
        case divider
        case quote(String)
        case codeBlock(String)
        /// 管道表格：首行表头，|---| 分隔行已剔除；各行单元格数已补齐到列数
        case table(header: [String], rows: [[String]])
    }

    /// 表格分隔行单元格判定：`:---:` / `---` / `:--` 等
    private static func isSeparatorCell(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return !t.isEmpty && t.allSatisfy { $0 == "-" }
    }

    static func split(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var code: [String] = []
        var tableLines: [String] = []
        var inFence = false

        func flushPara() {
            guard !para.isEmpty else { return }
            blocks.append(.paragraph(para.joined(separator: "\n")))
            para = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            var rows = tableLines.map { line -> [String] in
                var s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("|") { s.removeFirst() }
                if s.hasSuffix("|") { s.removeLast() }
                return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            rows.removeAll { row in !row.isEmpty && row.allSatisfy(isSeparatorCell) }
            let columns = rows.map(\.count).max() ?? 0
            rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
            if let header = rows.first, columns > 0 {
                blocks.append(.table(header: header, rows: Array(rows.dropFirst())))
            }
            tableLines = []
        }
        func flushAll() {
            flushPara()
            flushQuote()
            flushTable()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.codeBlock(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushAll()
                }
                inFence.toggle()
                continue
            }
            if inFence { code.append(line); continue }

            if line.hasPrefix(">") {
                flushPara()
                flushTable()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            // 管道表格行：| 开头且至少两格
            if trimmed.hasPrefix("|"), trimmed.filter({ $0 == "|" }).count >= 2 {
                flushPara()
                tableLines.append(line)
                continue
            }
            flushTable()

            if trimmed.isEmpty { flushPara(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara()
                blocks.append(.divider)
                continue
            }
            // ATX 标题：1-6 个 # 后跟空格
            var hashes = 0
            while hashes < trimmed.count &&
                    trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)] == "#" { hashes += 1 }
            if hashes > 0, trimmed.count > hashes,
               trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)] == " " {
                flushPara()
                blocks.append(.heading(level: min(hashes, 6),
                                       text: String(trimmed.dropFirst(hashes + 1))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushPara()
                blocks.append(.unorderedItem(String(trimmed.dropFirst(2))))
                continue
            }
            if let m = trimmed.firstMatch(of: #/^(\d+)\.\s+(.*)$/#) {
                flushPara()
                blocks.append(.orderedItem(Int(m.1) ?? 1, String(m.2)))
                continue
            }
            para.append(line)
        }
        flushAll()
        // 未闭合围栏：兜底为代码块，不吞内容
        if inFence, !code.isEmpty { blocks.append(.codeBlock(code.joined(separator: "\n"))) }
        return blocks
    }
}

/// 渲染缓存：split/attributed 是纯解析但都在 body 里被调用——打字（vm.input 每击键变）
/// 和流式（每次 flush）都触发全树重渲染，历史消息内容不变，解析结果直接复用。
/// 容量封顶整体清空：命中集中在历史消息（稳定文本），周期性全清不损主路径；
/// 流式中间态文本是垃圾键，封顶防它们把缓存撑爆。只供视图层用（@MainActor），
/// 测试继续走 MarkdownBlocks.split / MarkdownText.attributed 纯函数入口。
@MainActor
enum MarkdownRenderCache {
    private static var blocksCache: [String: [MarkdownBlocks.Block]] = [:]
    private static var attributedCache: [String: AttributedString] = [:]
    private static let capacity = 300

    static func blocks(for text: String) -> [MarkdownBlocks.Block] {
        if let cached = blocksCache[text] { return cached }
        let blocks = MarkdownBlocks.split(text)
        if blocksCache.count >= capacity { blocksCache.removeAll(keepingCapacity: true) }
        blocksCache[text] = blocks
        return blocks
    }

    static func attributed(_ text: String) -> AttributedString {
        if let cached = attributedCache[text] { return cached }
        let value = MarkdownText.attributed(text)
        if attributedCache.count >= capacity { attributedCache.removeAll(keepingCapacity: true) }
        attributedCache[text] = value
        return value
    }
}

/// Text(变量) 不解析 markdown——统一从这里渲染富文本。
/// 固定 inlineOnlyPreservingWhitespace：只处理粗体/斜体/行内代码等行内语法，保留换行。
/// 段落级样式（标题/列表/引用/表格）由 MarkdownBlocks 切块后自绘，不走这里。
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(MarkdownRenderCache.attributed(text))
    }

    nonisolated static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: fixCJKFlanking(text), options: options))
            ?? AttributedString(text)
    }

    /// CommonMark flanking 规则的中英混排死法兜底：** 前贴汉字/字母、后接引号等标点时
    /// 被判成普通字符不渲染（模型常写 在**"work"**这里）。规范要求该形状前必须是空白/标点，
    /// 这里在死掉的定界符旁补 U+200A 发髻空格（Zs 空白、近乎不可见）让它复活。
    /// 定界符角色靠「同长度星号 run 顺序配对（奇开偶闭）」判断——局部字符无法区分
    /// 西**。 是闭（合法勿动）还是 在**" 是开（要修），纯正则双向互杀过。
    nonisolated static func fixCJKFlanking(_ text: String) -> String {
        let hairSpace = "\u{200A}"
        let scalars = Array(text.unicodeScalars)
        // 0=空白 1=标点 2=其他（字母/数字/汉字）
        func classOf(_ i: Int) -> Int {
            guard i >= 0, i < scalars.count else { return 0 }
            let s = scalars[i]
            if s.value == 0x200A || CharacterSet.whitespacesAndNewlines.contains(s) { return 0 }
            if CharacterSet.punctuationCharacters.contains(s) { return 1 }
            return 2
        }
        // 收集星号 run（起始 scalar 下标, 长度）
        var runs: [(start: Int, len: Int)] = []
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "*" else { i += 1; continue }
            var j = i
            while j < scalars.count && scalars[j] == "*" { j += 1 }
            runs.append((i, j - i))
            i = j
        }
        var pendingOpen: [Int: Bool] = [:]   // run 长度 → 是否有待闭合的开
        var inserts: [(pos: Int, text: String)] = []
        for (start, len) in runs where len <= 2 {
            let isOpener = !(pendingOpen[len] ?? false)
            let before = classOf(start - 1), after = classOf(start + len)
            if isOpener {
                if before == 2 && after == 1 { inserts.append((start, hairSpace)) }   // 死开：前插
                pendingOpen[len] = true
            } else {
                if before == 1 && after == 2 { inserts.append((start + len, hairSpace)) } // 死闭：后插
                pendingOpen[len] = false
            }
        }
        var out = text
        for (pos, s) in inserts.sorted(by: { $0.pos > $1.pos }) {   // 从后往前插，偏移不失效
            let scalarIdx = out.unicodeScalars.index(out.unicodeScalars.startIndex, offsetBy: pos)
            out.insert(contentsOf: s, at: String.Index(scalarIdx, within: out)!)
        }
        return out
    }
}
