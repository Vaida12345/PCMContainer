//
//  ChunksTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-11-24.
//

import Testing
@testable import PCMContainer
import FinderItem
import MultiArray
import Foundation
@preconcurrency import AVFoundation


@Suite("PCMContainer — Chunks")
struct ChunksTests {

    // MARK: - Concatenation

    /// The chunks, concatenated, equal `init(from:sampleRate:)`, whatever the chunk size.
    @Test(arguments: [8_000.0, 22_050, 44_100, 48_000, 96_000, 192_000], [nil, 44_100.0])
    func concatenationMatchesInit(nativeSampleRate: Double, requestedSampleRate: Double?) async throws {
        for channelCount in [1, 2] {
            let file = try await writeFixture(makeFixture(sampleRate: nativeSampleRate, channelCount: channelCount, frameCount: Int(nativeSampleRate / 2) + 37))
            defer { try? FileManager.default.removeItem(atPath: file.path) }

            let whole = try await PCMContainer(from: file, sampleRate: requestedSampleRate)
            let small = try await collect(PCMContainer.chunks(from: file, sampleRate: requestedSampleRate, maximumFrameCount: 1_000))

            #expect(whole.sampleRate == (requestedSampleRate ?? nativeSampleRate))
            #expect(small.content.shape == whole.content.shape)
            #expect(differingValues(small.content, whole.content) == 0)
        }
    }

    /// Files with more than two channels, which the reader returns interleaved.
    @Test(arguments: [nil, 44_100.0])
    func multiChannel(requestedSampleRate: Double?) async throws {
        let original = makeFixture(sampleRate: 48_000, channelCount: 6, frameCount: 24_017)
        let file = temporaryAudioFile()
        defer { try? FileManager.default.removeItem(atPath: file.path) }
        try writeMultiChannelFixture(original, to: file)

        let chunks = try PCMContainer.chunks(from: file, sampleRate: requestedSampleRate, maximumFrameCount: 4_096)
        #expect(chunks.channelCount == 6)
        let collected = try await collect(chunks)
        let whole = try await PCMContainer(from: file, sampleRate: requestedSampleRate)
        #expect(differingValues(collected.content, whole.content) == 0)

        if requestedSampleRate == nil {
            #expect(collected.contentsEqual(original, tolerance: 1e-6))
        }

        // mono per chunk equals mono of the whole
        var monoFrames: [Float] = []
        for try await chunk in chunks {
            let mono = chunk.mono()
            #expect(mono.channelCount == 1)
            #expect(mono.frames == chunk.frames)
            monoFrames.append(contentsOf: UnsafeBufferPointer(start: mono.content.baseAddress, count: mono.frames.count))
        }
        let wholeMono = whole.mono()
        #expect(monoFrames.count == wholeMono.content.shape[1])
        #expect(zip(monoFrames, UnsafeBufferPointer(start: wholeMono.content.baseAddress, count: monoFrames.count)).allSatisfy { $0 == $1 })
    }

    // MARK: - Shape

    @Test(arguments: [nil, 44_100.0])
    func chunksAreContiguousAndFull(requestedSampleRate: Double?) async throws {
        let nativeSampleRate = 96_000.0
        let frameCount = 96_000 + 1_234
        let file = try await writeFixture(makeFixture(sampleRate: nativeSampleRate, channelCount: 2, frameCount: frameCount))
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        let maximumFrameCount = 4_000
        let chunks = try PCMContainer.chunks(from: file, sampleRate: requestedSampleRate, maximumFrameCount: maximumFrameCount)
        let rate = requestedSampleRate ?? nativeSampleRate
        let expected = Int((Double(frameCount) * rate / nativeSampleRate).rounded())
        #expect(chunks.sampleRate == rate)
        #expect(abs(chunks.estimatedFrameCount - expected) <= 1)

        var position = 0
        var sizes: [Int] = []
        for try await chunk in chunks {
            #expect(chunk.frames.lowerBound == position)
            #expect(chunk.content.shape == [2, chunk.frames.count])
            position = chunk.frames.upperBound
            sizes.append(chunk.frames.count)
        }
        #expect(position == expected)
        #expect(sizes.dropLast().allSatisfy { $0 == maximumFrameCount })
        #expect((sizes.last ?? 0) > 0 && (sizes.last ?? 0) <= maximumFrameCount)
    }

    // MARK: - Alignment

