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
    /// Words selected alongside the primary `selection`; dragging any selected word moves them all.
    @State private var extraSelection: Set<Int> = []
    /// Time range swept by a rubber-band selection on the empty track.
    @State private var marquee: (from: Double, to: Double, base: Set<Int>)?
    @State private var visible: ClosedRange<Double> = 0...5
    @State private var pointsPerSecond: Double = 260
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var viewportWidth: Double = 800
    @State private var scrollX: Double = 0
    @State private var drag: DragState?
    /// Undo history for this editor. Each entry is a line's words before (undo) or after (redo) a change.
    @State private var undoStack: [Snapshot] = []
    @State private var redoStack: [Snapshot] = []
    /// The words as last saved for the current line, i.e. the "before" state of the next change.
    @State private var committed: [TimedWord] = []
    /// Time the dragged edge is currently snapped to, drawn as a guide on the timeline.
    @State private var snapGuide: Double?
    @State private var loop = false
    @State private var preroll = 0.5
    @State private var linkEdges = true
    @State private var auditionTask: Task<Void, Never>?
    @State private var confirmRevert = false
    @FocusState private var focused: Bool

    enum Edge { case start, end, both }
    struct Snapshot { var line: Int; var words: [TimedWord]; var selection: Int }
    /// `start`/`end` are the dragged span: the word for a trim, or the whole group's bounds for a move.
    struct DragState {
        var index: Int; var edge: Edge; var start: Double; var end: Double
        var group: [Int: (start: Double, end: Double)]
        var neighbours: [Int: (start: Double, end: Double)]
        var snapTargets: [Double]
    }

    /// Distance in points within which a dragged edge snaps to the playhead or another word's edge.
    static let snapDistance: Double = 8

    var selected: TimedWord? { words.indices.contains(selection) ? words[selection] : nil }
    var group: Set<Int> { extraSelection.union([selection]) }
    func isSelected(_ index: Int) -> Bool { index == selection || extraSelection.contains(index) }

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
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // ⌘← / ⌘→ belong to the Previous/Next Line toolbar buttons.
            guard !press.modifiers.contains(.command) else { return .ignored }
            select(selection + (press.key == .leftArrow ? -1 : 1)); return .handled
        }
        .onKeyPress(.return) { auditionWord(); return .handled }
        .onKeyPress(.space) { toggle(); return .handled }
        .onKeyPress("[") { setAtPlayhead(.start); return .handled }
        .onKeyPress("]") { setAtPlayhead(.end); return .handled }
        .onKeyPress(.escape) { extraSelection = []; return .handled }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            extraSelection = Set(words.indices.filter { words[$0].isTimed }).subtracting([selection])
            return .handled
        }
        .onAppear { open(line); focused = true }
        .onDisappear { auditionTask?.cancel() }
        .navigationTitle("Line \(line + 1) Timing")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Window-level shortcuts take precedence over the Edit menu, so ⌘Z undoes timing edits here.
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(undoStack.isEmpty || drag != nil)
                    .help("Undo the last timing change (⌘Z)")
                Button("Redo", systemImage: "arrow.uturn.forward") { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(redoStack.isEmpty || drag != nil)
                    .help("Redo (⇧⌘Z)")
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
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let tag = info.tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                    Text(info.text).font(.title2.weight(.semibold))
                }
                Spacer(minLength: 0)
                lineNavigator
            }
            Text("Drag a word to move it, drag its edges to trim. Drag the empty track or ⇧/⌘-click to select several and move them together. ← → select · ⌘← ⌘→ previous/next line · [ ] set start/end at playhead · Return plays the word")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// Previous/next line buttons, shown in the header because toolbar items don't appear in this sheet.
    var lineNavigator: some View {
        HStack(spacing: 8) {
            Button("Previous Line", systemImage: "chevron.left") { open(line - 1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(line == 0 || drag != nil)
                .help("Previous line (⌘←)")
            Text("\(line + 1) / \(lineCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Next Line", systemImage: "chevron.right") { open(line + 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(line + 1 >= lineCount || drag != nil)
                .help("Next line (⌘→)")
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
    }

    /// Every word of the line, including untimed ones, for selection.
    var wordStrip: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(isSelected(index) ? AnyShapeStyle(.white) : word.isTimed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(isSelected(index) ? (index == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.7))) : word.isTimed ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 6))
                    .overlay {
                        if !word.isTimed { RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.secondary) }
                    }
                    .onTapGesture { select(index, modifiers: NSEvent.modifierFlags) }
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
                Ruler(range: visible, pointsPerSecond: pointsPerSecond, viewport: max(0, scrollX - 20)...max(0, scrollX + viewportWidth)).frame(width: width, height: 26)
                    .contentShape(.rect)
                    .onTapGesture(coordinateSpace: .local) { point in playFrom(visible.lowerBound + point.x / pointsPerSecond) }
                Rectangle().fill(.quaternary.opacity(0.35)).frame(width: width, height: track).offset(y: 30)
                    .onTapGesture(coordinateSpace: .local) { point in playFrom(visible.lowerBound + point.x / pointsPerSecond) }
                    .gesture(marqueeGesture)
                if let marquee {
                    let low = min(marquee.from, marquee.to), high = max(marquee.from, marquee.to)
                    RoundedRectangle(cornerRadius: 4).fill(.tint.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.tint.opacity(0.6), lineWidth: 1) }
                        .frame(width: max(1, (high - low) * pointsPerSecond), height: track)
                        .offset(x: (low - visible.lowerBound) * pointsPerSecond, y: 30)
                        .allowsHitTesting(false)
                }
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    if let start = word.start, let end = word.end { block(index, word, start: start, end: end, track: track) }
                }
                if let snapGuide {
                    Rectangle().fill(.yellow).frame(width: 1.5, height: height - 4)
                        .offset(x: (snapGuide - visible.lowerBound) * pointsPerSecond - 0.75)
                        .allowsHitTesting(false)
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
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            geometry.visibleRect
        } action: { _, rect in
            scrollX = rect.minX
            viewportWidth = rect.width
            // Extend only the right edge; the time origin stays fixed so scrolling never jumps.
            if drag == nil, rect.maxX > width - 200 {
                visible = 0...(visible.upperBound + max(30, rect.width / pointsPerSecond))
            }
        }
        .scrollDisabled(drag != nil)
        .contentShape(.rect)
        .clipped()
    }

    func block(_ index: Int, _ word: TimedWord, start: Double, end: Double, track: Double) -> some View {
        let blockHeight = min(140, max(56, track * 0.6))
        let x = (start - visible.lowerBound) * pointsPerSecond
        let width = max(6, (end - start) * pointsPerSecond)
        let isSelected = isSelected(index)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(isSelected ? (index == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.75))) : AnyShapeStyle(.tint.opacity(0.35)))
            Text(word.text).font(.callout.weight(.medium)).lineLimit(1).foregroundStyle(isSelected ? .white : .primary).padding(.horizontal, 8)
        }
        .frame(width: width, height: blockHeight)
        .contentShape(.rect)
        .gesture(dragGesture(index, edge: .both))
        .overlay(alignment: .leading) { handle(index, .start, height: blockHeight) }
        .overlay(alignment: .trailing) { handle(index, .end, height: blockHeight) }
        .offset(x: x, y: 30 + (track - blockHeight) / 2)
        .onTapGesture { select(index, modifiers: NSEvent.modifierFlags) }
        .help("\(stamp(start)) – \(stamp(end))")
    }

    func handle(_ index: Int, _ edge: Edge, height: Double) -> some View {
        Rectangle().fill(.white.opacity(isSelected(index) ? 0.9 : 0.4))
            .frame(width: 4, height: min(44, height * 0.5)).clipShape(Capsule()).padding(.horizontal, 2)
            .frame(width: 10, height: height).contentShape(.rect)
            .highPriorityGesture(dragGesture(index, edge: edge))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    var zoomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $pointsPerSecond, in: 60...1200).frame(width: 200)
                .disabled(drag != nil)
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(word.text).font(.title3.weight(.semibold))
                        if !extraSelection.isEmpty {
                            Text("+\(extraSelection.count) more selected · drag to move together · Esc to clear")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
        committed = words
        selection = words.firstIndex { !$0.isTimed } ?? 0
        extraSelection = []
        fit()
        focused = true
    }

    /// Saves the line and records the change for undo.
    func commit() {
        guard words != committed else { return }
        undoStack.append(Snapshot(line: line, words: committed, selection: selection))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        committed = words
        save(line, words)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(restore(snapshot))
        report("Undo")
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(restore(snapshot))
        report("Redo")
    }

    /// Applies a snapshot (switching lines if needed) and returns the state it replaced.
    func restore(_ snapshot: Snapshot) -> Snapshot {
        if snapshot.line != line { open(snapshot.line) }
        let replaced = Snapshot(line: line, words: words, selection: selection)
        words = snapshot.words
        committed = snapshot.words
        selection = words.indices.contains(snapshot.selection) ? snapshot.selection : 0
        extraSelection = []
        save(line, words)
        if words.indices.contains(selection), let start = words[selection].start { reveal(start) }
        return replaced
    }

    /// Plain click selects one word; ⇧ extends a range from the current word; ⌘ toggles a word.
    func select(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard words.indices.contains(index) else { return }
        if modifiers.contains(.shift) {
            let range = min(selection, index)...max(selection, index)
            extraSelection.formUnion(range.filter { words[$0].isTimed || $0 == index })
            extraSelection.insert(selection)
            selection = index
            extraSelection.remove(index)
        } else if modifiers.contains(.command) {
            if index == selection {
                if let next = extraSelection.min() { extraSelection.remove(next); selection = next }
            } else if extraSelection.contains(index) {
                extraSelection.remove(index)
            } else {
                extraSelection.insert(selection)
                selection = index
            }
        } else {
            selection = index
            extraSelection = []
        }
        focused = true
    }

    /// Rubber-band selection: sweeping the empty track selects every timed word the band overlaps.
    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                let from = visible.lowerBound + value.startLocation.x / pointsPerSecond
                let to = visible.lowerBound + value.location.x / pointsPerSecond
                if marquee == nil {
                    let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                    marquee = (from, to, additive ? group : [])
                }
                marquee?.to = to
                guard let marquee else { return }
                let low = min(from, to), high = max(from, to)
                let hits = words.indices.filter { index in
                    guard let s = words[index].start, let e = words[index].end else { return false }
                    return s < high && e > low
                }
                let all = marquee.base.union(hits)
                guard let first = hits.first ?? all.min() else { extraSelection = []; return }
                selection = first
                extraSelection = all.subtracting([first])
            }
            .onEnded { _ in marquee = nil; focused = true }
    }

    /// Fit the current line without restricting how far the timeline can scroll.
    func fit() {
        let times = words.flatMap { [$0.start, $0.end].compactMap { $0 } }
        let low = max(0, (times.min() ?? playback.time) - 0.75)
        let high = (times.max() ?? (playback.time + 5)) + 0.75
        pointsPerSecond = min(1200, max(60, max(1, viewportWidth - 40) / max(0.5, high - low)))
        visible = 0...max(duration, high + 30)
        // Wait for the new content width before positioning the scroll view.
        DispatchQueue.main.async {
            scrollPosition.scrollTo(x: low * pointsPerSecond)
        }
    }

    func reveal(_ time: Double) {
        if time > visible.upperBound - 1 { visible = 0...(time + 30) }
        let x = time * pointsPerSecond
        if x < scrollX || x > scrollX + viewportWidth - 40 {
            DispatchQueue.main.async {
                scrollPosition.scrollTo(x: max(0, x - viewportWidth / 2))
            }
        }
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
                    guard words[index].start != nil, words[index].end != nil else { return }
                    // Moving a selected word carries the whole selection; trims and unselected words act alone.
                    let members: Set<Int>
                    if isSelected(index) {
                        members = edge == .both ? group.filter { words[$0].isTimed } : [index]
                        extraSelection = group.subtracting([index])
                    } else {
                        members = [index]
                        extraSelection = []
                    }
                    selection = index
                    var spans: [Int: (start: Double, end: Double)] = [:]
                    for member in members { if let s = words[member].start, let e = words[member].end { spans[member] = (s, e) } }
                    let start = spans.values.map(\.start).min()!, end = spans.values.map(\.end).max()!
                    let low = members.min()!, high = members.max()!
                    var neighbours: [Int: (start: Double, end: Double)] = [:]
                    for other in [low - 1, high + 1] where words.indices.contains(other) && !members.contains(other) {
                        if let s = words[other].start, let e = words[other].end { neighbours[other] = (s, e) }
                    }
                    drag = DragState(index: index, edge: edge, start: start, end: end, group: spans, neighbours: neighbours,
                                     snapTargets: snapTargets(excluding: Set(spans.keys), start: start, end: end))
                }
                // Only the gesture that began this edit may update it. A trim handle
                // and its enclosing word can otherwise compete for the same drag.
                guard let drag, drag.index == index, drag.edge == edge else { return }
                let delta = ((value.translation.width / pointsPerSecond) * 100).rounded() / 100   // snap to 10 ms
                var start = drag.start, end = drag.end
                switch drag.edge {
                case .start: start = min(drag.end - 0.03, max(0, drag.start + delta))
                case .end: end = max(drag.start + 0.03, drag.end + delta)
                case .both: let shift = max(-drag.start, delta); start += shift; end += shift
                }
                // Snap to the playhead or a neighbouring word's edge when close enough.
                let threshold = Self.snapDistance / pointsPerSecond
                func nearest(_ value: Double) -> Double? {
                    drag.snapTargets.min { abs($0 - value) < abs($1 - value) }.flatMap { abs($0 - value) <= threshold ? $0 : nil }
                }
                var guide: Double?
                switch drag.edge {
                case .start:
                    if let target = nearest(start), target <= drag.end - 0.03 { start = target; guide = target }
                case .end:
                    if let target = nearest(end), target >= drag.start + 0.03 { end = target; guide = target }
                case .both:
                    let length = drag.end - drag.start
                    let byStart = nearest(start).map { ($0 - start, $0) }
                    let byEnd = nearest(end).map { ($0 - end, $0) }
                    if let best = [byStart, byEnd].compactMap({ $0 }).min(by: { abs($0.0) < abs($1.0) }), start + best.0 >= 0 {
                        start += best.0; end = start + length; guide = best.1
                    }
                }
                if guide != snapGuide {
                    if guide != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    snapGuide = guide
                }
                if drag.edge == .both {
                    let shift = start - drag.start
                    for (member, span) in drag.group {
                        words[member].start = span.start + shift
                        words[member].end = span.end + shift
                    }
                } else {
                    words[drag.index].start = start
                    words[drag.index].end = end
                }
                if linkEdges {
                    let low = drag.group.keys.min()!, high = drag.group.keys.max()!
                    if let previous = drag.neighbours[low - 1], abs(previous.end - drag.start) < 0.02 {
                        words[low - 1].end = max(previous.start + 0.03, start)
                    }
                    if let next = drag.neighbours[high + 1], abs(next.start - drag.end) < 0.02 {
                        words[high + 1].start = min(next.end - 0.03, end)
                    }
                }
            }
            .onEnded { _ in
                guard let active = drag, active.index == index, active.edge == edge else { return }
                drag = nil
                snapGuide = nil
                commit()
            }
    }

    /// Edges a drag can snap to: the playhead and every other word's edges, except the edges of
    /// neighbours that are linked to the dragged word (those move with it).
    func snapTargets(excluding members: Set<Int>, start: Double, end: Double) -> [Double] {
        var targets = [playback.time]
        let low = members.min() ?? 0, high = members.max() ?? 0
        for (other, word) in words.enumerated() where !members.contains(other) {
            if let s = word.start, !(linkEdges && other == high + 1 && abs(s - end) < 0.02) { targets.append(s) }
            if let e = word.end, !(linkEdges && other == low - 1 && abs(e - start) < 0.02) { targets.append(e) }
        }
        return targets
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

    /// Clicking the ruler or empty track moves the playhead there and starts playing.
    func playFrom(_ seconds: Double) {
        auditionTask?.cancel(); auditionTask = nil
        playback.seek(to: max(0, seconds))
        guard !playback.isPlaying else { return }
        Task { do { try await playback.play() } catch { report("!" + error.localizedDescription) } }
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
    let viewport: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let step: Double = pointsPerSecond > 600 ? 0.05 : pointsPerSecond > 250 ? 0.1 : 0.25
            let labelEvery: Double = pointsPerSecond > 600 ? 0.25 : pointsPerSecond > 250 ? 0.5 : 1
            let first = max(range.lowerBound, range.lowerBound + viewport.lowerBound / pointsPerSecond)
            let last = min(range.upperBound, range.lowerBound + viewport.upperBound / pointsPerSecond)
            var time = (first / step).rounded(.up) * step
            while time <= last {
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
