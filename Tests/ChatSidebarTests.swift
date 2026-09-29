import AppKit
import Foundation

// 会话侧栏纯逻辑：列表过滤 / 输入框宽度补偿。

let chatSidebarTests: [TestCase] = [
    // MARK: SessionListFilter
    TestCase(name: "sidebar.filter.空查询原样返回") {
        let sessions = [makeSidebarSession(title: "徒步计划"), makeSidebarSession(first: "hello")]
        try expectEqual(SessionListFilter.filter(sessions, query: "").count, 2)
        try expectEqual(SessionListFilter.filter(sessions, query: "  ").count, 2, "纯空白视为空查询")
    },
    TestCase(name: "sidebar.filter.标题命中") {
        let a = makeSidebarSession(title: "周末徒步计划")
        let b = makeSidebarSession(first: "totally unrelated")
        let r = SessionListFilter.filter([a, b], query: "徒步")
        try expectEqual(r.count, 1)
        try expectEqual(r.first?.id, a.id)
    },
    TestCase(name: "sidebar.filter.发言内容命中") {
        let a = makeSidebarSession(first: "I went hiking last weekend")
        let b = makeSidebarSession(first: "what is a monad")
        let r = SessionListFilter.filter([a, b], query: "hiking")
        try expectEqual(r.count, 1)
        try expectEqual(r.first?.id, a.id)
    },
    TestCase(name: "sidebar.filter.大小写不敏感") {
        let a = makeSidebarSession(first: "Talk about JVM Tuning")
        try expectEqual(SessionListFilter.filter([a], query: "jvm").count, 1)
    },
    TestCase(name: "sidebar.filter.无命中为空") {
        let a = makeSidebarSession(first: "hello")
        try expect(SessionListFilter.filter([a], query: "zzz").isEmpty)
    },

    // MARK: SidebarLayout.targetFrame
    TestCase(name: "sidebar.pinMath.左侧有空间向左扩") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        let f = NSRect(x: 500, y: 200, width: 440, height: 640)
        let t = SidebarLayout.targetFrame(current: f, pinning: true, visibleFrame: vf)
        try expectEqual(t, NSRect(x: 500 - SidebarLayout.width, y: 200,
                                  width: 440 + SidebarLayout.width, height: 640))
    },
    TestCase(name: "sidebar.pinMath.贴左缘放不下则向右扩") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        let f = NSRect(x: 10, y: 200, width: 440, height: 640)
        let t = SidebarLayout.targetFrame(current: f, pinning: true, visibleFrame: vf)
        try expectEqual(t.origin.x, 10, "origin 不动")
        try expectEqual(t.width, 440 + SidebarLayout.width)
    },
    TestCase(name: "sidebar.pinMath.右扩越界钳回可见区") {
        let vf = NSRect(x: 0, y: 90, width: 600, height: 1770)
        let f = NSRect(x: 10, y: 200, width: 440, height: 640)
        let t = SidebarLayout.targetFrame(current: f, pinning: true, visibleFrame: vf)
        try expect(t.maxX <= vf.maxX, "右缘不得越出可见区")
        try expect(t.minX >= vf.minX, "左缘不得越出可见区")
    },
    TestCase(name: "sidebar.pinMath.收起从左收回且聊天列不动") {
        let vf = NSRect(x: 0, y: 90, width: 3360, height: 1770)
        let pinned = NSRect(x: 280, y: 200, width: 660, height: 640)
        let t = SidebarLayout.targetFrame(current: pinned, pinning: false, visibleFrame: vf)
        try expectEqual(t, NSRect(x: 500, y: 200, width: 440, height: 640),
                        "聊天列（右缘与宽度）回到展开前")
    },

    // MARK: chatColumnWidth
    TestCase(name: "sidebar.chatColumnWidth.展开扣侧栏宽") {
        try expectEqual(SidebarLayout.chatColumnWidth(windowContentWidth: 660, pinned: true),
                        660 - SidebarLayout.width)
        try expectEqual(SidebarLayout.chatColumnWidth(windowContentWidth: 440, pinned: false), 440)
    },

    // MARK: sidebarPinned 配置
    TestCase(name: "sidebar.config.老配置缺键默认 false") {
        // 模拟无 sidebarPinned 键的老 config.json
        let json = """
        {"activeProviderID": "deepseek", "providers": []}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        try expectEqual(config.sidebarPinned, false)
    },
    TestCase(name: "sidebar.config.round-trip") {
        var config = AppConfig(activeProviderID: "deepseek", providers: [])
        config.sidebarPinned = true
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        try expectEqual(back.sidebarPinned, true)
    },
]

/// 造会话：title 走 summary.title（LLM 命名路径），first 走首条用户发言（截断路径）
private func makeSidebarSession(title: String? = nil, first: String? = nil) -> ChatSession {
    var turns: [DialogueTurn] = []
    if let first { turns.append(DialogueTurn(role: .user, content: first)) }
    return ChatSession(turns: turns,
                       summary: title.map { ConversationSummary(title: $0) })
}
