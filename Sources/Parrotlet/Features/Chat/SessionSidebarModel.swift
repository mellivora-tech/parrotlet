import AppKit
import Foundation

/// 会话侧栏的纯逻辑：列表过滤 + 开合的窗口宽度数学（抽出供单测）。

/// 会话列表过滤：标题 + 全部发言内容，大小写/音调不敏感（localizedStandardContains）
enum SessionListFilter {
    static func filter(_ sessions: [ChatSession], query: String,
                       fallbackTitle: String = "新对话") -> [ChatSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayTitle(fallback: fallbackTitle).localizedStandardContains(q)
                || session.turns.contains { $0.content.localizedStandardContains(q) }
        }
    }
}

/// 侧栏开合的几何常量与换算。
/// 展开：聊天列视觉位置不动，窗口向左扩出侧栏宽度（贴屏幕左缘放不下才向右扩；
///   右扩再越界（屏幕太窄）则钳回可见区，极端窄屏压到可见区宽、聊天列让位）
/// 收起：从左侧收回侧栏宽（origin.x += w），聊天列原地不动——与展开的左扩镜像；
///   右扩过的窗口收起后会脱离左缘，聊天列不动优先于贴缘
enum SidebarLayout {
    /// 侧栏固定宽度
    static let width: CGFloat = 220

    static func targetFrame(current f: NSRect, pinning: Bool,
                            visibleFrame vf: NSRect,
                            sidebarWidth w: CGFloat = width) -> NSRect {
        var t = f
        if pinning {
            t.size.width += w
            if f.minX - w >= vf.minX {
                t.origin.x = f.minX - w            // 左侧有空间 → 向左扩
            } else if t.maxX > vf.maxX {
                t.origin.x = max(vf.minX, vf.maxX - t.width)   // 右扩越界 → 钳回
            }
            // 退化场景：加宽后比整屏还宽（屏宽 < 660）→ 压到可见区宽，聊天列让位
            if t.width > vf.width {
                t.size.width = vf.width
                t.origin.x = vf.minX
            }
        } else {
            t.origin.x += w
            t.size.width -= w
        }
        return t
    }

    /// 窗口整宽 → 聊天列宽：展开时扣除侧栏宽。
    /// WindowConfigurator 的 onWindowResize 上报的是整窗内容宽，喂输入框宽度前必须过这层，
    /// 否则展开时 TextField 显式宽度被撑大 220pt、折行失效
    static func chatColumnWidth(windowContentWidth w: CGFloat, pinned: Bool) -> CGFloat {
        w - (pinned ? width : 0)
    }
}
