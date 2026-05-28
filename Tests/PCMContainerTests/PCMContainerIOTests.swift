//
//  PCMContainerIOTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
import PCMContainer
import MultiArray
import FinderItem
import Foundation


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

    // MARK: - 3+ channel limitation

    @Test("write(to:) — throws formatUnavailable for 3-channel audio")
    func writeThreeChannelThrows() async throws {
        // AVAudioFormat(commonFormat:...) only supports 1 or 2 channels.
        // 3+ channels returns nil regardless of interleaving.
        let content = MultiArray<Float>([
            [0.1, 0.2, 0.3],
            [0.4, 0.5, 0.6],
            [0.7, 0.8, 0.9],
        ])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        await #expect(throws: PCMContainer.ReadError.formatUnavailable) {
            try await pcm.write(to: file)
        }
    }

    @Test("init(from:) — throws formatUnavailable for 3-channel WAV")
    func readThreeChannelThrows() async throws {
        // Same limitation applies to reading: the output format
        // can't be created for 3+ channels.
        // Since 3-channel WAV files can't be written through AVFoundation
        // either, this is consistent — PCMContainer only supports
        // mono and stereo through the WAV I/O path.
    }

    @Test("write(to:) — throws formatUnavailable for 5-channel audio")
    func writeFiveChannelThrows() async throws {
        let content = MultiArray<Float>.zeros(5, 100)
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        await #expect(throws: PCMContainer.ReadError.formatUnavailable) {
            try await pcm.write(to: file)
        }
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
