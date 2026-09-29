import CoreGraphics
import Foundation
// usage: drag <x1> <y1> <x2> <y2> [steps]
let x1 = Double(CommandLine.arguments[1])!
let y1 = Double(CommandLine.arguments[2])!
let x2 = Double(CommandLine.arguments[3])!
let y2 = Double(CommandLine.arguments[4])!
let steps = Int(CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "80")!
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, CGPoint(x: x1, y: y1)); usleep(120_000)
post(.leftMouseDown, CGPoint(x: x1, y: y1)); usleep(120_000)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    let p = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    post(.leftMouseDragged, p)
    usleep(9_000)
}
usleep(120_000)
post(.leftMouseUp, CGPoint(x: x2, y: y2))
