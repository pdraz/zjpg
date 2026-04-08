const std = @import("std");
const constants = @import("constants.zig");
const bitwriter = @import("bitwriter.zig");
const huffman = @import("huffman.zig");
const jpeg = @import("jpeg.zig");

pub fn writeBE16(writer: *std.io.Writer, value: u16) !void {
    try writer.writeByte(@truncate(value >> 8));
    try writer.writeByte(@truncate(value));
}

pub fn writeJFIFHeader(writer: *std.io.Writer) !void {
    try writeBE16(writer, constants.JPEG_SOI);

    try writeBE16(writer, constants.JPEG_APP0);
    try writeBE16(writer, 16); // APP0 segment length
    try writer.writeAll("JFIF\x00");
    try writer.writeByte(1); // Major version
    try writer.writeByte(1); // Minor version
    try writer.writeByte(0); // Density units (0 = no units, aspect ratio only)
    try writeBE16(writer, 1); // X density
    try writeBE16(writer, 1); // Y density
    try writer.writeByte(0); // Thumbnail width
    try writer.writeByte(0); // Thumbnail height
}

pub fn writeDQT(writer: *std.io.Writer, table_id: u8, table: *const [64]u8) !void {
    try writeBE16(writer, constants.JPEG_DQT);
    try writeBE16(writer, 67); // Length: 2 (length) + 1 (precision/id) + 64 (table)
    try writer.writeByte(table_id);

    for (constants.ZIGZAG_ORDER) |idx| {
        try writer.writeByte(table[idx]);
    }
}

pub fn writeDHT(writer: *std.io.Writer, table_class: u8, table_id: u8, bits: []const u8, values: []const u8) !void {
    try writeBE16(writer, constants.JPEG_DHT);
    try writeBE16(writer, @truncate(3 + bits.len + values.len));
    try writer.writeByte((table_class << 4) | table_id);
    try writer.writeAll(bits);
    try writer.writeAll(values);
}

pub fn writeSOF0(writer: *std.io.Writer, width: u16, height: u16, subsampling: jpeg.SubsamplingMode) !void {
    try writeBE16(writer, constants.JPEG_SOF0);
    try writeBE16(writer, 17); // Length: 8 + 3*components
    try writer.writeByte(8); // Bits per sample
    try writeBE16(writer, height);
    try writeBE16(writer, width);
    try writer.writeByte(3); // Number of components (Y, Cb, Cr)

    // Sampling factors encoded as (H << 4) | V where H = horizontal, V = vertical
    const y_sampling: u8 = switch (subsampling) {
        .@"4:4:4" => 0x11, // 1x1
        .@"4:2:2" => 0x21, // 2x1
        .@"4:2:0" => 0x22, // 2x2
        .@"4:1:1" => 0x41, // 4x1
    };
    const chroma_sampling: u8 = 0x11; // Chroma always 1x1

    try writer.writeByte(1); // Component ID: Y
    try writer.writeByte(y_sampling);
    try writer.writeByte(0); // Quantization table 0

    try writer.writeByte(2); // Component ID: Cb
    try writer.writeByte(chroma_sampling);
    try writer.writeByte(1); // Quantization table 1

    try writer.writeByte(3); // Component ID: Cr
    try writer.writeByte(chroma_sampling);
    try writer.writeByte(1); // Quantization table 1
}

pub fn writeSOS(writer: *std.io.Writer) !void {
    try writeBE16(writer, constants.JPEG_SOS);
    try writeBE16(writer, 12); // Length: 6 + 2*components
    try writer.writeByte(3); // Number of components

    try writer.writeByte(1); // Component ID: Y
    try writer.writeByte(0x00); // DC table 0, AC table 0

    try writer.writeByte(2); // Component ID: Cb
    try writer.writeByte(0x11); // DC table 1, AC table 1

    try writer.writeByte(3); // Component ID: Cr
    try writer.writeByte(0x11); // DC table 1, AC table 1

    try writer.writeByte(0); // Start of spectral selection
    try writer.writeByte(63); // End of spectral selection
    try writer.writeByte(0); // Successive approximation
}

