import AppKit

/// 浮层「点外部关闭」的 macOS 原生实现：本地事件监控——点浮层外 → 关浮层并放行事件
///（NSPopover .transient 同款：关闭与点击一次完成），替代 SwiftUI 全窗透明遮罩。
/// 遮罩方案的实测坑：它盖住所有下层控件，菜单打开后第一次点击只关菜单、点击被吞，
/// 页面上每个按钮都要被白点一下（体感「点不动」）。
///
/// 坐标对齐：passthroughFrames 由 onGeometryChange 在 SwiftUI 命名坐标系上报，
/// 事件点经 hostView（WindowReader 埋进同一根视图 background 的 NSView）换算——
/// 它占满根视图，换算后与 SwiftUI 坐标系逐点对齐，标题栏/安全区无需手工补偿。
///
/// 使用：浮层打开时 start()，关闭时 stop()（含 .onDisappear 兜底——本类无法在
/// deinit 里碰隔离状态，Swift 6 限制，泄漏的 monitor 持有 weak self 无副作用但不干净）。
@MainActor
final class OutsideClickDismiss {
    /// 点击不关浮层的区域（浮层自身 + 触发按钮；按钮走自身 toggle，监控不插手），
    /// SwiftUI 根视图坐标系（左上原点，pt）。闭包在点击时现取，避免 frame 更新时序问题
    var passthroughFrames: @MainActor () -> [CGRect] = { [] }
    /// 埋进浮层所在根视图 background 的标记视图（WindowReader 上报）；
    /// 点击落在其他窗口/无窗口一律视为外部
    weak var hostView: NSView?
    var dismiss: () -> Void = {}

    private var monitor: Any?

    var isActive: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // addLocalMonitorForEvents 回调必在主线程（事件分发路径），assumeIsolated 与
        // WindowResolutionView 同款
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let box = MainThreadEventBox(event: event)
            let shouldDismiss = MainActor.assumeIsolated { self.shouldDismiss(box.event) }
            if shouldDismiss { dismiss() }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func shouldDismiss(_ event: NSEvent) -> Bool {
        if let view = hostView, event.window == view.window {
            // locationInWindow（左下原点）→ 标记视图坐标系翻 y → SwiftUI 根视图坐标
            let p = view.convert(event.locationInWindow, from: nil)
            let topLeft = CGPoint(x: p.x, y: view.bounds.height - p.y)
            if passthroughFrames().contains(where: { $0.contains(topLeft) }) { return false }
        }
        return true // 放行事件本身：下层控件照常响应这次点击
    }
}

/// AppKit local event monitors run on the main thread; this makes the non-Sendable crossing explicit.
private struct MainThreadEventBox: @unchecked Sendable {
    let event: NSEvent
}
