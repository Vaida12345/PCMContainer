//
//  Chroma + DTW.swift
//  PCMContainer
//
//  Created by Vaida on 2026-04-01.
//

import MultiArray
import DetailedDescription


extension PCMContainer.Chroma {
    
    /// Dynamic Time Warping result.
    public struct DTWResult: Sendable {
        
        /// Accumulated path cost.
        public let distance: Float
        
        /// Path-cost normalized by alignment path length.
        public let normalizedDistance: Float
        
        /// Monotonic frame alignment path from start to end.
        public let path: [Point]
        
        @usableFromInline let referenceCoordinates: [Int]
        @usableFromInline let queryCoordinates: [Int]
        @usableFromInline let referenceTargetPrefix: [Double]
        @usableFromInline let queryTargetPrefix: [Double]
        
        @inlinable
        public init(distance: Float, normalizedDistance: Float, path: [Point]) {
            self.distance = distance
            self.normalizedDistance = normalizedDistance
            self.path = path
            
            var referenceCoordinates = [Int]()
            referenceCoordinates.reserveCapacity(path.count)
            var queryCoordinates = [Int]()
            queryCoordinates.reserveCapacity(path.count)
            var referenceTargetPrefix = [Double](repeating: 0, count: path.count + 1)
            var queryTargetPrefix = [Double](repeating: 0, count: path.count + 1)
            
            for (index, point) in path.enumerated() {
                referenceCoordinates.append(point.reference)
                queryCoordinates.append(point.query)
                referenceTargetPrefix[index + 1] = referenceTargetPrefix[index] + Double(point.query)
                queryTargetPrefix[index + 1] = queryTargetPrefix[index] + Double(point.reference)
            }
            
            self.referenceCoordinates = referenceCoordinates
            self.queryCoordinates = queryCoordinates
            self.referenceTargetPrefix = referenceTargetPrefix
            self.queryTargetPrefix = queryTargetPrefix
        }
        
        /// A frame alignment produced by Dynamic Time Warping.
        public struct Point: Sendable {
            
            /// Frame index in the reference sequence (`self`).
            public let reference: Int
            
            /// Frame index in the query sequence (`other`).
            public let query: Int
            
            @inlinable
            public init(reference: Int, query: Int) {
                self.reference = reference
                self.query = query
            }
        }
        
        public enum FrameSpace: Sendable {
            /// reference sequence (`self`), aka `lhs`.
            case reference
            /// query sequence (`other`), aka `rhs`.
            case query
        }
        
        /// Converts a frame position from one aligned sequence into the corresponding position in the other sequence.
        ///
        /// Exact integer frame values are averaged across all matching DTW path points.
        /// Fractional frame values are linearly interpolated along the monotonic DTW path.
        /// - Complexity: O(log(path.count)) time, O(1) extra space.
        @inlinable
        public func convert(frame: Double, to destination: FrameSpace) -> Double? {
            switch destination {
            case .query:
                return convert(
                    frame: frame,
                    sourceCoordinates: referenceCoordinates,
                    targetPrefix: referenceTargetPrefix,
                    targetAt: { index in Double(path[index].query) }
                )
            case .reference:
                return convert(
                    frame: frame,
                    sourceCoordinates: queryCoordinates,
                    targetPrefix: queryTargetPrefix,
                    targetAt: { index in Double(path[index].reference) }
                )
            }
        }
        
        @inlinable
        func convert(
            frame: Double,
            sourceCoordinates: [Int],
            targetPrefix: [Double],
            targetAt: (_ index: Int) -> Double
        ) -> Double? {
            guard !sourceCoordinates.isEmpty else { return nil }
            
            let firstSource = Double(sourceCoordinates[0])
            let lastSource = Double(sourceCoordinates[sourceCoordinates.count - 1])
            let clamped = min(max(frame, firstSource), lastSource)
            
            if clamped.rounded(.towardZero) == clamped {
                let exactFrame = Int(clamped)
                let start = Self.lowerBound(sourceCoordinates, value: exactFrame)
                let end = Self.lowerBound(sourceCoordinates, value: exactFrame + 1)
                
                if start < end {
                    let sum = targetPrefix[end] - targetPrefix[start]
                    return sum / Double(end - start)
                }
            }
            
            let upper = Self.firstIndexGreaterThan(sourceCoordinates, value: clamped)
            guard upper > 0 else { return targetAt(0) }
            guard upper < sourceCoordinates.count else { return targetAt(sourceCoordinates.count - 1) }
            
            let lower = upper - 1
            let lowerSource = Double(sourceCoordinates[lower])
            let upperSource = Double(sourceCoordinates[upper])
            let lowerTarget = targetAt(lower)
            let upperTarget = targetAt(upper)
            
            guard upperSource > lowerSource else { return lowerTarget }
            
            let progress = (clamped - lowerSource) / (upperSource - lowerSource)
            return lowerTarget + (upperTarget - lowerTarget) * progress
        }
        
