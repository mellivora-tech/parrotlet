import SwiftUI

@MainActor
let rainbowFlowBorderTests: [TestCase] = [
    TestCase(name: "border.geometry: 四段 90° 圆弧闭合，周长等于圆角矩形周长") {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let radius: CGFloat = 12
        let points = RainbowFlowBorderGeometry.perimeterPoints(rect: rect, radius: radius)
        try expect(points.count > 4)
        let first = points.first!, last = points.last!
        try expect(abs(first.x - last.x) < 0.0001 && abs(first.y - last.y) < 0.0001,
                   "末尾必须闭回起点，不能留下左上角缺口")
        // 圆弧每 15° 采样，实际周长是 24 根弦之和，而非连续圆周长。
        let expected = 2 * (rect.width + rect.height - 4 * radius)
            + 24 * 2 * radius * sin(CGFloat.pi / 24)
        try expect(abs(last.s - expected) < 0.0001,
                   "周长不符：\(last.s)，期望 \(expected)")
        for (a, b) in zip(points, points.dropFirst()) {
            try expect(b.s > a.s, "采样点不能重复或倒退")
        }
    },

    TestCase(name: "border.geometry: 描边内缩泛光半径并留抗锯齿余量") {
        let geometry = RainbowFlowBorderGeometry(size: CGSize(width: 400, height: 500),
                                                 cornerRadius: 12)
        let inset = RainbowFlowBorderGeometry.strokeInset
        try expectEqual(geometry.rect.minX, inset)
        try expectEqual(geometry.rect.minY, inset)
        try expectEqual(geometry.rect.width, 400 - 2 * inset)
        try expectEqual(geometry.rect.height, 500 - 2 * inset)
        try expectEqual(inset, RainbowFlowBorderGeometry.glowWidth / 2 + 0.5)
    },

    TestCase(name: "border.geometry: 分段描边使用圆端帽和圆连接") {
        let style = RainbowFlowBorderGeometry.strokeStyle(lineWidth: 4)
        try expect(style.lineCap == .round, "平端帽会在圆角接缝留下楔形缺口")
        try expect(style.lineJoin == .round)
        try expectEqual(style.lineWidth, 4)
    },

    TestCase(name: "border.comet: 亮尾位于运动方向后方，跨零点方向不反转") {
        let total: CGFloat = 1000
        let behind = RainbowFlowBorderGeometry.cometIntensity(at: 490, head: 500, total: total)
        let ahead = RainbowFlowBorderGeometry.cometIntensity(at: 510, head: 500, total: total)
        try expect(behind > 0.9, "头部后方 1% 周长处应接近全亮，实际 \(behind)")
        try expectEqual(ahead, 0, "头部前方不应出现亮尾")
        let wrappedBehind = RainbowFlowBorderGeometry.cometIntensity(at: 40, head: 50, total: total)
        let wrappedAhead = RainbowFlowBorderGeometry.cometIntensity(at: 60, head: 50, total: total)
        try expect(wrappedBehind > 0.9)
        try expectEqual(wrappedAhead, 0)
    },

    TestCase(name: "border.comet: 有限尾迹在半圈处连续归零") {
        let total: CGFloat = 1000
        let beforeEnd = RainbowFlowBorderGeometry.cometIntensity(at: 1, head: 500, total: total)
        let atEnd = RainbowFlowBorderGeometry.cometIntensity(at: 0, head: 500, total: total)
        let beyondEnd = RainbowFlowBorderGeometry.cometIntensity(at: 600, head: 500, total: total)
        try expect(beforeEnd >= 0 && beforeEnd < 0.001, "尾迹末端应趋近于零，实际 \(beforeEnd)")
        try expectEqual(atEnd, 0)
        try expectEqual(beyondEnd, 0)
    },

    TestCase(name: "border.clock: 暂停冻结相位，恢复从原位置继续") {
        var clock = RainbowFlowPhaseClock()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        clock.setFlowing(true, at: start)
        try expectEqual(clock.elapsed(at: start.addingTimeInterval(3)), 3)
        clock.setFlowing(false, at: start.addingTimeInterval(3))
        try expectEqual(clock.elapsed(at: start.addingTimeInterval(10)), 3,
                        "暂停 7 秒不能累计墙钟时间")
        clock.setFlowing(true, at: start.addingTimeInterval(10))
        try expectEqual(clock.elapsed(at: start.addingTimeInterval(10)), 3,
                        "恢复瞬间相位必须连续")
        clock.setFlowing(true, at: start.addingTimeInterval(11))
        try expectEqual(clock.elapsed(at: start.addingTimeInterval(11)), 4,
                        "重复恢复不能重置起点")
        try expectEqual(clock.elapsed(at: start.addingTimeInterval(10.25)), 3.25)
    },

    TestCase(name: "border.lifecycle: Reduce Motion 不保留补圈宽限") {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let until = now.addingTimeInterval(6)
        try expect(RainbowFlowBorder.shouldRun(active: false, minimumUntil: until,
                                               reduceMotion: false, now: now))
        try expect(!RainbowFlowBorder.shouldRun(active: false, minimumUntil: until,
                                                reduceMotion: true, now: now))
        try expect(RainbowFlowBorder.shouldRun(active: true, minimumUntil: nil,
                                               reduceMotion: true, now: now))
        try expect(!RainbowFlowBorder.shouldRun(active: false, minimumUntil: until,
                                                reduceMotion: false, now: until))
    },

    TestCase(name: "border.lifecycle: 贴边隐藏与 Reduce Motion 都暂停流动") {
        try expect(RainbowFlowBorder.shouldFlow(running: true, reduceMotion: false, paused: false))
        try expect(!RainbowFlowBorder.shouldFlow(running: true, reduceMotion: false, paused: true))
        try expect(!RainbowFlowBorder.shouldFlow(running: true, reduceMotion: true, paused: false))
        try expect(!RainbowFlowBorder.shouldFlow(running: false, reduceMotion: false, paused: false))
    },
]
