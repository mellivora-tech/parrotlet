import Foundation

/// 运行日志：JSONL 逐行可解析 + 滚动
let appLogTests: [TestCase] = [

    TestCase(name: "appLog.每行是合法 JSON，字段齐全") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        AppLog.fileURL = url
        AppLog.log(.info, "test.event", ["voice": "system", "len": 42])
        AppLog.log(.warn, "test.second")
        AppLog.flushForTest()

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        try expectEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        try expect(first?["event"] as? String == "test.event")
        try expect(first?["level"] as? String == "info")
        try expect(first?["ts"] as? Double != nil, "ts 必须是数字时间戳")
        try expectEqual(first?["len"] as? Int, 42)
        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        try expect(second?["event"] as? String == "test.second")
        try expect(second?["level"] as? String == "warn")
    },

    TestCase(name: "appLog.超阈值滚动为 .old.jsonl，当前文件重新起") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog-rotate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.jsonl")
        AppLog.fileURL = url
        AppLog.maxBytes = 200
        defer { AppLog.maxBytes = 2 * 1024 * 1024 }
        for i in 0..<10 {
            AppLog.log(.info, "rotate.\(i)", ["pad": String(repeating: "x", count: 50)])
        }
        AppLog.flushForTest()

        let old = dir.appendingPathComponent("app.old.jsonl")
        try expect(FileManager.default.fileExists(atPath: old.path), "应滚出旧档")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try expect(size < 300, "滚动后当前文件应被重新起，实际 \(size)")
        // 旧档本身也是合法 JSONL
        let oldText = try String(contentsOf: old, encoding: .utf8)
        let firstLine = oldText.split(separator: "\n").first!
        try expect((try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) != nil)
    },
    TestCase(name: "appLog.远程错误 body 不落入日志") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("la-log-redaction-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let previousURL = AppLog.fileURL
        AppLog.fileURL = url
        defer { AppLog.fileURL = previousURL }

        _ = UserFacingError.present(
            LLMError.http(status: 500, body: "SECRET-REMOTE-DETAIL user text"),
            language: .zh)
        AppLog.flushForTest()
        let text = try String(contentsOf: url, encoding: .utf8)
        try expect(!text.contains("SECRET-REMOTE-DETAIL"))
        try expect(text.contains("HTTP 500"))
    },

]