        @inlinable
        static func lowerBound(_ values: [Int], value: Int) -> Int {
            var low = 0
            var high = values.count
            
            while low < high {
                let mid = (low + high) >> 1
                if values[mid] < value {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            
            return low
        }
        
        @inlinable
        static func firstIndexGreaterThan(_ values: [Int], value: Double) -> Int {
            var low = 0
            var high = values.count
            
            while low < high {
                let mid = (low + high) >> 1
                if Double(values[mid]) <= value {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            
            return low
        }
        
        @inlinable
        static func sourceCoordinate(of point: Point, in source: FrameSpace) -> Int {
            switch source {
            case .reference:
                return point.reference
            case .query:
                return point.query
            }
        }
        
        @inlinable
        static func targetCoordinate(of point: Point, in source: FrameSpace) -> Int {
            switch source {
            case .reference:
                return point.query
            case .query:
                return point.reference
            }
        }
    }
    
    /// Computes Dynamic Time Warping alignment against another chroma sequence using dynamic programming.
    ///
    /// - Parameters:
    ///   - other: Chroma sequence to align with `self`.
    ///   - window: Optional Sakoe-Chiba half-window in frames. If `nil`, no window is applied.
    /// - Returns: DTW distance, normalized distance, and frame alignment path.
    public func dynamicTimeWarping(to other: Self, window: Int? = nil) -> DTWResult {
        let n = self.frameCount
        let m = other.frameCount
        
        assert(!(n == 0 || m == 0))
        
        let band = max(window ?? max(n, m), abs(n - m))
        
        let columnCount = m + 1
        let inf = Float.infinity
        var accumulated = [Float](repeating: inf, count: (n + 1) * columnCount)
        
        @inline(__always)
        func offset(_ i: Int, _ j: Int) -> Int {
            i * columnCount + j
        }
        
        accumulated[offset(0, 0)] = 0
        
        var i = 1
        while i <= n {
            let jStart = max(1, i - band)
            let jEnd = min(m, i + band)
            
            guard jStart <= jEnd else {
                i += 1
                continue
            }
            
            var j = jStart
            while j <= jEnd {
                let cost = chromaFrameDistance(self.values, i - 1, other.values, j - 1)
                let diagonal = accumulated[offset(i - 1, j - 1)]
                let up = accumulated[offset(i - 1, j)]
                let left = accumulated[offset(i, j - 1)]
                accumulated[offset(i, j)] = cost + min(diagonal, min(up, left))
                j += 1
            }
            
            i += 1
        }
        
        let total = accumulated[offset(n, m)]
        guard total.isFinite else {
            return DTWResult(distance: .infinity, normalizedDistance: .infinity, path: [])
        }
        
        var path = [DTWResult.Point]()
        path.reserveCapacity(n + m)
        
        i = n
        var j = m
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                path.append(DTWResult.Point(reference: i - 1, query: j - 1))
            } else if i > 0 {
                path.append(DTWResult.Point(reference: i - 1, query: 0))
            } else {
                path.append(DTWResult.Point(reference: 0, query: j - 1))
            }
            
            if i == 0 {
                j -= 1
                continue
            }
            
            if j == 0 {
                i -= 1
                continue
            }
            
            let diagonal = accumulated[offset(i - 1, j - 1)]
            let up = accumulated[offset(i - 1, j)]
            let left = accumulated[offset(i, j - 1)]
            
            if diagonal <= up && diagonal <= left {
                i -= 1
                j -= 1
            } else if up <= left {
                i -= 1
            } else {
                j -= 1
            }
        }
        
        path.reverse()
        
        let normalized = total / Float(max(path.count, 1))
        return DTWResult(distance: total, normalizedDistance: normalized, path: path)
    }
}

@inline(__always)
private func chromaFrameDistance(
    _ reference: MultiArray<Float>,
    _ referenceFrame: Int,
    _ query: MultiArray<Float>,
    _ queryFrame: Int
) -> Float {
    var distance: Float = 0
    var pitchClass = 0
    
    while pitchClass < 12 {
        distance += abs(reference[referenceFrame, pitchClass] - query[queryFrame, pitchClass])
        pitchClass += 1
    }
    
    return distance
}


extension PCMContainer.Chroma.DTWResult: DetailedStringConvertible {
    
    public func detailedDescription(using descriptor: DetailedDescription.Descriptor<PCMContainer.Chroma.DTWResult>) -> any DescriptionBlockProtocol {
        descriptor.container {
            descriptor.raw("distance: \(self.distance) (normalized: \(self.normalizedDistance))")
            descriptor.container("path") {
                descriptor.forEach(self.path) { point in
                    descriptor.raw("\(point.reference) -> \(point.query)")
                }
            }
        }
    }
    
}
