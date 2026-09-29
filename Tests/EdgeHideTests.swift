import AppKit

// EdgeHideController 的纯几何判定：贴边选边 + 三边热区。
// 状态机本身依赖真实窗口/光标，几何规则抽成纯函数在这里锁行为。

let edgeHideTests: [TestCase] = [
    // MARK: snapEdge（vf 取本机常见形态：含菜单栏/ Dock 的可见区）
    TestCase(name: "edgeHide.snapEdge.三边吸附") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)  // maxY = 1860
        // 顶边：窗口顶与可见区顶对齐（可略超出）
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 500, y: 1860 - 354, width: 440, height: 354), in: vf), .top)
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 500, y: 1860 + 20 - 354, width: 440, height: 354), in: vf), .top)
        // 左边：窗口左缘贴可见区左缘
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 10, y: 600, width: 440, height: 354), in: vf), .left)
        // 右边：窗口右缘贴可见区右缘
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 3360 - 440 + 10, y: 600, width: 440, height: 354), in: vf), .right)
    },
    TestCase(name: "edgeHide.snapEdge.不贴边与角落优先顶") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        // 屏幕中央：不吸附
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 1000, y: 600, width: 440, height: 354), in: vf), nil)
        // 超阈值：不吸附
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: EdgeHideController.snapThreshold + 1, y: 600, width: 440, height: 354),
            in: vf), nil)
        // 左上角同时贴两边：顶优先（QQ 拖到角落也是往上吸）
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 0, y: 1860 - 354, width: 440, height: 354), in: vf), .top)
    },
    TestCase(name: "edgeHide.snapEdge.拖拽过冲推出屏外仍吸附") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        // macOS 允许侧向拖出屏外（实测右缘能超出 287pt）——越过边缘同样是贴边
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 3360 + 287 - 440, y: 600, width: 440, height: 354), in: vf), .right)
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: -100, y: 600, width: 440, height: 354), in: vf), .left)
        // 顶边过冲：窗口顶高出可见区顶
        try expectEqual(EdgeHideController.snapEdge(
            for: NSRect(x: 500, y: 1860 + 40, width: 440, height: 354), in: vf), .top)
    },
    TestCase(name: "edgeHide.isTileLike.平铺尺寸识别") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        // 全屏 / 半屏 / 四分之一 tile 全命中
        try expect(EdgeHideController.isTileLike(NSRect(x: 0, y: 90, width: 3360, height: 1770), in: vf))
        try expect(EdgeHideController.isTileLike(NSRect(x: 0, y: 90, width: 1680, height: 1770), in: vf))
        try expect(EdgeHideController.isTileLike(NSRect(x: 0, y: 90, width: 1680, height: 885), in: vf))
        // 正常窗口与用户缩放上限（1200 宽 = 36%）不误伤
        try expect(!EdgeHideController.isTileLike(NSRect(x: 500, y: 400, width: 440, height: 640), in: vf))
        try expect(!EdgeHideController.isTileLike(NSRect(x: 500, y: 90, width: 1200, height: 1770), in: vf))
    },

    // MARK: inHotZone
    TestCase(name: "edgeHide.inHotZone.顶边命中与不命中") {
        let frame = NSRect(x: 500, y: 0, width: 440, height: 640)
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)   // 顶 1860
        let sf = NSRect(x: 0, y: 0, width: 3360, height: 1890)
        func hit(_ p: NSPoint) -> Bool {
            EdgeHideController.inHotZone(cursor: p, edge: .top, screen: sf, visibleFrame: vf, hiddenFrame: frame)
        }
        try expect(hit(NSPoint(x: 720, y: 1859)))                  // 顶边下 1pt
        try expect(hit(NSPoint(x: 720, y: 1852)))                  // 恰在热区深度边界
        try expect(hit(NSPoint(x: 720, y: 1880)))                  // 没入菜单栏带
        try expect(hit(NSPoint(x: frame.minX - EdgeHideController.hotZoneSlack, y: 1859)))  // 左放宽
        try expect(!hit(NSPoint(x: 720, y: 1851)))                 // 低于热区
        try expect(!hit(NSPoint(x: frame.minX - EdgeHideController.hotZoneSlack - 1, y: 1859)))
        try expect(!hit(NSPoint(x: frame.maxX + EdgeHideController.hotZoneSlack + 1, y: 1859)))
    },
    TestCase(name: "edgeHide.inHotZone.侧边命中与不命中") {
        // 侧边隐藏时窗口 x 已出屏，但 y 范围还在屏上，热区沿 y 判定
        let frame = NSRect(x: -444, y: 600, width: 440, height: 354)  // y 600..954
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        let sf = NSRect(x: 0, y: 0, width: 3360, height: 1890)
        func hitLeft(_ p: NSPoint) -> Bool {
            EdgeHideController.inHotZone(cursor: p, edge: .left, screen: sf, visibleFrame: vf, hiddenFrame: frame)
        }
        try expect(hitLeft(NSPoint(x: 0, y: 800)))                 // 左缘，y 在窗口范围内
        try expect(hitLeft(NSPoint(x: EdgeHideController.hotZoneDepth, y: 800)))  // 热区深度边界
        try expect(hitLeft(NSPoint(x: 2, y: 600 - EdgeHideController.hotZoneSlack)))  // 下放宽
        try expect(!hitLeft(NSPoint(x: EdgeHideController.hotZoneDepth + 1, y: 800)))
        try expect(!hitLeft(NSPoint(x: 2, y: 954 + EdgeHideController.hotZoneSlack + 1)))  // 超出上放宽

        func hitRight(_ p: NSPoint) -> Bool {
            EdgeHideController.inHotZone(cursor: p, edge: .right, screen: sf, visibleFrame: vf, hiddenFrame: frame)
        }
        try expect(hitRight(NSPoint(x: 3359, y: 800)))             // 右缘
        try expect(hitRight(NSPoint(x: 3360 - EdgeHideController.hotZoneDepth, y: 800)))
        try expect(!hitRight(NSPoint(x: 3360 - EdgeHideController.hotZoneDepth - 1, y: 800)))
        try expect(!hitRight(NSPoint(x: 3359, y: 600 - EdgeHideController.hotZoneSlack - 1)))
    },
]
