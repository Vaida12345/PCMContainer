//
//  ChromaTests.swift
//  MediaKit
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import PCMContainer
import AppKit
import FinderItem


@Suite
struct ChromaTests {
    
    @Test func increment() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/MediaKit/increment.m4a")
        let chroma = try await source.load(.pcm).mono().chroma()
        Attachment.record(chroma.values.rendered()!)
    }
}
