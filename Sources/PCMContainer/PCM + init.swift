//
//  PCM + init.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import MultiArray
import Accelerate


extension PCMContainer {
    
    /// Returns a mono version of this container.
    ///
    /// If there is more than one channel, channels are averaged per frame.
    /// If already mono (or empty), `self` is returned.
    public func mono() -> PCMContainer {
        let channelCount = self.channelCount
        guard channelCount > 1 else { return self }
        guard self.content.shape.count > 1 else { return self }
        
        let frameCount = self.content.shape[1]
        var result = MultiArray<Float>.zeros(1, frameCount)
        
        for channel in 0..<channelCount {
            vDSP_vadd(result.baseAddress, 1,
                      self.content.pointer(channel), 1,
                      result.baseAddress, 1,
                      vDSP_Length(self.content.shape.last!))
        }
        
        let scale = Float(1.0 / Double(channelCount))
        vDSP.multiply(scale, result, result: &result)
        
        return PCMContainer(content: result, sampleRate: self.sampleRate)
    }
    
    /// Returns a stereo version of this container.
    ///
    /// Mono content is copied into both output channels. Multichannel content is
    /// first averaged with ``mono()`` and then copied into both output channels.
    /// If already stereo (or empty), `self` is returned.
    public func stereo() -> PCMContainer {
        let channelCount = self.channelCount
        guard channelCount != 2 else { return self }
        guard channelCount > 0 else { return self }
        guard self.content.shape.count > 1 else { return self }
        
        let source = channelCount == 1 ? self : self.mono()
        let frameCount = source.content.shape[1]
        let result = MultiArray<Float>.allocate(2, frameCount)
        
        result.pointer(0).copy(from: source.content.pointer(0), count: frameCount)
        result.pointer(1).copy(from: source.content.pointer(0), count: frameCount)
        
        return PCMContainer(content: result, sampleRate: self.sampleRate)
    }
    
}
