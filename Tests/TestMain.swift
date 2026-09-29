import Foundation

// 微型测试运行器：非 XCTest，SPM 的 testTarget 塞不进去，由 Makefile 的 test 目标
// 用 swiftc 直接编译 Sources(排除 app 入口) + Tests 成独立测试二进制。
// （历史：本机 CLT 26.5/26.6 的 SPM 曾出厂损坏，2026-09-29 装全量 Xcode 26.6 后
// SPM 已修复，app 编译已迁 Package.swift；测试因 runner 形态留在 swiftc 路径。）

struct TestCase: @unchecked Sendable {
    let name: String
    let run: () throws -> Void
}

struct TestFailure: Error, Sendable {
    let message: String
    let file: String
    let line: UInt

    var description: String { "\(message) (\(file):\(line))" }
}

/// 断言：condition 为假时抛错并记录位置
func expect(_ condition: Bool, _ message: String = "条件不成立", file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else { throw TestFailure(message: message, file: "\(file)", line: line) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String = "",
                               file: StaticString = #fileID, line: UInt = #line) throws {
    try expect(a == b, label.isEmpty ? "\(a) != \(b)" : "\(label): \(a) != \(b)", file: file, line: line)
}

@main
@MainActor
enum TestMain {
    static func main() {
        // 运行日志全局重定向到临时文件：StorageTests 等会触发 AppLog 事件，
        // 不重定向就写进真实 app.jsonl，污染生产日志（排查时被误导过一次）
        AppLog.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrotlet-tests-\(UUID().uuidString).jsonl")

        var passed = 0
        var failed = 0
        let started = Date()

        for test in allTests {
            do {
                try test.run()
                passed += 1
                print("  ✅ \(test.name)")
            } catch let e as TestFailure {
                failed += 1
                print("  ❌ \(test.name): \(e.description)")
            } catch {
                failed += 1
                print("  ❌ \(test.name): \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("————————————————")
        print("\(passed) passed, \(failed) failed (\(String(format: "%.2f", elapsed))s)")
        exit(failed == 0 ? 0 : 1)
    }

    /// 各测试文件以 `let xxxTests: [TestCase]` 注册，在此汇总
    static var allTests: [TestCase] {
        smokeTests + sseParserTests + openAIDeltaTests + apiEndpointTests + llmProviderTests + storageTests
            + chatModelTests + edgeHideTests + windowGeometryTests + settingsTests + lookupTests
            + lookupPanelTests + chatSidebarTests + speechTests + wordBookTests
            + appLogTests + chatNavigationTests + starterSuggestionsTests + keychainTests
            + schemaVersionTests
    }
}

let smokeTests: [TestCase] = [
    TestCase(name: "smoke.sceneIDs") {
        try expectEqual(SceneID.chat, "chat")
        try expectEqual(SceneID.wordBook, "wordBook")
        try expectEqual(SceneID.settings, "settings")
    },
]
