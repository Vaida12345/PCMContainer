//
//  STFT.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-05.
//

import MultiArray
import CoreGraphics

extension PCMContainer {
    
    /// - parameters:
    ///   - n_fft: aka `fft_size`, better frequency resolution, worse time localization.
    ///   - hop: how far you slide the window forward between frames, in samples.
    ///
    /// - precondition: self is mono.
    public func shortTimeFourierTransform(
        n_fft: Int = 4096,
        hop: Int = 1024
    ) -> STFT {
        precondition(self.channelCount == 1)
        let stft = ShortTimeFourierTransform(n_fft: n_fft, hop: hop, center: true)
        let spectrum = stft(self.content)
        return STFT(n_fft: n_fft, hop: hop, spectrum: spectrum)
    }
    
    
    public struct STFT: Sendable {
        
        public let n_fft: Int
        
        public let hop: Int
        
        /// `frequencySamples × frames × complexComponents`
        ///
        /// `n_fft/2+1 × (1+L)/hop × 2`
        public let spectrum: MultiArray<Float>
        
        
        public func rendered() -> CGImage? {
            let tensor = MultiArray<Float>.zeros(self.spectrum.shape[0], self.spectrum.shape[1])
            
            tensor.forEach { indexes, _ in
                tensor[indexes] = hypotf(self.spectrum[indexes[0], indexes[1], 0], self.spectrum[indexes[0], indexes[1], 1])
            }
            
            // transpose and flip y (leading value)
            let new = MultiArray<Float>.zeros(self.spectrum.shape[1], self.spectrum.shape[0])
            let indexesCopy = UnsafeMutableBufferPointer<Int>.allocate(capacity: 2)
            defer { indexesCopy.deallocate() }
            tensor.forEach { indexes, value in
                indexesCopy.copy(from: indexes.baseAddress!, count: 2)
                indexesCopy.swapAt(0, 1)
                indexesCopy[0] = new.shape[0] - 1 - indexesCopy[0]
                new[indexesCopy] = tensor[indexes]
            }
            
            return new.rendered()
        }
        
    }
    
}
