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

    // Cached model metadata for performance
    private let inputName: String
    private let outputName: String
    private let expectedWidth: Int
    private let expectedHeight: Int
    private let outputDataType: MLMultiArrayDataType

    // Reusable buffers for performance
    private var cachedInputArray: MLMultiArray?
    private var cachedInputBuffer: MTLBuffer?
    private var cachedOutputBuffer: MTLBuffer?

    // Frame processing control
    private var isProcessingFrame = false

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

        // Cache model metadata for performance
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
            print("⚠️ No input features found in model")
            return nil
        }

        guard let inputDesc = model.modelDescription.inputDescriptionsByName[inputName] else {
            print("⚠️ Failed to get input description for '\(inputName)'")
            return nil
        }

        guard let multiArrayConstraint = inputDesc.multiArrayConstraint else {
            print("⚠️ Input is not a multiArray type (got: \(inputDesc.type))")
            return nil
        }

        guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first else {
            print("⚠️ No output features found in model")
            return nil
        }

        guard let outputDesc = model.modelDescription.outputDescriptionsByName[outputName] else {
            print("⚠️ Failed to get output description for '\(outputName)'")
            return nil
        }

        guard let outputConstraint = outputDesc.multiArrayConstraint else {
            print("⚠️ Output is not a multiArray type (got: \(outputDesc.type))")
            return nil
        }

        self.inputName = inputName
        self.outputName = outputName
        self.outputDataType = outputConstraint.dataType

        // Extract expected dimensions from model shape
        let modelShape = multiArrayConstraint.shape.map { $0.intValue }
        if modelShape.count == 4 {
            if modelShape[1] == 3 {
                // [1, 3, H, W] - channels first
                self.expectedHeight = modelShape[2]
                self.expectedWidth = modelShape[3]
            } else {
                // [1, H, W, 3] - channels last
                self.expectedHeight = modelShape[1]
                self.expectedWidth = modelShape[2]
            }
        } else if modelShape.count == 3 {
            if modelShape[0] == 3 {
                self.expectedHeight = modelShape[1]
                self.expectedWidth = modelShape[2]
            } else {
                self.expectedHeight = modelShape[0]
                self.expectedWidth = modelShape[1]
            }
        } else {
            print("⚠️ Unsupported model shape: \(modelShape)")
            return nil
        }

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
        isProcessingFrame = false
    }

    /// Clear cached buffers (call when switching models or dimensions change)
    func clearCache() {
        cachedInputArray = nil
        cachedInputBuffer = nil
        cachedOutputBuffer = nil
    }

    // MARK: - Private Methods

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(processFrame))
        // Target 10-15 FPS on simulator (CPU-only), higher on device
        #if targetEnvironment(simulator)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        #else
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        #endif
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private var debugFrameCount = 0

    @objc private func processFrame() {
        debugFrameCount += 1
        if debugFrameCount == 1 {
            print("🎬 processFrame called")
        }

        // Skip frame if still processing previous one
        guard !isProcessingFrame else {
            if debugFrameCount % 60 == 0 {
                print("⏭️ Skipping frame - still processing")
            }
            return
        }

        let currentTime = playerItem.currentTime()

        // Check if a new frame is available
        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else {
            if debugFrameCount == 1 {
                print("⚠️ No new pixel buffer available")
            }
            return
        }

        // Get the pixel buffer
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: currentTime,
            itemTimeForDisplay: nil
        ) else {
            if debugFrameCount == 1 {
                print("⚠️ Failed to copy pixel buffer")
            }
            return
        }

        if debugFrameCount == 1 {
            print("✅ Got pixel buffer, starting style transfer")
        }

        // Apply style transfer
        isProcessingFrame = true
        Task {
            defer {
                isProcessingFrame = false
            }

            do {
                let styledBuffer = try await applyStyleTransfer(to: pixelBuffer)

                if debugFrameCount % 30 == 1 {
                    print("✅ Frame processed successfully")
                }

                await MainActor.run {
                    onFrameAvailable?(styledBuffer)
                }
            } catch {
                // Fallback: use original frame if style transfer fails
                print("⚠️ Style transfer failed: \(error)")
                await MainActor.run {
                    onFrameAvailable?(pixelBuffer)
                }
            }
        }
    }

    private func applyStyleTransfer(to pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        var inputWidth = CVPixelBufferGetWidth(pixelBuffer)
        var inputHeight = CVPixelBufferGetHeight(pixelBuffer)

        // On simulator, downscale large inputs for better performance
        #if targetEnvironment(simulator)
        let maxDimension = 360
        if inputWidth > maxDimension || inputHeight > maxDimension {
            let scale = min(CGFloat(maxDimension) / CGFloat(inputWidth), CGFloat(maxDimension) / CGFloat(inputHeight))
            inputWidth = Int(CGFloat(inputWidth) * scale)
            inputHeight = Int(CGFloat(inputHeight) * scale)
        }
        #endif

        // Resize pixel buffer if needed (using cached expected dimensions)
        let resizedBuffer: CVPixelBuffer
        if inputWidth != expectedWidth || inputHeight != expectedHeight {
            resizedBuffer = try resizePixelBuffer(pixelBuffer, width: expectedWidth, height: expectedHeight)
        } else {
            resizedBuffer = pixelBuffer
        }

        // Reuse or create input MLMultiArray (using cached input metadata)
        let multiArray: MLMultiArray
        let inputShape: [NSNumber] = [1, 3, NSNumber(value: expectedHeight), NSNumber(value: expectedWidth)]

        // Validate cached array dimensions match current model
        let canReuseCache: Bool
        if let cached = cachedInputArray {
            canReuseCache = cached.shape.count >= 4 &&
                           cached.shape[2].intValue == expectedHeight &&
                           cached.shape[3].intValue == expectedWidth
        } else {
            canReuseCache = false
        }

        if canReuseCache, let cached = cachedInputArray {
            multiArray = cached
        } else {
            let newArray = try MLMultiArray(shape: inputShape, dataType: .float32)
            cachedInputArray = newArray
            multiArray = newArray
        }

        // Fast GPU conversion using Metal
        try convertPixelBufferToMultiArray(resizedBuffer, multiArray: multiArray, width: expectedWidth, height: expectedHeight)

        // Create input feature and run prediction (using cached input name)
        let inputFeature = MLFeatureValue(multiArray: multiArray)
        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature])

        // Run prediction
        let output = try await styleModel.prediction(from: inputProvider)

        // Extract output (using cached output name)
        guard let outputFeature = output.featureValue(for: outputName),
              let outputMultiArray = outputFeature.multiArrayValue else {
            throw VideoPassthroughError.predictionFailed
        }

        // Convert output back to CVPixelBuffer
        let styledBuffer = try convertMultiArrayToPixelBuffer(outputMultiArray)

        // Resize output back to original dimensions if needed
        let outputWidth = CVPixelBufferGetWidth(styledBuffer)
        let outputHeight = CVPixelBufferGetHeight(styledBuffer)

        if outputWidth != inputWidth || outputHeight != inputHeight {
            return try resizePixelBuffer(styledBuffer, width: inputWidth, height: inputHeight)
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

        // Reuse or create Metal buffer
        let bufferSize = width * height * 3 * MemoryLayout<Float>.stride

        let outputBuffer: MTLBuffer
        if let cached = cachedInputBuffer, cached.length >= bufferSize {
            outputBuffer = cached
        } else {
            guard let newBuffer = metalDevice.makeBuffer(length: bufferSize, options: .storageModeShared) else {
                print("❌ Failed to create Metal buffer (size: \(bufferSize) bytes)")
                computeEncoder.endEncoding()
                throw VideoPassthroughError.predictionFailed
            }
            cachedInputBuffer = newBuffer
            outputBuffer = newBuffer
        }

        var widthParam = UInt32(width)
        var heightParam = UInt32(height)

        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 0)
        computeEncoder.setBytes(&widthParam, length: MemoryLayout<UInt32>.stride, index: 1)
        computeEncoder.setBytes(&heightParam, length: MemoryLayout<UInt32>.stride, index: 2)

        // Dispatch threads with optimized thread group size
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

        // Copy data from Metal buffer to MLMultiArray using safe subscript access
        let arrayDataSize = multiArray.count * MemoryLayout<Float>.stride

        guard arrayDataSize >= bufferSize else {
            print("❌ MLMultiArray size (\(arrayDataSize)) is smaller than expected (\(bufferSize))")
            computeEncoder.endEncoding()
            throw VideoPassthroughError.predictionFailed
        }

        let bufferPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)

        // Use fast memcpy with correct size
        let arrayPointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        let copySize = min(arrayDataSize, bufferSize)
        memcpy(arrayPointer, bufferPointer, copySize)
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
            print("❌ Unexpected shape count: \(shape.count)")
            throw VideoPassthroughError.predictionFailed
        }

        // Validate that shape matches expected channel count
        let expectedChannels = 3
        let actualChannels = shape.count == 4 ? shape[1] : shape[0]
        guard actualChannels == expectedChannels else {
            print("❌ Expected \(expectedChannels) channels, got \(actualChannels)")
            throw VideoPassthroughError.predictionFailed
        }

        // Calculate expected element count
        let expectedCount = width * height * expectedChannels
        guard multiArray.count >= expectedCount else {
            print("❌ MLMultiArray count (\(multiArray.count)) is less than expected (\(expectedCount))")
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
            print("❌ Failed to create output pixel buffer")
            throw VideoPassthroughError.predictionFailed
        }

        // Create Metal texture from pixel buffer (before command buffer)
        guard let texture = createMetalTexture(from: outputBuffer, writable: true) else {
            print("❌ Failed to create Metal texture")
            throw VideoPassthroughError.predictionFailed
        }

        guard let commandBuffer = metalCommandQueue.makeCommandBuffer() else {
            print("❌ Failed to create command buffer")
            throw VideoPassthroughError.predictionFailed
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("❌ Failed to create compute encoder")
            throw VideoPassthroughError.predictionFailed
        }

        // Set up compute pipeline
        computeEncoder.setComputePipelineState(tensorToBGRAPipeline)

        // Calculate buffer size based on what we actually need
        let bufferSize = expectedCount * MemoryLayout<Float>.stride

        // Reuse or create Metal buffer for output conversion
        let inputBuffer: MTLBuffer
        if let cached = cachedOutputBuffer, cached.length >= bufferSize {
            inputBuffer = cached
        } else {
            guard let newBuffer = metalDevice.makeBuffer(length: bufferSize, options: .storageModeShared) else {
                print("❌ Failed to create Metal buffer")
                computeEncoder.endEncoding()
                throw VideoPassthroughError.predictionFailed
            }
            cachedOutputBuffer = newBuffer
            inputBuffer = newBuffer
        }

        // Copy data from MLMultiArray to Metal buffer using safe subscript access
        do {
            let bufferPointer = inputBuffer.contents().assumingMemoryBound(to: Float.self)
            let arrayDataSize = multiArray.count * MemoryLayout<Float>.stride

            guard arrayDataSize >= bufferSize else {
                print("❌ MLMultiArray size (\(arrayDataSize)) is smaller than buffer size (\(bufferSize))")
                computeEncoder.endEncoding()
                throw VideoPassthroughError.predictionFailed
            }

            let elementCount = multiArray.count

            // Handle Float16 vs Float32 output based on cached dataType
            if outputDataType == .float16 {
                // Output is Float16 - need to convert to Float32
                let arrayPointer = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)

                // Convert Float16 to Float32
                for i in 0..<elementCount {
                    bufferPointer[i] = Float(arrayPointer[i])
                }
            } else {
                // Output is Float32 - direct memcpy
                let arrayPointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
                let copySize = min(arrayDataSize, bufferSize)
                memcpy(bufferPointer, arrayPointer, copySize)
            }

        } catch {
            print("❌ Error during memory copy: \(error)")
            computeEncoder.endEncoding()
            throw VideoPassthroughError.predictionFailed
        }

        var widthParam = UInt32(width)
        var heightParam = UInt32(height)

        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBytes(&widthParam, length: MemoryLayout<UInt32>.stride, index: 1)
        computeEncoder.setBytes(&heightParam, length: MemoryLayout<UInt32>.stride, index: 2)

        // Dispatch threads with optimized thread group size
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
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuOnly
            #else
            config.computeUnits = .all
            config.allowLowPrecisionAccumulationOnGPU = true
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
