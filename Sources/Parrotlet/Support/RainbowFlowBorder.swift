import SwiftUI

/// 可暂停的动画时钟：运行期间按时间前进，暂停时累计相位，恢复后不跳变。
struct RainbowFlowPhaseClock {
    private var accumulated: TimeInterval = 0
    private var startedAt: Date?

    mutating func setFlowing(_ flowing: Bool, at date: Date) {
        if flowing {
            guard startedAt == nil else { return }
            startedAt = date
        } else if let startedAt {
            accumulated += max(0, date.timeIntervalSince(startedAt))
            self.startedAt = nil
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(startedAt))
    }
}

/// 尺寸固定的边框几何与颜色数据。TimelineView 逐帧只读这里，不重建 Path 或色相。
struct RainbowFlowBorderGeometry {
    struct PerimeterPoint {
        var x: CGFloat, y: CGFloat, s: CGFloat
    }

    struct Segment {
        var path: Path
        var s: CGFloat
        var hue: Double
    }

    static let period: Double = 6
    static let tail: Double = 0.16
    /// 指数尾迹在 0.4 圈后开始收束，半圈处归零；远处底环完全交给静态层。
    static let tailSpan: Double = 0.5
    static let mainWidth: CGFloat = 4
    static let glowWidth: CGFloat = 8
    /// 泛光外缘之外再留 0.5pt 抗锯齿余量，避免窗口裁掉描边的外侧一半。
    static let strokeInset = glowWidth / 2 + 0.5

    let rect: CGRect
    let segments: [Segment]
    let total: CGFloat

    init(size: CGSize, cornerRadius: CGFloat) {
        let inset = min(Self.strokeInset, min(size.width, size.height) / 2)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        self.rect = rect
        // rect 是外框向内平移后的同心圆角矩形，半径也要同步减去内缩量。
        let points = Self.perimeterPoints(rect: rect, radius: max(0, cornerRadius - inset))
        let totalLength = points.last?.s ?? 0
        total = totalLength
        guard totalLength > 0, points.count > 1 else {
            segments = []
            return
        }
        let builtSegments: [Segment] = (0...(points.count - 2)).compactMap { i in
            let a = points[i], b = points[i + 1]
            guard b.s > a.s else { return nil }
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            return Segment(path: path, s: a.s, hue: Double(a.s / totalLength))
        }
        segments = builtSegments
    }

    func head(elapsed: TimeInterval) -> CGFloat {
        guard total > 0 else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period
        return CGFloat(phase) * total
    }

    /// 彗星头后方（已经经过）的亮度；头前方和半圈以外不画动态层。
    static func cometIntensity(at s: CGFloat, head: CGFloat, total: CGFloat) -> Double {
        guard total > 0 else { return 0 }
        var behind = (head - s).truncatingRemainder(dividingBy: total)
        if behind < 0 { behind += total }
        let distance = Double(behind / total)
        guard distance < tailSpan else { return 0 }
        let intensity = exp(-distance / tail)
        // 最后 0.1 圈线性收束到零，避免有限尾迹末端出现亮点断口。
        let fadeLength = tailSpan - 0.4
        guard distance > 0.4 else { return intensity }
        return intensity * (tailSpan - distance) / fadeLength
    }

