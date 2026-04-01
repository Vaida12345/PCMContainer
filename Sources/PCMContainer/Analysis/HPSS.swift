//
//  HPSS.swift
//  MediaKit
//
//  Created by Vaida on 2026-04-01.
//

import AVFoundation
import MultiArray


/// Harmonic-percussive source separation utilities.
extension PCMContainer {

    /// Separates the audio spectrogram into harmonic and percussive components using median filtering.
    ///
    /// This implementation follows a classic HPSS approach:
    /// 1) compute STFT magnitude,
    /// 2) estimate harmonic energy with a time-axis median filter,
    /// 3) estimate percussive energy with a frequency-axis median filter,
    /// 4) apply soft masks.
    ///
    /// - Parameters:
    ///   - nFFT: FFT size used by STFT.
    ///   - hopLength: STFT hop length in samples.
    ///   - harmonicKernelSize: Median filter window along time for harmonic estimation.
    ///   - percussiveKernelSize: Median filter window along frequency for percussive estimation.
    ///   - power: Exponent used by the soft-mask rule. Lower values produce softer, less aggressive separation.
    ///   - margin: Margin factor for soft masks. Values below `1` are clamped to `1`.
    ///
    /// - Returns: A `HPSS` value containing separated magnitude spectrograms.
    ///
    /// - precondition: `self` is mono.
    @available(*, deprecated, message: "Does not work well.")
    public func hpss(
        nFFT: Int = 4096,
        hopLength: Int = 1024,
        harmonicKernelSize: Int = 31,
        percussiveKernelSize: Int = 31,
        power: Float = 1,
        margin: Float = 1
    ) async -> HPSS {
        precondition(self.channelCount == 1, "Only mono audio is supported")

        let resolvedFFT = max(2, nFFT)
        let resolvedHop = max(1, hopLength)
        let harmonicKernel = resolvedKernelSize(harmonicKernelSize)
        let percussiveKernel = resolvedKernelSize(percussiveKernelSize)
        let resolvedPower = max(power, 0)
        let resolvedMargin = max(margin, 1)

        let stft = ShortTimeFourierTransform(n_fft: resolvedFFT, hop: resolvedHop, center: true)
        let spectrum = stft(self.content)

        assert(spectrum.shape.count == 3)

        let frequencyBins = spectrum.shape[0]
        let frameCount = spectrum.shape[1]

        let magnitude = MultiArray<Float>.zeros(frequencyBins, frameCount)
        var bin = 0
        while bin < frequencyBins {
            var frame = 0
            while frame < frameCount {
                let real = spectrum[bin, frame, 0]
                let imag = spectrum[bin, frame, 1]
                magnitude[bin, frame] = hypotf(real, imag)
                frame += 1
            }
            bin += 1
        }

        let harmonicEstimate = MultiArray<Float>.zeros(frequencyBins, frameCount)

        bin = 0
        while bin < frequencyBins {
            var line = [Float](repeating: 0, count: frameCount)

            var frame = 0
            while frame < frameCount {
                line[frame] = magnitude[bin, frame]
                frame += 1
            }

            let filtered = medianFilter1D(line, kernelSize: harmonicKernel)
            frame = 0
            while frame < frameCount {
                harmonicEstimate[bin, frame] = filtered[frame]
                frame += 1
            }
            bin += 1
        }

        let percussiveEstimate = MultiArray<Float>.zeros(frequencyBins, frameCount)

        var frame = 0
        while frame < frameCount {
            var line = [Float](repeating: 0, count: frequencyBins)

            bin = 0
            while bin < frequencyBins {
                line[bin] = magnitude[bin, frame]
                bin += 1
            }

            let filtered = medianFilter1D(line, kernelSize: percussiveKernel)
            bin = 0
            while bin < frequencyBins {
                percussiveEstimate[bin, frame] = filtered[bin]
                bin += 1
            }
            frame += 1
        }

        let harmonic = MultiArray<Float>.zeros(frequencyBins, frameCount, 2)
        let percussive = MultiArray<Float>.zeros(frequencyBins, frameCount, 2)
        let epsilon: Float = 1e-8

        bin = 0
        while bin < frequencyBins {
            frame = 0
            while frame < frameCount {
                let h = max(harmonicEstimate[bin, frame], 0)
                let p = max(percussiveEstimate[bin, frame], 0)

                guard h + p > epsilon else {
                    harmonic[bin, frame, 0] = 0
                    harmonic[bin, frame, 1] = 0
                    percussive[bin, frame, 0] = 0
                    percussive[bin, frame, 1] = 0
                    frame += 1
                    continue
                }

                let hMask = softMask(
                    signal: h,
                    interference: p,
                    power: resolvedPower,
                    margin: resolvedMargin,
                    epsilon: epsilon
                )
                let pMask = softMask(
                    signal: p,
                    interference: h,
                    power: resolvedPower,
                    margin: resolvedMargin,
                    epsilon: epsilon
                )

                let real = spectrum[bin, frame, 0]
                let imag = spectrum[bin, frame, 1]

                harmonic[bin, frame, 0] = real * hMask
                harmonic[bin, frame, 1] = imag * hMask
                percussive[bin, frame, 0] = real * pMask
                percussive[bin, frame, 1] = imag * pMask
                frame += 1
            }
            bin += 1
        }

        return HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: resolvedHop,
            nFFT: resolvedFFT,
            sampleRate: self.sampleRate
        )
    }

    /// Harmonic and percussive STFT magnitude components.
    public struct HPSS: Sendable {

        /// Harmonic complex spectrogram with shape `frequencyBins × frameCount`.
        public let harmonic: MultiArray<Float>

        /// Percussive complex spectrogram with shape `frequencyBins × frameCount`.
        public let percussive: MultiArray<Float>

        /// STFT hop length used to produce frames, in samples.
        public let hopLength: Int

        /// FFT size used to compute STFT.
        public let nFFT: Int
        
        private let sampleRate: Double

        /// Creates an HPSS container.
        public init(
            harmonic: MultiArray<Float>,
            percussive: MultiArray<Float>,
            hopLength: Int,
            nFFT: Int,
            sampleRate: Double
        ) {
            self.harmonic = harmonic
            self.percussive = percussive
            self.hopLength = hopLength
            self.nFFT = nFFT
            self.sampleRate = sampleRate
        }

        /// Reconstructs the harmonic waveform as a mono `PCMContainer`.
        public func reconstruct(_ keyPath: KeyPath<Self, MultiArray<Float>>) -> PCMContainer {
            let spectrum = self[keyPath: keyPath]
            
            let istft = InverseShortTimeFourierTransform(n_fft: self.nFFT, hop: self.hopLength, center: true)
            var samples = istft(spectrum)
            let content = MultiArray<Float>.zeros(1, samples.count)
            memcpy(content.baseAddress, &samples, samples.count * MemoryLayout<Float>.stride)
            
            return PCMContainer(content: content, sampleRate: self.sampleRate)
        }

        /// Returns the magnitude spectrogram for the selected component.
        public func magnitude(of keyPath: KeyPath<Self, MultiArray<Float>>) -> MultiArray<Float> {
            let spectrum = self[keyPath: keyPath]
            assert(spectrum.shape.count == 3)

            let frequencyBins = spectrum.shape[0]
            let frameCount = spectrum.shape[1]
            let magnitude = MultiArray<Float>.zeros(frequencyBins, frameCount)

            var bin = 0
            while bin < frequencyBins {
                var frame = 0
                while frame < frameCount {
                    let real = spectrum[bin, frame, 0]
                    let imag = spectrum[bin, frame, 1]
                    magnitude[bin, frame] = hypotf(real, imag)
                    frame += 1
                }
                bin += 1
            }

            return magnitude
        }
    }

}


