import Foundation

/// JSONStore roundtrip / 坏文件降级 / ConfigStore 模板解析
/// JSONStore 是 @MainActor；测试 main() 本就运行在主线程，用 assumeIsolated 同步访问。
let storageTests: [TestCase] = [
    TestCase(name: "jsonstore.roundtrip with dates") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = dir.appendingPathComponent("words.json")
            struct Item: Codable, Equatable { let id: UUID; let text: String; let at: Date }
            let item = Item(id: UUID(), text: "serendipity", at: Date(timeIntervalSince1970: 1_800_000_000))

            let store = JSONStore<[Item]>(url: url, defaultValue: [])
            try expectEqual(store.value, [], "初始应为默认值")
            store.save([item])

            let reloaded = JSONStore<[Item]>(url: url, defaultValue: [])
            try expectEqual(reloaded.value, [item], "重新加载应还原（含 ISO8601 日期）")
        }
    },

    TestCase(name: "jsonstore.save creates missing data directory") {
        try MainActor.assumeIsolated {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-json-dir-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("nested/words.json")

            let store = JSONStore<[Int]>(url: url, defaultValue: [])
            if case .failure(let error) = store.save([1]) {
                throw TestFailure(message: "应创建缺失目录并保存: \(error)", file: "StorageTests", line: 8)
            }
            try expect(FileManager.default.fileExists(atPath: url.path))
        }
    },

    TestCase(name: "jsonstore.corrupt file quarantined, falls back") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = dir.appendingPathComponent("words.json")
            try Data("{ not valid json !!!".utf8).write(to: url)

            let store = JSONStore<[Int]>(url: url, defaultValue: [7])
            try expectEqual(store.value, [7], "坏文件应降级为默认值")
            if case .recoveryRequired = store.persistenceState {} else {
                throw TestFailure(message: "坏文件应进入恢复状态", file: "StorageTests", line: 37)
            }

            let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            guard let quarantineName = siblings.first(where: { $0.hasPrefix("words.json.corrupt-") }) else {
                throw TestFailure(message: "坏文件应被改名为 .corrupt-<时间戳>", file: "StorageTests", line: 41)
            }
            try expect(!FileManager.default.fileExists(atPath: url.path),
                       "canonical 文件在恢复确认前不应被默认值重建")
            if case .failure = store.save([8]) {
                // expected
            } else {
                throw TestFailure(message: "恢复状态必须阻止保存", file: "StorageTests", line: 47)
            }

            // 重启后仍能发现 quarantine，不允许空默认值静默接管。
            let reloaded = JSONStore<[Int]>(url: url, defaultValue: [])
            if case .recoveryRequired = reloaded.persistenceState {} else {
                throw TestFailure(message: "重启后仍应保持恢复状态", file: "StorageTests", line: 54)
            }
            _ = quarantineName
        }
    },

    TestCase(name: "apppaths.dataFile takes full filename, no double suffix") {
        // 回归：旧版 dataFile 给 "words.json" 再补一层 .json → words.json.json
        try expectEqual(AppPaths.dataFile("words.json").lastPathComponent, "words.json")
        try expectEqual(AppPaths.dataFile("activity.json").lastPathComponent, "activity.json")
    },

    TestCase(name: "apppaths.migrate moves legacy .json.json when canonical missing") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("chat-sessions.json.json")
        try Data("[]".utf8).write(to: legacy)
        // 干扰项：目标已存在时绝不覆盖
        try Data("[1]".utf8).write(to: dir.appendingPathComponent("activity.json"))
        try Data("[2]".utf8).write(to: dir.appendingPathComponent("activity.json.json"))

        AppPaths.migrateLegacyDoubleSuffixFiles(in: dir)

        let fm = FileManager.default
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("chat-sessions.json").path),
                   "旧双后缀文件应被挪到规范名")
        try expect(!fm.fileExists(atPath: legacy.path), "旧文件应不再存在")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("activity.json.json").path),
                   "规范名已存在时不动旧文件")
    },

    TestCase(name: "configstore.first write uses 0600") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-config-perm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")

            _ = ConfigStore(url: url, secrets: .inMemory())
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            try expectEqual(permissions, 0o600, "配置包含 API key，应写为 0600")
        }
    },

    TestCase(name: "configstore.save keeps permissions at 0600") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-config-save-perm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ConfigStore(url: dir.appendingPathComponent("config.json"), secrets: .inMemory())
            var config = store.value
            config.appearance = .light
            store.save(config)

            let permissions = try FileManager.default
                .attributesOfItem(atPath: dir.appendingPathComponent("config.json").path)[.posixPermissions] as? Int
            try expectEqual(permissions, 0o600)
        }
    },

    TestCase(name: "configstore.startup tightens legacy permissions") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-config-perm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try ConfigTemplate.templateJSON.data(using: .utf8)?.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

            _ = ConfigStore(url: url, secrets: .inMemory())
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            try expectEqual(permissions, 0o600, "旧 config 启动时应被收紧到 0600")
        }
    },

    TestCase(name: "chat.viewmodel reports recovery mode instead of replacing data") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ea-chat-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("chat-sessions.json")
            try Data("not json".utf8).write(to: storeURL)

            let llm = LLMService(configStore: ConfigStore(url: dir.appendingPathComponent("config.json"), secrets: .inMemory()))
            let vm = ChatViewModel(llm: llm, storeURL: storeURL)
            try expect(vm.error != nil, "损坏会话应给用户可见错误")
            try expect(!FileManager.default.fileExists(atPath: storeURL.path),
                       "未确认恢复前不得重建 canonical 会话文件")
        }
    },

    TestCase(name: "configstore.template parses with _comment ignored") {
        let data = try ConfigTemplate.templateJSON.data(using: .utf8)
            ?? { throw TestFailure(message: "模板不是 UTF-8", file: "StorageTests", line: 3) }()
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try expectEqual(config.activeProviderID, "deepseek")
        try expectEqual(config.providers.count, 3)
        try expectEqual(config.providers.map(\.id),
                        ["deepseek", "glm", "kimi"])
        try expectEqual(config.activeProvider?.model, "deepseek-chat")
        try expectEqual(config.appearance, .dark, "模板默认深色（沿用初版观感）")
    },

    TestCase(name: "appconfig.appearance 缺省兜底 dark，显式值正常解码") {
        // 老配置（appearance 键出现之前）必须能解码且观感不变
        let legacy = Data(#"{"activeProviderID":"p","providers":[]}"#.utf8)
        try expectEqual(JSONDecoder().decode(AppConfig.self, from: legacy).appearance, .dark)

        for (raw, mode) in [("auto", AppAppearance.auto), ("light", .light), ("dark", .dark)] {
            let json = Data(#"{"activeProviderID":"p","providers":[],"appearance":""#.utf8)
                + Data(raw.utf8) + Data(#""}"#.utf8)
            try expectEqual(JSONDecoder().decode(AppConfig.self, from: json).appearance, mode)
        }

        // 显式选择必须能落盘往返（防止被默认值吃掉）
        let saved = AppConfig(activeProviderID: "p", providers: [], appearance: .light)
        let roundtrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(saved))
        try expectEqual(roundtrip.appearance, .light)
    },

    TestCase(name: "appconfig.language 缺省兜底 auto，显式值与解析正确") {
        // 老配置（language 键出现之前）必须能解码
        let legacy = Data(#"{"activeProviderID":"p","providers":[]}"#.utf8)
        try expectEqual(JSONDecoder().decode(AppConfig.self, from: legacy).language, .auto)

        for (raw, mode) in [("auto", AppLanguage.auto), ("zhHans", .zhHans), ("english", .english)] {
            let json = Data(#"{"activeProviderID":"p","providers":[],"language":""#.utf8)
                + Data(raw.utf8) + Data(#""}"#.utf8)
            try expectEqual(JSONDecoder().decode(AppConfig.self, from: json).language, mode)
        }

        // 落盘往返
        let saved = AppConfig(activeProviderID: "p", providers: [], language: .english)
        let roundtrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(saved))
        try expectEqual(roundtrip.language, .english)

        // 显式值解析（auto 依赖系统语言，不在单测断言）
        try expectEqual(AppLanguage.zhHans.resolved, .zh)
        try expectEqual(AppLanguage.english.resolved, .en)
    },

    TestCase(name: "l10n 双语文案与带参文案") {
        try expectEqual(L10n.s(.newChat, .zh), "新对话")
        try expectEqual(L10n.s(.newChat, .en), "New Chat")
        try expectEqual(L10n.s(.paneServices, .en), "Models")
        try expectEqual(L10n.turnsAndMode(12, "Chat", .zh), "12 轮 · Chat")
        try expectEqual(L10n.turnsAndMode(12, "Chat", .en), "12 turns · Chat")
        try expect(L10n.version("1.0", .en).hasPrefix("Version"), "英文版本号前缀")
        try expect(L10n.deleteServiceMessage("DeepSeek", .en).contains("DeepSeek"), "删除弹窗含服务名")
    },
]