const McuConfig = struct {
    mcu_width: u32,
    mcu_height: u32,
    y_blocks: []const [2]u32,
    chroma_h_factor: u32,
    chroma_v_factor: u32,
};

fn getMcuConfig(subsampling: jpeg.SubsamplingMode) McuConfig {
    return switch (subsampling) {
        .@"4:4:4" => .{
            .mcu_width = 8,
            .mcu_height = 8,
            .y_blocks = &[_][2]u32{.{ 0, 0 }},
            .chroma_h_factor = 1,
            .chroma_v_factor = 1,
        },
        .@"4:2:2" => .{
            .mcu_width = 16,
            .mcu_height = 8,
            .y_blocks = &[_][2]u32{
                .{ 0, 0 },
                .{ 1, 0 },
            },
            .chroma_h_factor = 2,
            .chroma_v_factor = 1,
        },
        .@"4:2:0" => .{
            .mcu_width = 16,
            .mcu_height = 16,
            .y_blocks = &[_][2]u32{
                .{ 0, 0 },
                .{ 1, 0 },
                .{ 0, 1 },
                .{ 1, 1 },
            },
            .chroma_h_factor = 2,
            .chroma_v_factor = 2,
        },
        .@"4:1:1" => .{
            .mcu_width = 32,
            .mcu_height = 8,
            .y_blocks = &[_][2]u32{
                .{ 0, 0 },
                .{ 1, 0 },
                .{ 2, 0 },
                .{ 3, 0 },
            },
            .chroma_h_factor = 4,
            .chroma_v_factor = 1,
        },
    };
}

pub fn encodeColorImage(writer: *std.io.Writer, width: u32, height: u32, rgb_pixels: []const u8, luma_table: *const [64]u8, chroma_table: *const [64]u8, subsampling: jpeg.SubsamplingMode) !void {
    const config = getMcuConfig(subsampling);
    const mcus_x = (width + config.mcu_width - 1) / config.mcu_width;
    const mcus_y = (height + config.mcu_height - 1) / config.mcu_height;

    var bit_writer = bitwriter.BitWriter.init(writer);
    var prev_dc_y: i16 = 0;
    var prev_dc_cb: i16 = 0;
    var prev_dc_cr: i16 = 0;

    var mcu_y: u32 = 0;
    while (mcu_y < mcus_y) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcus_x) : (mcu_x += 1) {
            for (config.y_blocks) |block_offset| {
                const block_x = mcu_x * (config.mcu_width / 8) + block_offset[0];
                const block_y = mcu_y * (config.mcu_height / 8) + block_offset[1];

                var y_block: [64]u8 = undefined;
                extractComponentBlock(rgb_pixels, width, height, block_x, block_y, 0, &y_block);

                var y_quantized: [64]i16 = undefined;
                dct8x8_quantize(&y_block, luma_table, &y_quantized);

                const y_dc_diff = y_quantized[0] - prev_dc_y;
                try encodeDCCoefficientComponent(&bit_writer, y_dc_diff, false);
                prev_dc_y = y_quantized[0];
                try encodeACCoefficientsComponent(&bit_writer, y_quantized[1..], false);
            }

            var cb_block: [64]u8 = undefined;
            extractChromaBlockSubsampled(rgb_pixels, width, height, mcu_x, mcu_y, 1, config.chroma_h_factor, config.chroma_v_factor, config.mcu_width, config.mcu_height, &cb_block);

            var cb_quantized: [64]i16 = undefined;
            dct8x8_quantize(&cb_block, chroma_table, &cb_quantized);

            const cb_dc_diff = cb_quantized[0] - prev_dc_cb;
            try encodeDCCoefficientComponent(&bit_writer, cb_dc_diff, true);
            prev_dc_cb = cb_quantized[0];
            try encodeACCoefficientsComponent(&bit_writer, cb_quantized[1..], true);

            var cr_block: [64]u8 = undefined;
            extractChromaBlockSubsampled(rgb_pixels, width, height, mcu_x, mcu_y, 2, config.chroma_h_factor, config.chroma_v_factor, config.mcu_width, config.mcu_height, &cr_block);

            var cr_quantized: [64]i16 = undefined;
            dct8x8_quantize(&cr_block, chroma_table, &cr_quantized);

            const cr_dc_diff = cr_quantized[0] - prev_dc_cr;
            try encodeDCCoefficientComponent(&bit_writer, cr_dc_diff, true);
            prev_dc_cr = cr_quantized[0];
            try encodeACCoefficientsComponent(&bit_writer, cr_quantized[1..], true);
        }
    }

    try bit_writer.flush();
}


