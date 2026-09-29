import AppKit
import SwiftUI

/// 取词卡片放置公式（纯函数，可单测）。坐标系约定：
/// - anchor：选区包围盒，宿主窗内容坐标（左上原点，同 AX 换算后的 LookupViewModel.anchor）
/// - windowFrame / visible / 返回值：Cocoa 屏幕坐标（左下原点，同 NSWindow.frame / NSScreen.visibleFrame）
///
/// 从窗内坐标转 Cocoa 只需 windowFrame.maxY（窗顶），不碰主屏高度——
/// 「AX→窗内」需要主屏高是因为跨坐标系原点，「窗内→Cocoa」是同系内平移+翻 y
enum LookupPlacement {
    /// 卡片最小高度：两侧空间都不够时的下限（与面板 contentMinSize 对齐，
    /// relayout 还会再钳一次，双保险）
    static let minCardHeight: CGFloat = 140

    /// 优先选区下方 6pt；下方不够上方够 → 上方；两边都不够 → 放空间大的一侧，
    /// 高度压到该侧空间（返回 cap，卡片内容按 cap 收缩+内滚）。
    /// 最终无条件把面板钳进屏幕可见区——锚点陈旧（选区被滚走）时也不能看不见
    static func frame(anchor: CGRect, windowFrame: CGRect, cardSize: CGSize,
                      visible: CGRect, fallbackTop: CGFloat = 52) -> (frame: CGRect, cap: CGFloat) {
        // 窗内（左上原点）→ Cocoa（左下原点）：y' = 窗顶 - y
        let x0: CGFloat
        let selTop: CGFloat    // 选区上沿（Cocoa y，大 = 靠屏幕上方）
        let selBottom: CGFloat // 选区下沿
        if anchor == .zero {
            // 无锚点（AX 拿不到 bounds）：贴宿主窗顶部下方
            x0 = windowFrame.minX + 24
            selTop = windowFrame.maxY - fallbackTop
            selBottom = selTop
        } else {
            x0 = windowFrame.minX + anchor.minX
            selTop = windowFrame.maxY - anchor.minY
            selBottom = windowFrame.maxY - anchor.maxY
        }
        let x = min(max(visible.minX + 8, x0),
                    max(visible.minX + 8, visible.maxX - 8 - cardSize.width))

        let spaceBelow = selBottom - 6 - visible.minY
        let spaceAbove = visible.maxY - (selTop + 6)
        var h = cardSize.height
        var originY: CGFloat
        var cap: CGFloat = .infinity
        if spaceBelow >= h {
            originY = selBottom - 6 - h
        } else if spaceAbove >= h {
            originY = selTop + 6
        } else if spaceBelow >= spaceAbove {
            cap = max(minCardHeight, spaceBelow)
            h = min(h, cap)
            originY = selBottom - 6 - h
        } else {
            cap = max(minCardHeight, spaceAbove)
            h = min(h, cap)
            originY = selTop + 6
        }
        // 安全钳：完整收进可见区（锚点陈旧时各分支都可能算出屏外）
        originY = min(max(originY, visible.minY + 4),
                      max(visible.minY + 4, visible.maxY - 4 - h))
        return (CGRect(x: x, y: originY, width: cardSize.width, height: h), cap)
    }
}

/// 取词卡片面板：独立 NSPanel（非激活、可缩放、透明标题栏），卡片不再受宿主窗裁剪。
/// 职责：屏幕坐标放置、跟随宿主窗移动/缩放、原生缩放回馈 VM、点外/Esc/失焦关闭。
///
/// dismiss 时断开 hostingView，避免 VM → controller → panel → hostingView → VM
/// 形成跨窗口生命周期的保留环。
@MainActor
final class LookupPanelController: NSObject {
    private var panel: NSPanel?
    private weak var lookup: LookupViewModel?
    private weak var hostWindow: NSWindow?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    // MARK: - 显隐

    func show(lookup: LookupViewModel, env: AppEnvironment?) {
        self.lookup = lookup
        if panel == nil {
            guard let env else { return }
            panel = makePanel(lookup: lookup, env: env)
        }
        hostWindow = NSApp.keyWindow
        startObservers()
        startMonitors()
        relayout(lookup: lookup)
        panel?.orderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        stopMonitors()
        stopObservers()
        hostWindow = nil
        lookup = nil
    }

