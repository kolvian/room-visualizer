# Room Visualizer - Apple Interview Overview

## 🎯 Project Elevator Pitch
**Room Visualizer** is a visionOS application that applies real-time neural style transfer to AR-mapped room environments. It combines ARKit room scanning capabilities with Core ML-powered artistic style transformations, allowing users to visualize their physical space transformed with different artistic styles (sci-fi, fantasy, etc.) in real-time on Apple Vision Pro.

---

## 🏗️ Architecture Overview

### Platform & Target
- **Platform**: visionOS 2.5 (Apple Vision Pro)
- **Language**: Swift 5.0
- **Frameworks**: SwiftUI, RealityKit, ARKit, Core ML, AVFoundation
- **Architecture Pattern**: MVVM with @Observable pattern (modern SwiftUI)
- **Deployment Target**: visionOS 1.0+ (also supports iOS 15+ for testing)

### Project Structure
```
room-visualizer/
├── Main App Target (visionOS app)
├── Local Swift Packages:
│   ├── StyleTransferEngine (Core ML pipeline)
│   ├── ARRoomMapping (ARKit abstraction)
│   └── RealityKitContent (3D assets)
└── Models/ (Core ML models - .mlmodel/.mlmodelc)
```

---

## 🔧 Core Components

### 1. **App Entry & State Management**

#### `room_visualizerApp.swift`
- App entry point using `@main` attribute
- Manages two scene types:
  - **WindowGroup**: Main 2D UI (ContentView)
  - **ImmersiveSpace**: Full immersion AR view (ImmersiveView)
- Uses `.immersionStyle(.full)` for complete passthrough replacement

#### `AppModel.swift`
- `@Observable` macro (replaces old ObservableObject pattern)
- Tracks immersive space state: `.closed`, `.inTransition`, `.open`
- Shared across all views via `.environment(appModel)`

**Key Technical Detail**: Uses modern Swift concurrency with `@MainActor` to ensure UI updates happen on main thread.

---

### 2. **User Interface Layer**

#### `ContentView.swift`
- Navigation hub with two main features:
  1. **Toggle Immersive Space**: Launches full AR view
  2. **Style Transfer MVP**: Performance benchmarking tool
- Simple NavigationStack-based UI

#### `ToggleImmersiveSpaceButton.swift`
- Manages immersive space lifecycle using environment actions:
  - `@Environment(\.openImmersiveSpace)`
  - `@Environment(\.dismissImmersiveSpace)`
- Handles all edge cases: user cancellation, errors, transition states
- **Key Pattern**: State changes happen in lifecycle callbacks (`onAppear`/`onDisappear`), not in button handler, to avoid race conditions

#### `DemoStyleBenchmarkView.swift`
- **Purpose**: FPS benchmarking tool for style transfer performance
- Generates synthetic 720p pixel buffers (1280×720) with gradient patterns
- Runs processing loop at ~60Hz using `DispatchSourceTimer`
- Current implementation uses `NoOpAdapter` (pass-through) to measure pipeline overhead
- **Metrics**: Real-time FPS display, averaged over 250ms windows
- **Design Philosophy**: Validate 30+ FPS before integrating with live ARKit camera

---

### 3. **AR & Room Mapping**

#### `ImmersiveView.swift`
- Main RealityKit view using `RealityView` construct
- Manages AR content hierarchy:
  - **World Anchor**: Root entity for all AR content (`.world(transform: .identity)`)
  - **Plane Entities**: Detected surfaces (floors, walls, tables)
  - **Mesh Entities**: Fine-grained room geometry
- **Current State**: Infrastructure ready, ARRoomMapper integration pending

**Key Methods** (prepared for integration):
- `addOrUpdatePlane(id:transform:extent:)`: Creates/updates plane visualizations
- `addOrUpdateMesh(id:vertices:normals:faces:)`: Converts mesh data to RealityKit `MeshResource`
- `applyStylizedFrame(_:)`: Will apply Core ML output as texture overlay

**Technical Details**:
- Uses `MeshDescriptor` with positions, normals, primitives for custom geometry
- `SimpleMaterial` with alpha blending for semi-transparent overlays
- `@State` dictionaries track entities by UUID for efficient updates/removals

