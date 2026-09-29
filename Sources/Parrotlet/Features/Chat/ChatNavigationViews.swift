import SwiftUI
import AppKit

// MARK: - 滚动度量（刻度轨 + 回底胶囊共用的数据源）

/// ScrollView 的实时滚动状态：偏移 / 内容高 / 视口高。由 AppKit 探针采集——
/// SwiftUI 在 ScrollView 内拿不到滚动偏移（PreferenceKey 永不上报，见 ChatView 注释），
/// 走 NSScrollView.contentView 的 boundsDidChangeNotification 最稳。
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// 距底不足此阈值视为「在底部」——回底胶囊据此显隐，视口变矮的补贴底也据此放行。
    /// 从「一屏」收窄到 120pt：只欠几行的状态（流式收尾滞后、视口微缩）也要让
    /// 胶囊露出来，给用户「没滚到底」的线索；同时避免「在一屏内就被静默拽回底部」
    var nearBottom: Bool { contentHeight - (offset + viewportHeight) < 120 }
}

/// AppKit 滚动探针：挂在 LazyVStack 上（同 ContentHeightProbe），
/// 它的 NSView 在 documentView 内，enclosingScrollView 向上找到内核 NSScrollView。
/// 滚轮触发 boundsDidChange 上报；内容增长（新消息/流式）靠 layout 兜底补报。
@MainActor
struct ScrollMetricsProbe: NSViewRepresentable {
    let onChange: (ScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { [weak coordinator = context.coordinator] m in
            coordinator?.onChange(m)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { [weak coordinator = context.coordinator] m in
            coordinator?.onChange(m)
        }
        context.coordinator.onChange = onChange
        nsView.report()
    }

    final class ProbeView: NSView {
        var onChange: ((ScrollMetrics) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: ScrollMetrics?

        /// 探针最近见过的 NSScrollView（弱引用）：供贴底回读校验同步直读真实位置
        /// （探针上报走 async 有一帧延迟，校验要 ground truth）
        @MainActor static weak var liveScrollView: NSScrollView?

        /// 同步直读 offset / contentHeight / viewportHeight
        @MainActor static func liveMetrics() -> ScrollMetrics? {
            guard let sv = liveScrollView else { return nil }
            return ScrollMetrics(offset: sv.contentView.bounds.origin.y,
                                 contentHeight: sv.documentView?.frame.height ?? 0,
                                 viewportHeight: sv.contentView.bounds.height)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil, let sv = enclosingScrollView else { return }
            // 滚轮滚动：contentView bounds 变化即上报
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sv.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        override func layout() {
            super.layout()
            report()   // 内容增长（流式/新消息）触发布局，补报内容高
        }

        private func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        func report() {
            guard let sv = enclosingScrollView, window != nil else { return }
            Self.liveScrollView = sv
            let m = ScrollMetrics(
                offset: sv.contentView.bounds.origin.y,
                contentHeight: sv.documentView?.frame.height ?? 0,
                viewportHeight: sv.contentView.bounds.height
            )
            guard m != last else { return }
            last = m
            let cb = onChange
            DispatchQueue.main.async { cb?(m) }
        }
    }

    @MainActor
    final class Coordinator {
        var onChange: (ScrollMetrics) -> Void
        init(onChange: @escaping (ScrollMetrics) -> Void) { self.onChange = onChange }
    }
}

// MARK: - 刻度轨（左缘轮次指示器，Codex 实机形态）

/// 左缘等距刻度簇：一轮一根，≤30 根垂直居中，超出后窗口跟随（滚动联动 + 弹性平滑）。
/// 状态分三条通道，互不串色：
/// - hover：选中最长 + 变色，上下各 3 根梯度变短不变色，弹预览卡
/// - 点击：跳转 + 钉住色（全部恢复常态，只有被点选那根留深色）
/// - 滚动中：当前轮临时点亮（指针），停滚 0.8s 熄灭、回落到钉住色
/// 流式进行中轨道可见但禁跳——跳了也会被跟随滚动拽回底部。
struct TickRailView: View {
    let turns: [DialogueTurn]
    let streaming: Bool
    let metrics: ScrollMetrics
    let onJump: (Int) -> Void

    private static let hoverTol: CGFloat = 7    // 半间距，光标在刻度簇上滑动时选中无缝衔接
    private static let clickTol: CGFloat = 14
    /// hover 梯度（Codex 实机）：距选中 0/1/2/3 根的宽度，只变长不变色
    private static let grow: [CGFloat] = [20, 15, 12, 11]
    private static let baseWidth: CGFloat = 10

    /// 窗口起点的平滑跟随值（滚动联动的传送带）；hover/钉住/指针见头注释三通道
    @State private var shown: CGFloat = 0
    @State private var hovered: Int? = nil
    @State private var pinned: Int? = nil
    @State private var scrollLit: Int? = nil
    @State private var litTask: Task<Void, Never>? = nil
    /// 预览卡的轮：hover 驻留 150ms 才出卡（scrub 划过不闪），移开立即消失
    @State private var previewRound: Int? = nil
    @State private var previewTask: Task<Void, Never>? = nil

    var body: some View {
        let rounds = ChatNavigation.pairRounds(turns)
        GeometryReader { geo in
            let count = min(rounds.count, ChatNavigation.maxTicks)
            let pitch = ChatNavigation.clusterPitch(railHeight: geo.size.height, count: count)
            let bandTop = ChatNavigation.bandTop(railHeight: geo.size.height, count: count, pitch: pitch)
            let cf = ChatNavigation.currentFloat(offset: metrics.offset,
                                                 viewportHeight: metrics.viewportHeight,
                                                 contentHeight: metrics.contentHeight,
                                                 rounds: rounds.count)
            let target = ChatNavigation.targetStart(currentFloat: cf, rounds: rounds.count)
            let current = min(max(Int(cf.rounded()), 0), max(rounds.count - 1, 0))

            ZStack(alignment: .topLeading) {
                ForEach(Array(ChatNavigation.visibleRange(shown: shown, count: count,
                                                          total: rounds.count)), id: \.self) { r in
                    tickView(round: r, shown: shown, count: count)
                        .offset(x: 0, y: ChatNavigation.topFor(round: r, shown: shown,
                                                               bandTop: bandTop, pitch: pitch) - 1)
                }
                if let p = previewRound, rounds.indices.contains(p) {
                    RoundSummaryCard(roundIndex: p, round: rounds[p], turns: turns)
                        .offset(x: 46,   // 热区（44）右侧弹出，给向右生长的刻度让位
                                y: Self.clampY(ChatNavigation.topFor(round: p, shown: shown,
                                                                     bandTop: bandTop, pitch: pitch),
                                               railHeight: geo.size.height))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .id(p)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let loc):
                    let h = ChatNavigation.nearestRound(y: loc.y, shown: shown, bandTop: bandTop,
                                                        pitch: pitch, total: rounds.count,
                                                        tol: Self.hoverTol)
                    if h != hovered {
                        hovered = h
                        schedulePreview(h)
                    }
                case .ended:
                    hovered = nil
                    schedulePreview(nil)
                }
            }
            .onTapGesture { loc in
                guard !streaming else { return }   // 流式禁跳
                guard let r = ChatNavigation.nearestRound(y: loc.y, shown: shown, bandTop: bandTop,
                                                          pitch: pitch, total: rounds.count,
                                                          tol: Self.clickTol) else { return }
                pinned = r
                onJump(r)
            }
            .onAppear { shown = target }   // 初帧直落，无动画
            .onChange(of: target) { _, newTarget in
                // 滚动联动：spring retarget 保速度，连续滚动时自然衔接
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { shown = newTarget }
            }
            .onChange(of: metrics.offset) { _, _ in
                // 滚动指针：临时点亮当前轮，停滚 0.8s 熄灭
                scrollLit = current
                litTask?.cancel()
                litTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    scrollLit = nil
                }
            }
        }
    }

    // MARK: 刻度渲染（三通道着色）

    private func tickView(round r: Int, shown: CGFloat, count: Int) -> some View {
        let x = CGFloat(r) - shown
        var width = Self.baseWidth
        var color = Color.primary.opacity(0.13)   // 默认浅灰（自适应明暗）
        if let h = hovered {
            let d = abs(r - h)
            if d < Self.grow.count { width = Self.grow[d] }
            if d == 0 { color = Color.primary.opacity(0.85) }   // 只有选中的变色
        } else if r == (scrollLit ?? pinned ?? -1) {
            color = Color.primary.opacity(0.85)   // 指针/钉住：只留颜色，宽度常态
        }
        return RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: width, height: 2)
            .opacity(ChatNavigation.edgeOpacity(x: x, count: count))
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: scrollLit)
            .animation(.easeOut(duration: 0.12), value: pinned)
    }

    private static func clampY(_ y: CGFloat, railHeight: CGFloat) -> CGFloat {
        min(max(0, y - 40), max(0, railHeight - 180))
    }

    /// 预览驻留：hover 在同一根刻度上停 150ms 才出卡——scrub 连续划过时一张都不弹；
    /// 移开（nil）立即消失。换轮时 0.1s 交叉淡入（.id + .transition(.opacity)）
    private func schedulePreview(_ h: Int?) {
        previewTask?.cancel()
        guard let h else {
            previewRound = nil
            return
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.1)) { previewRound = h }
        }
    }
}

