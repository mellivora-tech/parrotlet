import SwiftUI
import AppKit

extension AppAppearance {
    /// 应用到全局外观：auto = nil（跟随系统）；设置后所有窗口实时切换。
    /// 必须走 NSApplication.shared 而非 NSApp 全局变量：本函数在 AppEnvironment.init
    /// （App 属性初始化器，早于 init  body 的 setActivationPolicy）就被调用，
    /// 此刻 NSApplication.shared 可能还没被触碰过，NSApp 是 nil，直接解包即崩（实测 SIGTRAP）
    @MainActor func apply() {
        switch self {
        case .auto: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// 按当前外观取色（深/浅双值）。App 外观由 AppAppearance 全局覆盖，
    /// 动态 NSColor 的 provider 在绘制时按当前外观（含 App 级覆盖）求值。
    /// 硬编码调色板（设置页深色风 DS 色板、header 纯白三点）经此适配浅色模式
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
