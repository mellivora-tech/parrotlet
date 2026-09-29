import Foundation
import Observation
import AppKit
import ServiceManagement

/// 设置：provider 增删改 / 切换激活 / 测试连接 / 登录启动
@MainActor
@Observable
final class SettingsViewModel {
    private let configStore: ConfigStore
    private let llm: LLMService

    /// 结果文案随界面语言（测试连接/模型拉取是异步回调，不走视图层 env）
    private var uiLanguage: UILanguage { configStore.value.language.resolved }

    /// 测试连接状态：id → (运行中, 结果文案)
    private(set) var testing: [String: Bool] = [:]
    private(set) var testResults: [String: String] = [:]

    init(configStore: ConfigStore, llm: LLMService) {
        self.configStore = configStore
        self.llm = llm
    }

    var config: AppConfig { configStore.value }

    var providers: [ProviderConfig] { config.providers }

    var activeProviderID: String {
        get { config.activeProviderID }
        set {
            var next = config
            next.activeProviderID = newValue
            configStore.save(next)
        }
    }

    func provider(_ id: String) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    // MARK: - 编辑

    func update(_ provider: ProviderConfig) {
        var next = config
        guard let idx = next.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        guard next.providers.dropFirst(idx + 1).allSatisfy({ $0.id != provider.id }) else { return }
        next.providers[idx] = provider
        configStore.save(next)
    }

    /// 从预设创建新配置草稿（不落盘——模态「保存」时才 commit）。
    /// 名称为空：placeholder/保存兜底用预设默认名（参考设计）
    func draftFromPreset(_ preset: ProviderPreset?) -> ProviderConfig {
        // UUID 后缀：之前用 count+1 编号，删除后再添加会撞已有 id
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ProviderConfig(
            id: "\(preset?.id ?? "custom")-\(suffix)",
            kind: preset?.kind ?? .openAICompatible,
            name: "",
            baseURL: preset?.baseURL ?? "",
            model: preset?.builtinModels.first ?? "",
            apiKey: nil, maxTokens: 4096,
            preset: preset?.id)
    }

    /// 新增落盘（模态「保存」）。参考联动规则：当前无启用项时新配置自动成为启用项
    func add(_ provider: ProviderConfig) {
        var next = config
        guard !next.providers.contains(where: { $0.id == provider.id }) else { return }
        next.providers.append(provider)
        if next.activeProviderID.isEmpty {
            next.activeProviderID = provider.id
        }
        configStore.save(next)
    }

    /// 行内互斥开关：开一个其他自动弹回（单 activeProviderID 天然互斥）；
    /// 再点当前项 = 全部停用（activeProviderID 置空，聊天侧报「未配置」引导）
    func toggleActive(_ id: String) {
        var next = config
        next.activeProviderID = next.activeProviderID == id ? "" : id
        configStore.save(next)
    }

    func delete(_ id: String) {
        var next = config
        next.providers.removeAll { $0.id == id }
        if next.activeProviderID == id {
            next.activeProviderID = next.providers.first?.id ?? ""
        }
        configStore.save(next)
    }

    // MARK: - 测试连接

    func testConnection(_ provider: ProviderConfig) async {
        testing[provider.id] = true
        testResults[provider.id] = nil
        defer { testing[provider.id] = nil }

        // 直接对目标 provider 发一条最小请求（不走 activeProvider 分发）
        let probe: any LLMProvider = OpenAICompatibleProvider(config: provider)
        let started = ContinuousClock.now
        do {
            _ = try await probe.complete(
                [ChatMessage.user("Reply with exactly: ok")],
                options: .init(maxTokens: 32))
            // 成功只报可用 + 延迟（参考设计：绿点「可用 · Nms」）
            let ms = Int(started.duration(to: .now) / .milliseconds(1))
            testResults[provider.id] = "✅ " + L10n.availableLatency(ms, uiLanguage)
        } catch {
            testResults[provider.id] = "❌ \(error.localizedDescription.prefix(150))"
        }
    }

    // MARK: - 模型列表

    /// id → 拉取到的模型 id 列表（按 id 缓存，切走再回来不重复请求）
    private(set) var models: [String: [String]] = [:]
    private(set) var modelsLoading: [String: Bool] = [:]
    private(set) var modelsError: [String: String] = [:]

    /// 用传入的配置拉模型列表——传草稿而非已保存配置，刚填的 API Key 立即生效
    func fetchModels(_ provider: ProviderConfig) async {
        let requiresKey: Bool
        do {
            requiresKey = !(try APIEndpoint.validate(provider.baseURL).isLocal)
        } catch let error as APIEndpoint.ValidationError {
            modelsError[provider.id] = error.message
            return
        } catch {
            modelsError[provider.id] = L10n.s(.endpointInvalid, uiLanguage)
            return
        }
        if requiresKey {
            guard let key = provider.apiKey, !key.isEmpty else {
                modelsError[provider.id] = L10n.s(.enterKeyFirst, uiLanguage)
                return
            }
        }
        modelsLoading[provider.id] = true
        modelsError[provider.id] = nil
        defer { modelsLoading[provider.id] = nil }

        let probe: any LLMProvider = OpenAICompatibleProvider(config: provider)
        do {
            models[provider.id] = try await probe.listModels()
        } catch {
            modelsError[provider.id] = String(error.localizedDescription.prefix(150))
        }
    }

    // MARK: - 外观

    /// 外观模式：写回 config.json 并立即应用到 NSApp（所有窗口实时切换）
    var appearance: AppAppearance {
        get { config.appearance }
        set {
            guard newValue != config.appearance else { return }
            var next = config
            next.appearance = newValue
            configStore.save(next)
            newValue.apply()
        }
    }

    // MARK: - 配置文件 / 登录启动

    func revealConfigFolder() {
        NSWorkspace.shared.open(AppPaths.supportDirectory)
    }

    /// 访达中选中运行日志（没有日志文件时退回数据文件夹）
    func revealLogFile() {
        if FileManager.default.fileExists(atPath: AppLog.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
        } else {
            revealConfigFolder()
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // 注册失败（权限/策略限制）静默回退，Toggle 状态自然还原
            NSSound.beep()
        }
    }

    var llmProviderName: String { llm.activeProviderName }
}
