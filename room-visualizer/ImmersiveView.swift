//
//  ImmersiveView.swift
//  room-visualizer
//
//  Created by Eliot Pontarelli on 9/12/25.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ARKit
import AVFoundation
import CoreML

struct ImmersiveView: View {
    @Environment(AppModel.self) var appModel

    @State private var worldAnchor = AnchorEntity(.world(transform: matrix_identity_float4x4))
    @State private var planeEntities: [UUID: ModelEntity] = [:]
    @State private var meshEntities: [UUID: ModelEntity] = [:]
    @State private var arSession: ARKitSession?
    @State private var planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
    @State private var worldTracking = WorldTrackingProvider()
    @State private var styleTransferModel: MLModel?
    @State private var videoPassthrough: VideoPassthroughSimulator?
    @State private var videoDisplayEntity: ModelEntity?

    // Detect if running in simulator
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    var body: some View {
        RealityView { content in
            content.add(worldAnchor)

            // Load ML model
            await loadStyleTransferModel()

            if isSimulator {
                // Use video passthrough simulation
                await setupVideoPassthrough()
            } else {
                // Use real ARKit on device
                await startARSession()
            }

        } update: { content in
            // Update loop for dynamic content
        }
        .task {
            if !isSimulator {
                await processPlaneDetection()
            }
        }
        .onDisappear {
            videoPassthrough?.stop()
        }
    }
    
    private func startARSession() async {
        let session = ARKitSession()
        self.arSession = session

        do {
            try await session.run([planeDetection, worldTracking])
        } catch {
            print("⚠️ Failed to start ARKit session: \(error)")
        }
    }
    
    private func processPlaneDetection() async {
        for await update in planeDetection.anchorUpdates {
            switch update.event {
            case .added, .updated:
                await addOrUpdatePlane(anchor: update.anchor)
            case .removed:
                removePlane(id: update.anchor.id)
            }
        }
    }
    
    @MainActor
    private func addOrUpdatePlane(anchor: PlaneAnchor) async {
        let id = anchor.id
        let transform = anchor.originFromAnchorTransform
        
        if let existing = planeEntities[id] {
            existing.transform.matrix = transform
        } else {
            // Create a semi-transparent plane mesh
            let mesh = MeshResource.generatePlane(width: 2.0, depth: 2.0)
            
            // Create material with style transfer texture
            var material = SimpleMaterial()
            material.color = .init(tint: .white.withAlphaComponent(0.8))
            
            // TODO: Apply ML styled texture here
            // For now, use a colored overlay to show where planes are detected
            let hue = Float.random(in: 0...1)
            material.color = .init(tint: UIColor(hue: CGFloat(hue), saturation: 0.6, brightness: 0.9, alpha: 0.5))
            
            let planeEntity = ModelEntity(mesh: mesh, materials: [material])
            planeEntity.transform.matrix = transform
            
            // Scale plane to match detected size
            let extent = anchor.geometry.extent
            planeEntity.scale = [extent.width, 1.0, extent.height]
            
            worldAnchor.addChild(planeEntity)
            planeEntities[id] = planeEntity
        }
    }

    private func removePlane(id: UUID) {
        guard let entity = planeEntities.removeValue(forKey: id) else { return }
        entity.removeFromParent()
    }
    
    private func loadStyleTransferModel() async {
        do {
            guard let modelURL = Bundle.main.url(forResource: "starry_night", withExtension: "mlpackage") ??
                                 Bundle.main.url(forResource: "starry_night", withExtension: "mlmodelc") else {
                print("⚠️ Model 'starry_night' not found in bundle")
                return
            }

            let config = MLModelConfiguration()
            // Use CPU and GPU on simulator, all units on device
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuAndGPU
            #else
            config.computeUnits = .all
            #endif
            let model = try MLModel(contentsOf: modelURL, configuration: config)

            print("✅ Style transfer model loaded successfully")

            await MainActor.run {
                self.styleTransferModel = model
            }

        } catch {
            print("⚠️ Failed to load style transfer model: \(error)")
        }
    }
    
