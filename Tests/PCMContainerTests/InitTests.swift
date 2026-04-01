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
}
