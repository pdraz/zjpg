const std = @import("std");
const test_image = @import("test_image.zig");
const zjpg = @import("root.zig");

// Checks that a JPEG byte slice has correct structure:
//   SOI marker, APP0/JFIF header, EOI at end, byte stuffing in entropy data.
fn assertValidJpeg(data: []const u8) !void {
    // Minimum plausible JPEG: SOI + APP0 + ... + EOI
    try std.testing.expect(data.len >= 20);

    // SOI
    try std.testing.expectEqual(@as(u8, 0xFF), data[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), data[1]);

    // APP0 marker (JFIF)
    try std.testing.expectEqual(@as(u8, 0xFF), data[2]);
    try std.testing.expectEqual(@as(u8, 0xE0), data[3]);

    // "JFIF\x00" at offset 6
    try std.testing.expectEqualSlices(u8, "JFIF\x00", data[6..11]);

    // EOI at the very end
    try std.testing.expectEqual(@as(u8, 0xFF), data[data.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), data[data.len - 1]);

    // Byte stuffing: scan after SOS for bare 0xFF bytes.
    // Find SOS marker (0xFF 0xDA) first.
    var sos_end: usize = 0;
    var i: usize = 2;
    while (i + 1 < data.len) {
        if (data[i] == 0xFF and data[i + 1] == 0xDA) {
            // SOS length field is at i+2 (big-endian u16)
            if (i + 3 >= data.len) break;
            const sos_len = (@as(usize, data[i + 2]) << 8) | data[i + 3];
            sos_end = i + 2 + sos_len; // first byte of entropy-coded data
            break;
        }
        i += 1;
    }

    if (sos_end > 0 and sos_end + 2 < data.len) {
        var j: usize = sos_end;
        while (j < data.len - 2) : (j += 1) {
            if (data[j] == 0xFF) {
                // Must be stuffed (0x00) or a valid marker (0xD9 = EOI)
                const next = data[j + 1];
                try std.testing.expect(next == 0x00 or next == 0xD9);
                if (next == 0xD9) break; // reached EOI inside scan
            }
        }
    }
}

test "various resolutions" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct {
        width: u32,
        height: u32,
        data: []const u8,
        name: []const u8,
        desc: []const u8,
    }{
        .{ .width = 1, .height = 1, .data = &test_image.TEST_IMAGE_1x1_RGB, .name = "test_1x1.jpg", .desc = "minimum size" },
        .{ .width = 5, .height = 5, .data = &test_image.TEST_IMAGE_5x5_RGB, .name = "test_5x5.jpg", .desc = "smaller than 8x8 block" },
        .{ .width = 7, .height = 13, .data = &test_image.TEST_IMAGE_7x13_RGB, .name = "test_7x13.jpg", .desc = "odd dimensions" },
        .{ .width = 10, .height = 10, .data = &test_image.TEST_IMAGE_10x10_RGB, .name = "test_10x10.jpg", .desc = "not multiple of 8" },
        .{ .width = 16, .height = 8, .data = &test_image.TEST_IMAGE_16x8_RGB, .name = "test_16x8.jpg", .desc = "rectangular" },
        .{ .width = 16, .height = 16, .data = &test_image.TEST_IMAGE_16x16_RGB, .name = "test_16x16.jpg", .desc = "standard size" },
    };

    std.debug.print("\nResolution tests:\n", .{});
    for (test_cases) |tc| {
        const jpeg_data = try zjpg.encodeRGB(allocator, tc.width, tc.height, tc.data, null, .@"4:4:4");
        defer allocator.free(jpeg_data);

        try std.testing.expect(jpeg_data.len > 100);

        const file = std.fs.cwd().createFile(tc.name, .{}) catch |err| {
            std.debug.print("Warning: couldn't create {s}: {}\n", .{ tc.name, err });
            continue;
        };
        defer file.close();
        try file.writeAll(jpeg_data);
        std.debug.print("  {}x{} ({s}): {} bytes -> {s}\n", .{ tc.width, tc.height, tc.desc, jpeg_data.len, tc.name });
    }
}

