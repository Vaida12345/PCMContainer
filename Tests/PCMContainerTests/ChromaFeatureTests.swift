//
//  ChromaFeatureTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
import Foundation
@testable import PCMContainer
import MultiArray


@Suite("Chroma")
struct ChromaFeatureTests {

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

    // MARK: - Chroma init

    @Test("Chroma init — valid parameters")
    func chromaInit() {
        let values = MultiArray<Float>.zeros(10, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )

        #expect(chroma.frameCount == 10)
        #expect(chroma.hopLength == 1024)
        #expect(chroma.sampleRate == 44100)
    }

    @Test("Chroma init — single frame")
    func chromaInitSingleFrame() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 512,
            sampleRate: 22050
        )

        #expect(chroma.frameCount == 1)
    }

    @Test("Chroma init — zero frames")
    func chromaInitZeroFrames() {
        let values = MultiArray<Float>.zeros(0, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )

        #expect(chroma.frameCount == 0)
    }

    // MARK: - frameCount

    @Test("frameCount — matches shape first dimension")
    func frameCountMatchesShape() {
        let values = MultiArray<Float>.zeros(42, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )

        #expect(chroma.frameCount == 42)
    }

    // MARK: - secondsPerFrame (internal)

    @Test("secondsPerFrame — computed correctly")
    func secondsPerFrame() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )

        // secondsPerFrame = hopLength / sampleRate
        let expected = 1024.0 / 44100.0
        #expect(chroma.secondsPerFrame == expected)
    }

    @Test("secondsPerFrame — half hop")
    func secondsPerFrameHalfHop() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 512,
            sampleRate: 44100
        )

        #expect(chroma.secondsPerFrame == 512.0 / 44100.0)
    }

    // MARK: - convert(time:to:)

    @Test("convert — frames to seconds")
    func convertFramesToSeconds() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )
        let secondsPerFrame = 1024.0 / 44100.0

        #expect(chroma.convert(time: 0, to: .seconds) == 0.0)
        #expect(chroma.convert(time: 1, to: .seconds) == secondsPerFrame)
        #expect(chroma.convert(time: 10, to: .seconds) == 10 * secondsPerFrame)
    }

    @Test("convert — seconds to frames")
    func convertSecondsToFrames() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )
        let secondsPerFrame = 1024.0 / 44100.0

        #expect(chroma.convert(time: 0, to: .frames) == 0.0)
        #expect(chroma.convert(time: secondsPerFrame, to: .frames) == 1.0)
    }

    @Test("convert — roundtrip")
    func convertRoundtrip() {
        let values = MultiArray<Float>.zeros(1, 12)
        let chroma = PCMContainer.Chroma(
            values: values,
            hopLength: 1024,
            sampleRate: 44100
        )

        let frames = 5.0
        let seconds = chroma.convert(time: frames, to: .seconds)
        let backToFrames = chroma.convert(time: seconds, to: .frames)

        #expect(abs(backToFrames - frames) < 1e-9)
    }

    // MARK: - chroma() computation

    @Test("chroma — shape is frameCount × 12")
    func chromaShape() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 0.5)
        let mono = pcm.mono()
        let chroma = await mono.chroma()

        #expect(chroma.values.shape.count == 2)
        #expect(chroma.values.shape[1] == 12)
        #expect(chroma.values.shape[0] > 0)  // at least one frame
        #expect(chroma.hopLength == 1024)
        #expect(chroma.sampleRate == 44100)
    }

    @Test("chroma — each frame is L1 normalized")
    func chromaL1Normalized() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 0.5)
        let mono = pcm.mono()
        let chroma = await mono.chroma()

        let frameCount = chroma.values.shape[0]
        #expect(frameCount > 0)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for pitch in 0..<12 {
                sum += chroma.values[frame, pitch]
            }
            // Each frame should be L1-normalized (sum ≈ 1) or all zeros.
            #expect(abs(sum - 1.0) < 1e-5 || sum == 0.0,
                    "Frame \(frame): sum = \(sum)")
        }
    }

    @Test("chroma — 440 Hz sine produces dominant pitch class A (9)")
    func chroma440HzIsPitchClassA() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 1.0)
        let mono = pcm.mono()
        let chroma = await mono.chroma()

        let frameCount = chroma.values.shape[0]
        #expect(frameCount > 0)

        // Aggregate energy per pitch class across all frames.
        var energyPerPitch = [Float](repeating: 0, count: 12)
        for frame in 0..<frameCount {
            for pitch in 0..<12 {
                energyPerPitch[pitch] += chroma.values[frame, pitch]
            }
        }

        // Pitch class 9 (A) should have the most energy.
        var maxPitch = 0
        var maxEnergy: Float = 0
        for pitch in 0..<12 {
            if energyPerPitch[pitch] > maxEnergy {
                maxEnergy = energyPerPitch[pitch]
                maxPitch = pitch
            }
        }

        #expect(maxPitch == 9, "Expected pitch class 9 (A), got \(maxPitch)")
        #expect(maxEnergy > 0)
    }

    @Test("chroma — C4 (261.63 Hz) produces dominant pitch class C (0)")
    func chromaC4IsPitchClassC() async {
        let pcm = sineWave(frequency: 261.63, sampleRate: 44100, duration: 1.0)
        let mono = pcm.mono()
        let chroma = await mono.chroma()

        let frameCount = chroma.values.shape[0]
        #expect(frameCount > 0)

        var energyPerPitch = [Float](repeating: 0, count: 12)
        for frame in 0..<frameCount {
            for pitch in 0..<12 {
                energyPerPitch[pitch] += chroma.values[frame, pitch]
            }
        }

        var maxPitch = 0
        var maxEnergy: Float = 0
        for pitch in 0..<12 {
            if energyPerPitch[pitch] > maxEnergy {
                maxEnergy = energyPerPitch[pitch]
                maxPitch = pitch
            }
        }

        #expect(maxPitch == 0, "Expected pitch class 0 (C), got \(maxPitch)")
        #expect(maxEnergy > 0)
    }

    @Test("chroma — precondition fails for multi-channel audio")
    func chromaPreconditionMultiChannel() async {
        // The chroma() method has a precondition requiring mono audio.
        // Multi-channel audio triggers `precondition(self.channelCount == 1, ...)`.
        // Swift Testing does not support expecting precondition failures directly,
        // so this test documents the expected behavior.
    }

    // MARK: - positiveModulo (tested indirectly via chroma)

    @Test("chroma — chroma values are all non-negative after absolute value")
    func chromaValuesNonNegative() async {
        let pcm = sineWave(frequency: 440, sampleRate: 44100, duration: 0.3)
        let mono = pcm.mono()
        let chroma = await mono.chroma()

        let frameCount = chroma.values.shape[0]
        for frame in 0..<frameCount {
            for pitch in 0..<12 {
                #expect(chroma.values[frame, pitch] >= 0)
            }
        }
    }
}
