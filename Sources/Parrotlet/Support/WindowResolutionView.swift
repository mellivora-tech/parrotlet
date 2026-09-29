import AppKit
import SwiftUI

/// 视图入窗回调 NSView：收敛 NSViewRepresentable「拿所在 NSWindow」的样板
/// （WindowConfigurator / EdgeHideInstaller 共用）。
/// viewDidMoveToWindow 在视图挂上窗口时同步触发，比 makeNSView 里
/// DispatchQueue.main.async 赌时序可靠——装配早于首次 layout，回调时机只早不晚。
/// AppKit 视图生命周期回调必在主线程，故闭包标 @MainActor 并用 assumeIsolated 调用。
final class WindowResolutionView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        MainActor.assumeIsolated { onWindow?(window) }
    }
}

/// SwiftUI 侧拿所在 NSWindow / 标记视图的最小桥。
/// 埋在根视图 background 里时标记视图占满根视图：OutsideClickDismiss 用它把
/// 事件点换算进 SwiftUI 根坐标系（标题栏/安全区自动对齐，无需手工补偿）
struct WindowReader: NSViewRepresentable {
    let onResolve: @MainActor (WindowResolutionView) -> Void

    func makeNSView(context: Context) -> WindowResolutionView {
        let view = WindowResolutionView()
        view.onWindow = { [weak view] _ in
            if let view { onResolve(view) }
        }
        return view
    }

    func updateNSView(_ nsView: WindowResolutionView, context: Context) {
        nsView.onWindow = { [weak nsView] _ in
            if let nsView { onResolve(nsView) }
        }
    }
}
