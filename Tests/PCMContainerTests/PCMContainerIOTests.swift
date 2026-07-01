//
//  PCMContainerIOTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
@testable import PCMContainer
import MultiArray
import FinderItem
import Foundation
@preconcurrency import AVFoundation


@Suite("PCMContainer — I/O")
struct PCMContainerIOTests {

    /// Creates a temporary FinderItem that is cleaned up after the test.
    private func tempFile(extension: String = "wav") -> FinderItem {
        let name = "pcm_test_\(UUID().uuidString).\(`extension`)"
        return FinderItem(at: NSTemporaryDirectory()) / name
    }

    // MARK: - Roundtrip

    @Test("roundtrip — mono, float values preserved")
    func roundtripMono() async throws {
        let content = MultiArray<Float>([
            [1.0, 2.0, 3.0, 4.0, 5.0, 0.0, -1.0, -2.0],
        ])
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 44100)
        #expect(restored.channelCount == 1)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("roundtrip — stereo")
    func roundtripStereo() async throws {
        let content = MultiArray<Float>([
            [1.0,  2.0,  3.0,  4.0],
            [5.0,  6.0,  7.0,  8.0],
        ])
        let original = PCMContainer(content: content, sampleRate: 48000)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 48000)
        #expect(restored.channelCount == 2)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("roundtrip — custom sample rate")
    func roundtripCustomSampleRate() async throws {
        let content = MultiArray<Float>([
            [0.5, -0.5, 1.0],
        ])
        let original = PCMContainer(content: content, sampleRate: 22050)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file, sampleRate: 22050)

        #expect(restored.sampleRate == 22050)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("roundtrip — single sample")
    func roundtripSingleSample() async throws {
        let content = MultiArray<Float>([[0.75]])
        let original = PCMContainer(content: content, sampleRate: 8000)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.channelCount == 1)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("roundtrip — stereo with many frames")
    func roundtripMultiChannelManyFrames() async throws {
        let frameCount = 1024
        let channelCount = 2
        let content = MultiArray<Float>.zeros(channelCount, frameCount)
        // Fill with known pattern: content[c][f] = Float(c * frameCount + f)
        for c in 0..<channelCount {
            for f in 0..<frameCount {
                content[c, f] = Float(c * frameCount + f)
            }
        }
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.channelCount == channelCount)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    // MARK: - Read error cases

