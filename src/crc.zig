//! The CRC-32 used by Ogg pages (RFC 3533, section 6).
//!
//! The RFC only specifies the generator polynomial 0x04C11DB7. The remaining
//! parameters follow the reference implementation (libogg): the register
//! starts at zero, neither input nor output is reflected, and the result is
//! not XORed. The checksum is computed over the whole page with the
//! `CRC_checksum` field set to zero.

const std = @import("std");

/// Incremental Ogg CRC-32 hasher.
pub const Crc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0x00000000,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0x00000000,
});

/// Computes the Ogg CRC-32 of `bytes` in one shot.
pub fn hash(bytes: []const u8) u32 {
    return Crc.hash(bytes);
}

test "check value" {
    // Check value of this parameter set for the standard input "123456789".
    try std.testing.expectEqual(@as(u32, 0x89a1897f), hash("123456789"));
}

test "empty input" {
    try std.testing.expectEqual(@as(u32, 0), hash(""));
}

test "incremental update equals one-shot hash" {
    var c = Crc.init();
    c.update("1234");
    c.update("56789");
    try std.testing.expectEqual(hash("123456789"), c.final());
}
