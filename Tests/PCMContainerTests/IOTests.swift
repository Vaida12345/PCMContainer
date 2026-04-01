//
//  IOTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import FinderItem
import PCMContainer
import Foundation


@Suite
struct IOTests {
    @Test func autoencode() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let pcm = try await source.load(.pcm)
        
        let temp = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/Temp/PCMContainer")/"\(UUID()).wav"
        try await pcm.write(to: temp)
        
        let newPCM = try await temp.load(.pcm)
        #expect(pcm.contentsEqual(newPCM))
    }
}