    static func strokeStyle(lineWidth: CGFloat) -> StrokeStyle {
        // 分段颜色不同，必须分别描边；圆端帽覆盖相邻线段外侧的楔形缺口。
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    func drawBase(ctx: GraphicsContext) {
        for segment in segments {
            let color = Color(hue: segment.hue, saturation: 0.9, brightness: 1)
            ctx.stroke(segment.path, with: .color(color.opacity(0.18 * 0.35)),
                       style: Self.strokeStyle(lineWidth: Self.glowWidth))
            ctx.stroke(segment.path, with: .color(color.opacity(0.18)),
                       style: Self.strokeStyle(lineWidth: Self.mainWidth))
        }
    }

    func drawComet(ctx: GraphicsContext, head: CGFloat) {
        for segment in segments {
            let intensity = Self.cometIntensity(at: segment.s, head: head, total: total)
            guard intensity > 0 else { continue }
            let color = Color(hue: segment.hue, saturation: 0.9, brightness: 1)
            ctx.stroke(segment.path, with: .color(color.opacity(intensity * 0.35)),
                       style: Self.strokeStyle(lineWidth: Self.glowWidth))
            // 叠在 0.18 的静态底环上后，头部合成不透明度回到 1。
            ctx.stroke(segment.path, with: .color(color.opacity(intensity)),
                       style: Self.strokeStyle(lineWidth: Self.mainWidth))
        }
    }

    /// 边框采样点：位置 + 累计弧长，顺时针（顶边→右→底→左），末尾闭回起点。
    static func perimeterPoints(rect: CGRect, radius: CGFloat) -> [PerimeterPoint] {
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        var pts: [PerimeterPoint] = []
        var s: CGFloat = 0
        func add(_ x: CGFloat, _ y: CGFloat) {
            guard let last = pts.last else {
                pts.append(PerimeterPoint(x: x, y: y, s: 0))
                return
            }
            let distance = hypot(x - last.x, y - last.y)
            guard distance > 0 else { return }
            s += distance
            pts.append(PerimeterPoint(x: x, y: y, s: s))
        }
        // 四段直边 + 四段 90° 圆弧，圆弧每 15° 一点。
        let step = max(6, (rect.width + rect.height) / 80)
        stride(from: left + r, through: right - r, by: step).forEach { add($0, top) }
        add(right - r, top)
        arc(center: CGPoint(x: right - r, y: top + r), radius: r, from: -.pi / 2, add: add)
        stride(from: top + r, through: bottom - r, by: step).forEach { add(right, $0) }
        add(right, bottom - r)
        arc(center: CGPoint(x: right - r, y: bottom - r), radius: r, from: 0, add: add)
        stride(from: right - r, through: left + r, by: -step).forEach { add($0, bottom) }
        add(left + r, bottom)
        arc(center: CGPoint(x: left + r, y: bottom - r), radius: r, from: .pi / 2, add: add)
        stride(from: bottom - r, through: top + r, by: -step).forEach { add(left, $0) }
        add(left, top + r)
        arc(center: CGPoint(x: left + r, y: top + r), radius: r, from: .pi, add: add)
        if let first = pts.first, let last = pts.last {
            if hypot(first.x - last.x, first.y - last.y) > 0.0001 {
                add(first.x, first.y)
            } else {
                // 三角函数的末点可能有极小误差：坐标吸附起点，不追加零弧长采样段。
                pts[pts.count - 1] = PerimeterPoint(x: first.x, y: first.y, s: last.s)
            }
        }
        return pts
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: Double,
                            add: (CGFloat, CGFloat) -> Void) {
        let step: Double = .pi / 12 // 15°
        for i in 1...6 {
            let a = start + step * Double(i)
            add(center.x + radius * CGFloat(cos(a)), center.y + radius * CGFloat(sin(a)))
        }
    }
}

/// 键盘灯式流光边框：active 期间亮彩虹拖着尾巴沿圆角矩形边框单向匀速跑。
/// - 最少一圈：正常动态模式下，active 结束时不足一圈则补跑满一圈再淡出；
///   宽限期内重新 active 会重锚。Reduce Motion 无需补圈，active 结束即淡出。
/// - 空闲：完全无痕；出现/消失均为 0.25s 透明度渐变。
/// - Reduce Motion / 贴边隐藏：相位暂停，恢复时从冻结位置继续。
/// - 静态暗底与动态彗星分层：TimelineView 只驱动动态层，几何和底色不逐帧重建。
struct RainbowFlowBorder: View {
    var cornerRadius: CGFloat
    var active: Bool
    var paused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var minimumUntil: Date?
    @State private var hasAppeared = false
    @State private var phaseClock = RainbowFlowPhaseClock()

    static func shouldRun(active: Bool, minimumUntil: Date?, reduceMotion: Bool, now: Date) -> Bool {
        active || (!reduceMotion && (minimumUntil.map { now < $0 } ?? false))
    }

    static func shouldFlow(running: Bool, reduceMotion: Bool, paused: Bool) -> Bool {
        running && !reduceMotion && !paused
    }

    private var running: Bool {
        Self.shouldRun(active: active, minimumUntil: minimumUntil,
                       reduceMotion: reduceMotion, now: Date())
    }

    private var flowing: Bool {
        Self.shouldFlow(running: running, reduceMotion: reduceMotion, paused: paused)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RainbowFlowBorderGeometry(size: proxy.size, cornerRadius: cornerRadius)
            ZStack {
                // 静态层不挂在 TimelineView 内，动画 tick 不会重算或重提交暗底。
                Canvas { ctx, _ in geometry.drawBase(ctx: ctx) }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { timeline in
                    Canvas { ctx, _ in
                        let elapsed = phaseClock.elapsed(at: timeline.date)
                        geometry.drawComet(ctx: ctx, head: geometry.head(elapsed: elapsed))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        // hasAppeared 让“创建时已经 active”的查询面板也从 0 淡入，而非首帧直接不透明。
        .opacity(hasAppeared && running ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: hasAppeared && running)
        .onAppear {
            phaseClock.setFlowing(flowing, at: Date())
            hasAppeared = true
        }
        .onDisappear {
            phaseClock.setFlowing(false, at: Date())
            hasAppeared = false
        }
        .onChange(of: flowing) { _, isFlowing in
            phaseClock.setFlowing(isFlowing, at: Date())
        }
        .onChange(of: reduceMotion) { _, reduceMotion in
            if reduceMotion {
                minimumUntil = nil
            } else if active {
                // 动态效果恢复后，从本次续跑起保证一圈。
                minimumUntil = Date().addingTimeInterval(RainbowFlowBorderGeometry.period)
            }
        }
        .task(id: active) {
            // 被取消的旧 active=true 任务不能在新任务之后写入过期锚点。
            guard !Task.isCancelled else { return }
            if active {
                minimumUntil = reduceMotion ? nil : Date().addingTimeInterval(RainbowFlowBorderGeometry.period)
            } else if !reduceMotion, let until = minimumUntil, until > Date() {
                try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                minimumUntil = nil
            } else {
                minimumUntil = nil
            }
        }
    }
}