    /// 按当前锚点/尺寸重算放置（show、宿主窗移动、卡片理想高度变化时调用）。
    /// 宽度保持面板现状（用户可能拖宽过），高度贴卡片上报的理想高
    func relayout(lookup: LookupViewModel) {
        guard let panel, let hostWindow else { return }
        let currentWidth = panel.frame.width > 1 ? panel.frame.width : 300
        let base = CGSize(width: currentWidth, height: max(140, lookup.idealCardHeight))
        let selCocoa = CGPoint(x: hostWindow.frame.minX + lookup.anchor.midX,
                               y: hostWindow.frame.maxY - lookup.anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(selCocoa) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        var (frame, cap) = LookupPlacement.frame(
            anchor: lookup.anchor, windowFrame: hostWindow.frame,
            cardSize: base, visible: screen.visibleFrame)
        // setFrame 永不突破 contentMin/MaxSize：压高分支可能给出 < minSize 的高度，
        // 窗口在布局时强制 min 与 frame 冲突会抛异常
        frame.size.width = min(max(frame.size.width, 240), 520)
        frame.size.height = min(max(frame.size.height, 140), 560)
        if abs(cap - lookup.heightCap) > 0.5 { lookup.heightCap = cap }
        // 与现状一致就不动：每次 setFrame 都会触发一轮约束/布局 pass，
        // 无谓的 setFrame 是给「布局→尺寸变→再布局」循环探测器递刀子
        guard abs(frame.origin.x - panel.frame.origin.x) > 0.5
            || abs(frame.origin.y - panel.frame.origin.y) > 0.5
            || abs(frame.size.width - panel.frame.width) > 0.5
            || abs(frame.size.height - panel.frame.height) > 0.5 else { return }
        panel.setFrame(frame, display: false)
    }

    // MARK: - 面板装配

    private func makePanel(lookup: LookupViewModel, env: AppEnvironment) -> NSPanel {
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        // 无可见标题栏的 titled 窗口：拿原生边缘拖拽缩放 + 系统圆角 + 系统阴影，
        // 同时不出现标题栏 UI（overlay 时代手写的把手/冻结/钳位全部由窗口系统接管）
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            p.standardWindowButton($0)?.isHidden = true
        }
        p.isFloatingPanel = true
        // 宿主窗是菜单栏 app 高层级窗口，.floating 会被它盖住（实测下半截藏在主窗后）
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false // 隐藏走显式 dismiss（点外/Esc/失焦），不搞自动
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentMinSize = CGSize(width: 240, height: 140)
        p.contentMaxSize = CGSize(width: 520, height: 560)
        let hosting = NSHostingView(rootView: LookupCard(lookup: lookup).environment(env))
        // 清空 sizingOptions，尽量关掉 SwiftUI「理想尺寸→自动改窗口大小」的联动；
        // 真正防崩的是数据流单向：卡片是柔性布局（填满面板），任何窗口尺寸都合法，
        // 不回馈、不纠正——「约束 pass 循环探测器」异常（实测崩溃四连）失去发动机
        hosting.sizingOptions = []
        p.contentView = hosting
        return p
    }

    // MARK: - 关闭路径监控

    private func startMonitors() {
        guard localClickMonitor == nil else { return }
        // 点面板外（含主窗）→ 关，事件放行（NSPopover .transient 同款：关闭与点击一次完成）。
        // 本地监控管 app 内，全局监控管其他 app
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window !== panel else { return }
                self.lookup?.close()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookup?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.lookup?.close() }
                return nil
            }
            return event
        }
    }

    private func stopMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - 宿主窗/应用生命周期跟随

    private func startObservers() {
        stopObservers()
        guard let hostWindow else { return }
        let center = NotificationCenter.default
        // 宿主窗移动/缩放（含聊天窗自动长高）→ 卡片重新贴选区。
        // 延迟到显示周期之后：通知在宿主窗布局/resize 管线内发出，同步 setFrame 面板 +
        // 改 heightCap（@Observable，卡片在读）会重入显示周期（与 noteIdealHeight 同坑）
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: hostWindow, queue: .main) {
                [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let lookup = self.lookup else { return }
                        self.relayout(lookup: lookup)
                    }
                }
            })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: hostWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookup?.close() }
        })
        // 切走 app（⌘⇥ 等）→ 收卡片（弹层语义；点其他 app 的点击已被全局监控覆盖）
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookup?.close() }
        })
    }

    private func stopObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

// MARK: - 卡片视图

/// 取词浮层卡片：选中词/短语 + 🔊 发音 + LLM 语境讲解。
/// 由 LookupPanelController 的 NSPanel 承载：缩放是系统原生边缘拖拽（contentMin/MaxSize
/// 钳制），卡片柔性布局填满面板——任何窗口尺寸都合法，无需把尺寸回馈模型层
struct LookupCard: View {
    @Environment(AppEnvironment.self) private var env
    let lookup: LookupViewModel
    /// 内容区实测高度：自动模式下面板高 = chrome + min(内容, 上限)
    @State private var contentHeight: CGFloat = 120