    private func setupVideoPassthrough() async {
        guard let model = styleTransferModel else {
            print("⚠️ Cannot setup video passthrough: model not loaded")
            return
        }

        // Try to load video from bundle
        // Note: You need to add a video file to your bundle (e.g., "test-room.mp4")
        guard let videoURL = Bundle.main.url(forResource: "test-room", withExtension: "mp4") else {
            print("⚠️ Video 'test-room.mp4' not found in bundle")
            print("💡 Add a video file to simulate passthrough in the simulator")
            // Fallback to demo planes if no video
            await createDemoPlanes()
            return
        }

        guard let simulator = VideoPassthroughSimulator(videoURL: videoURL, model: model) else {
            print("⚠️ Failed to create video passthrough simulator")
            await createDemoPlanes()
            return
        }

        videoPassthrough = simulator

        // Create a full-screen quad to display the video
        await createVideoDisplayQuad()

        // Set up frame callback (capture videoDisplayEntity to avoid reference cycles)
        let displayEntity = videoDisplayEntity
        simulator.onFrameAvailable = { styledBuffer in
            Task { @MainActor in
                guard let entity = displayEntity else { return }
                await updateVideoTexture(for: entity, with: styledBuffer)
            }
        }

        // Start playback
        simulator.start()
    }

    @MainActor
    private func createVideoDisplayQuad() async {
        // Create a large plane to simulate full passthrough
        let mesh = MeshResource.generatePlane(width: 10.0, depth: 5.625) // 16:9 aspect ratio
        var material = SimpleMaterial()
        material.color = .init(tint: .white)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = [0, 0, -5] // Place in front of user

        worldAnchor.addChild(entity)
        videoDisplayEntity = entity
    }

    @MainActor
    private func updateVideoTexture(for entity: ModelEntity, with pixelBuffer: CVPixelBuffer) async {
        do {
            // Convert pixel buffer to texture
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                return
            }

            let texture = try await TextureResource(image: cgImage, options: .init(semantic: .color))

            // Update material
            var material = SimpleMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            entity.model?.materials = [material]

        } catch {
            // Silently fail - don't spam console
        }
    }
    
    @MainActor
    private func createDemoPlanes() async {
        print("Creating demo planes (fallback mode)")

        let demoPlanes: [(position: SIMD3<Float>, size: (width: Float, height: Float), orientation: String)] = [
            (SIMD3<Float>(0, 0, -2), (2.0, 2.0), "wall"),
            (SIMD3<Float>(-1.5, 0, -1), (1.5, 1.5), "wall"),
            (SIMD3<Float>(1.5, 0, -1.5), (1.5, 1.5), "wall"),
            (SIMD3<Float>(0, -1, -1.5), (2.5, 2.5), "floor")
        ]

        for (index, planeData) in demoPlanes.enumerated() {
            let mesh = MeshResource.generatePlane(width: planeData.size.width, depth: planeData.size.height)
            var material = SimpleMaterial()

            // Try to apply style transfer if model is available
            if let model = styleTransferModel,
               let styledTexture = await applyStyleTransfer(model: model, planeSize: planeData.size) {
                material.color = .init(tint: .white, texture: .init(styledTexture))
            } else {
                // Fallback to colored plane
                material.color = .init(tint: UIColor(hue: CGFloat(index) * 0.2, saturation: 0.6, brightness: 0.9, alpha: 0.8))
            }

            let planeEntity = ModelEntity(mesh: mesh, materials: [material])
            planeEntity.position = planeData.position

            if planeData.orientation == "floor" {
                planeEntity.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            }

            worldAnchor.addChild(planeEntity)
            planeEntities[UUID()] = planeEntity
        }
    }
    
    private func applyStyleTransfer(model: MLModel, planeSize: (width: Float, height: Float)) async -> MaterialParameters.Texture? {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)

        let inputImage = renderer.image { context in
            let colors = [UIColor.blue.cgColor, UIColor.green.cgColor, UIColor.yellow.cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }

        do {
            guard let inputArray = inputImage.toMLMultiArray() else {
                return nil
            }

            let inputFeature = MLFeatureValue(multiArray: inputArray)
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: ["input_image": inputFeature])

            let prediction = try await model.prediction(from: inputProvider)

            guard let outputFeature = prediction.featureValue(for: "stylized_image"),
                  let outputArray = outputFeature.multiArrayValue,
                  let outputImage = outputArray.toCGImage(width: 256, height: 256) else {
                return nil
            }

            let texture = try await TextureResource(image: outputImage, options: .init(semantic: .color))
            return MaterialParameters.Texture(texture)

        } catch {
            return nil
        }
    }
}

