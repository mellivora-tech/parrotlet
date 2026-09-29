import Foundation

/// 从模型输出里提取 JSON：容忍代码块围栏和前后闲话。
/// 取首个 `{` 到最后一个 `}` 之间的内容——要求目标本身是 JSON 对象。
enum JSONExtractor {
    static func sliceObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return String(raw[start...end])
    }

    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        guard let sliced = sliceObject(from: raw),
              let data = sliced.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
