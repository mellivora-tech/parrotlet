import SwiftUI
import AppKit
import QuartzCore

/// 侧栏开合过渡（issue #3 方案 1：过渡槽位）。
/// env.sidebarPinned 立即翻转（持久化同步走），布局槽位靠本状态续命：
/// 收起 = 槽位保留，被窗口动画从左侧逐步吃掉，动画结束才撤；
/// 展开 = 槽位立即占位，从 0 宽被窗口动画逐步揭开。
/// 全程聊天列钉死当前宽、槽位吸收全部宽度变化 → 正文零重排。
/// （跳动的根因：布局随 pinned 瞬时翻转，窗口 setFrame 还要 0.25s——两个时钟不同步）
private struct SidebarTransition {
    /// 过渡中聊天列的钉死宽度（开合前一瞬的实测聊天列宽）
    let chatWidth: CGFloat
    /// true = 收起过渡（pinned 已翻 false，槽位续命中等撤）
    let collapsing: Bool
}

/// 聊天主入口：打开即对话（onAppear 自动续上次或开新）。
struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    /// 过渡状态上提到这层：窗口宽度约束挂在根视图上，过渡中 minWidth 必须钉 400
    /// （两方向的安全下限）——否则展开时 min 抢先升 620，动画每帧视觉宽都违反
    /// contentMinSize，SwiftUI 逐帧回钳 = 整窗抖动（收起是降 min，天然不受影响）
    @State private var sidebarTransition: SidebarTransition?

    var body: some View {
        ConversationView(vm: env.chat, sidebarTransition: $sidebarTransition)
            // 竖长窄栏形态（对齐参考）：宽窗时内容列限宽居中，行宽不失控。
            // 高度完全内容自适应：无最小/最大高度限制（自动高度 680–900 只钳引擎，
            // 用户手动拖拽不受限——R3 修正）
            // 侧栏展开时最小/理想宽度加上侧栏宽，SwiftUI 尺寸协商与开合的 setFrame 同目标。
            // 过渡中 minWidth 钉 400：min 提前抬高会触发系统逐帧钳制（见 sidebarTransition 注释）
            .frame(minWidth: env.sidebarPinned && sidebarTransition == nil ? 620 : 400,
                   idealWidth: env.sidebarPinned ? 660 : 440)
    }
}

private struct ConversationView: View {
    @Bindable var vm: ChatViewModel
    /// 侧栏开合过渡状态（拥有者在 ChatView：根窗口约束要跟着它钉 minWidth）
    @Binding var sidebarTransition: SidebarTransition?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @FocusState private var inputFocused: Bool
    /// 窗口高度自适应状态机（峰值/冻结/贴边停手等，见 WindowGeometryModel）
    @State private var geometry = WindowGeometryModel()
    /// 取词讲解浮层（划词触发，原型；卡片 = 独立 NSPanel，见 LookupPanelController）
    @State private var lookup = LookupViewModel()
    /// 根视图实测尺寸（触发按钮 x 钳位用；不在 ScrollView 内，onGeometryChange 可靠）
    @State private var rootSize: CGSize = .zero
    /// 控件行容器锚点（模式下拉面板定位基准：右缘 × 行顶，@State 保证跨渲染同一实例）
    @State private var controlsRowAnchor = AnchorBox()

    /// 输入卡片单行⇄两层弹性布局开关（1:1 参考：单行时控件与文本同排，折行才沉底）。
    /// 只在事件回调（onChange）里由 remeasureInputLayout 写入——布局只读。
    /// 绝不能在布局阶段（onGeometryChange 等）写它：布局中写状态 → 新事务 → 再布局，
    /// 实测形成 100% CPU 反馈环
    @State private var inputIsMultiline = false
    /// 单行态右侧控件簇预留宽（模式下拉 ~86 + 发送 ~24 + 间距，实测估算）
    private static let inputControlsReserve: CGFloat = 122
    /// 多行态底部腾给控件行的高度（控件 ~26 + 底距 10 + 与文本间隔 4）
    private static let controlsBlockHeight: CGFloat = 40
    private static func singleRowTextWidth(from fullWidth: CGFloat) -> CGFloat {
        fullWidth - inputControlsReserve
    }

