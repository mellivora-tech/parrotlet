import Foundation

/// 回看导航纯逻辑：左缘轮次指示器（对齐 Codex 实机形态，HTML 原型逐条冻结）。
/// 等距刻度簇（≤30 根）垂直居中于消息区，不铺满、不映射内容长度；超出 30 轮后
/// 窗口跟随滚动，窗口起点为浮点——随滚动亚格级滑动（滚动联动），由 View 层做弹性平滑。
/// 全部无状态纯函数，供单测；View 只负责渲染与交互。

/// 一轮 = 一条用户提问 + 紧随的 AI 回复（流式中回复还没落盘，assistantIndex 为 nil）。
struct ChatRound: Equatable, Sendable {
    let userIndex: Int
    let assistantIndex: Int?
}

enum ChatNavigation {
    /// 刻度簇上限（Codex 实机确认：超出后窗口跟随，总数恒 30）
    static let maxTicks = 30
    /// 等距间距；刻度簇高于轨道 90% 时压缩适配（矮窗口兜底）
    static let pitch: CGFloat = 14

    /// 把 turns 按「用户提问开轮，其后紧跟的 assistant 归入本轮」分组。
    /// 连续两条 user 之间无 assistant（异常/被打断）也各成一轮，assistantIndex 为 nil。
    static func pairRounds(_ turns: [DialogueTurn]) -> [ChatRound] {
        var rounds: [ChatRound] = []
        for (i, t) in turns.enumerated() where t.role == .user {
            let next = (i + 1 < turns.count && turns[i + 1].role == .assistant) ? i + 1 : nil
            rounds.append(ChatRound(userIndex: i, assistantIndex: next))
        }
        return rounds
    }

    /// 当前轮（浮点 0...R-1）。SwiftUI 拿不到每条消息的真实 Y（PreferenceKey 不上报 /
    /// onGeometryChange 遇 .id 重建失聪，见 ChatView 头注释），按滚动比例均摊：
    /// 视口中线落在内容的哪个分数，就落在第几轮的哪个分数。
    static func currentFloat(offset: CGFloat, viewportHeight: CGFloat,
                             contentHeight: CGFloat, rounds: Int) -> CGFloat {
        guard rounds > 0, contentHeight > 0 else { return 0 }
        let mid = offset + viewportHeight / 2
        return min(max(mid / contentHeight * CGFloat(rounds), 0), CGFloat(rounds - 1))
    }

    /// 窗口起点目标：当前轮尽量居中，两端钳位；总数不超上限恒为 0
    static func targetStart(currentFloat cf: CGFloat, rounds: Int, maxTicks: Int = maxTicks) -> CGFloat {
        guard rounds > maxTicks else { return 0 }
        return min(max(cf - CGFloat(maxTicks / 2), 0), CGFloat(rounds - maxTicks))
    }

    /// 刻度间距：固定 14；矮窗口时刻度簇过高则压缩适配
    static func clusterPitch(railHeight: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return pitch }
        return min(pitch, railHeight * 0.9 / CGFloat(count))
    }

    /// 刻度簇垂直居中
    static func bandTop(railHeight: CGFloat, count: Int, pitch: CGFloat) -> CGFloat {
        (railHeight - CGFloat(count) * pitch) / 2
    }

    /// 轮 round 的刻度中心 Y（轨道本地坐标）；round - shown 即槽位浮点 x
    static func topFor(round: Int, shown: CGFloat, bandTop: CGFloat, pitch: CGFloat) -> CGFloat {
        bandTop + (CGFloat(round) - shown) * pitch + pitch / 2
    }

    /// 簇边缘渐变：槽位 x 在 [-1, 0] / [count-1, count] 内不透明度 0→1 渐变，
    /// 进出不跳变，同时暗示「外面还有」
    static func edgeOpacity(x: CGFloat, count: Int) -> CGFloat {
        min(max(min(x + 1, CGFloat(count) - x), 0), 1)
    }

    /// 参与渲染的轮范围（两侧各多一根做渐变缓冲）
    static func visibleRange(shown: CGFloat, count: Int, total: Int) -> ClosedRange<Int> {
        guard total > 0 else { return 0...0 }
        let lo = max(0, Int(floor(shown)) - 1)
        let hi = min(total - 1, Int(ceil(shown + CGFloat(count - 1))) + 1)
        return lo...max(lo, hi)
    }

    /// 光标 Y → 最近轮：容差内才算命中（hover 预览 ±7、点击跳转 ±14 共用一个函数）
    static func nearestRound(y: CGFloat, shown: CGFloat, bandTop: CGFloat, pitch: CGFloat,
                             total: Int, tol: CGFloat) -> Int? {
        guard total > 0 else { return nil }
        let x = (y - bandTop - pitch / 2) / pitch + shown
        let r = min(max(Int(x.rounded()), 0), total - 1)
        let d = abs(topFor(round: r, shown: shown, bandTop: bandTop, pitch: pitch) - y)
        return d <= tol ? r : nil
    }

    /// 预览卡的纯文本摘要（方案 A：摘要卡，不渲 markdown）：剥掉粗斜体/行内码/标题/
    /// 列表/引用标记，跳过代码块，空行折叠，最多 maxLines 行，"\n" 连接。
    /// 职责是「认出哪一轮」，不保真排版——真要看内容就跳过去。
    static func plainSummary(_ markdown: String, maxLines: Int) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") {
                line = String(line.dropFirst(2))
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.count >= maxLines { break }
        }
        return lines.joined(separator: "\n")
    }
}
