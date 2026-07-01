//
//  PCM + Write.swift
//  PCMContainer
//
//  Created by Vaida on 2026-07-02.
//

import MultiArray
import AVFoundation
import FinderItem


extension PCMContainer {
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
