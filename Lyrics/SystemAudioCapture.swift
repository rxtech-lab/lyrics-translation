import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// One captured chunk of audio and its presentation time on the host clock, in seconds.
struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let hostTime: Double
}

/// Records the audio the Mac is playing (including the in-app Apple Music player) with ScreenCaptureKit,
/// so a song streamed from Apple Music can be listened to while it plays. Needs the
/// Screen & System Audio Recording permission, which macOS asks for the first time.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let audio: AsyncStream<CapturedAudio>
    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let queue = DispatchQueue(label: "app.rxlab.LyricStudio.audio-capture", qos: .userInitiated)
    private var stream: SCStream?

    override init() {
        (audio, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    /// Current time on the clock that captured audio is stamped with.
    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw AutoTimingError.capturePermission }
        guard let display = content.displays.first else { throw AutoTimingError.capturePermission }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Audio is all that's needed; keep the video side as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        do { try await stream.startCapture() } catch { throw AutoTimingError.capturePermission }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        var streamDescription = description
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        continuation.yield(CapturedAudio(buffer: buffer, hostTime: sampleBuffer.presentationTimeStamp.seconds))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
    }
}
