const std = @import("std");

const jpeg_mod = @import("jpeg.zig");
pub const JpegEncoder = jpeg_mod.JpegEncoder;
pub const QuantizationTables = jpeg_mod.QuantizationTables;
pub const SubsamplingMode = jpeg_mod.SubsamplingMode;

pub fn encodeRGB(allocator: std.mem.Allocator, width: u32, height: u32, rgb_data: []const u8, quant_tables: ?*const QuantizationTables, subsampling: SubsamplingMode) ![]u8 {
    var encoder = JpegEncoder.init(allocator);
    defer encoder.deinit();
    return encoder.encode(width, height, rgb_data, quant_tables, subsampling);
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test.zig");
}
