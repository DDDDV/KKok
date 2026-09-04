import AVFoundation

/// Both paths use Apple's installed decoders; no static codec/extension allowlist.
enum NativeAudioDecoder {
    static func canReadAudioFile(_ url: URL) -> Bool {
        (try? probeAudioFile(url)) != nil
    }

    static func validate(_ url: URL) throws {
        if canReadAudioFile(url) { return }
        let (reader, output) = try assetReader(url)
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(),
              CMSampleBufferGetNumSamples(sample) > 0 else {
            throw AudioPipelineError.unsupportedFormat
        }
        _ = try pcmBuffer(sample)
    }

    private static func probeAudioFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024)
        else { throw AudioPipelineError.emptyAudio }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw AudioPipelineError.emptyAudio }
    }

    static func decodeAsset(_ url: URL, to destination: URL) throws {
        let (reader, output) = try assetReader(url)
        defer { reader.cancelReading() }
        var writer: AVAudioFile?
        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            try autoreleasepool {
                let buffer = try pcmBuffer(sample)
                if writer == nil {
                    writer = try AVAudioFile(
                        forWriting: destination, settings: buffer.format.settings,
                        commonFormat: .pcmFormatFloat32, interleaved: true
                    )
                }
                try writer?.write(from: buffer)
                frames += Int64(buffer.frameLength)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? AudioPipelineError.unsupportedFormat
        }
        guard frames > 0 else { throw AudioPipelineError.emptyAudio }
    }

    private static func assetReader(_ url: URL) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        // Invoked only on the import/separation worker, never the main actor.
        let asset = AVURLAsset(url: url)
        guard !asset.hasProtectedContent,
              let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioPipelineError.unsupportedFormat
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioPipelineError.unsupportedFormat }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioPipelineError.unsupportedFormat
        }
        return (reader, output)
    }

    private static func pcmBuffer(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw AudioPipelineError.unsupportedFormat
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
              ) else { throw AudioPipelineError.unsupportedFormat }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw AudioPipelineError.unsupportedFormat }
        return buffer
    }
}
