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
    }
    
    
    /// The number of float samples stored in `content`.
    @inlinable
    public var sampleCount: Int {
        guard !self.content.shape.isEmpty else { return 0 }
        return self.content.shape.reduce(1, *)
    }
    
    /// Reads and decodes the source `AudioFile` to float PCM for all channels.
    ///
    /// - Parameter sampleRate: If specified, this sample rate will be used for decoding input.
    public init(
        from source: FinderItem,
        sampleRate: Double? = nil
    ) async throws {
        let inputFile = try AVAudioFile(forReading: source.url)
        let inFormat  = inputFile.processingFormat          // e.g. 48 kHz/2ch/float32
        let resolvedSampleRate = sampleRate ?? inFormat.sampleRate
        let channelCount = Int(inFormat.channelCount)

        // AVAudioFormat(commonFormat:...) only supports 1 or 2 channels.
        // Try non-interleaved first for straightforward per-channel memcpy,
        // then interleaved; beyond stereo both return nil and we throw.
        let useNonInterleaved: Bool
        let outFormat: AVAudioFormat
        if let nonInterleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedSampleRate,
            channels: inFormat.channelCount,
            interleaved: false) {
            useNonInterleaved = true
            outFormat = nonInterleaved
        } else if let interleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedSampleRate,
            channels: inFormat.channelCount,
            interleaved: true) {
            useNonInterleaved = false
            outFormat = interleaved
        } else {
            throw ReadError.formatUnavailable
        }
        
        // make the converter
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ReadError.converterUnavailable
        }
        
        // figure out how many frames we expect
        let inputFrameCount  = AVAudioFrameCount(inputFile.length)
        let rateRatio        = outFormat.sampleRate / inFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * rateRatio) + 1
        
        // prepare buffers
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputFrameCount)!
        let destBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCount)!
        
        // read the entire file into sourceBuffer
        try inputFile.read(into: sourceBuffer)
        
        // now do a single-shot conversion
        var error: NSError? = nil
        var didProvideInput = false
        let status = converter.convert(to: destBuffer, error: &error) { inNumPackets, outStatus in
            _ = inNumPackets
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
        }
        if status == .error || error != nil {
            throw error ?? ReadError.conversionFailed
        }
        
        // destBuffer now contains converted audio.
        let channelData = destBuffer.floatChannelData!
        let frameCount = Int(destBuffer.frameLength)
        let result = MultiArray<Float>.allocate(channelCount, frameCount)

        if useNonInterleaved {
            for channel in 0..<channelCount {
                memcpy(result.sequence(at: [channel]).baseAddress!, channelData[channel], frameCount * MemoryLayout<Float>.stride)
            }
        } else {
            let src = channelData[0]
            var channel = 0
            while channel < channelCount {
                let dest = result.sequence(at: [channel]).baseAddress!
                var frame = 0
                while frame < frameCount {
                    (dest + frame).initialize(to: src[frame &* channelCount &+ channel])
                    frame &+= 1
                }
                channel &+= 1
            }
        }
        
        self.content = result
        self.sampleRate = outFormat.sampleRate
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
                memcpy(channelData[channel], self.content.sequence(at: [channel]).baseAddress!, frameCount * MemoryLayout<Float>.stride)
            }
        } else {
            let dest = channelData[0]
            let srcs = (0..<channelCount).map { self.content.sequence(at: [$0]).baseAddress! }
            var frame = 0
            while frame < frameCount {
                let base = frame &* channelCount
                var channel = 0
                while channel < channelCount {
                    (dest + (base &+ channel)).initialize(to: srcs[channel][frame])
                    channel &+= 1
                }
                frame &+= 1
            }
        }

        try file.write(from: buffer)
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