@inline(__always)
private func softMask(
    signal: Float,
    interference: Float,
    power: Float,
    margin: Float,
    epsilon: Float
) -> Float {
    let resolvedSignal = max(signal, 0)
    let resolvedInterference = max(interference, 0)

    guard power > 0 else {
        return resolvedSignal / (resolvedSignal + margin * resolvedInterference + epsilon)
    }

    let signalScore = powf(resolvedSignal, power)
    let interferenceScore = powf(margin * resolvedInterference, power)
    return signalScore / (signalScore + interferenceScore + epsilon)
}

/// Resolves the kernel size to a positive odd number.
@inline(__always)
private func resolvedKernelSize(_ kernelSize: Int) -> Int {
    let clamped = max(1, kernelSize)
    return clamped.isMultiple(of: 2) ? clamped + 1 : clamped
}

/// Applies a 1D median filter with edge-clamped variable window sizes.
private func medianFilter1D(_ values: [Float], kernelSize: Int) -> [Float] {
    guard !values.isEmpty else { return [] }

    let radius = kernelSize / 2
    var result = [Float](repeating: 0, count: values.count)

    var start = 0
    var end = min(values.count - 1, radius)
    var sortedWindow = Array(values[start...end])
    sortedWindow.sort()

    var index = 0
    while index < values.count {
        result[index] = medianOfSortedWindow(sortedWindow)

        let next = index + 1
        guard next < values.count else { break }

        let nextStart = max(0, next - radius)
        let nextEnd = min(values.count - 1, next + radius)

        if nextStart > start {
            var outgoing = start
            while outgoing < nextStart {
                removeSorted(values[outgoing], from: &sortedWindow)
                outgoing += 1
            }
        }

        if nextEnd > end {
            var incoming = end + 1
            while incoming <= nextEnd {
                insertSorted(values[incoming], into: &sortedWindow)
                incoming += 1
            }
        }

        start = nextStart
        end = nextEnd
        index = next
    }

    return result
}

@inline(__always)
private func medianOfSortedWindow(_ values: [Float]) -> Float {
    let middle = values.count / 2
    guard values.count.isMultiple(of: 2) else { return values[middle] }
    return (values[middle - 1] + values[middle]) * 0.5
}

@inline(__always)
private func lowerBound(_ values: [Float], value: Float) -> Int {
    var low = 0
    var high = values.count

    while low < high {
        let mid = (low + high) / 2
        if values[mid] < value {
            low = mid + 1
        } else {
            high = mid
        }
    }

    return low
}

@inline(__always)
private func insertSorted(_ value: Float, into values: inout [Float]) {
    let index = lowerBound(values, value: value)
    values.insert(value, at: index)
}

@inline(__always)
private func removeSorted(_ value: Float, from values: inout [Float]) {
    let index = lowerBound(values, value: value)
    guard index < values.count else { return }

    if values[index] == value {
        values.remove(at: index)
        return
    }

    var cursor = index + 1
    while cursor < values.count {
        if values[cursor] == value {
            values.remove(at: cursor)
            return
        }
        cursor += 1
    }

    cursor = index
    while cursor > 0 {
        let prev = cursor - 1
        if values[prev] == value {
            values.remove(at: prev)
            return
        }
        cursor = prev
    }
}
