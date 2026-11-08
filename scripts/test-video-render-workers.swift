import Foundation

@main struct VideoRenderWorkersTests {
    static func main() {
        let gib: UInt64 = 1024 * 1024 * 1024
        func count(_ selection: Int = 0, _ width: Int = 1920, _ height: Int = 1080,
                   _ cores: Int = 8, _ memory: UInt64 = 16) -> Int {
            VideoRenderWorkers.count(selection: selection, width: width, height: height,
                                     processors: cores, memory: memory * gib)
        }
        precondition(count() == 4)
        precondition(count(0, 3840, 2160) == 2)
        precondition(count(0, 3840, 2160, 12, 32) == 4)
        precondition(count(0, 1920, 1080, 4, 8) == 2)
        precondition(count(0, 1920, 1080, 2, 4) == 1)
        precondition(count(0, 3840, 2160, 1, 0) == 1)
        for selection in [1, 2, 4] { precondition(count(selection) == selection) }
        for staleSelection in [-1, 3, 100] { precondition(count(staleSelection) == 4) }
        print("Video render worker policy: all checks passed")
    }
}
