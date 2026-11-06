"""Run the production Mandarin checker in isolation with Foundation."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Lyrics/Pipeline.swift").read_text()
types = source[source.index("struct TranslationRhymePlan:"):source.index("struct Analysis:")]
error = source[source.index("enum PipelineError:"):source.index("@MainActor @Observable")]
checker = source[source.index("enum MandarinRhyme {"):]
tests = r"""
func same(_ a: String, _ b: String) {
    assert(MandarinRhyme.final(in: a) != nil)
    assert(MandarinRhyme.final(in: a) == MandarinRhyme.final(in: b), "\(a) / \(b)")
}
same("月光。", "风霜！")
same("自由", "远走")
same("归来", "花开")
same("绿", "雨")
assert(MandarinRhyme.final(in: "事") != MandarinRhyme.final(in: "醒"))
assert(MandarinRhyme.final(in: "醒") != MandarinRhyme.final(in: "偿"))
assert(MandarinRhyme.final(in: "路") != MandarinRhyme.final(in: "绿"))
assert(MandarinRhyme.final(in: "心") != MandarinRhyme.final(in: "星"))
assert(MandarinRhyme.final(in: "星") != MandarinRhyme.final(in: "诗"))
assert(MandarinRhyme.final(in: "") == nil)
assert(MandarinRhyme.final(in: "hello") == nil)
let plan = TranslationRhymePlan(groups: [.init(id: 1, lines: [1, 2], sound: "ang", kind: "end", anchor: "光")], conflicts: [])
func failures(_ candidate: String, _ partner: String, _ pending: Set<Int> = [0], _ target: String = "Chinese") -> [String] {
    MandarinRhyme.failures(candidate: candidate, index: 0, plan: plan, translations: ["", partner], pending: pending, target: target)
}
assert(failures("风霜", "月光").isEmpty)
assert(!failures("提醒", "月光").isEmpty)
assert(!failures("风霜", "提醒").isEmpty)
assert(failures("风霜", "", [0, 1]).isEmpty)
assert(!failures("提醒", "", [0, 1]).isEmpty)
assert(!failures("风霜", "").isEmpty)
assert(failures("hello", "world", [0], "English").isEmpty)
print("Mandarin rhyme regression checks passed")
"""
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / "checks.swift"
    path.write_text("import Foundation\n".replace("\\n", "\n") + types + error + checker + tests)
    subprocess.run(["swift", "-module-cache-path", "/tmp/lyric-rhyme-test-cache", str(path)], check=True)
