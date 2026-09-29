> **Status:** Historical / superseded design note. Current development is focused on the chat-first context English tutor; this document is not an implementation contract.

# 每日复盘功能审核（2026-09-01）

对 `Sources/Parrotlet/Features/DailyReview/` + `Models/Activity.swift` 的合理性审核结论。
骨架没问题（手动触发 + 按天缓存 + 本地日历边界一致、错误处理得体），以下按严重度记录待办问题。

## 🔴 P0：输入信息太薄，撑不起 prompt 的要求

- `DailyReviewViewModel.prompt` 只喂 `HH:mm [类型] 一句话计数` 的流水（如 `14:32 [对话] 对话 · 第 2 轮`），没有任何内容素材。
- prompt 却要求"从对话反馈里找薄弱点证据" → 模型只能编造或写"没有"，复盘沦为计数复述。
- **素材就在本地**:`ChatSession.summary`(LLM 生成的标题 + 总结正文，`ChatViewModel.summarizeActiveSessionIfNeeded`）完全没利用。
- 改法：生成时把当日各会话的 `summary.title` + 总结正文带进 prompt。

## 🟠 P1：与功能现状脱节

- prompt 引用"批改问题/复习遗忘"，但写作批改/生词复习已砍（commit `0178801`)。`ActivityEvent.Kind` 里 `correction / wordAdded / reviewCompleted / reading` 4 个 case 是死代码，prompt 里的对应表述应一并清理。
- `chatTurn` 每轮一条埋点（`ChatViewModel.swift:141`),10 轮对话刷 10 条相同事件，时间线噪音大、统计数（"对话 23"）无意义；`chatReport` 每 5 轮节流也重复 log。应改为会话级聚合（一场会话一条，带标题与轮数）。

## 🟡 P2：次要

- 容量不匹配：事件上限 2000 条（按每轮一条只够几周），总结上限 400 天。老日子总结还在但事件已裁掉 → "重新生成"被 `hasActivity=false` 永久禁用，缓存总结却照常显示，行为不一致。
- 复盘窗是 `WindowGroup` 却共享单例 `DailyReviewViewModel`：开两个窗口，一边翻日期另一边跟着跳。要么改单例 `Window`（与对话窗一致），要么 VM 按窗口实例化。
- `stats` 排序只有 count 一个键，同数类型顺序随 Dictionary 遍历漂移，加 kind 次序 tiebreak。

## 建议顺序

1. P0（喂会话总结进 prompt + 清理已砍功能的 prompt 表述）
2. P1 埋点改会话级聚合（顺手缓解 P2 的容量问题）
3. P2 逐项收尾

## 处理记录（2026-09-02）

方向重定后落地：**复盘对象从"行为流水"改为"会话内容"**，复盘是学习闭环里"注意到 → 下次练到"的一段，
埋点管道整体移除（`Activity.swift` 删除，复盘取数改为从 `chat-sessions` 派生的纯函数）。

- **P0 ✅**：`prompt` 输入换成当日各会话的总结素材（标题 / 总评 / 错句 / 表达），缺总结的会话如实标注；
  `generate` 前对活跃会话补一次落后总结（总结落后于对话是节流设计的常态）。
- **P1 ✅（取消式修复）**：`ActivityLogger` 连管道删除，`chatTurn` 每轮一条的噪音不存在了；
  prompt 里"批改问题/复习遗忘"表述清除。
- **P2 部分消解**：`stats` 改为固定四项（会话 / 发言 / 纠错 / 新表达），排序漂移消失；
  事件 2000 条上限随管道消失。**仍在**：daily-summaries 400 天上限 vs 会话无限留存的不一致；
  复盘窗 `WindowGroup` 共享单例 VM（开两窗日期联动）。
- `activity.json` 管道与磁盘文件均已删除。
