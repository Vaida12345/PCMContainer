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
    /// Iteration ends after the first error, including cancellation: the call that throws is followed by `nil`.
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
        let fileSampleRate = file.processingFormat.sampleRate
        let sampleRate = sampleRate ?? fileSampleRate
        return Chunks(
            url: source.url,
            sampleRate: sampleRate,
            channelCount: Int(file.processingFormat.channelCount),
            estimatedFrameCount: Int((Double(file.length) * sampleRate / fileSampleRate).rounded()),
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
        ///
        /// The iterator is not `Sendable`: use it from one task.
        public struct AsyncIterator: AsyncIteratorProtocol, ~Sendable {
            
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
    
    /// Places decoded buffers on the native timeline, and hands them out in order.
    ///
    /// The rules match the whole-file decoding this replaced:
    /// - Gaps between buffers become silence, handed out in pieces of at most ``maximumSilenceFrameCount`` frames, so a long gap is never allocated at once.
    /// - When buffers overlap, the later one wins. The latest buffer is held back until the next one arrives, so an overlap can overwrite it; frames already handed out stay as they were, and only an overlap reaching past the held buffer keeps earlier samples.
    /// - Frames before the start of the timeline are dropped.
    struct Timeline {
        
        /// Copies `count` frames from `sourceOffset` in a decoded buffer into `channels`, at `destinationOffset`.
        typealias Copy = (_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, _ destinationOffset: Int, _ sourceOffset: Int, _ count: Int) throws -> Void
        
        private enum Piece {
            case samples(AVAudioPCMBuffer)
            case silence(Int)
        }
        
        let format: AVAudioFormat
        let maximumSilenceFrameCount: Int
        
        /// Frames handed out, or queued to be, which can no longer change.
        private(set) var settledFrameCount = 0
        /// The latest buffer, which a later overlapping buffer can still overwrite.
        private var held: AVAudioPCMBuffer?
        private var queue: [Piece] = []
        
        init(format: AVAudioFormat, maximumSilenceFrameCount: Int) {
            self.format = format
            self.maximumSilenceFrameCount = maximumSilenceFrameCount
        }
        
        /// The number of frames on the timeline so far.
        var frameCount: Int {
            settledFrameCount + Int(held?.frameLength ?? 0)
        }
        
        var hasPieces: Bool {
            !queue.isEmpty
        }
        
        /// Places `count` frames at `destination`, copying them with `copy`.
        mutating func place(count: Int, at destination: Int, copy: Copy) throws {
            var destination = destination
            var sourceOffset = 0
            var count = count
            
            // frames that land on settled frames are dropped
            let settled = Swift.min(count, Swift.max(0, settledFrameCount - destination))
            sourceOffset += settled
            count -= settled
            destination += settled
            guard count > 0 else { return }
            
            // the later buffer overwrites the held one
            if let held, destination < frameCount {
                let overlap = Swift.min(count, frameCount - destination)
                try copy(held.floatChannelData!, destination - settledFrameCount, sourceOffset, overlap)
                sourceOffset += overlap
                count -= overlap
                destination += overlap
                guard count > 0 else { return }
            }
            
            settleHeld()
            if destination > settledFrameCount {
                queue.append(.silence(destination - settledFrameCount))
                settledFrameCount = destination
            }
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else {
                throw PCMContainer.ReadError.conversionFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try copy(channels, 0, sourceOffset, count)
            held = buffer
        }
        
        /// Settles the held buffer, once no more buffers will come.
        mutating func finish() {
            settleHeld()
        }
        
        private mutating func settleHeld() {
            guard let held else { return }
            queue.append(.samples(held))
            settledFrameCount += Int(held.frameLength)
            self.held = nil
        }
        
        /// The next settled piece, or `nil` if none is settled yet.
        mutating func next() throws -> AVAudioPCMBuffer? {
            guard let first = queue.first else { return nil }
            switch first {
            case .samples(let buffer):
                queue.removeFirst()
                return buffer
            case .silence(let count):
                let piece = Swift.min(count, maximumSilenceFrameCount)
                if piece == count {
                    queue.removeFirst()
                } else {
                    queue[0] = .silence(count - piece)
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(piece)),
                      let channels = buffer.floatChannelData else {
                    throw PCMContainer.ReadError.conversionFailed
                }
                buffer.frameLength = AVAudioFrameCount(piece)
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].update(repeating: 0, count: piece)
                }
                return buffer
            }
        }
    }
    
    /// Decodes at the file's own rate, places the buffers on a ``Timeline``, and resamples them through one converter.
    final class Decoder: @unchecked Sendable { // `AsyncIterator` is not `Sendable`, so one `next()` runs at a time; its blocking part runs on `queue`.
        
        private let chunks: PCMContainer.Chunks
        
        /// Where the blocking decoding runs.
        private let queue = DispatchQueue(label: "PCMContainer.Chunks.Decoder")
        
        /// Set once the reader has started.
        private var trackOutput: AVAssetReaderTrackOutput?
        private var reader: AVAssetReader?
        
        /// Set from the first decoded buffer, whose rate is the one the samples come at.
        private var timeline: Timeline?
        private var nativeSampleRate = 0.0
        private var outputFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        /// The first decoded buffer, read early for its format.
        private var firstSampleBuffer: CMSampleBuffer?
        
        private var inputEnded = false
        /// The frames returned so far, at the output rate.
        private var produced = 0
        /// The output length, once the input has ended and the converter is in use.
        private var expectedFrameCount: Int?
        /// Silence still owed after the converter's output, when its tail fell short of ``expectedFrameCount``.
        private var pendingSilence = 0
        /// Native frames decoded but not yet returned, when not resampling.
        private var leftover: AVAudioPCMBuffer?
        private var leftoverOffset = 0
        
        private var finished = false
        
        init(chunks: PCMContainer.Chunks) {
            self.chunks = chunks
        }
        
        func next() async throws -> Chunk? {
            guard !finished else { return nil }
            do {
                try Task.checkCancellation()
                if reader == nil {
                    try await start()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        continuation.resume(with: Result { try self.nextBlocking() })
                    }
                }
            } catch {
                // An iterator ends after it throws.
                finished = true
                throw error
            }
        }
        
        private func start() async throws {
            let asset = AVURLAsset(url: chunks.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw PCMContainer.ReadError.noAudioTrack
            }
            
            // No sample rate: the reader decodes at the file's own rate, which is reproducible.
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
            
            self.trackOutput = output
            self.reader = reader
        }
        
        /// Reads the first buffer, and sets up the timeline and the converter at the rate it was decoded at.
        private func prepare() throws {
            guard let reader, let trackOutput else { throw PCMContainer.ReadError.assetReaderError }
            
            let first = trackOutput.copyNextSampleBuffer()
            if first == nil {
                guard reader.status == .completed else { throw reader.error ?? PCMContainer.ReadError.assetReaderError }
            }
            let nativeSampleRate = first
                .flatMap(CMSampleBufferGetFormatDescription)
                .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?
                .pointee.mSampleRate ?? chunks.sampleRate
            
            guard let nativeFormat = Self.format(sampleRate: nativeSampleRate, channelCount: chunks.channelCount),
                  let outputFormat = Self.format(sampleRate: chunks.sampleRate, channelCount: chunks.channelCount) else {
                throw PCMContainer.ReadError.formatUnavailable
            }
            var converter: AVAudioConverter?
            if nativeSampleRate != chunks.sampleRate {
                guard let made = AVAudioConverter(from: nativeFormat, to: outputFormat) else {
                    throw PCMContainer.ReadError.conversionFailed
                }
                made.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
                made.sampleRateConverterQuality = .max
                converter = made
            }
            
            // Only now that everything is set up.
            self.firstSampleBuffer = first
            self.nativeSampleRate = nativeSampleRate
            self.outputFormat = outputFormat
            self.converter = converter
            self.timeline = Timeline(format: nativeFormat, maximumSilenceFrameCount: chunks.maximumFrameCount)
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
        
        /// The next chunk; blocks while decoding.
        private func nextBlocking() throws -> Chunk? {
            if pendingSilence > 0 {
                let count = Swift.min(pendingSilence, chunks.maximumFrameCount)
                pendingSilence -= count
                if pendingSilence == 0 {
                    finished = true
                }
                return makeChunk(MultiArray<Float>.zeros(chunks.channelCount, count))
            }
            if timeline == nil {
                try prepare()
            }
            
            if converter != nil {
                return try nextResampled()
            } else {
                return try nextNative()
            }
        }
        
        /// The next settled buffer on the native timeline, or `nil` at the end.
        private func nextPlacedBuffer() throws -> AVAudioPCMBuffer? {
            guard var timeline, let reader, let trackOutput else { throw PCMContainer.ReadError.assetReaderError }
            defer { self.timeline = timeline }
            
            while !timeline.hasPieces && !inputEnded {
                let sampleBuffer: CMSampleBuffer
                if let first = firstSampleBuffer {
                    sampleBuffer = first
                    firstSampleBuffer = nil
                } else if let next = trackOutput.copyNextSampleBuffer() {
                    sampleBuffer = next
                } else {
                    guard reader.status == .completed else { throw reader.error ?? PCMContainer.ReadError.assetReaderError }
                    timeline.finish()
                    inputEnded = true
                    break
                }
                try place(sampleBuffer, on: &timeline)
            }
            return try timeline.next()
        }
        
        /// Places the valid frames of `sampleBuffer` at its presentation time.
        private func place(_ sampleBuffer: CMSampleBuffer, on timeline: inout Timeline) throws {
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0 else { return }
            
            let rate = nativeSampleRate
            let trimStart = PCMContainer.trimFrameCount(in: sampleBuffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, sampleRate: rate)
            let trimEnd = PCMContainer.trimFrameCount(in: sampleBuffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, sampleRate: rate)
            let validRange = PCMContainer.decodedSampleRange(sampleCount: sampleCount, trimStart: trimStart, trimEnd: trimEnd)
            guard validRange.count > 0 else { return }
            
            let startFrame = PCMContainer.outputFrameIndex(for: CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer), sampleRate: rate)
            let channelCount = chunks.channelCount
            
            try sampleBuffer.withAudioBufferList(flags: [.audioBufferListAssure16ByteAlignment]) { bufferList, _ in
                let interleaved: Bool
                if bufferList.count == channelCount {
                    interleaved = false
                } else if bufferList.count == 1 {
                    interleaved = true
                } else {
                    throw PCMContainer.ReadError.conversionFailed
                }
                
                // `place` measures source offsets from `startFrame`, so offset them by the trim at the start.
                try timeline.place(count: validRange.count, at: startFrame) { channels, destinationOffset, sourceOffset, count in
                    let frame = validRange.lowerBound + sourceOffset
                    for channel in 0..<channelCount {
                        let destination = channels[channel] + destinationOffset
                        if interleaved {
                            guard let source = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { throw PCMContainer.ReadError.conversionFailed }
                            var index = frame * channelCount + channel
                            for offset in 0..<count {
                                destination[offset] = source[index]
                                index += channelCount
                            }
                        } else {
                            guard let source = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { throw PCMContainer.ReadError.conversionFailed }
                            destination.update(from: source + frame, count: count)
                        }
                    }
                }
            }
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
                    if self.expectedFrameCount == nil, let timeline = self.timeline {
                        self.expectedFrameCount = Int((Double(timeline.frameCount) * self.chunks.sampleRate / self.nativeSampleRate).rounded())
                    }
                    inputStatus.pointee = .endOfStream
                } catch {
                    // Not the end of the stream: stop converting, and throw below.
                    inputError = error
                    inputStatus.pointee = .noDataNow
                }
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
                    if pendingSilence > 0 {
                        finished = false
                    }
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
