import SwiftUI

/// 键盘灯式流光边框：彗星线程——active 期间一段亮彩虹拖着尾巴沿圆角矩形边框单向匀速跑。
/// - 最少一圈：active 结束时彗星不足一圈（LLM 回复快）则补跑满一圈再淡出；
///   宽限期内 active 再次翻 true 会重锚（从新激活起再保一圈）
/// - 空闲：完全无痕（整环透明度归零），边框回到宿主自己的样子
/// - 出现/消失：0.25s 淡入淡出（Canvas 内容不可动画，用外层 opacity；淡出的是定格帧）
/// - 减弱动态效果（Reduce Motion）：不跑，active 期间显示一环静态亮彩（无运动）
///
/// 画法：Canvas 按弧长参数化边框周长（四直边 + 四段圆角弧），每小段按
/// 「段位置 s 的静态彩虹 × 彗星亮度包络」上色——周向速度恒定，才是真正的
/// 顺一个方向流动（整圈锥形渐变 rotationEffect 旋转是按方位角转，看着像原地变彩）。
/// TimelineView 驱动逐帧重画，相位取自挂钟（暂停/恢复不跳变）；paused 挂 !flowing，
/// 空闲零 tick。head 恒用挂钟相位：淡出瞬间的单帧自然冻结在原位。
struct RainbowFlowBorder: View {
    var cornerRadius: CGFloat
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 可见（在跑）= 激活中，或仍在收尾宽限期内。Date() 在 body 求值时取；
    /// 宽限到期靠 task 睡醒清锚触发重算（TimelineView 的 tick 只刷新内容不重算 body）
    @State private var minimumUntil: Date?
    private var running: Bool {
        active || (minimumUntil.map { Date() < $0 } ?? false)
    }

    private var flowing: Bool { running && !reduceMotion }

    /// 一圈 6s（周长 ~2000pt ≈ 340pt/s）；尾巴时间常数（占周长比例）
    private static let period: Double = 6
    private static let tail: Double = 0.16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { timeline in
            Canvas { ctx, size in
                let pts = Self.perimeterPoints(size: size, radius: cornerRadius)
                guard pts.count > 4 else { return }
                let total = pts[pts.count - 1].s
                // 彗星头位置（0..<total）。恒用挂钟相位：空闲暂停后单帧自然冻结在原位，
                // 再次激活从当前时刻续跑，不跳变
                let head = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period * total
                draw(ctx: ctx, pts: pts, total: total, head: head)
            }
        }
        // 出现/消失的淡入淡出：Canvas 内容不可动画，动画挂在外层视图 opacity 上
        .opacity(running ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: running)
        // 最少一圈：激活时锚定 now+period；结束时未到期则睡到到期清锚
        // （清锚 → body 重算 → running 翻 false → 暂停 + 淡出）。
        // 睡醒先查取消：宽限期内又激活，旧 task 的取消残留不能清掉新锚
        .task(id: active) {
            if active {
                minimumUntil = Date().addingTimeInterval(Self.period)
            } else if let until = minimumUntil, until > Date() {
                try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                minimumUntil = nil
            } else {
                minimumUntil = nil
            }
        }
    }

    private func draw(ctx: GraphicsContext, pts: [PerimeterPoint], total: CGFloat, head: CGFloat) {
        for i in 0...(pts.count - 2) {
            let a = pts[i], b = pts[i + 1]
            // 该段落后彗星头的距离比例（0 = 正好在头）
            let behind = ((total + a.s - head).truncatingRemainder(dividingBy: total)) / total
            // 亮度包络：暗底 0.18 + 头部指数衰减尾巴
            let bright: CGFloat = 0.18 + 0.82 * CGFloat(exp(-Double(behind) / Self.tail))
            let color = Color(hue: Double(a.s / total), saturation: 0.9, brightness: 1)
                .opacity(bright)
            var seg = Path()
            seg.move(to: CGPoint(x: a.x, y: a.y))
            seg.addLine(to: CGPoint(x: b.x, y: b.y))
            // 两层一遍画完：泛光带（宽而淡）+ 主环（细而实），省第二次遍历
            ctx.stroke(seg, with: .color(color.opacity(0.35)), lineWidth: 8)
            ctx.stroke(seg, with: .color(color), lineWidth: 4)
        }
    }

    // MARK: - 周长弧长参数化

    /// 边框上的采样点：位置 + 从起点累计弧长。顺时针（顶边→右→底→左）
    private struct PerimeterPoint {
        var x: CGFloat, y: CGFloat, s: CGFloat
    }

    /// 步长 ~4pt 一段，圆角弧上密、直边直取两端
    private static func perimeterPoints(size: CGSize, radius: CGFloat) -> [PerimeterPoint] {
        let w = size.width, h = size.height
        let r = min(radius, min(w, h) / 2)
        var pts: [PerimeterPoint] = []
        var s: CGFloat = 0
        func add(_ x: CGFloat, _ y: CGFloat) {
            if let last = pts.last {
                s += hypot(x - last.x, y - last.y)
            }
            pts.append(PerimeterPoint(x: x, y: y, s: s))
        }
        // 四段直边 + 四段四分之一圆弧，圆弧每 15° 一点
        let step = max(6, (w + h) / 80)
        // 顶边（左→右）
        stride(from: r, through: w - r, by: step).forEach { add($0, 0) }
        add(w - r, 0)
        // TR 弧（−90°→0°）
        arc(center: CGPoint(x: w - r, y: r), radius: r, from: -.pi / 2, add: add)
        // 右边（上→下）
        stride(from: r, through: h - r, by: step).forEach { add(w, $0) }
        add(w, h - r)
        // BR 弧（0°→90°）
        arc(center: CGPoint(x: w - r, y: h - r), radius: r, from: 0, add: add)
        // 底边（右→左）
        stride(from: w - r, through: r, by: -step).forEach { add($0, h) }
        add(r, h)
        // BL 弧（90°→180°）
        arc(center: CGPoint(x: r, y: h - r), radius: r, from: .pi / 2, add: add)
        // 左边（下→上）
        stride(from: h - r, through: r, by: -step).forEach { add(0, $0) }
        add(0, r)
        // TL 弧（180°→270°），终点闭回起点 (r, 0)
        arc(center: CGPoint(x: r, y: r), radius: r, from: .pi, add: add)
        return pts
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: Double,
                            add: (CGFloat, CGFloat) -> Void) {
        let step: Double = .pi / 12 // 15°
        for i in 1...4 {
            let a = start + step * Double(i)
            add(center.x + radius * CGFloat(cos(a)), center.y + radius * CGFloat(sin(a)))
        }
    }
}
