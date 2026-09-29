import AVFoundation
import Observation

/// 系统语音朗读服务：取词发音和生词本朗读共用，互斥打断。
/// 默认优先选择已安装的高质量自然语音；若只有 Compact 语音，则优先 Samantha，避免落到 Albert 等效果音色。
/// （消息点读/自动朗读已移除：双语回复念中文没有学习价值，纯英文场景才有意义——见 git 历史）
@MainActor
@Observable
final class SpeechService: NSObject {
    /// 正在朗读的条目（调用方给的 opaque id，消息用 turn.id.uuidString）；nil = 没在播
    private(set) var speakingToken: String?

    /// 系统语音语速；设置页修改后立即生效
    var rate: SpeechRate = .standard

    /// 系统 TTS 音色 identifier；nil 表示自动选择默认自然语音。
    var voiceID: String? {
        didSet {
            guard voiceID != oldValue else { return }
            if oldValue != nil { stop() }
            selectVoice()
        }
    }

    private(set) var selectedVoice: AVSpeechSynthesisVoice?
    private(set) var availableVoices: [AVSpeechSynthesisVoice] = []

    private let synthesizer = AVSpeechSynthesizer()
    /// 播放代际。迟到的旧 utterance 回调不允许清掉新一次朗读状态。
    private var generation: UInt64 = 0

    /// 设置页显示用：当前系统音色名
    var systemVoiceName: String { selectedVoice?.name ?? "System Default" }

    override init() {
        super.init()
        availableVoices = Self.selectableVoices(from: AVSpeechSynthesisVoice.speechVoices())
        selectVoice()
        synthesizer.delegate = self
    }

    /// 朗读；连续点击时打断重来。空文本不播。
    func speak(_ text: String, token: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        generation += 1
        let currentGeneration = generation
        speakingToken = token

        let utterance = TrackedUtterance(string: trimmed, generation: currentGeneration)
        utterance.voice = selectedVoice
        utterance.rate = rate.utteranceRate
        utterance.prefersAssistiveTechnologySettings = false
        AppLog.log(.info, "speech.speak", [
            "voice": selectedVoice?.identifier ?? "system",
            "len": trimmed.count
        ])
        synthesizer.speak(utterance)
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        speakingToken = nil
        AppLog.log(.debug, "speech.stop")
    }

    private func selectVoice() {
        if let voiceID,
           let voice = availableVoices.first(where: { $0.identifier == voiceID }) {
            selectedVoice = voice
            return
        }
        selectedVoice = availableVoices.first
    }

    private static let preferredCompactNames: [String] = [
        "Samantha", "Alex", "Ava", "Zoe", "Victoria", "Susan", "Karen", "Moira", "Tessa"
    ]

    private static func selectableVoices(from all: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        let voices = all
            .filter { $0.language == "en-US" }
            .filter { $0.quality != .default || preferredCompactNames.contains($0.name) }
        let selectable = voices.isEmpty ? all.filter { $0.language == "en-US" } : voices
        return selectable.sorted { left, right in
            if left.quality != right.quality {
                return left.quality.rawValue > right.quality.rawValue
            }
            return preferredRank(left.name) < preferredRank(right.name)
        }
    }

    private static func preferredRank(_ name: String) -> Int {
        preferredCompactNames.firstIndex(of: name) ?? preferredCompactNames.count
    }

    nonisolated static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality,
                                         _ lang: UILanguage) -> String {
        switch quality {
        case .default: L10n.s(.voiceQualityCompact, lang)
        case .enhanced: L10n.s(.voiceQualityEnhanced, lang)
        case .premium: L10n.s(.voiceQualityPremium, lang)
        @unknown default: L10n.s(.voiceQualityCompact, lang)
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Self.scheduleFinish(utterance, self: self)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Self.scheduleFinish(utterance, self: self)
    }

    nonisolated private static func scheduleFinish(_ utterance: AVSpeechUtterance, self: SpeechService) {
        let finishedGeneration = (utterance as? TrackedUtterance)?.generation
        Task { @MainActor [weak self] in
            guard let self, finishedGeneration == self.generation else { return }
            self.speakingToken = nil
        }
    }
}

/// AVSpeechSynthesizer delegate 不提供 utterance 关联值；用轻量子类携带代际。
private final class TrackedUtterance: AVSpeechUtterance {
    let generation: UInt64

    init(string: String, generation: UInt64) {
        self.generation = generation
        super.init(string: string)
    }

    required init?(coder: NSCoder) {
        self.generation = 0
        super.init(coder: coder)
    }
}