// Get the magnitude (number of bits needed) to represent a coefficient
// This is log2(abs(value)) + 1, or equivalently the position of the MSB
fn getMagnitude(value: i16) u8 {
    if (value == 0) return 0;
    const abs_val: u16 = @intCast(@abs(value));
    return @as(u8, 16 - @clz(abs_val));
}

// Encode coefficient value in JPEG's variable-length integer format
// Positive values are stored as-is, negative values use ones' complement
fn getAdditionalBits(value: i16, magnitude: u8) u32 {
    if (magnitude == 0) return 0;

    if (value > 0) {
        return @intCast(value);
    } else {
        const power_of_2: i32 = @as(i32, 1) << @intCast(magnitude);
        const result = @as(i32, value) + power_of_2 - 1;
        return @intCast(result);
    }
}

fn encodeDCCoefficientComponent(
    bit_writer: *bitwriter.BitWriter,
    dc_value: i16,
    is_chroma: bool,
) !void {
    const magnitude = getMagnitude(dc_value);

    const huffman_entry = if (is_chroma)
        huffman.DC_CHROMA_TABLE.codes[magnitude]
    else
        huffman.DC_LUMA_TABLE.codes[magnitude];

    try bit_writer.writeBits(huffman_entry.code, huffman_entry.bits);

    if (magnitude > 0) {
        const additional = getAdditionalBits(dc_value, magnitude);
        try bit_writer.writeBits(additional, magnitude);
    }
}

fn encodeACCoefficientsComponent(
    bit_writer: *bitwriter.BitWriter,
    ac_coeffs: []const i16,
    is_chroma: bool,
) !void {
    var zero_run: u8 = 0;
    var last_nonzero_idx: i32 = -1;

    for (ac_coeffs, 0..) |coeff, i| {
        if (coeff != 0) {
            last_nonzero_idx = @intCast(i);
        }
    }

    if (last_nonzero_idx == -1) {
        const table = if (is_chroma) huffman.AC_CHROMA_TABLE else huffman.AC_LUMA_TABLE;
        const eob_entry = table.codes[0x00];
        try bit_writer.writeBits(eob_entry.code, eob_entry.bits);
        return;
    }

    const table = if (is_chroma) huffman.AC_CHROMA_TABLE else huffman.AC_LUMA_TABLE;

    for (ac_coeffs[0..@intCast(last_nonzero_idx + 1)]) |coeff| {
        if (coeff == 0) {
            zero_run += 1;

            if (zero_run == 16) {
                const zrl_entry = table.codes[0xF0];
                try bit_writer.writeBits(zrl_entry.code, zrl_entry.bits);
                zero_run = 0;
            }
        } else {
            const magnitude = getMagnitude(coeff);
            const rs_byte = (zero_run << 4) | magnitude;

            const huffman_entry = table.codes[rs_byte];
            try bit_writer.writeBits(huffman_entry.code, huffman_entry.bits);

            const additional = getAdditionalBits(coeff, magnitude);
            try bit_writer.writeBits(additional, magnitude);

            zero_run = 0;
        }
    }

    if (last_nonzero_idx < 62) {
        const eob_entry = table.codes[0x00];
        try bit_writer.writeBits(eob_entry.code, eob_entry.bits);
    }
}

