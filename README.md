# ZJPG

JPEG encoder for Zig. Takes RGB image data, produces standard JPEG files. No external dependencies.

Useful when you need JPEG output in a Zig project without pulling in C libraries, or when you need precise control over compression — per-coefficient quantization tables for luma and chroma independently, all four standard chroma subsampling modes, and quality presets compatible with standard JPEG tooling.

## Installation

### Zig Package Manager

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .zjpg = .{
        .path = "path/to/zjpg",
    },
},
```

In `build.zig`, first get the dependency:

```zig
const zjpg_dep = b.dependency("zjpg", .{ .target = target, .optimize = optimize });
```

Then add it to your module using whichever form fits:

**`addImport`** — when you have a module variable (e.g., from `b.addModule`):
```zig
mod.addImport("zjpg", zjpg_dep.module("zjpg"));
```

**`.imports`** — when creating a module inline (e.g., inside `b.addExecutable` or `b.createModule`):
```zig
.imports = &.{
    .{ .name = "zjpg", .module = zjpg_dep.module("zjpg") },
},
```

### Manual

Copy the `src` directory into your project and import directly.

## Usage

### Basic encoding

`encodeRGB` is the primary API.

```zig
const std = @import("std");
const zjpg = @import("zjpg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // RGB image data: width × height × 3 bytes (R, G, B interleaved, row-major)
    const width = 640;
    const height = 480;
    var rgb_pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb_pixels);

    // Fill with a red gradient (replace with your actual image data)
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * 3;
            rgb_pixels[idx + 0] = @intCast((x * 255) / width); // R
            rgb_pixels[idx + 1] = 0;                           // G
            rgb_pixels[idx + 2] = 0;                           // B
        }
    }

    // null = default quantization tables
    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, null, .@"4:4:4");
    defer allocator.free(jpeg_data);

    const file = try std.fs.cwd().createFile("output.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

### Quality presets

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

    // Fill with your image data (see one-shot example above)

    // Quality 1–100: higher = better quality, larger file
    const tables = zjpg.QuantizationTables.standard(85);

    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &tables, .@"4:2:0");
    defer allocator.free(jpeg_data);

    const file = try std.fs.cwd().createFile("output.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

### Custom quantization tables

Full per-coefficient control over luma and chroma quantization independently. Values 1–255; lower = less loss.

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

    // Fill with your image data (see one-shot example above)

    var tables: zjpg.QuantizationTables = undefined;
    // Each array has 64 entries — one per DCT coefficient in natural (row-major) order, not zigzag
    for (0..64) |i| tables.luma[i]   = 4;   // high luma quality
    for (0..64) |i| tables.chroma[i] = 64;  // aggressive chroma compression

    const jpeg_data = try zjpg.encodeRGB(allocator, width, height, rgb_pixels, &tables, .@"4:4:4");
    defer allocator.free(jpeg_data);

    const file = try std.fs.cwd().createFile("output.jpg", .{});
    defer file.close();
    try file.writeAll(jpeg_data);
}
```

### Chroma subsampling

Reduces file size by storing chrominance at lower resolution than luminance. For natural photos, 4:2:0 typically yields meaningfully smaller files than 4:4:4 with minimal perceptual difference. The actual reduction varies with content, image dimensions, and quality setting. 4:1:1 discards more horizontal chroma than 4:2:0 but can produce larger output in some cases — its 32×8 MCU layout compresses differently than 4:2:0's 16×16 blocks depending on the image.

| Mode | Description |
|------|-------------|
| `4:4:4` | No subsampling — full color resolution |
| `4:2:2` | Half horizontal chroma |
| `4:2:0` | Half horizontal + vertical chroma (most common for photos) |
| `4:1:1` | Quarter horizontal chroma |

Combine with quality presets (see [basic example](#basic-encoding) for full setup):

```zig
const tables_hi = zjpg.QuantizationTables.standard(85);
const tables_lo = zjpg.QuantizationTables.standard(50);

const photo     = try zjpg.encodeRGB(allocator, w, h, pixels, &tables_hi, .@"4:2:0");
defer allocator.free(photo);

const thumbnail = try zjpg.encodeRGB(allocator, w, h, pixels, &tables_lo, .@"4:2:0");
defer allocator.free(thumbnail);
```

### Object-oriented style

`JpegEncoder` is available for code that prefers explicit object lifecycle management. It currently offers no additional functionality over `encodeRGB`.

```zig
var encoder = zjpg.JpegEncoder.init(allocator);
defer encoder.deinit();

const jpeg_data = try encoder.encode(width, height, rgb_pixels, null, .@"4:2:0");
defer allocator.free(jpeg_data);
```

## API Reference

### `zjpg.encodeRGB`

```zig
fn encodeRGB(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    rgb_data: []const u8,
    quant_tables: ?*const QuantizationTables,  // null = default (same as standard(100))
    subsampling: SubsamplingMode,
) ![]u8
```

Returns owned slice. Caller must free.

**Errors:**
- `error.InvalidDimensions` — width or height is 0
- `error.DimensionsTooLarge` — width or height > 65535
- `error.InvalidDataSize` — `rgb_data.len != width * height * 3`

### `JpegEncoder`

```zig
fn init(allocator: std.mem.Allocator) JpegEncoder
fn deinit(self: *JpegEncoder) void  // currently no-op
fn encode(self: *JpegEncoder, width, height, rgb_data, quant_tables, subsampling) ![]u8
```

Same parameters and errors as `encodeRGB`.

### `QuantizationTables`

```zig
pub const QuantizationTables = struct {
    luma:   [64]u8,
    chroma: [64]u8,

    pub fn default() QuantizationTables              // same as standard(100); also what null produces in encodeRGB
    pub fn standard(quality: u8) QuantizationTables  // quality: 1–100; values outside range are clamped
};
```

Values in natural (row-major) order. Range 1–255.

### `SubsamplingMode`

```zig
pub const SubsamplingMode = enum {
    @"4:4:4",  // Y:1×1, Cb:1×1, Cr:1×1 — 8×8 MCU
    @"4:2:2",  // Y:2×1, Cb:1×1, Cr:1×1 — 16×8 MCU
    @"4:2:0",  // Y:2×2, Cb:1×1, Cr:1×1 — 16×16 MCU
    @"4:1:1",  // Y:4×1, Cb:1×1, Cr:1×1 — 32×8 MCU
};
```

## Input Format

RGB bytes, interleaved, row-major:

```
[R₀ G₀ B₀  R₁ G₁ B₁  R₂ G₂ B₂ ...]
```

Each channel 0–255. Input size must be exactly `width * height * 3` bytes.

Images with dimensions not divisible by 8 are handled automatically — edge pixels are replicated to fill the last block. Minimum size: 1×1. Maximum: 65535×65535 (JPEG spec limit).

## Technical Details

Encoding pipeline: RGB → YCbCr (ITU-R BT.601) → 8×8 DCT blocks → quantization → zigzag reorder → Huffman coding (standard tables from ITU-T T.81 Annex K).

Output format: JFIF 1.01, baseline DCT, 8-bit precision.

## Building

Requires Zig 0.15.1 or newer.

```bash
zig build        # build library
zig build test   # run tests
```

## Testing

```bash
zig build test
```

Test images are written to `test_output/`. They use synthetic patterns (checkerboards, color blocks), which compress differently than natural photos.

## Limitations

- Encoder only — no decoder
- Baseline DCT only — no progressive or lossless modes
- RGB input only — converted to YCbCr internally
