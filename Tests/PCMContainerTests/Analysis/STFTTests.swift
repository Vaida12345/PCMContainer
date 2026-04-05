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
struct STFTTests {
    
    @Test func increment() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let stft = try await source.load(.pcm).mono().shortTimeFourierTransform()
        print(stft.spectrum.shape)
        Attachment.record(stft.rendered()!)
    }
}
