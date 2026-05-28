//
//  HPSSTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
import PCMContainer
import MultiArray


@Suite("HPSS Struct")
struct HPSSFeatureTests {

    /// Creates a minimal complex spectrogram for testing.
    /// Shape: [frequencyBins, frameCount, 2] where last dim is (real, imag).
    private func makeSpectrogram(
        frequencyBins: Int,
        frameCount: Int,
        fill: (Int, Int) -> (real: Float, imag: Float) = { _, _ in (1.0, 0.0) }
    ) -> MultiArray<Float> {
        let spectrum = MultiArray<Float>.zeros(frequencyBins, frameCount, 2)
        for bin in 0..<frequencyBins {
            for frame in 0..<frameCount {
                let (real, imag) = fill(bin, frame)
                spectrum[bin, frame, 0] = real
                spectrum[bin, frame, 1] = imag
            }
        }
        return spectrum
    }

    // MARK: - HPSS init

    @Test("HPSS init — valid parameters")
    func hpssInit() {
        let harmonic = makeSpectrogram(frequencyBins: 4, frameCount: 3)
        let percussive = makeSpectrogram(frequencyBins: 4, frameCount: 3)

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 1024,
            nFFT: 4096,
            sampleRate: 44100
        )

        #expect(hpss.hopLength == 1024)
        #expect(hpss.nFFT == 4096)
        #expect(hpss.harmonic.shape[0] == 4)
        #expect(hpss.harmonic.shape[1] == 3)
        #expect(hpss.harmonic.shape[2] == 2)
    }

    // MARK: - magnitude

    @Test("magnitude — computes sqrt(real² + imag²)")
    func magnitudeComputation() {
        // Create a known spectrogram: bin 0 has (3, 4) → magnitude 5
        let harmonic = makeSpectrogram(frequencyBins: 1, frameCount: 1) { _, _ in
            (3.0, 4.0)
        }
        let percussive = makeSpectrogram(frequencyBins: 1, frameCount: 1)

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 512,
            nFFT: 1024,
            sampleRate: 44100
        )

        let mag = hpss.magnitude(of: \.harmonic)

        #expect(mag.shape == [1, 1])
        #expect(abs(mag[0, 0] - 5.0) < 1e-5)  // hypot(3, 4) = 5
    }

    @Test("magnitude — zero spectrogram gives zero magnitude")
    func magnitudeZero() {
        let harmonic = makeSpectrogram(frequencyBins: 2, frameCount: 2) { _, _ in
            (0.0, 0.0)
        }
        let percussive = makeSpectrogram(frequencyBins: 2, frameCount: 2)

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 512,
            nFFT: 1024,
            sampleRate: 44100
        )

        let mag = hpss.magnitude(of: \.harmonic)

        #expect(mag[0, 0] == 0.0)
        #expect(mag[0, 1] == 0.0)
        #expect(mag[1, 0] == 0.0)
        #expect(mag[1, 1] == 0.0)
    }

    @Test("magnitude — all non-negative")
    func magnitudeNonNegative() {
        let harmonic = makeSpectrogram(frequencyBins: 4, frameCount: 3) { bin, frame in
            (Float(bin) - 2.0, Float(frame) - 1.0)
        }
        let percussive = makeSpectrogram(frequencyBins: 4, frameCount: 3)

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 1024,
            nFFT: 4096,
            sampleRate: 44100
        )

        let mag = hpss.magnitude(of: \.harmonic)

        for bin in 0..<mag.shape[0] {
            for frame in 0..<mag.shape[1] {
                #expect(mag[bin, frame] >= 0)
            }
        }
    }

    @Test("magnitude — percussive path")
    func magnitudePercussivePath() {
        let harmonic = makeSpectrogram(frequencyBins: 1, frameCount: 1) { _, _ in
            (0.0, 0.0)
        }
        let percussive = makeSpectrogram(frequencyBins: 1, frameCount: 1) { _, _ in
            (1.0, 0.0)
        }

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 512,
            nFFT: 1024,
            sampleRate: 44100
        )

        let magHarmonic = hpss.magnitude(of: \.harmonic)
        let magPercussive = hpss.magnitude(of: \.percussive)

        #expect(magHarmonic[0, 0] == 0.0)
        #expect(magPercussive[0, 0] == 1.0)
    }

    // MARK: - reconstruct

    @Test("reconstruct — returns PCMContainer with correct sample rate")
    func reconstructSampleRate() {
        // Create a minimal valid spectrogram. ISTFT expects specific format.
        // We use a small spectrogram that should produce some output.
        let nFFT = 64
        let frequencyBins = nFFT / 2 + 1  // 33
        let frameCount = 4

        let harmonic = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { _, _ in (0.0, 0.0) }

        let percussive = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { _, _ in (0.0, 0.0) }

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 16,
            nFFT: nFFT,
            sampleRate: 44100
        )

        let pcm = hpss.reconstruct(\.harmonic)

        #expect(pcm.sampleRate == 44100)
        #expect(pcm.channelCount == 1)
    }

    @Test("reconstruct — produces non-empty output")
    func reconstructNonEmpty() {
        let nFFT = 128
        let frequencyBins = nFFT / 2 + 1  // 65
        let frameCount = 8

        // Put some energy into the spectrum.
        let harmonic = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { bin, _ in
            // Energy in a few bins.
            if bin >= 2 && bin <= 10 {
                return (1.0, 0.0)
            }
            return (0.0, 0.0)
        }

        let percussive = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        )

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 32,
            nFFT: nFFT,
            sampleRate: 22050
        )

        let pcm = hpss.reconstruct(\.harmonic)

        #expect(pcm.content.shape[1] > 0, "Reconstructed signal should have samples")
    }

    @Test("reconstruct — harmonics and percussive from same spectrogram")
    func reconstructBothPaths() {
        let nFFT = 64
        let frequencyBins = nFFT / 2 + 1
        let frameCount = 4

        let harmonic = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { bin, _ in
            if bin == 5 { return (0.5, 0.0) }
            return (0.0, 0.0)
        }

        let percussive = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { bin, _ in
            if bin == 10 { return (1.0, 0.0) }
            return (0.0, 0.0)
        }

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 16,
            nFFT: nFFT,
            sampleRate: 44100
        )

        let harmonicPCM = hpss.reconstruct(\.harmonic)
        let percussivePCM = hpss.reconstruct(\.percussive)

        #expect(harmonicPCM.sampleRate == 44100)
        #expect(percussivePCM.sampleRate == 44100)
        #expect(harmonicPCM.channelCount == 1)
        #expect(percussivePCM.channelCount == 1)
    }

    // MARK: - Large spectrogram

    @Test("magnitude — larger spectrogram")
    func magnitudeLargerSpectrogram() {
        let frequencyBins = 128
        let frameCount = 32

        let harmonic = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        ) { bin, frame in
            (Float(bin), Float(frame))
        }

        let percussive = makeSpectrogram(
            frequencyBins: frequencyBins,
            frameCount: frameCount
        )

        let hpss = PCMContainer.HPSS(
            harmonic: harmonic,
            percussive: percussive,
            hopLength: 1024,
            nFFT: 4096,
            sampleRate: 44100
        )

        let mag = hpss.magnitude(of: \.harmonic)

        #expect(mag.shape[0] == frequencyBins)
        #expect(mag.shape[1] == frameCount)
    }
}
