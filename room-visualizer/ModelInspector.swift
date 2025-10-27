import CoreML
import Foundation

func inspectModel() {
    guard let modelURL = Bundle.main.url(forResource: "starry_night", withExtension: "mlpackage") else {
        print("Failed to find model")
        return
    }
    
    do {
        let model = try MLModel(contentsOf: modelURL)
        let desc = model.modelDescription
        
        print("=== MODEL INSPECTION ===")
        print("\nInputs:")
        for (name, feature) in desc.inputDescriptionsByName {
            print("  - \(name): \(feature.type)")
            if let constraint = feature.imageConstraint {
                print("    Size: \(constraint.pixelsWide)x\(constraint.pixelsHigh)")
                print("    Format: \(constraint.pixelFormatType)")
            }
        }
        
        print("\nOutputs:")
        for (name, feature) in desc.outputDescriptionsByName {
            print("  - \(name): \(feature.type)")
            if let constraint = feature.imageConstraint {
                print("    Size: \(constraint.pixelsWide)x\(constraint.pixelsHigh)")
                print("    Format: \(constraint.pixelFormatType)")
            }
        }
    } catch {
        print("Error loading model: \(error)")
    }
}