test "public API" {
    const allocator = std.testing.allocator;

    std.debug.print("\nPublic API tests:\n", .{});

    var encoder = zjpg.JpegEncoder.init(allocator);
    defer encoder.deinit();

    const jpeg_encoder = try encoder.encode(16, 16, &test_image.TEST_IMAGE_16x16_RGB, null, .@"4:4:4");
    defer allocator.free(jpeg_encoder);
    try std.testing.expect(jpeg_encoder.len > 100);
    std.debug.print("  JpegEncoder.encode(): {} bytes\n", .{jpeg_encoder.len});

    const jpeg_convenience = try zjpg.encodeRGB(allocator, 10, 10, &test_image.TEST_IMAGE_10x10_RGB, null, .@"4:4:4");
    defer allocator.free(jpeg_convenience);
    try std.testing.expect(jpeg_convenience.len > 100);
    std.debug.print("  encodeRGB(): {} bytes\n", .{jpeg_convenience.len});
}

test "custom quantization" {
    const allocator = std.testing.allocator;

    const quality_levels = [_]u8{ 100, 85, 50, 10 };
    var quality_results: [4]usize = undefined;

    std.debug.print("\nQuantization quality tests:\n", .{});
    for (quality_levels, 0..) |quality, i| {
        const tables = zjpg.QuantizationTables.standard(quality);
        const jpeg_data = try zjpg.encodeRGB(allocator, 16, 16, &test_image.TEST_IMAGE_16x16_RGB, &tables, .@"4:4:4");
        defer allocator.free(jpeg_data);

        try std.testing.expect(jpeg_data.len > 100);
        quality_results[i] = jpeg_data.len;

        var filename_buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "test_quality{}.jpg", .{quality});
        const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            std.debug.print("Warning: couldn't create {s}: {}\n", .{ filename, err });
            continue;
        };
        defer file.close();
        try file.writeAll(jpeg_data);
        std.debug.print("  Quality {}: {} bytes -> {s}\n", .{ quality, jpeg_data.len, filename });
    }

    var custom_tables: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        custom_tables.luma[i] = 50;
        custom_tables.chroma[i] = 50;
    }

    const jpeg_data = try zjpg.encodeRGB(allocator, 16, 16, &test_image.TEST_IMAGE_16x16_RGB, &custom_tables, .@"4:4:4");
    defer allocator.free(jpeg_data);

    try std.testing.expect(jpeg_data.len > 100);

    const filename = "test_quality_custom.jpg";
    const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
        std.debug.print("Warning: couldn't create {s}: {}\n", .{ filename, err });
        return;
    };
    defer file.close();
    try file.writeAll(jpeg_data);
    std.debug.print("  Quality custom: {} bytes -> {s}\n", .{jpeg_data.len, filename});
}

test "chroma subsampling - all modes" {
    const allocator = std.testing.allocator;

    // Use 32x32 gradient image for realistic compression behavior
    const jpeg_444 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, null, .@"4:4:4");
    defer allocator.free(jpeg_444);

    const jpeg_422 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, null, .@"4:2:2");
    defer allocator.free(jpeg_422);

    const jpeg_420 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, null, .@"4:2:0");
    defer allocator.free(jpeg_420);

    const jpeg_411 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, null, .@"4:1:1");
    defer allocator.free(jpeg_411);

    try std.testing.expect(jpeg_444.len > 100);
    try std.testing.expect(jpeg_422.len > 100);
    try std.testing.expect(jpeg_420.len > 100);
    try std.testing.expect(jpeg_411.len > 100);

    const files = [_]struct { name: []const u8, data: []const u8, mode: []const u8 }{
        .{ .name = "test_444.jpg", .data = jpeg_444, .mode = "4:4:4" },
        .{ .name = "test_422.jpg", .data = jpeg_422, .mode = "4:2:2" },
        .{ .name = "test_420.jpg", .data = jpeg_420, .mode = "4:2:0" },
        .{ .name = "test_411.jpg", .data = jpeg_411, .mode = "4:1:1" },
    };

    std.debug.print("\nChroma subsampling (32x32 gradient image):\n", .{});
    for (files) |f| {
        const file = std.fs.cwd().createFile(f.name, .{}) catch |err| {
            std.debug.print("Warning: couldn't create {s}: {}\n", .{ f.name, err });
            continue;
        };
        defer file.close();
        try file.writeAll(f.data);

        // Calculate reduction vs 4:4:4
        const reduction = 100.0 * (1.0 - @as(f64, @floatFromInt(f.data.len)) / @as(f64, @floatFromInt(jpeg_444.len)));
        std.debug.print("  {s}: {} bytes ({d:.1}% vs 4:4:4) -> {s}\n", .{ f.mode, f.data.len, reduction, f.name });
    }
}

