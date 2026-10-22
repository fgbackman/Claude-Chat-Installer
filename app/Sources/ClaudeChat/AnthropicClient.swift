import Foundation

enum StreamEvent {
    case text(String)
    case thinking(String)
    case usage(Usage)
    case stop(String)
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MessageRequest {
    var model: String
    var system: String
    var messages: [[String: Any]]   // already-built API messages: [{"role": ..., "content": [blocks]}]
    var maxTokens: Int
    var effort: Effort
    var showThinking: Bool
    var useCache: Bool
}

/// Minimal client for the Claude Messages API with server-sent-event streaming.
enum AnthropicClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxRequestBytes = 31_000_000   // API limit is 32 MB per request

    static func body(for r: MessageRequest) -> [String: Any] {
        var b: [String: Any] = [
            "model": r.model,
            "max_tokens": r.maxTokens,
            "stream": true,
            "messages": r.messages,
        ]
        let sys = r.system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { b["system"] = sys }
        if r.effort != .auto { b["output_config"] = ["effort": r.effort.rawValue] }
        if r.showThinking { b["thinking"] = ["type": "adaptive", "display": "summarized"] }
        // Automatic prompt caching: re-sent chat history is billed at the cheap cache-read rate.
        if r.useCache { b["cache_control"] = ["type": "ephemeral"] }
        return b
    }

    /// Streams a reply. `body` is the JSON request body, built on the caller's side with `body(for:)`.
    static func stream(body: Data, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.httpBody = body

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError(message: "No response from the API.")
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw APIError(message: errorMessage(status: http.statusCode, data: data))
                    }

                    var usage = Usage()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let d = payload.data(using: .utf8),
                              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                              let type = obj["type"] as? String else { continue }

                        switch type {
                        case "message_start":
                            if let m = obj["message"] as? [String: Any],
                               let u = m["usage"] as? [String: Any] {
                                merge(u, into: &usage)
                                continuation.yield(.usage(usage))
                            }
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any] {
                                let deltaType = (delta["type"] as? String) ?? ""
                                if deltaType == "text_delta", let t = delta["text"] as? String {
                                    continuation.yield(.text(t))
                                } else if deltaType == "thinking_delta",
                                          let t = delta["thinking"] as? String, !t.isEmpty {
                                    continuation.yield(.thinking(t))
                                }
                            }
                        case "message_delta":
                            if let u = obj["usage"] as? [String: Any] {
                                merge(u, into: &usage)   // counts here are cumulative
                                continuation.yield(.usage(usage))
                            }
                            if let delta = obj["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                continuation.yield(.stop(reason))
                            }
                        case "error":
                            let e = obj["error"] as? [String: Any]
                            throw APIError(message: (e?["message"] as? String) ?? "The stream reported an error.")
                        default:
                            break   // ping, content_block_start/stop, message_stop, future event types
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func merge(_ u: [String: Any], into usage: inout Usage) {
        if let v = u["input_tokens"] as? Int { usage.inputTokens = v }
        if let v = u["output_tokens"] as? Int { usage.outputTokens = v }
        if let v = u["cache_read_input_tokens"] as? Int { usage.cacheReadTokens = v }
        if let v = u["cache_creation_input_tokens"] as? Int { usage.cacheWriteTokens = v }
    }

    static func errorMessage(status: Int, data: Data) -> String {
        var msg = "Error \(status)"
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let e = obj["error"] as? [String: Any],
           let m = e["message"] as? String {
            msg += ": " + m
        } else if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            msg += ": " + String(s.prefix(300))
        }
        switch status {
        case 401: msg += "\n\nYour API key was rejected. Check it in Settings (⌘,)."
        case 429: msg += "\n\nRate limited. Wait a moment and try again."
        case 529: msg += "\n\nThe API is overloaded right now. Try again shortly."
        default: break
        }
        return msg
    }
}
