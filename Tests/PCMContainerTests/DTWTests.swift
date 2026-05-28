//
//  DTWTests.swift
//  PCMContainer
//
//  Created by Vaida on 2026-05-28.
//

import Testing
@testable import PCMContainer
import MultiArray


@Suite("Dynamic Time Warping")
struct DTWTests {

    /// Creates a Chroma with specified per-frame values.
    /// Values are arranged as a flat array of per-frame pitch-class vectors.
    private func makeChroma(
        frames: [[Float]],
        hopLength: Int = 1024,
        sampleRate: Double = 44100
    ) -> PCMContainer.Chroma {
        let frameCount = frames.count
        let values = MultiArray<Float>.zeros(frameCount, 12)
        for f in 0..<frameCount {
            for p in 0..<min(12, frames[f].count) {
                values[f, p] = frames[f][p]
            }
        }
        return PCMContainer.Chroma(
            values: values,
            hopLength: hopLength,
            sampleRate: sampleRate
        )
    }

    // MARK: - DTWResult.Point

    @Test("DTWResult.Point init")
    func pointInit() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 3)

        #expect(point.reference == 5)
        #expect(point.query == 3)
    }

    @Test("DTWResult.Point — zero indices")
    func pointZeroIndices() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0)

        #expect(point.reference == 0)
        #expect(point.query == 0)
    }

    @Test("DTWResult.Point — large indices")
    func pointLargeIndices() {
        let point = PCMContainer.Chroma.DTWResult.Point(
            reference: Int.max / 2,
            query: Int.max / 2
        )

        #expect(point.reference == Int.max / 2)
        #expect(point.query == Int.max / 2)
    }

    // MARK: - DTWResult init

    @Test("DTWResult init — builds coordinates and prefix arrays")
    func dtwResultInit() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 1),
            PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 2),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 4.0,
            normalizedDistance: 1.0,
            path: path
        )

        #expect(result.distance == 4.0)
        #expect(result.normalizedDistance == 1.0)
        #expect(result.path.count == 4)
    }

    @Test("DTWResult init — empty path")
    func dtwResultInitEmptyPath() {
        let result = PCMContainer.Chroma.DTWResult(
            distance: .infinity,
            normalizedDistance: .infinity,
            path: []
        )

        #expect(result.distance == .infinity)
        #expect(result.path.isEmpty)
    }

    @Test("DTWResult init — single point path")
    func dtwResultInitSinglePoint() {
        let path = [PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0)]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 0.0,
            normalizedDistance: 0.0,
            path: path
        )

        #expect(result.distance == 0.0)
        #expect(result.path.count == 1)
        #expect(result.path[0].reference == 0)
        #expect(result.path[0].query == 0)
    }

    // MARK: - lowerBound (internal)

    @Test("lowerBound — empty array")
    func lowerBoundEmpty() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound([], value: 5)
        #expect(result == 0)
    }

    @Test("lowerBound — value less than all elements")
    func lowerBoundBeforeAll() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [1, 3, 5, 7], value: 0
        )
        #expect(result == 0)
    }

    @Test("lowerBound — value greater than all elements")
    func lowerBoundAfterAll() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [1, 3, 5, 7], value: 8
        )
        #expect(result == 4)
    }

    @Test("lowerBound — exact match")
    func lowerBoundExactMatch() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [1, 3, 5, 7], value: 5
        )
        #expect(result == 2)
    }

    @Test("lowerBound — between elements")
    func lowerBoundBetweenElements() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [1, 3, 5, 7], value: 4
        )
        #expect(result == 2)
    }

    @Test("lowerBound — duplicate values")
    func lowerBoundDuplicates() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [1, 1, 1, 2, 2], value: 1
        )
        #expect(result == 0)
    }

    @Test("lowerBound — single element, match")
    func lowerBoundSingleElementMatch() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [5], value: 5
        )
        #expect(result == 0)
    }

    @Test("lowerBound — single element, below")
    func lowerBoundSingleElementBelow() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [5], value: 3
        )
        #expect(result == 0)
    }

    @Test("lowerBound — single element, above")
    func lowerBoundSingleElementAbove() {
        let result = PCMContainer.Chroma.DTWResult.lowerBound(
            [5], value: 7
        )
        #expect(result == 1)
    }

    // MARK: - firstIndexGreaterThan (internal)

    @Test("firstIndexGreaterThan — empty array")
    func firstIndexGreaterThanEmpty() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [], value: 5.0
        )
        #expect(result == 0)
    }

    @Test("firstIndexGreaterThan — value less than first element")
    func firstIndexGreaterThanBeforeAll() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 3, 5, 7], value: 0.0
        )
        #expect(result == 0)
    }

    @Test("firstIndexGreaterThan — value greater than all elements")
    func firstIndexGreaterThanAfterAll() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 3, 5, 7], value: 8.0
        )
        #expect(result == 4)
    }

    @Test("firstIndexGreaterThan — value equals an element (strict greater)")
    func firstIndexGreaterThanEqualToElement() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 3, 5, 7], value: 5.0
        )
        #expect(result == 3)  // First > 5 is 7 at index 3
    }

    @Test("firstIndexGreaterThan — between elements")
    func firstIndexGreaterThanBetweenElements() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 3, 5, 7], value: 4.0
        )
        #expect(result == 2)  // First > 4 is 5 at index 2
    }

    @Test("firstIndexGreaterThan — fractional value")
    func firstIndexGreaterThanFractional() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 3, 5, 7], value: 4.5
        )
        #expect(result == 2)  // First > 4.5 is 5 at index 2
    }

    @Test("firstIndexGreaterThan — duplicate values")
    func firstIndexGreaterThanDuplicates() {
        let result = PCMContainer.Chroma.DTWResult.firstIndexGreaterThan(
            [1, 1, 3, 3, 5], value: 1.0
        )
        #expect(result == 2)  // First > 1 is 3 at index 2
    }

    // MARK: - sourceCoordinate / targetCoordinate (internal)

    @Test("sourceCoordinate — reference space")
    func sourceCoordinateReference() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 3)

        #expect(
            PCMContainer.Chroma.DTWResult.sourceCoordinate(
                of: point, in: .reference
            ) == 5
        )
    }

    @Test("sourceCoordinate — query space")
    func sourceCoordinateQuery() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 3)

        #expect(
            PCMContainer.Chroma.DTWResult.sourceCoordinate(
                of: point, in: .query
            ) == 3
        )
    }

    @Test("targetCoordinate — reference space (returns query)")
    func targetCoordinateReference() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 3)

        #expect(
            PCMContainer.Chroma.DTWResult.targetCoordinate(
                of: point, in: .reference
            ) == 3
        )
    }

    @Test("targetCoordinate — query space (returns reference)")
    func targetCoordinateQuery() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 3)

        #expect(
            PCMContainer.Chroma.DTWResult.targetCoordinate(
                of: point, in: .query
            ) == 5
        )
    }

    @Test("sourceCoordinate / targetCoordinate — zero indices")
    func sourceTargetCoordinateZero() {
        let point = PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0)

        #expect(
            PCMContainer.Chroma.DTWResult.sourceCoordinate(of: point, in: .reference) == 0
        )
        #expect(
            PCMContainer.Chroma.DTWResult.targetCoordinate(of: point, in: .reference) == 0
        )
    }

    // MARK: - DTWResult.convert(frame:to:) — public API

    @Test("convert(frame:to:) — empty path returns nil")
    func convertFrameToEmptyPath() {
        let result = PCMContainer.Chroma.DTWResult(
            distance: .infinity,
            normalizedDistance: .infinity,
            path: []
        )

        #expect(result.convert(frame: 0, to: .query) == nil)
        #expect(result.convert(frame: 0, to: .reference) == nil)
    }

    @Test("convert(frame:to:) — diagonal path, reference to query")
    func convertFrameToDiagonalReferenceToQuery() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 1),
            PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 2),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 0.0,
            normalizedDistance: 0.0,
            path: path
        )

        // Exact integer frames should map directly.
        #expect(result.convert(frame: 0, to: .query) == 0.0)
        #expect(result.convert(frame: 1, to: .query) == 1.0)
        #expect(result.convert(frame: 2, to: .query) == 2.0)
    }

    @Test("convert(frame:to:) — diagonal path, query to reference")
    func convertFrameToDiagonalQueryToReference() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 1),
            PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 2),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 0.0,
            normalizedDistance: 0.0,
            path: path
        )

        #expect(result.convert(frame: 0, to: .reference) == 0.0)
        #expect(result.convert(frame: 1, to: .reference) == 1.0)
        #expect(result.convert(frame: 2, to: .reference) == 2.0)
    }

    @Test("convert(frame:to:) — non-trivial path, reference to query")
    func convertFrameToNonTrivialReferenceToQuery() {
        // Path: (0,0), (1,0), (1,1), (2,2)
        // Reference 0 → Query 0
        // Reference 1 → Query 0, Query 1 (average = 0.5)
        // Reference 2 → Query 2
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 1),
            PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 2),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 2.0,
            normalizedDistance: 0.5,
            path: path
        )

        #expect(result.convert(frame: 0, to: .query) == 0.0)
        #expect(result.convert(frame: 1, to: .query) == 0.5)
        #expect(result.convert(frame: 2, to: .query) == 2.0)
    }

    @Test("convert(frame:to:) — fractional frame interpolation")
    func convertFrameToFractionalInterpolation() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
            PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 10),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 1.0,
            normalizedDistance: 0.5,
            path: path
        )

        // Frame 1.0 (halfway between reference 0 and 2) → query 5.0
        let queryFrame = result.convert(frame: 1.0, to: .query)
        #expect(queryFrame != nil)
        #expect(abs(queryFrame! - 5.0) < 1e-6)
    }

    @Test("convert(frame:to:) — frame before first maps to first")
    func convertFrameToBeforeFirst() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 10),
            PCMContainer.Chroma.DTWResult.Point(reference: 6, query: 11),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 0.0,
            normalizedDistance: 0.0,
            path: path
        )

        // Frame 0 is clamped to first reference frame (5).
        #expect(result.convert(frame: 0, to: .query) == 10.0)
    }

    @Test("convert(frame:to:) — frame after last maps to last")
    func convertFrameToAfterLast() {
        let path = [
            PCMContainer.Chroma.DTWResult.Point(reference: 5, query: 10),
            PCMContainer.Chroma.DTWResult.Point(reference: 6, query: 11),
        ]
        let result = PCMContainer.Chroma.DTWResult(
            distance: 0.0,
            normalizedDistance: 0.0,
            path: path
        )

        // Frame 100 is clamped to last reference frame (6).
        #expect(result.convert(frame: 100, to: .query) == 11.0)
    }

    // MARK: - DTWResult.convert (internal) — direct testing

    @Test("convert(internal) — exact integer frame")
    func convertInternalExactInteger() {
        // Path: (0,0), (1,0), (1,1), (2,2)
        // Converting reference frame 1 to query:
        // sourceCoordinates = [0, 1, 1, 2]
        // targetPrefix = [0, 0, 0, 1, 3]  (query prefix sums)
        let sourceCoordinates = [0, 1, 1, 2]
        let targetPrefix = [0.0, 0.0, 0.0, 1.0, 3.0]

        let result = PCMContainer.Chroma.DTWResult(
            distance: 0,
            normalizedDistance: 0,
            path: [
                PCMContainer.Chroma.DTWResult.Point(reference: 0, query: 0),
                PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 0),
                PCMContainer.Chroma.DTWResult.Point(reference: 1, query: 1),
                PCMContainer.Chroma.DTWResult.Point(reference: 2, query: 2),
            ]
        )

        // Test via the public API which delegates to internal convert.
        let queryFrame = result.convert(frame: 1.0, to: .query)
        #expect(queryFrame == 0.5)
    }

    // MARK: - dynamicTimeWarping

    @Test("DTW — identical chroma gives zero distance")
    func dtwIdenticalChroma() {
        let chroma = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = chroma.dynamicTimeWarping(to: chroma)

        #expect(result.distance == 0.0)
        #expect(result.normalizedDistance == 0.0)
        #expect(result.path.count == 3)
        #expect(result.path[0].reference == 0)
        #expect(result.path[0].query == 0)
        #expect(result.path[1].reference == 1)
        #expect(result.path[1].query == 1)
        #expect(result.path[2].reference == 2)
        #expect(result.path[2].query == 2)
    }

    @Test("DTW — different chroma with known cost")
    func dtwDifferentChroma() {
        // Reference: energy in pitch classes 0, 1, 2
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        // Query: energy in pitch classes 0, 1 (swapped)
        let query = makeChroma(frames: [
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = reference.dynamicTimeWarping(to: query)

        // Cost per pair:
        // d(ref0, query0) = |1-0| + |0-1| = 2
        // d(ref0, query1) = |1-1| + |0-0| = 0
        // d(ref1, query0) = |0-0| + |1-1| = 0
        // d(ref1, query1) = |0-1| + |1-0| = 2
        //
        // Optimal path: (0,1), (1,1) or (0,0), (1,0)
        // Both have cost: d(0,1) + d(1,1) = 0+2 = 2 or d(0,0) + d(1,0) = 2+0 = 2
        // With diagonal bias, path is (0,0), (1,1) with cost: 2+2 = 4

        #expect(result.distance == 4.0)
        #expect(result.normalizedDistance == 2.0)  // 4 / 2
        #expect(result.path.count == 2)
    }

    @Test("DTW — sequences of different lengths")
    func dtwDifferentLengths() {
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let query = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = reference.dynamicTimeWarping(to: query)

        #expect(result.distance.isFinite)
        #expect(!result.path.isEmpty)
        // Path should start at (0,0) and end at (2,1).
        #expect(result.path.first?.reference == 0)
        #expect(result.path.first?.query == 0)
        #expect(result.path.last?.reference == 2)
        #expect(result.path.last?.query == 1)
    }

    @Test("DTW — with Sakoe-Chiba window")
    func dtwWithWindow() {
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let query = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = reference.dynamicTimeWarping(to: query, window: 2)

        #expect(result.distance.isFinite)
        #expect(!result.path.isEmpty)
    }

    @Test("DTW — single frame each")
    func dtwSingleFrameEach() {
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])
        let query = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = reference.dynamicTimeWarping(to: query)

        #expect(result.distance == 0.0)
        #expect(result.path.count == 1)
        #expect(result.path[0].reference == 0)
        #expect(result.path[0].query == 0)
    }

    @Test("DTW — fully different single-frame chroma")
    func dtwSingleFrameDifferent() {
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])
        let query = makeChroma(frames: [
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        ])

        let result = reference.dynamicTimeWarping(to: query)

        // L1 distance between [1,0,...] and [0,...,1] = |1-0|+|0-1| = 2
        #expect(result.distance == 2.0)
        #expect(result.path.count == 1)
    }

    @Test("DTW — path is monotonic")
    func dtwPathIsMonotonic() {
        let reference = makeChroma(frames: [
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])
        let query = makeChroma(frames: [
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ])

        let result = reference.dynamicTimeWarping(to: query)

        // Verify monotonicity: both coordinates non-decreasing.
        for i in 1..<result.path.count {
            #expect(result.path[i].reference >= result.path[i - 1].reference)
            #expect(result.path[i].query >= result.path[i - 1].query)
            // At least one coordinate must increase.
            #expect(
                result.path[i].reference > result.path[i - 1].reference ||
                result.path[i].query > result.path[i - 1].query
            )
        }
    }
}
