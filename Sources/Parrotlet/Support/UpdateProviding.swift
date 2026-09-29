import Foundation

/// 自动更新的抽象口：视图只依赖本协议。
/// Sparkle 实体只在 SPM app 构建里链接（见 SparkleUpdateController.swift 头注释），
/// 测试二进制 / swiftc 门禁路径不链接 Sparkle，用 NoopUpdateProvider 兜底——
/// 与 SecretStore 的可替换通道同一思路。
@MainActor
protocol UpdateProviding: AnyObject {
    /// 自动检查更新开关（生产实现直接映射 Sparkle 的偏好，持久化由 Sparkle 负责）
    var automaticallyChecksForUpdates: Bool { get set }
    /// 立即检查更新（生产实现弹出 Sparkle 标准更新 UI）
    func checkForUpdates()
}

/// 无 Sparkle 环境的兜底（测试 / 无 Info.plist 的裸跑）：开关不落盘、检查是空操作
final class NoopUpdateProvider: UpdateProviding {
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}
