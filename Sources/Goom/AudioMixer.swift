import AVFoundation

/// Mixes system audio and microphone buffers into one continuous PCM stream.
///
/// Each source is placed on a shared timeline by presentation timestamp (relative to the first video
/// frame), so gaps become silence and the two sources stay in sync with the video. The timeline is
/// also advanced by video timestamps, which keeps the output continuous even if no audio is playing.
///
/// Not thread-safe: call from a single serial queue.
final class AudioMixer {
    enum Source { case system, mic }

    let format: AVAudioFormat
    private let sampleRate: Double
    private let channels: Int
    /// How far behind the newest data the output trails, so a slightly late source still lands in time.
    private let latencyFrames: Int
    /// Timestamps this close to the previous buffer's end are treated as contiguous (avoids clicks).
    private let toleranceFrames: Int

    private var base = CMTime.invalid
    private var accum: [[Float]]
    private var accumStart = 0      // timeline frame index of accum[0]
    private var newest = 0          // furthest timeline index seen
    private var nextExpected: [Source: Int] = [:]
    private var converters: [Source: (converter: AVAudioConverter, input: AVAudioFormat)] = [:]

    init?(sampleRate: Int, channels: Int) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))
        else { return nil }
        self.format = format
        self.sampleRate = Double(sampleRate)
        self.channels = channels
        latencyFrames = sampleRate / 4
        toleranceFrames = sampleRate / 50
        accum = Array(repeating: [], count: channels)
    }

    /// Fixes timeline zero. Audio before this time is discarded.
    func start(at base: CMTime) {
        self.base = base
    }

    func advance(to time: CMTime) {
        guard base.isValid else { return }
        newest = max(newest, index(of: time))
    }

    func add(_ sampleBuffer: CMSampleBuffer, from source: Source) {
        guard base.isValid,
              let input = Self.pcm(from: sampleBuffer),
              let pcm = convert(input, source: source),
              pcm.frameLength > 0, let data = pcm.floatChannelData
        else { return }

        var start = index(of: sampleBuffer.presentationTimeStamp)
        if let expected = nextExpected[source], abs(start - expected) <= toleranceFrames { start = expected }
        let frames = Int(pcm.frameLength)
        nextExpected[source] = start + frames
        newest = max(newest, start + frames)

        // Drop the part that lies before the timeline start or was already emitted.
        let skip = max(0, accumStart - start)
        guard skip < frames else { return }
        let offset = start + skip - accumStart
        let count = frames - skip
        let needed = offset + count
        let sourceChannels = Int(pcm.format.channelCount)
        for ch in 0..<channels {
            if accum[ch].count < needed { accum[ch].append(contentsOf: repeatElement(0, count: needed - accum[ch].count)) }
            let src = data[min(ch, sourceChannels - 1)]
            accum[ch].withUnsafeMutableBufferPointer { dst in
                for i in 0..<count { dst[offset + i] += src[skip + i] }
            }
        }
    }

    /// Returns mixed audio that is ready to be written. With `final`, flushes everything.
    func drain(final: Bool = false) -> [(buffer: AVAudioPCMBuffer, time: CMTime)] {
        guard base.isValid else { return [] }
        var out: [(buffer: AVAudioPCMBuffer, time: CMTime)] = []
        let limit = final ? newest : newest - latencyFrames
        let chunk = 4096
        while limit - accumStart >= (final ? 1 : chunk) {
            let count = min(chunk, limit - accumStart)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            for ch in 0..<channels {
                let available = min(count, accum[ch].count)
                for i in 0..<available { data[ch][i] = max(-1, min(1, accum[ch][i])) }
                for i in available..<count { data[ch][i] = 0 }
                accum[ch].removeFirst(available)
            }
            let time = CMTimeAdd(base, CMTime(value: CMTimeValue(accumStart), timescale: CMTimeScale(sampleRate)))
            accumStart += count
            out.append((buffer: buffer, time: time))
        }
        return out
    }

    // MARK: - Helpers

    private func index(of time: CMTime) -> Int {
        Int((CMTimeGetSeconds(CMTimeSubtract(time, base)) * sampleRate).rounded())
    }

    private func convert(_ input: AVAudioPCMBuffer, source: Source) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converters[source]?.input != input.format {
            guard let c = AVAudioConverter(from: input.format, to: format) else { return nil }
            converters[source] = (c, input.format)
        }
        guard let converter = converters[source]?.converter else { return nil }

        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }

    static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Wraps PCM in a CMSampleBuffer so AVAssetWriterInput can encode it.
    static func sampleBuffer(from pcm: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description
        else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: CMItemCount(pcm.frameLength),
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer
        else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sampleBuffer
    }
}
