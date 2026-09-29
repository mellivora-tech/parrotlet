import CoreGraphics
import Foundation
let text = CommandLine.arguments[1]
let interval = useconds_t((Double(CommandLine.arguments[2]) ?? 0.09) * 1_000_000)
let src = CGEventSource(stateID: .hidSystemState)
for scalar in text.unicodeScalars {
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
    var u = [UniChar](String(scalar).utf16)
    down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
    up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
    down.post(tap: .cghidEventTap)
    usleep(8000)
    up.post(tap: .cghidEventTap)
    usleep(interval)
}
