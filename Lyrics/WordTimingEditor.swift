import SwiftUI

/// Precise timing for one line: drag word blocks or their edges on a zoomable timeline, type exact times,
/// nudge in milliseconds, set edges at the playhead, and audition a single word or the whole line.
struct WordTimingEditor: View {
    let lineCount: Int
    let text: (Int) -> (text: String, tag: String?)
    let load: (Int) -> [TimedWord]
    let save: (Int, [TimedWord]) -> Void
    let playback: MusicPlayback
    let duration: Double
    var report: (String) -> Void

    @State var line: Int
    @State private var words: [TimedWord] = []
    @State private var original: [TimedWord] = []
    @State private var selection = 0
    @State private var visible: ClosedRange<Double> = 0...5
    @State private var pointsPerSecond: Double = 260
    @State private var drag: DragState?
    @State private var loop = false
    @State private var preroll = 0.5
    @State private var linkEdges = true
    @State private var auditionTask: Task<Void, Never>?
    @State private var confirmRevert = false
    @FocusState private var focused: Bool

    enum Edge { case start, end, both }
    struct DragState { var index: Int; var edge: Edge; var start: Double; var end: Double; var neighbours: [Int: (start: Double, end: Double)] }

    var selected: TimedWord? { words.indices.contains(selection) ? words[selection] : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            wordStrip
            lane
            zoomBar
            Divider()
            inspector
            Divider()
            TransportBar(playback: playback, duration: duration, report: report)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { select(selection - 1); return .handled }
        .onKeyPress(.rightArrow) { select(selection + 1); return .handled }
        .onKeyPress(.return) { auditionWord(); return .handled }
        .onKeyPress(.space) { toggle(); return .handled }
        .onKeyPress("[") { setAtPlayhead(.start); return .handled }
        .onKeyPress("]") { setAtPlayhead(.end); return .handled }
        .onAppear { open(line); focused = true }
        .onDisappear { auditionTask?.cancel() }
        .navigationTitle("Line \(line + 1) Timing")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Previous Line", systemImage: "chevron.up") { open(line - 1) }.disabled(line == 0)
                Button("Next Line", systemImage: "chevron.down") { open(line + 1) }.disabled(line + 1 >= lineCount)
                Menu("More", systemImage: "ellipsis") {
                    Button("Fill Untimed Words", systemImage: "wand.and.stars") { fillLine() }
                    Button("Revert Line…", systemImage: "arrow.uturn.backward") { confirmRevert = true }.disabled(words == original)
                    Divider()
                    Button("Clear Line Timing", systemImage: "eraser", role: .destructive) {
                        words = words.map { TimedWord(text: $0.text, space: $0.space) }; commit(); report("Line timing cleared")
                    }
                }
            }
        }
        .confirmationDialog("Revert this line to how it was when you opened it?", isPresented: $confirmRevert) {
            Button("Revert Line", role: .destructive) { words = original; commit(); fit(); report("Line reverted") }
        }
    }

    // MARK: Sections

    var header: some View {
        let info = text(line)
        return VStack(alignment: .leading, spacing: 4) {
            if let tag = info.tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            Text(info.text).font(.title2.weight(.semibold))
            Text("Drag a word to move it, drag its edges to trim. ← → select · [ ] set start/end at playhead · Return plays the word")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// Every word of the line, including untimed ones, for selection.
    var wordStrip: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(index == selection ? AnyShapeStyle(.white) : word.isTimed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(index == selection ? AnyShapeStyle(.tint) : word.isTimed ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 6))
                    .overlay {
                        if !word.isTimed { RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.secondary) }
                    }
                    .onTapGesture { select(index) }
                    .help(word.isTimed ? "\(stamp(word.start)) – \(stamp(word.end))" : "Not timed · use Set at Playhead")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    /// Timeline that grows with the window: the ruler on top, then a word track filling the remaining height.
    var lane: some View {
        GeometryReader { proxy in
            lane(height: max(130, proxy.size.height - 20))
        }
        .frame(minHeight: 150, maxHeight: .infinity)
    }

    func lane(height: Double) -> some View {
        let width = max(1, (visible.upperBound - visible.lowerBound) * pointsPerSecond)
        let track = height - 30
        return ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Ruler(range: visible, pointsPerSecond: pointsPerSecond).frame(width: width, height: 26)
                Rectangle().fill(.quaternary.opacity(0.35)).frame(width: width, height: track).offset(y: 30)
                    .onTapGesture(coordinateSpace: .local) { point in playback.seek(to: visible.lowerBound + point.x / pointsPerSecond) }
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    if let start = word.start, let end = word.end { block(index, word, start: start, end: end, track: track) }
                }
                TimelineView(.animation) { _ in
                    let x = (playback.time - visible.lowerBound) * pointsPerSecond
                    Rectangle().fill(.red).frame(width: 2, height: height - 4).offset(x: x - 1)
                        .opacity(x >= 0 && x <= width ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .padding(.horizontal, 20)
        }
    }

    func block(_ index: Int, _ word: TimedWord, start: Double, end: Double, track: Double) -> some View {
        let blockHeight = min(140, max(56, track * 0.6))
        let x = (start - visible.lowerBound) * pointsPerSecond
        let width = max(6, (end - start) * pointsPerSecond)
        let isSelected = index == selection
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.35)))
            Text(word.text).font(.callout.weight(.medium)).lineLimit(1).foregroundStyle(isSelected ? .white : .primary).padding(.horizontal, 8)
        }
        .frame(width: width, height: blockHeight)
        .contentShape(.rect)
        .gesture(dragGesture(index, edge: .both))
        .overlay(alignment: .leading) { handle(index, .start, height: blockHeight) }
        .overlay(alignment: .trailing) { handle(index, .end, height: blockHeight) }
        .offset(x: x, y: 30 + (track - blockHeight) / 2)
        .onTapGesture { select(index) }
        .help("\(stamp(start)) – \(stamp(end))")
    }

    func handle(_ index: Int, _ edge: Edge, height: Double) -> some View {
        Rectangle().fill(.white.opacity(index == selection ? 0.9 : 0.4))
            .frame(width: 4, height: min(44, height * 0.5)).clipShape(Capsule()).padding(.horizontal, 2)
            .frame(width: 10, height: height).contentShape(.rect)
            .gesture(dragGesture(index, edge: edge))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    var zoomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $pointsPerSecond, in: 60...1200).frame(width: 200)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("Fit Line", action: fit)
            Button("Close All Gaps") {
                words = TimedWord.closingGaps(words)
                commit()
                report("All gaps in this line closed")
            }
            .disabled(TimedWord.closingGaps(words) == words)
            .help("Extend each timed word to the next word’s start in this line")
            Spacer()
            Toggle("Link touching edges", isOn: $linkEdges).help("Moving one word’s edge also moves the neighbour that touches it")
        }
        .controlSize(.small)
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    @ViewBuilder var inspector: some View {
        if let word = selected {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(word.text).font(.title3.weight(.semibold))
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        edgeRow("Start", .start, value: word.start)
                        edgeRow("End", .end, value: word.end)
                        GridRow {
                            Text("Length").foregroundStyle(.secondary)
                            Text(word.start.flatMap { s in word.end.map { String(format: "%.3f s", $0 - s) } } ?? "—").monospacedDigit()
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    HStack {
                        Button("Play Word", systemImage: "play.circle") { auditionWord() }.disabled(!word.isTimed)
                        Button("Play Line", systemImage: "text.line.first.and.arrowtriangle.forward") { auditionLine() }
                            .disabled(!words.contains(where: \.isTimed))
                        if auditionTask != nil { Button("Stop", systemImage: "stop.fill") { stopAudition() } }
                    }
                    HStack {
                        Toggle("Loop", isOn: $loop)
                        Picker("Lead-in", selection: $preroll) {
                            Text("No lead-in").tag(0.0); Text("0.5 s lead-in").tag(0.5); Text("1 s lead-in").tag(1.0); Text("2 s lead-in").tag(2.0)
                        }
                        .labelsHidden().fixedSize()
                    }
                    Button("Clear Word", systemImage: "eraser", role: .destructive) {
                        words[selection].start = nil; words[selection].end = nil; commit()
                    }
                    .disabled(!word.isTimed)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        } else {
            Text("This line has no words to time.").foregroundStyle(.secondary).padding(20)
        }
    }

    func edgeRow(_ title: String, _ edge: Edge, value: Double?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { if let new = $0 { set(edge, to: new) } }),
                      format: .number.precision(.fractionLength(3)))
                .monospacedDigit().frame(width: 90).textFieldStyle(.roundedBorder)
            HStack(spacing: 2) {
                ForEach([-0.05, -0.01, 0.01, 0.05], id: \.self) { step in
                    Button(step < 0 ? "−\(Int(-step * 1000))" : "+\(Int(step * 1000))") { nudge(edge, by: step) }
                        .monospacedDigit().disabled(value == nil)
                }
                Text("ms").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Button("Set at Playhead", systemImage: "scope") { setAtPlayhead(edge) }.controlSize(.small)
                .help(edge == .start ? "Set the start to the current playback time ( [ )" : "Set the end to the current playback time ( ] )")
        }
    }

    // MARK: Editing

    func open(_ index: Int) {
        guard index >= 0, index < lineCount else { return }
        stopAudition()
        line = index
        words = load(index)
        original = words
        selection = words.firstIndex { !$0.isTimed } ?? 0
        fit()
        focused = true
    }

    func commit() { save(line, words) }

    func select(_ index: Int) {
        guard words.indices.contains(index) else { return }
        selection = index
        focused = true
    }

    /// Fits the timeline to the timed words, or to the playhead when nothing is timed.
    func fit() {
        let times = words.flatMap { [$0.start, $0.end].compactMap { $0 } }
        if let low = times.min(), let high = times.max() {
            visible = max(0, low - 0.75)...(high + 0.75)
            pointsPerSecond = min(1200, max(60, 760 / max(0.5, visible.upperBound - visible.lowerBound)))
        } else {
            let now = playback.time
            visible = max(0, now - 1)...(now + 6)
        }
    }

    /// Makes sure the edited time is visible, extending the timeline when needed.
    func reveal(_ time: Double) {
        if time < visible.lowerBound + 0.2 { visible = max(0, time - 0.75)...visible.upperBound }
        if time > visible.upperBound - 0.2 { visible = visible.lowerBound...(time + 0.75) }
    }

    func set(_ edge: Edge, to value: Double) {
        guard words.indices.contains(selection) else { return }
        let time = max(0, (value * 1000).rounded() / 1000)
        var word = words[selection]
        let oldStart = word.start, oldEnd = word.end
        switch edge {
        case .start:
            word.start = time
            if let end = word.end, end < time + 0.03 { word.end = time + 0.03 }
            if word.end == nil { word.end = nextStart(after: selection).map { max(time + 0.03, $0) } ?? time + 0.4 }
        case .end:
            word.end = time
            if let start = word.start, start > time - 0.03 { word.start = max(0, time - 0.03) }
            if word.start == nil { word.start = max(0, time - 0.4) }
        case .both: break
        }
        words[selection] = word
        if linkEdges { follow(selection, oldStart: oldStart, oldEnd: oldEnd) }
        reveal(time)
        commit()
    }

    func nudge(_ edge: Edge, by step: Double) {
        guard let word = selected, let value = edge == .start ? word.start : word.end else { return }
        set(edge, to: value + step)
    }

    func setAtPlayhead(_ edge: Edge) { set(edge, to: playback.time) }

    func nextStart(after index: Int) -> Double? { words[(index + 1)...].lazy.compactMap(\.start).first }

    /// Moves neighbouring edges that touched the edited word's old edges.
    func follow(_ index: Int, oldStart: Double?, oldEnd: Double?) {
        let word = words[index]
        if index > 0, let oldStart, let newStart = word.start, let previousEnd = words[index - 1].end, abs(previousEnd - oldStart) < 0.02 {
            words[index - 1].end = max((words[index - 1].start ?? 0) + 0.03, newStart)
        }
        if index + 1 < words.count, let oldEnd, let newEnd = word.end, let nextStart = words[index + 1].start, abs(nextStart - oldEnd) < 0.02 {
            words[index + 1].start = min((words[index + 1].end ?? .infinity) - 0.03, newEnd)
        }
    }

    func dragGesture(_ index: Int, edge: Edge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if drag == nil {
                    guard let start = words[index].start, let end = words[index].end else { return }
                    selection = index
                    var neighbours: [Int: (start: Double, end: Double)] = [:]
                    for other in [index - 1, index + 1] where words.indices.contains(other) {
                        if let s = words[other].start, let e = words[other].end { neighbours[other] = (s, e) }
                    }
                    drag = DragState(index: index, edge: edge, start: start, end: end, neighbours: neighbours)
                }
                guard let drag else { return }
                let delta = ((value.translation.width / pointsPerSecond) * 100).rounded() / 100   // snap to 10 ms
                var start = drag.start, end = drag.end
                switch drag.edge {
                case .start: start = min(drag.end - 0.03, max(0, drag.start + delta))
                case .end: end = max(drag.start + 0.03, drag.end + delta)
                case .both: let shift = max(-drag.start, delta); start += shift; end += shift
                }
                words[drag.index].start = start
                words[drag.index].end = end
                if linkEdges {
                    if let previous = drag.neighbours[drag.index - 1], abs(previous.end - drag.start) < 0.02 {
                        words[drag.index - 1].end = max(previous.start + 0.03, start)
                    }
                    if let next = drag.neighbours[drag.index + 1], abs(next.start - drag.end) < 0.02 {
                        words[drag.index + 1].start = min(next.end - 0.03, end)
                    }
                }
            }
            .onEnded { _ in
                guard drag != nil else { return }
                drag = nil
                commit()
            }
    }

    func fillLine() {
        guard words.contains(where: \.isTimed) else { report("Time at least one word of the line first"); return }
        words = AutoTiming.interpolate([words])[0]
        commit(); fit(); report("Untimed words filled")
    }

    // MARK: Audition

    func toggle() {
        stopAudition()
        Task { do { try await playback.toggle() } catch { report("!" + error.localizedDescription) } }
    }

    func auditionWord() {
        guard let word = selected, let start = word.start, let end = word.end else { return }
        audition(from: start, to: end)
    }

    func auditionLine() {
        let ranges = TimedWord.resolve(words).compactMap { $0 }
        guard let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else { return }
        audition(from: start, to: end)
    }

    /// Plays from a little before `from` and pauses just after `to`, repeating while Loop is on.
    func audition(from: Double, to: Double) {
        auditionTask?.cancel()
        auditionTask = Task {
            repeat {
                playback.seek(to: from - preroll)
                do { try await playback.play() } catch { report("!" + error.localizedDescription); break }
                while !Task.isCancelled, playback.isPlaying, playback.time < to + 0.08 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard !Task.isCancelled else { return }
                playback.pause()
                if loop { try? await Task.sleep(for: .milliseconds(350)) }
            } while loop && !Task.isCancelled
            auditionTask = nil
        }
        focused = true
    }

    func stopAudition() {
        guard let task = auditionTask else { return }
        task.cancel()
        auditionTask = nil
        playback.pause()
    }

    func stamp(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? "…" }
}

/// Time ruler with labelled ticks that adapt to the zoom level.
private struct Ruler: View {
    let range: ClosedRange<Double>
    let pointsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            let step: Double = pointsPerSecond > 600 ? 0.05 : pointsPerSecond > 250 ? 0.1 : 0.25
            let labelEvery: Double = pointsPerSecond > 600 ? 0.25 : pointsPerSecond > 250 ? 0.5 : 1
            var time = (range.lowerBound / step).rounded(.up) * step
            while time <= range.upperBound {
                let x = (time - range.lowerBound) * pointsPerSecond
                let major = abs((time / labelEvery).rounded() * labelEvery - time) < step / 2
                context.fill(Path(CGRect(x: x, y: major ? 14 : 20, width: 1, height: major ? 12 : 6)), with: .color(.secondary.opacity(major ? 0.8 : 0.4)))
                if major {
                    context.draw(Text(KaraokeClock.precise(time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                                 at: CGPoint(x: x + 2, y: 6), anchor: .leading)
                }
                time += step
            }
        }
    }
}
