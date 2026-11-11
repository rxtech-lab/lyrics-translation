import Foundation

/// URLSession reports bytes sent from the file without loading the video into memory.
final class VideoUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @MainActor @Sendable (Int64) -> Void

    init(report: @escaping @MainActor @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Task { @MainActor in report(totalBytesSent) }
    }
}
