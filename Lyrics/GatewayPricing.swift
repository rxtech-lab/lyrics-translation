import Foundation
import Observation

extension AgentSetting {
    /// Model the provider uses when none is chosen, when it can be read locally (Codex `~/.codex/config.toml`).
    var providerDefaultModel: String? {
        guard provider == "Codex" else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break } // only top-level keys
            guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Per-token USD prices for one Vercel AI Gateway model.
struct ModelPrice: Sendable {
    struct Rate: Sendable {
        struct Tier: Sendable { var min: Int; var cost: Double }
        var base: Double
        var tiers: [Tier] = []
        /// Price per token for a call whose prompt is `context` tokens long.
        func perToken(context: Int) -> Double { tiers.last { context >= $0.min }?.cost ?? base }
    }
    var input: Rate
    var output: Rate
    var cacheRead: Rate?
    var cacheWrite: Rate?
}

/// Immutable, thread-safe snapshot of gateway prices with model ids normalised once, so matching is a dictionary lookup.
struct PriceTable: Sendable {
    struct Entry: Sendable { var id: String; var released: Double; var price: ModelPrice }
    let entries: [Entry]
    private let byKey: [String: [Entry]]
    /// Changes whenever any price changes, so cached costs can tell whether they are still current.
    let signature: Int

    init(entries: [Entry] = []) {
        self.entries = entries
        byKey = Dictionary(grouping: entries) { GatewayPricing.normalize($0.id) }
        var hasher = Hasher()
        for entry in entries.sorted(by: { $0.id < $1.id }) {
            hasher.combine(entry.id)
            for rate in [entry.price.input, entry.price.output, entry.price.cacheRead, entry.price.cacheWrite] {
                hasher.combine(rate?.base); for tier in rate?.tiers ?? [] { hasher.combine(tier.min); hasher.combine(tier.cost) }
            }
        }
        signature = entries.isEmpty ? 0 : hasher.finalize()
    }

    /// Gateway model matching what an agent used, preferring the client's own vendor.
    func entry(model: String, provider: String) -> Entry? {
        let key = GatewayPricing.normalize(model)
        guard !key.isEmpty else { return nil }
        let vendor = provider == "Claude Code" ? "anthropic/" : provider == "Codex" ? "openai/" : ""
        if let exact = byKey[key], let hit = exact.first(where: { $0.id.hasPrefix(vendor) }) ?? exact.first { return hit }
        // Aliases such as "opus" or "sonnet" resolve to the newest model of that family.
        let family = key.hasPrefix("claude-") ? key : "claude-\(key)"
        return entries
            .filter { $0.id.hasPrefix("anthropic/\(family)") && !$0.id.hasSuffix("-batch") && !$0.id.hasSuffix("-fast") }
            .max { $0.released < $1.released }
    }

    /// USD cost of a call at these prices, or nil when the model has no gateway price.
    func cost(_ record: UsageRecord, entry: Entry?) -> Double? {
        guard let price = entry?.price else { return nil }
        // Codex (OpenAI) counts cached tokens inside input tokens; Claude and ACP report them separately.
        let inclusive = record.provider == "Codex"
        let fresh = inclusive ? max(0, record.input - record.cacheRead) : record.input
        let context = inclusive ? record.input : record.input + record.cacheRead + record.cacheWrite
        return Double(fresh) * price.input.perToken(context: context)
            + Double(record.output) * price.output.perToken(context: context)
            + Double(record.cacheRead) * (price.cacheRead ?? price.input).perToken(context: context)
            + Double(record.cacheWrite) * (price.cacheWrite ?? price.input).perToken(context: context)
    }

    /// Priced result for one call, as stored in the document.
    func priced(_ record: UsageRecord) -> PricedUsage {
        let entry = entry(model: record.model, provider: record.provider)
        return PricedUsage(cost: cost(record, entry: entry), gatewayModel: entry?.id)
    }
}

/// Live model pricing from Vercel AI Gateway's public model list (no API key required).
@MainActor @Observable final class GatewayPricing {
    static let shared = GatewayPricing()
    typealias Entry = PriceTable.Entry
    private(set) var table = PriceTable()
    private(set) var fetchedAt: Date?
    private(set) var loading = false
    private(set) var error: String?
    private static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v1/models")!

    func loadIfNeeded() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 15 * 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "AI Gateway returned HTTP \(http.statusCode)."])
            }
            // Parsing and normalising hundreds of models is done off the main thread.
            table = try await Task.detached(priority: .userInitiated) { PriceTable(entries: try Self.parse(data)) }.value
            fetchedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func parse(_ data: Data) throws -> [Entry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = root["data"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "AI Gateway pricing has an unexpected format."])
        }
        func number(_ value: Any?) -> Double? {
            if let text = value as? String { return Double(text) }
            return (value as? NSNumber)?.doubleValue
        }
        func rate(_ pricing: [String: Any], _ key: String) -> ModelPrice.Rate? {
            guard let base = number(pricing[key]) else { return nil }
            let tiers = (pricing["\(key)_tiers"] as? [[String: Any]] ?? []).compactMap { tier -> ModelPrice.Rate.Tier? in
                guard let cost = number(tier["cost"]) else { return nil }
                return .init(min: Int(number(tier["min"]) ?? 0), cost: cost)
            }.sorted { $0.min < $1.min }
            return .init(base: base, tiers: tiers)
        }
        return models.compactMap { model in
            guard let id = model["id"] as? String, let pricing = model["pricing"] as? [String: Any],
                  let input = rate(pricing, "input"), let output = rate(pricing, "output") else { return nil }
            let price = ModelPrice(input: input, output: output, cacheRead: rate(pricing, "input_cache_read"), cacheWrite: rate(pricing, "input_cache_write"))
            return Entry(id: id, released: number(model["released"]) ?? number(model["created"]) ?? 0, price: price)
        }
    }

    /// Normalises ids so "claude-opus-5-5", "anthropic/claude-opus-5.5" and "claude-opus-5-5-20260101" compare equal.
    nonisolated static func normalize(_ model: String) -> String {
        var value = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = value.lastIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        if let bracket = value.firstIndex(of: "[") { value = String(value[..<bracket]) }
        value = value.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        value = value.replacing(/-\d{8}$/, with: "").replacing(/-latest$/, with: "")
        return value
    }
}
