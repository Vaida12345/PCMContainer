//
//  PCM + Chunks.swift
//  PCMContainer
//
//  Created by Vaida on 2026-11-24.
//

import AVFoundation
import FinderItem
import MultiArray


extension PCMContainer {

    /// Decodes `source` progressively, as a sequence of consecutive chunks.
    ///
    /// The sequence is pull-based: each call to `next()` decodes, and resamples if needed, just enough of the file for one chunk. A consumer that processes the chunks as they come never holds the whole signal, and nothing is decoded while it is busy.
    ///
    /// Decoding is reproducible, and resampling is sample-aligned: the file is decoded at its own rate, its buffers are placed on the timeline, and one `AVAudioConverter` resamples them in order. `AVAssetReader` can resample through its output settings, but its output then depends on system load. Concatenated, the chunks equal ``init(from:sampleRate:)``.
    ///
    /// - Parameters:
    ///   - source: The audio file to decode.
    ///   - sampleRate: The sample rate of the chunks. If `nil`, the file's own rate.
    ///   - maximumFrameCount: The number of frames in every chunk but the last, which can be shorter.
    ///
    /// - Throws: An error if the file cannot be opened as audio.
    public static func chunks(from source: FinderItem, sampleRate: Double? = nil, maximumFrameCount: Int = 65_536) throws -> Chunks {
        precondition(maximumFrameCount > 0, "`maximumFrameCount` must be positive.")
        let file = try AVAudioFile(forReading: source.url)
        let nativeSampleRate = file.processingFormat.sampleRate
        let sampleRate = sampleRate ?? nativeSampleRate
        return Chunks(
            url: source.url,
            sampleRate: sampleRate,
            nativeSampleRate: nativeSampleRate,
            channelCount: Int(file.processingFormat.channelCount),
            estimatedFrameCount: Int((Double(file.length) * sampleRate / nativeSampleRate).rounded()),
            maximumFrameCount: maximumFrameCount
        )
    }

    /// The consecutive chunks of a decoded audio file. See ``PCMContainer/chunks(from:sampleRate:maximumFrameCount:)``.
    public struct Chunks: AsyncSequence, Sendable {

        public typealias Element = Chunk
        public typealias Failure = any Error

        let url: URL

        /// The sample rate of the chunks: the requested one, or the file's own.
        public let sampleRate: Double

        /// The sample rate of the file.
        let nativeSampleRate: Double

        /// The number of channels in every chunk.
        public let channelCount: Int

        /// The number of frames the file's length implies at ``sampleRate``.
        ///
        /// This comes from the file's metadata before decoding, so use it for progress, not to size buffers.
        public let estimatedFrameCount: Int

        let maximumFrameCount: Int

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(decoder: Decoder(chunks: self))
        }

        /// Decodes the chunks one at a time.
        ///
        /// `AVAssetReader` decodes synchronously, so the decoding runs on a serial dispatch queue of the iterator's own; ``next()`` suspends meanwhile and never blocks a Swift concurrency thread. Blocking those threads deadlocks once enough decodes run at the same time.
        public struct AsyncIterator: AsyncIteratorProtocol {

            let decoder: Decoder

            public mutating func next() async throws -> Chunk? {
                try await decoder.next()
            }
        }

        /// Consecutive frames of a decoded audio file.
        public struct Chunk: Sendable {

            /// The samples, `(channelCount, frames.count)`.
            public let content: MultiArray<Float>

            /// The position of these frames in the decoded file, at ``Chunks/sampleRate``.
            public let frames: Range<Int>

            /// The number of channels in ``content``.
            @inlinable
            public var channelCount: Int {
                content.shape[0]
            }

            /// Returns a mono version of this chunk, with the channels averaged per frame, as ``PCMContainer/mono()`` does.
            ///
            /// If already mono, `self` is returned.
            public func mono() -> Chunk {
                guard channelCount > 1 else { return self }
                return Chunk(content: PCMContainer.averagedChannels(content), frames: frames)
            }
        }
    }

}


extension PCMContainer.Chunks {

    /// Decodes at the file's own rate, places the buffers on the timeline, and resamples them through one converter.
    ///
    /// The placement follows ``PCMContainer/init(from:sampleRate:)``: decoder trim is applied, gaps between timestamps become silence, and when buffers overlap, the earlier samples are kept.
    final class Decoder: @unchecked Sendable { // its state is only touched by one `next()` at a time, on `queue`, or in `start()` before decoding begins.

