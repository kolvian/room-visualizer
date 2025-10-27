//
//  VideoPassthroughSimulator.swift
//  room-visualizer
//
//  Simulates passthrough camera by playing video and applying style transfer
//

import Foundation
import AVFoundation
import CoreVideo
import CoreML
import CoreImage
import Metal
import MetalKit

/// Simulates camera passthrough in the simulator by playing a video file
/// and applying style transfer to each frame
@MainActor
final class VideoPassthroughSimulator: NSObject {

    // MARK: - Properties

    private let player: AVPlayer
    private let playerItem: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?
    private let styleModel: MLModel
    private let ciContext: CIContext

    // Metal resources for GPU-accelerated conversions
    private let metalDevice: MTLDevice
    private let metalCommandQueue: MTLCommandQueue
    private let bgraToTensorPipeline: MTLComputePipelineState
    private let tensorToBGRAPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    /// Callback invoked when a new styled frame is available
    var onFrameAvailable: ((CVPixelBuffer) -> Void)?

    // MARK: - Initialization

    /// Initialize with a video URL and CoreML model
    /// - Parameters:
    ///   - videoURL: URL to the video file (from bundle or file system)
    ///   - model: CoreML style transfer model
    init?(videoURL: URL, model: MLModel) {
        // Configure video output for pixel buffer extraction
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)

