//
//  PCM + IO.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import MultiArray
@preconcurrency import AVFoundation
import FinderItem


extension PCMContainer {
    
    /// Error thrown by `init(from:)` and `write(to:)`.
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
    
    /// Writes `self` as a `wav` to destination.
    public func write(to destination: FinderItem) async throws {
        let channelCount = self.channelCount
        let frameCount = self.content.shape[1]

        // AVAudioFormat(commonFormat:...) only supports 1 or 2 channels.
        // Try non-interleaved first for straightforward per-channel memcpy,
        // then interleaved; beyond stereo both return nil and we throw.
        let useNonInterleaved: Bool
        let format: AVAudioFormat
        if let nonInterleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) {
            useNonInterleaved = true
            format = nonInterleaved
        } else if let interleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) {
            useNonInterleaved = false
            format = interleaved
        } else {
            throw ReadError.formatUnavailable
        }

        let file = try AVAudioFile(forWriting: destination.url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = buffer.frameCapacity

        let channelData = buffer.floatChannelData!
        if useNonInterleaved {
            for channel in 0..<channelCount {
                memcpy(channelData[channel], self.content.pointer(channel), frameCount * MemoryLayout<Float>.stride)
            }
        } else {
            let dest = channelData[0]
            var frame = 0
            while frame < frameCount {
                let base = frame &* channelCount
                var channel = 0
                while channel < channelCount {
                    (dest + (base &+ channel)).initialize(to: self.content[channel, frame])
                    channel &+= 1
                }
                frame &+= 1
            }
        }

        try file.write(from: buffer)
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

            let presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let startFrame = Self.outputFrameIndex(for: presentationTime, sampleRate: sampleRate)
            let destinationStart = max(0, startFrame)
            let sourceOffset = max(0, -startFrame)
            guard sourceOffset < sampleCount else { continue }

            let copiedFrameCount = sampleCount - sourceOffset
            let requiredFrameCount = destinationStart + copiedFrameCount
            Self.ensureFrameCapacity(requiredFrameCount, in: &content)

            try sampleBuffer.withAudioBufferList(flags: [.audioBufferListAssure16ByteAlignment]) { bufferList, _ in
                try Self.copySamples(
                    from: bufferList,
                    sampleCount: sampleCount,
                    sourceOffset: sourceOffset,
                    destinationStart: destinationStart,
                    channelCount: channelCount,
                    into: &content
                )
            }
            decodedFrameCount = max(decodedFrameCount, requiredFrameCount)
        }

        guard reader.status == .completed else { throw reader.error ?? ReadError.assetReaderError }

        let frameCount = max(decodedFrameCount, estimatedFrameCount)
        Self.ensureFrameCapacity(frameCount, in: &content)
        return content
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

    /// Converts a Core Media time to the nearest output PCM frame index.
    static func outputFrameIndex(for time: CMTime, sampleRate: Double) -> Int {
        guard time.isValid && !time.isIndefinite && time.seconds.isFinite else { return 0 }
        return Int((time.seconds * sampleRate).rounded())
    }

    /// Copies Float32 samples from a decoded sample buffer into channel-major PCM storage.
    static func copySamples(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        sampleCount: Int,
        sourceOffset: Int,
        destinationStart: Int,
        channelCount: Int,
        into content: inout MultiArray<Float>
    ) throws {
        guard bufferList.count > 0 else { throw ReadError.conversionFailed }

        let frameCount = sampleCount - sourceOffset
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
