import Foundation
import Observation

/// 生词本：取词讲解的收藏沉淀（对话 → 纠错 → 收藏 → 复盘 的学习闭环）。
/// 落盘 words.json（JSONStore 原子写）
@MainActor
@Observable
final class WordBookStore {
    /// 倒序（新的在前），视图直接渲染
    private(set) var entries: [WordEntry] = []
    private(set) var persistenceState: JSONStore<WordBookArchive>.PersistenceState = .normal
    /// 落盘走版本锚点包装（v1 裸数组读入即迁移，见 PersistedArchives.swift）
    private let store: JSONStore<WordBookArchive>

    init(storeURL: URL = AppPaths.dataFile("words.json")) {
        store = JSONStore(url: storeURL, defaultValue: WordBookArchive(words: []))
        entries = store.value.words.sorted { $0.createdAt > $1.createdAt }
    }

    /// 是否已收藏（大小写不敏感）
    func contains(_ text: String) -> Bool {
        let key = text.lowercased()
        return entries.contains { $0.text.lowercased() == key }
    }

    /// 收藏；同词重复收藏 = 更新讲解/出处 + 刷新时间（提到最前）
    func add(text: String, note: String, context: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        if let idx = entries.firstIndex(where: { $0.text.lowercased() == key }) {
            entries[idx].note = note
            entries[idx].context = context
            entries[idx].createdAt = Date()
        } else {
            entries.append(WordEntry(text: trimmed, note: note, context: context))
        }
        entries.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// 某天的收藏数（复盘页统计卡用）
    func count(on date: Date, calendar: Calendar = .current) -> Int {
        entries.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }.count
    }

    private func persist() {
        let result = store.save(WordBookArchive(words: entries))
        persistenceState = store.persistenceState
        if case .failure(let error) = result {
            AppLog.log(.error, "wordBook.saveFailed", ["error": error.localizedDescription])
        }
    }
}
