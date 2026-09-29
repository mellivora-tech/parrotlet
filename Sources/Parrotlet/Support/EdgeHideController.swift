import AppKit
import SwiftUI
import ObjectiveC

/// NSWindow 的 constrainFrameRect 补丁：贴边隐藏期间放开「窗口不许出可见区」的钳制。
///
/// 为什么必须动它：NSWindow 默认实现把窗口钉在屏幕可见区内，程序 setFrame 一样被钳
/// （实测：titled 窗口 setFrame 到屏幕外会被拉回 top == visibleFrame.maxY），
/// QQ 式「滑出屏幕外」对 titled 窗口物理上不可能。borderless 窗口不受钳，但会失去
/// key 窗口能力（默认 canBecomeKey=false，输入框失焦）和系统圆角——都不接受。
/// 所以换 method swizzle：只对本控制器管理的窗口、只在隐藏态/隐藏动画期间放行，
/// 其余窗口和用户拖拽的钳制行为完全不变。
private extension NSWindow {
    static let edgeHideSwizzleOnce: Void = {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(constrainFrameRect(_:to:))),
              let replacement = class_getInstanceMethod(NSWindow.self, #selector(ea_constrainFrameRect(_:to:))) else { return }
        method_exchangeImplementations(original, replacement)
    }()

    static func installEdgeHideConstrainPatch() { _ = edgeHideSwizzleOnce }

    @objc func ea_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if EdgeHideConstrainBypass.shared.shouldBypass(for: self) { return frameRect }
        // 实现已交换，这里调用的 ea_constrainFrameRect 其实是原始实现
        return ea_constrainFrameRect(frameRect, to: screen)
    }
}

/// 钳制放行状态：哪个窗口 + 是否放行。只在主线程读写（constrainFrameRect 由 AppKit
/// 在 setFrame 路径上调用，必在主线程；controller 侧是 @MainActor）
@MainActor
private final class EdgeHideConstrainBypass {
    static let shared = EdgeHideConstrainBypass()
    weak var window: NSWindow?
    var active = false

    /// constrainFrameRect 回调里从非 isolated 上下文查（主线程保证见上）
    nonisolated func shouldBypass(for win: NSWindow) -> Bool {
        MainActor.assumeIsolated { active && window === win }
    }
}

/// QQ 式贴边隐藏（screen-edge auto-hide），支持上 / 左 / 右三边：
/// - 窗口拖到屏幕边缘松手 → 滑出屏幕藏起来（hidden）
/// - 光标碰到该边缘（窗口沿边范围内）→ 滑回原位（revealed）
/// - 光标进入窗口后又离开 → 自动藏回；若用户已把窗口拖离边缘，则转回 normal 不再藏
///
/// 实现要点：
/// - titled 窗口的 setFrame（含程序调用）被 constrainFrameRect 钳在可见区内，出不了屏幕
///   ——靠上面的 swizzle 补丁在隐藏期间放行（borderless 能出屏但丢 key 窗口能力和圆角，否决）
/// - 往上滑的过程会被菜单栏自然遮住（菜单栏 window level 比 floating 高），视觉就是「吸上去」
/// - 光标监控必须本地 + 全局双监听：mouseMoved 按光标位置路由——落在本 App 窗口上
///   走本地监听，落在别的 App / 桌面上走全局监听，缺一个就有盲区
/// - 本地 mouseMoved 要开窗 acceptsMouseMovedEvents（默认 false，不开收不到）
/// - 隐藏期间高度引擎（WindowConfigurator.apply）是「顶边锚定」向下长高的，
///   会把底边长回屏幕里——所以 hidden 期间 ChatView 的 expectedWindowHeight 必须返回 nil
@MainActor
final class EdgeHideController {
    /// 吸附的屏幕边缘
    enum Edge: Equatable {
        // 备注（将来做 Windows 版时对齐）：Windows QQ 拖到左/右侧边停靠时会先把面板
        // 纵向拉满到屏幕全高、再隐藏只留一条细边，滑出时也是全高侧边栏形态；
        // 顶边不拉满直接吸上去。macOS 版（这里）按 Mac QQ 手感三边都只藏不拉满。
        case top, left, right
    }