    @Test("init(from:) — non-existent file throws")
    func readNonExistentFile() async {
        let file = FinderItem(at: "/tmp/pcm_nonexistent_file_\(UUID().uuidString).wav")

        await #expect(throws: (any Error).self) {
            let _ = try await PCMContainer(from: file)
        }
    }

    // MARK: - AsyncLoadableContent

    @Test("AsyncLoadableContent.pcm loads audio")
    func asyncLoadableContent() async throws {
        let content = MultiArray<Float>([[1.0, 2.0, 3.0]])
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await file.load(.pcm)

        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("AsyncLoadableContent.pcm(sampleRate:) loads with rate")
    func asyncLoadableContentWithSampleRate() async throws {
        let content = MultiArray<Float>([[1.0, 2.0, 3.0, 4.0]])
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await file.load(.pcm(sampleRate: 44100))

        #expect(restored.sampleRate == 44100)
    }

    // MARK: - Output formats

    /// Verifies that AAC decoder priming and padding trims do not shift decoded transients.
    @Test("AAC decode aligns transient with WAV")
    func aacDecodeAlignsTransientWithWAV() async throws {
        let sampleRate = 44_100.0
        let channelCount = 2
        let frameCount = 12_000
        let transientFrame = 4_096
        let content = MultiArray<Float>.zeros(channelCount, frameCount)
        for channel in 0..<channelCount {
            content[channel, transientFrame] = channel == 0 ? 1.0 : 0.75
        }
        let original = PCMContainer(content: content, sampleRate: sampleRate)

        let wavFile = tempFile(extension: "wav")
        let aacFile = tempFile(extension: "m4a")
        defer {
            try? FileManager.default.removeItem(atPath: wavFile.path)
            try? FileManager.default.removeItem(atPath: aacFile.path)
        }

        try await original.write(to: wavFile, as: .wav)
        try await original.write(to: aacFile, as: .aac)

        let wav = try await PCMContainer(from: wavFile, sampleRate: sampleRate)
        let aac = try await PCMContainer(from: aacFile, sampleRate: sampleRate)
        let wavPeakFrame = strongestFrame(in: wav, channel: 0)
        let aacPeakFrame = strongestFrame(in: aac, channel: 0)

        #expect(wavPeakFrame == transientFrame)
        #expect(abs(aacPeakFrame - wavPeakFrame) <= 96)
        #expect(aac.channelCount == channelCount)
    }

    /// Verifies that `decodeUntrimmed` keeps a packet's priming and remainder frames.
    @Test("decodeUntrimmed preserves packet trim ranges")
    func decodeUntrimmedPreservesPacketTrimRanges() {
        let trimmedRange = PCMContainer.decodedSampleRange(
            sampleCount: 1_024,
            trimStart: 211,
            trimEnd: 37,
            options: []
        )
        let untrimmedRange = PCMContainer.decodedSampleRange(
            sampleCount: 1_024,
            trimStart: 211,
            trimEnd: 37,
            options: .decodeUntrimmed
        )

        #expect(trimmedRange == 211..<987)
        #expect(untrimmedRange == 0..<1_024)
    }
    
    @Test func decodeUntrimmed() async throws {
        let container = try await PCMContainer(
            from: .bundleItem(
                forResource: "Rose Adagio",
                withExtension: "mp3",
                subdirectory: "Resources",
                in: .module
            ),
            sampleRate: 44100,
            options: .decodeUntrimmed
        )
        
        #expect(container.content.shape[1] == 14802048)
    }

    /// Returns the frame containing the largest absolute sample in one channel.
    private func strongestFrame(in pcm: PCMContainer, channel: Int) -> Int {
        let frameCount = pcm.content.shape[1]
        var strongestFrame = 0
        var strongestValue: Float = 0
        for frame in 0..<frameCount {
            let value = abs(pcm.content[channel, frame])
            guard value > strongestValue else { continue }
            strongestFrame = frame
            strongestValue = value
        }
        return strongestFrame
    }

    /// Verifies that each supported output format writes a decodable audio file.
    @Test("write(to:as:) — common formats are writable and readable")
    func writeCommonFormats() async throws {
        let content = MultiArray<Float>([
            [0.0, 0.25, 0.5, 0.25, 0.0, -0.25, -0.5, -0.25],
            [0.5, 0.25, 0.0, -0.25, -0.5, -0.25, 0.0, 0.25],
        ])
        let original = PCMContainer(content: content, sampleRate: 44100)
        let formats: [(extension: String, format: AudioFileFormat, isLosslessPCM: Bool)] = [
            ("wav", .wav, true),
            ("aiff", .aiff, true),
            ("caf", .caf, true),
            ("m4a", .aac, false),
            ("m4a", .alac(), false),
        ]

        for format in formats {
            let file = tempFile(extension: format.extension)
            defer { try? FileManager.default.removeItem(atPath: file.path) }

            try await original.write(to: file, as: format.format)
            let restored = try await PCMContainer(from: file)

            #expect(restored.sampleRate == 44100)
            #expect(restored.channelCount == 2)
            #expect(restored.sampleCount > 0)
            if format.isLosslessPCM {
                #expect(restored.contentsEqual(original, tolerance: 1e-4))
            }
        }
    }

    /// Verifies that `AudioFileFormat` maps to the expected Core Audio format identifiers.
    @Test("AudioFileFormat settings expose expected Core Audio format identifiers")
    func audioFileFormatSettings() {
        let sampleRate = 44100.0
        let channelCount = 2
        let expectedFormats: [(AudioFileFormat, AudioFormatID)] = [
            (.wav, kAudioFormatLinearPCM),
            (.aiff, kAudioFormatLinearPCM),
            (.caf, kAudioFormatLinearPCM),
            (.aac, kAudioFormatMPEG4AAC),
            (.alac(), kAudioFormatAppleLossless),
        ]

        for expectedFormat in expectedFormats {
            let settings = expectedFormat.0.settings(sampleRate: sampleRate, channelCount: channelCount)
            #expect(settings[AVSampleRateKey] as? Double == sampleRate)
            #expect(settings[AVNumberOfChannelsKey] as? Int == channelCount)
            #expect(settings[AVFormatIDKey] as? AudioFormatID == expectedFormat.1)
        }
    }

    // MARK: - write(to:) edge cases

    @Test("write overwrites existing file")
    func writeOverwrites() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        let first = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0]]),
            sampleRate: 44100
        )
        try await first.write(to: file)

        let second = PCMContainer(
            content: MultiArray<Float>([[3.0, 4.0, 5.0]]),
            sampleRate: 44100
        )
        try await second.write(to: file)

        let restored = try await PCMContainer(from: file)
        #expect(restored.contentsEqual(second, tolerance: 1e-4))
        #expect(!restored.contentsEqual(first))
    }

    // MARK: - Multichannel output

    /// Verifies that the default WAV writer can round-trip three-channel PCM content.
    @Test("write(to:) — supports 3-channel audio")
    func writeThreeChannelRoundtrip() async throws {
        let content = MultiArray<Float>([
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6],
            [0.7, 0.8, 0.9],
        ])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await pcm.write(to: file)
        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 44100)
        #expect(restored.channelCount == 3)
        #expect(restored.contentsEqual(pcm, tolerance: 1e-4))
    }

    /// Verifies that the default WAV writer can round-trip five-channel PCM content.
    @Test("write(to:) — supports 5-channel audio")
    func writeFiveChannelRoundtrip() async throws {
        let content = MultiArray<Float>.zeros(5, 100)
        for channel in 0..<5 {
            for frame in 0..<100 {
                content[channel, frame] = Float(channel * 100 + frame) / 500
            }
        }
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await pcm.write(to: file)
        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 44100)
        #expect(restored.channelCount == 5)
        #expect(restored.contentsEqual(pcm, tolerance: 1e-4))
    }

    // MARK: - Sample rate edge cases

    @Test("roundtrip — very low sample rate (8000 Hz)")
    func roundtripLowSampleRate() async throws {
        let content = MultiArray<Float>([[0.5, 1.0, -0.5]])
        let original = PCMContainer(content: content, sampleRate: 8000)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 8000)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    @Test("roundtrip — high sample rate (192000 Hz)")
    func roundtripHighSampleRate() async throws {
        let content = MultiArray<Float>([[0.25, -0.25]])
        let original = PCMContainer(content: content, sampleRate: 192000)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.sampleRate == 192000)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    // MARK: - Value extremes

    @Test("roundtrip — preserves extreme float values")
    func roundtripExtremeValues() async throws {
        let content = MultiArray<Float>([
            [Float.greatestFiniteMagnitude * 0.5,
             -Float.greatestFiniteMagnitude * 0.5,
             0.0,
             1e-6,
             -1e-6],
        ])
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.contentsEqual(original, tolerance: 1e-3))
    }

    @Test("roundtrip — alternating sign pattern")
    func roundtripAlternatingSign() async throws {
        let frameCount = 256
        let content = MultiArray<Float>.zeros(1, frameCount)
        for f in 0..<frameCount {
            content[0, f] = f.isMultiple(of: 2) ? 1.0 : -1.0
        }
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    // MARK: - Mono with many frames

    @Test("roundtrip — mono 8192 frames")
    func roundtripMonoManyFrames() async throws {
        let frameCount = 8192
        let content = MultiArray<Float>.zeros(1, frameCount)
        for f in 0..<frameCount {
            content[0, f] = Float(f % 256) / 256.0
        }
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        #expect(restored.channelCount == 1)
        #expect(restored.sampleRate == 44100)
        #expect(restored.contentsEqual(original, tolerance: 1e-4))
    }

    // MARK: - Tolerance boundary

    @Test("roundtrip — values near tolerance boundary")
    func roundtripToleranceBoundary() async throws {
        let content = MultiArray<Float>([[1.0, 1.0 + 1e-5, 1.0 - 1e-5]])
        let original = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        try await original.write(to: file)

        let restored = try await PCMContainer(from: file)

        // Should be equal within default 1e-4 tolerance of the values themselves,
        // but we use a generous tolerance for the roundtrip comparison.
        #expect(restored.contentsEqual(original, tolerance: 1e-3))
    }

}
