import SwiftUI
import AppKit
import RxRemotion
import RxRemotionUI

/// A rendered karaoke preview of the open song, made by the lyric video sheet with its lyrics, timings and audio.
struct KaraokePreviewBuild {
    let session: RemotionPreviewSession
    let folder: URL
    /// Where playback starts: just before the first sung line.
    let start: Double
}
typealias KaraokePreviewBuilder = @MainActor (KaraokeVideoStyle, RemotionEngine) async throws -> KaraokePreviewBuild

/// Settings for the built-in karaoke lyric video: a fixed backdrop with a word-by-word color wipe.
/// Saved inside the video as src/karaoke.json, which the template reads.
struct KaraokeVideoStyle: Codable, Equatable {
    enum Background: String, Codable, CaseIterable, Identifiable {
        case solid, gradient, greenScreen
        var id: Self { self }
        var label: String {
            switch self {
            case .solid: "Solid Color"
            case .gradient: "Gradient"
            case .greenScreen: "Green Screen"
            }
        }
    }

    enum Layout: String, Codable, CaseIterable, Identifiable {
        /// One lyric at a time in a fixed, vertically centered position.
        case oneRow
        /// Up to two current lines at a time, centered.
        case single
        /// Lines alternate between an upper and a lower place.
        case double
        /// The live-lyrics view from the app and the web: the list scrolls up past a focus line.
        case scroll
        var id: Self { self }
        var label: String {
            switch self {
            case .oneRow: "One Row"
            case .single: "Show"
            case .double: "Two Lines"
            case .scroll: "Scroll"
            }
        }
    }

    enum Alignment: String, Codable, CaseIterable, Identifiable {
        case staggered, left, center, right
        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    var background = Background.gradient
    var solidColor = "#141B33"
    var gradientStart = "#121A33"
    var gradientEnd = "#2E4C7C"
    var gradientAngle = 45.0
    var screenColor = "#00FF00"
    var sungColor = "#FFFFFF"
    var unsungColor = "#7F8DA8"
    var font = "Helvetica Neue"
    var originalSize = 88.0
    var translationSize = 52.0
    var speakerSize = 30.0
    var layout = Layout.single
    var alignment = Alignment.staggered
    var showSpeaker = true
    var shadow = true
    /// Size of a line sung over an earlier one, in percent of the regular size.
    var overlapScale = 70.0

    static let fonts = ["Helvetica Neue", "SF Pro Display", "Avenir Next", "Futura", "Gill Sans", "DIN Alternate",
                        "Optima", "Georgia", "Didot", "PingFang SC", "Hiragino Sans", "Menlo"]
    static let fileName = "karaoke.json"
    static let agentName = "Karaoke"
    private static let storageKey = "karaokeVideoStyle"

    var styleLabel: String { "Karaoke · \(background.label) — word-by-word color wipe" }

    /// Files of a saved karaoke video: the template plus these settings.
    func files() throws -> [String: String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return ["video.tsx": Self.template, Self.fileName: json]
    }

    /// The settings of a saved karaoke video, or nil for director or built-in videos.
    static func from(_ script: LyricVideoScript) -> KaraokeVideoStyle? {
        guard let json = script.files?[fileName] else { return nil }
        return try? JSONDecoder().decode(KaraokeVideoStyle.self, from: Data(json.utf8))
    }

