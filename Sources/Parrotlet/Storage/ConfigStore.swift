import Foundation

/// config.json 读写：首次启动写入带说明的模板（JSON 无注释，用 `_comment` 字段——解码器忽略未知键）。
/// apiKey 不落盘：密钥统一进 Keychain（见 KeychainHelper），本文件只留 null。
@MainActor
final class ConfigStore {
    private let url: URL
    private let store: JSONStore<AppConfig>
    private let secrets: SecretStore

    /// 入串失败的 provider id：落盘保留明文兜底（读回校验不过时宁可降级，绝不丢 key）。
    /// 用引用类型是为让 persistedValueTransform 闭包共享同一份（值类型会被拷贝定格）。
    private final class PlaintextFallback { var ids: Set<String> = [] }
    private let plaintextFallback = PlaintextFallback()

    init(url: URL = AppPaths.configFile, secrets: SecretStore = .keychain) {
        self.url = url
        self.secrets = secrets
        AppPaths.ensureDirectories()
        // 旧版本可能按进程 umask 写成 0644；启动时统一收紧配置文件权限。
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // 首次：写带注释的模板原文
            try? ConfigTemplate.templateJSON.data(using: .utf8)?.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        self.store = JSONStore(url: url, defaultValue: ConfigTemplate.fallbackConfig)
        // 落盘副本不含 apiKey（Keychain 才是密钥的落盘点；内存保留，LLM/设置页零改动）
        let fallback = plaintextFallback
        store.persistedValueTransform = { config in
            var scrubbed = config
            for i in scrubbed.providers.indices where !fallback.ids.contains(scrubbed.providers[i].id) {
                scrubbed.providers[i].apiKey = nil
            }
            return scrubbed
        }
        reconcileSecrets()
    }

    /// 密钥链路收敛（启动一次）：
    /// 1. 磁盘明文 key（老配置/模板残留）搬入 Keychain，读回校验通过才允许落盘擦除；
    /// 2. Keychain 里的 key 填回内存——磁盘常态无 key、内存常态有 key。
    /// keychain 读不到时内存保持磁盘解码原样（兜底场景），绝不反向清空。
    private func reconcileSecrets() {
        var config = store.value
        var changed = false
        for i in config.providers.indices {
            let id = config.providers[i].id
            if let plain = config.providers[i].apiKey, !plain.isEmpty {
                secrets.save(id, plain)
                if secrets.read(id) == plain {
                    changed = true   // 已确认入串，本次落盘即可擦除
                } else {
                    plaintextFallback.ids.insert(id)
                    AppLog.log(.error, "keychain.migrationUnverified", ["account": id])
                }
            }
            if let key = secrets.read(id), !key.isEmpty, config.providers[i].apiKey != key {
                config.providers[i].apiKey = key
                changed = true
            }
        }
        if changed {
            // persistedValueTransform 保证非兜底 provider 的落盘副本无 key
            _ = store.save(config)
        }
    }

    var value: AppConfig { store.value }
    var persistenceState: JSONStore<AppConfig>.PersistenceState { store.persistenceState }

    @discardableResult
    func save(_ config: AppConfig) -> Result<Void, Error> {
        // key 全部经 Keychain 落盘：有值写入（读回校验定兜底）、清空删除、
        // 从配置里消失的 provider 清残留
        for provider in config.providers {
            if let key = provider.apiKey, !key.isEmpty {
                secrets.save(provider.id, key)
                if secrets.read(provider.id) == key {
                    plaintextFallback.ids.remove(provider.id)
                } else {
                    plaintextFallback.ids.insert(provider.id)
                    AppLog.log(.error, "keychain.saveUnverified", ["account": provider.id])
                }
            } else {
                secrets.remove(provider.id)
                plaintextFallback.ids.remove(provider.id)
            }
        }
        for removed in Set(store.value.providers.map(\.id)).subtracting(config.providers.map(\.id)) {
            secrets.remove(removed)
            plaintextFallback.ids.remove(removed)
        }
        let result = store.save(config)
        if case .success = result {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return result
    }
}

/// 配置模板（非隔离命名空间：GUI、测试、CLI 都能直接引用）
enum ConfigTemplate {
    /// 模板解析失败时的兜底配置（极简、无注释）
    static let fallbackConfig = AppConfig(activeProviderID: "deepseek", providers: [
        ProviderConfig(id: "deepseek", kind: .openAICompatible, name: "DeepSeek",
                       baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                       apiKey: nil, maxTokens: 4096),
    ])

    static let templateJSON = """
    {
      "_comment": "Parrotlet 配置。activeProviderID 指定当前使用的 provider；apiKey 存于系统钥匙串（按 provider id），不落本文件。baseURL 需含版本前缀，代码只拼 /chat/completions。appearance 外观：auto / light / dark。language 界面语言：auto / zhHans / english。sidebarPinned 会话侧栏展开：true / false。朗读使用系统 en-US 语音。",
      "activeProviderID": "deepseek",
      "appearance": "dark",
      "language": "auto",
      "sidebarPinned": false,
      "providers": [
        {
          "id": "deepseek",
          "kind": "openAICompatible",
          "name": "DeepSeek",
          "baseURL": "https://api.deepseek.com/v1",
          "model": "deepseek-chat",
          "apiKey": null,
          "maxTokens": 4096
        },
        {
          "id": "glm",
          "kind": "openAICompatible",
          "name": "智谱 GLM",
          "baseURL": "https://open.bigmodel.cn/api/paas/v4",
          "model": "glm-4.7",
          "apiKey": null,
          "maxTokens": 4096
        },
        {
          "id": "kimi",
          "kind": "openAICompatible",
          "name": "Kimi (Moonshot)",
          "baseURL": "https://api.moonshot.cn/v1",
          "model": "moonshot-v1-32k",
          "apiKey": null,
          "maxTokens": 4096
        }
      ]
    }
    """
}
