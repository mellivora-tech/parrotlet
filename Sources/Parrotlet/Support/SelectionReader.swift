import AppKit
import ApplicationServices

/// 读自己窗口里的文本选区（取词讲解的输入）。
/// 本进程读自己的 AX 树不需要辅助功能授权——TCC 管的是跨进程检查（原型实测验证）。
/// 注意不能查 focused element：文本选中后焦点仍留在输入框，选区在静态文本上，
/// 所以要遍历 key 窗口的 AX 树找第一个非空选区（聊天窗元素量级 ~100，遍历无感）。
enum SelectionReader {
    struct Selection {
        let text: String
        /// 选区包围盒（屏幕坐标，左上原点）；元素不支持 AXBoundsForRange 时为 nil
        let screenBounds: CGRect?
    }

    @MainActor
    static func currentSelection() -> Selection? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        // swiftlint:disable:next force_cast — AX API 契约返回 AXUIElement
        return findSelection(in: window as! AXUIElement, depth: 0)
    }

    private static func findSelection(in element: AXUIElement, depth: Int) -> Selection? {
        if depth > 15 { return nil }
        var textRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
           let text = textRef as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Selection(text: text, screenBounds: boundsOfSelection(in: element))
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for kid in kids {
            if let found = findSelection(in: kid, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 选区屏幕包围盒（AXBoundsForRange 参数化属性；不支持的元素返回 nil，调用方兜底锚点）
    private static func boundsOfSelection(in element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        // swiftlint:disable:next force_cast
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef
        ) == .success, let boundsValue = boundsRef else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
