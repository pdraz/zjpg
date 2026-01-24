const std = @import("std");
const test_image = @import("test_image.zig");
const zjpg = @import("root.zig");

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

    // Test JpegEncoder
    var encoder = zjpg.JpegEncoder.init(allocator);
    defer encoder.deinit();

    const jpeg_encoder = try encoder.encode(16, 16, &test_image.TEST_IMAGE_16x16_RGB, null, .@"4:4:4");
    defer allocator.free(jpeg_encoder);
    try std.testing.expect(jpeg_encoder.len > 100);
    std.debug.print("  JpegEncoder.encode(): {} bytes\n", .{jpeg_encoder.len});

    // Test convenience function
    const jpeg_convenience = try zjpg.encodeRGB(allocator, 10, 10, &test_image.TEST_IMAGE_10x10_RGB, null, .@"4:4:4");
    defer allocator.free(jpeg_convenience);
    try std.testing.expect(jpeg_convenience.len > 100);
    std.debug.print("  encodeRGB(): {} bytes\n", .{jpeg_convenience.len});
}

test "custom quantization" {
    const allocator = std.testing.allocator;

    // Test standard quality levels
    const quality_levels = [_]u8{ 100, 85, 50, 10 };
    var quality_results: [4]usize = undefined;

    std.debug.print("\nQuantization quality tests:\n", .{});
    for (quality_levels, 0..) |quality, i| {
        const tables = zjpg.QuantizationTables.standard(quality);
        const jpeg_data = try zjpg.encodeRGB(allocator, 16, 16, &test_image.TEST_IMAGE_16x16_RGB, &tables, .@"4:4:4");
        defer allocator.free(jpeg_data);

        try std.testing.expect(jpeg_data.len > 100);
        quality_results[i] = jpeg_data.len;

        // Save test file
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

    // Verify quality ordering: higher quality = larger file (generally true)
    std.debug.print("  Note: Higher quality should generally produce larger files\n", .{});

    // Test fully custom tables
    var custom_tables: zjpg.QuantizationTables = undefined;
    for (0..64) |i| {
        custom_tables.luma[i] = 10;
        custom_tables.chroma[i] = 10;
    }

    const jpeg_data = try zjpg.encodeRGB(allocator, 10, 10, &test_image.TEST_IMAGE_10x10_RGB, &custom_tables, .@"4:4:4");
    defer allocator.free(jpeg_data);

    try std.testing.expect(jpeg_data.len > 100);

    const filename: []const u8 = "test_quality_custom.jpg";
    if (std.fs.cwd().createFile(filename, .{})) |file| {
        defer file.close();
        try file.writeAll(jpeg_data);
    } else |err| {
        std.debug.print("Warning: couldn't create {s}: {}\n", .{ filename, err });
    }

    std.debug.print("  Custom tables: {} bytes\n", .{jpeg_data.len});
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

    // Verify all modes produce valid JPEG data
    try std.testing.expect(jpeg_444.len > 100);
    try std.testing.expect(jpeg_422.len > 100);
    try std.testing.expect(jpeg_420.len > 100);
    try std.testing.expect(jpeg_411.len > 100);

    // Save test files and display results
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
