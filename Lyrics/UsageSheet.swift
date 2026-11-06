import SwiftUI

/// Token usage and live AI Gateway cost, per agent, per session and per call.
/// Costs are computed on a background task and cached in the document, so reopening is instant
/// and only new calls (or all calls, after prices change) are priced again.
struct UsageSheet: View {
    @Binding var song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var stats: UsageStatsCache?
    @State private var computing = false
    @State private var sessionID: UUID?
    @State private var mode = Mode.agents
    private let pricing = GatewayPricing.shared

    enum Mode: String, CaseIterable, Identifiable { case agents = "Agents", sessions = "Sessions", calls = "Calls"; var id: Self { self } }

    struct Row: Identifiable {
        var id: String
        var title: String
        var detail: String
        var calls = 0
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var cost = 0.0
        var unpriced = 0
        var pending = 0
    }

    var sessions: [UsageSession] { song.usage.sorted { $0.date > $1.date } }
    var selected: [UsageSession] { sessionID.map { id in sessions.filter { $0.id == id } } ?? sessions }
    var records: [(session: UsageSession, record: UsageRecord)] { selected.flatMap { session in session.records.map { (session, $0) } } }

    var body: some View {
        NavigationStack {
            Group {
                if song.usage.isEmpty {
                    ContentUnavailableView("No usage yet", systemImage: "chart.bar.xaxis", description: Text("Token usage is recorded each time agents format or translate lyrics."))
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        summary
                        Picker("View", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                        table
                        footer
                    }.padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Usage & Cost")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Session", selection: $sessionID) {
                        Text("All sessions").tag(UUID?.none)
                        Divider()
                        ForEach(sessions) { session in Text("\(session.title) · \(session.date.formatted(date: .abbreviated, time: .shortened))").tag(UUID?.some(session.id)) }
                    }.pickerStyle(.menu).disabled(song.usage.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh Prices", systemImage: "arrow.clockwise") { Task { await pricing.refresh() } }.disabled(pricing.loading)
                }
            }
        }
        .frame(minWidth: 860, idealWidth: 920, maxWidth: .infinity, minHeight: 640, idealHeight: 720, maxHeight: .infinity)
        .task { await pricing.loadIfNeeded() }
        .task(id: PricingKey(signature: pricing.table.signature, records: song.usage.reduce(0) { $0 + $1.records.count })) { await updateStats() }
        .onChange(of: song.usage.map(\.id)) { _, ids in if let sessionID, !ids.contains(sessionID) { self.sessionID = nil } }
    }

    // MARK: Background pricing

    struct PricingKey: Equatable { var signature: Int; var records: Int }

    var cache: UsageStatsCache { stats ?? song.usageStats ?? UsageStatsCache() }

    /// Prices calls missing from the saved statistics, or every call when gateway prices changed, off the main thread.
    func updateStats() async {
        let table = pricing.table
        guard !table.entries.isEmpty else { return }
        let cached = cache
        let all = song.usage.flatMap(\.records)
        let current = cached.priceSignature == table.signature
        let todo = current ? all.filter { cached.records[$0.id] == nil } : all
        let ids = Set(all.map(\.id))
        let stale = cached.records.keys.contains { !ids.contains($0) }
        guard !todo.isEmpty || stale || !current else { stats = cached; return }
        computing = true
        defer { computing = false }
        let previous = current ? cached.records : [:]
        let records = await Task.detached(priority: .userInitiated) {
            var result = previous.filter { ids.contains($0.key) }
            for record in todo { result[record.id] = table.priced(record) }
            return result
        }.value
        guard !Task.isCancelled else { return }
        var next = UsageStatsCache(priceSignature: table.signature, pricedAt: pricing.fetchedAt, records: records)
        // Keep the old timestamp when nothing changed so the document isn't marked edited for no reason.
        if next.records == song.usageStats?.records, next.priceSignature == song.usageStats?.priceSignature { next.pricedAt = song.usageStats?.pricedAt }
        stats = next
        if song.usageStats != next { song.usageStats = next }
    }

    // MARK: Summary

    var total: Row { aggregate(records.map(\.record), id: "total", title: "Total", detail: "") }

