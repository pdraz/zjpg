const std = @import("std");

pub const HuffmanCode = struct { code: u32, bits: u8 };

pub const HuffmanTable = struct {
    codes: [256]HuffmanCode = undefined,

    pub fn init() HuffmanTable {
        return .{ .codes = [_]HuffmanCode{.{ .code = 0, .bits = 0 }} ** 256 };
    }

    // Construct Huffman table from JPEG spec format
    // BITS array contains count of codes for each bit length (1-16)
    // VALUES array contains the symbols in ascending code order
    pub fn buildFromSpec(bits: []const u8, values: []const u8) HuffmanTable {
        var table = HuffmanTable.init();
        var code: u32 = 0;
        var value_idx: usize = 0;

        for (bits, 0..) |count, length| {
            const actual_length = @as(u8, @intCast(length + 1));

            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (value_idx >= values.len) break;

                const symbol = values[value_idx];
                table.codes[symbol] = .{
                    .code = code,
                    .bits = actual_length,
                };

                code += 1;
                value_idx += 1;
            }

            code <<= 1;
        }

        return table;
    }
};

// Compile-time generation of standard JPEG Huffman tables
pub const DC_LUMA_TABLE = HuffmanTable.buildFromSpec(&@import("constants.zig").DC_LUMINANCE_BITS, &@import("constants.zig").DC_LUMINANCE_VALUES);
pub const DC_CHROMA_TABLE = HuffmanTable.buildFromSpec(&@import("constants.zig").DC_CHROMINANCE_BITS, &@import("constants.zig").DC_CHROMINANCE_VALUES);
pub const AC_LUMA_TABLE = HuffmanTable.buildFromSpec(&@import("constants.zig").AC_LUMINANCE_BITS, &@import("constants.zig").AC_LUMINANCE_VALUES);
pub const AC_CHROMA_TABLE = HuffmanTable.buildFromSpec(&@import("constants.zig").AC_CHROMINANCE_BITS, &@import("constants.zig").AC_CHROMINANCE_VALUES);
