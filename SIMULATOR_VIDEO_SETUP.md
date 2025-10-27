# Video Passthrough Simulator Setup

## What Was Implemented

Since camera/passthrough is **not available in the visionOS simulator**, we've created a video-based workaround that simulates passthrough by:

1. Playing a pre-recorded video file
2. Applying your CoreML style transfer model to each frame
3. Displaying the stylized result as a full-screen texture in the immersive space

## What You Need To Do

### 1. Add a Video File to Your Project

To use the video passthrough simulator, you need to add a video file to your Xcode project:

1. **Find or record a video** (e.g., a room walkthrough, indoor scene, etc.)
   - Recommended: MP4 format, 720p or 1080p
   - Duration: 10-30 seconds (will loop automatically)

2. **Add to Xcode project:**
   - Drag the video file into Xcode's Project Navigator
   - **Ensure** "Copy items if needed" is checked
   - **Ensure** "room-visualizer" target is selected
   - Name the file: **`test-room.mp4`** (or update the filename in `ImmersiveView.swift`)

### 2. Verify Your Model is Loaded

The code expects your CoreML model at:
- **Model name:** `starry_night.mlmodelc` or `starry_night.mlpackage`
- **Location:** Should be in the app bundle

To verify:
```swift
// In Xcode, check that starry_night.mlpackage is in the project
// and has target membership for "room-visualizer"
```

### 3. Run in Simulator

1. Select **visionOS Simulator** as your run destination
2. Build and run the app
3. Tap **"Show Immersive Space"**
4. You should see:
   - Your video playing
   - Style transfer applied to each frame
   - The styled result displayed as a virtual "passthrough"

### 4. Fallback Behavior

If the video file is not found, the app will fall back to the original **demo planes** mode:
- 4 colored planes in 3D space
- Style transfer applied to gradient textures on the planes

## Code Changes Made

### New Files
- **`VideoPassthroughSimulator.swift`**: Handles video playback, frame extraction, and style transfer

### Modified Files
- **`ImmersiveView.swift`**:
  - Cleaned up excessive logging
  - Added video passthrough mode for simulator
  - Fallback to demo planes if video not found

- **`CoreMLStyleAdapter.swift`**:
  - Removed excessive logging
  - Cleaner error handling

- **`RoomVisualizerApp.swift`**:
  - Fixed naming convention (`room_visualizerApp` → `RoomVisualizerApp`)

### Removed Files
- **`StyleTransferShaders.metal`** (empty file)
- **`AVPlayerView.swift`** (unused)
- **`AVPlayerViewModel.swift`** (unused)

## Testing on Real Device

When running on a **real Vision Pro**:
- The app will use **actual ARKit** instead of video simulation
- Plane detection and style transfer will work with the real environment
- No changes needed to your code - it automatically detects simulator vs. device

## Customization

### Change Video Filename
Edit `ImmersiveView.swift` line ~155:
```swift
guard let videoURL = Bundle.main.url(forResource: "YOUR_VIDEO_NAME", withExtension: "mp4") else {
```

### Change Model Name
Edit `ImmersiveView.swift` line ~127:
```swift
guard let modelURL = Bundle.main.url(forResource: "YOUR_MODEL_NAME", withExtension: "mlmodelc") else {
```

### Adjust Display Size
Edit `ImmersiveView.swift` line ~188:
```swift
let mesh = MeshResource.generatePlane(width: 10.0, depth: 5.625) // Adjust dimensions
```

## Performance Notes

- **Frame Rate**: Depends on your CoreML model and Neural Engine availability
- **Resolution**: Video should be 720p-1080p for best balance of quality vs. performance
- **Model Optimization**: Ensure your CoreML model uses `.all` compute units (CPU + GPU + Neural Engine)

## Troubleshooting

**"Video not found" message:**
- Check video is in Xcode project
- Verify filename matches code
- Ensure target membership is correct

**Model not loading:**
- Check model is `starry_night.mlpackage` or `.mlmodelc`
- Verify target membership in Xcode
- Run "Test Model Load" button in ContentView

**Style transfer not working:**
- Check Console for errors
- Verify model input/output match code expectations
- Try running on a simpler test video first

## Next Steps

1. Add `test-room.mp4` to your project
2. Run in simulator
3. Once working in simulator, test on real Vision Pro for actual passthrough style transfer
4. Consider adding UI toggle between video mode and demo planes mode