    var summary: some View {
        let total = total
        return HStack(spacing: 12) {
            tile("Total cost", cost(total), systemImage: "dollarsign.circle")
            tile("Input tokens", total.input.formatted(), systemImage: "arrow.down.doc")
            tile("Cached tokens", (total.cacheRead + total.cacheWrite).formatted(), systemImage: "memorychip")
            tile("Output tokens", total.output.formatted(), systemImage: "arrow.up.doc")
            tile("Agent calls", total.calls.formatted(), systemImage: "person.3")
        }
    }

    func tile(_ title: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Tables

    var rows: [Row] {
        switch mode {
        case .agents:
            let groups = Dictionary(grouping: records.map(\.record)) { "\($0.agent)\u{1F}\($0.model)" }
            return groups.map { key, items in
                let first = items[0]
                return aggregate(items, id: key, title: first.agent, detail: modelLabel(first))
            }.sorted { ($0.cost, $0.input + $0.output) > ($1.cost, $1.input + $1.output) }
        case .sessions:
            return selected.map { session in
                aggregate(session.records, id: session.id.uuidString, title: session.title, detail: session.date.formatted(date: .abbreviated, time: .shortened))
            }
        case .calls:
            return records.sorted { $0.record.date > $1.record.date }.map { session, record in
                aggregate([record], id: record.id.uuidString, title: "\(record.agent) · \(record.step)", detail: "\(modelLabel(record)) · \(record.date.formatted(date: .omitted, time: .standard))\(sessionID == nil ? " · \(session.title)" : "")")
            }
        }
    }

    var table: some View {
        Table(rows) {
            TableColumn(mode == .agents ? "Agent" : mode == .sessions ? "Session" : "Call") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.width(min: 220, ideal: 300)
            TableColumn("Calls") { Text($0.calls.formatted()).monospacedDigit() }.width(50)
            TableColumn("Input") { Text($0.input.formatted()).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Cache read") { Text($0.cacheRead.formatted()).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Cache write") { Text($0.cacheWrite.formatted()).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Output") { Text($0.output.formatted()).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Cost (USD)") { row in
                Text(cost(row)).monospacedDigit().foregroundStyle(row.unpriced + row.pending == row.calls ? .secondary : .primary)
                    .help(row.unpriced > 0 ? "\(row.unpriced) call\(row.unpriced == 1 ? "" : "s") without an AI Gateway price are excluded." : "")
            }.width(min: 90, ideal: 110)
        }
    }

    var footer: some View {
        let total = total
        let unpriced = total.unpriced
        return HStack(spacing: 8) {
            if pricing.loading || computing { ProgressView().controlSize(.small) }
            if let error = pricing.error {
                Label("Couldn't load AI Gateway prices: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if computing {
                Text("Calculating costs…")
            } else if let pricedAt = cache.pricedAt ?? pricing.fetchedAt {
                Text("Prices from Vercel AI Gateway · updated \(pricedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Loading Vercel AI Gateway prices…")
            }
            Spacer()
            if unpriced > 0, total.pending == 0 {
                Label("\(unpriced) call\(unpriced == 1 ? "" : "s") not priced (model unknown to AI Gateway)", systemImage: "questionmark.circle")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Helpers

    func aggregate(_ items: [UsageRecord], id: String, title: String, detail: String) -> Row {
        var row = Row(id: id, title: title, detail: detail)
        let priced = cache.records
        for item in items {
            row.calls += 1; row.input += item.input; row.output += item.output
            row.cacheRead += item.cacheRead; row.cacheWrite += item.cacheWrite
            if let entry = priced[item.id] {
                if let cost = entry.cost { row.cost += cost } else { row.unpriced += 1 }
            } else { row.pending += 1 }
        }
        return row
    }

    func modelLabel(_ record: UsageRecord) -> String {
        let model = record.model.isEmpty ? "Provider default" : record.model
        guard let gatewayModel = cache.records[record.id]?.gatewayModel else { return "\(record.provider) · \(model)" }
        return "\(record.provider) · \(gatewayModel)"
    }

    func cost(_ row: Row) -> String {
        if row.calls > 0, row.pending == row.calls { return "…" }
        if row.calls > 0, row.unpriced == row.calls { return "—" }
        return row.cost.formatted(.currency(code: "USD").precision(.fractionLength(row.cost < 1 ? 4 : 2)))
    }
}
