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
    ///   - power: Exponent used by the soft-mask rule.
    ///   - margin: Margin factor for soft masks. `1` is unbiased.
    ///
    /// - Returns: A `HPSS` value containing separated magnitude spectrograms.
    ///
    /// - precondition: `self` is mono.
    public func hpss(
        nFFT: Int = 4096,
        hopLength: Int = 1024,
        harmonicKernelSize: Int = 31,
        percussiveKernelSize: Int = 31,
        power: Float = 2,
        margin: Float = 1
    ) async -> HPSS {
        precondition(self.channelCount == 1, "Only mono audio is supported")
        
        let resolvedFFT = max(2, nFFT)
        let resolvedHop = max(1, hopLength)
        let harmonicKernel = resolvedKernelSize(harmonicKernelSize)
        let percussiveKernel = resolvedKernelSize(percussiveKernelSize)
        let resolvedPower = max(power, 0)
        let resolvedMargin = max(margin, 0)

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
        let harmonicRadius = harmonicKernel / 2

        bin = 0
        while bin < frequencyBins {
            var window: [Float] = []
            window.reserveCapacity(harmonicKernel)

            var frame = 0
            while frame < frameCount {
                window.removeAll(keepingCapacity: true)
                let start = max(0, frame - harmonicRadius)
                let end = min(frameCount - 1, frame + harmonicRadius)

                var t = start
                while t <= end {
                    window.append(magnitude[bin, t])
                    t += 1
                }

                harmonicEstimate[bin, frame] = median(of: &window)
                frame += 1
            }
            bin += 1
        }

        let percussiveEstimate = MultiArray<Float>.zeros(frequencyBins, frameCount)
        let percussiveRadius = percussiveKernel / 2

        var frame = 0
        while frame < frameCount {
            var window: [Float] = []
            window.reserveCapacity(percussiveKernel)

            bin = 0
            while bin < frequencyBins {
                window.removeAll(keepingCapacity: true)
                let start = max(0, bin - percussiveRadius)
                let end = min(frequencyBins - 1, bin + percussiveRadius)

                var f = start
                while f <= end {
                    window.append(magnitude[f, frame])
                    f += 1
                }

                percussiveEstimate[bin, frame] = median(of: &window)
                bin += 1
            }
            frame += 1
        }

        let harmonic = MultiArray<Float>.zeros(frequencyBins, frameCount)
        let percussive = MultiArray<Float>.zeros(frequencyBins, frameCount)
        let epsilon: Float = 1e-8

        bin = 0
        while bin < frequencyBins {
            frame = 0
            while frame < frameCount {
                let h = max(harmonicEstimate[bin, frame], 0)
                let p = max(percussiveEstimate[bin, frame], 0)
                let hScore = powf(h, resolvedPower)
                let pScore = powf(p, resolvedPower)

                let hMask = hScore / (hScore + resolvedMargin * pScore + epsilon)
                let pMask = pScore / (pScore + resolvedMargin * hScore + epsilon)

                harmonic[bin, frame] = magnitude[bin, frame] * hMask
                percussive[bin, frame] = magnitude[bin, frame] * pMask
                frame += 1
            }
            bin += 1
        }

        return HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: resolvedHop,
            nFFT: resolvedFFT
        )
    }

    /// Harmonic and percussive STFT magnitude components.
    public struct HPSS: Sendable {

        /// Harmonic magnitude spectrogram with shape `frequencyBins × frameCount`.
        public let harmonic: MultiArray<Float>

        /// Percussive magnitude spectrogram with shape `frequencyBins × frameCount`.
        public let percussive: MultiArray<Float>

        /// STFT hop length used to produce frames, in samples.
        public let hopLength: Int

        /// FFT size used to compute STFT.
        public let nFFT: Int

        /// Number of spectrogram frames.
        @inlinable
        public var frameCount: Int {
            harmonic.shape.count >= 2 ? harmonic.shape[1] : 0
        }

        /// Number of frequency bins.
        @inlinable
        public var frequencyBinCount: Int {
            harmonic.shape.first ?? 0
        }

        /// Creates an HPSS container.
        @inlinable
        public init(
            harmonic: MultiArray<Float>,
            percussive: MultiArray<Float>,
            hopLength: Int,
            nFFT: Int
        ) {
            self.harmonic = harmonic
            self.percussive = percussive
            self.hopLength = hopLength
            self.nFFT = nFFT
        }
    }

}


/// Resolves the kernel size to a positive odd number.
@inline(__always)
private func resolvedKernelSize(_ kernelSize: Int) -> Int {
    let clamped = max(1, kernelSize)
    return clamped.isMultiple(of: 2) ? clamped + 1 : clamped
}

/// Computes the median value of a mutable sample window.
private func median(of values: inout [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    
    values.sort()
    let middle = values.count / 2
    
    if values.count.isMultiple(of: 2) {
        return (values[middle - 1] + values[middle]) * 0.5
    } else {
        return values[middle]
    }
}
