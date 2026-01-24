const std = @import("std");
const writers = @import("writers.zig");
const constants = @import("constants.zig");

pub const SubsamplingMode = enum {
    @"4:4:4", // No subsampling (8x8 MCU)
    @"4:2:2", // Horizontal 2:1 subsampling (16x8 MCU)
    @"4:2:0", // Horizontal and vertical 2:1 subsampling (16x16 MCU)
    @"4:1:1", // Horizontal 4:1 subsampling (32x8 MCU)
};

pub const QuantizationTables = struct {
    luma: [64]u8,
    chroma: [64]u8,

    pub fn default() QuantizationTables {
        return standard(100);
    }

    // Generate quantization tables scaled by quality factor (1-100)
    // Based on Annex K of ITU-T T.81 (JPEG standard)
    pub fn standard(quality: u8) QuantizationTables {
        const q = std.math.clamp(quality, 1, 100);

        const base_luma = [64]u8{
            16, 11, 10, 16, 24,  40,  51,  61,
            12, 12, 14, 19, 26,  58,  60,  55,
            14, 13, 16, 24, 40,  57,  69,  56,
            14, 17, 22, 29, 51,  87,  80,  62,
            18, 22, 37, 56, 68,  109, 103, 77,
            24, 35, 55, 64, 81,  104, 113, 92,
            49, 64, 78, 87, 103, 121, 120, 101,
            72, 92, 95, 98, 112, 100, 103, 99,
        };

        const base_chroma = [64]u8{
            17, 18, 24, 47, 99, 99, 99, 99,
            18, 21, 26, 66, 99, 99, 99, 99,
            24, 26, 56, 99, 99, 99, 99, 99,
            47, 66, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99,
        };

        const scale = if (q < 50)
            5000 / @as(u32, q)
        else
            200 - @as(u32, q) * 2;

        var result: QuantizationTables = undefined;

        for (0..64) |i| {
            const luma_val = (@as(u32, base_luma[i]) * scale + 50) / 100;
            const chroma_val = (@as(u32, base_chroma[i]) * scale + 50) / 100;

            result.luma[i] = @intCast(std.math.clamp(luma_val, 1, 255));
            result.chroma[i] = @intCast(std.math.clamp(chroma_val, 1, 255));
        }

        return result;
    }
};

pub const JpegEncoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JpegEncoder {
        return JpegEncoder{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JpegEncoder) void {
        _ = self;
    }

    pub fn encode(
        self: *JpegEncoder,
        width: u32,
        height: u32,
        rgb_data: []const u8,
        quant_tables: ?*const QuantizationTables,
        subsampling: SubsamplingMode,
    ) ![]u8 {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        if (width > 65535 or height > 65535) return error.DimensionsTooLarge;

        const expected_size = width * height * 3;
        if (rgb_data.len != expected_size) return error.InvalidDataSize;

        const tables = quant_tables orelse &QuantizationTables.default();

        var writerAlloc = std.io.Writer.Allocating.init(self.allocator);
        errdefer writerAlloc.deinit();

        try writers.writeJFIFHeader(&writerAlloc.writer);
        try writers.writeDQT(&writerAlloc.writer, 0, &tables.luma);
        try writers.writeDQT(&writerAlloc.writer, 1, &tables.chroma);
        try writers.writeSOF0(&writerAlloc.writer, @intCast(width), @intCast(height), subsampling);
        try writers.writeDHT(&writerAlloc.writer, 0, 0, &constants.DC_LUMINANCE_BITS, &constants.DC_LUMINANCE_VALUES);
        try writers.writeDHT(&writerAlloc.writer, 1, 0, &constants.AC_LUMINANCE_BITS, &constants.AC_LUMINANCE_VALUES);
        try writers.writeDHT(&writerAlloc.writer, 0, 1, &constants.DC_CHROMINANCE_BITS, &constants.DC_CHROMINANCE_VALUES);
        try writers.writeDHT(&writerAlloc.writer, 1, 1, &constants.AC_CHROMINANCE_BITS, &constants.AC_CHROMINANCE_VALUES);
        try writers.writeSOS(&writerAlloc.writer);

        try writers.encodeColorImage(&writerAlloc.writer, width, height, rgb_data, &tables.luma, &tables.chroma, subsampling);

        try writers.writeBE16(&writerAlloc.writer, constants.JPEG_EOI);

        var buffer = writerAlloc.toArrayList();
        return buffer.toOwnedSlice(self.allocator);
    }
};