    /// Resampled clicks land where their time says, to a twentieth of a sample.
    @Test(arguments: [96_000.0, 48_000])
    func resamplingIsSampleAligned(nativeSampleRate: Double) async throws {
        let times = [0.25, 0.5, 0.731]
        let content = MultiArray<Float>.zeros(1, Int(nativeSampleRate))
        for time in times {
            content[0, Int((time * nativeSampleRate).rounded())] = 0.5
        }
        let file = try await writeFixture(PCMContainer(content: content, sampleRate: nativeSampleRate))
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        let resampled = try await PCMContainer(from: file, sampleRate: 44_100)
        #expect(resampled.content.shape[1] == 44_100)
        let samples = UnsafeBufferPointer(start: resampled.content.baseAddress, count: resampled.content.shape[1])
        for time in times {
            let center = Int((time * 44_100).rounded())
            let peak = (center - 50 ..< center + 50).max { samples[$0] < samples[$1] }!
            let (y0, y1, y2) = (samples[peak - 1], samples[peak], samples[peak + 1])
            let interpolated = Double(peak) + 0.5 * Double(y0 - y2) / Double(y0 - 2 * y1 + y2)
            #expect(abs(interpolated - time * 44_100) < 0.05, "click at \(time) s is at \(interpolated)")
        }
    }

    // MARK: - Reproducibility

    @Test func repeatedDecodesAreIdentical() async throws {
        let file = try await writeFixture(makeFixture(sampleRate: 96_000, channelCount: 2, frameCount: 200_000))
        defer { try? FileManager.default.removeItem(atPath: file.path) }

        let first = try await PCMContainer(from: file, sampleRate: 44_100)
        for _ in 0..<3 {
            let again = try await PCMContainer(from: file, sampleRate: 44_100)
            #expect(differingValues(first.content, again.content) == 0)
        }
    }

    // MARK: - Helpers

    private func collect(_ chunks: PCMContainer.Chunks) async throws -> PCMContainer {
        var channels = [[Float]](repeating: [], count: chunks.channelCount)
        for try await chunk in chunks {
            for channel in 0..<chunks.channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: chunk.content.pointer(channel), count: chunk.frames.count))
            }
        }
        let content = MultiArray<Float>.zeros(chunks.channelCount, channels.first?.count ?? 0)
        for (channel, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { content.pointer(channel).update(from: $0.baseAddress!, count: samples.count) }
        }
        return PCMContainer(content: content, sampleRate: chunks.sampleRate)
    }

    private func differingValues(_ lhs: MultiArray<Float>, _ rhs: MultiArray<Float>) -> Int {
        guard lhs.shape == rhs.shape else { return max(lhs.count, rhs.count) }
        var differing = 0
        for i in 0..<lhs.count where lhs.baseAddress[i] != rhs.baseAddress[i] {
            differing += 1
        }
        return differing
    }

    private func temporaryAudioFile() -> FinderItem {
        FinderItem(at: NSTemporaryDirectory()) / "pcm_chunks_\(UUID().uuidString).wav"
    }

    private func writeFixture(_ pcm: PCMContainer) async throws -> FinderItem {
        let file = temporaryAudioFile()
        try await pcm.write(to: file)
        return file
    }

    /// Deterministic content whose channels have distinct sample patterns.
    private func makeFixture(sampleRate: Double, channelCount: Int, frameCount: Int) -> PCMContainer {
        let content = MultiArray<Float>.zeros(channelCount, frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let phase = (frame * (channel + 3) + channel * 11) % 257
                content[channel, frame] = Float(phase) / 256 - 0.5
            }
        }
        return PCMContainer(content: content, sampleRate: sampleRate)
    }

    /// Writes a fixture with a discrete channel layout, for channels beyond stereo.
    private func writeMultiChannelFixture(_ pcm: PCMContainer, to file: FinderItem) throws {
        let channelCount = pcm.channelCount
        let frameCount = pcm.content.shape[1]
        guard let layout = AVAudioChannelLayout(layoutTag: AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))) else {
            throw PCMContainer.ReadError.formatUnavailable
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.sampleRate, interleaved: true, channelLayout: layout)
        let audioFile = try AVAudioFile(forWriting: file.url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData?[0] else {
            throw PCMContainer.ReadError.formatUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                destination[frame * channelCount + channel] = pcm.content[channel, frame]
            }
        }
        try audioFile.write(from: buffer)
    }
}
