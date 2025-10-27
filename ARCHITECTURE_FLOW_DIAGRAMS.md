# Room Visualizer - Architecture & Code Flow Diagrams

## Application Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                    RoomVisualizerApp (@main)                   │
│         Defines WindowGroup (2D) + ImmersiveSpace (3D)          │
└────────────────────────────┬────────────────────────────────────┘
                             │
            ┌────────────────┴────────────────┐
            │                                 │
    ┌───────▼────────┐            ┌──────────▼──────────┐
    │  ContentView   │            │   ImmersiveView    │
    │  (2D UI)       │            │   (3D Environment) │
    │                │            │                    │
    │ - Button:      │            │ - RealityKit view  │
    │   Show/Hide    │            │ - World anchor     │
    │   Immersive    │            │ - Model entities   │
    │                │            │ - Style transfer   │
    │ - Links:       │            │                    │
    │   Benchmark    │            │ PLATFORM-SPECIFIC: │
    │   Test Model   │            │ if simulator:      │
    └────────────────┘            │   → Video mode     │
                                  │ else:              │
                                  │   → ARKit mode     │
                                  └────────────────────┘
```

## ImmersiveView Initialization Flow

```
ImmersiveView appears
    │
    ├─ [1] Load Style Transfer Model
    │       └─> CoreML: starry_night.mlpackage
    │           └─> MLModel with .all compute units
    │               └─> Stored in @State variable
    │
    └─ [2] Platform Detection (isSimulator)
           │
           ├─ TRUE (Simulator)
           │   └─> setupVideoPassthrough()
           │       │
           │       ├─ Check: test-room.mp4 in bundle?
           │       │  ├─ YES: Create VideoPassthroughSimulator
           │       │  │        └─> Create video display quad
           │       │  │        └─> Setup frame callback
           │       │  │        └─> Start video playback
           │       │  │
           │       │  └─ NO: createDemoPlanes() [FALLBACK]
           │       │
           │       └─ Error on simulator creation?
           │           └─> createDemoPlanes() [FALLBACK]
           │
           └─ FALSE (Real Device)
               └─> startARSession()
                   └─> PlaneDetection + WorldTracking
                       └─> processPlaneDetection()
                           └─> Create plane entities
```

## Video Passthrough Pipeline (Simulator Only)

```
SIMULATOR MODE: Video → Style → Display

┌──────────────────────────────────────────────────────────────┐
│                    VideoPassthroughSimulator                 │
└──────────────────────────────────────────────────────────────┘

[1] VIDEO INPUT
    ├─ AVPlayer(playerItem: test-room.mp4)
    ├─ AVPlayerItemVideoOutput
    │  └─ Pixel format: kCVPixelFormatType_32BGRA
    │
    └─ CADisplayLink (30-60 FPS)
       └─ Calls processFrame() every frame

[2] FRAME EXTRACTION
    ├─ Current time from playerItem
    ├─ Check: hasNewPixelBuffer()?
    └─ Extract: CVPixelBuffer

[3] STYLE TRANSFER (CoreML)
    ├─ Model: starry_night.mlpackage
    ├─ Input: CVPixelBuffer
    ├─ Process:
    │  ├─ Get model input name (first input)
    │  ├─ Create MLFeatureValue
    │  ├─ Create MLDictionaryFeatureProvider
    │  ├─ Run: model.prediction()
    │  └─ Extract output CVPixelBuffer
    │
    └─ Error fallback: Return original frame

[4] CALLBACK + UPDATE
    ├─ onFrameAvailable(styledBuffer)
    │  └─ [weak self capture in struct]
    │  └─ Task { @MainActor in ... }
    │
    └─ updateVideoTexture()
       ├─ Convert: CVPixelBuffer → CIImage
       ├─ Convert: CIImage → CGImage
       ├─ Create: TextureResource
       └─ Update: Material on quad entity

[5] LOOPING
    ├─ AVPlayerItemDidPlayToEndTime notification
    ├─ Seek to beginning
    └─ Resume playback
```

## Demo Planes Fallback Flow

```
FALLBACK MODE: 4 Colored Planes with Style Transfer

createDemoPlanes() called when:
├─ Video not found in bundle
├─ VideoPassthroughSimulator creation failed
└─ Model not loaded

PLANE CREATION (4 planes):
├─ [1] Front wall: (0, 0, -2)  size: 2.0 × 2.0
├─ [2] Left wall:  (-1.5, 0, -1)  size: 1.5 × 1.5
├─ [3] Right wall: (1.5, 0, -1.5)  size: 1.5 × 1.5
└─ [4] Floor:      (0, -1, -1.5)  size: 2.5 × 2.5
    └─ Rotated -π/2 radians around X-axis

MATERIAL GENERATION:
For each plane:
├─ IF model available:
│  ├─ Create gradient image (256×256)
│  ├─ Apply style transfer
│  │  ├─ Convert UIImage → MLMultiArray
│  │  ├─ Run model.prediction()
│  │  └─ Convert MLMultiArray → CGImage
│  └─ Create TextureResource
│
└─ ELSE (no model):
   └─ Use solid color (random hue)
       Hue: index × 0.2 (spreads across spectrum)
```

## Error Handling Chain

```
ERROR SCENARIOS & FALLBACKS

