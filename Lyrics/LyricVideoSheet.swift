import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import RxRemotion
import RxRemotionUI

struct LyricVideoSheet: View {
    let song: Song
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var track: KaraokeTrack = .original
    @State private var engine = RemotionEngine()
    @State private var project: RemotionPreparedProject?
    @State private var session: RemotionPreviewSession?
    @State private var directory: URL?
    @State private var appleMusicPreview = false
    @State private var syncTask: Task<Void, Never>?
    @State private var importing = false
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let session {
                    RemotionPreview(session: session).aspectRatio(16 / 9, contentMode: .fit)
                    HStack {
                        Button("Play", systemImage: "play.fill") { transport { if appleMusicPreview { try await MusicPlayback.shared.play() } else { try await session.play() } } }
                        Button("Pause", systemImage: "pause.fill") { transport { if appleMusicPreview { MusicPlayback.shared.pause() } else { try await session.pause() } } }
                        Button("Restart", systemImage: "backward.end") { transport { if appleMusicPreview { MusicPlayback.shared.seek(to: 0) }; try await session.seek(to: 0) } }
                    }
                    if appleMusicPreview {
                        Text("Apple Music · Preview only").foregroundStyle(.secondary)
                        Button("Import Audio for Export…") { importing = true }
                    }
                } else {
                    ContentUnavailableView("Create a lyric video", systemImage: "film", description: Text("Preview with the linked Apple Music song, or import audio for MP4 export. Every word in the selected track must be timed."))
                    Picker("Lyrics", selection: $track) { ForEach(KaraokeTrack.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 280)
                    if song.appleMusic != nil { Button("Preview with Apple Music", systemImage: "apple.logo") { prepare(nil) } }
                    Button("Import Audio…") { importing = true }
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Lyric Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .primaryAction) { Button("Export MP4…") { export() }.disabled(project == nil || busy || appleMusicPreview) }
            }
            .disabled(busy)
            .overlay {
                if busy {
                    VStack { ProgressView(); Text(status); Button("Cancel") { task?.cancel() } }
                        .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .frame(minWidth: 860, minHeight: 650)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result { case .success(let url): prepare(url); case .failure(let failure): error = failure.localizedDescription }
        }
        .alert("Lyric Video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onDisappear { syncTask?.cancel(); if appleMusicPreview { MusicPlayback.shared.pause() }; task?.cancel(); session?.dispose(); engine.closeAll(); if let directory { try? FileManager.default.removeItem(at: directory) } }
    }

    private func transport(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }

    private func prepare(_ audio: URL?) {
        syncTask?.cancel()
        if appleMusicPreview { MusicPlayback.shared.pause() }
        session?.dispose(); session = nil; project = nil; engine.closeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        appleMusicPreview = false
        busy = true; status = "Preparing video…"
        task = Task { @MainActor in
            defer { busy = false }
            let access = audio?.startAccessingSecurityScopedResource() ?? false
            defer { if access { audio?.stopAccessingSecurityScopedResource() } }
            do {
                let duration: Double
                if let audio {
                    duration = try await AVURLAsset(url: audio).load(.duration).seconds
                } else {
                    guard let recording = song.appleMusic, let length = recording.duration else {
                        throw RemotionError.resource("Choose an Apple Music song with a known duration in Karaoke first.")
                    }
                    try await MusicPlayback.shared.load(recording)
                    MusicPlayback.shared.pause()
                    MusicPlayback.shared.seek(to: 0)
                    duration = length
                }
                guard duration.isFinite, duration > 0 else { throw RemotionError.resource("The audio has no usable duration.") }
                var lines: [[String: Any]] = []
                var previous = 0.0
                for line in song.lines where !line.text(track).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var words: [[String: Any]] = []
                    for word in line.words(track) {
                        guard let start = word.start, let end = word.end, start.isFinite, end.isFinite,
                              start >= previous, end > start, end <= duration else {
                            throw RemotionError.resource("Finish word timing in Karaoke for the selected track. Timings must be ordered and fit inside the recording.")
                        }
                        previous = end
                        words.append(["text": word.text + (word.space ? " " : ""), "start": start, "end": end])
                    }
                    if !words.isEmpty { lines.append(["words": words, "subtitle": line.text(track.other)]) }
                }
                guard !lines.isEmpty else { throw RemotionError.resource("Add and time lyrics before creating a video.") }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LyricVideo-" + UUID().uuidString)
                directory = folder
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("public"), withIntermediateDirectories: true)
                let name = audio.map { "audio." + $0.pathExtension } ?? ""
                if let audio {
                    try await Task.detached { try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent("public/" + name)) }.value
                }
                try Task.checkCancellation()
                let data = try JSONSerialization.data(withJSONObject: ["title": title, "lines": lines, "audio": name, "frames": Int(ceil(duration * 30))], options: [.sortedKeys])
                try data.write(to: folder.appendingPathComponent("src/song.json"))
                try Self.source.write(to: folder.appendingPathComponent("src/index.tsx"), atomically: true, encoding: .utf8)
                let prepared = try await engine.prepare(projectURL: folder, entryPoint: "src/index.tsx")
                let preview = try await engine.makePreviewSession(project: prepared)
                preview.onEvent = { event in if case .error(let message) = event { error = message } }
                try Task.checkCancellation()
                project = prepared; session = preview
                appleMusicPreview = audio == nil
                if appleMusicPreview {
                    // MusicKit owns the clock; never run a second independent video clock.
                    syncTask = Task { @MainActor in
                        do {
                            var lastFrame = -1
                            while !Task.isCancelled {
                                let frame = max(0, min(Int(duration * 30) - 1, Int(MusicPlayback.shared.time * 30)))
                                if frame != lastFrame { try await preview.seek(to: frame); lastFrame = frame }
                                try await Task.sleep(for: .milliseconds(33))
                            }
                        } catch is CancellationError {} catch {
                            MusicPlayback.shared.pause()
                            self.error = error.localizedDescription
                        }
                    }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            if project == nil { engine.closeAll(); if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil }
        }
    }

