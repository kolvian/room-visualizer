//
//  StyleTransferShaders.metal
//  room-visualizer
//
//  GPU-accelerated pixel buffer conversions for style transfer
//

#include <metal_stdlib>
using namespace metal;

/// Convert BGRA8 pixel buffer to planar RGB float32 tensor [1, 3, H, W]
/// Scales values from 0-1 (texture range) to 0-255 (model input range)
kernel void convertBGRAToTensor(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device float* outputTensor [[buffer(0)]],
    constant uint& width [[buffer(1)]],
    constant uint& height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
)
{
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // Read BGRA pixel (texture values are 0-1)
    float4 pixel = inputTexture.read(gid);

    // Extract RGB channels and scale to 0-255 for model input
    float r = pixel.r * 255.0f;
    float g = pixel.g * 255.0f;
    float b = pixel.b * 255.0f;

    // Calculate offsets for CHW layout: [batch, channel, height, width]
    uint pixelIndex = gid.y * width + gid.x;
    uint pixelCount = width * height;

    uint rOffset = 0;
    uint gOffset = pixelCount;
    uint bOffset = pixelCount * 2;

    // Store values in 0-255 range
    outputTensor[rOffset + pixelIndex] = r;
    outputTensor[gOffset + pixelIndex] = g;
    outputTensor[bOffset + pixelIndex] = b;
}

/// Convert planar RGB float32 tensor [1, 3, H, W] to BGRA8 pixel buffer
/// Converts from 0-255 (model output range) to 0-1 (texture range) with clamping
kernel void convertTensorToBGRA(
    device const float* inputTensor [[buffer(0)]],
    texture2d<float, access::write> outputTexture [[texture(0)]],
    constant uint& width [[buffer(1)]],
    constant uint& height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
)
{
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // Calculate offsets for CHW layout
    uint pixelIndex = gid.y * width + gid.x;
    uint pixelCount = width * height;

    uint rOffset = 0;
    uint gOffset = pixelCount;
    uint bOffset = pixelCount * 2;

    // Read RGB values from tensor (0-255 range)
    float r = inputTensor[rOffset + pixelIndex];
    float g = inputTensor[gOffset + pixelIndex];
    float b = inputTensor[bOffset + pixelIndex];

    // Scale from 0-255 to 0-1 and clamp
    r = clamp(r / 255.0f, 0.0f, 1.0f);
    g = clamp(g / 255.0f, 0.0f, 1.0f);
    b = clamp(b / 255.0f, 0.0f, 1.0f);

    // Write BGRA pixel (alpha = 1.0)
    float4 pixel = float4(r, g, b, 1.0);
    outputTexture.write(pixel, gid);
}
