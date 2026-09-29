import CoreGraphics
import Foundation
// usage: key <keycode> [cmd] [shift]
// CGKeyCode 常用值：36=Return，51=Delete，0=A；cmd/shift 用字面量传入。
let code = CGKeyCode(UInt16(CommandLine.arguments[1])!)
var flags: CGEventFlags = []
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "cmd" { flags.insert(.maskCommand) }
if CommandLine.arguments.count > 3, CommandLine.arguments[3] == "shift" { flags.insert(.maskShift) }
let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
down?.flags = flags
down?.post(tap: .cghidEventTap)
usleep(30000)
let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
up?.flags = flags
up?.post(tap: .cghidEventTap)
