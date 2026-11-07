import SwiftUI

/// Translation runs for this song. Stopped, failed or interrupted runs can be resumed from where they left off.
struct TranslationJobsSheet: View {
    @Binding var song: Song
    let pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: TranslationJob?
    @State private var confirmClear = false

    enum Display { case running, stopped, failed, interrupted, completed }

    private func display(_ job: TranslationJob) -> Display {
        switch job.state {
        case .running: pipeline.running && pipeline.jobID == job.id ? .running : .interrupted
        case .stopped: .stopped
        case .failed: .failed
        case .completed: .completed
        }
    }
    private func remaining(_ job: TranslationJob) -> Int {
        let existing = Set(song.lines.map(\.id))
        return job.pendingIDs.filter { existing.contains($0) }.count
    }
    private func canResume(_ job: TranslationJob) -> Bool {
        display(job) != .running && display(job) != .completed && remaining(job) > 0 && !pipeline.running
    }
    private var finished: [TranslationJob] { song.jobs.filter { display($0) == .completed } }

    var body: some View {
        NavigationStack {
            Group {
                if song.jobs.isEmpty {
                    ContentUnavailableView("No Translation Jobs", systemImage: "list.bullet.clipboard",
                                           description: Text("Each translation run appears here, so a stopped or interrupted one can be resumed."))
                } else {
                    List {
                        ForEach(song.jobs) { job in
                            row(job)
                                .contextMenu {
                                    if canResume(job) { Button("Resume", systemImage: "play.fill") { resume(job) } }
                                    Button("Remove from List", systemImage: "trash", role: .destructive) { pendingRemoval = job }
                                        .disabled(display(job) == .running)
                                }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Translation Jobs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Finished", systemImage: "checkmark.circle.badge.xmark") { confirmClear = true }
                        .disabled(finished.isEmpty)
                        .help("Remove completed jobs from the list")
                }
            }
            .confirmationDialog("Remove this job from the list?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) {
                    if let job = pendingRemoval { song.jobs.removeAll { $0.id == job.id } }
                    pendingRemoval = nil
                }
            } message: { Text("Translations it already made are kept. You can no longer resume it.") }
            .confirmationDialog("Clear \(finished.count) finished job\(finished.count == 1 ? "" : "s")?", isPresented: $confirmClear) {
                Button("Clear Finished", role: .destructive) {
                    let ids = Set(finished.map(\.id))
                    song.jobs.removeAll { ids.contains($0.id) }
                }
            } message: { Text("Translations are kept; only the job records are removed.") }
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
    }

    private func row(_ job: TranslationJob) -> some View {
        let state = display(job)
        let total = max(job.lineIDs.count, 1)
        let done = job.lineIDs.count - remaining(job)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon(state))
                .font(.title2)
                .foregroundStyle(color(state))
                .symbolEffect(.pulse, isActive: state == .running)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(label(state)).font(.caption.weight(.semibold)).foregroundStyle(color(state))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color(state).opacity(0.15), in: Capsule())
                }
                ProgressView(value: Double(done), total: Double(total)).tint(color(state))
                Text("\(done) of \(job.lineIDs.count) line\(job.lineIDs.count == 1 ? "" : "s") translated · \(state == .running ? pipeline.status : job.status)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !job.instruction.isEmpty {
                    Label(job.instruction, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let error = job.error, state == .failed {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Text(job.updated, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            VStack {
                if state == .running {
                    Button("Stop", systemImage: "stop.fill") { pipeline.stop() }
                } else if canResume(job) {
                    Button("Resume", systemImage: "play.fill") { resume(job) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func resume(_ job: TranslationJob) {
        pipeline.resume(job, song: $song)
    }

    private func icon(_ state: Display) -> String {
        switch state {
        case .running: "arrow.triangle.2.circlepath"
        case .stopped: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "bolt.horizontal.circle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }
    private func color(_ state: Display) -> Color {
        switch state {
        case .running: .blue
        case .stopped: .orange
        case .failed: .red
        case .interrupted: .purple
        case .completed: .green
        }
    }
    private func label(_ state: Display) -> String {
        switch state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .completed: "Completed"
        }
    }
}