    /// The most recently used settings, as the starting point for a new karaoke video.
    static func load() -> KaraokeVideoStyle {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let style = try? JSONDecoder().decode(KaraokeVideoStyle.self, from: data) else { return KaraokeVideoStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    private enum CodingKeys: String, CodingKey {
        case background, solidColor, gradientStart, gradientEnd, gradientAngle, screenColor, sungColor, unsungColor, font,
             originalSize, translationSize, speakerSize, layout, alignment, showSpeaker, shadow, overlapScale
    }

    /// Settings saved by an earlier version lack newer keys; those keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let base = KaraokeVideoStyle()
        background = value(.background, base.background); solidColor = value(.solidColor, base.solidColor)
        gradientStart = value(.gradientStart, base.gradientStart); gradientEnd = value(.gradientEnd, base.gradientEnd)
        gradientAngle = value(.gradientAngle, base.gradientAngle); screenColor = value(.screenColor, base.screenColor)
        sungColor = value(.sungColor, base.sungColor); unsungColor = value(.unsungColor, base.unsungColor)
        font = value(.font, base.font); originalSize = value(.originalSize, base.originalSize)
        translationSize = value(.translationSize, base.translationSize); speakerSize = value(.speakerSize, base.speakerSize)
        layout = value(.layout, base.layout); alignment = value(.alignment, base.alignment)
        showSpeaker = value(.showSpeaker, base.showSpeaker); shadow = value(.shadow, base.shadow)
        overlapScale = value(.overlapScale, base.overlapScale)
    }

    init() {}

    /// Deterministic karaoke template; every value it varies comes from karaoke.json.
    private static let template = #"""
    // Style: Karaoke — fixed backdrop with a word-by-word color wipe.
    import React, {memo, useLayoutEffect, useMemo, useRef, useState} from 'react';
    import {AbsoluteFill, Audio, staticFile, useCurrentFrame, interpolate, Easing, delayRender, continueRender} from 'remotion';
    import song from './song.json';
    import style from './karaoke.json';

    const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
    const lines = song.lines ?? [];
    const font = `'${style.font}', 'Helvetica Neue', 'PingFang SC', 'PingFang TC', 'Hiragino Sans', 'Apple SD Gothic Neo', sans-serif`;
    const margin = 150, maxWidth = 1920 - margin * 2, fade = 0.25, lead = 0.5;
    const layout = style.layout ?? 'single';
    const smaller = Math.min(1, Math.max(0.3, (style.overlapScale ?? 70) / 100));

    const background = style.background === 'greenScreen' ? style.screenColor
      : style.background === 'solid' ? style.solidColor
      : `linear-gradient(${style.gradientAngle}deg, ${style.gradientStart}, ${style.gradientEnd})`;
    const sizeOf = (track) => track === 'translation' ? style.translationSize : style.originalSize;
    const estimate = (text, size) => {
      let width = 0;
      for (const c of Array.from(text ?? '')) {
        const code = c.codePointAt(0) ?? 0;
        width += code >= 0x2e80 ? 1 : c === ' ' ? 0.28 : 0.6;
      }
      return width * size;
    };

    // Singers alternate sides by first appearance, as in the app and on the web.
    const speakers = [];
    for (const line of lines) if (line.speaker && !speakers.includes(line.speaker)) speakers.push(line.speaker);
    // A line sung together with an earlier one (overlapping it by a second, or half its own length when shorter)
    // is drawn smaller, like backing vocals. Brief handoffs between lines don't count.
    const joined = lines.map((line, i) => {
      const needed = Math.min(1, (line.end - line.start) * 0.5);
      return lines.some((other, j) => j < i && Math.min(line.end, other.end) - Math.max(line.start, other.start) >= needed);
    });
    // Lines whose timings overlap are shown together, stacked in the order they start.
    const groups = [];
    lines.forEach((line, i) => {
      const last = groups[groups.length - 1];
      if (last && line.start < last.end) { last.items.push(i); last.end = Math.max(last.end, line.end); }
      else groups.push({start: line.start, end: line.end, items: [i]});
    });
    const groupOf = lines.map(() => 0);
    groups.forEach((group, g) => group.items.forEach(i => { groupOf[i] = g; }));

    // Show windows: an item waits for the previous item in its place to finish, then fades in early.
    const windows = (spans, previous, early) => {
      const plan = spans.map(span => ({show: span.start - early, hide: span.end + 0.5}));
      spans.forEach((span, i) => {
        const j = previous(i);
        if (j < 0) return;
        plan[i].show = Math.min(Math.max(plan[i].show, spans[j].end + 0.1), span.start - 0.15);
        plan[j].hide = Math.min(plan[j].hide, Math.max(plan[i].show + fade, spans[j].end + 0.05));
      });
      return plan;
    };
    const fadeOf = (p, t) => Math.min(interpolate(t, [p.show, p.show + fade], [0, 1], clamp), interpolate(t, [p.hide - fade, p.hide], [1, 0], clamp));

    const wordFill = (w, t) => w.end > w.start ? interpolate(t, [w.start, w.end], [0, 100], clamp) : t >= w.start ? 100 : 0;
    const Word = memo(({w, t}) => {
      const body = w.text.replace(/\s+$/, '');
      const gap = w.text.slice(body.length);
      const fill = wordFill(w, t);
      const color = fill >= 100 ? style.sungColor : style.unsungColor;
      return <>
        <span style={{display: 'inline-block', whiteSpace: 'pre',
          backgroundImage: fill > 0 && fill < 100 ? `linear-gradient(90deg, ${style.sungColor} ${fill}%, ${style.unsungColor} ${fill}%)` : undefined,
          WebkitBackgroundClip: 'text', backgroundClip: 'text', color: fill > 0 && fill < 100 ? 'transparent' : color,
          WebkitTextFillColor: fill > 0 && fill < 100 ? 'transparent' : color}}>{body}</span>
        {gap ? <span style={{whiteSpace: 'pre'}}>{gap}</span> : null}
      </>;
    }, (a, b) => a.w === b.w && wordFill(a.w, a.t) === wordFill(b.w, b.t));

    /// align: main rows; last: the final wrapped row; meta: speaker name and the line underneath.
    const alignment = (i, side) => {
      const line = lines[i];
      const size = sizeOf(line.track) * (joined[i] ? smaller : 1);
      if (side) return {align: side, last: side, meta: side};
      const align = style.alignment;
      if (align !== 'staggered') return {align, last: align, meta: align};
      return {align: 'left', last: estimate(line.text, size) > maxWidth ? 'right' : 'left', meta: 'right'};
    };
    const speakerSide = (i) => {
      const speaker = lines[i].speaker;
      if (!speaker) return null;
      return speakers.indexOf(speaker) % 2 === 1 ? 'right' : style.alignment === 'right' ? 'right' : 'left';
    };

    // Offscreen, upcoming and completed lyrics do not need their word tree rebuilt at 60 fps.
    const inkRanges = lines.map(line => ({
      start: Math.min(...(line.words ?? []).map(w => w.start)),
      end: Math.max(...(line.words ?? []).map(w => Math.max(w.start, w.end)))
    }));
    const sameInk = (i, a, b) => a === b || (a < inkRanges[i].start && b < inkRanges[i].start)
      || (a >= inkRanges[i].end && b >= inkRanges[i].end);
    const Line = memo(({i, t, side}) => {
      const line = lines[i];
      const scale = joined[i] ? smaller : 1;
      const size = sizeOf(line.track) * scale;
      const subtitleSize = sizeOf(line.track === 'translation' ? 'original' : 'translation') * scale;
      const {align, last, meta} = alignment(i, side);
      return <div data-line={i} style={{width: '100%', filter: style.shadow ? 'drop-shadow(0 4px 14px rgba(0,0,0,0.4))' : undefined}}>
        {style.showSpeaker && line.speaker ? <div style={{fontSize: style.speakerSize * scale, fontWeight: 500, color: style.unsungColor,
          textAlign: meta, marginBottom: size * 0.25}}>{line.speaker}</div> : null}
        <div style={{fontSize: size, fontWeight: 700, lineHeight: 1.22, textAlign: align, textAlignLast: last}}>
          {(line.words ?? []).map((w, j) => <Word key={j} w={w} t={t}/>)}
        </div>
        {line.subtitle ? <div style={{fontSize: subtitleSize, fontWeight: 600, lineHeight: 1.3, color: style.unsungColor,
          textAlign: meta, marginTop: size * 0.3}}>{line.subtitle}</div> : null}
      </div>;
    }, (a, b) => a.i === b.i && a.side === b.side && sameInk(a.i, a.t, b.t));

    // SHOW: overlapping timing groups can span a whole verse through chained overlaps.
    // Keep the selected number of visible lines, retiring each line after its own end.
    const showPlan = windows(groups, i => i - 1, 1);
    const rowCount = layout === 'oneRow' ? 1 : 2;
    const rowPlan = lines.map((line, i) => ({
      show: Math.max(showPlan[groupOf[i]].show, line.start - 1),
      hide: Math.min(showPlan[groupOf[i]].hide, line.end + 0.5)
    }));
    // Each line owns a fixed slot and side throughout its lifetime. Fade it out before
    // the next occupant arrives, rather than moving survivors when the row count changes.
    rowPlan.forEach((p, i) => {
      if (i + rowCount < rowPlan.length) p.hide = Math.min(p.hide, rowPlan[i + rowCount].show);
    });
    const showRowsAt = (t) => rowPlan.flatMap((p, i) => t >= p.show && t < p.hide ? [i] : []);
    const ShowStage = ({t}) => {
      const rows = showRowsAt(t);
      return <div style={{position: 'absolute', left: margin, right: margin, top: 60, height: 960}}>
          {rows.map(i => {
            const opacity = fadeOf(rowPlan[i], t);
            return <div key={i} style={{position: 'absolute', top: rowCount === 1 ? 0 : (i % 2 === 0 ? 0 : 500),
              height: rowCount === 1 ? 960 : 460, width: '100%',
              display: 'flex', flexDirection: 'column', justifyContent: 'center', opacity,
              transform: `translate3d(0, ${interpolate(opacity, [0, 1], [16, 0])}px, 0)`, willChange: 'transform, opacity'}}>
              <Line i={i} t={t} side={style.alignment === 'staggered' ? speakerSide(i) : null}/>
            </div>;
          })}
      </div>;
    };

    // TWO LINES: lines alternate between an upper and a lower place, the next line showing early.
    const doublePlan = windows(lines, i => i - 2, 4);
    const DoubleStage = ({t}) => {
      const slots = [[], []];
      doublePlan.forEach((p, i) => {
        if (t < p.show || t > p.hide) return;
        const opacity = fadeOf(p, t);
        const side = style.alignment === 'staggered' ? (i % 2 === 0 ? 'left' : 'right') : null;
        slots[i % 2].push(<div key={i} style={{gridArea: '1 / 1', opacity, transform: `translateY(${interpolate(opacity, [0, 1], [16, 0])}px)`}}>
          <Line i={i} t={t} side={side}/>
        </div>);
      });
      const regions = [{top: 60, justifyContent: 'flex-end'}, {top: 560, justifyContent: 'flex-start'}];
      return <>{regions.map((region, slot) => <div key={slot} style={{position: 'absolute', left: margin, right: margin, top: region.top,
        height: 460, display: 'flex', flexDirection: 'column', justifyContent: region.justifyContent}}>
        <div style={{display: 'grid', width: '100%'}}>{slots[slot]}</div>
      </div>)}</>;
    };

    // SCROLL: the live-lyrics view — the focus line sits 30% from the top and the list glides up,
    // groups below it following with a short cascade.
    const focusPoint = 1080 * 0.3;
    const focusAt = (t) => {
      const current = lines.findIndex(line => line.start <= t + lead && t < line.end);
      if (current >= 0) return current;
      let last = 0;
      lines.forEach((line, i) => { if (line.start <= t + lead) last = i; });
      return last;
    };
    // Focus only changes when a line comes into focus or ends.
    const changes = (() => {
      const times = [...new Set(lines.flatMap(line => [line.start - lead, line.end]))].sort((a, b) => a - b);
      const result = [];
      let focus = focusAt(-Infinity);
      for (const time of times) {
        const next = focusAt(time + 1e-4);
        if (next !== focus) { result.push({time, focus: next}); focus = next; }
      }
      return result;
    })();
    const glide = Easing.bezier(0.2, 0.8, 0.2, 1);
    const scrollAt = (moves, t, initial) => {
      let y = initial;
      for (const move of moves) {
        if (move.time > t) break;
        y = move.from + (move.to - move.from) * glide(Math.min(1, (t - move.time) / 0.6));
      }
      return y;
    };
    const ScrollStage = ({t}) => {
      const column = useRef(null);
      const [handle] = useState(() => delayRender('Measuring lyric rows'));
      const [tops, setTops] = useState(null);
      useLayoutEffect(() => {
        const node = column.current;
        if (node) {
          // Measure in the 1920×1080 design space, whatever zoom the output size applies.
          const box = node.getBoundingClientRect();
          const zoom = box.width / maxWidth || 1;
          const measured = lines.map(() => 0);
          node.querySelectorAll('[data-line]').forEach(element => {
            measured[Number(element.getAttribute('data-line'))] = (element.getBoundingClientRect().top - box.top) / zoom;
          });
          setTops(measured);
        }
        continueRender(handle);
      }, [handle]);
      const moves = useMemo(() => {
        if (!tops) return [];
        const result = [];
        for (const change of changes) {
          const from = scrollAt(result, change.time, tops[0] ?? 0);
          const to = tops[change.focus] ?? 0;
          if (Math.abs(to - from) > 0.5) result.push({time: change.time, from, to});
        }
        return result;
      }, [tops]);
      const focusGroup = groupOf[focusAt(t)] ?? 0;
      return <AbsoluteFill style={{maskImage: 'linear-gradient(transparent, #000 12%, #000 85%, transparent)',
        WebkitMaskImage: 'linear-gradient(transparent, #000 12%, #000 85%, transparent)'}}>
        <div ref={column} style={{position: 'absolute', left: margin, width: maxWidth, top: 0}}>
          {groups.map((group, g) => {
            const delay = Math.min(0.3, Math.max(0, g - focusGroup) * 0.05);
            const y = tops ? focusPoint - scrollAt(moves, t - delay, tops[0] ?? 0) : focusPoint;
            return <div key={g} style={{display: 'flex', flexDirection: 'column', gap: 14, marginBottom: 36, transform: `translateY(${y}px)`}}>
              {group.items.map(i => {
                const line = lines[i];
                const opacity = t < line.end ? interpolate(t, [line.start - lead - 0.5, line.start - lead], [0.6, 1], clamp)
                  : interpolate(t, [line.end, line.end + 0.5], [1, 0.3], clamp);
                return <div key={i} style={{opacity}}><Line i={i} t={t} side={speakerSide(i)}/></div>;
              })}
            </div>;
          })}
        </div>
      </AbsoluteFill>;
    };

    export const Video = () => {
      const frame = useCurrentFrame(), t = frame / song.fps;
      return <AbsoluteFill style={{background, fontFamily: font, overflow: 'hidden'}}>
        {layout === 'scroll' ? <ScrollStage t={t}/> : layout === 'double' ? <DoubleStage t={t}/> : <ShowStage t={t}/>}
        {song.audio ? <Audio src={staticFile(song.audio)}/> : null}
      </AbsoluteFill>;
    };
    """#
}

/// Background, typography and layout settings for a karaoke lyric video.
struct KaraokeVideoStyleSheet: View {
    let editing: Bool
    /// Silent preview: Apple Music only plays in the main video preview.
    let silent: Bool
    let makePreview: KaraokePreviewBuilder
    let apply: (KaraokeVideoStyle) -> Void
    @State private var style: KaraokeVideoStyle
    @State private var engine = RemotionEngine()
    @State private var preview: KaraokePreviewBuild?
    @State private var rendering = false
    @State private var previewError: String?
    @Environment(\.dismiss) private var dismiss

    init(style: KaraokeVideoStyle, editing: Bool, silent: Bool, makePreview: @escaping KaraokePreviewBuilder,
         apply: @escaping (KaraokeVideoStyle) -> Void) {
        self.editing = editing
        self.silent = silent
        self.makePreview = makePreview
        self.apply = apply
        _style = State(initialValue: style)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                previewColumn
                Divider()
                settingsForm
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Karaoke Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { style = KaraokeVideoStyle() }
                        .help("Restore the default karaoke style")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "Apply" : "Create Video") {
                        let chosen = style
                        chosen.save()
                        dismiss()
                        apply(chosen)
                    }
                }
            }
        }
        .frame(minWidth: 1040, idealWidth: 1120, minHeight: 680, idealHeight: 760)
        .task(id: style) {
            // Let sliders and color wells settle before rebuilding the preview.
            if preview != nil { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
        .onDisappear {
            preview?.session.dispose()
            engine.closeAll()
            if let folder = preview?.folder { try? FileManager.default.removeItem(at: folder) }
            preview = nil
        }
    }

    /// Renders the song with the current settings, keeping the playback position and play state.
    private func rebuildPreview() async {
        rendering = true
        defer { if !Task.isCancelled { rendering = false } }
        let old = preview
        do {
            let new = try await makePreview(style, engine)
            guard !Task.isCancelled else { discard(new); return }
            let fps = Double(new.session.composition?.fps ?? 30)
            let frame = old?.session.frame ?? Int(new.start * fps)
            let playing = old?.session.playing ?? false
            if let old { try? await old.session.pause(); discard(old) }
            preview = new
            previewError = nil
            try await new.session.seek(to: frame)
            if playing { try await new.session.play() }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { previewError = error.localizedDescription }
        }
    }

    private func discard(_ build: KaraokePreviewBuild) {
        build.session.dispose()
        engine.close(projectURL: build.folder)
        try? FileManager.default.removeItem(at: build.folder)
    }

    private func transport(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { previewError = error.localizedDescription } }
    }

    /// Stays in view while the settings on the right scroll.
    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview").font(.headline)
            ZStack {
                Color.black
                if let preview { RemotionPreview(session: preview.session) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if rendering {
                    ProgressView("Updating preview…")
                        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let session = preview?.session {
                HStack(spacing: 12) {
                    Button(session.playing ? "Pause" : "Play", systemImage: session.playing ? "pause.fill" : "play.fill") {
                        transport { if session.playing { try await session.pause() } else { try await session.play() } }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).font(.title3)
                    .keyboardShortcut(.space, modifiers: [])
                    VideoTimeline(session: session) { frame in transport { try await session.seek(to: frame) } }
                }
            }
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text(silent ? "Your song's lyrics and timings with the chosen settings. The preview is silent while Apple Music is the audio source; choose an audio file to hear it."
                        : "Your song with its lyrics, timings and audio, rendered with the chosen settings exactly as the export will look.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.4))
    }

    private var settingsForm: some View {
            Form {
                Section("Background") {
                    Picker("Background", selection: $style.background) {
                        ForEach(KaraokeVideoStyle.Background.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch style.background {
                    case .solid:
                        ColorPicker("Color", selection: color(\.solidColor), supportsOpacity: false)
                    case .gradient:
                        ColorPicker("Start color", selection: color(\.gradientStart), supportsOpacity: false)
                        ColorPicker("End color", selection: color(\.gradientEnd), supportsOpacity: false)
                        LabeledContent("Angle") {
                            Slider(value: $style.gradientAngle, in: 0...360, step: 15) { Text("Angle") }
                                .labelsHidden()
                            Text("\(Int(style.gradientAngle))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    case .greenScreen:
                        ColorPicker("Key color", selection: color(\.screenColor), supportsOpacity: false)
                        Text("Key out this color in your video editor to place the lyrics over other footage. Turn off the text shadow for the cleanest key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Text") {
                    Picker("Font", selection: $style.font) {
                        ForEach(KaraokeVideoStyle.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                    }
                    ColorPicker("Sung color", selection: color(\.sungColor), supportsOpacity: false)
                    ColorPicker("Unsung color", selection: color(\.unsungColor), supportsOpacity: false)
                    Toggle("Text shadow", isOn: $style.shadow)
                }
                Section {
                    sizeRow("Original text", value: $style.originalSize, range: 32...160)
                    sizeRow("Translation text", value: $style.translationSize, range: 24...140)
                    sizeRow("Speaker name", value: $style.speakerSize, range: 16...80)
                    LabeledContent("Overlapping line") {
                        Slider(value: $style.overlapScale, in: 40...100, step: 5) { Text("Overlapping line") }.labelsHidden()
                        Text("\(Int(style.overlapScale))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                } header: { Text("Font Sizes") } footer: {
                    Text("Sizes are in points on a 1920×1080 frame and scale with the export resolution. The timed line uses its own language's size; the line underneath uses the other. A line sung over an earlier one for at least a second is drawn at the overlapping-line size, like backing vocals.")
                }
                Section("Layout") {
                    Picker("Style", selection: $style.layout) {
                        ForEach(KaraokeVideoStyle.Layout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(layoutSummary).font(.caption).foregroundStyle(.secondary)
                    Picker("Alignment", selection: $style.alignment) {
                        ForEach(KaraokeVideoStyle.Alignment.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show speaker names", isOn: $style.showSpeaker)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var layoutSummary: String {
        switch style.layout {
        case .oneRow: "One lyric row at a time, vertically centered. Each line fades out before the next appears."
        case .single: "Up to two lyric rows in fixed positions. Each singer keeps the same side as lines fade in and out."
        case .double: "Lines alternate between the upper and lower half, with the next line shown early."
        case .scroll: "Like live lyrics in the app and on the web: the whole lyric list scrolls up, with the current line near the top. Singers alternate sides."
        }
    }

    private func sizeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range, step: 2) { Text(title) }.labelsHidden()
            Text("\(Int(value.wrappedValue)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func color(_ keyPath: WritableKeyPath<KaraokeVideoStyle, String>) -> Binding<Color> {
        Binding(get: { Color(karaokeHex: style[keyPath: keyPath]) },
                set: { style[keyPath: keyPath] = $0.karaokeHex })
    }
}

extension Color {
    init(karaokeHex hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var karaokeHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
