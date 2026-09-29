import Foundation

/// 泛型 JSON 存储：原子写；坏文件隔离后进入只读恢复模式，避免默认值覆盖用户数据。
@MainActor
final class JSONStore<Element: Codable> {
    enum PersistenceState: Equatable {
        case normal
        case recoveryRequired(quarantineURL: URL)
        case failed(String)
    }

    struct SaveFailure: Error, Equatable {
        let message: String
    }

    private let url: URL
    private(set) var value: Element
    private let defaultValue: Element
    private(set) var persistenceState: PersistenceState = .normal

    /// 落盘前的编码变换：内存值不变，写磁盘的副本先过它（ConfigStore 用来擦除 apiKey）
    var persistedValueTransform: ((Element) -> Element)?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    init(url: URL, defaultValue: Element) {
        self.url = url
        self.defaultValue = defaultValue
        value = defaultValue

        let fm = FileManager.default
        // 权限错误、磁盘错误不能伪装成“文件不存在”；进入 failed 状态并禁止覆盖。
        guard fm.fileExists(atPath: url.path) else {
            if let quarantineURL = Self.latestQuarantineURL(for: url) {
                persistenceState = .recoveryRequired(quarantineURL: quarantineURL)
            }
            return
        }

        do {
            let data = try Data(contentsOf: url)
            value = try decoder.decode(Element.self, from: data)
        } catch let error as DecodingError {
            let quarantineURL = Self.quarantineURL(for: url)
            do {
                try fm.moveItem(at: url, to: quarantineURL)
                persistenceState = .recoveryRequired(quarantineURL: quarantineURL)
                AppLog.log(.error, "storage.corrupt", [
                    "file": url.lastPathComponent,
                    "error": describeDecodingError(error)
                ])
            } catch {
                // 移动失败时保留原文件并不再写入，仍然优先保护用户数据。
                persistenceState = .recoveryRequired(quarantineURL: url)
                AppLog.log(.error, "storage.quarantineFailed", [
                    "file": url.lastPathComponent,
                    "error": error.localizedDescription
                ])
            }
        } catch {
            persistenceState = .failed(error.localizedDescription)
            AppLog.log(.error, "storage.readFailed", [
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    @discardableResult
    func save(_ newValue: Element) -> Result<Void, Error> {
        guard persistenceState.isWritable else {
            let failure = SaveFailure(message: "数据文件需要恢复，已阻止本次写入")
            AppLog.log(.error, "storage.saveBlocked", ["file": url.lastPathComponent])
            return .failure(failure)
        }

        value = newValue
        do {
            let directory = url.deletingLastPathComponent()
            let fm = FileManager.default
            if fm.fileExists(atPath: directory.path) {
                guard fm.isWritableFile(atPath: directory.path) else {
                    throw SaveFailure(message: "数据目录不可写")
                }
            } else {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let data = try encoder.encode(persistedValueTransform?(value) ?? value)
            try data.write(to: url, options: .atomic)
            persistenceState = .normal
            return .success(())
        } catch {
            let failure = SaveFailure(message: error.localizedDescription)
            persistenceState = .failed(error.localizedDescription)
            AppLog.log(.error, "storage.saveFailed", [
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return .failure(failure)
        }
    }

    private static func quarantineURL(for url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return url.appendingPathExtension("corrupt-\(stamp)")
    }

    private static func latestQuarantineURL(for url: URL) -> URL? {
        let fm = FileManager.default
        let prefix = url.lastPathComponent + ".corrupt-"
        guard let names = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return nil
        }
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .last
            .map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }
}

private extension JSONStore.PersistenceState {
    var isWritable: Bool {
        if case .normal = self { return true }
        return false
    }
}
