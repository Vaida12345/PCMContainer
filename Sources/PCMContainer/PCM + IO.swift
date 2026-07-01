//
//  PCM + IO.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import MultiArray
@preconcurrency import AVFoundation
import FinderItem


/// Common audio file formats supported by `PCMContainer.write(to:as:)`.
public enum AudioFileFormat: Sendable, Equatable {
    /// Waveform Audio File Format containing 32-bit floating-point linear PCM samples.
    case wav
    /// Audio Interchange File Format containing 32-bit floating-point linear PCM samples.
    case aiff
    /// Core Audio Format containing 32-bit floating-point linear PCM samples.
    case caf
    /// MPEG-4 AAC in an `.m4a` container.
    case aac
    /// Apple Lossless Audio Codec in an `.m4a` container using the specified source bit depth.
    case alac(bitDepth: Int = 24)

    /// Returns the `AVAudioFile` settings dictionary for this output format.
    ///
    /// - Parameters:
    ///   - sampleRate: Output sample rate, in hertz.
    ///   - channelCount: Number of audio channels to write.
    public func settings(sampleRate: Double, channelCount: Int) -> [String: Any] {
        switch self {
        case .wav:
            Self.linearPCMSettings(sampleRate: sampleRate, channelCount: channelCount, isBigEndian: false)
        case .aiff:
            Self.linearPCMSettings(sampleRate: sampleRate, channelCount: channelCount, isBigEndian: true)
        case .caf:
            Self.linearPCMSettings(sampleRate: sampleRate, channelCount: channelCount, isBigEndian: false)
        case .aac:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
            ]
        case .alac(let bitDepth):
            [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitDepthHintKey: bitDepth,
            ]
        }
    }

    /// Returns common linear PCM settings for uncompressed file containers.
    private static func linearPCMSettings(
        sampleRate: Double,
        channelCount: Int,
        isBigEndian: Bool
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: isBigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

extension PCMContainer {
    
    /// Error thrown by `init(from:)` and `write(to:as:)`.
    public enum ReadError: Error {
        case assetReaderError
        case converterUnavailable
        case conversionFailed
        case formatUnavailable
        case noAudioTrack
    }
    
    
    /// The number of float samples stored in `content`.
    @inlinable
    public var sampleCount: Int {
        guard !self.content.shape.isEmpty else { return 0 }
        return self.content.shape.reduce(1, *)
    }
    
    /// Reads and decodes the source audio to timeline-correct float PCM for all channels.
    ///
    /// Decoding uses `AVAssetReader` sample buffers so presentation timestamps, edit-list
    /// trimming, and gaps are reflected in the returned `[channel, frame]` samples.
    ///
    /// - Parameters:
    ///   - source: Audio file to decode.
    ///   - sampleRate: If specified, the output PCM is decoded at this sample rate.
    public init(
        from source: FinderItem,
        sampleRate: Double? = nil
    ) async throws {
        let inputFile = try AVAudioFile(forReading: source.url)
        let inFormat = inputFile.processingFormat
        let resolvedSampleRate = sampleRate ?? inFormat.sampleRate
        let channelCount = Int(inFormat.channelCount)

        let result = try await Self.decodeTimelineCorrectPCM(
            from: source.url,
            sampleRate: resolvedSampleRate,
            channelCount: channelCount
        )
        
        self.content = result
        self.sampleRate = resolvedSampleRate
    }

    /// Writes `self` to `destination` using the requested audio file format.
    ///
    /// The destination file extension should match the selected format, such as `.wav`, `.aiff`,
    /// `.caf`, or `.m4a`. Lossy formats such as AAC do not preserve samples exactly.
    ///
    /// - Parameters:
    ///   - destination: File to create or overwrite.
    ///   - outputFormat: Audio file encoding and container settings to use.
    public func write(to destination: FinderItem, as outputFormat: AudioFileFormat = .wav) async throws {
        let channelCount = self.channelCount
        let frameCount = self.content.shape[1]
        let settings = outputFormat.settings(sampleRate: sampleRate, channelCount: channelCount)
        let file = try AVAudioFile(
            forWriting: destination.url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw ReadError.formatUnavailable
        }
        buffer.frameLength = buffer.frameCapacity
        try Self.copyContent(from: self.content, to: buffer)

        try file.write(from: buffer)
    }
    
}

// MARK: - write
private extension PCMContainer {
    /// Copies channel-major PCM storage into an `AVAudioPCMBuffer`.
    static func copyContent(from content: MultiArray<Float>, to buffer: AVAudioPCMBuffer) throws {
        let channelCount = content.shape[0]
        let frameCount = content.shape[1]
        guard let channelData = buffer.floatChannelData else { throw ReadError.formatUnavailable }

        if buffer.format.isInterleaved {
            let destination = channelData[0]
            var frame = 0
            while frame < frameCount {
                let base = frame &* channelCount
                var channel = 0
                while channel < channelCount {
                    (destination + (base &+ channel)).initialize(to: content[channel, frame])
                    channel &+= 1
                }
                frame &+= 1
            }
        } else {
            for channel in 0..<channelCount {
                memcpy(channelData[channel], content.pointer(channel), frameCount * MemoryLayout<Float>.stride)
            }
        }
    }
}

// MARK: - read
private extension PCMContainer {
    /// Decodes audio through `AVAssetReader` and places each buffer on its output timeline.
    static func decodeTimelineCorrectPCM(
        from url: URL,
        sampleRate: Double,
        channelCount: Int
    ) async throws -> MultiArray<Float> {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { throw ReadError.noAudioTrack }
        let assetDuration = try await asset.load(.duration)
        let estimatedFrameCount = Self.outputFrameIndex(for: assetDuration, sampleRate: sampleRate)

        let useNonInterleavedOutput = channelCount <= 2
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: useNonInterleavedOutput,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReadError.assetReaderError }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadError.assetReaderError }

        var content = MultiArray<Float>.zeros(channelCount, max(0, estimatedFrameCount))
        var decodedFrameCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0 else { continue }

            let trimStart = Self.trimFrameCount(
                in: sampleBuffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                sampleRate: sampleRate
            )
            let trimEnd = Self.trimFrameCount(
                in: sampleBuffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                sampleRate: sampleRate
            )
            let validSourceStart = min(sampleCount, trimStart)
            let validSourceEnd = max(validSourceStart, sampleCount - trimEnd)
            let validFrameCount = validSourceEnd - validSourceStart
            guard validFrameCount > 0 else { continue }

            let presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let startFrame = Self.outputFrameIndex(for: presentationTime, sampleRate: sampleRate)
            let destinationStart = max(0, startFrame)
            let clippedLeadingFrameCount = max(0, -startFrame)
            guard clippedLeadingFrameCount < validFrameCount else { continue }

            let sourceOffset = validSourceStart + clippedLeadingFrameCount
            let copiedFrameCount = validFrameCount - clippedLeadingFrameCount
            let requiredFrameCount = destinationStart + copiedFrameCount
            Self.ensureFrameCapacity(requiredFrameCount, in: &content)

            try sampleBuffer.withAudioBufferList(flags: [.audioBufferListAssure16ByteAlignment]) { bufferList, _ in
                try Self.copySamples(
                    from: bufferList,
                    sourceOffset: sourceOffset,
                    frameCount: copiedFrameCount,
                    destinationStart: destinationStart,
                    channelCount: channelCount,
                    into: &content
                )
            }
            decodedFrameCount = max(decodedFrameCount, requiredFrameCount)
        }

        guard reader.status == .completed else { throw reader.error ?? ReadError.assetReaderError }

        return Self.resized(content, frameCount: decodedFrameCount)
    }

    /// Extends decoded storage to contain at least `frameCount` frames, preserving existing samples.
    static func ensureFrameCapacity(_ frameCount: Int, in content: inout MultiArray<Float>) {
        guard frameCount > content.shape[1] else { return }

        let channelCount = content.shape[0]
        let oldFrameCount = content.shape[1]
        let expanded = MultiArray<Float>.zeros(channelCount, frameCount)
        guard oldFrameCount > 0 else {
            content = expanded
            return
        }

        for channel in 0..<channelCount {
            _ = memcpy(
                expanded.pointer(channel),
                content.pointer(channel),
                oldFrameCount * MemoryLayout<Float>.stride
            )
        }
        content = expanded
    }

    /// Returns a copy of decoded storage containing exactly `frameCount` frames.
    static func resized(_ content: MultiArray<Float>, frameCount: Int) -> MultiArray<Float> {
        guard frameCount != content.shape[1] else { return content }

        let channelCount = content.shape[0]
        let resized = MultiArray<Float>.zeros(channelCount, max(0, frameCount))
        let copiedFrameCount = min(content.shape[1], resized.shape[1])
        guard copiedFrameCount > 0 else { return resized }

        for channel in 0..<channelCount {
            _ = memcpy(
                resized.pointer(channel),
                content.pointer(channel),
                copiedFrameCount * MemoryLayout<Float>.stride
            )
        }
        return resized
    }

    /// Converts a Core Media time to the nearest output PCM frame index.
    static func outputFrameIndex(for time: CMTime, sampleRate: Double) -> Int {
        guard time.isValid && !time.isIndefinite && time.seconds.isFinite else { return 0 }
        return Int((time.seconds * sampleRate).rounded())
    }

    /// Reads a sample-buffer trim attachment and converts it to frames at the output sample rate.
    static func trimFrameCount(in sampleBuffer: CMSampleBuffer, key: CFString, sampleRate: Double) -> Int {
        guard let attachment = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil),
              CFGetTypeID(attachment) == CFDictionaryGetTypeID() else {
            return 0
        }

        let dictionary = unsafeDowncast(attachment, to: CFDictionary.self)
        let time = CMTimeMakeFromDictionary(dictionary)
        return max(0, Self.outputFrameIndex(for: time, sampleRate: sampleRate))
    }

    /// Copies a bounded Float32 frame range from a decoded sample buffer into channel-major PCM storage.
    static func copySamples(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        sourceOffset: Int,
        frameCount: Int,
        destinationStart: Int,
        channelCount: Int,
        into content: inout MultiArray<Float>
    ) throws {
        guard bufferList.count > 0 else { throw ReadError.conversionFailed }
        guard frameCount > 0 else { return }

        if bufferList.count == channelCount {
            for channel in 0..<channelCount {
                guard let source = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else {
                    throw ReadError.conversionFailed
                }
                _ = memcpy(
                    content.pointer(channel) + destinationStart,
                    source + sourceOffset,
                    frameCount * MemoryLayout<Float>.stride
                )
            }
        } else if bufferList.count == 1 {
            guard let source = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else {
                throw ReadError.conversionFailed
            }
            if channelCount == 1 {
                _ = memcpy(
                    content.pointer(0) + destinationStart,
                    source + sourceOffset,
                    frameCount * MemoryLayout<Float>.stride
                )
                return
            }
            for channel in 0..<channelCount {
                let destination = content.pointer(channel) + destinationStart
                var sourceIndex = sourceOffset * channelCount + channel
                var frame = 0
                while frame < frameCount {
                    destination[frame] = source[sourceIndex]
                    sourceIndex += channelCount
                    frame += 1
                }
            }
        } else {
            throw ReadError.conversionFailed
        }
    }
}


extension FinderItem.AsyncLoadableContent {
    /// Returns a `PCMContainer`.
    public static var pcm: FinderItem.AsyncLoadableContent<PCMContainer, any Error> {
        .init { source in
            try await PCMContainer(from: source)
        }
    }
    /// Returns a `PCMContainer`.
    public static func pcm(sampleRate: Double) -> FinderItem.AsyncLoadableContent<PCMContainer, any Error> {
        .init { source in
            try await PCMContainer(from: source, sampleRate: sampleRate)
        }
    }
}