    /// 折行测量：onChange 事件里同步算（Inter 14、单行态宽度），结果写 inputIsMultiline。
    /// boundingRect 与 TextField 真实排版有内边距差，宽度减 8pt 余量——宁早翻不晚翻
    private func remeasureInputLayout() {
        let text = vm.input.isEmpty ? " " : vm.input + " "  // 尾随空格让末尾换行也占行
        let font = NSFont(name: "Inter", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let width = max(120, Self.singleRowTextWidth(from: inputTextWidth) - 8)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        // Inter 14 单行 ≈ 17–18pt，阈值留足余量
        let multiline = rect.height > 22
        if multiline != inputIsMultiline { inputIsMultiline = multiline }
    }

    /// transcript 底部渐隐门控：视口底缘之外还有内容就渐隐（short > 1pt，亚像素余量）。
    /// 与回底胶囊的 120pt 阈值解耦——输入栏生长吃掉视口一截时，被遮的末行靠渐隐软化
    /// （参考图行为：不重新贴底、文字位置不动）；真正滚到贴底（short ≈ 0）时关闭
    private var transcriptFadeEnabled: Bool {
        scrollMetrics.contentHeight - (scrollMetrics.offset + scrollMetrics.viewportHeight) > 1
    }

    /// transcript 顶部渐隐门控：视口顶缘之上还有内容就渐隐（对称底部语义，贴顶不渐隐）。
    /// 内容不足一屏时 offset ≈ 0，与底部同时关闭——不会出现无意义的雾
    private var transcriptTopFadeEnabled: Bool {
        scrollMetrics.offset > 1
    }

    /// 输入文字区的显式宽度（卡片实测宽 − 文字左右内边距 24）。
    /// TextField(axis:.vertical) 的宽度必须显式给死才折行——协商宽度
    /// （maxWidth/idealWidth 各种组合实测全部失败）下排版引擎拿不到
    /// 权威宽度上限，永远单行横滚（探针逐级复现）
    @State private var inputTextWidth: CGFloat = 356
    /// 实时滚动状态（刻度轨 + 回底胶囊的数据源，ScrollMetricsProbe 采集）
    @State private var scrollMetrics = ScrollMetrics()

    // MARK: 会话侧栏（header 按钮开合，状态持久化；展开 = 常驻 220pt 占布局）

    /// 窗口宽度动画时长的保守上限（系统默认 ~0.2s）；落终态定时比动画略晚，
    /// 过渡末帧与终态布局逐点一致，晚落安全、早落才会跳
    private static let sidebarAnimationDuration: TimeInterval = 0.25

    /// 布局层的槽位显隐：跟随 pinned；收起过渡中 pinned 已翻 false，槽位靠过渡状态续命
    private var sidebarSlotVisible: Bool {
        env.sidebarPinned || sidebarTransition?.collapsing == true
    }

    /// 搜索词放这层：侧栏视图重建时词不丢
    @State private var sidebarSearch = ""
    /// 所在窗口（侧栏开合的宽度动画用；WindowReader 入窗回调解析）
    @State private var hostWindow: NSWindow?

    var body: some View {
        // 根布局：展开时侧栏常驻占布局 + 分隔线；收起时聊天列独占。
        // 过渡中（开合动画的 0.25s）：槽位弹性宽吸收全部宽度变化，聊天列钉死当前宽
        HStack(spacing: 0) {
            if sidebarSlotVisible {
                sidebarView
                    // 过渡槽位：槽宽弹性（minWidth 0），220 宽的侧栏内容尾对齐（贴聊天列），
                    // 窗口边吃掉/露出的部分裁掉——屏幕上侧栏原地不动，窗口边从它上面滑过；
                    // 非过渡 = 固定 220（与原布局一致）
                    .frame(minWidth: 0,
                           maxWidth: sidebarTransition != nil ? .infinity : SidebarLayout.width,
                           alignment: .trailing)
                    .clipped()
                // 过渡中不画分隔线：它是 1pt 刚体，会把内容最小宽顶过目标窗口宽 1pt，
                // 收起动画的终点 frame 被 contentMinSize 钳住
                if sidebarTransition == nil { Divider() }
            }
            chatColumn
                // 过渡中钉死当前宽（nil = 柔性，非过渡无效果）：正文零重排的关键
                .frame(width: sidebarTransition?.chatWidth)
        }
        // 隐藏红绿灯 + 窗口高度引擎：
        // - 每次渲染后（updateNSView）把窗口内容高对齐到期望值
        //   （SwiftUI 的 idealHeight 只在建窗时生效，增长/收缩必须主动驱动）
        // - 用户拖拽用 live-resize 通知精确识别，拖拽结束即冻结（R9b）
        .background(WindowConfigurator(
            expectedHeight: { geometry.expectedWindowHeight },
            onUserResize: { windowContentHeight in
                geometry.noteUserResize(windowContentHeight: windowContentHeight)
            },
            interceptsKeys: { inputFocused },
            onReturnKey: {
                // 不在此挡 canSend：录音中 input 可能还是空的，send() 内部先收麦落字再判断
                Task { await vm.send() }
            },
            onHistoryRecall: { older in vm.recallHistory(older: older) },
            onWindowResize: { contentWidth in
                // 窗口实际内容宽度 → noteInputWidth（其内部减 56 = 卡片外边距 20 + 文字内边距 36）。
                // 与 GeometryReader 上报的 geo 宽同义（background 在卡片 padding 外侧），直接传，
                // 不要再加偏移——加回去会把 inputTextWidth 撑大，正好吃掉两侧边距（实测）。
                // 上报的是整窗宽，展开时先扣掉侧栏宽再喂（否则折行宽度被撑破）。
                // 过渡中冻结：聊天列已钉死宽度、无需跟随；且 pinned 已先行翻转，
                // chatColumnWidth 的 pinned 语义与过渡槽位布局对不上
                guard sidebarTransition == nil else { return }
                noteInputWidth(SidebarLayout.chatColumnWidth(windowContentWidth: contentWidth,
                                                             pinned: env.sidebarPinned))
            }
        ))
        // 侧栏开合的窗口宽度动画目标解析；持久化的展开态在入窗时补一次宽度还原
        .background(WindowReader { view in
            hostWindow = view.window
            // defaultSize 按收起态开 440 宽；上次退出时是展开态 → 入窗补扩到展开宽
            if env.sidebarPinned, let win = view.window, win.frame.width < 600,
               let screen = win.screen {
                win.setFrame(SidebarLayout.targetFrame(current: win.frame, pinning: true,
                                                       visibleFrame: screen.visibleFrame),
                             display: true)
            }
        })
        // QQ 式贴边隐藏：拖到屏幕边缘（上/左/右）松手吸出去，光标碰该边缘滑出
        .background(EdgeHideInstaller { state in
            if case .hidden = state { geometry.edgeHidden = true } else { geometry.edgeHidden = false }
        })
        // Cmd+N 新对话：挂在常驻视图树上才始终生效——侧栏收起时 ✎ 按钮不在树里
        // （if env.sidebarPinned），shortcut 挂它身上会跟着失效。hidden 不移出树，快捷键照收
        .background(
            Button(action: vm.startNewSession) { EmptyView() }
                .keyboardShortcut("n")
                .hidden()
        )
        // hiddenTitleBar 下不显示，但窗口标题仍用于 Mission Control / 窗口菜单
        .navigationTitle(vm.activeSession?.displayTitle(fallback: env.t(.newChat)) ?? env.t(.defaultChatTitle))
        .onAppear {
            vm.openConversation()
            inputFocused = true
        }
        .onDisappear {
            // 关窗 = 本场结束：后台静默生成/更新总结（菜单栏 app 不退出，任务照跑完）。
            // 同时释放窗口局部资源，避免朗读和取词监听/面板跨窗口生命周期残留。
            env.speech.stop()
            lookup.dispose()
            Task { await vm.summarizeActiveSessionIfNeeded() }
        }
        .onPreferenceChange(HeaderHeightKey.self) { geometry.headerHeight = $0 }
        .onPreferenceChange(InputBarHeightKey.self) { geometry.inputBarHeight = $0 }
        // R8c/R9b 的复位时机：切换/新开会话 → 允许窗口重新自适应（含收缩）
        .onChange(of: vm.activeSessionID) {
            geometry.resetForSessionSwitch()
        }
        .coordinateSpace(name: "chatRoot")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { rootSize = $0 }
        // 根环境字体 = Inter 14：未显式指定字体的文字（消息正文/引用块）全部继承
        .font(.eaFont(14))
        // 取词讲解（原型）：划词浮「讲解」按钮 → 点击出独立面板卡片；
        // 卡片的显隐/放置/点外关闭全在 LookupPanelController，视图层只管触发按钮
        .onAppear {
            lookup.attach(env: env)
            lookup.installSelectionMonitor()
        }
        // 划词触发按钮：松鼠标选中文字后浮在选区下方，点击出卡片。定位用 padding 不用
        // .offset——offset 只移渲染，macOS 滚轮/部分命中按布局位置（卡片同款坑）
        .overlay(alignment: .topLeading) {
            if lookup.isButtonPresented {
                Button {
                    lookup.performLookup(llm: env.llm, turns: vm.activeSession?.turns ?? [])
                } label: {
                    Label(env.t(.lookupExplain), systemImage: "character.book.closed")
                        .font(.eaFont(12, .body, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.leading, lookupButtonOrigin.x)
                .padding(.top, lookupButtonOrigin.y)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: lookup.isButtonPresented)
        // 放最外层：整个视图树（含 overlay 里的面板）共享同一无安全区坐标系，
        // 否则 header 突破了安全区而 panel 没有，顶部错开约 28pt
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 聊天列：原单列布局原样抽成一根列（header/transcript/错误横幅/输入栏），
    /// pinned 时与侧栏并排，未 pinned 时独占窗口
    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            transcript
            // 错误/引导横幅：占布局空间（不用 overlay——半透明浮层盖输入栏重影的教训），
            // transcript 是 idealHeight 柔性吸收这部分高度，窗口高度公式不动
            if let error = vm.error {
                ErrorBanner(error: error) { vm.error = nil }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            inputBar
        }
    }

    /// 常驻会话侧栏
    private var sidebarView: some View {
        SessionSidebarView(vm: vm, searchText: $sidebarSearch)
    }

    /// 侧栏开合：窗口向左（贴左缘放不下则向右）扩/收一个侧栏宽，聊天列视觉不动。
    /// 贴边隐藏中禁动宽度——会污染 EdgeHideController 的 storedFrame（滑出目标）
    private func toggleSidebar() {
        guard !geometry.edgeHidden, let win = hostWindow, let screen = win.screen,
              sidebarTransition == nil else { return }   // 过渡中的重入直接吞掉（0.25s）
        let collapsing = env.sidebarPinned
        let target = SidebarLayout.targetFrame(current: win.frame, pinning: !collapsing,
                                               visibleFrame: screen.visibleFrame)
        // 方案 1 过渡槽位：pinned 立即翻转（窗口约束同步走），布局终态等动画跑完再落。
        // 聊天列钉死当前宽（chatColumnWidth 复用同一套几何），槽位吸收全部宽度变化
        sidebarTransition = SidebarTransition(
            chatWidth: SidebarLayout.chatColumnWidth(windowContentWidth: win.contentLayoutRect.width,
                                                     pinned: collapsing),
            collapsing: collapsing)
        env.sidebarPinned.toggle()
        win.setFrame(target, display: true, animate: true)
        // 落终态用定时而非动画回调：窗口 frame 动画可能被高度引擎的 setFrame 顶掉，
        // 回调时机不可靠；定时比动画略晚，端点布局一致所以不可见
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarAnimationDuration + 0.05) {
            sidebarTransition = nil
        }
    }

    /// 自绘 header 1:1：[☰ 侧栏] [会话标题] … [× 关闭]（头像→设置入口暂下线，见下方注释）
    /// 整行挂 WindowDragGesture，可拖拽移动窗口
    private var header: some View {
        HStack(spacing: 14) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.eaFont(13, .body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(geometry.edgeHidden)
            .help(env.t(.toggleSidebar))

            Text(vm.activeSession?.displayTitle(fallback: env.t(.newChat)) ?? env.t(.defaultChatTitle))
                .font(.eaFont(13, .headline, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()

            // 头像入口暂时下线：系统用户名不可控（中文系统全名直拼），后续产品上
            // 用户档案/昵称后再恢复——avatarInitial 保留待用。
            // 设置入口不受影响：输入卡片右侧模型名按钮、菜单栏右键菜单均可达。
            // Button {
            //     ActivationHelper.open(id: SceneID.settings, using: openWindow)
            // } label: {
            //     Text(Self.avatarInitial)
            //         .font(.eaFont(10, .caption, weight: .semibold))
            //         .foregroundStyle(.white)
            //         .frame(width: 24, height: 24)
            //         .background(Color.brown, in: Circle())
            // }
            // .buttonStyle(.plain)
            // .help(env.t(.helpSettings))

            Button {
                NSApp.keyWindow?.performClose(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.eaFont(13, .body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(env.t(.helpClose))
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        // 实测高度上报：参与窗口高度公式（header + transcript + inputBar）
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
            }
        )
    }

    /// 头像字母：取本机用户名首字符，兜底「我」
    private static var avatarInitial: String {
        String(NSFullUserName().prefix(1)).uppercased().isEmpty
            ? "我" : String(NSFullUserName().prefix(1)).uppercased()
    }

    private var transcript: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 13) {
                        // 空态（无用户发言）：问候块 + 建议胶囊，1:1 参考 Claude 欢迎页
                        if vm.userTurnCount == 0 {
                            WelcomeView(vm: vm)
                        }
                        if let session = vm.activeSession {
                            ForEach(session.turns) { turn in
                                TurnView(turn: turn)
                                    .id(turn.id)
                            }
                        }
                        if vm.streamingText != nil {
                            AssistantBody(text: vm.streamingText ?? "")
                                .id(Self.streamingID)
                                .opacity(0.75)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    // 宽窗时内容列限宽居中（ Claude 桌面版同款处理）
                    .frame(maxWidth: 560)
                    // 内容高度上报（须在 minHeight 之前测，否则测到的是视口高）。
                    // 用 AppKit 探针——SwiftUI 上报全是坑（全部探针复现）：
                    // ScrollView 内 PreferenceKey 永不上报；onGeometryChange 遇 .id 重建后失聪；
                    // layout 回调里同步改 @State 会被丢弃（探针内部已异步绕开）
                    .background(ContentHeightProbe { geometry.noteContentHeight($0) })
                    // 滚动偏移/视口高上报：刻度轨 + 回底胶囊的数据源（同 AppKit 探针路线）
                    .background(ScrollMetricsProbe { scrollMetrics = $0 })
                    .frame(maxWidth: .infinity)
                    // 内容不足一屏时底部锚定：对话贴着输入框向上生长（1:1 参考 Claude），
                    // 空洞沉到 header 之下；内容超一屏后的贴底由显式滚动路径管理
                    // （流式/收尾/回底胶囊/会话切换——钉底已摘，见下方说明）
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                // 窗口高度自适应的核心：ScrollView 理想高度 = 内容峰值（保底 680 −
                // chrome，封顶 900 − chrome）；
                // 用户手动拖过窗则锁死冻结值（R9b），根视图无 maxHeight 故拖拽不受限（R3）
                .frame(idealHeight: geometry.idealTranscriptHeight)
                // 高度引擎 setFrame 换算有亚像素 ε，视口可能比内容矮零点几 pt；
                // 系统「始终显示滚动条」下会常驻一条灰轨（参考图无此物）——隐藏指示器
                .scrollIndicators(.hidden)
                // 钉底已摘（原 defaultScrollAnchor(.bottom)）：钉底在视口缩短时自动调
                // offset 保持底缘钉住——输入折行 → 视口缩 → 整屏内容上移（实测根因，
                // 且只在精确锚点触发，时隐时现）。贴底时机全部改显式管理：
                // 流式（下方 onChange）、流结束收尾、回底胶囊、会话切换初始定位（下方
                // onChange）。折行/窗口变化不再有任何人碰 offset——内容静止，
                // 被遮末行渐隐软化，想看的用户滚出来（视口缩 1pt 滚动行程 +1pt，天然）
                // 上下双边渐隐（底部 1:1 参考图，顶部对称）：回看历史时内容滚向输入栏/
                // header 淡出融进背景，替代分割线做分层，同时软化视口裁剪的硬边。贴底/贴顶
                // 不渐隐（门控见 transcriptFadeEnabled / transcriptTopFadeEnabled）。mask 只
                // 影响渲染，滚动/选中不受影响。必须放在下方 overlay（刻度轨/回底胶囊）之前，
                // 否则浮层会一起被淡出
                .mask(TranscriptFadeMask(topEnabled: transcriptTopFadeEnabled,
                                         bottomEnabled: transcriptFadeEnabled))
                // 渐隐带收起/长出要过渡：enabled 翻转是 0↔44pt 的 mask 突变，直切会闪现
                // （只罩 mask 这一节，后续 overlay 在动画作用域之外）
                .animation(.easeOut(duration: 0.2), value: transcriptFadeEnabled)
                .animation(.easeOut(duration: 0.2), value: transcriptTopFadeEnabled)
                .onChange(of: vm.streamingText?.count ?? -1) {
                    // 流式跟随：无动画直跳——逐 flush 的 withAnimation 滚动是纯开销。
                    // 发送消息也被这条覆盖：send 同步置 streamingText=""，nil→0 触发本回调
                    if vm.streamingText != nil {
                        proxy.scrollTo(Self.streamingID, anchor: .bottom)
                        return
                    }
                    // 流结束收尾贴底：换位后 streamingID 已不存在（scrollTo 它是 no-op）。
                    // 走 AppKit 直滚（见 scrollTranscriptToBottom）——proxy.scrollTo 依赖
                    // SwiftUI 解析 id 并 realize 目标单元格，长会话尾部单元格未 realize 时
                    // 会静默落空（间歇失效的实测根因）；scrollToPoint 只认 documentView
                    // 高度，无此前提。回读重贴覆盖 documentView 高度尚未刷新的时序窗口
                    DispatchQueue.main.async {
                        Self.scrollTranscriptToBottom()
                    }
                    for delay in [0.15, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard vm.streamingText == nil,
                                  let m = ScrollMetricsProbe.ProbeView.liveMetrics(),
                                  m.contentHeight > m.viewportHeight else { return }
                            let short = m.contentHeight - (m.offset + m.viewportHeight)
                            guard short > 24 else { return }   // 正常贴底后 short≈14（底部 padding）
                            Self.scrollTranscriptToBottom()
                        }
                    }
                }
                // 会话切换/开窗初始贴底（钉底摘除后初始定位改显式）：文档高度异步就位，
                // 延迟重贴覆盖时序窗口（流结束收尾同款防御）。scrollTranscriptToBottom
                // 自身有 >1pt 门控，内容不足一屏/已贴底时是 no-op
                .onChange(of: vm.activeSessionID) {
                    DispatchQueue.main.async { Self.scrollTranscriptToBottom() }
                    for delay in [0.15, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            Self.scrollTranscriptToBottom()
                        }
                    }
                }
                // 输入卡片换行/收起会改变 transcript 的视口高度（窗口按「保底 680」不变，
                // 差额由 transcript 吸收）。此处【不要】补重新贴底——参考 App 的行为是
                // 视口收缩、滚动偏移不动：文字位置保持，被遮的底部交给渐隐软化（本文件
                // transcriptFadeEnabled）。历史上这里做过 nearBottom 补贴底（commit 13ae7f8
                // 修「末行被输入卡片压住」），结果是输入栏一翻折整屏文字上跳，已按 1:1
                // 参考移除；defaultScrollAnchor 的隐式钉底同样摘了（同根因）
                // 左缘刻度轨（回看导航；设计冻结记录见 ChatNavigation 头注释）
                .overlay(alignment: .leading) {
                    if railVisible, let session = vm.activeSession {
                        TickRailView(turns: session.turns,
                                     streaming: vm.streamingText != nil,
                                     metrics: scrollMetrics) { r in
                            let rounds = ChatNavigation.pairRounds(session.turns)
                            guard rounds.indices.contains(r) else { return }
                            withAnimation {
                                proxy.scrollTo(session.turns[rounds[r].userIndex].id, anchor: .top)
                            }
                        }
                        .frame(width: 44)
                        .transition(.opacity)
                    }
                }
                // 回底胶囊：滚离底部超过阈值出现（ScrollMetrics.nearBottom，120pt）
                .overlay(alignment: .bottom) {
                    BackToBottomButton(show: !scrollMetrics.nearBottom
                                       && scrollMetrics.contentHeight > scrollMetrics.viewportHeight) {
                        if vm.streamingText != nil {
                            proxy.scrollTo(Self.streamingID, anchor: .bottom)
                        } else {
                            // 非流式同走 AppKit 直滚：尾部单元格未 realize 时
                            // proxy.scrollTo(last.id) 会静默落空
                            Self.scrollTranscriptToBottom()
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// 刻度轨显隐：≥2 轮且内容超一屏（不足一屏没有回看导航的需求）
    private var railVisible: Bool {
        guard let session = vm.activeSession else { return false }
        return ChatNavigation.pairRounds(session.turns).count >= 2
            && scrollMetrics.contentHeight > scrollMetrics.viewportHeight + 4
    }

    /// 触发按钮位置：选区下方 6pt，与卡片同一套钳位/翻转（尺寸按估算，小按钮偏差无害）
    private var lookupButtonOrigin: CGPoint {
        let buttonSize = CGSize(width: 76, height: 30)
        guard lookup.buttonAnchor != .zero else {
            return CGPoint(x: 24, y: geometry.headerHeight + 8)
        }
        let x = min(max(8, lookup.buttonAnchor.minX), max(8, rootSize.width - buttonSize.width - 8))
        let below = lookup.buttonAnchor.maxY + 6
        let fitsBelow = below + buttonSize.height <= rootSize.height - 8
        let rawY = fitsBelow ? below : max(geometry.headerHeight + 8, lookup.buttonAnchor.minY - 6 - buttonSize.height)
        // 与卡片同款保险：锚点出界（选区被滚出屏）时钳回窗口内
        let minY = geometry.headerHeight + 8
        let maxY = max(minY, rootSize.height - 8 - buttonSize.height)
        let y = min(max(rawY, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    /// 把 transcript 直滚到真实底部（AppKit 路径）：offset = 内容高 − 视口高。
    /// 不依赖 proxy.scrollTo 的 id 解析/单元格 realize，只认 documentView 实测高度
    private static func scrollTranscriptToBottom() {
        guard let sv = ScrollMetricsProbe.ProbeView.liveScrollView,
              let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        guard abs(sv.contentView.bounds.origin.y - maxY) > 1 else { return }
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: maxY))
        sv.reflectScrolledClipView(sv.contentView)
    }

    static let streamingID = "streaming"

    /// 输入卡片（1:1 参考图的弹性结构，身份稳定版）：单行 = 文本一行、控件浮在同排
    /// 右缘；折行 = 文本向上生长、底部 padding 腾出控件行。控件常驻 bottomTrailing
    /// overlay，TextField 全程同一身份——绝不做 if/else 分支切换：分支翻转会销毁重建
    /// TextField，丢焦点 → 异步补焦 → 新建 field 程序化聚焦默认【全选】→ 继续输入
    /// 吞掉全文（实测事故链）。翻折只改 padding，焦点/选区不动
    private var inputBar: some View {
        inputField(width: inputTextWidth)
            .padding(.horizontal, 18)
            .padding(.top, 15)
            // 单行态底 15（整卡 ~50pt，控件落在同一排）；多行态底 40 腾出控件行。
            // 文本测量始终按单行态窄宽（singleRowTextWidth），翻折发生在文字到达
            // 控件区之前，所以单行态下全宽文本区也不会与控件重叠
            .padding(.bottom, inputIsMultiline ? Self.controlsBlockHeight : 15)
            .overlay(alignment: .bottomTrailing) {
                // 必须显式 HStack：inputControls 是两个顶层视图，单视图上下文里
                // SwiftUI 隐式按 ZStack 叠放（发送钮压模式下拉的实测根因）
                HStack(spacing: 6) {
                    inputControls
                }
                // 控件行锚点：面板右缘 = 发送钮右缘、底缘 = 行顶 + 缝隙（参考对齐）
                .background(AnchorCapture(box: controlsRowAnchor))
                .padding(.trailing, 8)
                .padding(.bottom, 11)
            }
            .animation(.easeOut(duration: 0.15), value: inputIsMultiline)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        // 分层靠软阴影（参考图无描边）；发丝描边仅兜底深色模式（深底上阴影不可见）
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: InputBarHeightKey.self, value: geo.size.height)
                    .onAppear { noteInputWidth(geo.size.width) }
                    .onChange(of: geo.size.width) { noteInputWidth(geo.size.width) }
            }
        )
        .onChange(of: vm.input) { remeasureInputLayout() }
        .onChange(of: inputTextWidth) { remeasureInputLayout() }
    }

    /// 文本区（单行/两层两种布局共用）；宽度必须显式给死才折行（见 inputTextWidth 头注释）
    private func inputField(width: CGFloat) -> some View {
        TextField(vm.activeMode.placeholder, text: $vm.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.eaFont(14))
            .lineLimit(1...4)
            .frame(width: max(120, width), alignment: .leading)
            .id(Int(width / 20))
            .focused($inputFocused)
    }

    /// 右侧控件簇：模式下拉（写回当前会话持久化，下一条消息生效）+ 发送
    @ViewBuilder private var inputControls: some View {
        ModeMenuControl(selection: vm.activeMode, rowAnchor: controlsRowAnchor) { vm.setMode($0) }

        Button {
            Task { await vm.send() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.eaFont(22, .title2))
                .foregroundStyle(vm.canSend ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.borderless)
        .disabled(!vm.canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(env.t(.helpSend))
    }

    private func noteInputWidth(_ cardWidth: CGFloat) {
        guard cardWidth > 200, cardWidth < 2000 else { return }
        // 卡片宽 − 卡片外边距 20 − 文字左右内边距 36 = 文本区宽
        let w = cardWidth - 56
        if abs(w - inputTextWidth) > 0.5 { inputTextWidth = w }
    }
}

/// transcript 上下渐隐 mask：顶/底固定高渐变 + 中段全黑（不透渐隐）。
/// 用 VStack 拼装而不用 LinearGradient 的 stop 比例——stop 是相对值，
/// 视口拉高时渐隐带会被等比拉长（参考图是固定 2–3 行的淡入背景）。
/// 两条门控各自独立（topEnabled / bottomEnabled）：贴顶/贴底不渐隐，
/// 停在中间时双边同显（「上下都还有历史」的视觉提示）
private struct TranscriptFadeMask: View {
    let topEnabled: Bool
    let bottomEnabled: Bool

    /// 渐隐带高度（pt），约 2–3 行文字；视觉微调改这里
    static let fadeHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: topEnabled ? Self.fadeHeight : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottomEnabled ? Self.fadeHeight : 0)
        }
    }
}

/// 空态问候块 + 建议胶囊（1:1 参考）：胶囊点击 = 以用户身份发送该句，直接开聊
private struct WelcomeView: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 单句问候：不用系统用户名（不可控、中文系统是全名直拼），
            // 陪练口吻取代助手口吻；这句英文本身就是空态的每日示范，须语法正确
            Text("What would you like to chat about today?")
                .font(.eaFont(16, .title2, weight: .bold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 10) {
                // 动态胶囊：复习错句 / 续聊话题从最近会话总结长出，兜底池按日轮换
                ForEach(StarterSuggestions.make(sessions: vm.sessions), id: \.self) { starter in
                    Button {
                        vm.input = starter
                        Task { await vm.send() }
                    } label: {
                        // 宽条圆角矩形（1:1 参考），非全圆角 Capsule
                        Text(starter)
                            .font(.eaFont(12, .callout))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// 视图锚点捕获：把 SwiftUI 视图背后的 NSView 暴露给 AppKit 弹层做组件级定位
/// （frame 换算自真实视图，不靠鼠标位置 ± 魔数）
private final class AnchorBox {
    weak var view: NSView?
}

private struct AnchorCapture: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// 模式面板内的活选择态：行观察它渲染对勾。onPick 先写它——对勾在面板还开着时
/// 即时跳到点中项（原生下拉的反馈语义），而不是靠「关了再开」换快照
@Observable private final class ModeMenuSelection {
    var current: ChatMode
    init(_ current: ChatMode) { self.current = current }
}

/// 富文本模式下拉（1:1 参考图：菜单项 = 模式名 + 一句话副标题两行，checkmark 在行尾）。
/// 按钮本体；面板由 ModeMenuController 承载。
/// 不用 SwiftUI Menu（macOS 上自定义 item label 被桥接压平）也不用 NSMenu + 自定义
/// item view（模态跟踪循环与 SwiftUI 手势/重绘四层冲突，五连 bug 实测）——
/// 走 LookupPanelController 同款：borderless NSPanel + 纯 SwiftUI 内容，正常 runloop
private struct ModeMenuControl: View {
    let selection: ChatMode
    /// 控件行容器锚点：面板右缘对齐行右缘（发送钮右缘）、底缘贴行顶——
    /// 锚定角 = 控件区右下角，面板从该角向上向左展开（参考对齐）
    let rowAnchor: AnchorBox
    let onSelect: (ChatMode) -> Void

    var body: some View {
        Button {
            ModeMenuController.shared.toggle(selection: selection,
                                             anchor: rowAnchor.view,
                                             onSelect: onSelect)
        } label: {
            HStack(spacing: 3) {
                Text(selection.label)
                    .font(.eaFont(13, .callout))
                Image(systemName: "chevron.down")
                    .font(.eaFont(11, .caption))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(selection.help)
    }
}

/// 模式面板：borderless NSPanel + 纯 SwiftUI 卡片。结构照抄 LookupPanelController
/// （非激活、popUpMenu 层级、点外/Esc/失焦/宿主窗动即关）。每次 show 新建面板，
/// dismiss 断开 contentView，无跨生命周期状态
@MainActor
private final class ModeMenuController: NSObject {
    static let shared = ModeMenuController()

    private var panel: NSPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    private static let width: CGFloat = 226
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 2
    private static let cardPadding: CGFloat = 8
    /// 面板下缘与控件行顶的缝隙（参考对齐）
    private static let gap: CGFloat = 6

    private static var height: CGFloat {
        let n = CGFloat(ChatMode.allCases.count)
        return n * rowHeight + (n - 1) * rowSpacing + cardPadding * 2
    }

    func toggle(selection: ChatMode, anchor: NSView?, onSelect: @escaping (ChatMode) -> Void) {
        if panel != nil { dismiss(); return }
        show(selection: selection, anchor: anchor, onSelect: onSelect)
    }

    private func show(selection: ChatMode, anchor: NSView?,
                      onSelect: @escaping (ChatMode) -> Void) {
        guard let anchor, let hostWindow = anchor.window else { return }
        // 面板级活选择态：点击先写它（对勾即时跳，正常 runloop 下 SwiftUI 原生响应式），
        // 再真实切换，留 0.2s 节拍后关面板——原生下拉的反馈语义
        let box = ModeMenuSelection(selection)
        let card = ModeMenuCard(selection: box) { [weak self] mode in
            box.current = mode
            onSelect(mode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        let panel = makePanel(content: card)
        // 组件级定位：面板右缘 = 控件行右缘（发送钮右缘），面板下缘 = 行顶 + 缝隙——
        // 锚定角 = 控件区右下角，面板从该角向上向左展开。convert(to: nil) → 窗口坐标，
        // convertToScreen → 屏幕 Cocoa 坐标（左下原点）
        let anchorRect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (hostWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let x = min(max(visible.minX + 4, anchorRect.maxX - Self.width),
                    max(visible.minX + 4, visible.maxX - 4 - Self.width))
        let final = NSRect(x: x, y: anchorRect.maxY + Self.gap,
                           width: Self.width, height: Self.height)
        // borderless 面板 frame == content（无标题栏 inset/clamp，实测 titled 样式会被
        // 最小外框高钳制、内容下推 32pt 盖住控件行），final 即卡片最终落位
        // 出场 = popover 式 scale-from-corner：窗口级淡入（阴影同步），
        // 内容层 0.92→1 缩放在 ModeMenuCard 内以 bottomTrailing 为锚点进行。
        // 窗口无 transform 动画 API，8% 幅度下内容缩放与窗口阴影的差异不可感知
        panel.alphaValue = 0
        panel.setFrame(final, display: false)
        self.panel = panel
        startMonitors()
        startObservers(hostWindow: hostWindow)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        stopMonitors()
        stopObservers()
        // 淡出后 orderOut（先摘监控/观察者，动画期间再有点外事件也不会重入）
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

    private func makePanel(content: ModeMenuCard) -> NSPanel {
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
            // borderless：frame == content，卡片落位像素级精确（下拉不需要标题栏/拖拽缩放，
            // 圆角由卡片自绘 cornerRadius、阴影由 hasShadow 按内容透明度成型）
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let hosting = NSHostingView(rootView: content)
        // 数据流单向：卡片填满面板，尺寸不回馈（LookupPanel 防布局循环同款处置）
        hosting.sizingOptions = []
        p.contentView = hosting
        return p
    }

    private func startMonitors() {
        // 点面板外（含主窗）→ 关，事件放行；本地管 app 内，全局管其他 app
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window !== panel else { return }
                self.dismiss()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.dismiss() }
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

    private func startObservers(hostWindow: NSWindow) {
        let center = NotificationCenter.default
        // 菜单语义是瞬态：宿主窗移动/缩放/关闭 → 关（不像 LookupPanel 跟随重排）
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: hostWindow, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func stopObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

/// 面板卡片：模式行列表 + 材质底 + 发丝描边（LookupCard 同款皮肤）
private struct ModeMenuCard: View {
    let selection: ModeMenuSelection
    let onPick: (ChatMode) -> Void
    /// 出场 scale 驱动：false = 缩在右下角（0.92），onAppear 弹到 1——
    /// 锚点 bottomTrailing 即面板定位锚角（控件区右下角），popover 式弹出
    @State private var popped = false

    var body: some View {
        VStack(spacing: 2) {
            ForEach(ChatMode.allCases) { mode in
                ModeMenuItemRow(mode: mode, selection: selection) { onPick(mode) }
                    .frame(height: 38)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        .scaleEffect(popped ? 1 : 0.92, anchor: .bottomTrailing)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { popped = true }
        }
    }
}

/// 菜单项行：模式名 + 副标题两行，行尾 checkmark（观察活选择态，点中即跳）。
/// view-based NSMenuItem 的系统高亮不画背景、action 不自动派发——悬停态与点击都自理
private struct ModeMenuItemRow: View {
    let mode: ChatMode
    let selection: ModeMenuSelection
    let onPick: () -> Void
    @State private var hovering = false

    private var isSelected: Bool { selection.current == mode }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.label)
                    .font(.eaFont(12))
                Text(mode.subtitle)
                    .font(.eaFont(10, .caption))
                    .foregroundStyle(hovering ? Color.white.opacity(0.75) : .secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.eaFont(11, .body, weight: .semibold))
            }
        }
        .foregroundStyle(hovering ? Color.white : .primary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(hovering ? Color.accentColor : .clear)
        .contentShape(.rect)
        .onTapGesture { onPick() }
        .onHover { hovering = $0 }
    }
}

/// NSEvent is non-Sendable, while local AppKit monitors are documented to run on the main thread.
/// The unchecked box makes that runtime assumption explicit at the isolation boundary.
private struct MainThreadEventBox: @unchecked Sendable {
    let event: NSEvent
}

/// 一条发言：用户 = 右侧灰色圆角气泡；AI = 无气泡全宽正文（Claude 风格）。
/// Equatable：turn 没变时跳过——打字/流式触发的全树重渲染不再波及历史消息
/// （@State/@Environment 不参与相等判定，手动 == 只比 turn）
@MainActor
private struct TurnView: View, @MainActor Equatable {
    let turn: DialogueTurn
    @Environment(AppEnvironment.self) private var env

    static func == (l: Self, r: Self) -> Bool { l.turn == r.turn }

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 60)
                MarkdownText(turn.content)
                    .textSelection(.enabled)   // 用户消息也要能选中复制
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 480, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                AssistantBody(text: turn.content)
                if turn.deliveryStatus == .partial {
                    HStack(spacing: 8) {
                        Label(env.t(.replyInterrupted), systemImage: "exclamationmark.triangle")
                            .font(.eaFont(10, .caption))
                            .foregroundStyle(.orange)
                        Button(env.t(.continueReply)) {
                            Task { await env.chat.continuePartialTurn(turn.id) }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .disabled(env.chat.streamingText != nil)
                    }
                }
            }
        }
    }
}

/// AI 正文：全宽、块级 markdown、可选择复制
private struct AssistantBody: View, Equatable {
    let text: String

    var body: some View {
        MarkdownBlocksView(text: text)
            .textSelection(.enabled)
            .padding(.horizontal, 2)
    }
}

// MARK: - 共用小组件

/// 内容高度探针（AppKit 兜底）：作为 background 挂在 LazyVStack 上，
/// frame.height 即内容实测高。layout 覆盖尺寸变化；updateNSView 覆盖重渲染
/// （同高切换会话等「尺寸没变」场景也刷出读数）。
/// 关键：layout/updateNSView 都在 SwiftUI 渲染管线内，同步改 @State 会被丢弃（实测），
/// 必须异步派发上报。
private struct ContentHeightProbe: NSViewRepresentable {
    let onHeight: (CGFloat) -> Void

    final class ProbeView: NSView {
        var onHeight: ((CGFloat) -> Void)?
        /// 上次上报值：测量装置不重复报数——同值重复上报在 @Observable 模型层
        /// 会触发布局失效自激（实测 99% CPU 卡死）；源头去重，与上层存储语义解耦
        private var lastReported: CGFloat = -1

        override func layout() {
            super.layout()
            report()
        }
        func report() {
            guard window != nil else { return }
            let h = frame.height
            guard h != lastReported else { return }
            lastReported = h
            let callback = onHeight
            DispatchQueue.main.async { callback?(h) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onHeight = onHeight
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? ProbeView else { return }
        probe.onHeight = onHeight
        probe.report()
    }
}

/// header 实测高度上报通道（下拉面板贴底用）
private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 输入卡片高度上报通道（参与窗口高度公式：header + transcript + inputBar）
private struct InputBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 96
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension NSView {
    /// 递归收集子树里的所有 NSScrollView（SwiftUI ScrollView 的内核）
    func allScrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let sv = self as? NSScrollView { found.append(sv) }
        for sub in subviews { found.append(contentsOf: sub.allScrollViews()) }
        return found
    }
}

/// 窗口配置器：隐藏红绿灯 + 窗口高度引擎。
/// SwiftUI 的 idealHeight 只在窗口创建时生效（已实测：内容增长窗口不动），
/// 所以高度自适应要主动驱动：expectedHeight 非 nil 时把窗口内容高设为该值。
/// 用户拖拽用 live-resize 通知精确识别（willStart/didEndLiveResize 只在用户拖动时触发，
/// 程序 setFrame 不触发）——不要用 didResize+防抖+期望值比对，异步测量下必误判（实测）。
private struct WindowConfigurator: NSViewRepresentable {
    /// 当前期望的窗口内容高度；nil = 不干预（已冻结或内容未测出）
    let expectedHeight: () -> CGFloat?
    /// 用户拖拽结束：上报窗口实际内容高度
    let onUserResize: (CGFloat) -> Void
    /// 窗口级键监听是否接管当前 field editor：false = 焦点在侧栏搜索框等其他输入框，
    /// Enter/上下键原样放行（不发送聊天、不翻历史）
    let interceptsKeys: () -> Bool
    /// 输入框 plain Enter 回调（发送）。SwiftUI 的 onKeyPress 对 return 不触发（实测），
    /// 只能用本地事件监听在窗口级接管；Shift+Enter 换行也在监听里处理
    let onReturnKey: () -> Void
    /// 输入框上/下键回调（翻发言历史，终端式）；返回 true = 已消费，事件不再下发
    let onHistoryRecall: (Bool) -> Bool
    /// 窗口尺寸变化时上报内容宽度（供输入框显式宽度跟随）；
    /// GeometryReader 的 onChange 在窗口缩小时不触发（SwiftUI 认为 minWidth 内无需重排），
    /// 必须用 AppKit 通知兜底
    let onWindowResize: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // 入窗即配置 + 装配（WindowResolutionView 统一入窗回调，替代 async 赌时序）
        let view = WindowResolutionView()
        view.onWindow = { [coordinator = context.coordinator] win in
            configure(win)
            coordinator.attach(to: win)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.expectedHeight = expectedHeight
        context.coordinator.onUserResize = onUserResize
        context.coordinator.interceptsKeys = interceptsKeys
        context.coordinator.onReturnKey = onReturnKey
        context.coordinator.onHistoryRecall = onHistoryRecall
        context.coordinator.onWindowResize = onWindowResize
        guard let win = nsView.window else { return }
        configure(win)
        context.coordinator.attach(to: win)
        // updateNSView 运行在 SwiftUI 布局中途，此刻 frame 是脏的（实测 current 读到 608
        // 而真实 640）；同步 setFrame 会把脏值固化。延迟到渲染结束后用干净值对齐。
        DispatchQueue.main.async {
            context.coordinator.apply(to: win)
        }
    }

    static func dismantleNSView(_ nsView: NSView, context: Context) {
        context.coordinator.invalidate()
    }

    private func configure(_ win: NSWindow) {
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        // 窄栏设计的尺寸上限（ideal 440，宽了内容列也是居中留白）；
        // 注意这不拦系统平铺——平铺无视 contentMaxSize（实测），平铺的应对在
        // EdgeHideController 的事后回滚
        win.contentMaxSize = NSSize(width: 1200, height: 3000)
        // 系统检测到鼠标时 NSScrollView 退化成老式滚动条（常驻轨道+底色，实测截图），
        // SwiftUI 的 scrollIndicators(.hidden) 在这条路径上拦不住——
        // 直取 NSScrollView 强制 overlay 风格并关掉 scroller（幂等，每次渲染后重刷）
        for scrollView in win.contentView?.allScrollViews() ?? [] {
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
    }

    @MainActor final class Coordinator {
        var expectedHeight: (() -> CGFloat?)?
        var onUserResize: ((CGFloat) -> Void)?
        var interceptsKeys: (() -> Bool)?
        var onReturnKey: (() -> Void)?
        var onHistoryRecall: ((Bool) -> Bool)?
        var onWindowResize: ((CGFloat) -> Void)?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var keyMonitor: Any?
        private var liveResizing = false

        func attach(to win: NSWindow) {
            guard window !== win else { return }
            window = win
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willStartLiveResizeNotification,
                                   object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveResizing = true }
                },
                center.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                   object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let win = self.window else { return }
                        self.liveResizing = false
                        self.onUserResize?(win.contentLayoutRect.height)
                    }
                },
                // 窗口尺寸变化（含程序 setFrame 和用户拖拽）都上报内容宽度，
                // 供输入框显式宽度跟随——SwiftUI 布局回调在缩窗时不可靠（实测）。
                // 必须 async：通知在 setFrame 中途触发，此刻 contentLayoutRect 是脏值
                // （和高度引擎「updateNSView 同步读 frame」同一类坑），延迟到渲染结束后读干净值
                center.addObserver(forName: NSWindow.didResizeNotification,
                                   object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let win = self.window else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.onWindowResize?(win.contentLayoutRect.width)
                            }
                        }
                    }
                },
            ]
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    // Local event monitors run on AppKit's main dispatch path. Wrap the
                    // non-Sendable event explicitly instead of letting it cross actor isolation.
                    let box = MainThreadEventBox(event: event)
                    let consumed = MainActor.assumeIsolated {
                        self.handleKeyDown(box.event) == nil
                    }
                    return consumed ? nil : event
                }
            }
        }

        /// Enter / 上下键窗口级接管（在事件派发给输入框之前拦截）：
        /// plain Enter = 发送；Shift+Enter = 光标处换行（macOS shift+return 默认是
        /// 「全选」，必须拦）；上/下 = 翻发言历史（由 onHistoryRecall 决定是否消费，
        /// 不消费则还给光标移动）；IME 选词中的按键放行；其他键一律不动。
        /// 只认本窗口 + firstResponder 是 field editor（= 某个输入框聚焦中）；
        /// 侧栏搜索框等其他输入框由 interceptsKeys 放行（各键走默认行为）
        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard event.window === window,
                  let editor = window?.firstResponder as? NSTextView,
                  editor.isFieldEditor else { return event }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let isArrow = event.keyCode == 125 || event.keyCode == 126  // down / up
            guard isReturn || isArrow else { return event }
            guard interceptsKeys?() ?? true else { return event }
            // 拼音 IME 组词中（hasMarkedText）按键优先给输入法（上下键 = 翻候选页）；
            // 无组词时不能问 IME —— 实测拼音 inputContext 会无条件吞掉 Enter
            if editor.hasMarkedText(),
               let context = editor.inputContext, context.handleEvent(event) {
                return nil
            }
            if isArrow {
                let older = event.keyCode == 126
                let consumed = onHistoryRecall?(older) == true
                return consumed ? nil : event
            }
            if event.modifierFlags.contains(.shift) {
                editor.insertText("\n", replacementRange: editor.selectedRange())
            } else {
                onReturnKey?()
            }
            return nil
        }

        /// 把窗口内容高度设到期望值（顶部不动，向下伸缩）；用户拖拽中不打扰
        func apply(to win: NSWindow) {
            guard !liveResizing, !win.inLiveResize,
                  let expected = expectedHeight?() else { return }
            let current = win.contentLayoutRect.height
            guard abs(current - expected) > 1 else { return }
            var frame = win.frame
            let newHeight = win.frameRect(forContentRect: NSRect(
                origin: .zero, size: NSSize(width: current, height: expected))).height
            frame.origin.y += frame.height - newHeight
            frame.size.height = newHeight
            win.setFrame(frame, display: true)
        }

        func invalidate() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }
}
