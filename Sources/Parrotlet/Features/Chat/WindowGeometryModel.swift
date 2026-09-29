import SwiftUI

/// 聊天窗高度自适应状态机（从 ConversationView 抽出，纯逻辑可单测）。
///
/// 策略：
/// - 内容少于下限 → transcript 撑到 680 − chrome（保底，开窗即 680 不缩矮）；
///   超过下限 → 贴内容峰值的只长不缩，到 900 − chrome 封顶
/// - 用户手动拖过窗 → 冻结在拖拽结果，直到切换/新开会话才复位（R9b）
/// - 贴边隐藏中 → 停手：apply() 顶边锚定向下长高会把底边长回屏幕里
@MainActor
@Observable
final class WindowGeometryModel {
    /// header 实测高度（PreferenceKey 上报），参与窗口高度公式
    var headerHeight: CGFloat = 44
    /// 输入卡片实测高度（1-4 行自适应），参与窗口高度公式
    var inputBarHeight: CGFloat = 96
    /// 贴边隐藏中（EdgeHideController 上报）
    var edgeHidden = false

    /// session 内内容峰值——流式过程只长不缩，切换会话时复位（允许收缩）
    private(set) var peakContent: CGFloat = 0
    /// 尖峰去抖：SwiftUI 布局探测会瞬态把容器拉伸到屏幕级高度（实测 1606），
    /// 超出合理增量的读数要连续出现两次才采信
    private var pendingSpike: CGFloat?
    /// 用户手动拖过窗 = true，冻结自适应直到切换/新开会话
    private(set) var userResized = false
    /// 冻结时锁死的 transcript 高度
    private(set) var frozenTranscript: CGFloat = 0

    /// noteContentHeight 的实际写入次数（测试断言收敛不变式用：
    /// 同值重复上报不得再写入，防 @Observable 布局失效自激回归——实测卡死过）。
    /// @ObservationIgnored 排除在视图跟踪外，计数本身不触发重渲染
    @ObservationIgnored private(set) var probeWriteCount = 0

    /// 自动高度下限（也是 defaultSize 的开窗高度）：窗口打开即 680，内容少也不缩矮
    nonisolated static let minAutoHeight: CGFloat = 680
    /// 自动高度上限：内容超过下限后继续贴内容长，封顶 900
    nonisolated static let maxAutoHeight: CGFloat = 900

    /// 自动高度策略下 transcript 的理想高度：
    /// 内容峰值夹在 [680 − chrome, 900 − chrome] 之间（保底不缩矮，封顶不疯长）
    var autoTranscriptHeight: CGFloat {
        let floor = max(120, Self.minAutoHeight - headerHeight - inputBarHeight)
        let cap = max(floor, Self.maxAutoHeight - headerHeight - inputBarHeight)
        return min(max(peakContent, floor), cap)
    }

    /// transcript 理想高度：用户拖过窗 → 冻结值；否则保底 680 − chrome、封顶 900 − chrome
    var idealTranscriptHeight: CGFloat? {
        if userResized { return frozenTranscript }
        guard peakContent > 0 else { return nil }
        return autoTranscriptHeight
    }

    /// 引擎期望的窗口内容高；nil = 不干预（已冻结、贴边隐藏中或内容未测出）
    var expectedWindowHeight: CGFloat? {
        guard !userResized, !edgeHidden, peakContent > 0 else { return nil }
        return headerHeight + autoTranscriptHeight + inputBarHeight
    }

    /// 内容高度读数入口（ContentHeightProbe 异步上报）。
    /// 尖峰去抖：比当前峰值高出 400pt 以上的读数属瞬态拉伸嫌疑，连续两次才采信
    /// （正常路径：流式每行 +20 渐进；切长会话跳变会由 updateNSView/二次 layout 立刻补报同值）
    func noteContentHeight(_ h: CGFloat) {
        guard h > 1 else { return }
        if h <= peakContent + 400 {
            // 值没变就不写：@Observable 同值写入照样触发视图 invalidation（@State 不会），
            // 探针每轮渲染都回报 → 写 → 重渲染 → 再回报 → 99% CPU 自激（实测卡死）
            guard max(peakContent, h) != peakContent || pendingSpike != nil else { return }
            peakContent = max(peakContent, h)
            pendingSpike = nil
            probeWriteCount += 1
        } else if pendingSpike == h {
            peakContent = h
            pendingSpike = nil
            probeWriteCount += 1
        } else {
            pendingSpike = h
            probeWriteCount += 1
        }
    }

    /// 用户拖拽结束（live-resize 通知精确识别，程序 setFrame 不触发）：冻结在当前高度
    func noteUserResize(windowContentHeight: CGFloat) {
        let frozen = max(120, windowContentHeight - headerHeight - inputBarHeight)
        // 同值不写（同 noteContentHeight 的 @Observable 自激防御）
        guard frozen != frozenTranscript || !userResized else { return }
        frozenTranscript = frozen
        userResized = true
    }

    /// 切换/新开会话：允许窗口重新自适应（含收缩）
    func resetForSessionSwitch() {
        peakContent = 0
        pendingSpike = nil
        userResized = false
        frozenTranscript = 0
    }
}
