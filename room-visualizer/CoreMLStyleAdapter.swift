//
//  CoreMLStyleAdapter.swift
//  room-visualizer
//
//  Created by Eliot Pontarelli on 10/18/25.
//

import Foundation
import CoreML
import CoreImage
import VideoToolbox
import StyleTransferEngine

/// Production adapter for Core ML style transfer models
/// Drop your .mlmodel into the app bundle and update modelName
class CoreMLStyleAdapter: StyleModelAdapter {
    private var model: MLModel?
    private var modelURL: URL?
    private var isLoading = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // TODO: Update this to match your exported model name (without .mlmodelc extension)
    private let modelName = "starry_night" // Change to match your style name
    
    func load(modelURL: URL) throws {
        self.modelURL = modelURL
    }

    private func ensureModelLoaded() throws {
        guard model == nil else { return }

        guard let modelURL = modelURL else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Model URL not set"])
        }

        guard !isLoading else { return }
        isLoading = true

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            isLoading = false
            throw NSError(domain: "CoreMLStyleAdapter", code: 7,
                         userInfo: [NSLocalizedDescriptionKey: "Model file does not exist"])
        }
        
        let compiledURL: URL
        do {
            let pathExtension = modelURL.pathExtension
            if pathExtension == "mlmodelc" || pathExtension == "mlpackage" {
                compiledURL = modelURL
            } else {
                compiledURL = try MLModel.compileModel(at: modelURL)
            }
        } catch {
            isLoading = false
            throw error
        }

        let config = MLModelConfiguration()
        // Use CPU and GPU on simulator, all units on device
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuAndGPU
        #else
        config.computeUnits = .all
        #endif
        config.allowLowPrecisionAccumulationOnGPU = true

        do {
            model = try MLModel(contentsOf: compiledURL, configuration: config)
            isLoading = false
        } catch {
            isLoading = false
            throw error
        }
    }
    
    func encode(input pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        try ensureModelLoaded()

        guard let model = model else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let modelDescription = model.modelDescription

        guard let inputFeatureName = modelDescription.inputDescriptionsByName.keys.first else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Model has no input features"])
        }

        let inputFeature = MLFeatureValue(pixelBuffer: pixelBuffer)
        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputFeatureName: inputFeature])

        let output = try model.prediction(from: inputProvider)

        guard let outputFeatureName = modelDescription.outputDescriptionsByName.keys.first else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 4,
                         userInfo: [NSLocalizedDescriptionKey: "Model has no output features"])
        }

        guard let outputFeature = output.featureValue(for: outputFeatureName),
              let outputBuffer = outputFeature.imageBufferValue else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to extract output buffer"])
        }

        return outputBuffer
    }
}

// MARK: - Convenience Initializer for Bundle Models

extension CoreMLStyleAdapter {
    /// Load a model from the app bundle by name
    /// - Parameter modelName: Name of the .mlmodel, .mlmodelc, or .mlpackage in the bundle (without extension)
    static func fromBundle(modelName: String) throws -> CoreMLStyleAdapter {
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlpackage") ??
                             Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") ??
                             Bundle.main.url(forResource: modelName, withExtension: "mlmodel") else {
            throw NSError(domain: "CoreMLStyleAdapter", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Model '\(modelName)' not found in bundle"])
        }

        let adapter = CoreMLStyleAdapter()
        try adapter.load(modelURL: modelURL)
        return adapter
    }
}
