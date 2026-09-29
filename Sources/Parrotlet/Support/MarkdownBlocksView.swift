import SwiftUI

/// 全局统一字体：Inter（随包 assets/fonts/Inter.ttc，全字重真实字形；中文自动回落苹方）
extension Font {
    static func eaFont(_ size: CGFloat, _ style: Font.TextStyle = .body,
                       weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size, relativeTo: style).weight(weight)
    }
}

/// 块级 markdown 正文视图：MarkdownBlocks 切块 → 逐块自绘。
/// 对话窗 AI 正文渲染。
/// 密度定稿：块距 12 / 行距 5 —— 段落被空气包围，眼睛有落点（对齐参考的呼吸感）
/// Equatable：文本没变时 SwiftUI 直接跳过整棵块子树（历史消息在打字/流式期间不重渲染）
struct MarkdownBlocksView: View, Equatable {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 走渲染缓存：历史消息内容稳定，重复渲染不重复切块（见 MarkdownRenderCache）
            ForEach(Array(MarkdownRenderCache.blocks(for: text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单个块级段落的渲染：标题稍大加粗拉开层级、列表圆点/序号悬挂缩进、
/// 分隔线细灰、代码块等宽字体灰底、表格卡片
struct BlockView: View {
    let block: MarkdownBlocks.Block

    var body: some View {
        switch block {
        case .paragraph(let md):
            MarkdownText(md)
        case .heading(_, let text):
            MarkdownText(text)
                .font(.eaFont(16, .title3, weight: .semibold))
                .padding(.top, 4)
        case .unorderedItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                MarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
        case .orderedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(.secondary)
                MarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
        case .divider:
            Divider()
                .opacity(0.5)
                .padding(.vertical, 4)
        case .quote(let quote):
            QuoteBlock(text: quote)
        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        MarkdownText(cell)
                            .font(.eaFont(13, .callout, weight: .semibold))
                    }
                }
                Divider().opacity(0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            MarkdownText(cell)
                                .font(.eaFont(13, .callout))
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 引用块：浅灰底圆角卡片（与表格同款容器），例句/纠错和正文一眼分层
struct QuoteBlock: View {
    let text: String

    var body: some View {
        MarkdownText(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
