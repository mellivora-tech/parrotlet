import SwiftUI
import AppKit

/// 侧栏调色板：沿用设置页侧栏的深浅双值（SettingsView 的 DS 是 private，此处自取所需）
private enum SidebarDS {
    static let sidebar = Color.adaptive(light: Color(white: 0.93),
                                        dark: Color(red: 0.165, green: 0.165, blue: 0.180))
    static let control = Color.adaptive(light: .black.opacity(0.05), dark: .white.opacity(0.07))
    static let selection = Color.adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.11))
    static let text3 = Color.adaptive(light: Color(white: 0.50), dark: Color(white: 0.42))
}

/// 常驻会话侧栏（聊天窗内固定 220pt）：搜索 / 新建 / 切换 / 删除（hover 行尾 × 或右键菜单）。
struct SessionSidebarView: View {
    @Bindable var vm: ChatViewModel
    @Environment(AppEnvironment.self) private var env
    /// 搜索词由外层（ConversationView）持有
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
            sessionList
        }
        .frame(width: SidebarLayout.width)
        .frame(maxHeight: .infinity)
        .background(SidebarDS.sidebar)
    }

    /// 顶行：[✎ 新对话]；整行可拖拽移动窗口（与聊天 header 同款）
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                vm.startNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.eaFont(13, .body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(env.t(.newChat))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.eaFont(11, .callout))
                .foregroundStyle(SidebarDS.text3)
            TextField(env.t(.searchChats), text: $searchText)
                .textFieldStyle(.plain)
                .font(.eaFont(12, .callout))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(SidebarDS.control, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var sessionList: some View {
        let shown = SessionListFilter.filter(vm.sessions, query: searchText,
                                             fallbackTitle: env.t(.newChat))
        if vm.sessions.isEmpty {
            emptyLabel(env.t(.emptyChats))
        } else if shown.isEmpty {
            emptyLabel(env.t(.noResults))
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { session in
                        SessionRow(session: session,
                                   active: session.id == vm.activeSessionID,
                                   onSelect: { vm.resumeSession(session.id) },
                                   onDelete: { vm.deleteSession(session.id) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.eaFont(11, .callout))
            .foregroundStyle(SidebarDS.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 会话行：标题 + 相对时间；当前会话底色高亮，hover 出行尾删除按钮
private struct SessionRow: View {
    @Environment(AppEnvironment.self) private var env
    let session: ChatSession
    let active: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    /// 系统本地化的相对时间（「3小时前」/「3 hr ago」），不占 L10n key
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            // 标题+时间一行：标题尾断让位，时间钉右端完整显示；超长标题悬停 tooltip 看全名
            Text(session.displayTitle(fallback: env.t(.newChat)))
                .font(.eaFont(12, .callout, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session.displayTitle(fallback: env.t(.newChat)))
            Spacer(minLength: 4)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.eaFont(10, .caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(env.t(.deleteChat))
            } else {
                Text(Self.relativeFormatter.localizedString(for: session.updatedAt,
                                                            relativeTo: Date()))
                    .font(.eaFont(10, .caption))
                    .foregroundStyle(SidebarDS.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: 18)   // × 钮 18 高：行高不随 hover 抖动
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            active ? AnyShapeStyle(SidebarDS.selection)
                : hovering ? AnyShapeStyle(.fill.tertiary)
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(.rect)
        // 行用 onTapGesture 而非 Button：行尾删除是真 Button，嵌套 Button 命中不稳定
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Text(env.t(.deleteChat))
            }
        }
    }
}