#### `ARRoomMapping` Package
- **Protocol-based design**: `ARRoomMappingDelegate` for loose coupling
- **Data structures**:
  - `PlaneAnchorInfo`: Normal, center, extent (Sendable & Equatable)
  - `MeshInfo`: Vertices, indices for triangle meshes
  - `SessionMode`: `.planes`, `.mesh`, `.roomplan`
- **Current State**: Stub implementation (platform-specific ARKit code pending)

**Design Philosophy**: Abstract ARKit complexity into reusable package; delegate pattern allows ImmersiveView to remain framework-agnostic.

---

### 4. **Style Transfer Engine**

#### Architecture: Adapter Pattern
```
StyleTransferEngine (coordinator)
    ↓
StyleModelAdapter (protocol)
    ↓
├── NoOpAdapter (MVP testing)
└── CoreMLStyleAdapter (production)
```

#### `StyleTransferEngine` Package
**Core abstraction layer** for neural style transfer:

```swift
public protocol StyleModelAdapter: AnyObject {
    func load(modelURL: URL) throws
    func encode(input pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer
}
```

**Key Features**:
- Thread-safe (`@unchecked Sendable`) for background processing
- FPS tracking with rolling average (updates every 250ms)
- Configuration via `InferenceConfig`:
  - `targetSize: CGSize` - Input resolution (affects quality vs performance)
  - `useNeuralEngine: Bool` - Hardware acceleration preference
- Style descriptor system for multi-model support

**Design Decisions**:
- Uses `CVPixelBuffer` throughout (native to AVFoundation, Core ML, Metal)
- Protocol-oriented: easy to swap implementations (testing vs production)
- Manages model lifecycle independently of view layer

#### `NoOpAdapter`
- **Purpose**: Baseline performance testing
- Pass-through implementation (returns input unchanged)
- Measures pure pipeline overhead (pixel buffer passing, FPS calculation)
- **Result**: Establishes performance ceiling before adding ML inference

#### `CoreMLStyleAdapter`
- **Production adapter** for Core ML models
- Features:
  - Automatic model compilation (`.mlmodel` → `.mlmodelc`)
  - `MLModelConfiguration` with `.all` compute units (CPU + GPU + Neural Engine)
  - Low-precision accumulation enabled for GPU optimization
  - Bundle loading convenience method: `fromBundle(modelName:)`
- **Current State**: Ready for trained models (TODOs for feature names, normalization)

**Technical Deep Dive**:
```swift
let config = MLModelConfiguration()
config.computeUnits = .all  // Critical: enables Neural Engine
config.allowLowPrecisionAccumulationOnGPU = true  // 2x speedup
```

**Integration Points**:
- Input feature name: `"image"` (verify in Xcode model inspector)
- Output feature name: `"stylized_image"` (verify in Xcode model inspector)
- Preprocessing: Normalization to [0,1] or [-1,1] depending on model training
- Postprocessing: Color space conversion if needed

---

### 5. **ML Model Integration**

#### Current Model: `starry_night.mlpackage`
- Located in: `room-visualizer/Models/starry_night.mlpackage/`
- Structure:
  - `Manifest.json`: Model metadata
  - `Data/com.apple.CoreML/model.mlmodel`: Model architecture
  - `weights/weight.bin`: Trained parameters
- **Status**: Ready for integration (not yet wired to CoreMLStyleAdapter)

#### Integration Workflow (per ML_MODEL_INTEGRATION.md):
1. Drop `.mlmodel` into Xcode project
2. Update `CoreMLStyleAdapter.modelName` to match
3. Verify input/output feature names in Xcode inspector
4. Replace `NoOpAdapter` with `CoreMLStyleAdapter` in benchmark
5. Validate 30+ FPS performance
6. Wire to ImmersiveView camera capture

**Performance Target**: 30+ FPS at 512×512 resolution on Neural Engine

---

## 🔄 Data Flow (When Fully Integrated)

```
ARKit Camera Frame (CVPixelBuffer)
    ↓
StyleTransferEngine.process()
    ↓
CoreMLStyleAdapter.encode()
    ↓
Core ML Model (Neural Engine)
    ↓
Stylized CVPixelBuffer
    ↓
Metal Texture / RealityKit Material
    ↓
ImmersiveView.applyStylizedFrame()
    ↓
User sees styled room in real-time
```

