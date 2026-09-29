import Foundation

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
