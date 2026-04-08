# ZJPG - JPEG Encoder for Zig

A pure Zig implementation of a JPEG encoder supporting color images with baseline DCT encoding, conforming to ITU-T T.81 (JPEG) standard.

## Features

- Full color support with YCbCr encoding
- Chroma subsampling modes: 4:4:4, 4:2:2, 4:2:0, and 4:1:1
- Resolution support from 1×1 to 65535×65535 pixels
- Baseline DCT with 8-bit precision (JFIF 1.01 format)
- Configurable quality through custom quantization tables
- Standard-compliant Huffman encoding
- Automatic padding for non-multiple-of-8 dimensions
- Zero external dependencies

## Installation

### Using Zig Package Manager (build.zig.zon)

Add ZJPG as a dependency in your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zjpg = .{
            .path = "path/to/zjpg",
        },
    },
}
```

Then in your `build.zig`:

```zig
const zjpg_dep = b.dependency("zjpg", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zjpg", zjpg_dep.module("zjpg"));
```

### Manual Installation

Copy the `src` directory to your project and import directly.

## Usage

### Simple Example - Convenience Function

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create some RGB image data (width × height × 3 bytes)
    const width = 640;
    const height = 480;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // Fill with your image data (R, G, B, R, G, B, ...)
    // For example, a red gradient:
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            rgb_pixels[idx + 0] = @intCast((x * 255) / width); // R
            rgb_pixels[idx + 1] = 0;                           // G
            rgb_pixels[idx + 2] = 0;                           // B
        }
    }

    // Encode to JPEG (null = use default quantization tables, 4:4:4 = no chroma subsampling)
    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, null, .@"4:4:4");
    defer allocator.free(jpeg_data);

    // Write to file
    const file = try std.fs.cwd().createFile("output.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);

    std.debug.print("Wrote {d} bytes to output.jpg\n", .{jpeg_data.len});
}
```

### Using the Encoder API

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize encoder
    var encoder = zjpg.JpegEncoder.init(allocator);
    defer encoder.deinit();

    // Prepare RGB data
    const width = 320;
    const height = 240;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // Fill with blue color
    @memset(rgb_pixels, 0);
    for (0..width * height) |i| {
        rgb_pixels[i * 3 + 2] = 255; // Blue channel
    }

    // Encode (null = use default quantization tables, 4:4:4 = full color resolution)
    const jpeg_data = try encoder.encode(width, height, rgb_pixels, null, .@"4:4:4");
    defer allocator.free(jpeg_data);

    // Save to file
    const file = try std.fs.cwd().createFile("blue.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

### Custom Quantization Tables

You can control JPEG quality and compression by providing custom quantization tables.

#### Using Standard Quality Levels

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const width = 640;
    const height = 480;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // ... fill rgb_pixels with image data ...

    // Create quantization tables with quality factor (1-100)
    // Higher quality = less compression, larger file
    const tables = zjpg.QuantizationTables.standard(85);

    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &tables, .@"4:4:4");
    defer allocator.free(jpeg_data);

    // Write to file
    const file = try std.fs.cwd().createFile("high_quality.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

**Quality Guidelines:**
- **100**: Best quality, minimal compression (~same size as default)
- **85-95**: Excellent quality, good for photos
- **75-84**: Good quality, reasonable compression
- **50-74**: Acceptable quality, higher compression
- **1-49**: Low quality, maximum compression

#### Using Fully Custom Tables

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create custom quantization tables
    var custom_tables: zjpg.QuantizationTables = undefined;

    // Set all luma values to 8 (aggressive quantization)
    for (0..64) |i| {
        custom_tables.luma[i] = 8;
    }

    // Set all chroma values to 12 (even more aggressive)
    for (0..64) |i| {
        custom_tables.chroma[i] = 12;
    }

    const width = 640;
    const height = 480;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // ... fill rgb_pixels ...

    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &custom_tables, .@"4:4:4");
    defer allocator.free(jpeg_data);

    const file = try std.fs.cwd().createFile("custom.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

**Note:** Quantization table values are in natural (row-major) order, not zigzag. Each value should be 1-255, where:
- Lower values = higher quality, less compression
- Higher values = lower quality, more compression

### Chroma Subsampling

Chroma subsampling reduces file size by storing color (chrominance) information at lower resolution than brightness (luminance). ZJPG supports all common subsampling modes:

- **4:4:4** - Full color resolution (no subsampling). Best quality, larger files. MCU: 8×8 pixels.
- **4:2:2** - Half horizontal chroma resolution. Good for images with horizontal detail. MCU: 16×8 pixels.
- **4:2:0** - Half horizontal and vertical chroma resolution (most common mode). Excellent quality/size balance. MCU: 16×16 pixels.
- **4:1:1** - Quarter horizontal chroma resolution. Aggressive compression, lower quality. MCU: 32×8 pixels.

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const width = 640;
    const height = 480;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // ... fill rgb_pixels ...

    // Use 4:2:0 subsampling for smaller file size (standard for most JPEGs)
    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, null, .@"4:2:0");
    defer allocator.free(jpeg_data);

    const file = try std.fs.cwd().createFile("photo.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

**Subsampling Mode Guidelines:**
- **4:4:4** - Use for images with fine color details, text, graphics, medical images, or when file size is not a concern
- **4:2:2** - Good for broadcast video, images with strong horizontal features
- **4:2:0** - Best for photos and natural images (most common mode, used by ~95% of JPEGs)
- **4:1:1** - Maximum compression for low-quality previews or thumbnails

**Note:** You can combine subsampling with quality settings for optimal compression:
```zig
const tables = zjpg.QuantizationTables.standard(85);

// High quality photo
const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &tables, .@"4:2:0");

// Aggressive compression for thumbnails
const tables_low = zjpg.QuantizationTables.standard(50);
const thumbnail = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &tables_low, .@"4:1:1");
```

## API Reference

### Main Functions

#### `zjpg.encodeRGB(allocator, width, height, rgb_data, quant_tables, subsampling) ![]u8`

Convenience function for one-shot encoding.

**Parameters:**
- `allocator: std.mem.Allocator` - Memory allocator for output buffer
- `width: u32` - Image width in pixels (1-65535)
- `height: u32` - Image height in pixels (1-65535)
- `rgb_data: []const u8` - RGB pixel data, must be `width * height * 3` bytes
- `quant_tables: ?*const QuantizationTables` - Optional custom quantization tables (null = use defaults)
- `subsampling: SubsamplingMode` - Chroma subsampling mode (`.@"4:4:4"`, `.@"4:2:2"`, `.@"4:2:0"`, or `.@"4:1:1"`)

**Returns:**
- `[]u8` - JPEG file data (caller owns memory, must free)

**Errors:**
- `error.InvalidDimensions` - Width or height is 0
- `error.DimensionsTooLarge` - Width or height > 65535
- `error.InvalidDataSize` - RGB data size doesn't match width × height × 3

### JpegEncoder

#### `JpegEncoder.init(allocator) JpegEncoder`

Create a new encoder instance.

#### `encoder.deinit()`

Clean up encoder resources (currently no-op).

#### `encoder.encode(width, height, rgb_data, quant_tables, subsampling) ![]u8`

Encode RGB image to JPEG.

**Parameters:**
- Same as `encodeRGB()`

**Returns:**
- Same as `encodeRGB()`

### SubsamplingMode

```zig
pub const SubsamplingMode = enum {
    @"4:4:4",  // Full color resolution (8×8 MCU)
    @"4:2:2",  // Half horizontal chroma (16×8 MCU)
    @"4:2:0",  // Half horizontal + vertical chroma (16×16 MCU)
    @"4:1:1",  // Quarter horizontal chroma (32×8 MCU)
};
```

**Chroma Sampling Factors:**
- 4:4:4 - Y:1×1, Cb:1×1, Cr:1×1 (no subsampling)
- 4:2:2 - Y:2×1, Cb:1×1, Cr:1×1 (2 Y blocks per MCU)
- 4:2:0 - Y:2×2, Cb:1×1, Cr:1×1 (4 Y blocks per MCU)
- 4:1:1 - Y:4×1, Cb:1×1, Cr:1×1 (4 Y blocks per MCU)

### QuantizationTables

#### `QuantizationTables.default() QuantizationTables`

Create default quantization tables (same as standard 100).

#### `QuantizationTables.standard(quality: u8) QuantizationTables`

Create standard JPEG quantization tables with quality factor.

**Parameters:**
- `quality: u8` - Quality level from 1 (worst) to 100 (best)

**Returns:**
- `QuantizationTables` with scaled standard JPEG tables

#### Custom Tables

```zig
pub const QuantizationTables = struct {
    luma: [64]u8,    // Luminance quantization table
    chroma: [64]u8,  // Chrominance quantization table
};
```

Values are in natural (row-major) order. Each value should be 1-255.

## Input Format

RGB data must be provided as interleaved bytes in row-major order:

```
[R₀, G₀, B₀, R₁, G₁, B₁, R₂, G₂, B₂, ...]
```

Where each color component is a byte (0-255).

**Example for a 2×2 image:**
```
Pixel (0,0): Red
Pixel (1,0): Green
Pixel (0,1): Blue
Pixel (1,1): White

Data: [255,0,0, 0,255,0, 0,0,255, 255,255,255]
```

## Supported Resolutions

ZJPG supports all resolutions from 1×1 to 65535×65535 pixels:

- Minimum size: 1×1 pixel
- Small images (< 8×8): Automatically padded
- Non-multiples of 8: Edge pixels replicated for padding
- Rectangular images: Any aspect ratio
- Odd dimensions: 7×13, 99×101, etc.
- Maximum size: 65535×65535 (JPEG specification limit)

## Technical Details

### Encoding Process

1. **Color Space Conversion**: RGB → YCbCr (ITU-R BT.601)
2. **Block Processing**: 8×8 pixel blocks with edge padding
3. **DCT**: 2D Discrete Cosine Transform
4. **Quantization**: Configurable tables (default, standard quality, or fully custom)
5. **Zigzag Reordering**: Entropy coding optimization
6. **Huffman Encoding**: Standard Huffman tables with RLE

### Format Details

- **Format**: JFIF 1.01
- **Encoding**: Baseline DCT
- **Precision**: 8-bit
- **Chroma Subsampling**: Configurable (4:4:4, 4:2:2, 4:2:0, 4:1:1)
- **Quantization**: Fully customizable tables with standard quality presets
- **Huffman Tables**: Standard DC/AC tables for luminance and chrominance
- **Color Space**: RGB → YCbCr conversion using ITU-R BT.601

## Building

```bash
# Build library
zig build

# Run tests
zig build test

# Run example
zig build run
```

## Testing

The library includes comprehensive tests for various resolutions:

```bash
zig build test
```

Test images are generated in the project root:
- `test_1x1.jpg` - Minimum size (1×1 pixel)
- `test_5x5.jpg` - Smaller than 8×8 block
- `test_7x13.jpg` - Odd dimensions
- `test_10x10.jpg` - Not multiple of 8
- `test_16x8.jpg` - Rectangular
- `test_16x16.jpg` - Standard size
- `test_444.jpg`, `test_422.jpg`, `test_420.jpg`, `test_411.jpg` - All subsampling modes
- `test_quality*.jpg` - Various quality levels (100, 85, 50, 10)

**Note about test results:** The test images use synthetic patterns (checkerboards, color blocks) which compress differently than natural photos. With synthetic patterns, subsampling may not always reduce file size due to MCU overhead and pattern characteristics. **Real photographs typically show 15-25% size reduction** with 4:2:0 subsampling compared to 4:4:4.

## Limitations

- Encoder only (no decoder implementation)
- Baseline DCT only (no progressive or lossless modes)
- RGB input only (converts to YCbCr internally)