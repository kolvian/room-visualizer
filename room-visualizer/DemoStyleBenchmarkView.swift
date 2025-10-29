//
//  DemoStyleBenchmarkView.swift
//  room-visualizer
//
//  Minimal MVP: simulate frames, run through StyleTransferEngine (NoOp), display FPS.
//

import SwiftUI
import CoreVideo
import CoreGraphics

#if canImport(StyleTransferEngine)
import StyleTransferEngine
#endif

struct DemoStyleBenchmarkView: View {
    @State private var fps: Double = 0
    @State private var running = false
    @State private var selectedModel: String = "starry_night"

    // 720p target for MVP
    private let width: Int32 = 1280
    private let height: Int32 = 720

    #if canImport(StyleTransferEngine)
    @State private var engine: StyleTransferEngine? = nil
    #endif

    @State private var timer: DispatchSourceTimer?

    var body: some View {
        VStack(spacing: 16) {
            Text("Style Transfer MVP")
                .font(.title2)
            Text(String(format: "FPS: %.1f", fps))
                .font(.headline)

            // Model selection buttons
            HStack(spacing: 12) {
                Button("Starry Night") {
                    selectedModel = "starry_night"
                    reset()
                }
                .buttonStyle(.bordered)
                .tint(selectedModel == "starry_night" ? .blue : .gray)

                Button("Rain Princess") {
                    selectedModel = "rain_princess"
                    reset()
                }
                .buttonStyle(.bordered)
                .tint(selectedModel == "rain_princess" ? .blue : .gray)
            }

            HStack {
                Button(running ? "Stop" : "Start") { toggleRun() }
                    .buttonStyle(.borderedProminent)
                Button("Reset") { reset() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)

            #if canImport(StyleTransferEngine)
            Text("Engine: StyleTransferEngine + CoreMLStyleAdapter")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Model: \(selectedModel)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            Text("StyleTransferEngine not linked in this target.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif

            Spacer()
        }
        .padding()
        .onAppear { setupIfNeeded() }
        .onDisappear { stopTimer() }
    }

    private func setupIfNeeded() {
        #if canImport(StyleTransferEngine)
        if engine == nil {
            let cfg = InferenceConfig(targetSize: CGSize(width: Int(width), height: Int(height)))
            let displayName = selectedModel == "starry_night" ? "Starry Night" : "Rain Princess"
            engine = StyleTransferEngine(style: StyleDescriptor(id: selectedModel, displayName: displayName), config: cfg)

            // Load the CoreML model from the bundle
            if let adapter = try? CoreMLStyleAdapter.fromBundle(modelName: selectedModel) {
                // The adapter already has the model URL loaded
                try? engine?.loadModel(at: URL(fileURLWithPath: "/dev/null"), adapter: adapter)
            }
        }
        #endif
    }

    private func toggleRun() {
        running ? stopTimer() : startTimer()
        running.toggle()
    }

    private func reset() {
        stopTimer()
        running = false
        fps = 0
        #if canImport(StyleTransferEngine)
        engine = nil
        #endif
        setupIfNeeded()
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2)) // ~60 Hz
        t.setEventHandler {
            #if canImport(StyleTransferEngine)
            if let engine = self.engine, let pb = Self.makePixelBuffer(width: self.width, height: self.height) {
                _ = try? engine.process(pixelBuffer: pb)
                let current = engine.currentFPS
                DispatchQueue.main.async { self.fps = current }
            }
            #else
            DispatchQueue.main.async { self.fps = max(0, self.fps * 0.9 + 6) }
            #endif
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private static func makePixelBuffer(width: Int32, height: Int32) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let result = CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard result == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            // Fill with a quick gradient pattern for variability
            for y in 0..<Int(height) {
                let row = base.advanced(by: y * bpr).bindMemory(to: UInt32.self, capacity: Int(width))
                for x in 0..<Int(width) {
                    let r = UInt32((x * 255) / Int(width))
                    let g = UInt32((y * 255) / Int(height))
                    let b: UInt32 = 127
                    row[x] = (255 << 24) | (b << 16) | (g << 8) | r
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

#Preview {
    DemoStyleBenchmarkView()
}