        // Create player item and player
        self.playerItem = AVPlayerItem(url: videoURL)
        self.player = AVPlayer(playerItem: playerItem)
        self.styleModel = model
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Set up Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ Failed to create Metal device")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("⚠️ Failed to create Metal command queue")
            return nil
        }

        guard let library = device.makeDefaultLibrary() else {
            print("⚠️ Failed to load default Metal library")
            return nil
        }

        print("✅ Metal device: \(device.name)")

        self.metalDevice = device
        self.metalCommandQueue = commandQueue

        // Create compute pipelines
        do {
            guard let bgraToTensorFunction = library.makeFunction(name: "convertBGRAToTensor") else {
                print("⚠️ Failed to find Metal function: convertBGRAToTensor")
                return nil
            }

            guard let tensorToBGRAFunction = library.makeFunction(name: "convertTensorToBGRA") else {
                print("⚠️ Failed to find Metal function: convertTensorToBGRA")
                return nil
            }

            self.bgraToTensorPipeline = try device.makeComputePipelineState(function: bgraToTensorFunction)
            self.tensorToBGRAPipeline = try device.makeComputePipelineState(function: tensorToBGRAFunction)

            print("✅ Metal compute pipelines created successfully")
        } catch {
            print("⚠️ Failed to create Metal compute pipelines: \(error)")
            return nil
        }

        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        super.init()

        // Add video output to player item
        playerItem.add(videoOutput)

        // Set up looping
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    deinit {
        // Cleanup without calling stop() to avoid main actor isolation issues
        player.pause()
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Playback Control

    /// Start video playback and frame processing
    func start() {
        player.play()
        startDisplayLink()
    }

    /// Stop video playback and frame processing
    func stop() {
        player.pause()
        stopDisplayLink()
    }

    // MARK: - Private Methods

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(processFrame))
        // Target 15-20 FPS for better performance with style transfer
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func processFrame() {
        let currentTime = playerItem.currentTime()

        // Check if a new frame is available
        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else {
            return
        }

        // Get the pixel buffer
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: currentTime,
            itemTimeForDisplay: nil
        ) else {
            return
        }

        // Apply style transfer
        Task {
            do {
                let styledBuffer = try await applyStyleTransfer(to: pixelBuffer)
                onFrameAvailable?(styledBuffer)
            } catch {
                // Fallback: use original frame if style transfer fails
                print("⚠️ Style transfer failed: \(error)")
                onFrameAvailable?(pixelBuffer)
            }
        }
    }

    private func applyStyleTransfer(to pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
        let originalHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard let inputName = styleModel.modelDescription.inputDescriptionsByName.keys.first else {
            throw VideoPassthroughError.invalidModel
        }

        // Get input description to check expected format
        guard let inputDesc = styleModel.modelDescription.inputDescriptionsByName[inputName] else {
            throw VideoPassthroughError.invalidModel
        }

        print("🔍 Model input type: \(inputDesc.type)")

        let inputFeature: MLFeatureValue

        // Check if model expects multiArray (tensor) or image input
        if let multiArrayConstraint = inputDesc.multiArrayConstraint {
            print("🔍 Model expects MLMultiArray input, shape: \(multiArrayConstraint.shape)")
            // Model expects tensor input - convert pixel buffer to MLMultiArray
            let modelShape = multiArrayConstraint.shape.map { $0.intValue }

            // Extract expected dimensions from model shape
            // Common shapes: [1, 3, H, W] or [3, H, W] or [1, H, W, 3]
            let expectedHeight: Int
            let expectedWidth: Int

            if modelShape.count == 4 {
                // [batch, channels, height, width] or [batch, height, width, channels]
                if modelShape[1] == 3 {
                    // [1, 3, H, W] - channels first
                    expectedHeight = modelShape[2]
                    expectedWidth = modelShape[3]
                } else {
                    // [1, H, W, 3] - channels last
                    expectedHeight = modelShape[1]
                    expectedWidth = modelShape[2]
                }
            } else if modelShape.count == 3 {
                // [3, H, W] or [H, W, 3]
                if modelShape[0] == 3 {
                    expectedHeight = modelShape[1]
                    expectedWidth = modelShape[2]
                } else {
                    expectedHeight = modelShape[0]
                    expectedWidth = modelShape[1]
                }
            } else {
                throw VideoPassthroughError.invalidModel
            }

            let inputWidth = CVPixelBufferGetWidth(pixelBuffer)
            let inputHeight = CVPixelBufferGetHeight(pixelBuffer)

            // Resize pixel buffer if needed
            let resizedBuffer: CVPixelBuffer
            if inputWidth != expectedWidth || inputHeight != expectedHeight {
                resizedBuffer = try resizePixelBuffer(pixelBuffer, width: expectedWidth, height: expectedHeight)
            } else {
                resizedBuffer = pixelBuffer
            }

            // Create MLMultiArray with the model's expected shape
            let multiArray = try MLMultiArray(shape: multiArrayConstraint.shape, dataType: .float32)

            // Fast conversion using vImage
            try convertPixelBufferToMultiArray(resizedBuffer, multiArray: multiArray, width: expectedWidth, height: expectedHeight)

            inputFeature = MLFeatureValue(multiArray: multiArray)
        } else {
            // Model expects image input directly
            print("🔍 Model expects image input directly")
            inputFeature = MLFeatureValue(pixelBuffer: pixelBuffer)
        }

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature])

        // Run prediction
        let output = try await styleModel.prediction(from: inputProvider)

        // Extract output
        guard let outputName = styleModel.modelDescription.outputDescriptionsByName.keys.first,
              let outputFeature = output.featureValue(for: outputName) else {
            throw VideoPassthroughError.predictionFailed
        }

        // Check if output is multiArray or image
        let styledBuffer: CVPixelBuffer
        if let multiArray = outputFeature.multiArrayValue {
            // Convert multiArray back to CVPixelBuffer
            styledBuffer = try convertMultiArrayToPixelBuffer(multiArray)
        } else if let outputBuffer = outputFeature.imageBufferValue {
            // Output is already a pixel buffer
            styledBuffer = outputBuffer
        } else {
            throw VideoPassthroughError.predictionFailed
        }

        // Resize output back to original dimensions if needed
        let outputWidth = CVPixelBufferGetWidth(styledBuffer)
        let outputHeight = CVPixelBufferGetHeight(styledBuffer)

        if outputWidth != originalWidth || outputHeight != originalHeight {
            return try resizePixelBuffer(styledBuffer, width: originalWidth, height: originalHeight)
        } else {
            return styledBuffer
        }
    }

    private func convertPixelBufferToMultiArray(_ pixelBuffer: CVPixelBuffer, multiArray: MLMultiArray, width: Int, height: Int) throws {
        // Create Metal texture from pixel buffer first (before command buffer)
        guard let texture = createMetalTexture(from: pixelBuffer) else {
            print("❌ Failed to create Metal texture from pixel buffer")
            throw VideoPassthroughError.predictionFailed
        }

        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else {
            print("❌ Failed to create Metal command buffer")
            throw VideoPassthroughError.predictionFailed
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("❌ Failed to create Metal compute encoder")
            throw VideoPassthroughError.predictionFailed
        }

        // Set up compute pipeline
        computeEncoder.setComputePipelineState(bgraToTensorPipeline)
        computeEncoder.setTexture(texture, index: 0)

        // Get pointer to MLMultiArray data and create Metal buffer
        let bufferSize = width * height * 3 * MemoryLayout<Float>.stride

        print("🔍 Creating Metal buffer: size=\(bufferSize), width=\(width), height=\(height)")

        // Create a new buffer instead of using bytesNoCopy for better simulator compatibility
        guard let outputBuffer = metalDevice.makeBuffer(
            length: bufferSize,
            options: .storageModeShared
        ) else {
            print("❌ Failed to create Metal buffer (size: \(bufferSize) bytes)")
            computeEncoder.endEncoding()
            throw VideoPassthroughError.predictionFailed
        }

        print("✅ Metal buffer created successfully")

        var widthParam = UInt32(width)
        var heightParam = UInt32(height)

        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 0)
        computeEncoder.setBytes(&widthParam, length: MemoryLayout<UInt32>.stride, index: 1)
        computeEncoder.setBytes(&heightParam, length: MemoryLayout<UInt32>.stride, index: 2)

        // Dispatch threads
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Copy data from Metal buffer to MLMultiArray
        let arrayPointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        let bufferPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        memcpy(arrayPointer, bufferPointer, bufferSize)
    }

    private func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let scaleY = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let scaledImage = ciImage.transformed(by: transform)

        // Create output pixel buffer with IOSurface backing for Metal compatibility
        var resizedBuffer: CVPixelBuffer?
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes as CFDictionary,
            &resizedBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = resizedBuffer else {
            throw VideoPassthroughError.predictionFailed
        }

        // Render to pixel buffer using cached context
        ciContext.render(scaledImage, to: outputBuffer)

        return outputBuffer
    }

    private func convertMultiArrayToPixelBuffer(_ multiArray: MLMultiArray) throws -> CVPixelBuffer {
        // Assuming shape is [1, 3, height, width] or [3, height, width]
        let shape = multiArray.shape.map { $0.intValue }

        let height: Int
        let width: Int

        if shape.count == 4 {
            // [batch, channel, height, width]
            height = shape[2]
            width = shape[3]
        } else if shape.count == 3 {
            // [channel, height, width]
            height = shape[1]
            width = shape[2]
        } else {
            throw VideoPassthroughError.predictionFailed
        }

        // Create output pixel buffer with IOSurface backing for Metal compatibility
        var pixelBuffer: CVPixelBuffer?
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = pixelBuffer else {
            throw VideoPassthroughError.predictionFailed
        }

        // Create Metal texture from pixel buffer (before command buffer)
        guard let texture = createMetalTexture(from: outputBuffer, writable: true) else {
            throw VideoPassthroughError.predictionFailed
        }

        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else {
            throw VideoPassthroughError.predictionFailed
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoPassthroughError.predictionFailed
        }

        // Set up compute pipeline
        computeEncoder.setComputePipelineState(tensorToBGRAPipeline)

        // Get pointer to MLMultiArray data and create Metal buffer
        let arrayPointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        let bufferSize = width * height * 3 * MemoryLayout<Float>.stride

        // Create a new buffer and copy data for better simulator compatibility
        guard let inputBuffer = metalDevice.makeBuffer(
            length: bufferSize,
            options: .storageModeShared
        ) else {
            computeEncoder.endEncoding()
            throw VideoPassthroughError.predictionFailed
        }

        // Copy data from MLMultiArray to Metal buffer
        let bufferPointer = inputBuffer.contents().assumingMemoryBound(to: Float.self)
        memcpy(bufferPointer, arrayPointer, bufferSize)

        var widthParam = UInt32(width)
        var heightParam = UInt32(height)

        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBytes(&widthParam, length: MemoryLayout<UInt32>.stride, index: 1)
        computeEncoder.setBytes(&heightParam, length: MemoryLayout<UInt32>.stride, index: 2)

        // Dispatch threads
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputBuffer
    }

    private func createMetalTexture(from pixelBuffer: CVPixelBuffer, writable: Bool = false) -> MTLTexture? {
        guard let textureCache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTextureOut else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTexture)
    }

    @objc private func playerDidFinishPlaying() {
        // Loop the video
        player.seek(to: .zero)
        player.play()
    }
}

// MARK: - Convenience Initializer

extension VideoPassthroughSimulator {
    /// Create simulator with video from bundle
    /// - Parameters:
    ///   - videoName: Name of video file (without extension)
    ///   - videoExtension: File extension (e.g., "mp4")
    ///   - modelName: Name of CoreML model (without extension)
    static func fromBundle(videoName: String, videoExtension: String = "mp4", modelName: String = "starry_night") -> VideoPassthroughSimulator? {
        // Find video
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: videoExtension) else {
            print("⚠️ Video '\(videoName).\(videoExtension)' not found in bundle")
            return nil
        }

        // Find and load model
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            print("⚠️ Model '\(modelName).mlmodelc' not found in bundle")
            return nil
        }

        do {
            let config = MLModelConfiguration()
            // Use CPU and GPU on simulator, all units on device
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuAndGPU
            #else
            config.computeUnits = .all
            #endif
            let model = try MLModel(contentsOf: modelURL, configuration: config)

            return VideoPassthroughSimulator(videoURL: videoURL, model: model)
        } catch {
            print("⚠️ Failed to load model: \(error)")
            return nil
        }
    }
}

// MARK: - Error Types

enum VideoPassthroughError: Error {
    case invalidModel
    case predictionFailed
}
