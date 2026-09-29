import Foundation

/// API Key 入 Keychain 的迁移/擦盘/补水/清理链路（SecretStore 内存替身，不碰真钥匙串）
let keychainTests: [TestCase] = [
    TestCase(name: "keychain.migration scrubs plaintext from disk, keeps it in memory") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("migrate")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try JSONEncoder().encode(AppConfig(activeProviderID: "deepseek", providers: [
                ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "DeepSeek",
                               baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                               apiKey: "sk-plain-123"),
            ])).write(to: url)

            let secrets = SecretStore.inMemory()
            let store = ConfigStore(url: url, secrets: secrets)

            try expectEqual(secrets.read("deepseek"), "sk-plain-123", "明文 key 应搬入 Keychain")
            try expectEqual(store.value.providers[0].apiKey, "sk-plain-123", "内存应保留 key 供 LLM 用")
            let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            try expectEqual(onDisk.providers[0].apiKey, nil, "落盘副本不得含明文 key")
        }
    },

    TestCase(name: "keychain.second launch hydrates key from secrets") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("hydrate")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try JSONEncoder().encode(AppConfig(activeProviderID: "deepseek", providers: [
                ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "DeepSeek",
                               baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            ])).write(to: url)

            let secrets = SecretStore.inMemory()
            secrets.save("deepseek", "sk-from-keychain")
            let store = ConfigStore(url: url, secrets: secrets)

            try expectEqual(store.value.providers[0].apiKey, "sk-from-keychain",
                            "磁盘无 key 时应从 Keychain 补水到内存")
            let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            try expectEqual(onDisk.providers[0].apiKey, nil, "补水后落盘副本仍不得含 key")
        }
    },

    TestCase(name: "keychain.save writes key to secrets not disk") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("save")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            let secrets = SecretStore.inMemory()
            let store = ConfigStore(url: url, secrets: secrets)

            var config = store.value
            config.providers[0].apiKey = "sk-new-1"
            store.save(config)

            try expectEqual(secrets.read(config.providers[0].id), "sk-new-1", "key 应写入 Keychain")
            try expectEqual(store.value.providers[0].apiKey, "sk-new-1", "内存应保留 key")
            let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            try expectEqual(onDisk.providers[0].apiKey, nil, "落盘副本不得含 key")
        }
    },

    TestCase(name: "keychain.clearing key removes it from secrets") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("clear")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            let secrets = SecretStore.inMemory()
            let store = ConfigStore(url: url, secrets: secrets)

            var config = store.value
            config.providers[0].apiKey = "sk-temp"
            store.save(config)
            try expectEqual(secrets.read(config.providers[0].id), "sk-temp")

            config.providers[0].apiKey = nil
            store.save(config)
            try expectEqual(secrets.read(config.providers[0].id), nil, "清空 key 应从 Keychain 删除")
        }
    },

    TestCase(name: "keychain.deleting provider removes its secret") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("delete")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            let secrets = SecretStore.inMemory()
            let store = ConfigStore(url: url, secrets: secrets)

            var config = store.value
            config.providers.append(ProviderConfig(
                id: "custom-x", kind: .openAICompatible, name: "X",
                baseURL: "https://example.com/v1", model: "m", apiKey: "sk-x"))
            store.save(config)
            try expectEqual(secrets.read("custom-x"), "sk-x")

            config.providers.removeAll { $0.id == "custom-x" }
            store.save(config)
            try expectEqual(secrets.read("custom-x"), nil, "删除 provider 应清掉 Keychain 残留")
        }
    },

    TestCase(name: "keychain.failed migration keeps plaintext on disk (no key loss)") {
        try MainActor.assumeIsolated {
            let dir = try makeKeychainTestDir("fallback")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try JSONEncoder().encode(AppConfig(activeProviderID: "deepseek", providers: [
                ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "DeepSeek",
                               baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                               apiKey: "sk-keep-me"),
            ])).write(to: url)

            // 读写全失败的替身：模拟 Keychain 不可用——宁可磁盘留明文，绝不丢 key
            let dead = SecretStore(read: { _ in nil }, save: { _, _ in }, remove: { _ in })
            let store = ConfigStore(url: url, secrets: dead)

            try expectEqual(store.value.providers[0].apiKey, "sk-keep-me",
                            "入串失败时内存不得丢 key")
            let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            try expectEqual(onDisk.providers[0].apiKey, "sk-keep-me",
                            "入串失败时落盘副本应保留明文兜底")
        }
    },
]

// 通用临时测试目录（KeychainTests 起家用，SchemaVersionTests 等复用）
func makeKeychainTestDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ea-keychain-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
