import Foundation

/// SSE 逐行解析（纯函数，无 IO，可单测）。
///
/// 关键前提：上游用 `URLSession.AsyncBytes.lines` 读流，而它**会丢弃空行**
/// （本机 macOS 26.5 实测），SSE 规范里作为事件边界的空行根本到不了解析器。
/// 因此这里不做规范式的「多行 data 聚合 + 空行触发」——那会把两个连续事件
/// 用 \n 拼成一个非法 JSON。改为：**一行 `data:` 即一个完整事件**。
/// OpenAI 系聊天流都是单行 data，与规范行为无差别。
///
/// 处理的规范子集：
/// - `data: <载荷>` / `data:<载荷>`（冒号后空格可选）
/// - `data: [DONE]` → `.done`（OpenAI 系哨兵）
/// - `:` 开头（注释/keep-alive）与 `event:`/`id:`/`retry:` 一律忽略
struct SSEParser {
    enum Output: Equatable, Sendable {
        case data(String)
        case done
    }

    /// 喂入一行（不含换行符；结尾 \r 兜底剥掉）。是 data 行则返回事件，否则 nil。
    func consume(_ rawLine: String) -> Output? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return nil }
        if line.hasPrefix(":") { return nil }
        guard line.hasPrefix("data:") else { return nil }

        let rest = line.dropFirst("data:".count)
        let payload = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        return payload.trimmingCharacters(in: .whitespaces) == "[DONE]" ? .done : .data(payload)
    }
}