    enum State: Equatable {
        case normal         // 普通窗口
        case hidden(Edge)   // 已吸附在某条屏幕边缘（整窗在屏幕外）
        case revealed       // 临时滑出；光标离开后藏回
    }

    // MARK: - 手感参数（魔法数字，可调）

    /// 拖窗松手时，窗口边与可见区对应边的间距 ≤ 该值视为「贴边」
    nonisolated static let snapThreshold: CGFloat = 24
    /// 隐藏后边缘热区深度（从屏幕边往内）。太小触摸板一次跨帧打不中，
    /// 太大容易在别的 App 边缘工具栏误触发
    nonisolated static let hotZoneDepth: CGFloat = 8
    /// 热区沿边方向相对窗口范围两端的放宽
    nonisolated static let hotZoneSlack: CGFloat = 24
    /// revealed 时光标「离开窗口」的判定余量（防边界抖动闪藏）
    nonisolated static let leaveSlack: CGFloat = 8
    /// revealed 且光标从未进入窗口时，光标远离窗口超过该范围直接藏回
    /// （滑出动画中途光标就跑了的场景，窗口不该赖着）
    nonisolated static let straySlack: CGFloat = 80

    private(set) var state: State = .normal {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private weak var window: NSWindow?
    /// 隐藏前的 frame（滑回目标）。revealed 态藏回时会用当前 frame 覆盖，
    /// 因此始终指向「下次滑回的位置」
    private var storedFrame: NSRect?
    /// 隐藏时所在屏（窗口在屏幕外时 win.screen 不可靠）
    private weak var storedScreen: NSScreen?
    /// revealed 态下光标是否进入过窗口：进入过再离开才藏回。
    /// hover 滑出时窗口正好落在光标下方会立即置 true；
    /// 菜单栏图标唤起时光标在远处，等首次进入才武装，避免刚一滑出就藏回去
    private var cursorVisited = false

    /// 本次按下的光标起点；松手时算位移判断「是否真拖了」。
    /// 不能用 didMove 通知当拖动信号：窗口已贴边时继续往边缘拖，窗口被钳制动都不动，
    /// didMove 根本不发——但光标明明位移了，用户意图就是吸附（实测漏判）
    private var mouseDownPoint: NSPoint?
    /// 按下时的窗口 frame：系统平铺劫持拖拽时回滚用（见 handleTileArtifact）。
    /// 非拖拽的点击在松手时清掉（handleMouseUp）：会话侧栏 pin 住后窗口 660pt 宽，
    /// 1440 宽屏幕上已达 isTileLike 的 45% 阈值，点击武装的脏值会把 pin 的
    /// setFrame 误判成平铺劫持而回滚——「tile 尺寸只有平铺能产生」的前提已被打破
    private var preDragFrame: NSRect?

    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []

    // MARK: - 几何判定（纯函数，供单测）

    /// 贴边判定：窗口哪条边贴住了可见区哪条边（顶优先——拖到角落时按顶边吸附）。
    /// 单边不等式而非 abs：侧边用户拖拽可以直接推出屏外（实测右缘能超出 287pt），
    /// 「越过边缘」同样是贴边——窗口都快看不见了，吸走正是 QQ 的语义
    nonisolated static func snapEdge(for f: NSRect, in vf: NSRect) -> Edge? {
        if f.maxY >= vf.maxY - snapThreshold { return .top }
        if f.minX <= vf.minX + snapThreshold { return .left }
        if f.maxX >= vf.maxX - snapThreshold { return .right }
        return nil
    }

    /// 热区判定：光标压在屏幕对应边缘（含沿边方向放宽）。侧边热区用 screen.frame
    /// 而不是 visibleFrame——Dock 放侧边时热区要盖过 Dock 带才打得中
    nonisolated static func inHotZone(cursor: NSPoint, edge: Edge, screen sf: NSRect,
                          visibleFrame vf: NSRect, hiddenFrame: NSRect) -> Bool {
        switch edge {
        case .top:
            return cursor.y >= vf.maxY - hotZoneDepth
                && cursor.x >= hiddenFrame.minX - hotZoneSlack
                && cursor.x <= hiddenFrame.maxX + hotZoneSlack
        case .left:
            return cursor.x <= sf.minX + hotZoneDepth
                && cursor.y >= hiddenFrame.minY - hotZoneSlack
                && cursor.y <= hiddenFrame.maxY + hotZoneSlack
        case .right:
            return cursor.x >= sf.maxX - hotZoneDepth
                && cursor.y >= hiddenFrame.minY - hotZoneSlack
                && cursor.y <= hiddenFrame.maxY + hotZoneSlack
        }
    }

    // MARK: - 装配

    func attach(to win: NSWindow) {
        guard window !== win else { return }
        NSWindow.installEdgeHideConstrainPatch()
        window = win
        EdgeHideConstrainBypass.shared.window = win
        win.acceptsMouseMovedEvents = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers = []
        monitors = []

        // 菜单栏图标点开窗口（窗口藏在屏幕外时 openWindow 只会把它置 key）→ 滑出来
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .hidden = self.state else { return }
                self.reveal()
            }
        })

        // 系统平铺劫持检测：didResize 且尺寸像 tile（平铺会 resize 窗口）时回滚
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTileArtifact() }
        })

        // 按下 = 可能开始拖拽，记录光标起点（松手时算位移）和窗口 frame（平铺回滚用）
        let mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if let self, event.window === self.window {
                MainActor.assumeIsolated {
                    self.mouseDownPoint = NSEvent.mouseLocation
                    self.preDragFrame = self.window?.frame
                }
            }
            return event
        }

        // 松手 = 拖拽结束（靠光标位移 + 几何判定过滤，点击无副作用）
        let mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            if let self, event.window === self.window {
                MainActor.assumeIsolated { self.handleMouseUp() }
            }
            return event
        }

        // 光标在本 App 窗口上移动（revealed 态的进入/离开判定）
        let localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            if let self {
                MainActor.assumeIsolated { self.handleCursor() }
            }
            return event
        }

        // 光标在别的 App / 桌面上移动（hidden 态热区探测、revealed 态离开判定都靠它；
        // 本 App 非前台时本地监听只能收到落在本窗口上的事件，覆盖不了这两种）
        let globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleCursor() }
        }
        monitors = [mouseDownMonitor, mouseUpMonitor, localMoveMonitor, globalMoveMonitor].compactMap { $0 }
    }

    /// 视图拆除时清理（dismantleNSView 是 @MainActor 上下文）。
    /// 不放 deinit：nonisolated deinit 访问 non-Sendable monitor 是 Swift 6 错误
    func invalidate() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers = []
        monitors = []
        if let window, EdgeHideConstrainBypass.shared.window === window {
            EdgeHideConstrainBypass.shared.window = nil
            EdgeHideConstrainBypass.shared.active = false
        }
        window = nil
    }

    /// 平铺尺寸判定：宽高都 ≥ 可见区 45%（半屏/全屏/四分之一 tile 全命中）。
    /// 注意：侧栏 pin 住后窗口 660pt 宽，在小屏（1440 宽）上会越过 45%——
    /// 此时是否回滚由 preDragFrame 是否来自真拖拽把关（见 handleMouseUp 的清理）
    nonisolated static func isTileLike(_ f: NSRect, in vf: NSRect) -> Bool {
        f.width >= vf.width * 0.45 && f.height >= vf.height * 0.45
    }

    /// 系统平铺劫持检测：macOS 15+ 拖窗到边缘悬停松手 → 系统无视 contentMaxSize 把窗口
    /// 拉成 tile 尺寸（实测顶边悬停 1.5s → 3360x1770），贴边隐藏被抢戏。
    /// 没有可用的关闭开关（NSWindowTilingEnabled 无效），只能事后回滚，而且平铺动画
    /// 会持续刷 didResize 覆盖我们的回滚——所以每个 tile 帧都顶回去，直到动画播完：
    /// - normal/revealed：回滚到拖拽前 frame；光标还在边缘说明用户就是要贴边 → 直接藏
    /// - hidden：藏好了还被拽回 → 以 storedFrame 重新推出屏外
    /// preDragFrame 的时效：真拖拽武装的值一路留到平铺动画播完（tile 帧逐帧顶回）；
    /// 纯点击武装的脏值在松手时已清（handleMouseUp），pin 侧栏等程序 resize 不会误伤
    private func handleTileArtifact() {
        guard let win = window, let screen = win.screen else { return }
        // 用户拖拽缩放途中不回滚：pin 侧栏后窗口 660pt 宽，小屏上拖宽即越 45% 阈值，
        // 而系统平铺只发生在松手之后（inLiveResize 已结束）——此刻的不算劫持
        guard !win.inLiveResize else { return }
        guard Self.isTileLike(win.frame, in: screen.visibleFrame) else { return }
        switch state {
        case .hidden(let edge):
            guard let stored = storedFrame else { return }
            win.setFrame(Self.hiddenTarget(for: stored, edge: edge, screen: screen.frame),
                         display: false, animate: false)
        case .normal, .revealed:
            guard let stored = preDragFrame else { return }
            win.setFrame(stored, display: true, animate: false)
            if let edge = Self.snapEdge(for: stored, in: screen.visibleFrame) {
                hide(to: edge)
            }
        }
    }

    // MARK: - 事件处理

    /// 松手时：normal 贴边 → 吸附；revealed 被拖离边缘 → 脱离贴边转 normal
    private func handleMouseUp() {
        // 位移判定在此刻做（光标最终位置最准）；吸附判定延迟 0.2s 纯为 QQ 的吸附前摇手感。
        // （早期 performDrag 时代延迟是必须的：本地监听在事件入队时触发，performDrag 的
        // 模态循环还没收尾，同步读 frame 是脏值；自绘拖拽后 frame 在 mouseDragged 已最终化）
        let dragged: Bool
        if let down = mouseDownPoint {
            let up = NSEvent.mouseLocation
            dragged = hypot(up.x - down.x, up.y - down.y) > 6
        } else {
            dragged = false
        }
        mouseDownPoint = nil
        // 纯点击（没拖）不可能触发系统平铺，武装的 preDragFrame 是脏值——
        // 清掉，否则 pin 侧栏等程序 setFrame 会被 handleTileArtifact 误回滚
        if !dragged { preDragFrame = nil }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.checkSnap(dragged: dragged)
        }
    }

    private func checkSnap(dragged: Bool) {
        guard let win = window, let screen = win.screen else { return }
        // 只有「这次按下真的拖了」才做吸附判定：纯点击不改状态
        guard dragged else { return }
        switch state {
        case .normal:
            if let edge = Self.snapEdge(for: win.frame, in: screen.visibleFrame) {
                hide(to: edge)
            }
        case .revealed:
            if Self.snapEdge(for: win.frame, in: screen.visibleFrame) == nil {
                state = .normal
                cursorVisited = false
                EdgeHideConstrainBypass.shared.active = false
            }
        case .hidden:
            break
        }
    }

    /// 光标移动：hidden 探测热区滑出；revealed 跟踪进入/离开决定藏回
    private func handleCursor() {
        guard let win = window else { return }
        let p = NSEvent.mouseLocation
        switch state {
        case .normal:
            break
        case .hidden(let edge):
            guard let storedFrame, let storedScreen else { return }
            if Self.inHotZone(cursor: p, edge: edge, screen: storedScreen.frame,
                              visibleFrame: storedScreen.visibleFrame,
                              hiddenFrame: storedFrame) {
                reveal()
            }
        case .revealed:
            let f = win.frame
            if f.insetBy(dx: -Self.leaveSlack, dy: -Self.leaveSlack).contains(p) {
                cursorVisited = true
            } else if cursorVisited {
                // 进入后离开 → 藏回（被拖离边缘的情形已在松手时转 normal，走不到这）
                hideToCurrentEdge()
            } else if !f.insetBy(dx: -Self.straySlack, dy: -Self.straySlack).contains(p) {
                hideToCurrentEdge()
            }
        }
    }

    // MARK: - 状态迁移

    /// revealed 藏回：以当前 frame 重新判定贴的是哪条边（用户可能在滑出后拖到了别的边）。
    /// 不贴任何边 = 已被拖离边缘，藏回没有落点——转 normal。不能兜底吸顶：mouseUp 的
    /// 吸附判定有 200ms 前摇延迟，光标先离窗会先走到这里，兜底会把「拖到屏幕任意
    /// 位置快速松开」全部吸回顶（实测竞态）；转 normal 与 checkSnap 的收尾等价
    private func hideToCurrentEdge() {
        guard let win = window, let screen = win.screen else { return }
        guard let edge = Self.snapEdge(for: win.frame, in: screen.visibleFrame) else {
            state = .normal
            cursorVisited = false
            EdgeHideConstrainBypass.shared.active = false
            return
        }
        hide(to: edge)
    }

    private func hide(to edge: Edge) {
        guard let win = window,
              let screen = storedScreen ?? win.screen ?? NSScreen.main else { return }
        storedFrame = win.frame
        storedScreen = screen
        state = .hidden(edge)
        cursorVisited = false
        // 整个隐藏期间放开钳制（防系统/引擎任何 setFrame 把窗口拉回可见区）
        EdgeHideConstrainBypass.shared.active = true
        win.setFrame(Self.hiddenTarget(for: win.frame, edge: edge, screen: screen.frame),
                     display: false, animate: true)
    }

    /// 整窗移出屏幕对应边缘的目标 frame（+4 防某些分辨率下漏 1px 边）
    nonisolated static func hiddenTarget(for f: NSRect, edge: Edge, screen sf: NSRect) -> NSRect {
        var t = f
        switch edge {
        case .top: t.origin.y = sf.maxY + 4
        case .left: t.origin.x = sf.minX - t.width - 4
        case .right: t.origin.x = sf.maxX + 4
        }
        return t
    }

    private func reveal() {
        guard case .hidden(let edge) = state, let win = window else { return }
        var target = storedFrame ?? win.frame
        // 屏配置可能变过：沿边方向贴齐可见区对应边，另一轴收回屏内
        if let screen = storedScreen ?? win.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            switch edge {
            case .top:
                target.origin.y = vf.maxY - target.height
                target.origin.x = min(max(target.origin.x, vf.minX), vf.maxX - target.width)
            case .left:
                target.origin.x = vf.minX
                target.origin.y = min(max(target.origin.y, vf.minY), vf.maxY - target.height)
            case .right:
                target.origin.x = vf.maxX - target.width
                target.origin.y = min(max(target.origin.y, vf.minY), vf.maxY - target.height)
            }
        }
        state = .revealed
        cursorVisited = false
        win.setFrame(target, display: false, animate: true)
        // 滑出动画落点完全在可见区内，落稳后即可恢复钳制（动画时长余量给足）
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.state == .revealed else { return }
            EdgeHideConstrainBypass.shared.active = false
        }
    }
}

/// 把 EdgeHideController 挂到窗口上（零尺寸视图，纯装配器，同 WindowConfigurator 模式）
struct EdgeHideInstaller: NSViewRepresentable {
    let onStateChange: (EdgeHideController.State) -> Void

    func makeCoordinator() -> EdgeHideController {
        let c = EdgeHideController()
        c.onStateChange = onStateChange
        return c
    }

    func makeNSView(context: Context) -> NSView {
        // 入窗即装配（WindowResolutionView 统一入窗回调，替代 async 赌时序）
        let view = WindowResolutionView()
        view.onWindow = { [coordinator = context.coordinator] win in
            coordinator.attach(to: win)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onStateChange = onStateChange
        if let win = nsView.window {
            context.coordinator.attach(to: win)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: EdgeHideController) {
        coordinator.invalidate()
    }
}
