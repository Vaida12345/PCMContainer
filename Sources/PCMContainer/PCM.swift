//
//  PCMContainer.swift
//  MediaKit
//
//  Created by Vaida on 2026-04-01.
//

import Foundation
import FinderItem
import MultiArray


public struct PCMContainer {
    
    /// Contents of the audio as linearPCM.
    ///
    /// `content` is 2D, with leading dimension being `channelCount`.
    public let content: MultiArray<Float>
    
    /// Sampling rate of the decoded PCM signal, in Hz.
    public let sampleRate: Double
    
    /// Creates a PCM container from audio samples and a sample rate.
    ///
    /// - Parameters:
    ///   - content: Audio samples arranged as `[channel, frame]`.
    ///   - sampleRate: Sample rate for `content`, in hertz.
    public init(content: MultiArray<Float>, sampleRate: Double) {
        assert(content.shape.count == 2, "`content` must be 2-dimensional")
        
        self.content = content
        self.sampleRate = sampleRate
    }
    
    /// Number of channels in `content`.
    @inlinable
    public var channelCount: Int {
        content.shape[0]
    }
    
}


extension PCMContainer {
    
    /// Checks whether `self` and `other` has the same content.
    ///
    /// - important: `sampleRate` is not checked. 
    public func contentsEqual(_ other: PCMContainer, tolerance: Float = 1e-6) -> Bool {
        self.content.contentsEqual(other.content, tolerance: tolerance)
    }
    
}
