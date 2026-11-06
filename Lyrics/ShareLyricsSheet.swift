import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RxAuthSwift
import RxAuthSwiftUI

@MainActor
struct ShareLyricsSheet: View {
    @Binding var song: Song
    let title: String
    var initialLineIDs: Set<UUID>? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var excerpt = false
    @State private var busy = false
    @State private var loaded = false
    @State private var activity = "Checking publication…"
    @State private var confirmUnpublish = false
    @State private var status: String?
    @State private var sharedURL: URL?
    @State private var copied = false
    @State private var manager: OAuthManager?
    @State private var signInSession: SignInSession?
    private struct SignInSession: Identifiable {
        let id = UUID()
        let manager: OAuthManager
    }
    @State private var signedIn = false
    private let storage = KeychainTokenStorage(serviceName: "app.rxlab.LyricStudio.auth")
    private var server: String {
        Bundle.main.object(forInfoDictionaryKey: "LyricStudioServerURL") as? String ?? ""
    }
    var body: some View {
        Group {
            if let initialLineIDs {
                LyricImageShareSheet(song: song, title: title, publishedURL: sharedURL, initialLineIDs: initialLineIDs)
            } else {
                publicationView
            }
        }
        .task {
            guard initialLineIDs != nil else { return }
            signedIn = storage.getAccessToken() != nil
            if signedIn { await checkPublication() }
        }
    }
    private var publicationView: some View {
        NavigationStack {
            Form {
                Section { header } footer: {
                    if sharedURL == nil {
                        Text("Only publish lyrics you have permission to share. Published translations appear in Discover.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let sharedURL {
                    Section {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Button { copy(sharedURL) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                                    .help("Copy Link")
                                ShareLink(item: sharedURL) { Image(systemName: "square.and.arrow.up") }
                                    .help("Share Link")
                            }
                            .buttonStyle(.borderless)
                        } label: {
                            Label {
                                Text(sharedURL.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            } icon: { Image(systemName: "link").foregroundStyle(.blue) }
                        }
                        Link(destination: sharedURL) {
                            HStack {
                                Label("Open in Browser", systemImage: "safari")
                                Spacer()
                                Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } header: { Text("Public Link") }
                }
                Section {
                    sharedItem("Lyrics & Translation", detail: "\(song.lines.count) lines · \(song.target)", symbol: "text.quote", tint: .blue)
                    if let music = song.appleMusic {
                        sharedItem("Apple Music Recording", detail: "\(music.title) — \(music.artist)", symbol: "music.note", tint: .pink)
                    }
                    if timedLines > 0 {
                        sharedItem("Word Timings", detail: "\(timedLines) timed lines", symbol: "waveform", tint: .orange)
                    }
                    sharedItem("Usage Details", detail: "Token and cost totals per agent", symbol: "chart.bar.fill", tint: .green)
                } header: {
                    Text("What’s Shared")
                } footer: {
                    Label("Private prompts, comments, and revision history stay on your Mac.", systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { excerpt = true } label: {
                        HStack {
                            Label("Share Lyric Lines as Image", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: { Text("Export") } footer: {
                    Text("Pick lines and export them as a PNG card, with a link to the published translation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if sharedURL != nil {
                    Section {
                        Button(role: .destructive) { confirmUnpublish = true } label: {
                            Text("Unpublish Translation").foregroundStyle(.red).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    } footer: {
                        Text("Removes the translation from Discover and disables its public link.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Share Translation")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { primaryAction }
                }
        }
        .frame(minWidth: 580, minHeight: 620)
        .task {
            if song.publicationID == nil { song.publicationID = UUID() }
            signedIn = storage.getAccessToken() != nil
            if signedIn { await checkPublication() }
        }
        .sheet(isPresented: $excerpt) { LyricImageShareSheet(song: song, title: title, publishedURL: sharedURL) }
        .confirmationDialog("Unpublish this translation?", isPresented: $confirmUnpublish) {
            Button("Unpublish", role: .destructive) { Task { await checkPublication(unpublish: true) } }
        } message: { Text("This removes the translation from Discover and disables its public link.") }
        .sheet(item: $signInSession) { session in
            let manager = session.manager
                NavigationStack {
                    RxSignInView(
                        manager: manager,
                        appearance: RxSignInAppearance(title: "Welcome to LyricStudio", subtitle: "Sign in to share your lyric translations.", accentColor: .blue),
                        onAuthSuccess: { signedIn = true; signInSession = nil; Task { await checkPublication() } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Sign In")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signInSession = nil }.disabled(manager.isAuthenticating) } }
                }
                .frame(minWidth: 580, minHeight: 680)
                .interactiveDismissDisabled(manager.isAuthenticating)
        }
        .overlay { if busy { ProgressView(activity).padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .overlay {
            if copied {
                Label("Link Copied", systemImage: "checkmark.circle.fill")
                    .padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .alert("Sharing", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) { Button("OK") { status = nil } } message: { Text(status ?? "") }
    }
    private var displayTitle: String { title.isEmpty ? "Untitled Translation" : title }
    private var timedLines: Int {
        song.lines.filter { !($0.originalTiming ?? []).isEmpty || !($0.translationTiming ?? []).isEmpty }.count
    }
    private var header: some View {
        HStack(spacing: 16) {
            Group {
                if let music = song.appleMusic {
                    Artwork(url: music.artworkURL, size: 72)
                } else {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle).font(.title2.weight(.semibold)).lineLimit(2)
                Text(song.appleMusic.map { "\($0.artist) · \(song.target)" } ?? song.target)
                    .foregroundStyle(.secondary).lineLimit(1)
                statusBadge.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
    private var statusBadge: some View {
        let (text, symbol, tint): (String, String, Color) =
            sharedURL != nil ? ("Published to Discover", "checkmark.seal.fill", .green)
            : !signedIn ? ("Sign in to publish", "person.crop.circle", .secondary)
            : loaded ? ("Not published", "eye.slash", .secondary)
            : ("Status unavailable", "exclamationmark.triangle.fill", .orange)
        return Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
    private func sharedItem(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    @ViewBuilder private var primaryAction: some View {
        if sharedURL != nil {
            Button("Update") { Task { await publish() } }
                .disabled(busy || song.lines.isEmpty)
                .help("Publish your latest changes")
        } else if signedIn && loaded {
            Button("Publish") { Task { await publish() } }
                .buttonStyle(.borderedProminent)
                .disabled(busy || song.lines.isEmpty)
                .help("Only publish lyrics you have permission to share.")
        } else if signedIn {
            Button("Retry") { Task { await checkPublication() } }.disabled(busy)
        } else {
            Button("Sign In") { prepareSignIn() }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        }
    }
    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
    private func prepareSignIn() {
        do { signInSession = SignInSession(manager: try authenticationManager()) }
        catch { status = error.localizedDescription }
    }
    private func authenticationManager() throws -> OAuthManager {
        if let manager { return manager }
        guard let client = Bundle.main.object(forInfoDictionaryKey: "RxAuthClientID") as? String,
              !client.isEmpty, !client.contains("$(") else { throw ShareError.configuration }
        let configuration = RxAuthConfiguration(
            issuer: "https://auth.rxlab.app", clientID: client,
            redirectURI: "lyricstudio://oauth-callback", scopes: ["openid", "read:profile", "read:email"],
            passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
            passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
            passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
            passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
            passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
            passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
            passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
            passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
            passkeyRelyingPartyIdentifier: "rxlab.app",
            keychainServiceName: "app.rxlab.LyricStudio.auth"
        )
        let auth = OAuthManager(configuration: configuration, tokenStorage: storage)
        manager = auth
        return auth
    }
    private func checkPublication(unpublish: Bool = false) async {
        guard !busy, let id = song.publicationID else { return }
        busy = true
        activity = unpublish ? "Unpublishing…" : "Checking publication…"
        defer { busy = false }
        do {
            let auth = try authenticationManager()
            try await auth.refreshTokenIfNeeded()
            guard let token = storage.getAccessToken() else { signedIn = false; loaded = false; sharedURL = nil; return }
            guard let url = URL(string: server + "/api/shares?documentId=" + id.uuidString),
                  url.host != nil else { throw ShareError.configuration }
            var request = URLRequest(url: url)
            request.httpMethod = unpublish ? "DELETE" : "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                signedIn = false; loaded = false; sharedURL = nil
                signInSession = SignInSession(manager: auth)
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ShareError.failed }
            struct Reply: Decodable { let url: URL? }
            sharedURL = try JSONDecoder().decode(Reply.self, from: data).url
            loaded = true
            if unpublish { status = "Translation unpublished." }
        } catch {
            if !unpublish { loaded = false }
            status = error.localizedDescription
        }
    }
    private func publish() async {
        activity = sharedURL == nil ? "Publishing…" : "Updating publication…"
        busy = true; defer { busy = false }
        do {
            guard let client = Bundle.main.object(forInfoDictionaryKey: "RxAuthClientID") as? String, !client.isEmpty, !client.contains("$("), let endpoint = URL(string: server + "/api/shares"), endpoint.host != nil, !server.contains("$("), !server.isEmpty else { throw ShareError.configuration }
            let auth = try authenticationManager()
            guard storage.getAccessToken() != nil else { signedIn = false; signInSession = SignInSession(manager: auth); return }
            if storage.isTokenExpired() {
                do { try await auth.refreshTokenIfNeeded() }
                catch { signedIn = false; signInSession = SignInSession(manager: auth); return }
            }
            guard let token = storage.getAccessToken() else { throw ShareError.configuration }
            let encodedLines = try JSONEncoder().encode(song.lines)
            let lines = try JSONSerialization.jsonObject(with: encodedLines)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let grouped = Dictionary(grouping: song.usage.flatMap(\.records), by: \.agent)
            let usage: [[String: Any]] = grouped.keys.sorted().map { agent in
                let records = grouped[agent]!
                let costs = records.map { song.usageStats?.records[$0.id]?.cost ?? $0.reportedCostUSD }
                return ["agent": agent,
                        "tokens": records.reduce(0) { $0 + $1.input + $1.output },
                        "costUSD": costs.allSatisfy { $0 != nil } ? costs.compactMap { $0 }.reduce(0, +) as Any : NSNull()]
            }
            var document: [String: Any] = ["target": song.target, "lines": lines, "usageSummary": usage]
            if let music = song.appleMusic { document["appleMusic"] = try JSONSerialization.jsonObject(with: encoder.encode(music)) }
            let data = try JSONSerialization.data(withJSONObject: ["documentId": song.publicationID!.uuidString, "title": title.isEmpty ? "Untitled translation" : title, "document": document])
            guard data.count <= 1_000_000 else { throw ShareError.tooLarge }
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (response, result) = try await URLSession.shared.data(for: request)
            if (result as? HTTPURLResponse)?.statusCode == 401 {
                signedIn = false; signInSession = SignInSession(manager: auth); return
            }
            guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw ShareError.failed }
            struct Reply: Decodable { let url: URL }
            sharedURL = try JSONDecoder().decode(Reply.self, from: response).url
            status = "Translation published."
        } catch { status = error.localizedDescription }
    }
    enum ShareError: LocalizedError {
        case configuration, tooLarge, failed
        var errorDescription: String? { switch self { case .configuration: "Configure LyricStudio’s RxAuth client and production website URL before sharing."; case .tooLarge: "This translation exceeds the 1 MB sharing limit."; case .failed: "The sharing request failed. Check your sign-in and server connection, then try again." } }
    }
}

@MainActor
private struct LyricImageShareSheet: View {
    let song: Song
    let title: String
    let publishedURL: URL?
    init(song: Song, title: String, publishedURL: URL?, initialLineIDs: Set<UUID> = []) {
        self.song = song
        self.title = title
        self.publishedURL = publishedURL
        _selected = State(initialValue: Set(song.lines.enumerated().compactMap { initialLineIDs.contains($0.element.id) ? $0.offset : nil }))
    }
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<Int>()
    @State private var error: String?
    @State private var preparing = false
    @State private var saved = false
    var body: some View {
        NavigationStack {
            List(Array(song.lines.enumerated()), id: \.offset) { index, line in
                Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                    VStack(alignment: .leading) { Text(line.original); Text(line.translated).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Share Lyric Lines")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Export PNG", systemImage: "square.and.arrow.up") {
                        Button("Save PNG…", systemImage: "square.and.arrow.down") { share(saveToDisk: true) }
                        Button("Share PNG…", systemImage: "square.and.arrow.up") { share() }
                    }.disabled(selected.isEmpty || preparing)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 620)
        .overlay { if preparing { ProgressView("Preparing image…").padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .overlay {
            if saved {
                Label("PNG saved", systemImage: "checkmark.circle.fill")
                    .padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        saved = false
                    }
            }
        }
        .alert("Unable to export", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func share(saveToDisk: Bool = false) {
        saved = false
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            let indices = selected.sorted()
            let card = SharedLyricArtwork(song: song, title: title, indices: indices)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { error = "Could not render these lines."; return }
            if saveToDisk {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = (title.isEmpty ? "Lyrics" : title.replacingOccurrences(of: "/", with: "-")) + ".png"
                guard let window = NSApp.keyWindow else { error = "No export window is available."; return }
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url, options: .atomic)
                        saved = true
                    } catch { self.error = error.localizedDescription }
                }
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lyrics-\(UUID().uuidString).png")
                try data.write(to: url)
                var items: [Any] = [url]
                if let publishedURL, var components = URLComponents(url: publishedURL, resolvingAgainstBaseURL: false) {
                    components.queryItems = (components.queryItems ?? []).filter { $0.name != "lines" } + [URLQueryItem(name: "lines", value: indices.map { String($0 + 1) }.joined(separator: ","))]
                    if let link = components.url { items.append(link) }
                }
                guard let view = NSApp.keyWindow?.contentView else { error = "No sharing window is available."; return }
                NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Opaque, self-contained artwork so exported images match the website on any background.
private struct SharedLyricArtwork: View {
    let song: Song
    let title: String
    let indices: [Int]
    private let ink = Color(red: 0.94, green: 0.96, blue: 1)
    private let blue = Color(red: 0.61, green: 0.78, blue: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .medium))
                Text("LYRICSTUDIO").font(.system(size: 12, weight: .semibold)).tracking(3)
                Spacer()
                Text(song.target).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(blue.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(blue.opacity(0.25)))
            }
            .foregroundStyle(blue)

            Text(title.isEmpty ? "A song, reimagined." : title)
                .font(.system(size: 46, weight: .medium, design: .serif))
                .tracking(-1.5)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 30) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 34, weight: .regular)).foregroundStyle(blue.opacity(0.65))
                ForEach(indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(song.lines[index].original)
                            .font(.system(size: 29, weight: .medium))
                            .foregroundStyle(ink)
                        if !song.lines[index].translated.isEmpty {
                            Text(song.lines[index].translated)
                                .font(.system(size: 25, weight: .regular))
                                .foregroundStyle(blue)
                        }
                    }
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }

            HStack {
                Rectangle().fill(blue.opacity(0.45)).frame(width: 28, height: 1)
                Text("WORDS ACROSS WORLDS").font(.system(size: 10, weight: .medium)).tracking(2.5)
                Spacer()
                Image(systemName: "sparkle").font(.system(size: 18))
            }
            .foregroundStyle(blue.opacity(0.75))
        }
        .padding(48)
        .frame(width: 720, alignment: .leading)
        .foregroundStyle(ink)
        .background {
            ZStack {
                Color(red: 0.016, green: 0.043, blue: 0.125)
                RadialGradient(colors: [Color(red: 0.12, green: 0.32, blue: 0.57).opacity(0.65), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
                RadialGradient(colors: [Color(red: 0.25, green: 0.17, blue: 0.43).opacity(0.35), .clear], center: .bottomLeading, startRadius: 0, endRadius: 450)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
