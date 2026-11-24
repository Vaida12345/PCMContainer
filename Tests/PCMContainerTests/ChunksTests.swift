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
    
    // MARK: - Independent references
    
    /// Resampled chunks equal one `AVAudioConverter` run over the whole native signal, built here without the decoder.
    @Test(arguments: [96_000.0, 48_000, 22_050])
    func resamplingMatchesOneShotConverter(nativeSampleRate: Double) async throws {
        let original = makeFixture(sampleRate: nativeSampleRate, channelCount: 2, frameCount: Int(nativeSampleRate) + 4_321)
        let file = try await writeFixture(original)
        defer { try? FileManager.default.removeItem(atPath: file.path) }
        
        let streamed = try await collect(PCMContainer.chunks(from: file, sampleRate: 44_100, maximumFrameCount: 1_000))
        let native = try await PCMContainer(from: file)
        let reference = try oneShotResample(native.content, from: nativeSampleRate, to: 44_100)
        
        #expect(streamed.content.shape == reference.shape)
        #expect(differingValues(streamed.content, reference) == 0)
    }
    
    /// AAC adds encoder priming that the decoder trims; clicks must stay where they were written, and the length must match.
    @Test func aacPrimingIsTrimmed() async throws {
        let sampleRate = 44_100.0
        let times = [0.3, 0.71, 1.2]
        let content = MultiArray<Float>.zeros(1, Int(sampleRate * 1.5))
        for time in times {
            content[0, Int((time * sampleRate).rounded())] = 0.9
        }
        let file = FinderItem(at: NSTemporaryDirectory()) / "pcm_chunks_\(UUID().uuidString).m4a"
        try await PCMContainer(content: content, sampleRate: sampleRate).write(to: file, as: .aac)
        defer { try? FileManager.default.removeItem(atPath: file.path) }
        
        let decoded = try await collect(PCMContainer.chunks(from: file, maximumFrameCount: 1_000))
        #expect(abs(decoded.content.shape[1] - content.shape[1]) <= 1)
        let samples = UnsafeBufferPointer(start: decoded.content.baseAddress, count: decoded.content.shape[1])
        for time in times {
            let expected = Int((time * sampleRate).rounded())
            let peak = (expected - 3_000 ..< expected + 3_000).max { abs(samples[$0]) < abs(samples[$1]) }!
            #expect(abs(peak - expected) <= 2, "click at \(time) s is at frame \(peak), expected \(expected)")
        }
    }
    
    // MARK: - Timeline
    
    @Test func overlappingBufferWins() throws {
        var timeline = makeTimeline()
        try place(&timeline, [1, 1, 1, 1], at: 0)
        try place(&timeline, [2, 2, 2], at: 2)
        #expect(try drain(&timeline) == [1, 1, 2, 2, 2])
    }
    
    @Test func overlapInsideHeldBufferOnlyOverwrites() throws {
        var timeline = makeTimeline()
        try place(&timeline, [1, 1, 1, 1, 1], at: 0)
        try place(&timeline, [2, 2], at: 1)
        #expect(try drain(&timeline) == [1, 2, 2, 1, 1])
    }
    
    @Test func settledFramesKeepEarlierSamples() throws {
        var timeline = makeTimeline()
        try place(&timeline, [1, 1], at: 0)
        try place(&timeline, [2, 2], at: 2)    // settles [1, 1]
        try place(&timeline, [3, 3, 3], at: 1) // frame 1 is settled; frames 2, 3 overwrite the held buffer
        #expect(try drain(&timeline) == [1, 1, 3, 3])
    }
    
    @Test func gapsBecomeSilenceInBoundedPieces() throws {
        var timeline = makeTimeline(maximumSilenceFrameCount: 4)
        try place(&timeline, [1], at: 0)
        try place(&timeline, [2], at: 11)
        timeline.finish()
        var lengths: [Int] = []
        var samples: [Float] = []
        while let buffer = try timeline.next() {
            lengths.append(Int(buffer.frameLength))
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        #expect(lengths == [1, 4, 4, 2, 1])
        #expect(samples == [1] + Array(repeating: 0, count: 10) + [2])
    }
    
    @Test func framesBeforeTheStartAreDropped() throws {
        var timeline = makeTimeline()
        try place(&timeline, [9, 9, 1, 1], at: -2)
        #expect(try drain(&timeline) == [1, 1])
    }
    
    // MARK: - Errors
    
    /// After `next()` throws, here because the task was cancelled, iteration ends.
    @Test func cancellationEndsIteration() async throws {
        let file = try await writeFixture(makeFixture(sampleRate: 48_000, channelCount: 2, frameCount: 48_000))
        defer { try? FileManager.default.removeItem(atPath: file.path) }
        let chunks = try PCMContainer.chunks(from: file, sampleRate: 44_100, maximumFrameCount: 1_000)
        
        let endedAfterThrowing = await Task {
            var iterator = chunks.makeAsyncIterator()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await iterator.next()
                return false
            } catch is CancellationError {
                return (try? await iterator.next()) == nil
            } catch {
                return false
            }
        }.value
        #expect(endedAfterThrowing)
    }
    
    // MARK: - Helpers
    
    /// The whole signal through one `AVAudioConverter`, with the decoder's settings, trimmed or padded to the length the duration implies.
    private func oneShotResample(_ content: MultiArray<Float>, from rate: Double, to target: Double) throws -> MultiArray<Float> {
        let channelCount = content.shape[0]
        let frameCount = content.shape[1]
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channelCount))!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: AVAudioChannelCount(channelCount))!
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frameCount))!
        input.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<channelCount {
            input.floatChannelData![channel].update(from: content.pointer(channel), count: frameCount)
        }
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = .max
        let expected = Int((Double(frameCount) * target / rate).rounded())
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(expected + 8_192))!
        var provided = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let result = MultiArray<Float>.zeros(channelCount, expected)
        for channel in 0..<channelCount {
            result.pointer(channel).update(from: output.floatChannelData![channel], count: min(expected, Int(output.frameLength)))
        }
        return result
    }
    
    private func makeTimeline(maximumSilenceFrameCount: Int = 1_000) -> PCMContainer.Chunks.Timeline {
        PCMContainer.Chunks.Timeline(format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!, maximumSilenceFrameCount: maximumSilenceFrameCount)
    }
    
    private func place(_ timeline: inout PCMContainer.Chunks.Timeline, _ samples: [Float], at destination: Int) throws {
        try timeline.place(count: samples.count, at: destination) { channels, destinationOffset, sourceOffset, count in
            for offset in 0..<count {
                channels[0][destinationOffset + offset] = samples[sourceOffset + offset]
            }
        }
    }
    
    private func drain(_ timeline: inout PCMContainer.Chunks.Timeline) throws -> [Float] {
        timeline.finish()
        var samples: [Float] = []
        while let buffer = try timeline.next() {
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
    
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
