import Foundation

extension String {
    /// 空白（含纯空格/换行）→ nil，用于可选字符串字段的表单绑定
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
