import Foundation
import CoreVideo
import CoreML
import CoreImage

public struct StyleDescriptor: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct InferenceConfig: Sendable, Equatable {
    public var targetSize: CGSize
    public var useNeuralEngine: Bool
    public init(targetSize: CGSize, useNeuralEngine: Bool = true) {
        self.targetSize = targetSize
        self.useNeuralEngine = useNeuralEngine
    }
}

public protocol StyleModelAdapter: AnyObject {
    func load(modelURL: URL) throws
    func encode(input pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer
}

public final class StyleTransferEngine: @unchecked Sendable {
    private var adapter: StyleModelAdapter?
    private(set) public var currentStyle: StyleDescriptor?
    private(set) public var config: InferenceConfig

    private var ciContext = CIContext(options: nil)
    private var frameCounter: Int = 0
    private var startTime: TimeInterval = 0
    private(set) public var currentFPS: Double = 0

    public init(style: StyleDescriptor? = nil, config: InferenceConfig) {
        self.currentStyle = style
        self.config = config
    }

    public func loadModel(at url: URL, adapter: StyleModelAdapter) throws {
        try adapter.load(modelURL: url)
        self.adapter = adapter
        self.frameCounter = 0
        self.startTime = CFAbsoluteTimeGetCurrent()
    }

    public func process(pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let adapter else { throw NSError(domain: "StyleTransferEngine", code: -1) }
        let out = try adapter.encode(input: pixelBuffer)
        updateFPS()
        return out
    }

    private func updateFPS() {
        frameCounter += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if elapsed > 0.25 { // update at a modest cadence
            currentFPS = Double(frameCounter) / elapsed
        }
    }
}
