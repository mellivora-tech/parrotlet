> **Status:** Historical / superseded design note. Current development is focused on the chat-first context English tutor; this document is not an implementation contract.

# Phase 2 开发计划（按执行顺序）

> 2026-09-14 定。顺序即优先级：生词本 → 自动朗读 → 逐句流式 → 按住说话。
> 每阶段独立可交付、独立 commit，做完一个再做下一个。
> 语音方案调研结论见聊天归档，引擎选型已定：sherpa-onnx + Piper（vendor/README.md）。

## 阶段 1：生词本（学习闭环的最后一块）

**动机**：纠错（三段式）和取词讲解都「看完即焚」，生词不沉淀。补上收藏后学习链路闭环：对话 → 纠错 → 收藏 → 复盘。

**数据模型**(`Models/WordEntry.swift` 新建）:
```swift
struct WordEntry: Codable, Identifiable {
    var id: UUID
    var text: String        // 单词/短语（小写归一，去重用）
    var note: String        // 讲解（LLM 输出的 markdown 原样存）
    var context: String     // 出处句（划词时的选区上下文）
    var createdAt: Date
}
```
- 存储：`JSONStore<[WordEntry]>` → `words.json`（名字已在 AppPaths 迁移白名单里）
- 去重：`text` 小写比较，重复收藏 = 更新 note/context + 刷新 createdAt

**采集入口**：取词讲解卡片（LookupViewModel/LookupCard）底部加「收藏」按钮，payload = 选区词 + 讲解 + 出处。纠错自动入库留 v1.5 后话（summary.mistakes/expressions 是现成素材）。

**展示**：每日复盘窗口顶部分段控件：复盘 / 生词本。生词本 tab:
- 列表：词 + 一句话讲解 + 相对日期，按时间倒序
- 行尾：发音按钮（**复用 env.speech**——语音投入的直接回报）、删除
- 复盘页顺带加「今日新词」一行统计（words.json 按日过滤）

**测试**(`Tests/WordBookTests.swift`):store round-trip、大小写去重、按日过滤。

## 阶段 2：自动朗读

**动机**:English 沉浸模式的核心体验——AI 回复生成完自动读出来，不用逐条点。

- config 加 `autoRead: Bool`（默认 false，加法键模式）；设置 → 朗读语音区加开关
- 挂载点：`ChatViewModel` 流式收尾 `appendTurn(.assistant, ...)` 处。ChatViewModel 不直接碰音频——init 加一个可注入的 `onAssistantTurn: ((UUID, String) -> Void)?` 闭包，AppEnvironment 装配时接上 `speech.speak(SpeakableText.plain(reply), token: id)`
- 打断语义现成：speak 互斥；用户发新消息/点其他朗读自然打断
- 中英混排念得怪是已接受取舍（全用当前音色读）

**测试**:config 键默认/round-trip；闭包注入在流式完成时被调（mock 闭包断言）。

## 阶段 3：逐句流式播放

**动机**：长回复现在是「整段生成完才播」，等几秒；改成第一句生成完就开播，零等待。

- `PiperEngine.generate` 加 `onChunk: @Sendable ([Float]) -> Void`：progress callback 每次回调 = 一句的 PCM（引擎按 max_num_sentences=1 分片），C 线程内**立即拷贝**样本（指针仅回调内有效），抛回主线程
- `SpeechService` 收到 chunk 即 `playerNode.scheduleBuffer`——生成比播放快（实测 RTF 0.83，2 线程更快），天然领先一句
- 完成判定：「生成已返回」且「已排队的 chunk 全部播完」（计数器），才清 speakingToken；取消路径不变（callback 返回 0 → 停生成 + 停 node)
- 顺带项（可拆独立小 commit)：语速三档（慢/标准/快 → length_scale 1.1/0.9/0.75),config 加 `speechRate`；语音包行加试听按钮

**测试**:chunk 回调顺序/取消语义（PiperEngine 注入假生成器）；播放调度逻辑拆纯函数测。

## 阶段 4：按住说话（push-to-talk ASR)

**动机**：语音练习的输入半边。macOS 自带 `SFSpeechRecognizer`(en-US）免费、端侧、英文质量一流，不接任何 API。先验证「愿不愿意对电脑说英语」这个习惯本身。

- **权限**:Info.plist 加 `NSSpeechRecognitionUsageDescription` + `NSMicrophoneUsageDescription`(Makefile 已整份拷贝，不用改）；启动时 `SFSpeechRecognizer.requestAuthorization`
- **管线**:`AVAudioEngine.inputNode` tap → `SFSpeechAudioBufferRecognitionRequest`,`requiresOnDeviceRecognition = true`（离线优先，不支持再回落在线）
- **UI**：输入框控件条加麦克风按钮，点击开/再点收（比按住更易发现；按住空格留后话）。识别中：partial result 实时流进输入框（可编辑）,**识别完文本留在输入框，Enter 才发**——说错了能改
- **状态机**:idle / recording / failed(权限拒绝/无网络/无识别器）,failed 走红色小提示（不上 UserFacingError 横幅，太隆重）
- `SpeechRecognizer` 包 protocol，状态机可单测；音频管线不测

**测试**：状态机迁移（idle→recording→idle、权限拒绝→failed);partial 结果写输入框的去抖/覆盖逻辑。

## 工程随手项（不占阶段，穿插做）

- `phase2-plan.xmind` 入库；本文档即语音调研结论的沉淀
- 修本机 SPM/CLT（下次想接 MLX/Kokoro 或任何 SPM 包的前置）
- 分发公证（要发给别人之前才需要）