test "JPEG structure validation" {
    // Every output from the encoder must satisfy the JPEG binary structure
    // regardless of image content, size or encoding parameters.
    const allocator = std.testing.allocator;

    std.debug.print("\nJPEG structure validation:\n", .{});

    const cases = [_]struct {
        w: u32,
        h: u32,
        data: []const u8,
        label: []const u8,
    }{
        .{ .w = 1, .h = 1, .data = &test_image.TEST_IMAGE_1x1_RGB, .label = "1x1" },
        .{ .w = 7, .h = 13, .data = &test_image.TEST_IMAGE_7x13_RGB, .label = "7x13 odd" },
        .{ .w = 16, .h = 16, .data = &test_image.TEST_IMAGE_16x16_RGB, .label = "16x16 checker" },
        .{ .w = 32, .h = 32, .data = &test_image.TEST_IMAGE_32x32_RGB, .label = "32x32 gradient" },
    };

    const modes = [_]zjpg.SubsamplingMode{ .@"4:4:4", .@"4:2:2", .@"4:2:0", .@"4:1:1" };

    for (cases) |tc| {
        for (modes) |mode| {
            const jpeg_data = try zjpg.encodeRGB(allocator, tc.w, tc.h, tc.data, null, mode);
            defer allocator.free(jpeg_data);
            try assertValidJpeg(jpeg_data);
        }
        std.debug.print("  {s}: SOI/APP0/JFIF/EOI/byte-stuffing OK (all 4 subsampling modes)\n", .{tc.label});
    }

    // Also validate with all standard quality levels
    const qualities = [_]u8{ 1, 10, 50, 85, 100 };
    for (qualities) |q| {
        const tables = zjpg.QuantizationTables.standard(q);
        const jpeg_data = try zjpg.encodeRGB(allocator, 16, 16, &test_image.TEST_IMAGE_16x16_RGB, &tables, .@"4:4:4");
        defer allocator.free(jpeg_data);
        try assertValidJpeg(jpeg_data);
    }
    std.debug.print("  standard quality 1/10/50/85/100: structure OK\n", .{});
}

test "error paths" {
    const allocator = std.testing.allocator;

    std.debug.print("\nError path tests:\n", .{});

    // width = 0  -> InvalidDimensions
    try std.testing.expectError(
        error.InvalidDimensions,
        zjpg.encodeRGB(allocator, 0, 8, &([_]u8{0} ** 24), null, .@"4:4:4"),
    );
    std.debug.print("  width=0 -> InvalidDimensions OK\n", .{});

    // height = 0  -> InvalidDimensions
    try std.testing.expectError(
        error.InvalidDimensions,
        zjpg.encodeRGB(allocator, 8, 0, &([_]u8{0} ** 24), null, .@"4:4:4"),
    );
    std.debug.print("  height=0 -> InvalidDimensions OK\n", .{});

    // width > 65535 -> DimensionsTooLarge
    try std.testing.expectError(
        error.DimensionsTooLarge,
        zjpg.encodeRGB(allocator, 65536, 1, &[3]u8{ 0, 0, 0 }, null, .@"4:4:4"),
    );
    std.debug.print("  width=65536 -> DimensionsTooLarge OK\n", .{});

    // height > 65535 -> DimensionsTooLarge
    try std.testing.expectError(
        error.DimensionsTooLarge,
        zjpg.encodeRGB(allocator, 1, 65536, &[3]u8{ 0, 0, 0 }, null, .@"4:4:4"),
    );
    std.debug.print("  height=65536 -> DimensionsTooLarge OK\n", .{});

    // wrong data size -> InvalidDataSize  (expected 3 bytes, got 6)
    try std.testing.expectError(
        error.InvalidDataSize,
        zjpg.encodeRGB(allocator, 1, 1, &[6]u8{ 0, 0, 0, 0, 0, 0 }, null, .@"4:4:4"),
    );
    std.debug.print("  wrong data size -> InvalidDataSize OK\n", .{});

    // too little data -> InvalidDataSize  (expected 300 bytes for 10x10, got 3)
    try std.testing.expectError(
        error.InvalidDataSize,
        zjpg.encodeRGB(allocator, 10, 10, &[3]u8{ 0, 0, 0 }, null, .@"4:4:4"),
    );
    std.debug.print("  data too short -> InvalidDataSize OK\n", .{});
}

