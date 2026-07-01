//
//  InitTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import FinderItem
import PCMContainer
import Foundation
import MultiArray


@Suite
struct InitTests {
    @Test func mono() async throws {
        let array = MultiArray<Float>([[1.1, 3.2, 7.9], [1.0, 5.2, 0]])
        let source = PCMContainer(content: array, sampleRate: 10)
        let mono = source.mono()
        #expect(mono.content.shape == [1, 3])
        #expect(mono.content[0, 0] == 1.05)
        #expect(mono.content[0, 1] == 4.2)
        #expect(mono.content[0, 2] == 7.9/2)
        #expect(mono.sampleRate == 10)
    }
    
    @Test func stereoFromMono() async throws {
        let array = MultiArray<Float>([[1.1, 3.2, 7.9]])
        let source = PCMContainer(content: array, sampleRate: 10)
        let stereo = source.stereo()
        #expect(stereo.content.shape == [2, 3])
        #expect(stereo.content[0, 0] == 1.1)
        #expect(stereo.content[0, 1] == 3.2)
        #expect(stereo.content[0, 2] == 7.9)
        #expect(stereo.content[1, 0] == 1.1)
        #expect(stereo.content[1, 1] == 3.2)
        #expect(stereo.content[1, 2] == 7.9)
        #expect(stereo.sampleRate == 10)
    }
    
    @Test func stereoFromStereo() async throws {
        let array = MultiArray<Float>([[1.1, 3.2, 7.9], [1.0, 5.2, 0]])
        let source = PCMContainer(content: array, sampleRate: 10)
        let stereo = source.stereo()
        #expect(stereo.content.shape == [2, 3])
        #expect(stereo.contentsEqual(source))
        #expect(stereo.sampleRate == 10)
    }
    
    @Test func stereoFromMultichannel() async throws {
        let array = MultiArray<Float>([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]])
        let source = PCMContainer(content: array, sampleRate: 10)
        let stereo = source.stereo()
        #expect(stereo.content.shape == [2, 3])
        #expect(stereo.content[0, 0] == 4.0)
        #expect(stereo.content[0, 1] == 5.0)
        #expect(stereo.content[0, 2] == 6.0)
        #expect(stereo.content[1, 0] == 4.0)
        #expect(stereo.content[1, 1] == 5.0)
        #expect(stereo.content[1, 2] == 6.0)
        #expect(stereo.sampleRate == 10)
    }
}
