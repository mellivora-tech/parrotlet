import SwiftUI
import AppKit

/// 设置：对齐 macOS 26 System Settings（Tahoe）——
/// 窗口 hiddenTitleBar，垂直两条通高列：左列悬浮玻璃侧栏（红绿灯托管在其顶部），
/// 右列透明工具栏（‹ › + 页标题）+ 分组卡片内容。卡片/分隔线/行解剖按真机：
/// 分隔线从文字左缘起画（图标行跳过图标列）、可进入行带 chevron、
/// 状态副标题带彩色圆点（● Connected 语法）。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var pane: Pane = .services
    @State private var search = ""
    /// 「!」说明 popover
    @State private var showInfo = false
    /// 三级页路由（真 NavigationStack 推入；栈元素即编辑草稿+新增标记）
    private struct EditRoute: Hashable {
        let config: ProviderConfig
        let isNew: Bool
    }
    @State private var path: [EditRoute] = []
    /// 前进历史（NavigationStack 只维护回退；层级只有两级，一层就够）
    @State private var forwardRoute: EditRoute?

    private var vm: SettingsViewModel { env.settings }

    /// "0.1.0 (1)"；裸二进制无 Info.plist 时退化为 —
    private static var appVersionString: String {
        guard let info = Bundle.main.infoDictionary,
              let v = info["CFBundleShortVersionString"] as? String else { return "—" }
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(build))"
    }

    /// 自绘 chrome 的少量 token（控件本体仍全原生）
    private enum DS {
        // 真机实测：窗口底纯白，卡片 #f8f8f8 浅灰（Tahoe 与白底反着来）
        static let card = Color.adaptive(light: Color(white: 0.973), dark: .white.opacity(0.065))
        static let control = Color.adaptive(light: .black.opacity(0.055), dark: .white.opacity(0.09))
        // 导航胶囊填充：真机实测 #f7f7f7（比搜索框底更浅）
        static let capsule = Color.adaptive(light: Color(white: 0.969), dark: .white.opacity(0.09))
        static let hairline = Color.adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.09))
        static let text3 = Color.adaptive(light: .black.opacity(0.34), dark: .white.opacity(0.36))
        static let green = Color(nsColor: .systemGreen)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            rightColumn
        }
        // hiddenTitleBar 的顶部安全区会把内容整体下推（红绿灯悬在空白带上），
        // 忽略后内容顶到窗口上缘——侧栏/工具栏已各自为红绿灯留位（ChatView 同款）
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 520, idealHeight: 648)
        // 外接鼠标时 NSScrollView 退化成常驻轨道滚动条（ChatView 同款坑），强制 overlay；
        // 顺带把红绿灯内移到真机位置
        .background(WindowChromeFix())
    }

    // MARK: - 侧栏（通高玻璃列）

    private enum Pane: String, CaseIterable, Identifiable {
        case general, services, about
        var id: String { rawValue }
        var key: L10n.Key {
            switch self { case .general: .paneGeneral; case .services: .paneServices; case .about: .paneAbout }
        }
        var icon: String {
            switch self { case .general: "gearshape"; case .services: "globe"; case .about: "info.circle" }
        }
        var tint: Color {
            switch self { case .general: .gray; case .services: .blue; case .about: .purple }
        }
    }

    private var filteredPanes: [Pane] {
        Pane.allCases.filter { search.isEmpty || L10n.s($0.key, env.uiLanguage).contains(search) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 红绿灯托管区：留到搜索框起始于 ~y62（真机实测），并可拖窗
            Color.clear.frame(height: 44)
                .contentShape(.rect)
                .gesture(WindowDragGesture())

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(env.t(.search), text: $search).textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(DS.control, in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 2) {
                ForEach(filteredPanes) { p in navButton(p) }
                if filteredPanes.isEmpty {
                    Text(env.t(.noResults))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 232)
        // System Settings 侧栏同款 .sidebar 材质——SwiftUI .regularMaterial 浅色下太淡，
        // 面板顶缘和窗体融在一起，红绿灯看起来像悬在窗外
        .background(SidebarMaterial().clipShape(RoundedRectangle(cornerRadius: 10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 0.5))
        .padding(.leading, 10)
        .padding(.top, 8)      // 顶内缩 8：给红绿灯留 ~5px 净空（真机值）
        .padding(.bottom, 10)
    }

    private func navButton(_ p: Pane) -> some View {
        let selected = pane == p
        // 切页时若三级页开着，先弹回列表（前进历史一并清掉）
        return Button {
            pane = p
            if !path.isEmpty { path = [] }
            forwardRoute = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: p.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                Text(env.t(p.key)).font(.callout)
                // 模型页状态圆点：有启用项 → 绿；全停用 → 红
                if p == .services {
                    Circle()
                        .fill(vm.activeProviderID.isEmpty ? Color.red : DS.green)
                        .frame(width: 6, height: 6)
                }
                Spacer()
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.88) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右列（工具栏 + 内容）

    private var rightColumn: some View {
        VStack(spacing: 0) {
            // 透明工具栏：‹ › 导航（list ↔ 三级编辑页）+ 页标题（与红绿灯同一高度带）
            HStack(spacing: 12) {
                // 真机 Tahoe：‹ › 是一个整体胶囊（两半 36×35 + 中缝），不是两个独立按钮
                HStack(spacing: 0) {
                    navHalf("chevron.left", enabled: !path.isEmpty) { goBack() }
                    DS.hairline.frame(width: 0.5, height: 22)
                    navHalf("chevron.right", enabled: forwardRoute != nil) { goForward() }
                }
                .background(DS.capsule, in: Capsule())
                Text(toolbarTitle)
                    .font(.system(size: 15, weight: .semibold))
                    // 标题跟着页面走：换标题走淡入淡出（与系统推入动画同步）
                    .id(toolbarTitle)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: toolbarTitle)
                if pane == .services && path.isEmpty { infoButton }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 52)   // 真机实测：工具栏高 52，中心 y≈26 与红绿灯 (25,25) 同线
            .contentShape(.rect)
            .gesture(WindowDragGesture())

            NavigationStack(path: $path) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch pane {
                        case .general: generalPane
                        case .services: servicesPane
                        case .about: aboutPane
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)   // 卡片左右外边距对称，与工具栏内边距对齐
                    .padding(.bottom, 26)
                }
                .navigationDestination(for: EditRoute.self) { route in
                    // 三级页：编辑/新增 provider（系统推入，非 sheet）
                    ProviderEditPage(
                        draft: route.config, isNew: route.isNew,
                        onSave: { saveDraft($0) },
                        onDelete: { confirmDelete($0, name: route.config.name) },
                        onCancel: { goBack() }
                    )
                }
                // 系统自带的浮动返回钮按窗口安全区定位，落在侧栏上——藏掉，‹ › 用工具栏自绘的
                .navigationBarBackButtonHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 导航胶囊的半枚：36×35 命中区（真机实测），底框/中缝由外层胶囊承担，
    /// 只有字形随启停变色（.bordered 会把禁用态底框淡没，看着像两个尺寸）
    private func navHalf(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.primary : DS.text3)
                .frame(width: 36, height: 35)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 工具栏标题：列表 = pane 名；三级页 = 服务名 / 「添加 xxx」（真机 System Settings 语法）
    private var toolbarTitle: String {
        guard let route = path.last else { return env.t(pane.key) }
        let fallback = ProviderPreset.match(route.config)?.defaultName ?? env.t(.customPreset)
        if route.isNew {
            return L10n.addPresetTitle(fallback, env.uiLanguage)
        }
        return route.config.name.isEmpty ? fallback : route.config.name
    }

    /// 「!」说明按钮 + 原生 popover（箭头、点击外部关闭由系统负责）
    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(env.t(.infoProviders))
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            Text(env.t(.providerInfoText))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(width: 330, alignment: .leading)
                .padding(14)
        }
    }

    // MARK: - 通用

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 单行 Section 不重复段头（行标签已说明内容），与 System Settings 惯例一致
            section {
                row(env.t(.sectionAppearance), sub: env.t(.appearanceSub)) {
                    Picker("", selection: Binding(
                        get: { vm.appearance },
                        set: { vm.appearance = $0 }
                    )) {
                        ForEach(AppAppearance.allCases) { Text($0.label(env.uiLanguage)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            section {
                row(env.t(.sectionLanguage), sub: env.t(.languageSub)) {
                    Picker("", selection: Bindable(env).language) {
                        ForEach(AppLanguage.allCases) { Text($0.label(env.uiLanguage)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            section(env.t(.sectionVoice), footnote: env.t(.voiceSystemHint)) {
                row(env.t(.voiceSystem), sub: env.speech.systemVoiceName) {
                    Picker("", selection: Bindable(env).systemVoiceID) {
                        Text(env.t(.voiceAuto)).tag(String?.none)
                        ForEach(env.speech.availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(SpeechService.qualityLabel(voice.quality, env.uiLanguage))")
                                .tag(Optional(voice.identifier))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    .controlSize(.small)
                }
                sep()
                row(env.t(.speechRate)) {
                    Picker("", selection: Bindable(env).speechRate) {
                        Text(env.t(.rateSlow)).tag(SpeechRate.slow)
                        Text(env.t(.rateStandard)).tag(SpeechRate.standard)
                        Text(env.t(.rateFast)).tag(SpeechRate.fast)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .controlSize(.small)
                }
            }
            section(env.t(.sectionLaunch)) {
                row(env.t(.launchAtLogin)) {
                    Toggle("", isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { _ in vm.toggleLaunchAtLogin() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            section(env.t(.sectionUpdate)) {
                row(env.t(.updateAutoCheck)) {
                    Toggle("", isOn: Binding(
                        get: { env.update.automaticallyChecksForUpdates },
                        set: { env.update.automaticallyChecksForUpdates = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                sep()
                row(env.t(.updateCurrentVersion), sub: Self.appVersionString) {
                    Button(env.t(.updateCheckNow)) { env.update.checkForUpdates() }
                        .controlSize(.small)
                }
            }
            section(env.t(.sectionData)) {
                row(env.t(.dataFolder), sub: env.t(.dataFolderSub)) {
                    Button(env.t(.revealInFinder)) { vm.revealConfigFolder() }
                        .controlSize(.small)
                }
                sep()
                row(env.t(.runLog), sub: env.t(.runLogSub)) {
                    Button(env.t(.revealInFinder)) { vm.revealLogFile() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.top, 16)   // 真机实测：工具栏底 52 + 16 → 首卡顶 ~y68
    }

    // MARK: - 模型服务

    private var servicesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.providers.isEmpty {
                // 空态：卡片内居中文案 + accent 添加按钮
                card {
                    VStack(spacing: 12) {
                        Text(env.t(.emptyProviders))
                            .foregroundStyle(.secondary)
                        addProviderMenu
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                // 首组裸卡无段头（System Settings 惯例：段头从第二组才出现）
                card {
                    ForEach(Array(vm.providers.enumerated()), id: \.element.id) { idx, p in
                        if idx > 0 { sep(54) }   // 分隔线跳过图标列，从文字左缘起画
                        providerRow(p)
                    }
                }
                // 卡片外左下角的添加按钮
                addProviderMenu
                    .padding(.leading, 2)
            }
        }
        .padding(.top, 16)   // 同通用页：首卡顶对齐真机 ~y68
    }

    /// 服务行（真机解剖）：28px 图标 + 名称 + ● 状态副标题 + 互斥开关 + chevron。
    /// 点行（除开关外）推入三级编辑页；右键给出删除入口
    private func providerRow(_ p: ProviderConfig) -> some View {
        let active = p.id == vm.activeProviderID
        return HStack(spacing: 12) {
            Button {
                openEditor(p, isNew: false)
            } label: {
                HStack(spacing: 12) {
                    ProviderIcon(config: p, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                            .font(.callout)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(active ? DS.green : DS.text3)
                                .frame(width: 6, height: 6)
                            Text(p.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // 互斥语义由 VM 的单 activeProviderID 保证；Toggle 是 Button 的兄弟而非子视图（避免点击被吞）
            Toggle("", isOn: Binding(
                get: { active },
                set: { _ in vm.toggleActive(p.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(active ? env.t(.inUse) : env.t(.setActive))

            Button {
                openEditor(p, isNew: false)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.text3)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(.rect)
        .contextMenu {
            Button(env.t(.delete), role: .destructive) { confirmDelete(p.id, name: p.name) }
        }
    }

    /// 「添加 Provider」菜单：预设 + 自定义（类型在此选定）
    private var addProviderMenu: some View {
        Menu {
            ForEach(ProviderPreset.all) { preset in
                Button {
                    openEditor(vm.draftFromPreset(preset), isNew: true)
                } label: {
                    Label {
                        Text(preset.defaultName)
                    } icon: {
                        presetIcon(preset)
                    }
                }
            }
            Divider()
            Button {
                openEditor(vm.draftFromPreset(nil), isNew: true)
            } label: {
                Label(env.t(.customPreset), systemImage: "globe")
            }
        } label: {
            Text(env.t(.addProvider))
        }
        .controlSize(.small)
    }

    private func presetIcon(_ preset: ProviderPreset) -> some View {
        Group {
            if let img = NSImage(named: "provider-\(preset.id)") {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
            }
        }
    }

    // MARK: - 三级页导航与编辑动作

    /// 推入编辑页（清空前进历史）
    private func openEditor(_ p: ProviderConfig, isNew: Bool) {
        path.append(EditRoute(config: p, isNew: isNew))
        forwardRoute = nil
    }

    /// ‹ 回列表，当前页进前进历史
    private func goBack() {
        guard let current = path.last else { return }
        forwardRoute = current
        path.removeLast()
    }

    /// › 前进回编辑页
    private func goForward() {
        guard let next = forwardRoute else { return }
        path.append(next)
        forwardRoute = nil
    }

    /// 保存后弹出三级页
    private func saveDraft(_ provider: ProviderConfig) {
        if path.last?.isNew == true { vm.add(provider) } else { vm.update(provider) }
        path.removeLast()
    }

    private func confirmDelete(_ id: String, name: String) {
        confirmAlert(env.t(.deleteServiceTitle),
                     message: L10n.deleteServiceMessage(name, env.uiLanguage),
                     confirm: env.t(.delete)) {
            vm.delete(id)
            // 编辑页里删的是自己 → 弹出；前进历史里的也一并清
            if path.last?.config.id == id { path.removeLast() }
            if forwardRoute?.config.id == id { forwardRoute = nil }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 19))
                .padding(.bottom, 4)
            Text("Parrotlet").font(.headline)
            Text(L10n.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", env.uiLanguage))
                .font(.caption).foregroundStyle(.secondary)
            Text(env.t(.aboutTagline))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - 小组件

    /// 分组：段头（可空）+ 卡片 + 脚注（可空），间距节奏按真机
    private func section<Content: View>(_ label: String? = nil, footnote: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            card(content: content)
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(DS.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    /// 行：标签（可带副标题）左置、控件右置
    private func row<Control: View>(_ label: String, sub: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                if let sub {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) { control() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    /// 分隔线：从文字左缘起画（inset），右端顶到卡片边
    private func sep(_ inset: CGFloat = 14) -> some View {
        Hairline().padding(.leading, inset)
    }

    /// 1 物理像素分隔线：@1x 外接屏上 0.5pt 只有半像素，
    /// 可见性取决于亚像素相位（实测同一张卡两条线一深一浅）——按屏幕 scale 取整
    private struct Hairline: View {
        @Environment(\.pixelLength) private var px
        var body: some View { DS.hairline.frame(height: px) }
    }

    // MARK: - 弹窗

    private func confirmAlert(_ title: String, message: String, confirm: String,
                              action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: env.t(.cancel))
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

// MARK: - 滚动条修正

/// NSVisualEffectView .sidebar 材质（SwiftUI ShapeStyle 无对应物）
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 窗口 chrome 修正：① 外接鼠标时 NSScrollView 退化成常驻轨道+底色（ChatView 同款坑），
/// SwiftUI scrollIndicators 拦不住——直取 NSScrollView 强制 overlay（幂等重刷）；
/// ② hiddenTitleBar 后红绿灯贴在系统默认位（~20,16），真机 System Settings (Tahoe)
/// 实测是内移到中心 (25,25)——AppKit 平移三枚按钮对齐真机（幂等）
private struct WindowChromeFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.fix(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { Self.fix(nsView) }

    private static func fix(_ v: NSView) {
        guard let win = v.window else { return }
        for sv in win.contentView?.allScrollViews ?? [] {
            sv.scrollerStyle = .overlay
        }
        Self.alignTrafficLights(win)
    }

    /// 以 close 按钮为锚，三枚按钮整组平移到中心 (25,25)（屏幕点 → superview 坐标）
    private static func alignTrafficLights(_ win: NSWindow) {
        guard let close = win.standardWindowButton(.closeButton),
              let sup = close.superview else { return }
        let target = sup.convert(NSPoint(x: 25, y: win.frame.height - 25), from: nil)
        let dx = target.x - close.frame.midX
        let dy = target.y - close.frame.midY
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let btn = win.standardWindowButton(type) {
                btn.frame.origin.x += dx
                btn.frame.origin.y += dy
            }
        }
    }
}

private extension NSView {
    var allScrollViews: [NSScrollView] {
        subviews.flatMap(\.allScrollViews) + ((self as? NSScrollView).map { [$0] } ?? [])
    }
}

// MARK: - 模型页专用组件

/// Provider 官方品牌图标（assets/providers/provider-<id>.png，随包资源）；
/// 自定义/未识别服务退回灰色地球方块
private struct ProviderIcon: View {
    let config: ProviderConfig
    var size: CGFloat = 28

    var body: some View {
        if let preset = ProviderPreset.match(config),
           let img = NSImage(named: "provider-\(preset.id)") {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.secondary.gradient, in: RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

/// 新增/编辑三级页（右列推入，非 sheet）：Esc/取消返回列表；删除仅编辑态出现；
/// 保存时 API Key 为空 → 聚焦输入框不提交；名称留空自动用预设名
private struct ProviderEditPage: View {
    @Environment(AppEnvironment.self) private var env
    @State var draft: ProviderConfig
    let isNew: Bool
    let onSave: (ProviderConfig) -> Void
    let onDelete: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var keyFocused: Bool
    @State private var keyHint = false

    private var vm: SettingsViewModel { env.settings }
    private var preset: ProviderPreset? { ProviderPreset.match(draft) }
    private var busy: Bool {
        vm.modelsLoading[draft.id] == true || vm.testing[draft.id] == true
    }
    private var endpointError: APIEndpoint.ValidationError? {
        do {
            _ = try APIEndpoint.validate(draft.baseURL)
            return nil
        } catch let error as APIEndpoint.ValidationError {
            return error
        } catch {
            return .invalid
        }
    }

    private var requiresAPIKey: Bool {
        (try? APIEndpoint.validate(draft.baseURL))?.isLocal != true
    }

    private var canSave: Bool {
        endpointError == nil
            && !draft.model.trimmingCharacters(in: .whitespaces).isEmpty
            && !busy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 标题由工具栏承担（真机 System Settings 详情页内容区不重复标题）
                Form {
                    Section {
                        formRow(env.t(.name)) {
                            sheetField(preset?.defaultName ?? env.t(.customServiceName), text: $draft.name)
                        }
                        formRow("API Key") {
                            KeyField(text: Binding(
                                get: { draft.apiKey ?? "" },
                                set: { draft.apiKey = $0.nilIfBlank }
                            ), focused: $keyFocused)
                        }
                        formRow("Base URL") {
                            sheetField(env.t(.baseURLPlaceholder), text: $draft.baseURL)
                        }
                        formRow(env.t(.model)) { modelPicker }
                        formRow(env.t(.testConnection)) { connectionRow }
                    }
                }
                .formStyle(.grouped)

                if let endpointError {
                    Text(env.t(endpointError.l10nKey))
                        .font(.caption).foregroundStyle(.red)
                } else if keyHint {
                    Text(env.t(.apiKeyRequired))
                        .font(.caption).foregroundStyle(.red)
                }
                if let err = vm.modelsError[draft.id] {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    if !isNew {
                        Button(env.t(.delete)) { onDelete(draft.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(busy)
                    }
                    Spacer()
                    Button(env.t(.cancel), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(env.t(.save)) { attemptSave() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .padding(.horizontal, 20)
            // Form .grouped 首个 Section 自带 ~24pt 顶边距，负 padding 抵消后净 16，
            // 首卡顶与列表页对齐（工具栏底 52 + 16 ≈ y68）
            .padding(.top, -8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 有 Key 时自动拉模型列表；模型还是占位值时顺手选中第一个
        .task(id: draft.id) {
            let isLocal = (try? APIEndpoint.validate(draft.baseURL))?.isLocal == true
            guard vm.models[draft.id] == nil, vm.modelsLoading[draft.id] != true,
                  isLocal || ((draft.apiKey ?? "").isEmpty == false) else { return }
            await vm.fetchModels(draft)
            if let first = vm.models[draft.id]?.first, draft.model.isEmpty {
                draft.model = first
            }
        }
    }

    /// 模型下拉：选项 = 内置预设 ∪ 已保存值 ∪ 在线缓存；↻ 在线拉取替换，转圈禁用
    private var modelPicker: some View {
        var options = preset?.builtinModels ?? []
        for m in vm.models[draft.id] ?? [] where !options.contains(m) { options.append(m) }
        if !draft.model.isEmpty, !options.contains(draft.model) { options.append(draft.model) }
        return HStack(spacing: 8) {
            if vm.modelsLoading[draft.id] == true {
                ProgressView().controlSize(.mini)
            }
            Picker("", selection: $draft.model) {
                if options.isEmpty {
                    Text(env.t(.fetchModelsHint)).tag("")
                } else {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(options.isEmpty || busy)
            Button {
                Task { await vm.fetchModels(draft) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .disabled(busy)
            .help(env.t(.reloadModels))
            Spacer()
        }
    }

    /// 连接行：测试按钮 + 状态（转圈 / 绿点「可用 · Nms」/ 红点错误）
    private var connectionRow: some View {
        HStack(spacing: 8) {
            Button(env.t(.test)) { Task { await vm.testConnection(draft) } }
                .controlSize(.small)
                .disabled(busy)
            if vm.testing[draft.id] == true {
                ProgressView().controlSize(.mini)
            } else if let result = vm.testResults[draft.id] {
                let ok = result.hasPrefix("✅")
                Circle().fill(ok ? .green : .red).frame(width: 7, height: 7)
                Text(String(result.dropFirst(2)))
                    .font(.caption)
                    .foregroundStyle(ok ? .green : .red)
                    .lineLimit(2)
            } else {
                Text(env.t(.notTested)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// 保存：Key 为空 → 聚焦输入框 + 提示，不提交；名称留空 → 预设默认名
    private func attemptSave() {
        guard canSave else { return }
        if requiresAPIKey && (draft.apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            keyHint = true
            keyFocused = true
            return
        }
        var c = draft
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty {
            c.name = preset?.defaultName ?? env.t(.customServiceName)
        }
        onSave(c)
    }

    private func formRow<Control: View>(_ label: String,
                                        @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            control()
        }
    }

    private func sheetField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            // Form 行内 TextField 会把 title 拆成左侧标签（placeholder 与值双显），labelsHidden 复原
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// SecureField / TextField 切换的 API Key 输入框（focused 供「Key 为空保存时聚焦」）
private struct KeyField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @Environment(AppEnvironment.self) private var env
    @State private var show = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if show {
                    TextField(env.t(.keyPlaceholder), text: $text)
                } else {
                    SecureField(env.t(.keyPlaceholder), text: $text)
                }
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.callout)
            .focused(focused)
            // 长 key 超出宽度时横向滚动（macOS 原生行为），布局上尽量给足宽度
            .layoutPriority(1)
            Button {
                show.toggle()
            } label: {
                Image(systemName: show ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // 不定宽：吃满行内剩余空间，35 位的 DeepSeek key 完整可见
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