/// 悬停预览卡（方案 A：摘要卡，不渲 markdown）：元信息行（第 N 轮 · 时间）+
/// 提问前 2 行 + 回答前 3 行，纯文本。构建零成本，scrub 不闪；
/// 职责是「认出哪一轮再决定跳不跳」，真要看内容就跳过去。
private struct RoundSummaryCard: View {
    let roundIndex: Int
    let round: ChatRound
    let turns: [DialogueTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(.eaFont(10, .caption))
                .foregroundStyle(.tertiary)
            if round.userIndex < turns.count {
                Text(ChatNavigation.plainSummary(turns[round.userIndex].content, maxLines: 2))
                    .font(.eaFont(12.5, weight: .medium))
                    .lineLimit(2)
            }
            if let a = round.assistantIndex, a < turns.count {
                Text(ChatNavigation.plainSummary(turns[a].content, maxLines: 3))
                    .font(.eaFont(12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                // 无 env 注入处，走 L10n.current 快照（同菜单栏桥接模式）
                Text(L10n.s(.replyGenerating, L10n.current))
                    .font(.eaFont(12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }

    /// 「第 N 轮 · HH:mm」（非今天补月日）
    private var header: String {
        var s = "第 \(roundIndex + 1) 轮"
        if round.userIndex < turns.count {
            let at = turns[round.userIndex].at
            s += Calendar.current.isDateInToday(at)
                ? " · " + at.formatted(.dateTime.hour().minute())
                : " · " + at.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        }
        return s
    }
}

// MARK: - 回底胶囊

/// 滚离底部超过一屏时出现的回底按钮（Codex 式底部居中圆形 ↓，克制不抢戏）。
struct BackToBottomButton: View {
    let show: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .opacity(show ? 1 : 0)
        .scaleEffect(show ? 1 : 0.8)
        .animation(.easeOut(duration: 0.15), value: show)
        .allowsHitTesting(show)
    }
}
