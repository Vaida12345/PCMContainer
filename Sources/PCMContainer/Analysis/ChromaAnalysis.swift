import AVFoundation
import MultiArray

/// Chroma feature extraction utilities.
extension PCMContainer {

    /// Computes frame-wise 12-bin chroma features for the audio track.
    ///
    /// The method decodes the asset to mono PCM, computes an STFT magnitude spectrum,
    /// folds spectral energy into pitch classes (`C...B`), then L1-normalizes each frame.
    ///
    /// - Returns: A `Chroma` value with shape `frameCount × 12`.
    ///
    /// - Throws: Any error thrown while loading audio tracks.
    ///
    /// - precondition: `self` is mono.
    public func chroma() async -> Chroma {
        precondition(self.channelCount == 1, "Only mono audio is supported")
        let nFFT = 4096
        let hopLength = 1024

        let stft = ShortTimeFourierTransform(n_fft: nFFT, hop: hopLength, center: true)
        let spectrum = stft(self.content)

        assert(spectrum.shape.count == 3)

        let frequencyBins = spectrum.shape[0]
        let frameCount = spectrum.shape[1]
        let chroma = MultiArray<Float>.zeros(frameCount, 12)

        // 0 Hz (DC) carries no pitch class information.
        var bin = 1
        while bin < frequencyBins {
            let frequency = Double(bin) * self.sampleRate / Double(nFFT)
            guard frequency > 0 else {
                bin += 1
                continue
            }

            let midi = 69 + 12 * log2(frequency / 440)
            let pitchClass = positiveModulo(Int(lround(midi)), 12)

            var frame = 0
            while frame < frameCount {
                let real = spectrum[bin, frame, 0]
                let imag = spectrum[bin, frame, 1]
                let magnitude = hypotf(real, imag)
                chroma[frame, pitchClass] += magnitude
                frame += 1
            }

            bin += 1
        }

        // L1 normalize each frame for robust comparison.
        var frame = 0
        while frame < frameCount {
            var sum: Float = 0

            var pitch = 0
            while pitch < 12 {
                sum += chroma[frame, pitch]
                pitch += 1
            }

            if sum > 0 {
                pitch = 0
                while pitch < 12 {
                    chroma[frame, pitch] /= sum
                    pitch += 1
                }
            }

            frame += 1
        }

        return Chroma(values: chroma, hopLength: hopLength)
    }

    /// Frame-wise chroma (HPCP-like) features with 12 pitch classes per frame.
    public struct Chroma: Sendable {

        /// Chroma matrix with shape `frameCount, 12`.
        ///
        /// Each row is a frame, and each column is a pitch class index in `[0, 11]`.
        public let values: MultiArray<Float>

        /// STFT hop length used to produce frames, in samples.
        public let hopLength: Int

        /// Number of chroma frames.
        @inlinable
        public var frameCount: Int {
            values.shape.first ?? 0
        }

        /// Creates a chroma container.
        ///
        /// - Parameters:
        ///   - values: Chroma matrix of shape `frameCount × 12`.
        ///   - hopLength: Hop length used during analysis, in samples.
        @inlinable
        public init(values: MultiArray<Float>, hopLength: Int) {
            self.values = values
            self.hopLength = hopLength
        }
    }

}

/// Computes a non-negative modulo result in the range `[0, modulus)`.
///
/// - Parameters:
///   - value: Input integer.
///   - modulus: Positive modulus.
/// - Returns: Positive wrapped value.
@inline(__always)
private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}
