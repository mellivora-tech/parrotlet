import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(w[kCGWindowNumber as String] ?? 0) x=\(b["X"] ?? 0) y=\(b["Y"] ?? 0) w=\(b["Width"] ?? 0) h=\(b["Height"] ?? 0)")
}
