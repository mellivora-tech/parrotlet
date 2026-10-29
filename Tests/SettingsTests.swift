import Foundation
import Observation

/// 设置页模型服务：预设目录 / 互斥开关 / 添加联动（对齐 workstation 参考交互）
let settingsTests: [TestCase] = [
    TestCase(name: "preset.match：preset 标记 → id 前缀 → host 关键词，三级命中") {
        // preset 标记优先
        let marked = ProviderConfig(id: "custom-abc", kind: .openAICompatible, name: "x",
                                    baseURL: "https://example.com", model: "m", preset: "kimi")
        try expectEqual(ProviderPreset.match(marked)?.id, "kimi")

        // 老模板配置（无 preset）：id 前缀命中
        let legacy = ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "DeepSeek",
                                    baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        try expectEqual(ProviderPreset.match(legacy)?.id, "deepseek")

        // 自定义 id：host 关键词命中（kimi 的 host 是 moonshot）
        let byHost = ProviderConfig(id: "custom-xyz", kind: .openAICompatible, name: "我的 Kimi",
                                    baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2")
        try expectEqual(ProviderPreset.match(byHost)?.id, "kimi")

        // 完全自定义：不命中（用默认图标）
        let custom = ProviderConfig(id: "custom-q1", kind: .openAICompatible, name: "本地",
                                    baseURL: "http://127.0.0.1:11434/v1", model: "qwen")
        try expect(ProviderPreset.match(custom) == nil, "Ollama 本地服务不应命中任何预设")
    },

    TestCase(name: "preset.draftFromPreset：kind/baseURL/模型预填，名称为空待兜底") {
        try MainActor.assumeIsolated {
            let (vm, _) = makeSettingsViewModelForTest()
            let draft = vm.draftFromPreset(.glm)
            try expectEqual(draft.kind, .openAICompatible)
            try expectEqual(draft.baseURL, "https://open.bigmodel.cn/api/paas/v4")
            try expectEqual(draft.model, "glm-4.7", "默认选中第一个内置模型")
            try expectEqual(draft.preset, "glm")
            try expect(draft.name.isEmpty, "名称为空 → placeholder/保存兜底用预设名")
            try expect(draft.id.hasPrefix("glm-"), "新 id 以预设为前缀")

            let custom = vm.draftFromPreset(nil)
            try expectEqual(custom.kind, .openAICompatible)
            try expect(custom.baseURL.isEmpty, "自定义不留预设 URL")
            try expect(custom.preset == nil, "自定义无预设标记")
        }
    },

    TestCase(name: "settings.toggleActive：互斥启用，再点当前项全停") {
        try MainActor.assumeIsolated {
            let (vm, _) = makeSettingsViewModelForTest(seed: [
                ProviderConfig(id: "a", kind: .openAICompatible, name: "A",
                               baseURL: "https://a.com/v1", model: "m"),
                ProviderConfig(id: "b", kind: .openAICompatible, name: "B",
                               baseURL: "https://b.com/v1", model: "m"),
            ])
            vm.toggleActive("a")
            try expectEqual(vm.activeProviderID, "a")
            vm.toggleActive("b")   // 开 b → a 自动弹回（单 activeProviderID 天然互斥）
            try expectEqual(vm.activeProviderID, "b")
            vm.toggleActive("b")   // 再点当前项 → 全部停用
            try expectEqual(vm.activeProviderID, "")
        }
    },

    TestCase(name: "settings.toggleActive：配置变化会通知 SwiftUI 观察层") {
        try MainActor.assumeIsolated {
            let provider = ProviderConfig(id: "a", kind: .openAICompatible, name: "A",
                                          baseURL: "https://a.com/v1", model: "m")
            let (vm, dir) = makeSettingsViewModelForTest(seed: [provider])
            defer { try? FileManager.default.removeItem(at: dir) }
            let notified = SettingsAsyncResultBox<Bool>()
            withObservationTracking {
                _ = vm.config
            } onChange: {
                notified.outcome = .success(true)
            }
            vm.toggleActive("a")
            try expect(notified.outcome != nil, "配置保存后必须通知视图刷新，否则 Toggle 停留在旧状态")
        }
    },

    TestCase(name: "settings.add：无启用项时新配置自动启用") {
        try MainActor.assumeIsolated {
            let (vm, dir) = makeSettingsViewModelForTest()
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = ProviderConfig(id: "first", kind: .openAICompatible, name: "F",
                                   baseURL: "https://f.com/v1", model: "m")
            vm.add(p)
            try expectEqual(vm.activeProviderID, "first", "保存第一个配置自动成为启用项")

            let q = ProviderConfig(id: "second", kind: .openAICompatible, name: "S",
                                   baseURL: "https://s.com/v1", model: "m")
            vm.add(q)
            try expectEqual(vm.activeProviderID, "first", "已有启用项时新增不抢启用")
        }
    },

    TestCase(name: "settings.add：重复 provider id 被拒绝") {
        try MainActor.assumeIsolated {
            let a = ProviderConfig(id: "same", kind: .openAICompatible, name: "A",
                                   baseURL: "https://a.com/v1", model: "m")
            let (vm, dir) = makeSettingsViewModelForTest(seed: [a])
            defer { try? FileManager.default.removeItem(at: dir) }

            vm.add(ProviderConfig(id: "same", kind: .openAICompatible, name: "B",
                                  baseURL: "https://b.com/v1", model: "m"))
            try expectEqual(vm.providers.count, 1, "重复 id 不得写入配置")
            try expectEqual(vm.providers[0].name, "A")
        }
    },

    TestCase(name: "config.decode：空 id 或重复 id 失败，避免 first(where:) 语义错位") {
        func json(id1: String, id2: String) -> Data {
            let objects = [
                "{\"id\":\"\(id1)\",\"kind\":\"openAICompatible\",\"name\":\"A\",\"baseURL\":\"https://a.com/v1\",\"model\":\"m\"}",
                "{\"id\":\"\(id2)\",\"kind\":\"openAICompatible\",\"name\":\"B\",\"baseURL\":\"https://b.com/v1\",\"model\":\"m\"}"
            ]
            return Data("{\"activeProviderID\":\"\",\"providers\":[\(objects.joined(separator: ","))]}".utf8)
        }

        do {
            _ = try JSONDecoder().decode(AppConfig.self, from: json(id1: "", id2: "b"))
            throw TestFailure(message: "空 id 应解码失败", file: "SettingsTests", line: 88)
        } catch let error as DecodingError {
            try expect(String(describing: error).contains("provider id cannot be empty"))
        }

        do {
            _ = try JSONDecoder().decode(AppConfig.self, from: json(id1: "a", id2: "a"))
            throw TestFailure(message: "重复 id 应解码失败", file: "SettingsTests", line: 96)
        } catch let error as DecodingError {
            try expect(String(describing: error).contains("provider ids must be unique"))
        }
    },

    TestCase(name: "settings.delete：删除启用项回退到列表第一个，删光全停") {
        try MainActor.assumeIsolated {
            let (vm, _) = makeSettingsViewModelForTest(seed: [
                ProviderConfig(id: "a", kind: .openAICompatible, name: "A",
                               baseURL: "https://a.com/v1", model: "m"),
                ProviderConfig(id: "b", kind: .openAICompatible, name: "B",
                               baseURL: "https://b.com/v1", model: "m"),
            ], active: "b")
            vm.delete("b")
            try expectEqual(vm.activeProviderID, "a", "删除启用项回退到列表第一个")
            vm.delete("a")
            try expectEqual(vm.activeProviderID, "", "删光则全停用")
        }
    },

    TestCase(name: "provider.readiness：active、Key、endpoint 和模型必须真正可用") {
        try MainActor.assumeIsolated {
            var remote = ProviderConfig(id: "remote", kind: .openAICompatible, name: "Remote",
                                        baseURL: "https://example.com/v1", model: "m")
            try expect(!SettingsViewModel.isReady(nil), "无 active Provider 未就绪")
            try expect(!SettingsViewModel.isReady(remote), "远程服务无 Key 未就绪")
            remote.apiKey = "   "
            try expect(!SettingsViewModel.isReady(remote), "空白 Key 未就绪")
            remote.apiKey = "secret"
            try expect(SettingsViewModel.isReady(remote), "完整远程配置已就绪")
            remote.model = " "
            try expect(!SettingsViewModel.isReady(remote), "空模型未就绪")
            remote.model = "m"
            remote.baseURL = "not a URL"
            try expect(!SettingsViewModel.isReady(remote), "非法 endpoint 未就绪")

            let local = ProviderConfig(id: "local", kind: .openAICompatible, name: "Local",
                                       baseURL: "http://127.0.0.1:11434/v1", model: "qwen")
            try expect(SettingsViewModel.isReady(local), "本地服务允许无 Key")

            let (vm, dir) = makeSettingsViewModelForTest(seed: [remote], active: "")
            defer { try? FileManager.default.removeItem(at: dir) }
            try expect(!vm.isActiveProviderReady, "Provider 存在但未启用仍未就绪")
        }
    },

    TestCase(name: "provider.setupDraft：优先复用已有预设，避免重复添加") {
        try MainActor.assumeIsolated {
            let existing = ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "My DS",
                                          baseURL: "https://api.deepseek.com/v1", model: "custom-model")
            let (vm, dir) = makeSettingsViewModelForTest(seed: [existing])
            defer { try? FileManager.default.removeItem(at: dir) }
            let reused = vm.setupDraft(for: .deepseek)
            try expectEqual(reused.id, existing.id)
            try expectEqual(reused.model, "custom-model")
            let created = vm.setupDraft(for: .kimi)
            try expect(created.id.hasPrefix("kimi-"), "没有已有项时才创建新草稿")
        }
    },

    TestCase(name: "provider.connect：测试成功后保存、命名并启用") {
        try MainActor.assumeIsolated {
            let old = ProviderConfig(id: "old", kind: .openAICompatible, name: "Old",
                                     baseURL: "https://old.com/v1", model: "m", apiKey: "old-key")
            let blank = ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "",
                                       baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
            let (vm, dir) = makeSettingsViewModelForTest(seed: [old, blank], active: "old")
            defer { try? FileManager.default.removeItem(at: dir) }
            vm.connectionProbeOverride = { _ in }
            let connected = ProviderConfig(
                id: blank.id, kind: blank.kind, name: blank.name,
                baseURL: blank.baseURL, model: blank.model, apiKey: "new-key")
            let failure = try awaitSettings { await vm.connectAndActivate(connected) }
            try expect(failure == nil, "连接成功不应返回错误")
            try expectEqual(vm.activeProviderID, "deepseek")
            try expectEqual(vm.providers.count, 2, "已有 Provider 应更新而不是重复添加")
            try expectEqual(vm.provider("deepseek")?.name, "DeepSeek")
            try expect(vm.isActiveProviderReady, "保存后的 active Provider 应就绪")
        }
    },

    TestCase(name: "provider.connect：测试失败不保存、不改变 active") {
        try MainActor.assumeIsolated {
            let old = ProviderConfig(id: "old", kind: .openAICompatible, name: "Old",
                                     baseURL: "https://old.com/v1", model: "m", apiKey: "old-key")
            let candidate = ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "",
                                           baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                                           apiKey: "bad-key")
            let (vm, dir) = makeSettingsViewModelForTest(seed: [old], active: "old")
            defer { try? FileManager.default.removeItem(at: dir) }
            vm.connectionProbeOverride = { _ in throw LLMError.http(status: 401, body: "untrusted body") }
            let failure = try awaitSettings { await vm.connectAndActivate(candidate) }
            try expectEqual(failure?.style, .guidance)
            try expectEqual(failure?.detail, "HTTP 401", "远程响应正文不得进入用户错误详情")
            try expectEqual(vm.activeProviderID, "old")
            try expectEqual(vm.providers.count, 1, "失败的候选 Provider 不得落盘")
            try expect(vm.isActiveProviderReady, "原有可用配置不得受影响")
        }
    },

    TestCase(name: "provider.connect：连接成功但保存失败返回存储错误") {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("settings-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try Data("broken config".utf8).write(to: url)
            let store = ConfigStore(url: url, secrets: .inMemory())
            let vm = SettingsViewModel(configStore: store, llm: LLMService(configStore: store))
            vm.connectionProbeOverride = { _ in }
            let candidate = ProviderConfig(id: "new", kind: .openAICompatible, name: "New",
                                           baseURL: "https://new.com/v1", model: "m", apiKey: "key")
            let previousActive = vm.activeProviderID
            let failure = try awaitSettings { await vm.connectAndActivate(candidate) }
            try expectEqual(failure?.style, .failure)
            try expectEqual(failure?.message, L10n.s(.storageSaveFailed, vm.config.language.resolved))
            try expectEqual(vm.activeProviderID, previousActive)
            try expect(vm.provider("new") == nil, "保存被拒绝时不得新增 Provider")
            try expect(vm.testing["new"] != true, "返回后必须清理连接中状态")
        }
    },

    TestCase(name: "fontScale：默认 1.0 不缩放，越界钳回安全范围") {
        try expectEqual(AppConfig.clampingFontScale(1.0), 1.0, "默认 = 标准")
        try expectEqual(AppConfig.clampingFontScale(0.5), 0.85, "低于下限钳到 0.85")
        try expectEqual(AppConfig.clampingFontScale(2.0), 1.3, "高于上限钳到 1.3")
        try expect(AppConfig.fontScaleRange.contains(1.15), "旧「大」档等价值在范围内")
    },
]

/// 构造隔离的 SettingsViewModel（临时目录 + 空配置；seed 可选预置 provider 列表）
@MainActor
private func makeSettingsViewModelForTest(
    seed: [ProviderConfig] = [], active: String = ""
) -> (SettingsViewModel, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    // 预写配置：阻止 ConfigStore 生成含 3 个预设的模板
    let config = AppConfig(activeProviderID: active, providers: seed)
    try? JSONEncoder().encode(config).write(to: url)
    let store = ConfigStore(url: url, secrets: .inMemory())
    return (SettingsViewModel(configStore: store, llm: LLMService(configStore: store)), dir)
}

private final class SettingsAsyncResultBox<T>: @unchecked Sendable {
    var outcome: Result<T, Error>?
}

private func awaitSettings<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = SettingsAsyncResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.outcome = .success(try await operation()) }
        catch { box.outcome = .failure(error) }
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(10)
    while semaphore.wait(timeout: .now()) != .success && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let outcome = box.outcome else {
        throw TestFailure(message: "async settings test timed out", file: "SettingsTests", line: #line)
    }
    return try outcome.get()
}
