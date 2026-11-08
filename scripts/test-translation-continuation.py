"""Exercise the production translation loop with deterministic agent responses."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Lyrics/Pipeline.swift").read_text()
models = source[source.index("struct FormattedLyrics:"):source.index("@MainActor @Observable")]
jobs = source[source.index("    private func updateJob("):source.index("    private var task:")]
start = source[source.index("    func start(song:"):source.index("\n}\n\n\n/// Conservative Mandarin")]
checker = source[source.index("enum MandarinRhyme {"):]
harness = r'''
import Foundation
struct Rhyme: Codable { var words: String; var sound: String; var relatedLines: [Int] }
@MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
@MainActor struct Binding<T> {
    let box: Box<T>
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
}
struct Line {
    var id = UUID()
    var original = "Original"
    var label = ""
    var translated = "Previous"
    var review = "Previous review"
    var approved = false
    var translationTiming: Int?
    var syllables = 0
    var stress = ""
    var comment = ""
}
struct TranslationJob {
    enum State { case running, stopped, failed, completed }
    var id = UUID()
    var title: String
    var instruction: String
    var lineIDs: [UUID]
    var pendingIDs: [UUID]
    var state = State.running
    var status = "Starting"
    var error: String?
    var updated = Date()
    init(title: String, instruction: String, lineIDs: [UUID]) {
        self.title = title; self.instruction = instruction
        self.lineIDs = lineIDs; self.pendingIDs = lineIDs
    }
}
struct Song {
    var lines = [Line(), Line(), Line()]
    var jobs: [TranslationJob] = []
    var direction = "Direction"
    var target = "English"
    var agents = [0, 1, 2, 3, 4]
    mutating func checkpoint(_ title: String) {}
    mutating func setRhymes(_ rhymes: [Rhyme], at index: Int) {}
}
@MainActor final class Pipeline {
    var running = false
    var status = ""
    var error: String?
    var transcript = ""
    var canRetryTranslation = false
    var pendingTranslationIDs: Set<UUID> = []
    var activeInstruction = ""
    var jobID: UUID?
    var jobSong: Binding<Song>?
    var task: Task<Void, Never>?
    var active: Int?
    var turn: UUID?
    var failRhyme = true
    var interruptSecondLine = true
    var cancelAtLastCheck = false
    var calls: [String] = []
    var prompts: [String] = []
    func beginUsage(_ title: String, song: Binding<Song>) {}
    func endUsage() {}
    func ask(_ setting: Int, _ prompt: String, step: String) async throws -> String {
        try Task.checkCancellation()
        calls.append(step); prompts.append(prompt)
        if step == "Direction" { return "Direction" }
        if step == "Rhyme plan" { return #"{"groups":[],"conflicts":[]}"# }
        if step.hasSuffix("Rhythm") {
            if step.hasPrefix("Line 2"), interruptSecondLine {
                interruptSecondLine = false
                throw PipelineError.invalid("Simulated transport failure")
            }
            return #"{"syllables":8,"stress":"01010101","rhymes":[]}"#
        }
        if step.hasSuffix("Rhyme check") {
            if step.hasPrefix("Line 1"), failRhyme {
                if cancelAtLastCheck, calls.filter({ $0 == step }).count == 3 { task?.cancel() }
                return #"{"passes":false,"corrections":"Unresolved embedded voice rhyme","checks":[]}"#
            }
            return #"{"passes":true,"corrections":"Verified","checks":[]}"#
        }
        return "Checked translation"
    }
    func wait() async { await task?.value }
'''
tests = r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let binding = Binding(box: Box(Song()))
        let pipeline = Pipeline()
        let ids = Set(binding.wrappedValue.lines.map(\.id))
        // Existing translations must survive a failed verification.
        pipeline.start(song: binding, retryIDs: ids)
        await pipeline.wait()
        assert(!pipeline.running)
        assert(binding.wrappedValue.lines[0].translated == "Previous")
        assert(binding.wrappedValue.lines[0].review == "Previous review")
        assert(binding.wrappedValue.lines[1].translated == "Checked translation")
        assert(binding.wrappedValue.lines[2].translated == "Checked translation")
        assert(pipeline.calls.filter { $0 == "Line 1 · Rhyme check" }.count == 3,
               "Transport retries must not repeat an exhausted rhyme failure")
        let job = binding.wrappedValue.jobs[0]
        assert(job.state == .failed && job.pendingIDs == [binding.wrappedValue.lines[0].id])
        assert(job.error?.contains("Line 1 needs rhyme review") == true)
        assert(pipeline.canRetryTranslation)
        // Resume retries only unresolved lines and receives the prior failure evidence.
        pipeline.failRhyme = false
        pipeline.calls = []; pipeline.prompts = []
        pipeline.start(song: binding, instruction: job.instruction,
                       retryIDs: Set(job.pendingIDs), jobID: job.id)
        await pipeline.wait()
        assert(binding.wrappedValue.jobs.count == 1)
        assert(binding.wrappedValue.jobs[0].state == .completed)
        assert(binding.wrappedValue.jobs[0].pendingIDs.isEmpty)
        assert(binding.wrappedValue.jobs[0].error == nil)
        assert(!pipeline.calls.contains { $0.hasPrefix("Line 2") || $0.hasPrefix("Line 3") })
        assert(pipeline.prompts.contains { $0.contains("Unresolved embedded voice rhyme") })
        // Cancellation at the failed check must stop before processing the next line.
        let stoppedBinding = Binding(box: Box(Song()))
        let stopped = Pipeline()
        stopped.cancelAtLastCheck = true
        stopped.start(song: stoppedBinding, retryIDs: Set(stoppedBinding.wrappedValue.lines.map(\.id)))
        await stopped.wait()
        assert(!stopped.running)
        assert(stoppedBinding.wrappedValue.jobs[0].state == .stopped)
        assert(stoppedBinding.wrappedValue.jobs[0].pendingIDs.count == 3)
        assert(!stopped.calls.contains { $0.hasPrefix("Line 2") })
        print("Translation continuation, transport retry, resume and cancellation checks passed")
    }
}
'''
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / "checks.swift"
    prelude, pipeline = harness.split("@MainActor final class Pipeline", 1)
    path.write_text(prelude + models + "@MainActor final class Pipeline" + pipeline + jobs + start + tests + checker)
    binary = Path(folder) / "checks"
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path",
                    "/tmp/lyric-translation-test-cache", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
