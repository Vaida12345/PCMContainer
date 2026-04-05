//
//  ChromaTests.swift
//  MediaKit
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import PCMContainer
import FinderItem
import MultiArray


@Suite
struct ChromaTests {
    
    @Test func increment() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let chroma = try await source.load(.pcm).mono().chroma()
        Attachment.record(chroma.values.rendered()!)
    }
    
    @Test func dynamicTimeWarping() async throws {
        let lhs = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let rhs = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment_slow.m4a")
        let lChroma = try await lhs.load(.pcm).mono().chroma()
        let rChroma = try await rhs.load(.pcm).mono().chroma()
        let warping = lChroma.dynamicTimeWarping(to: rChroma)
        print(warping)
    }
}
