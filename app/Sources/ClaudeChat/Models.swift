import Foundation

// MARK: - Pricing

/// Dollars per million tokens. Source: platform.claude.com/docs/en/about-claude/pricing (Oct 2026).
struct Rates: Hashable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double   // 5-minute cache write
}

struct ModelOption: Identifiable, Hashable {
    let id: String           // API model ID
    let name: String
    let blurb: String
    let rates: Rates
    var longPromptRates: Rates? = nil
    var longPromptThreshold: Int? = nil

    /// Estimated dollar cost of one request with this usage.
    func cost(_ u: Usage) -> Double {
        var r = rates
        if let t = longPromptThreshold, let lr = longPromptRates, u.promptTokens > t { r = lr }
        let m = 1_000_000.0
        return Double(u.inputTokens) * r.input / m
             + Double(u.outputTokens) * r.output / m
             + Double(u.cacheReadTokens) * r.cacheRead / m
             + Double(u.cacheWriteTokens) * r.cacheWrite / m
    }

    static let all: [ModelOption] = [
        ModelOption(id: "claude-sonnet-5-5", name: "Sonnet 5.5",
                    blurb: "Smart all-rounder · $2 in / $10 out per million tokens",
                    rates: Rates(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.50)),
        ModelOption(id: "claude-opus-5-5", name: "Opus 5.5",
                    blurb: "Most capable Opus · $4 in / $20 out per million tokens",
                    rates: Rates(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)),
        ModelOption(id: "claude-haiku-5-5", name: "Haiku 5.5",
                    blurb: "Fast and very cheap · $0.10 in / $0.50 out per million tokens",
                    rates: Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
                    longPromptRates: Rates(input: 0.50, output: 2.50, cacheRead: 0.05, cacheWrite: 0.625),
                    longPromptThreshold: 100_000),
        ModelOption(id: "claude-fable-5-1", name: "Fable 5.1",
                    blurb: "Top tier, expensive · $10 in / $50 out per million tokens",
                    rates: Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.50)),
    ]

    static let fallback = all[0]

    static func find(_ id: String) -> ModelOption {
        all.first { $0.id == id }
            ?? ModelOption(id: id, name: id, blurb: "Custom model", rates: fallback.rates)
    }
}

enum Effort: String, CaseIterable, Identifiable, Codable {
    case auto, low, medium, high, max
    var id: String { rawValue }
    var label: String { self == .auto ? "Model default" : rawValue.capitalized }
}

// MARK: - Chat data

struct Usage: Codable, Hashable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var promptTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
}

enum Role: String, Codable {
    case user, assistant
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: Role
    var text: String
    var attachments: [Attachment] = []
    var thinking: String = ""
    var modelID: String? = nil
    var usage: Usage? = nil
    var cost: Double? = nil
    var error: String? = nil
    var date = Date()

    enum CodingKeys: String, CodingKey {
        case id, role, text, attachments, thinking, modelID, usage, cost, error, date
    }
}

extension ChatMessage {
    /// Tolerant decoding so chats saved by older versions (without attachments) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = "New chat"
    var modelID: String
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    // Optional, so chats saved by earlier versions still load.
    var parentID: UUID? = nil          // set on branches
    var presetName: String? = nil
    var systemOverride: String? = nil  // preset instructions, added to the global system prompt
    var effortOverride: Effort? = nil

    var totalCost: Double { messages.compactMap(\.cost).reduce(0, +) }
}

// MARK: - Presets

struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var modelID: String
    var effort: Effort
    var systemPrompt: String

    static let defaults: [Preset] = [
        Preset(name: "Quick answers", symbol: "bolt", modelID: "claude-haiku-5-5", effort: .low,
               systemPrompt: "Answer briefly and directly. No preamble."),
        Preset(name: "Swift code review", symbol: "chevron.left.forwardslash.chevron.right", modelID: "claude-opus-5-5", effort: .high,
               systemPrompt: "You are a senior Swift and macOS engineer. Review code for bugs, crashes, concurrency issues and API misuse first, then style. Show fixes as code."),
        Preset(name: "Writing editor", symbol: "pencil.line", modelID: "claude-sonnet-5-5", effort: .medium,
               systemPrompt: "You are a careful editor. Improve clarity and flow while keeping the author's voice. Show the edited text first, then a short list of what changed."),
        Preset(name: "Explain it simply", symbol: "lightbulb", modelID: "claude-sonnet-5-5", effort: .medium,
               systemPrompt: "Explain things plainly, with a concrete example, as if to a smart friend who is new to the topic."),
    ]
}

// MARK: - Model duel

struct DuelEntry: Identifiable {
    var id: String { modelID }
    let modelID: String
    var text = ""
    var usage: Usage? = nil
    var cost: Double = 0
    var error: String? = nil
    var done = false
}

struct DuelState: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let prompt: String
    let attachments: [Attachment]
    var entries: [DuelEntry]

    var allDone: Bool { entries.allSatisfy(\.done) }
    var total: Double { entries.reduce(0) { $0 + $1.cost } }
}

// MARK: - Batch jobs

struct BatchItem: Codable, Hashable {
    var customID: String
    var conversationID: UUID
    var messageID: UUID
    var modelID: String
}

struct BatchJob: Codable, Identifiable, Hashable {
    var id: String              // msgbatch_… from the API
    var createdAt = Date()
    var items: [BatchItem]
    var title: String
}

struct BatchResult {
    let customID: String
    let text: String?
    let usage: Usage?
    let error: String?
}

// MARK: - Sidebar tree

struct SidebarRow: Identifiable {
    let conversation: Conversation
    let depth: Int
    var id: UUID { conversation.id }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension ModelOption {
    /// Cost of sending `tokens` input tokens at the full (uncached) rate.
    func inputCost(_ tokens: Int) -> Double {
        var r = rates
        if let t = longPromptThreshold, let lr = longPromptRates, tokens > t { r = lr }
        return Double(tokens) * r.input / 1_000_000
    }

    /// The models a duel runs side by side.
    static let duelIDs = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
}

// MARK: - Formatting

enum Fmt {
    static func money(_ v: Double) -> String {
        if v != 0 && abs(v) < 0.01 { return String(format: "$%.4f", v) }
        return String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
