//
//  HPSSTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import Testing
import PCMContainer
import AppKit
import FinderItem


@Suite(.disabled("does not work well"))
struct HPSSTests {
    
    @Test func increment() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/increment.m4a")
        let hpss = try await source.load(.pcm).mono().hpss()
        
        let destination = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/Temp/PCMContainer")
        
        try await hpss.reconstruct(\.harmonic).write(to: destination/"harmonic.wav")
        try await hpss.reconstruct(\.percussive).write(to: destination/"percussive.wav")
    }
    
    @Test func audio() async throws {
        let source = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/PCMContainer/audio.m4a")
        let hpss = try await source.load(.pcm).mono().hpss()
        
        let destination = FinderItem(at: "/Users/vaida/DataBase/Swift Package/Test Reference/Temp/PCMContainer")
        
        try await hpss.reconstruct(\.harmonic).write(to: destination/"audio_harmonic.wav")
        try await hpss.reconstruct(\.percussive).write(to: destination/"audio_percussive.wav")
    }
}
