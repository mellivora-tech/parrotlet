import Foundation

/// SSE 解析与两家 provider 的 delta 解码（真实片段回放，无网络）
/// 语义：一行 data: 即一个完整事件（bytes.lines 会吞掉空行边界，见 SSEParser 注释）
let sseParserTests: [TestCase] = [
    TestCase(name: "sse.data line emits event immediately") {
        let parser = SSEParser()
        try expectEqual(parser.consume("data: {\"a\":1}"), .data("{\"a\":1}"))
        try expectEqual(parser.consume(""), nil as SSEParser.Output?, "空行不再承载边界语义")
    },

    TestCase(name: "sse.[DONE] sentinel") {
        let parser = SSEParser()
        try expectEqual(parser.consume("data: [DONE]"), .done)
    },

    TestCase(name: "sse.comment and keep-alive lines ignored") {
        let parser = SSEParser()
        try expectEqual(parser.consume(": keep-alive"), nil as SSEParser.Output?)
        try expectEqual(parser.consume("event: ping"), nil as SSEParser.Output?)
        try expectEqual(parser.consume("id: 42"), nil as SSEParser.Output?)
        try expectEqual(parser.consume("retry: 1000"), nil as SSEParser.Output?)
        try expectEqual(parser.consume("data: x"), .data("x"))
    },

    TestCase(name: "sse.no space after colon") {
        let parser = SSEParser()
        try expectEqual(parser.consume("data:{\"k\":true}"), .data("{\"k\":true}"))
    },

    /// 回归：真实链路上 bytes.lines 丢弃空行，两个事件以连续 data 行到达。
    /// 旧版按规范聚合会用 \n 拼接成非法 JSON（DeepSeek 实测踩坑）。
    TestCase(name: "sse.consecutive data lines are separate events (bytes.lines regression)") {
        let parser = SSEParser()
        try expectEqual(parser.consume("data: {\"a\":1}"), .data("{\"a\":1}"))
        try expectEqual(parser.consume("data: {\"b\":2}"), .data("{\"b\":2}"))
        try expectEqual(parser.consume("data: [DONE]"), .done)
    },

    TestCase(name: "sse.trailing CR stripped") {
        let parser = SSEParser()
        try expectEqual(parser.consume("data: x\r"), .data("x"))
    },

    TestCase(name: "sse.blank line without data yields nothing") {
        let parser = SSEParser()
        try expectEqual(parser.consume(""), nil as SSEParser.Output?)
    },
]

let openAIDeltaTests: [TestCase] = [
    TestCase(name: "openai.delta content extracted") {
        let json = #"{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#
        try expectEqual(OpenAICompatibleProvider.handle(.data(json)), "Hello")
    },

    TestCase(name: "openai.first frame role-only delta → nil") {
        let json = #"{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
        try expectEqual(try OpenAICompatibleProvider.handle(.data(json)), nil as String?)
    },

    TestCase(name: "openai.finish frame → nil, [DONE] → nil") {
        let finish = #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        try expectEqual(try OpenAICompatibleProvider.handle(.data(finish)), nil as String?)
        try expectEqual(try OpenAICompatibleProvider.handle(.done), nil as String?)
    },

    TestCase(name: "openai.reasoning_content ignored") {
        let json = #"{"choices":[{"delta":{"reasoning_content":"thinking...","content":"answer"}}]}"#
        try expectEqual(OpenAICompatibleProvider.handle(.data(json)), "answer")
    },

    /// DeepSeek 真实回放（2026-08 抓包），还原 bytes.lines 交付的无空行形态
    TestCase(name: "openai.full chunk stream replay (DeepSeek capture, no blank lines)") {
        let lines: [String] = [
            "data: " + #"{"id":"123396da","object":"chat.completion.chunk","created":1787909487,"model":"deepseek-v4-flash","system_fingerprint":"a26a7955944dc5c60445bff77fac9c8e","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}"#,
            "data: " + #"{"id":"123396da","object":"chat.completion.chunk","created":1787909487,"model":"deepseek-v4-flash","choices":[{"index":0,"delta":{"content":"Hi"},"logprobs":null,"finish_reason":null}]}"#,
            "data: " + #"{"id":"123396da","object":"chat.completion.chunk","created":1787909487,"model":"deepseek-v4-flash","choices":[{"index":0,"delta":{"content":" there"},"logprobs":null,"finish_reason":null}]}"#,
            "data: " + #"{"id":"123396da","object":"chat.completion.chunk","created":1787909487,"model":"deepseek-v4-flash","choices":[{"index":0,"delta":{"content":"!"},"logprobs":null,"finish_reason":null}]}"#,
            "data: " + #"{"id":"123396da","object":"chat.completion.chunk","created":1787909487,"model":"deepseek-v4-flash","choices":[{"index":0,"delta":{"content":""},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}"#,
            "data: [DONE]",
        ]
        let parser = SSEParser()
        var text = ""
        var sawDone = false
        for line in lines {
            if let output = parser.consume(line) {
                if case .done = output { sawDone = true }
                if let delta = try OpenAICompatibleProvider.handle(output) { text += delta }
            }
        }
        try expectEqual(text, "Hi there!")
        try expect(sawDone, "应看到 [DONE]")
    },
]