    private static let autoWidth: CGFloat = 300
    private static let maxContentHeight: CGFloat = 320
    /// chrome ≈ 标题行 + Divider + spacing + 上下 padding，压高时从 heightCap 里扣
    private static let chromeHeight: CGFloat = 76

    private var contentCap: CGFloat {
        max(48, min(Self.maxContentHeight, lookup.heightCap - Self.chromeHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(lookup.selection)
                    .font(.eaFont(16, .headline, weight: .semibold))
                    .lineLimit(2)
                // 词性/搭配类型 chip：随结构化结果一起到位，loading 时不占位
                if let tag = lookup.explanation?.posTag, !tag.isEmpty {
                    Text(tag)
                        .font(.eaFont(11, .body, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                Button { lookup.speakSelection() } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(env.t(.lookupPronounce))
                // 收藏进生词本：讲解到位才点亮（loading/出错时没有可沉淀的内容）
                Button { lookup.toggleWordBook() } label: {
                    Image(systemName: lookup.isSavedToWordBook ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(lookup.isSavedToWordBook ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .disabled({
                    if case .result = lookup.phase { return false }
                    return !lookup.isSavedToWordBook   // 已收藏的随时可取消
                }())
                .help(env.t(lookup.isSavedToWordBook ? .wordSaved : .saveWord))
                Button { lookup.copyExplanation() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(env.t(.copyExplanation))
                Button { lookup.continueInChat() } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(lookup.selection.isEmpty)
                .help(env.t(.continueLookup))
                Button { lookup.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // 音标：弱化辅助信息，紧跟标题（不重复单词本身）
            if let phonetic = lookup.explanation?.phonetic, !phonetic.isEmpty {
                Text(phonetic)
                    .font(.eaFont(13))
                    .foregroundStyle(.secondary)
            }
            Divider()
                .padding(.vertical, 2)
            // 内容区内置滚动。idealHeight = min(实测内容, 上限)：窗口按理想尺寸
            // 自动贴合内容；用户拖大后面板更大，ScrollView 柔性吃掉多余空间
            ScrollView {
                phaseContent
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
            }
            .frame(idealHeight: min(contentHeight, contentCap))
        }
        .padding(12)
        // 柔性卡片：理想尺寸供面板贴合内容，max 无限 → 用户缩放后填满窗口。
        // 数据流单向（VM → 卡片），尺寸不回馈 VM——回馈即「约束 pass 循环」的燃料
        .frame(idealWidth: Self.autoWidth, maxWidth: .infinity,
               idealHeight: Self.chromeHeight + min(contentHeight, contentCap),
               maxHeight: .infinity, alignment: .topLeading)
        // 理想高度上报：面板据此重放置（顶边锚定）。onChange 在渲染提交后跑，
        // 不在布局管线内，比 onGeometryChange 上报安全一档
        .onChange(of: contentHeight) { _, h in
            lookup.noteIdealHeight(Self.chromeHeight + min(h, contentCap))
        }
        .onChange(of: lookup.heightCap) { _, _ in
            lookup.noteIdealHeight(Self.chromeHeight + min(contentHeight, contentCap))
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        // 阴影由面板窗口（hasShadow，按内容透明度成型）提供，不再自绘
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch lookup.phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(env.t(.lookupLoading))
                    .font(.eaFont(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
        case .result(let markdown):
            if let ex = lookup.explanation {
                structuredBody(ex)
            } else {
                // 解析失败的兜底：原文 markdown 渲染，内容不丢
                MarkdownText(markdown)
                    .textSelection(.enabled)
            }
        case .error(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                    .font(.eaFont(12))
                    .foregroundStyle(error.style == .guidance ? Color.accentColor : Color.red)
                if error.action != nil {
                    Button(env.t(.goToSettings)) {
                        WindowOpenerBridge.open(SceneID.settings)
                    }
                    .buttonStyle(.borderless)
                    .font(.eaFont(12))
                }
            }
        }
    }

    /// 结构化正文：释义为主段落；例句独立浅底色块（英文主、中文辅）
    @ViewBuilder
    private func structuredBody(_ ex: LookupExplanation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ex.definition)
                .font(.eaFont(14))
                .lineSpacing(3)
                .textSelection(.enabled)
            if !ex.exampleEn.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ex.exampleEn)
                        .font(.eaFont(13))
                        .lineSpacing(2)
                    if !ex.exampleZh.isEmpty {
                        Text(ex.exampleZh)
                            .font(.eaFont(12))
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
