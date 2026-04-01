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
    
    /// Error thrown by `init(from:)`.
    public enum ReadError: Error {
        case assetReaderError
        case converterUnavailable
        case conversionFailed
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
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate ?? inFormat.sampleRate,
                                      channels: inFormat.channelCount,
                                      interleaved: false)!
        
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
        
        let channelCount = Int(outFormat.channelCount)
        let frameCount = Int(destBuffer.frameLength)
        let result = MultiArray<Float>.allocate(channelCount, frameCount)
        for channel in 0..<channelCount {
            memcpy(result.sequence(at: [channel]).baseAddress!, channelData[channel], frameCount * MemoryLayout<Float>.stride)
        }
        
        self.content = result
        self.sampleRate = outFormat.sampleRate
    }
    
    /// Writes `self` as a `wav` to destination.
    public func write(to destination: FinderItem) async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(self.channelCount),
                                   interleaved: false)!
        
        let file = try AVAudioFile(forWriting: destination.url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(self.content.shape[1]))!
        buffer.frameLength = buffer.frameCapacity
        
        let channelData = buffer.floatChannelData!
        for channel in 0..<self.content.shape[0] {
            memcpy(channelData[channel], self.content.sequence(at: [channel]).baseAddress!, Int(buffer.frameLength) * MemoryLayout<Float>.stride)
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