// AAN (Arai-Agui-Nakajima, 1988) fast DCT + quantization.
// The butterfly produces output scaled by 8*aanscale[u]*aanscale[v], which
// is absorbed into the quantization divisor so no separate descaling step
// is needed. Reference: libjpeg jfdctflt.c (IJG, public domain).

const AAN_SCALE = [8]f32{
    1.0, 1.387039845, 1.306562965, 1.175875602,
    1.0, 0.785694958, 0.541196100, 0.275899379,
};

// In-place 1-D AAN 8-point DCT on an array of 8 floats.
fn aan1d(x: *[8]f32) void {
    // Stage 1 – pairwise butterflies
    const s0 = x[0] + x[7];  const s7 = x[0] - x[7];
    const s1 = x[1] + x[6];  const s6 = x[1] - x[6];
    const s2 = x[2] + x[5];  const s5 = x[2] - x[5];
    const s3 = x[3] + x[4];  const s4 = x[3] - x[4];

    // Even part
    const e0 = s0 + s3;  const e3 = s0 - s3;
    const e1 = s1 + s2;  const e2 = s1 - s2;
    x[0] = e0 + e1;
    x[4] = e0 - e1;
    const z1 = (e2 + e3) * 0.707106781; // cos(π/4)
    x[2] = e3 + z1;
    x[6] = e3 - z1;

    // Odd part
    const o0 = s4 + s5;
    const o1 = s5 + s6;
    const o2 = s6 + s7;
    const z5 = (o0 - o2) * 0.382683433; // cos(3π/8)
    const z2 = 0.541196100 * o0 + z5;   // cos(3π/8) rotator
    const z4 = 1.306562965 * o2 + z5;   // cos(π/8)  rotator
    const z3 = o1 * 0.707106781;
    const z6 = s7 + z3;  const z7 = s7 - z3;
    x[5] = z7 + z2;
    x[3] = z7 - z2;
    x[1] = z6 + z4;
    x[7] = z6 - z4;
}

// 2-D AAN DCT + quantization in one pass.
// output[i] = quantized coefficient at zigzag scan position i.
pub fn dct8x8_quantize(input: *const [64]u8, quant: *const [64]u8, output: *[64]i16) void {
    var work: [64]f32 = undefined;

    // Level-shift
    for (0..64) |i| work[i] = @as(f32, @floatFromInt(input[i])) - 128.0;

    // Row transforms
    for (0..8) |row| {
        var r: [8]f32 = work[row * 8 ..][0..8].*;
        aan1d(&r);
        work[row * 8 ..][0..8].* = r;
    }

    // Column transforms
    for (0..8) |col| {
        var c: [8]f32 = undefined;
        for (0..8) |row| c[row] = work[row * 8 + col];
        aan1d(&c);
        for (0..8) |row| work[row * 8 + col] = c[row];
    }

    // Quantize with AAN de-scaling, output in zigzag order
    for (0..64) |scan| {
        const nat: usize = constants.ZIGZAG_ORDER[scan];
        const u: usize   = nat % 8;
        const v: usize   = nat / 8;
        // Divisor = quant_value * 8 * aanscale[u] * aanscale[v]
        const divisor = @as(f32, @floatFromInt(quant[nat])) * 8.0 * AAN_SCALE[u] * AAN_SCALE[v];
        const coeff   = @round(work[nat] / divisor);
        output[scan]  = @intFromFloat(@max(-32768.0, @min(32767.0, coeff)));
    }
}

