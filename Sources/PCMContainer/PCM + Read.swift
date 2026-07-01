//
//  PCM + Read.swift
//  PCMContainer
//
//  Created by Vaida on 2026-07-02.
//

import MultiArray
import FinderItem
import AVFoundation
import AudioToolbox


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
        
        let result: MultiArray<Float>
        if options.contains(.decodeUntrimmed) {
            result = try Self.decodeUntrimmedPCM(from: inputFile, url: source.url, sampleRate: resolvedSampleRate)
        } else {
            result = try await Self.decodeTimelineCorrectPCM(
                from: source.url,
                sampleRate: resolvedSampleRate,
                channelCount: channelCount
            )
        }
        
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
        
        /// Returns the full source package span, which can include priming frames and remainder frames.
        ///
        /// By default, Swift returns gapless-trimmed valid frames. Use this option to request the full package frame count, which is useful to reproduce pydub / ffmpeg behavior.
        public static let decodeUntrimmed = DecodeOptions(rawValue: 1 << 0)
    }
    
}


extension PCMContainer {
    /// Returns the source sample range that should be copied from a decoded packet.
    static func decodedSampleRange(
        sampleCount: Int,
        trimStart: Int,
        trimEnd: Int,
        options: DecodeOptions
    ) -> Range<Int> {
        guard sampleCount > 0 else { return 0..<0 }
        guard !options.contains(.decodeUntrimmed) else { return 0..<sampleCount }
        
        let sourceStart = min(sampleCount, max(0, trimStart))
        let sourceEnd = max(sourceStart, sampleCount - max(0, trimEnd))
        return sourceStart..<sourceEnd
    }
    
}


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
            let validRange = Self.decodedSampleRange(
                sampleCount: sampleCount,
                trimStart: trimStart,
                trimEnd: trimEnd,
                options: []
            )
            guard validRange.count > 0 else { continue }
            
            let presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let startFrame = Self.outputFrameIndex(for: presentationTime, sampleRate: sampleRate)
            let destinationStart = max(0, startFrame)
            let clippedLeadingFrameCount = max(0, -startFrame)
            guard clippedLeadingFrameCount < validRange.count else { continue }
            
            let sourceOffset = validRange.startIndex + clippedLeadingFrameCount
            let copiedFrameCount = validRange.count - clippedLeadingFrameCount
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
    
    /// Decodes valid frames through `AVAudioFile` and restores the full package frame span when metadata is available.
    static func decodeUntrimmedPCM(from inputFile: AVAudioFile, url: URL, sampleRate: Double) throws -> MultiArray<Float> {
        let sourceFormat = inputFile.processingFormat
        guard sourceFormat.channelCount > 0 else { throw ReadError.formatUnavailable }
        guard inputFile.length <= AVAudioFramePosition(AVAudioFrameCount.max) else {
            throw ReadError.formatUnavailable
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw ReadError.formatUnavailable
        }
        
        inputFile.framePosition = 0
        try inputFile.read(into: sourceBuffer)
        guard sourceBuffer.frameLength > 0 else {
            return MultiArray<Float>.zeros(Int(sourceFormat.channelCount), 0)
        }
        
        let outputFormat = try Self.floatPCMFormat(
            sampleRate: sampleRate,
            channelCount: sourceFormat.channelCount
        )
        let decoded: MultiArray<Float>
        if Self.needsConversion(from: sourceBuffer.format, to: outputFormat) {
            guard let converter = AVAudioConverter(from: sourceBuffer.format, to: outputFormat) else {
                throw ReadError.converterUnavailable
            }
            let ratio = sampleRate / sourceBuffer.format.sampleRate
            let outputCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw ReadError.formatUnavailable
            }
            
            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                guard !didProvideInput else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            guard conversionError == nil else { throw conversionError! }
            guard status != .error else { throw ReadError.conversionFailed }
            decoded = try Self.multiArray(from: outputBuffer)
        } else {
            decoded = try Self.multiArray(from: sourceBuffer)
        }
        
        return try Self.restoredFullPackage(decoded, from: url, sourceSampleRate: sourceFormat.sampleRate, outputSampleRate: sampleRate)
    }
    
    /// Restores decoded valid frames to the full package length declared by the source packet table.
    ///
    /// `AVAudioFile` has already removed the packet-table priming span from its reported valid frames. To match ffmpeg / pydub's full decoded package, the valid decode is placed after the decoder's priming delay, the packet-table priming span, and the frame boundary used by ffmpeg's MP3 output.
    static func restoredFullPackage(
        _ decoded: MultiArray<Float>,
        from url: URL,
        sourceSampleRate: Double,
        outputSampleRate: Double
    ) throws -> MultiArray<Float> {
        guard let packetTableInfo = try Self.packetTableInfo(for: url) else { return decoded }
        let packageFrameCount = Self.convertFrameCount(
            packetTableInfo.mNumberValidFrames + Int64(packetTableInfo.mPrimingFrames) + Int64(packetTableInfo.mRemainderFrames),
            from: sourceSampleRate,
            to: outputSampleRate
        )
        let primingFrameCount = Self.convertFrameCount(
            Int64(packetTableInfo.mPrimingFrames),
            from: sourceSampleRate,
            to: outputSampleRate
        )
        let restoredStartFrame = primingFrameCount * 2 + 1
        guard packageFrameCount > decoded.shape[1] else { return decoded }
        guard restoredStartFrame < packageFrameCount else { return decoded }
        
        let channelCount = decoded.shape[0]
        let restored = MultiArray<Float>.zeros(channelCount, packageFrameCount)
        let copiedFrameCount = min(decoded.shape[1], packageFrameCount - restoredStartFrame)
        guard copiedFrameCount > 0 else { return restored }
        
        for channel in 0..<channelCount {
            memcpy(
                restored.pointer(channel) + restoredStartFrame,
                decoded.pointer(channel),
                copiedFrameCount * MemoryLayout<Float>.stride
            )
        }
        return restored
    }
    
    /// Reads packet-table frame counts from an audio file when the container exposes them.
    static func packetTableInfo(for url: URL) throws -> AudioFilePacketTableInfo? {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else { return nil }
        defer { AudioFileClose(audioFile) }
        
        var info = AudioFilePacketTableInfo()
        var infoSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let status = AudioFileGetProperty(audioFile, kAudioFilePropertyPacketTableInfo, &infoSize, &info)
        guard status == noErr else { return nil }
        return info
    }
    
    /// Converts a source-frame count to the requested output sample rate.
    static func convertFrameCount(_ frameCount: Int64, from sourceSampleRate: Double, to outputSampleRate: Double) -> Int {
        guard frameCount > 0 else { return 0 }
        return Int((Double(frameCount) * outputSampleRate / sourceSampleRate).rounded())
    }
    
    /// Creates a non-interleaved Float32 PCM format for decoded output.
    static func floatPCMFormat(sampleRate: Double, channelCount: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw ReadError.formatUnavailable
        }
        return format
    }
    
    /// Returns whether an audio buffer must be converted before copying into channel-major storage.
    static func needsConversion(from sourceFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> Bool {
        sourceFormat.commonFormat != .pcmFormatFloat32 ||
        sourceFormat.sampleRate != outputFormat.sampleRate ||
        sourceFormat.channelCount != outputFormat.channelCount ||
        sourceFormat.isInterleaved
    }
    
    /// Copies an audio PCM buffer into channel-major `MultiArray` storage.
    static func multiArray(from buffer: AVAudioPCMBuffer) throws -> MultiArray<Float> {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let content = MultiArray<Float>.zeros(channelCount, frameCount)
        guard frameCount > 0 else { return content }
        guard let channelData = buffer.floatChannelData else { throw ReadError.conversionFailed }
        
        if buffer.format.isInterleaved {
            let source = channelData[0]
            for channel in 0..<channelCount {
                let destination = content.pointer(channel)
                var sourceIndex = channel
                var frame = 0
                while frame < frameCount {
                    destination[frame] = source[sourceIndex]
                    sourceIndex += channelCount
                    frame += 1
                }
            }
        } else {
            for channel in 0..<channelCount {
                memcpy(content.pointer(channel), channelData[channel], frameCount * MemoryLayout<Float>.stride)
            }
        }
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
