//
//  NoOpAdapter.swift
//  room-visualizer
//
//  No-op adapter for testing StyleTransferEngine pipeline overhead
//

import Foundation
import CoreVideo
import StyleTransferEngine

/// No-op implementation of StyleModelAdapter for performance testing
final class NoOpAdapter: StyleModelAdapter {
    init() {}

    func load(modelURL: URL) throws {
        // No-op: no model to load
    }

    func encode(input pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        // Return input unchanged to measure pipeline overhead
        return pixelBuffer
    }
}