// MARK: - Helper Extensions
extension UIImage {
    /// Convert UIImage to MLMultiArray in the format expected by style transfer models
    /// Shape: [1, 3, 256, 256] where channels are RGB
    func toMLMultiArray() -> MLMultiArray? {
        let width = 256
        let height = 256
        
        guard let resizedImage = self.resized(to: CGSize(width: width, height: height)) else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(resizedImage.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let array = try? MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32) else {
            return nil
        }
        
        // Use direct pointer access for much better performance
        let channelSize = width * height
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        
        // Convert RGBA pixels to CHW format (channels, height, width)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let arrayIndex = y * width + x
                
                // Extract RGB values from RGBA format and normalize
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                
                // Store in CHW format: [batch=0, channel, height, width]
                // Layout: R channel (0 to channelSize-1), G channel (channelSize to 2*channelSize-1), B channel (2*channelSize to 3*channelSize-1)
                ptr[arrayIndex] = r                      // R channel
                ptr[channelSize + arrayIndex] = g        // G channel
                ptr[2 * channelSize + arrayIndex] = b    // B channel
            }
        }

        return array
    }
    
    func resized(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    func toCVPixelBuffer(format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(self.size.width),
            Int(self.size.height),
            format,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0)) }

        guard let pixelData = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        // Determine bitmap info based on format
        let bitmapInfo: UInt32
        if format == kCVPixelFormatType_32BGRA {
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        } else if format == kCVPixelFormatType_32ARGB {
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        } else {
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        }
        
        guard let context = CGContext(
            data: pixelData,
            width: Int(self.size.width),
            height: Int(self.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.translateBy(x: 0, y: self.size.height)
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        self.draw(in: CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height))
        UIGraphicsPopContext()

        return buffer
    }
}

extension MLMultiArray {
    /// Convert MLMultiArray to CGImage
    /// Expects shape: [1, 3, height, width] in CHW format
    func toCGImage(width: Int, height: Int) -> CGImage? {
        guard self.shape.count == 4,
              self.shape[0].intValue == 1,
              self.shape[1].intValue == 3,
              self.shape[2].intValue == height,
              self.shape[3].intValue == width else {
            return nil
        }
        
        // Create a buffer to hold RGB pixel data
        var pixelData = [UInt8](repeating: 0, count: width * height * 4) // RGBA
        
        // Use direct pointer access for better performance
        let channelSize = width * height
        let ptr = UnsafePointer<Float>(OpaquePointer(self.dataPointer))
        
        // Convert from CHW format to RGBA and denormalize
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let arrayIndex = y * width + x
                
                // Get RGB values from CHW format using direct pointer access
                // Layout: R channel (0 to channelSize-1), G channel (channelSize to 2*channelSize-1), B channel (2*channelSize to 3*channelSize-1)
                let r = ptr[arrayIndex]                    // R channel
                let g = ptr[channelSize + arrayIndex]      // G channel
                let b = ptr[2 * channelSize + arrayIndex]  // B channel
                
                // Clamp and denormalize to 0-255
                pixelData[pixelIndex] = UInt8(max(0, min(255, r * 255.0)))
                pixelData[pixelIndex + 1] = UInt8(max(0, min(255, g * 255.0)))
                pixelData[pixelIndex + 2] = UInt8(max(0, min(255, b * 255.0)))
                pixelData[pixelIndex + 3] = 255 // Alpha
            }
        }

        // Create CGImage from pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return cgImage
    }
}

extension CVPixelBuffer {
    func toCGImage() -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

#Preview(immersionStyle: .full) {
    ImmersiveView()
        .environment(AppModel())
}
