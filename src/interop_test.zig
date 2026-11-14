//! Tests against Ogg files produced by another implementation.
//!
//! The fixtures in `testdata/` were generated with FFmpeg:
//!
//! - `grouped.ogg`: an Opus stream (serial 0) and a Vorbis stream (serial 1)
//!   multiplexed by grouping.
//! - `chained.ogg`: a Vorbis stream (serial 0) followed by an Opus stream
//!   (serial 1000), multiplexed by chaining.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Page = @import("Page.zig");
const PacketReader = @import("PacketReader.zig");
const PacketWriter = @import("PacketWriter.zig");

const grouped = @embedFile("testdata/grouped.ogg");
const chained = @embedFile("testdata/chained.ogg");

/// Decodes every page and checks that re-encoding gives identical bytes.
fn expectPagesRoundTrip(bytes: []const u8, expected_pages: usize) !void {
    var rest = bytes;
    var count: usize = 0;
    var buf: [Page.max_len]u8 = undefined;
    while (rest.len > 0) : (count += 1) {
        const page = try Page.parse(rest);
        const len = page.encodedLen();
        try testing.expectEqualSlices(u8, rest[0..len], try page.encodeToSlice(&buf));
        rest = rest[len..];
    }
    try testing.expectEqual(expected_pages, count);
}

const StreamSummary = struct {
    serial_number: u32,
    first_packet_prefix: []const u8,
    packet_count: u64,
};

fn expectPackets(bytes: []const u8, expected: []const StreamSummary) !void {
    var r: Io.Reader = .fixed(bytes);
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();

    var counts: [2]u64 = .{ 0, 0 };
    var ended: [2]bool = .{ false, false };
    while (try pr.next()) |packet| {
        const i: usize = for (expected, 0..) |e, i| {
            if (e.serial_number == packet.serial_number) break i;
        } else return error.TestUnexpectedSerialNumber;

        try testing.expect(!ended[i]);
        try testing.expectEqual(counts[i], packet.packet_number);
        try testing.expectEqual(counts[i] == 0, packet.bos);
        if (packet.bos) {
            try testing.expect(std.mem.startsWith(u8, packet.data, expected[i].first_packet_prefix));
        }
        counts[i] += 1;
        ended[i] = packet.eos;
    }
    for (expected, 0..) |e, i| {
        try testing.expectEqual(e.packet_count, counts[i]);
        try testing.expect(ended[i]);
    }
}

test "pages of grouped streams round-trip byte for byte" {
    try expectPagesRoundTrip(grouped, 6);
}

test "pages of chained streams round-trip byte for byte" {
    try expectPagesRoundTrip(chained, 6);
}

test "packets of grouped streams" {
    try expectPackets(grouped, &.{
        .{ .serial_number = 0, .first_packet_prefix = "OpusHead", .packet_count = 18 },
        .{ .serial_number = 1, .first_packet_prefix = "\x01vorbis", .packet_count = 14 },
    });
}

test "packets of chained streams" {
    try expectPackets(chained, &.{
        .{ .serial_number = 0, .first_packet_prefix = "\x01vorbis", .packet_count = 14 },
        .{ .serial_number = 1000, .first_packet_prefix = "OpusHead", .packet_count = 13 },
    });
}

test "re-muxing packets of a real file preserves them" {
    // Read the chained file, write each logical bitstream again with
    // PacketWriter and read the result back.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var packets: std.ArrayList([]u8) = .empty;
    defer {
        for (packets.items) |p| testing.allocator.free(p);
        packets.deinit(testing.allocator);
    }

    {
        var r: Io.Reader = .fixed(chained);
        var pr: PacketReader = try .init(testing.allocator, &r);
        defer pr.deinit();

        const pw = try testing.allocator.create(PacketWriter);
        defer testing.allocator.destroy(pw);
        var granule: i64 = 0;
        while (try pr.next()) |packet| {
            if (packet.bos) pw.* = .init(packet.serial_number, .{});
            if (packet.granule_position) |g| granule = g;
            try packets.append(testing.allocator, try testing.allocator.dupe(u8, packet.data));
            try pw.writePacket(&out.writer, packet.data, granule);
            if (packet.eos) try pw.finish(&out.writer);
        }
    }

    var r: Io.Reader = .fixed(out.written());
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();
    for (packets.items) |expected| {
        const packet = (try pr.next()).?;
        try testing.expectEqualSlices(u8, expected, packet.data);
    }
    try testing.expectEqual(null, try pr.next());
}
