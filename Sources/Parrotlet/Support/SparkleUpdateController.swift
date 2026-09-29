import Foundation
import Sparkle

/// Sparkle 自动更新的生产实现。
/// 本文件只被 SPM（Package.swift，-D HAS_SPARKLE）编译进 app；Makefile 的
/// swiftc 路径（swift6-typecheck / make test / smoke-compile）没有 Sparkle 模块
/// 可导入，已在 SOURCES 里 filter-out——该文件的类型门禁由 `swift build` 承担。
@MainActor
final class SparkleUpdateController: UpdateProviding {
    private let controller: SPUStandardUpdaterController

    init() {
        // 裸二进制（swift run / 冒烟工具）没有 Info.plist，缺 SUFeedURL 时启动
        // updater 只会报错刷日志；有 feed（正式 .app）才启动
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: hasFeed, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
