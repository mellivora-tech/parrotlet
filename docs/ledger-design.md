> **Status:** Historical / superseded design note. Current development is focused on the chat-first context English tutor; this document is not an implementation contract.

# 学习账本（Learning Ledger）设计定稿 · 2026-09-02

复盘的目的定案为回答四问：**错了哪些（事实）/ 弱点是什么（模式）/ 完全不会（盲区）/ 重点花时间（决策）**。
四问的主语是学习者，不是"这一天"——日期只是证据的到达时间。因此复盘的数据结构不是"按天存的文章"，
而是一份**长期维护的问题账本**：每日证据流入，账本更新，读出当前状态。

## 与现有数据的关系

- **sessions 仍是唯一事实源**。"今日证据"永远是从 sessions 按天投影的视图（`summary.mistakes / expressions`），不落盘。
- **daily-summaries.json 退役**（复盘文章取消——四问由账本 + 投影直接回答，不再让 LLM 每天写报道）。
- activity.json 已删（前序步骤）。
- 新增单文件：`learning-ledger.json`。

## 结构（Swift 定稿）

```swift
/// 学习账本：跨天成立的学习者问题状态。LLM 管语义，本地管事实。
struct LearningLedger: Codable {
    var weaknesses: [WeaknessEntry]   // 弱点是什么
    var blindSpots: [BlindSpot]       // 完全不会
    var focus: [FocusPoint]           // 重点花时间（≤3 条，始终是"当前生效"那组）
    var summarizedThrough: String     // 已消化证据的水位线（dayKey），增量更新防重复消化
    var updatedAt: Date
}

struct WeaknessEntry: Codable, Identifiable {
    enum Status: String, Codable { case active = "活跃", improving = "改善中", resolved = "已克服" }
    var id: UUID = UUID()
    /// 稳定短名，如「介词搭配」——LLM 输出与本地合并的 key（同义错误应归并到同一 title）
    var title: String
    /// 场景与形态描述（什么情况犯、长什么样），LLM 维护
    var detail: String
    /// 状态由本地按证据日期计算（规则见下），不采信 LLM 判断
    var status: Status
    /// 证据只留最近 10 条；累计数看 hitCount
    var evidence: [Evidence]
    var hitCount: Int
    var firstSeen: Date
    var lastSeen: Date
}

/// 自包含短引用：会话即使被删，账本仍可读、可展示。sessionID 仅用于回源跳转。
struct Evidence: Codable, Identifiable {
    var id: UUID = UUID()
    var day: String            // "2026-09-02"
    var original: String       // 错句原话（逐字）
    var correction: String
    var note: String?          // 错误原因（中文简释）
    var sessionID: UUID?
}

struct BlindSpot: Codable, Identifiable {
    enum Kind: String, Codable {
        case missedExpression = "没用上"   // 该用没用（summary.expressions 是信号源）
        case avoidance         = "回避"     // 句式/话题回避，纵向观察才能命名
        case unexplored        = "未触及"   // LLM 从 topics 历史推断的空白领域
    }
    var id: UUID = UUID()
    var kind: Kind
    var note: String
    /// kind = missedExpression 时的具体表达
    var expression: String?
    /// 陪练是否已带练过（盲区的解法是主动探测，把不会变成正在练）
    var probed: Bool
    var since: Date
}

struct FocusPoint: Codable, Identifiable {
    var id: UUID = UUID()
    /// 来源弱点 title（可空——关注点也可来自盲区）
    var weaknessTitle: String?
    /// 给用户看的中文短句
    var note: String
    /// 注入下一场对话 system prompt 的英文指令
    var injection: String
    var createdAt: Date
}
```

## 分工原则（谁管什么）

**LLM 管语义**：错误归类与归并（`interested on / interested about` → 同一条目）、条目命名与描述、
盲区命名（从 expressions / 句式统计 / topics 空白推断）、关注点措辞（中文一句 + 英文注入一句）。

**本地管事实**：hitCount 计数、evidence 追加去重（original + day）、状态迁移、水位线推进。
状态是确定性规则，不是 LLM 判断——可测、可解释、不会因为模型嘴瓢把"已克服"说早了：

| 状态 | 规则 |
|---|---|
| 活跃 | lastSeen ≤ 14 天 |
| 改善中 | hitCount ≥ 2 且 14 天无新证据 |
| 已克服 | 改善中持续到连续 30 天无复发 |
| 复发 | 已克服条目再来证据 → 回活跃，hitCount 继续累计 |

## 更新契约

1. **触发**：复盘窗打开时自动 + 手动「更新账本」按钮。幂等：只消化 `summarizedThrough` 之后的证据。
2. **输入**：当前账本摘要（每条弱点只带 title/status/hitCount/lastSeen，不带全部证据，省 token）
   + 水位线之后各天投影出的证据（mistakes → 弱点；expressions → 盲区；topics/brief 辅助盲区推断）。
3. **输出**：严格 JSON（与 summaryPrompt 同款约定）：弱点列表（title/detail/新证据）、盲区、关注点（≤3）。
4. **合并（本地）**：按 title 归一匹配——命中则更新 detail、追加证据（去重）、新条目则新建；
   LLM 没提到的既有条目**保留**（去留由本地状态规则决定，不因模型漏写而丢账）。focus 整体替换。
5. **消费**：active focus 的 injection 逐条拼进下一场对话的 system prompt（ChatPartner 规则之后追加
   `FOCUS:` 段）。关注点的第一消费者是下一场对话，复盘窗是它的展示面——窗口没人开，闭环照常转。

## 上限

- 弱点条目 ≤ 20（活跃 + 改善中），超出由 LLM 合并次要条目
- 每条 evidence ≤ 10 条（旧的裁掉，hitCount 已记住总量）；hitCount 无上限
- focus ≤ 3

> 界面不在本设计范围内，另行设计。
