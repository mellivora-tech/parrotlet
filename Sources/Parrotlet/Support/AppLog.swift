import Foundation

/// 运行日志：JSONL 落盘，每行一个事件 `{"ts":…,"level":…,"event":…, ...}`。
/// 超 2MB 滚动为 app.old.jsonl（只留一份旧档，不占盘）。
///
/// 记录纪律（审查红线）：
/// - 绝不写 API key / baseURL 之外的凭据
/// - 聊天正文、朗读文本、识别文本只记长度（len），不记内容
/// - 错误记 domain/code/描述，这些不含用户内容
enum AppLog {
    enum Level: String, Sendable { case debug, info, warn, error }

    /// 日志文件（测试重定向到临时路径）
    nonisolated(unsafe) static var fileURL = AppPaths.dataFile("app.jsonl")
    /// 滚动阈值（测试可压小）
    nonisolated(unsafe) static var maxBytes = 2 * 1024 * 1024

    private static let queue = DispatchQueue(label: "parrotlet.applog")

    static func log(_ level: Level, _ event: String, _ fields: [String: Any] = [:]) {
        var obj: [String: Any] = ["ts": Date().timeIntervalSince1970,
                                  "level": level.rawValue,
                                  "event": event]
        for (k, v) in fields { obj[k] = v }
        // Serialize on the caller's thread; only Sendable Data crosses the queue boundary.
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        queue.async {
            rotateIfNeeded()
            append(line + "\n")
        }
    }

    /// 测试用：排空写队列后直接读文件
    static func flushForTest() { queue.sync {} }

    // MARK: - 文件操作（只在 queue 上跑）

    private static func append(_ line: String) {
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            // 首写前目录可能不存在（测试重定向/数据目录被清），兜底建一次
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: fileURL, atomically: false, encoding: .utf8)
        }
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let old = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".old.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