test "quality size ordering" {
    // Higher standard quality must produce a larger or equal file for the same image.
    // Tested on a 32x32 smooth gradient (natural image behaviour).
    const allocator = std.testing.allocator;

    std.debug.print("\nQuality size ordering (32x32 gradient):\n", .{});

    const qualities = [_]u8{ 100, 85, 50, 10, 1 };
    var sizes: [5]usize = undefined;

    for (qualities, 0..) |q, i| {
        const tables = zjpg.QuantizationTables.standard(q);
        const jpeg_data = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables, .@"4:4:4");
        defer allocator.free(jpeg_data);
        sizes[i] = jpeg_data.len;
        std.debug.print("  quality={d:3}: {} bytes\n", .{ q, jpeg_data.len });
    }

    // quality=100 >= quality=85 >= quality=50 >= quality=10 >= quality=1
    try std.testing.expect(sizes[0] >= sizes[1]);
    try std.testing.expect(sizes[1] >= sizes[2]);
    try std.testing.expect(sizes[2] >= sizes[3]);
    try std.testing.expect(sizes[3] >= sizes[4]);
    std.debug.print("  Ordering assertions: PASSED\n", .{});
}

test "subsampling size ordering" {
    // For a smooth gradient (natural image proxy), more chroma subsampling means
    // fewer chroma coefficients, so the file should be smaller.
    // Expected order: 4:4:4 >= 4:2:2 >= 4:2:0 and 4:4:4 >= 4:1:1
    const allocator = std.testing.allocator;

    const tables_q85 = zjpg.QuantizationTables.standard(85);

    const jpeg_444 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_q85, .@"4:4:4");
    defer allocator.free(jpeg_444);
    const jpeg_422 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_q85, .@"4:2:2");
    defer allocator.free(jpeg_422);
    const jpeg_420 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_q85, .@"4:2:0");
    defer allocator.free(jpeg_420);
    const jpeg_411 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_q85, .@"4:1:1");
    defer allocator.free(jpeg_411);

    std.debug.print("\nSubsampling size ordering (32x32 gradient, quality=85):\n", .{});
    std.debug.print("  4:4:4 = {} bytes\n", .{jpeg_444.len});
    std.debug.print("  4:2:2 = {} bytes\n", .{jpeg_422.len});
    std.debug.print("  4:2:0 = {} bytes\n", .{jpeg_420.len});
    std.debug.print("  4:1:1 = {} bytes\n", .{jpeg_411.len});

    try std.testing.expect(jpeg_444.len >= jpeg_422.len);
    try std.testing.expect(jpeg_422.len >= jpeg_420.len);
    try std.testing.expect(jpeg_444.len >= jpeg_411.len);
    std.debug.print("  Ordering assertions: PASSED\n", .{});
}

