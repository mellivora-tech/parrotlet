import Foundation

/// 落盘文件的 schema 版本锚点（顶层数组文件的包装）。
///
/// 背景：自动更新上线后，数据是单向棘轮——新 app 必须读得了老数据，
/// 破坏性变更要有版本号做迁移挂点。对象的版本内联在自身字段里（AppConfig.schemaVersion），
/// 顶层是数组的文件无处放版本号，由这里的包装类型承载：
///   v1 = 裸数组（无版本号，2026-09 之前的格式）
///   v2 = { "schemaVersion": 2, "sessions/words": [...] }（当前）
/// 破坏性变更时：currentSchemaVersion +1，在 init(from:) 里按读到的旧版本号分支迁移。
///
/// 解码即迁移：v1 裸数组读进来标 1，下次 save 自然写成当前版本——无需单独迁移器。
/// 编码永远写当前版本；解码失败（既非对象也非数组）抛错，交给 JSONStore 隔离兜底。

/// chat-sessions.json 的落盘包装
struct ChatSessionArchive: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var sessions: [ChatSession]

    init(sessions: [ChatSession], schemaVersion: Int = ChatSessionArchive.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let sessions = try keyed.decodeIfPresent([ChatSession].self, forKey: .sessions) {
            self.sessions = sessions
            // 读到的旧版本号只供 init 内迁移分支使用；解码完成即迁移完成，
            // 内存值统一标当前版本——save 必须写当前版本（单向棘轮，测试钉死）
            _ = try keyed.decodeIfPresent(Int.self, forKey: .schemaVersion)
        } else {
            // v1 裸数组
            sessions = try [ChatSession](from: decoder)
        }
        schemaVersion = Self.currentSchemaVersion
    }
}

/// words.json 的落盘包装
struct WordBookArchive: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var words: [WordEntry]

    init(words: [WordEntry], schemaVersion: Int = WordBookArchive.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.words = words
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let words = try keyed.decodeIfPresent([WordEntry].self, forKey: .words) {
            self.words = words
            // 同 ChatSessionArchive：内存值统一标当前版本
            _ = try keyed.decodeIfPresent(Int.self, forKey: .schemaVersion)
        } else {
            // v1 裸数组
            words = try [WordEntry](from: decoder)
        }
        schemaVersion = Self.currentSchemaVersion
    }
}
