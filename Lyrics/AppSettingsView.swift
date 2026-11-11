import SwiftUI

@MainActor @Observable final class LocalCacheActivity {
    static let shared = LocalCacheActivity()
    var videoUsers = 0
}

struct AppSettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TabView {
            CacheSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 600, height: 560)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button("Close") { dismissWindow() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct CacheSelection: Identifiable {
    let id = UUID()
    let caches: [LocalCache]
    var file: LocalCacheFile?
    var title: String { file?.url.lastPathComponent ?? (caches.count == 1 ? caches[0].title + " Cache" : "All Caches") }
}

@MainActor private func cacheAvailable(_ cache: LocalCache) -> Bool {
    switch cache {
    case .waveforms: WaveformRecorder.shared.canClearCache
    case .videoFiles, .compiledVideo, .temporaryFiles: LocalCacheActivity.shared.videoUsers == 0
    case .network: true
    }
}

private func cacheSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

private extension LocalCache {
    var tint: Color {
        switch self {
        case .network: .blue
        case .waveforms: .purple
        case .videoFiles: .orange
        case .compiledVideo: .pink
        case .temporaryFiles: .teal
        }
    }
}

private struct CacheIcon: View {
    let cache: LocalCache
    var body: some View {
        Image(systemName: cache.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(cache.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct StorageBar: View {
    let sizes: [(LocalCache, Int64)]
    var body: some View {
        let total = max(sizes.reduce(0) { $0 + $1.1 }, 1)
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(sizes.filter { $0.1 > 0 }, id: \.0) { cache, bytes in
                    Rectangle()
                        .fill(cache.tint.gradient)
                        .frame(width: max(4, (proxy.size.width - 8) * CGFloat(bytes) / CGFloat(total)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct CacheSettingsView: View {
    @State private var files: [LocalCache: [LocalCacheFile]] = [:]
    @State private var networkBytes: Int64 = 0
    @State private var loaded = false
    @State private var refreshing = false
    @State private var selection: CacheSelection?
    @State private var browsing: LocalCache?
    @State private var error: String?
    private func bytes(_ cache: LocalCache) -> Int64 {
        cache == .network ? networkBytes : (files[cache] ?? []).reduce(0) { $0 + $1.bytes }
    }
    private var total: Int64 { LocalCache.allCases.reduce(0) { $0 + bytes($1) } }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loaded ? cacheSize(total) : "Calculating…")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("Local cache on this Mac").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshing)
                        .help("Recalculate cache sizes")
                    }
                    StorageBar(sizes: LocalCache.allCases.map { ($0, loaded ? bytes($0) : 0) })
                    HStack(spacing: 14) {
                        ForEach(LocalCache.allCases) { cache in
                            HStack(spacing: 5) {
                                Circle().fill(cache.tint).frame(width: 7, height: 7)
                                Text(cache.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(LocalCache.allCases) { cache in
                    HStack(spacing: 12) {
                        CacheIcon(cache: cache)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cache.title)
                            Text(cache.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Text(loaded ? cacheSize(bytes(cache)) : "…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if cache != .network {
                            Button { browsing = cache } label: { Image(systemName: "list.bullet") }
                                .buttonStyle(.borderless)
                                .help("Show Files")
                                .disabled(!loaded)
                        }
                        Button("Clear…") { selection = CacheSelection(caches: [cache]) }
                            .disabled(!cacheAvailable(cache) || !loaded || bytes(cache) == 0)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Close video, waveform, and karaoke views before clearing caches that are in use.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear All Caches")
                        Text("Saved documents and videos exported to your chosen location are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear All…", role: .destructive) { selection = CacheSelection(caches: LocalCache.allCases) }
                        .disabled(!LocalCache.allCases.allSatisfy(cacheAvailable) || !loaded || total == 0)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: loaded)
        .task { await refresh() }
        .sheet(item: $selection, onDismiss: { Task { await refresh() } }) { ClearCacheSheet(selection: $0) }
        .sheet(item: $browsing, onDismiss: { Task { await refresh() } }) { cache in
            CacheFileList(cache: cache, files: files[cache] ?? [], refresh: refresh)
        }
        .alert("Unable to Read Cache", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                var result: [LocalCache: [LocalCacheFile]] = [:]
                for cache in LocalCache.allCases { result[cache] = try LocalCacheFiles().files(for: cache) }
                return result
            }.value
            withAnimation {
                files = result
                networkBytes = Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
                loaded = true
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct CacheFileList: View {
    let cache: LocalCache
    @State var files: [LocalCacheFile]
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: CacheSelection?

    init(cache: LocalCache, files: [LocalCacheFile], refresh: @escaping () async -> Void) {
        self.cache = cache
        self._files = State(initialValue: files.sorted { $0.bytes > $1.bytes })
        self.refresh = refresh
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if files.isEmpty {
                        ContentUnavailableView("No Cached Files", systemImage: cache.symbol, description: Text(cache.detail))
                    }
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc").foregroundStyle(cache.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(cacheSize(file.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            Button("Clear…") { selection = CacheSelection(caches: [cache], file: file) }
                                .disabled(!cacheAvailable(cache))
                        }
                    }
                } header: {
                    HStack {
                        CacheIcon(cache: cache)
                        Text("\(files.count) files · \(cacheSize(files.reduce(0) { $0 + $1.bytes }))")
                    }
                } footer: {
                    if !files.isEmpty { Text(cache.detail).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(cache.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(width: 540, height: 480)
        .sheet(item: $selection, onDismiss: reload) { ClearCacheSheet(selection: $0) }
    }

    private func reload() {
        Task {
            let cache = cache
            if let fresh = try? await Task.detached(priority: .utility, operation: { try LocalCacheFiles().files(for: cache) }).value {
                files = fresh.sorted { $0.bytes > $1.bytes }
            }
            await refresh()
        }
    }
}

private struct ClearCacheSheet: View {
    let selection: CacheSelection
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var cleared = false
    @State private var error: String?
    private var available: Bool { selection.caches.allSatisfy(cacheAvailable) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let file = selection.file, let cache = selection.caches.first {
                        HStack(spacing: 12) {
                            CacheIcon(cache: cache)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(cacheSize(file.bytes)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ForEach(selection.caches) { cache in
                            HStack(spacing: 12) {
                                CacheIcon(cache: cache)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cache.title)
                                    Text(cache.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(selection.title)
                } footer: {
                    if !available {
                        Label("Close video, waveform, and karaoke views to clear caches that are in use.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Cached files are removed from this Mac. Saved lyric documents and your exported videos are preserved.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Clear Cache")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear", role: .destructive) { clear() }.disabled(busy || cleared || !available)
                }
            }
        }
        .frame(width: 520, height: 400)
        .interactiveDismissDisabled(busy)
        .overlay {
            if busy || cleared {
                VStack(spacing: 12) {
                    if cleared {
                        Label("Cache Cleared", systemImage: "checkmark.circle.fill")
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    } else { ProgressView("Clearing cache…") }
                }
                .padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .alert("Unable to Clear Cache", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text((error ?? "") + " Some selected caches may already have been cleared.") }
    }

    private func clear() {
        guard available else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let store = LocalCacheFiles()
                let targets = try await Task.detached(priority: .utility) {
                    try selection.caches.filter { $0 != .network && $0 != .waveforms }.map { cache in
                        (cache, try selection.file.map { [$0] } ?? store.files(for: cache))
                    }
                }.value
                guard available else { throw CacheInUseError() }
                // Delete only this snapshot; new video sessions use different temporary paths.
                if selection.caches.contains(.waveforms) { try WaveformRecorder.shared.clearCache(file: selection.file?.url) }
                try await Task.detached(priority: .utility) {
                    for (cache, files) in targets {
                        for file in files { try store.remove(file, from: cache) }
                    }
                    if selection.caches.contains(.network) { URLCache.shared.removeAllCachedResponses() }
                }.value
                cleared = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CacheInUseError: LocalizedError {
    var errorDescription: String? { "Close video, waveform, and karaoke views before clearing these caches." }
}
