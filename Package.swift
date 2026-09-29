// swift-tools-version: 6.3
import PackageDescription

// app 的编译入口（swift build -c release）；打包 .app/图标/签名仍走 Makefile。
// 测试不走 swift test：自定义 runner（Tests/TestMain.swift，非 XCTest），
// 由 Makefile 的 test 目标用 swiftc 直编。
// Sparkle：自动更新框架，只进 app 不进测试二进制（Makefile swiftc 路径不链接它）。
let package = Package(
    name: "Parrotlet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Parrotlet",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Parrotlet",
            // HAS_SPARKLE：只有 SPM 构建链得到 Sparkle，AppEnvironment 据此选
            // SparkleUpdateController 还是 NoopUpdateProvider（Makefile swiftc 路径无此宏）
            swiftSettings: [.define("HAS_SPARKLE")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
