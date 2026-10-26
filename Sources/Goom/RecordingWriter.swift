import AVFoundation
import ScreenCaptureKit

/// Writes the recording to an MP4 with AVAssetWriter: screen frames (with the camera bubble drawn on
/// top), plus system audio and microphone mixed into a single AAC track.
///
/// SCStream delivers every output on `queue`, and `finish()` hops onto the same queue, so all state is
/// touched serially.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "goom.recording-writer")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let mixer: AudioMixer
    private let compositor: CameraCompositor?
    private var pixelPool: CVPixelBufferPool?
    private var sessionStarted = false
    private let outputSize: CGSize

    init(url: URL, width: Int, height: Int, codec: AVVideoCodecType, frameRate: Int,
         sampleRate: Int, channels: Int, compositor: CameraCompositor?) throws {
        func fail(_ code: Int, _ message: String) -> NSError {
            NSError(domain: "Goom", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Bits per pixel per frame; HEVC reaches the same quality with fewer.
        let bitsPerPixel = codec == .hevc ? 0.06 : 0.1
        func compression(_ codec: AVVideoCodecType) -> [String: Any] {
            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: Int(Double(width * height * frameRate) * bitsPerPixel),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ]
            if codec == .h264 { properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            return properties
        }
        func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression(codec),
            ]
        }
        let chosen = writer.canApply(outputSettings: videoSettings(codec), forMediaType: .video) ? codec : .h264
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(chosen))
        videoInput.expectsMediaDataInRealTime = true

        var audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        // Lower-rate presets keep the encoder's default bitrate, which is always valid for them.
        if sampleRate >= 44_100 { audioSettings[AVEncoderBitRateKey] = 128_000 }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard let mixer = AudioMixer(sampleRate: sampleRate, channels: channels) else {
            throw fail(2, "Unsupported audio format")
        }
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw fail(2, "Can't add the tracks to the writer")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        self.mixer = mixer
        self.compositor = compositor
        outputSize = CGSize(width: width, height: height)
        super.init()

        if compositor != nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelPool)
        }

        guard writer.startWriting() else {
            throw writer.error ?? fail(3, "Can't start writing the file")
        }
    }

    // MARK: - Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen: handleScreen(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, from: .system)
        case .microphone: handleAudio(sampleBuffer, from: .mic)
        @unknown default: break
        }
    }

    private func handleScreen(_ sampleBuffer: CMSampleBuffer) {
        // Idle/blank/suspended frames carry no image; only .complete ones are real content.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        let time = sampleBuffer.presentationTimeStamp
        if !sessionStarted {
            if let buffer = sampleBuffer.imageBuffer {
                let bubble = compositor.map { "\($0.rect), camera frame \($0.feed.frame == nil ? "missing" : "ok")" } ?? "off"
                NSLog("Goom: first frame \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)), "
                      + "writer \(Int(outputSize.width))x\(Int(outputSize.height)), bubble \(bubble)")
            }
            writer.startSession(atSourceTime: time)
            mixer.start(at: time)
            sessionStarted = true
        }
        mixer.advance(to: time)
        writePendingAudio()

        guard videoInput.isReadyForMoreMediaData else { return }
        if let compositor, let screen = sampleBuffer.imageBuffer,
           let pool = pixelPool {
            var composed: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &composed)
            if let composed, compositor.render(screen: screen, into: composed) {
                adaptor.append(composed, withPresentationTime: time)
                return
            }
        }
        videoInput.append(sampleBuffer)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, from source: AudioMixer.Source) {
        guard sessionStarted else { return }
        mixer.add(sampleBuffer, from: source)
        writePendingAudio()
    }

    private func writePendingAudio(final: Bool = false) {
        for chunk in mixer.drain(final: final) {
            guard audioInput.isReadyForMoreMediaData,
                  let sampleBuffer = AudioMixer.sampleBuffer(from: chunk.buffer, at: chunk.time)
            else { continue }
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - Lifecycle

    /// Abandons the file, e.g. when the stream failed to start.
    func cancel() {
        queue.async {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.writer.outputURL)
        }
    }

    /// Finalizes the file. Call after the stream has stopped.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.sessionStarted, self.writer.status == .writing else {
                    // No frame ever arrived (or the writer already failed), so there is nothing to finalize.
                    let error = self.writer.error ?? NSError(
                        domain: "Goom", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "No video frames were captured"])
                    self.writer.cancelWriting()
                    c.resume(throwing: error)
                    return
                }
                self.writePendingAudio(final: true)
                self.videoInput.markAsFinished()
                self.audioInput.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        c.resume()
                    } else {
                        c.resume(throwing: self.writer.error ?? NSError(
                            domain: "Goom", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "The file could not be finalized"]))
                    }
                }
            }
        }
    }
}