    private func export() {
        guard let project, !appleMusicPreview else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Lyric Video.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Exporting…"
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try await session?.pause()
                try await engine.renderMovie(project: project, to: url) { progress in
                    status = "\(progress.stage.rawValue.capitalized) \(Int((progress.fraction ?? 0) * 100))%"
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private static let source = #"""
    import React from 'react';
    import {registerRoot, Composition, AbsoluteFill, Audio, staticFile, useCurrentFrame, spring} from 'remotion';
    import song from './song.json';
    const Scene = () => {
      const f = useCurrentFrame(), t = f / 30;
      const line = song.lines.find(l => t >= l.words[0].start && t < l.words[l.words.length-1].end + 0.25);
      const enter = line ? spring({frame: f - Math.floor(line.words[0].start * 30), fps:30, config:{damping:18}}) : 0;
      return <AbsoluteFill style={{background:'#090c20',color:'white',fontFamily:'Arial',padding:80,justifyContent:'center'}}>
        <AbsoluteFill style={{background:`radial-gradient(ellipse at ${40+20*Math.sin(t/4)}% 40%, #40316b, transparent 75%)`}}/>
        <div style={{position:'absolute',top:55,left:80,fontSize:24,letterSpacing:4,color:'#b5aacd'}}>{song.title}</div>
        {line && <div style={{position:'relative',textAlign:'center',opacity:enter,transform:`translateY(${(1-enter)*40}px)`}}>
          <div style={{fontSize:64,fontWeight:800,lineHeight:1.4,whiteSpace:'pre-wrap'}}>{line.words.map((w,i)=><span key={i} style={{color:t>=w.start?'#f5cc78':'#aaa2bd',display:'inline-block',transform:`scale(${t>=w.start&&t<w.end?1.06:1})`}}>{w.text}</span>)}</div>
          <div style={{fontSize:30,color:'#c8c0d8',marginTop:28}}>{line.subtitle}</div>
        </div>}
        {song.audio && <Audio src={staticFile(song.audio)}/>}
      </AbsoluteFill>;
    };
    registerRoot(()=><Composition id="Main" component={Scene} width={1920} height={1080} fps={30} durationInFrames={song.frames}/>);
    """#
}
