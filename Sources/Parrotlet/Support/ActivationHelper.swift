import AppKit
import SwiftUI

/// LSUIElement（菜单栏）app 的窗口默认不开前台、不获键盘焦点——
/// 所有 openWindow 入口统一走这里：先激活本 app，再开窗并置为 key window。
enum ActivationHelper {
    /// 从 MainActor 上下文（菜单/按钮回调）调用
    @MainActor
    static func open(id: String, using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
        // 新建窗口需要一轮 runloop 才出现在 NSApp.windows 里
        DispatchQueue.main.async {
            let candidates = NSApp.windows.filter { $0.canBecomeKey && $0.isVisible }
            candidates.last?.makeKeyAndOrderFront(nil)
        }
    }
}

/// App 级 openWindow 桥：App 的 body 里捕获 @Environment(\.openWindow) 存到这里，
/// 让 AppDelegate（自绘 NSStatusItem 的左键点击）也能开 SwiftUI Window 场景。
/// MenuBarExtra 的点击行为不可定制（任何点击都弹菜单），左键直开对话窗只能走这条路。
@MainActor
enum WindowOpenerBridge {
    private static var openWindow: OpenWindowAction?

    static func install(_ action: OpenWindowAction) {
        openWindow = action
    }

    static func open(_ id: String) {
        if let openWindow {
            ActivationHelper.open(id: id, using: openWindow)
        } else {
            // 桥还没装上（App body 未求值过）：至少把 app 激活，窗口交由用户点菜单栏
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
