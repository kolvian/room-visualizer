//
//  TestModelLoad.swift
//  room-visualizer
//
//  Test utility to verify CoreML model loading
//

import Foundation
import CoreML

final class TestModelLoad {
    static func testLoad() {
        guard let modelURL = Bundle.main.url(forResource: "starry_night", withExtension: "mlpackage") else {
            print("⚠️ Model 'starry_night.mlpackage' not found in bundle")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            let desc = model.modelDescription

            print("✅ Model loaded successfully")
            print("Inputs: \(desc.inputDescriptionsByName.keys.joined(separator: ", "))")
            print("Outputs: \(desc.outputDescriptionsByName.keys.joined(separator: ", "))")

        } catch {
            print("⚠️ Failed to load model: \(error.localizedDescription)")
        }
    }
}
