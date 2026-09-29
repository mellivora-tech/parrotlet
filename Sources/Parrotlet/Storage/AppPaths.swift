import Foundation

/// 数据目录：~/Library/Application Support/Parrotlet/
enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrotlet", isDirectory: true)
    }

    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }

    /// 各数据仓库的文件（config.json 之外的）。
    /// name 传完整文件名（含扩展名），如 dataFile("words.json") —— 这里不再补后缀。
    static func dataFile(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
        migrateLegacyDoubleSuffixFiles(in: supportDirectory)
    }

    /// 修复历史 bug：旧版 dataFile 会把 "activity.json" 拼成 "activity.json.json"，
    /// 早期版本的数据落在了双后缀文件里。目标文件不存在时把旧文件挪回正确名字。
    static func migrateLegacyDoubleSuffixFiles(in directory: URL) {
        let fm = FileManager.default
        for base in ["activity", "chat-sessions", "corrections", "daily-summaries",
                     "reading-notes", "review-logs", "words"] {
            let legacy = directory.appendingPathComponent("\(base).json.json")
            let canonical = directory.appendingPathComponent("\(base).json")
            guard fm.fileExists(atPath: legacy.path),
                  !fm.fileExists(atPath: canonical.path) else { continue }
            try? fm.moveItem(at: legacy, to: canonical)
        }
    }
}
