//
//  PCM + Read.swift
//  PCMContainer
//
//  Created by Vaida on 2026-07-02.
//

import MultiArray
import FinderItem
import AVFoundation


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
    ///   - options: Flags controlling how decoder padding and trim metadata are handled.
    public init(
        from source: FinderItem,
        sampleRate: Double? = nil,
        options: DecodeOptions = []
    ) async throws {
        let inputFile = try AVAudioFile(forReading: source.url)
        let inFormat = inputFile.processingFormat
        let resolvedSampleRate = sampleRate ?? inFormat.sampleRate
        let channelCount = Int(inFormat.channelCount)
        
        let result = try await Self.decodeTimelineCorrectPCM(
            from: source.url,
            sampleRate: resolvedSampleRate,
            channelCount: channelCount,
            options: options
        )
        
        self.content = result
        self.sampleRate = resolvedSampleRate
    }
    
}


extension PCMContainer {
    
    public struct DecodeOptions: OptionSet, Sendable, Hashable {
        public var rawValue: UInt
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }
        
        /// Returns full source package, which can include priming frames and remainder frames.
        ///
        /// By default, swift returns gapless-trimmed valid frame, use this option to indicate the full package should be returned, which is useful to reproduce pydub / ffmpeg behavior.
        public static let decodeUntrimmed = DecodeOptions(rawValue: 1 << 0)
    }
    
}


private extension PCMContainer {
    
    /// Decodes audio through `AVAssetReader` and places each buffer on its output timeline.
    ///
    /// When `options` contains `.decodeUntrimmed`, packet trim attachments are ignored so decoder priming and remainder frames are preserved.
    static func decodeTimelineCorrectPCM(
        from url: URL,
        sampleRate: Double,
        channelCount: Int,
        options: PCMContainer.DecodeOptions
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
