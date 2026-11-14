//! zigggoggg: an Ogg encapsulation format (RFC 3533) serializer and
//! deserializer.
//!
//! The library has two layers:
//!
//! - `Page`: the on-disk unit of an Ogg physical bitstream. It can be encoded
//!   to and decoded from bytes, with CRC computation and verification.
//! - `PacketWriter` / `PacketReader`: the packet layer. `PacketWriter` laces
//!   the packets of one logical bitstream into pages, and `PacketReader`
//!   reassembles packets from a (possibly multiplexed) physical bitstream.
//!
//! The library only implements the container. Interpreting packets and
//! granule positions is the job of a media mapping (Vorbis, Opus, ...).

const std = @import("std");

pub const Page = @import("Page.zig");
pub const PacketWriter = @import("PacketWriter.zig");
pub const PacketReader = @import("PacketReader.zig");
pub const crc = @import("crc.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("interop_test.zig");
}
