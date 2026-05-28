//
//  PCMContainerBasicTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
import PCMContainer
import MultiArray


@Suite("PCMContainer — Basic Properties")
struct PCMContainerBasicTests {

    // MARK: - init

    @Test("init with valid 2D content")
    func initValid() {
        let content = MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.sampleRate == 44100)
        #expect(pcm.channelCount == 2)
        #expect(pcm.content[0, 0] == 1.0)
        #expect(pcm.content[0, 1] == 2.0)
        #expect(pcm.content[1, 0] == 3.0)
        #expect(pcm.content[1, 1] == 4.0)
    }

    @Test("init with single channel")
    func initSingleChannel() {
        let content = MultiArray<Float>([[5.0, 6.0, 7.0]])
        let pcm = PCMContainer(content: content, sampleRate: 8000)

        #expect(pcm.channelCount == 1)
        #expect(pcm.sampleRate == 8000)
    }

    @Test("init with zero sample rate")
    func initZeroSampleRate() {
        let content = MultiArray<Float>([[1.0]])
        let pcm = PCMContainer(content: content, sampleRate: 0)

        #expect(pcm.sampleRate == 0)
        #expect(pcm.channelCount == 1)
    }

    // MARK: - channelCount

    @Test("channelCount — stereo")
    func channelCountStereo() {
        let content = MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.channelCount == 2)
    }

    @Test("channelCount — mono")
    func channelCountMono() {
        let content = MultiArray<Float>([[1.0, 2.0, 3.0]])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.channelCount == 1)
    }

    @Test("channelCount — five channels")
    func channelCountFiveChannel() {
        let content = MultiArray<Float>.zeros(5, 100)
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.channelCount == 5)
    }

    // MARK: - sampleCount

    @Test("sampleCount — stereo 2×3")
    func sampleCountStereo() {
        let content = MultiArray<Float>([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.sampleCount == 6)
    }

    @Test("sampleCount — mono single sample")
    func sampleCountSingleSample() {
        let content = MultiArray<Float>([[1.0]])
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.sampleCount == 1)
    }

    @Test("sampleCount — large")
    func sampleCountLarge() {
        let content = MultiArray<Float>.zeros(4, 1024)
        let pcm = PCMContainer(content: content, sampleRate: 44100)

        #expect(pcm.sampleCount == 4096)
    }

    // MARK: - contentsEqual

    @Test("contentsEqual — identical content")
    func contentsEqualIdentical() {
        let a = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]]),
            sampleRate: 44100
        )
        let b = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]]),
            sampleRate: 48000
        )

        #expect(a.contentsEqual(b))
    }

    @Test("contentsEqual — different content, same shape")
    func contentsEqualDifferentContent() {
        let a = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]]),
            sampleRate: 44100
        )
        let b = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 5.0]]),
            sampleRate: 44100
        )

        #expect(!a.contentsEqual(b))
    }

    @Test("contentsEqual — different shape")
    func contentsEqualDifferentShape() {
        let a = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0]]),
            sampleRate: 44100
        )
        let b = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]]),
            sampleRate: 44100
        )

        #expect(!a.contentsEqual(b))
    }

    @Test("contentsEqual — custom tolerance")
    func contentsEqualTolerance() {
        let a = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0]]),
            sampleRate: 44100
        )
        let b = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0001]]),
            sampleRate: 44100
        )

        #expect(!a.contentsEqual(b, tolerance: 1e-6))
        #expect(a.contentsEqual(b, tolerance: 1e-3))
    }

    @Test("contentsEqual — self")
    func contentsEqualSelf() {
        let a = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0], [3.0, 4.0]]),
            sampleRate: 44100
        )

        #expect(a.contentsEqual(a))
    }

    // MARK: - mono

    @Test("mono — already mono returns self")
    func monoAlreadyMono() {
        let pcm = PCMContainer(
            content: MultiArray<Float>([[1.0, 2.0, 3.0]]),
            sampleRate: 44100
        )
        let mono = pcm.mono()

        #expect(mono.channelCount == 1)
        #expect(mono.sampleRate == 44100)
        #expect(mono.content.shape == [1, 3])
    }

    @Test("mono — stereo averaging")
    func monoStereoAverage() {
        // Two channels with known values.
        let content = MultiArray<Float>([
            [1.0, 3.0, 5.0],
            [2.0, 4.0, 6.0],
        ])
        let pcm = PCMContainer(content: content, sampleRate: 10)
        let mono = pcm.mono()

        #expect(mono.channelCount == 1)
        #expect(mono.content.shape == [1, 3])
        #expect(mono.content[0, 0] == 1.5)
        #expect(mono.content[0, 1] == 3.5)
        #expect(mono.content[0, 2] == 5.5)
        #expect(mono.sampleRate == 10)
    }

    @Test("mono — three channel averaging")
    func monoThreeChannel() {
        let content = MultiArray<Float>([
            [1.0, 2.0],
            [3.0, 4.0],
            [5.0, 6.0],
        ])
        let pcm = PCMContainer(content: content, sampleRate: 44100)
        let mono = pcm.mono()

        #expect(mono.channelCount == 1)
        #expect(mono.content.shape == [1, 2])
        #expect(abs(mono.content[0, 0] - 3.0) < 1e-6)  // (1+3+5)/3
        #expect(abs(mono.content[0, 1] - 4.0) < 1e-6)  // (2+4+6)/3
    }

    @Test("mono — zero samples")
    func monoZeroSamples() {
        let content = MultiArray<Float>.zeros(2, 0)
        let pcm = PCMContainer(content: content, sampleRate: 44100)
        let mono = pcm.mono()

        #expect(mono.channelCount == 1)
        #expect(mono.content.shape == [1, 0])
    }
}
