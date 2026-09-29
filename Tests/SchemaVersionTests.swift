import Foundation

/// 数据版本（schema 锚点 + 枚举容错）的双向兼容测试：
/// - 向后：老格式（无版本号 / v1 裸数组）新版本必须读得进，save 后自然迁移到当前版本
/// - 前向：未来版本的未知枚举值，老代码单字段回默认，绝不整文件隔离
/// 覆盖动机见 PersistedArchives.swift 头注释（自动更新后数据是单向棘轮）
let schemaVersionTests: [TestCase] = [

    // MARK: 版本锚点

    TestCase(name: "schema.config legacy (no version key) decodes as v1, save writes current") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("schema-config-legacy")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try Data("""
                {"activeProviderID":"deepseek","providers":[]}
                """.utf8).write(to: url)

            let store = JSONStore<AppConfig>(url: url, defaultValue: AppConfig(activeProviderID: "", providers: []))
            try expectEqual(store.value.schemaVersion, AppConfig.currentSchemaVersion,
                            "读入即迁移：内存统一当前版本")
            try expectEqual(store.persistenceState, .normal, "老配置不得进恢复态")

            store.save(store.value)
            let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            try expect(raw.contains("\"schemaVersion\""), "save 后版本锚点必须落盘")
        }
    },

    TestCase(name: "schema.chat sessions v1 bare array migrates to wrapped v2 on save") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("schema-chat-v1")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("chat-sessions.json")
            let session = ChatSession(turns: [DialogueTurn(role: .user, content: "hello")])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([session]).write(to: url)   // v1 裸数组

            let store = JSONStore<ChatSessionArchive>(url: url, defaultValue: ChatSessionArchive(sessions: []))
            try expectEqual(store.value.schemaVersion, ChatSessionArchive.currentSchemaVersion,
                            "读入即迁移：内存统一当前版本")
            try expectEqual(store.value.sessions.count, 1, "老会话必须完整读入")
            try expectEqual(store.value.sessions.first?.turns.first?.content, "hello")

            store.save(store.value)
            let iso = JSONDecoder()
            iso.dateDecodingStrategy = .iso8601
            let archive = try iso.decode(ChatSessionArchive.self, from: Data(contentsOf: url))
            try expectEqual(archive.schemaVersion, ChatSessionArchive.currentSchemaVersion,
                            "save 后必须写成当前版本")
            try expectEqual(archive.sessions.count, 1, "迁移后会话不丢")
        }
    },

    TestCase(name: "schema.words v1 bare array migrates to wrapped v2 on save") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("schema-words-v1")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("words.json")
            let entry = WordEntry(text: "serendipity", note: "n. 意外之喜", context: "a happy accident")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([entry]).write(to: url)   // v1 裸数组

            let store = JSONStore<WordBookArchive>(url: url, defaultValue: WordBookArchive(words: []))
            try expectEqual(store.value.schemaVersion, WordBookArchive.currentSchemaVersion,
                            "读入即迁移：内存统一当前版本")
            try expectEqual(store.value.words.first?.text, "serendipity", "老生词必须完整读入")

            store.save(store.value)
            let iso = JSONDecoder()
            iso.dateDecodingStrategy = .iso8601
            let archive = try iso.decode(WordBookArchive.self, from: Data(contentsOf: url))
            try expectEqual(archive.schemaVersion, WordBookArchive.currentSchemaVersion,
                            "save 后必须写成当前版本")
            try expectEqual(archive.words.count, 1, "迁移后生词不丢")
        }
    },

    // MARK: 枚举容错（前向兼容：模拟"老代码读新数据"）

    TestCase(name: "schema.unknown config enum values fall back per-field, no quarantine") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("schema-config-unknown-enum")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            // 未来版本才可能出现的枚举值（appearance/language/speechRate/kind）
            try Data("""
                {"activeProviderID":"deepseek",
                 "providers":[{"id":"deepseek","kind":"neuralLink","name":"D",
                               "baseURL":"https://api.deepseek.com/v1","model":"m"}],
                 "appearance":"sepia","language":"klingon","speechRate":"ludicrous"}
                """.utf8).write(to: url)

            let store = JSONStore<AppConfig>(url: url, defaultValue: AppConfig(activeProviderID: "", providers: []))
            try expectEqual(store.persistenceState, .normal, "未知枚举值绝不得隔离整文件")
            try expectEqual(store.value.appearance, .dark, "未知 appearance 回默认")
            try expectEqual(store.value.language, .auto, "未知 language 回默认")
            try expectEqual(store.value.speechRate, .standard, "未知 speechRate 回默认")
            try expectEqual(store.value.providers.count, 1, "provider 列表不丢")
            try expectEqual(store.value.providers.first?.kind, .openAICompatible, "未知 kind 回兼容协议")
        }
    },

    TestCase(name: "schema.unknown turn role/deliveryStatus fall back, sessions survive") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("schema-chat-unknown-enum")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("chat-sessions.json")
            // 未来版本才可能出现的 role / deliveryStatus / mode
            try Data("""
                [{"id":"00000000-0000-0000-0000-000000000001",
                  "startedAt":"2026-09-29T00:00:00Z","updatedAt":"2026-09-29T00:00:00Z",
                  "mode":"hologram",
                  "turns":[{"role":"tool","content":"some tool output","deliveryStatus":"streamed"},
                           {"role":"user","content":"hi"}]}]
                """.utf8).write(to: url)

            let store = JSONStore<ChatSessionArchive>(url: url, defaultValue: ChatSessionArchive(sessions: []))
            try expectEqual(store.persistenceState, .normal, "未知枚举值绝不得隔离整文件")
            let session = store.value.sessions.first
            try expectEqual(store.value.sessions.count, 1, "会话不丢")
            try expectEqual(session?.mode, .conversation, "未知 mode 回默认")
            try expectEqual(session?.turns.count, 2, "轮次不丢")
            try expectEqual(session?.turns.first?.role, .assistant, "未知 role 落回 assistant")
            try expectEqual(session?.turns.first?.deliveryStatus, .complete, "未知 deliveryStatus 回默认")
        }
    },
]
