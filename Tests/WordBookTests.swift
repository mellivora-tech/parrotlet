import Foundation

/// 生词本：落盘 round-trip / 去重 / 按日统计
@MainActor
let wordBookTests: [TestCase] = [

    TestCase(name: "wordBook.收藏与落盘 round-trip") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("words-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = WordBookStore(storeURL: url)
        book.add(text: "feature", note: "释义: 功能", context: "We added a feature.")
        try expectEqual(book.entries.count, 1)
        try expect(book.contains("feature"))
        // 换实例重读（落盘验证）
        let reloaded = WordBookStore(storeURL: url)
        try expectEqual(reloaded.entries.count, 1)
        try expectEqual(reloaded.entries[0].text, "feature")
        try expectEqual(reloaded.entries[0].note, "释义: 功能")
    },

    TestCase(name: "wordBook.大小写去重：重复收藏更新内容并提前") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("words-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = WordBookStore(storeURL: url)
        book.add(text: "Feature", note: "旧讲解", context: "ctx1")
        book.add(text: "apple", note: "苹果", context: "ctx2")
        book.add(text: "feature", note: "新讲解", context: "ctx3")
        try expectEqual(book.entries.count, 2, "不应新增条目")
        try expectEqual(book.entries[0].text, "Feature", "重复收藏应提到最前")
        try expectEqual(book.entries[0].note, "新讲解")
        try expectEqual(book.entries[0].context, "ctx3")
    },

    TestCase(name: "wordBook.空白文本不收") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("words-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = WordBookStore(storeURL: url)
        book.add(text: "  \n ", note: "n", context: "c")
        try expectEqual(book.entries.count, 0)
    },

    TestCase(name: "wordBook.按日统计") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("words-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = WordBookStore(storeURL: url)
        book.add(text: "today-word", note: "n", context: "c")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        try expectEqual(book.count(on: Date(), calendar: cal), 1)
        try expectEqual(book.count(on: yesterday, calendar: cal), 0)
        book.remove(book.entries[0].id)
        try expectEqual(book.count(on: Date(), calendar: cal), 0)
    },
]
