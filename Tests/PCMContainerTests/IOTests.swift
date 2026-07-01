//
//  IOTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import FinderItem
import PCMContainer
import MultiArray
import Foundation
@preconcurrency import AVFoundation


@Suite
struct IOTests {
    /// Verifies that externally encoded audio can still be decoded and written back out.
    @Test func autoencode() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let pcm = try await source.load(.pcm)
        
        let temp = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/Temp/PCMContainer")/"\(UUID()).wav"
        try await pcm.write(to: temp)
        
        let newPCM = try await temp.load(.pcm)
        #expect(pcm.contentsEqual(newPCM))
    }

    /// Verifies that generated audio files decode with the correct sample rate, channel count, and samples.
    @Test func generatedFilesReadWithExpectedFormatAndContent() async throws {
        let sampleRates: [Double] = [8_000, 22_050, 44_100, 48_000, 96_000, 192_000]
        let channelCounts = [1, 2]

        for sampleRate in sampleRates {
            for channelCount in channelCounts {
                let frameCount = frameCountForFixture(sampleRate: sampleRate, channelCount: channelCount)
                let original = makeFixture(
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    frameCount: frameCount
                )
                let file = temporaryAudioFile()
                defer { try? FileManager.default.removeItem(atPath: file.path) }

                try await original.write(to: file)
                let restored = try await PCMContainer(from: file)

                #expect(restored.sampleRate == sampleRate)
                #expect(restored.channelCount == channelCount)
                #expect(restored.content.shape == [channelCount, frameCount])
                #expect(restored.contentsEqual(original, tolerance: 1e-4))
            }
        }
    }

    /// Verifies that generated multi-channel files decode beyond stereo.
    @Test func generatedMultiChannelFilesReadWithExpectedContent() async throws {
        let sampleRate = 48_000.0
        let channelCounts = [3, 4, 6]
        let frameCount = 2_048

        for channelCount in channelCounts {
            let original = makeFixture(
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: frameCount
            )
            let file = temporaryAudioFile()
            defer { try? FileManager.default.removeItem(atPath: file.path) }

            try writeMultiChannelFixture(original, to: file)
            let restored = try await PCMContainer(from: file)

            #expect(restored.sampleRate == sampleRate)
            #expect(restored.channelCount == channelCount)
            #expect(restored.content.shape == [channelCount, frameCount])
            #expect(restored.contentsEqual(original, tolerance: 1e-4))
        }
    }

    /// Verifies that read-time sample-rate conversion preserves channel count and timeline duration.
    @Test func generatedFilesReadWithRequestedSampleRate() async throws {
        let originalSampleRate = 48_000.0
        let requestedSampleRates = [12_000.0, 22_050.0, 44_100.0]
        let channelCounts = [1, 2]
        let originalFrameCount = 4_800

        for requestedSampleRate in requestedSampleRates {
            for channelCount in channelCounts {
                let original = makeFixture(
                    sampleRate: originalSampleRate,
                    channelCount: channelCount,
                    frameCount: originalFrameCount
                )
                let file = temporaryAudioFile()
                defer { try? FileManager.default.removeItem(atPath: file.path) }

                try await original.write(to: file)
                let restored = try await PCMContainer(from: file, sampleRate: requestedSampleRate)
                let expectedFrameCount = Int((Double(originalFrameCount) * requestedSampleRate / originalSampleRate).rounded())

                #expect(restored.sampleRate == requestedSampleRate)
                #expect(restored.channelCount == channelCount)
                #expect(abs(restored.content.shape[1] - expectedFrameCount) <= 1)
                #expect(restored.sampleCount > 0)
            }
        }
    }

    /// Creates a temporary WAV file path for generated I/O fixtures.
    private func temporaryAudioFile() -> FinderItem {
        FinderItem(at: NSTemporaryDirectory()) / "pcm_read_\(UUID().uuidString).wav"
    }

    /// Chooses a small but nontrivial frame count for a generated fixture.
    private func frameCountForFixture(sampleRate: Double, channelCount: Int) -> Int {
        Int(sampleRate / 20) + channelCount * 17
    }

    /// Creates deterministic PCM content whose channels have distinct sample patterns.
    private func makeFixture(sampleRate: Double, channelCount: Int, frameCount: Int) -> PCMContainer {
        let content = MultiArray<Float>.zeros(channelCount, frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let phase = (frame * (channel + 3) + channel * 11) % 257
                content[channel, frame] = Float(phase) / 128 - 1
            }
        }
        return PCMContainer(content: content, sampleRate: sampleRate)
    }

    /// Writes a generated fixture with an explicit discrete channel layout for channels beyond stereo.
    private func writeMultiChannelFixture(_ pcm: PCMContainer, to file: FinderItem) throws {
        let channelCount = pcm.channelCount
        let frameCount = pcm.content.shape[1]
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            throw PCMContainer.ReadError.formatUnavailable
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: pcm.sampleRate,
            interleaved: true,
            channelLayout: layout
        )
        let audioFile = try AVAudioFile(
            forWriting: file.url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData?[0] else {
            throw PCMContainer.ReadError.formatUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                destination[base + channel] = pcm.content[channel, frame]
            }
        }
        try audioFile.write(from: buffer)
    }
}