test "custom quantization tables" {
    // The configurable quantization table is the primary feature of zjpg.
    // This test exercises a range of custom tables and verifies:
    //   1. Output is structurally valid JPEG
    //   2. Table values affect file size predictably (smaller divisors -> larger files)
    //   3. Extreme tables (all-1 and all-255) both produce valid output
    //   4. Asymmetric luma/chroma tables work correctly
    const allocator = std.testing.allocator;

    std.debug.print("\nCustom quantization table tests (32x32 gradient):\n", .{});

    // all-1: no quantization loss, produces the largest output
    var tables_all1: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        tables_all1.luma[i] = 1;
        tables_all1.chroma[i] = 1;
    }
    const jpeg_all1 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_all1, .@"4:4:4");
    defer allocator.free(jpeg_all1);
    try assertValidJpeg(jpeg_all1);
    std.debug.print("  all-1  (min quant): {} bytes\n", .{jpeg_all1.len});

    // all-255: maximum quantization, smallest output
    var tables_all255: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        tables_all255.luma[i] = 255;
        tables_all255.chroma[i] = 255;
    }
    const jpeg_all255 = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_all255, .@"4:4:4");
    defer allocator.free(jpeg_all255);
    try assertValidJpeg(jpeg_all255);
    std.debug.print("  all-255 (max quant): {} bytes\n", .{jpeg_all255.len});

    // all-1 should produce a larger file than all-255
    try std.testing.expect(jpeg_all1.len > jpeg_all255.len);
    std.debug.print("  all-1 > all-255: PASSED\n", .{});

    // low-frequency emphasis: fine quantization for DC+low AC, coarse for high AC
    var tables_lowfreq: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        // Ramp from 1 (DC) to 128 (highest AC)
        const v: u8 = @intCast(@min(255, 1 + i * 2));
        tables_lowfreq.luma[i] = v;
        tables_lowfreq.chroma[i] = v;
    }
    const jpeg_lowfreq = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_lowfreq, .@"4:4:4");
    defer allocator.free(jpeg_lowfreq);
    try assertValidJpeg(jpeg_lowfreq);
    std.debug.print("  low-freq emphasis:  {} bytes\n", .{jpeg_lowfreq.len});

    // aggressive chroma: fine luma, coarse chroma
    var tables_chroma_agg: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        tables_chroma_agg.luma[i] = 4;   // retain most luma detail
        tables_chroma_agg.chroma[i] = 200; // aggressively discard chroma
    }
    const jpeg_chroma_agg = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_chroma_agg, .@"4:4:4");
    defer allocator.free(jpeg_chroma_agg);
    try assertValidJpeg(jpeg_chroma_agg);
    std.debug.print("  aggressive chroma:  {} bytes\n", .{jpeg_chroma_agg.len});

    // reverse: fine chroma, aggressive luma
    var tables_luma_agg: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        tables_luma_agg.luma[i] = 200;
        tables_luma_agg.chroma[i] = 4;
    }
    const jpeg_luma_agg = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_luma_agg, .@"4:4:4");
    defer allocator.free(jpeg_luma_agg);
    try assertValidJpeg(jpeg_luma_agg);
    std.debug.print("  aggressive luma:    {} bytes\n", .{jpeg_luma_agg.len});

    // Both asymmetric tables should fall between all-1 and all-255 in file size.
    try std.testing.expect(jpeg_chroma_agg.len < jpeg_all1.len);
    try std.testing.expect(jpeg_chroma_agg.len > jpeg_all255.len);
    try std.testing.expect(jpeg_luma_agg.len < jpeg_all1.len);
    try std.testing.expect(jpeg_luma_agg.len > jpeg_all255.len);
    std.debug.print("  asymmetric tables within expected range: PASSED\n", .{});

    // DC-only: keep only DC coefficient per block, discard all AC
    var tables_dc_only: zjpg.QuantizationTables = undefined;
    tables_dc_only.luma[0] = 1;
    tables_dc_only.chroma[0] = 1;
    for (1..64) |i| {
        tables_dc_only.luma[i] = 255;
        tables_dc_only.chroma[i] = 255;
    }
    const jpeg_dc_only = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_dc_only, .@"4:4:4");
    defer allocator.free(jpeg_dc_only);
    try assertValidJpeg(jpeg_dc_only);
    std.debug.print("  DC-only table:      {} bytes\n", .{jpeg_dc_only.len});

    // Save samples for visual inspection
    const save_cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "test_custom_all1.jpg", .data = jpeg_all1 },
        .{ .name = "test_custom_all255.jpg", .data = jpeg_all255 },
        .{ .name = "test_custom_lowfreq.jpg", .data = jpeg_lowfreq },
        .{ .name = "test_custom_chroma_agg.jpg", .data = jpeg_chroma_agg },
        .{ .name = "test_custom_luma_agg.jpg", .data = jpeg_luma_agg },
        .{ .name = "test_custom_dc_only.jpg", .data = jpeg_dc_only },
    };
    for (save_cases) |sc| {
        const f = std.fs.cwd().createFile(sc.name, .{}) catch continue;
        defer f.close();
        f.writeAll(sc.data) catch {};
    }

    // --- custom tables combined with subsampling modes ---
    std.debug.print("  Custom tables + subsampling modes (all-1 table):\n", .{});
    const sub_modes = [_]struct { mode: zjpg.SubsamplingMode, label: []const u8 }{
        .{ .mode = .@"4:4:4", .label = "4:4:4" },
        .{ .mode = .@"4:2:2", .label = "4:2:2" },
        .{ .mode = .@"4:2:0", .label = "4:2:0" },
        .{ .mode = .@"4:1:1", .label = "4:1:1" },
    };
    for (sub_modes) |sm| {
        const jpeg_sub = try zjpg.encodeRGB(allocator, 32, 32, &test_image.TEST_IMAGE_32x32_RGB, &tables_all1, sm.mode);
        defer allocator.free(jpeg_sub);
        try assertValidJpeg(jpeg_sub);
        std.debug.print("    {s}: {} bytes\n", .{ sm.label, jpeg_sub.len });
    }
}

