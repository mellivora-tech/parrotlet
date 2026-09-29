import SwiftUI
import AppKit

@main
struct ParrotletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appEnvironment = AppEnvironment()
    @Environment(\.openWindow) private var openWindow

    init() {
        // swift run 直跑可执行文件时没有 Info.plist，LSUIElement 不生效；
        // 这里主动设为 accessory（菜单栏 app，无 Dock 图标），与 .app 启动行为对齐。
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // 把 App 级 openWindow 装到桥里：AppDelegate 自绘菜单栏图标的左键点击要用
        let _ = WindowOpenerBridge.install(openWindow)

        // 单窗口场景（Window 而非 WindowGroup）：重复打开 = 聚焦已有窗口
        Window(appEnvironment.t(.chatWindowTitle), id: SceneID.chat) {
            ChatView()
                .environment(appEnvironment)
        }
        .windowResizability(.contentSize)
        // 菜单栏工具窗：永远浮在顶层，不被其他窗口盖住
        .windowLevel(.floating)
        // 隐藏原生标题栏：header 由 ChatView 自绘（红绿灯悬浮左上角，header 左侧留白避让）
        .windowStyle(.hiddenTitleBar)
        // 窗口初始尺寸以 defaultSize 为准：内容 idealWidth 不参与开窗计算，
        // 宽度不定死的内容会被系统按默认值开窗（本机实测 900×450）。
        // 440 = 聊天列（侧栏默认收起）；持久化的展开态由 ChatView 入窗时补扩到 660。
        // 高度取高度引擎的自动下限（WindowGeometryModel.minAutoHeight），单一事实源
        .defaultSize(width: 440, height: WindowGeometryModel.minAutoHeight)

        Window(appEnvironment.t(.wordBookTitle), id: SceneID.wordBook) {
            WordBookView()
                .environment(appEnvironment)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 480)

        Window(appEnvironment.t(.appMenuSettings), id: SceneID.settings) {
            SettingsView()
                .environment(appEnvironment)
        }
        // System Settings (Tahoe) 风：无标题栏，红绿灯托管在侧栏列顶部
        .windowStyle(.hiddenTitleBar)
        // 窗口可拖拽缩放，min 由视图约束给出
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 648)
    }
}

/// LSUIElement app 无应用主菜单，Cmd+C/V/X/A 可能失效；
/// 若 SwiftUI 未自动安装则手工补一个最小 Edit 菜单。
///
/// 菜单栏图标自绘（不用 MenuBarExtra——它的点击行为不可定制，任何点击都弹菜单）：
/// 左键 = 直接打开对话窗；右键 = 功能菜单
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全局外观已在 AppEnvironment.init 按 config.json 应用（不再强制深色）
        Self.installEditMenuIfNeeded()
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // M 鹦鹉剪影（assets/icon/menubar.png，make icon 生成）；
            // template 模式由系统着色，自动适配菜单栏明暗态。缺失时退回系统气泡
            let icon = NSImage(named: "menubar")
            icon?.isTemplate = true
            button.image = icon ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Parrotlet")
            button.image?.accessibilityDescription = "Parrotlet"
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        }
        statusItem = item

        let menu = NSMenu()
        // 菜单文案随界面语言（AppKit 侧走 L10n.current 快照）；每次弹出前刷新，切语言即时生效
        menu.addItem(withTitle: L10n.s(.appMenuChat, L10n.current), action: #selector(openScene(_:)), keyEquivalent: "").tag = 0
        menu.addItem(withTitle: L10n.s(.appMenuWordBook, L10n.current), action: #selector(openScene(_:)), keyEquivalent: "").tag = 1
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.s(.appMenuSettings, L10n.current), action: #selector(openScene(_:)), keyEquivalent: "").tag = 2
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.s(.appMenuQuit, L10n.current), action: #selector(quit), keyEquivalent: "q").tag = 99
        statusMenu = menu
    }

    /// 弹出前按当前界面语言刷新菜单文案（切语言后无需重启）
    private func refreshMenuTitles() {
        guard let menu = statusMenu else { return }
        menu.item(withTag: 0)?.title = L10n.s(.appMenuChat, L10n.current)
        menu.item(withTag: 1)?.title = L10n.s(.appMenuWordBook, L10n.current)
        menu.item(withTag: 2)?.title = L10n.s(.appMenuSettings, L10n.current)
        menu.item(withTag: 99)?.title = L10n.s(.appMenuQuit, L10n.current)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            // 右键弹菜单：临时挂上 → performClick 模态跟踪到菜单关闭 → 取下，保住左键动作
            refreshMenuTitles()
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            WindowOpenerBridge.open(SceneID.chat)
        }
    }

    @objc private func openScene(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: WindowOpenerBridge.open(SceneID.chat)
        case 1: WindowOpenerBridge.open(SceneID.wordBook)
        default: WindowOpenerBridge.open(SceneID.settings)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @MainActor
    private static func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
