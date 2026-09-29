import Foundation

/// LookupPlacement.frame：面板放置公式（Cocoa 坐标）——下方优先、上方翻转、
/// 两侧不足压高、x/越界钳位、无锚点兜底
let lookupPanelTests: [TestCase] = [
    // 屏幕 visibleFrame (0,0,1440,875)；宿主窗 (100,200,440,600) → 窗顶 Cocoa y=800
    // 锚点 (50,100,80,20)（窗内左上原点）→ 选区 Cocoa：上沿 700、下沿 680、x0=150

    TestCase(name: "panel.place: 下方空间充足 → 贴选区下方 6pt、无高度上限") {
        let (frame, cap) = LookupPlacement.frame(
            anchor: CGRect(x: 50, y: 100, width: 80, height: 20),
            windowFrame: CGRect(x: 100, y: 200, width: 440, height: 600),
            cardSize: CGSize(width: 300, height: 200),
            visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        try expectEqual(frame.origin.x, 150)
        try expectEqual(frame.origin.y, 680 - 6 - 200) // 474
        try expectEqual(frame.size.height, 200)
        try expect(cap == .infinity, "空间充足不应压高")
    },

    TestCase(name: "panel.place: 下方不够上方够 → 翻到选区上方") {
        // 矮窗贴屏幕底：窗 (100,10,440,300) → 窗顶 310；选区上沿 210、下沿 190
        // 下方空间 190-6-0=184 < 200；上方 875-216=659 ≥ 200
        let (frame, cap) = LookupPlacement.frame(
            anchor: CGRect(x: 50, y: 100, width: 80, height: 20),
            windowFrame: CGRect(x: 100, y: 10, width: 440, height: 300),
            cardSize: CGSize(width: 300, height: 200),
            visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        try expectEqual(frame.origin.y, 210 + 6) // 面板底 = 选区上沿 + 6
        try expect(cap == .infinity)
    },

    TestCase(name: "panel.place: 两侧都不够 → 放空间大的一侧并压高返回 cap") {
        // 屏幕只剩 240 高：下方 184、上方 24 → 选下方，cap=184，卡片压到 184
        let (frame, cap) = LookupPlacement.frame(
            anchor: CGRect(x: 50, y: 100, width: 80, height: 20),
            windowFrame: CGRect(x: 100, y: 10, width: 440, height: 300),
            cardSize: CGSize(width: 300, height: 200),
            visible: CGRect(x: 0, y: 0, width: 1440, height: 240))
        try expectEqual(cap, 184)
        try expectEqual(frame.size.height, 184)
        try expectEqual(frame.origin.y, 4) // 190-6-184=0，再被安全钳抬到 visible.minY+4
    },

    TestCase(name: "panel.place: x 越右界 → 钳回屏幕内") {
        // 窄屏 500 宽：x0=400，右界 500-8-300=192
        let (frame, _) = LookupPlacement.frame(
            anchor: CGRect(x: 300, y: 100, width: 80, height: 20),
            windowFrame: CGRect(x: 100, y: 200, width: 440, height: 600),
            cardSize: CGSize(width: 300, height: 200),
            visible: CGRect(x: 0, y: 0, width: 500, height: 900))
        try expectEqual(frame.origin.x, 192)
    },

    TestCase(name: "panel.place: 无锚点（.zero）→ 贴宿主窗顶部下方兜底") {
        let (frame, _) = LookupPlacement.frame(
            anchor: .zero,
            windowFrame: CGRect(x: 100, y: 200, width: 440, height: 600),
            cardSize: CGSize(width: 300, height: 200),
            visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        try expectEqual(frame.origin.x, 124) // 窗左 + 24
        try expectEqual(frame.origin.y, 800 - 52 - 6 - 200) // 窗顶下 52 的“选区”下方
    },
]
