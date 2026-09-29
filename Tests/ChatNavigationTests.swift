import Foundation

/// ChatNavigation：轮次指示器纯逻辑（配对 / 浮点当前轮 / 窗口目标 / 簇几何 / 边缘渐变 / 命中）
let chatNavigationTests: [TestCase] = [

    TestCase(name: "nav.pairRounds: user 开轮、紧随的 assistant 归本轮") {
        let turns = [
            DialogueTurn(role: .user, content: "q1"),
            DialogueTurn(role: .assistant, content: "a1"),
            DialogueTurn(role: .user, content: "q2"),
            DialogueTurn(role: .assistant, content: "a2"),
        ]
        let rounds = ChatNavigation.pairRounds(turns)
        try expectEqual(rounds.count, 2)
        try expectEqual(rounds[0], ChatRound(userIndex: 0, assistantIndex: 1))
        try expectEqual(rounds[1], ChatRound(userIndex: 2, assistantIndex: 3))
    },

    TestCase(name: "nav.pairRounds: 无 assistant 的轮 assistantIndex 为 nil（被打断/流式中）") {
        let turns = [
            DialogueTurn(role: .user, content: "q1"),
            DialogueTurn(role: .user, content: "q2"),   // 连续两条 user 各成一轮
            DialogueTurn(role: .assistant, content: "a2"),
        ]
        let rounds = ChatNavigation.pairRounds(turns)
        try expectEqual(rounds.count, 2)
        try expectEqual(rounds[0].assistantIndex, nil)
        try expectEqual(rounds[1].assistantIndex, 2)
    },

    TestCase(name: "nav.currentFloat: 视口中线按比例映射到轮，范围钳 [0, R-1]") {
        // 内容 4000、视口 500：offset 0 时中线在 250 → 250/4000×40 = 2.5 轮
        let cf = ChatNavigation.currentFloat(offset: 0, viewportHeight: 500,
                                             contentHeight: 4000, rounds: 40)
        try expect(abs(cf - 2.5) < 0.001, "中线映射偏差: \(cf)")
        // 滚到底：offset 3500 → 中线 3750 → 37.5
        let cf2 = ChatNavigation.currentFloat(offset: 3500, viewportHeight: 500,
                                              contentHeight: 4000, rounds: 40)
        try expect(abs(cf2 - 37.5) < 0.001, "底部映射偏差: \(cf2)")
        // 越界钳位（中线移出内容才算越界：offset −300 时中线 −50）
        try expectEqual(ChatNavigation.currentFloat(offset: -300, viewportHeight: 500,
                                                    contentHeight: 4000, rounds: 40), 0)
        try expectEqual(ChatNavigation.currentFloat(offset: 99999, viewportHeight: 500,
                                                    contentHeight: 4000, rounds: 40), 39)
        try expectEqual(ChatNavigation.currentFloat(offset: 0, viewportHeight: 500,
                                                    contentHeight: 0, rounds: 40), 0)
    },

    TestCase(name: "nav.targetStart: ≤30 轮恒 0；超出后当前轮居中、两端钳位") {
        try expectEqual(ChatNavigation.targetStart(currentFloat: 20, rounds: 30), 0)
        try expectEqual(ChatNavigation.targetStart(currentFloat: 20, rounds: 16), 0)
        // 45 轮：居中 → cf − 15
        try expectEqual(ChatNavigation.targetStart(currentFloat: 25, rounds: 45), 10)
        // 低端钳 0
        try expectEqual(ChatNavigation.targetStart(currentFloat: 3, rounds: 45), 0)
        // 高端钳 R − 30
        try expectEqual(ChatNavigation.targetStart(currentFloat: 44, rounds: 45), 15)
        // 浮点直通（滚动联动的亚格级滑动）
        try expect(abs(ChatNavigation.targetStart(currentFloat: 25.4, rounds: 45) - 10.4) < 0.001)
    },

    TestCase(name: "nav.clusterPitch: 常规固定 14，矮窗口压缩适配") {
        try expectEqual(ChatNavigation.clusterPitch(railHeight: 800, count: 30), 14)
        // 400×0.9/30 = 12 < 14 → 压缩
        try expectEqual(ChatNavigation.clusterPitch(railHeight: 400, count: 30), 12)
        try expectEqual(ChatNavigation.clusterPitch(railHeight: 800, count: 0), 14)
    },

    TestCase(name: "nav.bandTop: 刻度簇垂直居中") {
        // (800 − 30×14)/2 = 190
        try expectEqual(ChatNavigation.bandTop(railHeight: 800, count: 30, pitch: 14), 190)
    },

    TestCase(name: "nav.topFor/edgeOpacity: 槽位浮点定位，簇边缘一根渐变、界外全透") {
        let y = ChatNavigation.topFor(round: 10, shown: 5, bandTop: 190, pitch: 14)
        try expectEqual(y, 190 + 5 * 14 + 7)   // x = 10 − 5 = 5 槽
        try expectEqual(ChatNavigation.edgeOpacity(x: 5, count: 30), 1)
        try expectEqual(ChatNavigation.edgeOpacity(x: 0, count: 30), 1)
        try expectEqual(ChatNavigation.edgeOpacity(x: 29, count: 30), 1)
        try expectEqual(ChatNavigation.edgeOpacity(x: -0.5, count: 30), 0.5)
        try expectEqual(ChatNavigation.edgeOpacity(x: 29.5, count: 30), 0.5)
        try expectEqual(ChatNavigation.edgeOpacity(x: -1, count: 30), 0)
        try expectEqual(ChatNavigation.edgeOpacity(x: 30, count: 30), 0)
    },

    TestCase(name: "nav.visibleRange: 两侧各多一根缓冲，不越界") {
        try expectEqual(ChatNavigation.visibleRange(shown: 10, count: 30, total: 45), 9...40)
        try expectEqual(ChatNavigation.visibleRange(shown: 0, count: 30, total: 45), 0...30)
        try expectEqual(ChatNavigation.visibleRange(shown: 15, count: 30, total: 45), 14...44)
        try expectEqual(ChatNavigation.visibleRange(shown: 0, count: 16, total: 16), 0...15)
    },

    TestCase(name: "nav.nearestRound: 容差内命中最近轮，容差外落空") {
        // shown 0、bandTop 190、pitch 14：第 r 根中心 = 197 + 14r
        let hit = ChatNavigation.nearestRound(y: 197 + 14 * 5 + 6, shown: 0, bandTop: 190,
                                              pitch: 14, total: 16, tol: 7)
        try expectEqual(hit, 5)
        // 相邻刻度间距 14 = 2×容差 7，刻度之间无空窗——只有越出端点才落空
        let miss = ChatNavigation.nearestRound(y: 197 - 10, shown: 0, bandTop: 190,
                                               pitch: 14, total: 16, tol: 7)
        try expectEqual(miss, nil)
        // 197+14×5+8 = 275：距第 5 根 8、距第 6 根 6——点击容差 14 时命中最近的第 6 根
        let clicked = ChatNavigation.nearestRound(y: 197 + 14 * 5 + 8, shown: 0, bandTop: 190,
                                                  pitch: 14, total: 16, tol: 14)
        try expectEqual(clicked, 6)
        // 光标在簇外也钳到端点的轮
        let clamped = ChatNavigation.nearestRound(y: 190 - 30, shown: 0, bandTop: 190,
                                                  pitch: 14, total: 16, tol: 40)
        try expectEqual(clamped, 0)
    },

    TestCase(name: "nav.plainSummary: 剥标记、跳代码块、折空行、限行数") {
        let md = """
        # 标题行
        **不是**，程度差`很多`。

        - 列表项一
        > 引用行
        ```swift
        let x = 1
        ```
        第五行
        第六行
        """
        let s = ChatNavigation.plainSummary(md, maxLines: 3)
        try expectEqual(s, "标题行\n不是，程度差很多。\n列表项一")
        // 代码块内容不进摘要
        try expect(!s.contains("let x"), "代码块泄漏进摘要")
        // maxLines 大于实际行数时全给
        let full = ChatNavigation.plainSummary(md, maxLines: 99)
        try expect(full.contains("第六行"), "行数上限误伤")
        // 空输入
        try expectEqual(ChatNavigation.plainSummary("", maxLines: 3), "")
        try expectEqual(ChatNavigation.plainSummary("```\ncode\n```", maxLines: 3), "")
    },
]