**Parallel Path**: ARRoomMapper → Plane/Mesh Updates → RealityKit Entities

---

## 🎨 Technical Highlights for Interview

### 1. **Modern SwiftUI Patterns**
- `@Observable` macro (iOS 17+, visionOS 1+) instead of `ObservableObject`
- `@MainActor` isolation for UI safety
- Environment-based dependency injection
- Structured concurrency with `async/await`

### 2. **RealityKit Integration**
- `RealityView` with update closures for dynamic content
- Custom mesh generation using `MeshDescriptor`
- Entity hierarchy management (anchors → children)
- Material system for visual effects

### 3. **Core ML Optimization**
- Neural Engine targeting via `computeUnits = .all`
- FP16 precision for 2x speedup
- `CVPixelBuffer` for zero-copy between frameworks
- Model compilation caching

### 4. **Package Architecture**
- Local Swift Packages for modularity:
  - `StyleTransferEngine`: Cross-platform (iOS + visionOS)
  - `ARRoomMapping`: Platform abstraction
  - `RealityKitContent`: Assets in Reality Composer Pro
- Protocol-oriented design for testability
- `Sendable` conformance for thread safety

### 5. **Performance Engineering**
- FPS tracking for real-time feedback
- Benchmark-driven development (NoOpAdapter baseline)
- Resolution vs quality tradeoffs (512×512 → 720p)
- Dispatch queue optimization (`.userInitiated` QoS)

---

## 🚧 Current Project State

### ✅ **Completed**
- visionOS app scaffold with immersive space support
- Style transfer engine architecture (adapter pattern)
- FPS benchmarking tool
- Core ML adapter with Neural Engine support
- RealityKit entity management (planes, meshes)
- Documentation (ML_MODEL_INTEGRATION.md)

### 🔄 **In Progress**
- Training custom style transfer models (sci-fi, fantasy themes)
- Integration: NoOpAdapter → CoreMLStyleAdapter in benchmark

### 📋 **Next Steps**
1. Wire trained model to CoreMLStyleAdapter
2. Validate 30+ FPS performance
3. Implement ARKit camera capture for visionOS
4. Connect camera frames to StyleTransferEngine
5. Apply styled frames as RealityKit textures/overlays
6. Implement ARRoomMapper with plane/mesh detection
7. UI for style selection (StylePicker)
8. iOS fallback using ARKit face tracking or rear camera

---

## 🎤 Key Talking Points for Apple Interview

### **Problem Statement**
"How can we help users visualize their physical spaces transformed artistically in real-time on Vision Pro?"

### **Technical Challenge**
"Running neural style transfer at 30+ FPS on device while maintaining spatial awareness and low latency."

### **Solution Architecture**
1. **Modular Design**: Separate packages for style transfer, AR mapping, and content
2. **Adapter Pattern**: Swap implementations (testing → production) without changing engine
3. **Hardware Optimization**: Neural Engine + FP16 + resolution tuning
4. **Progressive Enhancement**: Benchmark → static frames → live camera → AR integration

### **Apple Technologies Leveraged**
- **visionOS**: Immersive spaces, spatial computing
- **RealityKit**: 3D rendering, entity system, materials
- **ARKit**: Room scanning, plane detection, mesh generation
- **Core ML**: On-device inference, Neural Engine acceleration
- **Swift Concurrency**: `async/await`, `@MainActor`, `Sendable`
- **SwiftUI**: Modern declarative UI, `@Observable` macro

### **Performance Mindset**
- Started with NoOpAdapter to measure baseline
- FPS tracking built into engine from day one
- Resolution as tunable parameter (not hardcoded)
- Benchmark view before integration (fail fast)

### **Scalability**
- Multi-model support via `StyleDescriptor`
- Protocol-oriented: easy to add TensorFlow Lite, ONNX adapters
- Cross-platform packages (iOS + visionOS)
- Delegate pattern for loose coupling

### **Future Enhancements**
- Multiple style models with UI picker
- User-uploaded custom styles
- Style intensity slider (blend original + styled)
- ARKit room persistence (save/load styled spaces)
- SharePlay for collaborative room styling
- Export styled videos

