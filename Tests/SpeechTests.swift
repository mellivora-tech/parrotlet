import Foundation

/// 语音设置：语速档位与音色配置的编解码
let speechTests: [TestCase] = [
    TestCase(name: "speech.系统语速三档映射到 AVSpeechUtterance.rate") {
        try expectEqual(SpeechRate.slow.utteranceRate, 0.42)
        try expectEqual(SpeechRate.standard.utteranceRate, 0.5)
        try expectEqual(SpeechRate.fast.utteranceRate, 0.62)
    },

    TestCase(name: "speech.旧配置 voice 键被忽略且不再写回") {
        let json = #"{"activeProviderID":"x","providers":[],"voice":"en_US-ryan-high-int8"}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        try expectEqual(cfg.speechRate, .standard)
        let encoded = String(data: try JSONEncoder().encode(cfg), encoding: .utf8)!
        try expect(!encoded.contains("\"voice\":"), "Piper voice 配置不应继续持久化")
    },
    TestCase(name: "speech.systemVoiceID 老配置缺省、显式配置和 round-trip") {
        let legacy = #"{"activeProviderID":"x","providers":[],"voice":"en_US-ryan-high-int8"}"#.data(using: .utf8)!
        let legacyCfg = try JSONDecoder().decode(AppConfig.self, from: legacy)
        try expect(legacyCfg.systemVoiceID == nil, "旧 Piper voice 键不应映射到系统音色")

        var cfg = AppConfig(activeProviderID: "x", providers: [])
        cfg.systemVoiceID = "com.apple.voice.compact.en-US.Samantha"
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        try expectEqual(back.systemVoiceID, "com.apple.voice.compact.en-US.Samantha")
    },
]
