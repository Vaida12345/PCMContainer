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
    /// The file is decoded at its own rate and, if `sampleRate` differs, resampled by one `AVAudioConverter`, so the result is reproducible and sample-aligned. This collects ``chunks(from:sampleRate:maximumFrameCount:)``; to process a long file without holding it whole, iterate those instead.
    ///
    /// - Parameters:
    ///   - source: Audio file to decode.
    ///   - sampleRate: If specified, the output PCM is decoded at this sample rate.
    public init(
        from source: FinderItem,
        sampleRate: Double? = nil
    ) async throws {
        let chunks = try Self.chunks(from: source, sampleRate: sampleRate)
        var content = MultiArray<Float>.zeros(chunks.channelCount, max(0, chunks.estimatedFrameCount))
        var frameCount = 0
        for try await chunk in chunks {
            Self.ensureFrameCapacity(chunk.frames.upperBound, in: &content)
            for channel in 0..<chunks.channelCount {
                (content.pointer(channel) + chunk.frames.lowerBound).update(from: chunk.content.pointer(channel), count: chunk.frames.count)
            }
            frameCount = chunk.frames.upperBound
        }

        self.content = Self.resized(content, frameCount: frameCount)
        self.sampleRate = chunks.sampleRate
    }
    
}


extension PCMContainer {
    /// Returns the source sample range after applying decoder trim metadata.
    static func decodedSampleRange(
        sampleCount: Int,
        trimStart: Int,
        trimEnd: Int
    ) -> Range<Int> {
        guard sampleCount > 0 else { return 0..<0 }
        
        let sourceStart = min(sampleCount, max(0, trimStart))
        let sourceEnd = max(sourceStart, sampleCount - max(0, trimEnd))
        return sourceStart..<sourceEnd
    }
    
}


extension PCMContainer {

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
