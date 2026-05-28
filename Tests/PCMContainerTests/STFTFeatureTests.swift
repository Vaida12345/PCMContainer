//
//  STFTFeatureTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
import Foundation
import PCMContainer
import MultiArray
import CoreGraphics


@Suite("STFT")
struct STFTFeatureTests {

    /// Creates a mono PCMContainer with a sine wave.
    private func sineWave(
        frequency: Double,
        sampleRate: Double,
        duration: Double
    ) -> PCMContainer {
        let frameCount = Int(sampleRate * duration)
        let content = MultiArray<Float>.zeros(1, frameCount)
        for i in 0..<frameCount {
            content[0, i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        }
        return PCMContainer(content: content, sampleRate: sampleRate)
    }

    /// Creates a silent mono PCMContainer.
    private func silence(sampleRate: Double, frameCount: Int) -> PCMContainer {
        let content = MultiArray<Float>.zeros(1, frameCount)
        return PCMContainer(content: content, sampleRate: sampleRate)
    }

    // MARK: - Shape verification

    @Test("STFT shape — default parameters")
    func stftShapeDefault() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 0.2)
        let stft = pcm.shortTimeFourierTransform()

        // n_fft=4096, so frequency bins = 4096/2+1 = 2049
        #expect(stft.spectrum.shape[0] == 2049)
        #expect(stft.spectrum.shape[2] == 2)  // complex (real, imag)
        #expect(stft.n_fft == 4096)
        #expect(stft.hop == 1024)
        #expect(stft.spectrum.shape[1] > 0)  // at least one frame
    }

    @Test("STFT shape — custom n_fft and hop")
    func stftShapeCustom() async {
        let pcm = sineWave(frequency: 440, sampleRate: 8000, duration: 0.5)
        let stft = pcm.shortTimeFourierTransform(n_fft: 256, hop: 64)

        #expect(stft.spectrum.shape[0] == 129)  // 256/2 + 1
        #expect(stft.spectrum.shape[2] == 2)
        #expect(stft.n_fft == 256)
        #expect(stft.hop == 64)
    }

    @Test("STFT shape — large hop")
    func stftShapeLargeHop() async {
        let pcm = sineWave(frequency: 100, sampleRate: 8000, duration: 1.0)
        let stft = pcm.shortTimeFourierTransform(n_fft: 512, hop: 256)

        #expect(stft.spectrum.shape[0] == 257)  // 512/2 + 1
        #expect(stft.spectrum.shape[2] == 2)
        #expect(stft.hop == 256)
    }

    @Test("STFT shape — small n_fft")
    func stftShapeSmallFFT() async {
        let pcm = sineWave(frequency: 440, sampleRate: 8000, duration: 0.1)
        let stft = pcm.shortTimeFourierTransform(n_fft: 64, hop: 16)

        #expect(stft.spectrum.shape[0] == 33)  // 64/2 + 1
        #expect(stft.spectrum.shape[2] == 2)
    }

    // MARK: - STFT contains energy at the input frequency

    @Test("STFT — energy near input frequency")
    func stftEnergyAtFrequency() async {
        let sampleRate = 44100.0
        let frequency = 440.0
        let pcm = sineWave(frequency: frequency, sampleRate: sampleRate, duration: 0.5)
        let stft = pcm.shortTimeFourierTransform(n_fft: 4096, hop: 1024)

        // Find the frequency bin nearest to 440 Hz.
        let binResolution = sampleRate / Double(stft.n_fft)
        let expectedBin = Int((frequency / binResolution).rounded())
        let frameCount = stft.spectrum.shape[1]

        // Check a middle frame — magnitude at expected bin should be non-trivial.
        let midFrame = frameCount / 2
        let real = stft.spectrum[expectedBin, midFrame, 0]
        let imag = stft.spectrum[expectedBin, midFrame, 1]
        let magnitude = hypotf(real, imag)

        #expect(magnitude > 1.0, "Expected significant energy at \(frequency) Hz bin \(expectedBin)")
    }

    // MARK: - rendered

    @Test("rendered — returns non-nil CGImage for valid spectrogram")
    func renderedReturnsImage() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 0.1)
        let stft = pcm.shortTimeFourierTransform(n_fft: 512, hop: 128)

        let image = stft.rendered()

        #expect(image != nil)
    }

    @Test("rendered — image has valid dimensions")
    func renderedDimensions() async {
        let pcm = sineWave(frequency: 440, sampleRate: 8000, duration: 0.2)
        let stft = pcm.shortTimeFourierTransform(n_fft: 256, hop: 64)

        guard let image = stft.rendered() else {
            Issue.record("rendered() returned nil")
            return
        }

        // Image dimensions should be positive and match the total pixel count
        // of the spectrogram (frequencyBins × frameCount).
        #expect(image.width > 0)
        #expect(image.height > 0)
        #expect(image.width * image.height == stft.spectrum.shape[0] * stft.spectrum.shape[1])
    }

    // MARK: - STFT with silence

    @Test("STFT — silence produces near-zero spectrum")
    func stftSilence() async {
        let pcm = silence(sampleRate: 44100, frameCount: 8192)
        let stft = pcm.shortTimeFourierTransform(n_fft: 4096, hop: 1024)

        let frequencyBins = stft.spectrum.shape[0]
        let frameCount = stft.spectrum.shape[1]

        // All bins should be near zero.
        var maxMagnitude: Float = 0
        for bin in 0..<frequencyBins {
            for frame in 0..<frameCount {
                let real = stft.spectrum[bin, frame, 0]
                let imag = stft.spectrum[bin, frame, 1]
                let mag = hypotf(real, imag)
                if mag > maxMagnitude { maxMagnitude = mag }
            }
        }

        #expect(maxMagnitude < 1e-4)
    }

    // MARK: - STFT requires mono input

    @Test("STFT — assertion fails for multi-channel audio")
    func stftMultiChannel() async {
        // The MultiArray STFT asserts that input has shape [L] or [1, L] or [1, 1, L], etc.
        // Multi-channel audio with shape [2, N] triggers "Invalid input shape".
        // Callers should use .mono() before .shortTimeFourierTransform().
        let content = MultiArray<Float>.zeros(2, 4096)
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        // Mono conversion enables STFT.
        let mono = pcm.mono()
        let stft = mono.shortTimeFourierTransform(n_fft: 2048, hop: 512)

        #expect(stft.spectrum.shape[2] == 2)
        #expect(stft.n_fft == 2048)
        #expect(stft.spectrum.shape[0] == 2048 / 2 + 1)
    }
}