// Convert RGB to YCbCr using ITU-R BT.601 coefficients
pub fn rgbToYCbCr(r: u8, g: u8, b: u8) struct { y: u8, cb: u8, cr: u8 } {
    const rf = @as(f32, @floatFromInt(r));
    const gf = @as(f32, @floatFromInt(g));
    const bf = @as(f32, @floatFromInt(b));

    const y = 0.299 * rf + 0.587 * gf + 0.114 * bf;
    const cb = 128.0 + (-0.168736 * rf - 0.331264 * gf + 0.5 * bf);
    const cr = 128.0 + (0.5 * rf - 0.418688 * gf - 0.081312 * bf);

    return .{
        .y = @intFromFloat(@round(@max(0.0, @min(255.0, y)))),
        .cb = @intFromFloat(@round(@max(0.0, @min(255.0, cb)))),
        .cr = @intFromFloat(@round(@max(0.0, @min(255.0, cr)))),
    };
}

pub fn extractComponentBlock(
    rgb_pixels: []const u8,
    width: u32,
    height: u32,
    block_x: u32,
    block_y: u32,
    component: u8,
    block: *[64]u8,
) void {
    const start_y = block_y * 8;
    const start_x = block_x * 8;

    for (0..8) |y| {
        for (0..8) |x| {
            const pixel_y = start_y + y;
            const pixel_x = start_x + x;

            var pixel_value: u8 = 0;

            if (pixel_y < height and pixel_x < width) {
                const pixel_idx = (pixel_y * width + pixel_x) * 3;
                const r = rgb_pixels[pixel_idx];
                const g = rgb_pixels[pixel_idx + 1];
                const b = rgb_pixels[pixel_idx + 2];

                const ycbcr = rgbToYCbCr(r, g, b);
                pixel_value = switch (component) {
                    0 => ycbcr.y,
                    1 => ycbcr.cb,
                    2 => ycbcr.cr,
                    else => unreachable,
                };
            } else {
                const clamp_y = @min(pixel_y, height - 1);
                const clamp_x = @min(pixel_x, width - 1);
                const pixel_idx = (clamp_y * width + clamp_x) * 3;
                const r = rgb_pixels[pixel_idx];
                const g = rgb_pixels[pixel_idx + 1];
                const b = rgb_pixels[pixel_idx + 2];

                const ycbcr = rgbToYCbCr(r, g, b);
                pixel_value = switch (component) {
                    0 => ycbcr.y,
                    1 => ycbcr.cb,
                    2 => ycbcr.cr,
                    else => unreachable,
                };
            }

            block[y * 8 + x] = pixel_value;
        }
    }
}

fn extractChromaBlockSubsampled(
    rgb_pixels: []const u8,
    width: u32,
    height: u32,
    mcu_x: u32,
    mcu_y: u32,
    component: u8,
    h_factor: u32,
    v_factor: u32,
    mcu_width: u32,
    mcu_height: u32,
    block: *[64]u8,
) void {
    const start_y = mcu_y * mcu_height;
    const start_x = mcu_x * mcu_width;

    for (0..8) |y| {
        for (0..8) |x| {
            const pixel_y = start_y + y * v_factor;
            const pixel_x = start_x + x * h_factor;

            var sum: u32 = 0;
            var count: u32 = 0;

            for (0..v_factor) |dy| {
                for (0..h_factor) |dx| {
                    const py = pixel_y + dy;
                    const px = pixel_x + dx;

                    if (py < height and px < width) {
                        const pixel_idx = (py * width + px) * 3;
                        const r = rgb_pixels[pixel_idx];
                        const g = rgb_pixels[pixel_idx + 1];
                        const b = rgb_pixels[pixel_idx + 2];

                        const ycbcr = rgbToYCbCr(r, g, b);
                        const val = switch (component) {
                            0 => ycbcr.y,
                            1 => ycbcr.cb,
                            2 => ycbcr.cr,
                            else => unreachable,
                        };
                        sum += val;
                        count += 1;
                    }
                }
            }

            block[y * 8 + x] = if (count > 0)
                @intCast(sum / count)
            else
                128;
        }
    }
}
