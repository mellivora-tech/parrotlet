import Foundation

let apiEndpointTests: [TestCase] = [
    TestCase(name: "endpoint.https normalizes trailing slash and appends path") {
        let url = try APIEndpoint.endpoint(baseURL: "https://api.example.com/v1/", path: "/chat/completions")
        try expectEqual(url.absoluteString, "https://api.example.com/v1/chat/completions")
    },

    TestCase(name: "endpoint.loopback http is allowed without key") {
        let validated = try APIEndpoint.validate("http://127.0.0.1:11434/v1")
        try expect(validated.isLocal)
        try expectEqual(validated.url.absoluteString, "http://127.0.0.1:11434/v1")
    },

    TestCase(name: "endpoint.remote http is rejected") {
        do {
            _ = try APIEndpoint.validate("http://api.example.com/v1")
            throw TestFailure(message: "远程 HTTP 应被拒绝", file: "APIEndpointTests", line: 14)
        } catch let error as APIEndpoint.ValidationError {
            try expectEqual(error, .insecureRemote)
        }
    },

    TestCase(name: "endpoint.rejects userinfo query and fragment") {
        for value in ["https://user@api.example.com/v1",
                      "https://api.example.com/v1?x=1",
                      "https://api.example.com/v1#section"] {
            do {
                _ = try APIEndpoint.validate(value)
                throw TestFailure(message: "应拒绝非端点组件: \(value)", file: "APIEndpointTests", line: 25)
            } catch let error as APIEndpoint.ValidationError {
                try expectEqual(error, .unsupportedComponents)
            }
        }
    },

    TestCase(name: "endpoint.only 127/8 localhost and IPv6 loopback are local") {
        for value in ["localhost", "::1", "[::1]", "127.0.0.1", "127.255.255.255"] {
            try expect(APIEndpoint.isLoopback(host: value), "\(value) 应是 loopback")
        }
        for value in ["example.com", "0.0.0.0", "192.168.1.2", "1270.0.0.1"] {
            try expect(!APIEndpoint.isLoopback(host: value), "\(value) 不应视为 loopback")
        }
    },
]