        private let chunks: PCMContainer.Chunks

        /// Where the blocking decoding runs.
        private let queue = DispatchQueue(label: "PCMContainer.Chunks.Decoder")

        private var reader: AVAssetReader?
        private var trackOutput: AVAssetReaderTrackOutput?
        private var nativeFormat: AVAudioFormat?
        private var outputFormat: AVAudioFormat?
        private var converter: AVAudioConverter?

        /// The native frames placed on the timeline so far.
        private var nativePosition = 0
        /// The frames returned so far, at the output rate.
        private var produced = 0
        /// The output length, once the native stream has ended.
        private var expectedFrameCount: Int?
        /// Silence still owed after the converter's output, when its tail fell short of ``expectedFrameCount``.
        private var pendingSilence = 0
        private var finished = false

        /// Native frames decoded but not yet returned, when not resampling.
        private var leftover: AVAudioPCMBuffer?
        private var leftoverOffset = 0

        init(chunks: PCMContainer.Chunks) {
            self.chunks = chunks
        }

        func next() async throws -> Chunk? {
            if reader == nil && !finished {
                try await start()
            }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try self.nextBlocking() })
                }
            }
        }

        /// The next chunk; blocks while decoding.
        private func nextBlocking() throws -> Chunk? {
            if pendingSilence > 0 {
                let count = Swift.min(pendingSilence, chunks.maximumFrameCount)
                pendingSilence -= count
                return makeChunk(MultiArray<Float>.zeros(chunks.channelCount, count))
            }
            guard !finished else { return nil }

            if converter != nil {
                return try nextResampled()
            } else {
                return try nextNative()
            }
        }

        private func start() async throws {
            let asset = AVURLAsset(url: chunks.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw PCMContainer.ReadError.noAudioTrack
            }

            let channelCount = chunks.channelCount
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: channelCount <= 2,
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw PCMContainer.ReadError.assetReaderError }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? PCMContainer.ReadError.assetReaderError }
            self.reader = reader
            self.trackOutput = output

            guard let nativeFormat = Self.format(sampleRate: chunks.nativeSampleRate, channelCount: channelCount),
                  let outputFormat = Self.format(sampleRate: chunks.sampleRate, channelCount: channelCount) else {
                throw PCMContainer.ReadError.formatUnavailable
            }
            self.nativeFormat = nativeFormat
            self.outputFormat = outputFormat

            if chunks.sampleRate != chunks.nativeSampleRate {
                guard let converter = AVAudioConverter(from: nativeFormat, to: outputFormat) else {
                    throw PCMContainer.ReadError.conversionFailed
                }
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
                converter.sampleRateConverterQuality = .max
                self.converter = converter
            }
        }

        /// Deinterleaved Float32 at `sampleRate`.
        ///
        /// Beyond two channels, `AVAudioFormat` needs a channel layout; the channels are taken as discrete, in order.
        private static func format(sampleRate: Double, channelCount: Int) -> AVAudioFormat? {
            guard channelCount > 2 else {
                return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))
            }
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)) else { return nil }
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }

        /// The next decoded buffer at the native rate, placed on the timeline, or `nil` at the end.
        private func nextPlacedBuffer() throws -> AVAudioPCMBuffer? {
            guard let reader, let trackOutput, let nativeFormat else { return nil }
            let channelCount = chunks.channelCount
            let rate = chunks.nativeSampleRate

            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
                guard sampleCount > 0 else { continue }

                let trimStart = PCMContainer.trimFrameCount(in: sampleBuffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, sampleRate: rate)
                let trimEnd = PCMContainer.trimFrameCount(in: sampleBuffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, sampleRate: rate)
                let validRange = PCMContainer.decodedSampleRange(sampleCount: sampleCount, trimStart: trimStart, trimEnd: trimEnd)
                guard validRange.count > 0 else { continue }

                let startFrame = PCMContainer.outputFrameIndex(for: CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer), sampleRate: rate)
                let destination = Swift.max(0, startFrame)
                // frames before the timeline's start, then frames that overlap what is already placed
                let skipped = Swift.max(0, -startFrame) + Swift.max(0, nativePosition - destination)
                let sourceOffset = validRange.startIndex + skipped
                let count = validRange.endIndex - sourceOffset
                guard count > 0 else { continue }
                let gap = Swift.max(0, destination - nativePosition)

                guard let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(gap + count)),
                      let channels = buffer.floatChannelData else {
                    throw PCMContainer.ReadError.conversionFailed
                }
                buffer.frameLength = AVAudioFrameCount(gap + count)

                try sampleBuffer.withAudioBufferList(flags: [.audioBufferListAssure16ByteAlignment]) { bufferList, _ in
                    if bufferList.count == channelCount {
                        for channel in 0..<channelCount {
                            guard let source = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else {
                                throw PCMContainer.ReadError.conversionFailed
                            }
                            channels[channel].update(repeating: 0, count: gap)
                            (channels[channel] + gap).update(from: source + sourceOffset, count: count)
                        }
                    } else if bufferList.count == 1, let source = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
                        // interleaved
                        for channel in 0..<channelCount {
                            let destination = channels[channel]
                            destination.update(repeating: 0, count: gap)
                            var sourceIndex = sourceOffset * channelCount + channel
                            var frame = 0
                            while frame < count {
                                destination[gap + frame] = source[sourceIndex]
                                sourceIndex += channelCount
                                frame += 1
                            }
                        }
                    } else {
                        throw PCMContainer.ReadError.conversionFailed
                    }
                }

                nativePosition += gap + count
                return buffer
            }

            guard reader.status == .completed else { throw reader.error ?? PCMContainer.ReadError.assetReaderError }
            return nil
        }

        /// The next chunk at the native rate.
        private func nextNative() throws -> Chunk? {
            let channelCount = chunks.channelCount
            let content = MultiArray<Float>.allocate(channelCount, chunks.maximumFrameCount)
            var filled = 0
            while filled < chunks.maximumFrameCount {
                if leftover == nil {
                    guard let buffer = try nextPlacedBuffer() else { break }
                    leftover = buffer
                    leftoverOffset = 0
                }
                guard let buffer = leftover, let source = buffer.floatChannelData else { throw PCMContainer.ReadError.conversionFailed }
                let count = Swift.min(chunks.maximumFrameCount - filled, Int(buffer.frameLength) - leftoverOffset)
                for channel in 0..<channelCount {
                    (content.pointer(channel) + filled).update(from: source[channel] + leftoverOffset, count: count)
                }
                filled += count
                leftoverOffset += count
                if leftoverOffset == Int(buffer.frameLength) {
                    leftover = nil
                }
            }

            if filled < chunks.maximumFrameCount {
                finished = true
            }
            guard filled > 0 else { return nil }
            return makeChunk(PCMContainer.resized(content, frameCount: filled))
        }

        /// The next chunk, resampled.
        private func nextResampled() throws -> Chunk? {
            guard let converter, let outputFormat,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunks.maximumFrameCount)),
                  let resampled = output.floatChannelData else {
                throw PCMContainer.ReadError.conversionFailed
            }

            var inputError: (any Error)?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                do {
                    if let buffer = try self.nextPlacedBuffer() {
                        inputStatus.pointee = .haveData
                        return buffer
                    }
                } catch {
                    inputError = error
                }
                if self.expectedFrameCount == nil {
                    self.expectedFrameCount = Int((Double(self.nativePosition) * self.chunks.sampleRate / self.chunks.nativeSampleRate).rounded())
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw PCMContainer.ReadError.conversionFailed }

            var count = Int(output.frameLength)
            var padding = 0
            if let expectedFrameCount {
                // The converter's tail can run past the length the timeline implies, or fall short of it.
                count = Swift.min(count, expectedFrameCount - produced)
                if status == .endOfStream {
                    finished = true
                    let shortfall = Swift.max(0, expectedFrameCount - produced - count)
                    padding = Swift.min(shortfall, chunks.maximumFrameCount - count)
                    pendingSilence = shortfall - padding
                }
            }
            guard count + padding > 0 else {
                finished = true
                return nil
            }

            let content = MultiArray<Float>.zeros(chunks.channelCount, count + padding)
            for channel in 0..<chunks.channelCount {
                content.pointer(channel).update(from: resampled[channel], count: count)
            }
            return makeChunk(content)
        }

        private func makeChunk(_ content: MultiArray<Float>) -> Chunk {
            let count = content.shape[1]
            defer { produced += count }
            return Chunk(content: content, frames: produced ..< produced + count)
        }
    }

}
