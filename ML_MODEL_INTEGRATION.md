# ML Model Integration Guide

## Quick Start: Add Your Trained Model

Once your style transfer model is trained and converted to Core ML (.mlmodel), follow these steps:

### 1. Add Model to Xcode Project

1. Drag your `.mlmodel` or `.mlmodelc` file into Xcode project navigator
2. In the file inspector, ensure:
   - ✅ Target Membership: `room-visualizer` is checked
   - ✅ Copy items if needed is checked
3. Xcode will automatically compile `.mlmodel` → `.mlmodelc` at build time

**Recommended location:** `room-visualizer/Models/` (create this folder)

### 2. Update CoreMLStyleAdapter

Open `CoreMLStyleAdapter.swift` and update these values to match your model:

```swift
private let modelName = "sci-fi" // Change to your model's name

// In encode() method, verify these match your model's input/output names:
let inputFeatureName = "image"           // Check in Xcode model inspector
let outputFeatureName = "stylized_image" // Check in Xcode model inspector
```

**How to find feature names:**
- Click on your `.mlmodel` in Xcode
- Look at "Model Inputs" and "Model Outputs" sections
- Use those exact names in the adapter

### 3. Replace NoOpAdapter with CoreMLStyleAdapter

**In `DemoStyleBenchmarkView.swift`:**

```swift
// OLD:
let adapter = NoOpAdapter()

// NEW:
let adapter = try! CoreMLStyleAdapter.fromBundle(modelName: "sci-fi")
```

### 4. Wire Up to ImmersiveView (when ready)

Once you have camera frames from ARKit:

```swift
// In ImmersiveView.swift
import StyleTransferEngine

@State private var styleEngine: StyleTransferEngine?
@State private var styleAdapter: CoreMLStyleAdapter?

// In RealityView setup:
let adapter = try! CoreMLStyleAdapter.fromBundle(modelName: "sci-fi")
let config = InferenceConfig(
    targetSize: CGSize(width: 512, height: 512), // Adjust based on model
    computeUnits: .all
)
styleEngine = StyleTransferEngine(adapter: adapter, config: config)

// When you get a camera frame (CVPixelBuffer):
if let styledBuffer = try? styleEngine?.process(pixelBuffer: cameraFrame) {
    applyStylizedFrame(styledBuffer)
}
```

---

## Model Requirements

Your Core ML model should:
- ✅ Accept `CVPixelBuffer` or `MLMultiArray` image input
- ✅ Output `CVPixelBuffer` or `MLMultiArray` image
- ✅ Be optimized for Neural Engine (use `coremltools` with `compute_units=ComputeUnit.ALL`)
- ✅ Target input size: 512×512 or 720p (balance quality vs FPS)
- ✅ Use FP16 precision for faster inference

### Recommended Export Settings (coremltools)

```python
import coremltools as ct

# After training your PyTorch/TensorFlow model:
mlmodel = ct.convert(
    traced_model,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 512, 512))],
    outputs=[ct.ImageType(name="stylized_image")],
    compute_units=ct.ComputeUnit.ALL,  # CPU + GPU + Neural Engine
    minimum_deployment_target=ct.target.iOS17,  # or visionOS1
)

# Optimize
mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(
    mlmodel, nbits=16
)

mlmodel.save("sci-fi.mlmodel")
```

---

## Performance Tuning

### Target: 30+ FPS

1. **Input Resolution:** Start with 512×512, go up to 720p only if you have headroom
2. **Preprocessing:** Do color conversion on GPU using `CIContext` (already set up)
3. **Compute Units:** `.all` uses Neural Engine when available (already configured)
4. **FP16:** Use half-precision in your model export
5. **Batch Size:** Keep at 1 for real-time

### Check FPS in DemoStyleBenchmarkView

The benchmark view already tracks FPS:
```swift
@State private var currentFPS: Double = 0.0
```

Run the benchmark with your real model to validate 30+ FPS before wiring to ARKit.

---

## Troubleshooting

### "Model not found in bundle"
- Verify the file is in the Xcode project navigator
- Check target membership is enabled
- Model name should match (without `.mlmodel` or `.mlmodelc` extension)

### "Failed to extract output buffer"
- Check output feature name matches your model
- Verify model outputs `CVPixelBuffer` (not `MLMultiArray`)
- If using `MLMultiArray`, add conversion in `encode()`

### Low FPS (< 30)
- Reduce input resolution (try 384×384 or 512×512)
- Verify model uses Neural Engine: check `computeUnits = .all`
- Use Instruments (Core ML template) to profile inference time
- Ensure no blocking on main thread

### Memory pressure
- Reuse `CVPixelBuffer` pool instead of allocating each frame
- Clear old buffers in `applyStylizedFrame()`
- Monitor in Xcode Memory debugger

---

## Next Steps After Model Integration

1. ✅ Verify 30+ FPS in `DemoStyleBenchmarkView`
2. Implement ARKit camera frame capture (iOS) or passthrough (visionOS)
3. Wire camera frames → `StyleTransferEngine.process()` → `applyStylizedFrame()`
4. Implement `ARRoomMapper` to visualize planes/mesh
5. Add UI to switch between styles (sci-fi, fantasy, etc.)
6. Add your other trained models to bundle and create a `StylePicker`

---

## File Checklist

- [x] `CoreMLStyleAdapter.swift` - Ready for your model
- [x] `ImmersiveView.swift` - Cleaned up, ready for AR mapping + style transfer
- [x] `DemoStyleBenchmarkView.swift` - FPS benchmark harness
- [ ] `YourModel.mlmodel` - **← Add this from your training repo**
- [ ] Update `modelName` in `CoreMLStyleAdapter.swift`
- [ ] Swap adapter in `DemoStyleBenchmarkView.swift`
- [ ] Test and verify 30+ FPS ✨

---

**You're ready!** Once your model training is done, just drop the `.mlmodel` into Xcode and update the adapter config. The pipeline is already built.