---

## 📊 Project Metrics

- **Languages**: Swift (100%)
- **Lines of Code**: ~800 (excluding packages)
- **Packages**: 3 local Swift packages
- **Minimum Deployment**: visionOS 1.0, iOS 15.0
- **Key Frameworks**: 7 (SwiftUI, RealityKit, ARKit, Core ML, CoreImage, AVFoundation, simd)
- **Architecture Pattern**: MVVM + Protocol-Oriented
- **Concurrency Model**: Structured concurrency (`async/await`)

---

## 🔍 Code Quality Highlights

1. **Type Safety**: `Sendable` conformance for thread-safe data structures
2. **Error Handling**: Proper throws/try throughout ML pipeline
3. **Documentation**: Inline comments, README, integration guide
4. **Testability**: Protocol-based adapters, dependency injection
5. **Apple Guidelines**: Modern Swift patterns, SwiftUI best practices
6. **Performance**: Early optimization (FPS tracking, benchmarking)

---

## 💡 Design Philosophy

**"Build the infrastructure first, validate performance early, integrate incrementally."**

The project demonstrates:
- Systems thinking (packages as boundaries)
- Performance-first development (benchmark before integration)
- Graceful degradation (NoOp → CoreML → future backends)
- User-centric design (FPS visible, style selection planned)
- Apple platform expertise (leveraging newest APIs)

---

## Questions You Might Be Asked

### "Why the adapter pattern?"
**Answer**: "It allows me to test the entire pipeline with a no-op implementation, measure baseline overhead, and swap in the real Core ML model only after validating the architecture. It also future-proofs for different backends—TensorFlow Lite, ONNX, or even cloud-based models."

### "How do you ensure 30+ FPS?"
**Answer**: "Three strategies: (1) Target Neural Engine with `.all` compute units, (2) Use FP16 precision, (3) Tune input resolution—start at 512×512, scale up only if headroom exists. The benchmark view validates this before touching ARKit."

### "Why separate packages?"
**Answer**: "Modularity and reusability. StyleTransferEngine works on both iOS and visionOS. ARRoomMapping abstracts platform differences. RealityKitContent is managed by Reality Composer Pro. This also improves build times—only changed packages recompile."

### "What's the hardest part?"
**Answer**: "Balancing quality vs latency. Style transfer models are inherently heavy—you're transforming every pixel. The Neural Engine helps, but resolution is the key knob. I started with benchmarking to establish a performance baseline before adding complexity."

### "How would you scale this?"
**Answer**: "Add a style picker UI with thumbnails, lazy-load models, cache compiled .mlmodelc files, potentially use model quantization for smaller sizes. For multi-user, integrate SharePlay so friends can vote on styles for a shared space."

---

## 🎓 Learning & Growth

This project demonstrates:
- **Rapid prototyping** on cutting-edge hardware (Vision Pro)
- **Cross-domain expertise**: ML, AR, 3D graphics, Swift
- **Performance engineering** mindset from day one
- **Modular architecture** for maintainability
- **Documentation discipline** (you wrote this for future you)

**Bottom Line**: You built a production-quality scaffold for a real-time AR + ML application, following Apple's best practices, and you're ready to plug in the final ML piece.

---

## 🚀 Demo Flow for Interview

1. **Show ContentView**: "Two entry points—immersive AR and style benchmark"
2. **Run DemoStyleBenchmarkView**: "This is my performance harness. Currently using NoOpAdapter, getting ~X FPS. Validates the pipeline works before ML."
3. **Show CoreMLStyleAdapter code**: "Ready for the trained model. Targets Neural Engine, handles compilation, returns CVPixelBuffers."
4. **Show ImmersiveView**: "RealityKit view with world anchor. Methods ready for plane/mesh updates and stylized frame application."
5. **Show package structure**: "Modular design—StyleTransferEngine is cross-platform, ARRoomMapping abstracts ARKit, RealityKitContent has 3D assets."
6. **Show ML_MODEL_INTEGRATION.md**: "Documentation for integrating trained models. Three-step process: add to Xcode, update adapter, benchmark."

**Closing**: "This is a real-time AR style transfer system, architected for performance and modularity, ready for the final ML integration."

---

Good luck with your interview! 🍀
