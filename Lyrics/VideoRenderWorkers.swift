import Foundation

/// Keep concurrent WebKit pages bounded, especially with large layered artwork at 4K.
enum VideoRenderWorkers {
    static func count(selection: Int, width: Int, height: Int,
                      processors: Int = ProcessInfo.processInfo.activeProcessorCount,
                      memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        if [1, 2, 4].contains(selection) { return selection }
        let gib: UInt64 = 1024 * 1024 * 1024
        let memoryPerWorker: UInt64 = width * height > 1920 * 1080 ? 8 * gib : 4 * gib
        let memoryLimit = Int(min(4, memory / memoryPerWorker))
        return max(1, min(4, processors / 2, memoryLimit))
    }
}