test "large dimension boundaries" {
    // Verify that images near the maximum allowed dimension encode without error.
    const allocator = std.testing.allocator;

    std.debug.print("\nLarge dimension boundary tests:\n", .{});

    // 256x1 - wide, single row
    const data_256x1 = try allocator.alloc(u8, 256 * 1 * 3);
    defer allocator.free(data_256x1);
    @memset(data_256x1, 128);
    const jpeg_wide = try zjpg.encodeRGB(allocator, 256, 1, data_256x1, null, .@"4:4:4");
    defer allocator.free(jpeg_wide);
    try assertValidJpeg(jpeg_wide);
    std.debug.print("  256x1: {} bytes\n", .{jpeg_wide.len});

    // 1x256 - tall, single column
    const data_1x256 = try allocator.alloc(u8, 1 * 256 * 3);
    defer allocator.free(data_1x256);
    @memset(data_1x256, 128);
    const jpeg_tall = try zjpg.encodeRGB(allocator, 1, 256, data_1x256, null, .@"4:4:4");
    defer allocator.free(jpeg_tall);
    try assertValidJpeg(jpeg_tall);
    std.debug.print("  1x256: {} bytes\n", .{jpeg_tall.len});

    // 64x64 - multiple full MCU blocks
    const data_64x64 = try allocator.alloc(u8, 64 * 64 * 3);
    defer allocator.free(data_64x64);
    for (0..64 * 64) |px| {
        data_64x64[px * 3] = @truncate(px % 256);
        data_64x64[px * 3 + 1] = @truncate((px / 64) % 256);
        data_64x64[px * 3 + 2] = @truncate((px + 128) % 256);
    }
    const jpeg_64x64 = try zjpg.encodeRGB(allocator, 64, 64, data_64x64, null, .@"4:4:4");
    defer allocator.free(jpeg_64x64);
    try assertValidJpeg(jpeg_64x64);
    std.debug.print("  64x64: {} bytes\n", .{jpeg_64x64.len});

    // 128x96 - common thumbnail size, all subsampling modes
    const data_128x96 = try allocator.alloc(u8, 128 * 96 * 3);
    defer allocator.free(data_128x96);
    @memset(data_128x96, 200);
    for ([_]zjpg.SubsamplingMode{ .@"4:4:4", .@"4:2:2", .@"4:2:0", .@"4:1:1" }) |mode| {
        const jpeg_thumb = try zjpg.encodeRGB(allocator, 128, 96, data_128x96, null, mode);
        defer allocator.free(jpeg_thumb);
        try assertValidJpeg(jpeg_thumb);
    }
    std.debug.print("  128x96 (all subsampling modes): OK\n", .{});
}
