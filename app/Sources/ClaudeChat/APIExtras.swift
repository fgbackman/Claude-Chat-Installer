import Foundation

/// Token counting and the Message Batches API (50% off, results within ~an hour).
extension AnthropicClient {
    static let countTokensURL = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
    static let batchesURL = URL(string: "https://api.anthropic.com/v1/messages/batches")!

    static func apiRequest(_ url: URL, method: String = "GET", apiKey: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = body
        }
        return req
    }

    static func checkOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "No response from the API.")
        }
        guard http.statusCode == 200 else {
            throw APIError(message: errorMessage(status: http.statusCode, data: data))
        }
    }

    /// Free. Returns the number of input tokens the request would use.
    static func countTokens(body: Data, apiKey: String) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(for: apiRequest(countTokensURL, method: "POST", apiKey: apiKey, body: body))
        try checkOK(response, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = obj["input_tokens"] as? Int else {
            throw APIError(message: "Unexpected reply from token counting.")
        }
        return n
    }

    /// `payload` is the JSON body {"requests": [...]}. Returns the batch id.
    static func createBatch(payload: Data, apiKey: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: apiRequest(batchesURL, method: "POST", apiKey: apiKey, body: payload))
        try checkOK(response, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String else {
            throw APIError(message: "Unexpected reply when creating the batch.")
        }
        return id
    }

    /// Returns the batch's processing status ("in_progress", "canceling" or "ended") and its results URL once ended.
    static func batchStatus(_ id: String, apiKey: String) async throws -> (status: String, resultsURL: String?) {
        let url = batchesURL.appendingPathComponent(id)
        let (data, response) = try await URLSession.shared.data(for: apiRequest(url, apiKey: apiKey))
        try checkOK(response, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(message: "Unexpected reply when checking the batch.")
        }
        let status = obj["processing_status"] as? String ?? "in_progress"
        return (status, obj["results_url"] as? String)
    }

    /// Downloads and parses the .jsonl results file.
    static func batchResults(_ urlString: String, apiKey: String) async throws -> [BatchResult] {
        guard let url = URL(string: urlString) else {
            throw APIError(message: "The batch results link is invalid.")
        }
        let (data, response) = try await URLSession.shared.data(for: apiRequest(url, apiKey: apiKey))
        try checkOK(response, data)

        var out: [BatchResult] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let customID = obj["custom_id"] as? String,
                  let result = obj["result"] as? [String: Any] else { continue }
            let type = result["type"] as? String ?? ""

            if type == "succeeded", let message = result["message"] as? [String: Any] {
                let blocks = message["content"] as? [[String: Any]] ?? []
                var text = ""
                for b in blocks where (b["type"] as? String) == "text" {
                    text += b["text"] as? String ?? ""
                }
                var usage = Usage()
                if let u = message["usage"] as? [String: Any] { merge(u, into: &usage) }
                out.append(BatchResult(customID: customID, text: text, usage: usage, error: nil))
            } else {
                var detail: String? = nil
                if let e = result["error"] as? [String: Any] {
                    if let inner = e["error"] as? [String: Any] {
                        detail = inner["message"] as? String
                    } else {
                        detail = e["message"] as? String
                    }
                }
                let reason: String
                switch type {
                case "expired": reason = "The batch expired before this request ran (not billed)."
                case "canceled": reason = "This request was canceled (not billed)."
                default: reason = "This request failed (not billed)" + (detail.map { ": \($0)" } ?? ".")
                }
                out.append(BatchResult(customID: customID, text: nil, usage: nil, error: reason))
            }
        }
        return out
    }
}