┌─────────────────────────────────────────┐
│ Missing test-room.mp4 (most common)     │
└─────────────────────────────────────────┘
    │
    ├─ Log: "⚠️ Video 'test-room.mp4' not found"
    ├─ Log: "💡 Add a video file to simulate..."
    │
    └─> createDemoPlanes()
        └─ Shows 4 colored planes
           (style transfer applied if model loaded)

┌─────────────────────────────────────────┐
│ Model Not Found/Failed to Load          │
└─────────────────────────────────────────┘
    │
    ├─ Log: "⚠️ Model 'starry_night' not found"
    │
    └─> setupVideoPassthrough() or createDemoPlanes()
        └─ Video/planes use original colors
           (no style transfer applied)

┌─────────────────────────────────────────┐
│ VideoPassthroughSimulator Creation Fail │
└─────────────────────────────────────────┘
    │
    ├─ Log: "⚠️ Failed to create simulator"
    │
    └─> createDemoPlanes()
        └─ Shows fallback planes

┌─────────────────────────────────────────┐
│ Style Transfer on Individual Frame Fails│
└─────────────────────────────────────────┘
    │
    ├─ Caught in applyStyleTransfer()
    ├─ return original pixelBuffer
    │
    └─> onFrameAvailable(pixelBuffer)
        └─ Displays original frame
           (happens silently, no console spam)
```

## Model Input/Output Format

```
STARRY NIGHT MLPACKAGE

Input Format:
├─ Name: [Dynamic - first input]
├─ Type: CVPixelBuffer
├─ Size: Dynamic (frame dimensions)
└─ Format: 32BGRA

Output Format:
├─ Name: [Dynamic - first output]
├─ Type: CVPixelBuffer
└─ Format: 32BGRA

MLMultiArray (for demo planes):
├─ Shape: [1, 3, 256, 256]
├─ Format: CHW (Channels, Height, Width)
├─ Channels: [R, G, B]
├─ Range: 0.0 - 1.0 (normalized)
└─ Batch: Always 1
```

## State Management

```
AppModel (@Observable, @MainActor)
├─ immersiveSpaceID = "ImmersiveSpace"
└─ immersiveSpaceState
   ├─ .closed
   ├─ .inTransition
   └─ .open

ImmersiveView (@State variables):
├─ worldAnchor: AnchorEntity
├─ planeEntities: [UUID: ModelEntity]
├─ arSession: ARKitSession?
├─ planeDetection: PlaneDetectionProvider
├─ styleTransferModel: MLModel?
├─ videoPassthrough: VideoPassthroughSimulator?
└─ videoDisplayEntity: ModelEntity?

VideoPassthroughSimulator:
├─ player: AVPlayer (@MainActor)
├─ playerItem: AVPlayerItem
├─ videoOutput: AVPlayerItemVideoOutput
├─ displayLink: CADisplayLink?
├─ styleModel: MLModel
└─ onFrameAvailable: Callback
```

## Deployment Target Impact

```
visionOS 2.5 Requirement

CoreML Compute Units (.all):
├─ CPU: Always available
├─ GPU: Available on visionOS 2.5+
│   └─ Requires Metal shader compilation
│   └─ May need binaryarchive.metallib
│       └─ Auto-generated on first run
│
└─ Neural Engine: Available on visionOS 2.5+
    └─ Best performance for inference
    └─ Falls back to GPU if unavailable

MPS Graph Backend:
├─ Available on visionOS 2.5+
├─ Required for GPU acceleration
└─ < 2.5 versions fall back to CPU-only
    (or require explicit .cpuOnly configuration)
```

## Code Files Quick Reference

```
Main Application:
├─ room_visualizerApp.swift (34 lines)
│  └─ Entry point, defines scenes
│
├─ AppModel.swift (22 lines)
│  └─ Global state management
│
└─ ContentView.swift (35 lines)
   └─ 2D UI buttons and links

3D Environment:
└─ ImmersiveView.swift (499 lines)
   ├─ [29-35]   isSimulator detection
   ├─ [37-63]   RealityView setup
   ├─ [65-74]   ARKit session startup
   ├─ [144-182] Video passthrough setup
   ├─ [221-254] Demo planes creation
   ├─ [293-421] Helper extensions
   └─ Contains:
      - toMLMultiArray() - UIImage conversion
      - toCGImage() - MLMultiArray conversion
      - toCVPixelBuffer() - UIImage conversion

Video Simulation:
└─ VideoPassthroughSimulator.swift (196 lines)
   ├─ [16]      @MainActor final class
   ├─ [35-59]   init(videoURL, model)
   ├─ [71-80]   start/stop playback
   ├─ [98-124]  processFrame
   ├─ [126-147] applyStyleTransfer
   ├─ [164-188] fromBundle convenience init
   └─ [192-195] Error types

Models & Adapters:
├─ CoreMLStyleAdapter.swift (125 lines)
│  └─ Load & run CoreML models
│
├─ NoOpAdapter.swift (25 lines)
│  └─ Pass-through for benchmarking
│
└─ starry_night.mlpackage/
   └─ Style transfer model

Testing & UI:
├─ TestModelLoad.swift (33 lines)
│  └─ Verify model loads correctly
│
├─ DemoStyleBenchmarkView.swift (142 lines)
│  └─ FPS benchmark view
│
└─ ToggleImmersiveSpaceButton.swift (59 lines)
   └─ Show/hide immersive space
```

