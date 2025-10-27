# ML Model Not Found in Bundle - Fix Guide

## Problem
Your `starry_night.mlpackage` file exists in the project directory (`room-visualizer/Models/starry_night.mlpackage`) but is **not being included in the app bundle** when you build the project. This is why you see:

```
[ImmersiveView] Failed to find starry_night.mlpackage in bundle
```

## Root Cause
Your Xcode project uses **PBXFileSystemSynchronizedRootGroup** (Xcode 16's new automatic file sync), but the `Models/` folder is not properly registered in the Xcode project, so it's being excluded from the build.

## Solution (Choose One)

### Option 1: Add ML Model to Xcode Project (Recommended)

1. **Open `room-visualizer.xcodeproj` in Xcode**

2. **Locate the file in Finder:**
   - Path: `room-visualizer/Models/starry_night.mlpackage`

3. **Drag and drop** the `starry_night.mlpackage` file into the Xcode project navigator (left sidebar)
   - Drag it into the `room-visualizer` folder group

4. **In the dialog that appears, ensure:**
   - ✅ **"Copy items if needed"** is CHECKED
   - ✅ **"Add to targets: room-visualizer"** is CHECKED
   - Click **"Finish"**

5. **Verify the file is added:**
   - Select the `starry_night.mlpackage` file in Xcode
   - Open the **File Inspector** (right sidebar)
   - Under "Target Membership", ensure **"room-visualizer"** is checked

6. **Clean and rebuild:**
   ```bash
   # In Xcode: Product > Clean Build Folder (Cmd+Shift+K)
   # Then: Product > Build (Cmd+B)
   ```

### Option 2: Use Direct File Path (Development Only)

If you want a quick temporary fix for testing, you can load the model directly from the source directory:

```swift
private func loadStyleTransferModel() async {
    do {
        // Development path - load directly from source (won't work in release builds)
        let projectPath = "/Users/epontarelli/room-visualizer/room-visualizer/Models/starry_night.mlpackage"
        let modelURL = URL(fileURLWithPath: projectPath)
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("[ImmersiveView] ❌ Model file does not exist at: \(modelURL.path)")
            return
        }
        
        print("[ImmersiveView] 📦 Loading model from development path: \(modelURL)")
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        
        // ... rest of your code
```

**Note:** This is only for testing. The proper solution is Option 1.

## Verification

After implementing Option 1, run the app again. You should see:

```
[ImmersiveView] 📁 Bundle resource path: /path/to/bundle
[ImmersiveView] 📂 Bundle contents (top level):
  - starry_night.mlpackage
[ImmersiveView] 📦 Found model at: file:///path/to/bundle/starry_night.mlpackage
[ImmersiveView] ✅ Style transfer model loaded successfully
```

## Additional Tips

### Check Build Phases
After adding the file, verify it's in the build phases:

1. Select your project in Xcode
2. Select the "room-visualizer" target
3. Go to **Build Phases** tab
4. Expand **"Copy Bundle Resources"**
5. Verify `starry_night.mlpackage` is listed there

If it's not listed:
- Click the **"+"** button
- Search for `starry_night.mlpackage`
- Add it to the list

### Common Issues

**Issue:** "The file exists but still not found"
- **Solution:** Make sure you're not looking at a symbolic link. The actual .mlpackage needs to be in the bundle.

**Issue:** "File is grayed out in Xcode"
- **Solution:** Check the file's location on disk. It might be in the wrong directory.

**Issue:** "Multiple copies of the model"
- **Solution:** Use only one copy. Having duplicates can cause confusion.

## Debug Output

The updated code now prints detailed information about what's in your bundle. Run the app and check the console for:

1. Bundle resource path
2. Bundle contents
3. Whether Models folder exists
4. What files are in the bundle

This will help confirm whether the model is being included or not.
