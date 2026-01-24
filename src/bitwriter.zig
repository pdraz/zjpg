const std = @import("std");

pub const BitWriter = struct {
    writer: *std.io.Writer,
    buffer: u32,
    bits_in_buffer: u8,

    pub fn init(writer: *std.io.Writer) BitWriter {
        return BitWriter{
            .writer = writer,
            .buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    pub fn writeBits(self: *BitWriter, bits: u32, num_bits: u8) !void {
        std.debug.assert(num_bits <= 24);

        self.buffer = (self.buffer << @as(u5, @truncate(num_bits))) | bits;
        self.bits_in_buffer += num_bits;

        while (self.bits_in_buffer >= 8) {
            const byte = @as(u8, @truncate(self.buffer >> @as(u5, @truncate(self.bits_in_buffer - 8))));
            try self.writer.writeByte(byte);

            // 0xFF in entropy-coded data must be followed by 0x00
            // to prevent confusion with JPEG markers
            if (byte == 0xFF) {
                try self.writer.writeByte(0x00);
            }

            self.bits_in_buffer -= 8;
            self.buffer &= (@as(u32, 1) << @as(u5, @truncate(self.bits_in_buffer))) - 1;
        }
    }

    pub fn flush(self: *BitWriter) !void {
        if (self.bits_in_buffer > 0) {
            // JPEG spec requires padding with 1s to complete the final byte
            const padding_bits = 8 - self.bits_in_buffer;
            const padding = (@as(u32, 1) << @as(u5, @truncate(padding_bits))) - 1;
            self.buffer = (self.buffer << @as(u5, @truncate(padding_bits))) | padding;

            const byte = @as(u8, @truncate(self.buffer));
            try self.writer.writeByte(byte);

            if (byte == 0xFF) {
                try self.writer.writeByte(0x00);
            }
        }
        self.buffer = 0;
        self.bits_in_buffer = 0;
    }
};
