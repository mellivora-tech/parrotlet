import Foundation

/// WindowGeometryModel：窗口高度自适应状态机（峰值只长不缩 / 尖峰去抖 / 拖拽冻结 / 贴边停手 / 切会话复位）
let windowGeometryTests: [TestCase] = [
    TestCase(name: "geometry: 保底 680 不缩矮，保底之上峰值只长不缩") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()   // chrome 默认 44 + 96
            g.noteContentHeight(200)
            try expectEqual(g.expectedWindowHeight, 680)   // 内容少也撑满保底
            g.noteContentHeight(600)
            try expectEqual(g.expectedWindowHeight, 740)   // 超过保底后贴内容长
            g.noteContentHeight(550)   // 更低的读数不收缩
            try expectEqual(g.expectedWindowHeight, 740)
        }
    },

    TestCase(name: "geometry: 理想高度保底 680 − chrome、封顶 900 − chrome") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(200)
            try expectEqual(g.idealTranscriptHeight, 540)   // 保底 680 − 44 − 96
            g.noteContentHeight(300)   // 渐进增长（≤+400/次）一路采信
            g.noteContentHeight(450)
            g.noteContentHeight(700)
            try expectEqual(g.idealTranscriptHeight, 700)   // 保底之上跟随峰值
            g.noteContentHeight(800)
            g.noteContentHeight(1000)
            try expectEqual(g.idealTranscriptHeight, 760)   // 封顶 900 − 44 − 96
        }
    },

    TestCase(name: "geometry: 尖峰读数需连续两次才采信") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(200)
            g.noteContentHeight(1606)   // 布局探测瞬态拉伸，首次不采信
            try expectEqual(g.expectedWindowHeight, 680)   // 保底
            g.noteContentHeight(300)    // 中间插一个正常读数，尖峰作废
            g.noteContentHeight(1606)   // 再次单发仍不采信
            try expectEqual(g.expectedWindowHeight, 680)
            g.noteContentHeight(1606)   // 连续第二次同值 → 采信（切长会话的真实跳变）
            try expectEqual(g.expectedWindowHeight, 900)   // 封顶 900
        }
    },

    TestCase(name: "geometry: 用户拖拽冻结，期望窗高停手、理想高度锁死") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(200)
            g.noteUserResize(windowContentHeight: 600)   // 冻住 transcript = 600 − 140
            try expectEqual(g.idealTranscriptHeight, 460)
            try expect(g.expectedWindowHeight == nil, "冻结后期望窗高不再干预")
            g.noteContentHeight(300)    // 冻结后内容增长也不动
            try expectEqual(g.idealTranscriptHeight, 460)
        }
    },

    TestCase(name: "geometry: 贴边隐藏停手，但理想高度仍上报") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(200)
            g.edgeHidden = true
            try expect(g.expectedWindowHeight == nil, "隐藏期间高度引擎必须停手")
            try expectEqual(g.idealTranscriptHeight, 540)   // 保底 680 − 44 − 96
        }
    },

    TestCase(name: "geometry: 切会话复位，允许重新自适应") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(300)
            g.noteUserResize(windowContentHeight: 600)
            g.resetForSessionSwitch()
            try expect(g.idealTranscriptHeight == nil, "内容未测出前不干预")
            g.noteContentHeight(200)   // 复位后按新会话内容重新自适应（保底 680）
            try expectEqual(g.expectedWindowHeight, 680)
        }
    },

    TestCase(name: "geometry: 同值重复上报零写入（收敛不变式，防 @Observable 自激回归）") {
        try MainActor.assumeIsolated {
            let g = WindowGeometryModel()
            g.noteContentHeight(300)
            g.noteContentHeight(450)
            let writes = g.probeWriteCount
            for _ in 0..<100 { g.noteContentHeight(450) }   // 稳态重复报数 → 静默
            try expectEqual(g.probeWriteCount, writes)
            try expectEqual(g.expectedWindowHeight, 680)   // 峰值 450 低于保底，状态不受影响

            g.noteContentHeight(900)   // 尖峰首报：记 pendingSpike（1 次写入）
            let spikeWrites = g.probeWriteCount
            for _ in 0..<100 { g.noteContentHeight(900) }  // 第二次同值采信 1 次，之后静默
            try expectEqual(g.probeWriteCount, spikeWrites + 1)
            try expectEqual(g.peakContent, 900)
        }
    },
]
