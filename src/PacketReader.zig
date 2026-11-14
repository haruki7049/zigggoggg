//! Reads Ogg pages from a physical bitstream and reassembles the packets of
//! every logical bitstream in it.
//!
//! Both kinds of multiplexing described in RFC 3533 section 4 are supported:
//! grouping (several logical bitstreams interleaved, all bos pages first)
//! and chaining (logical bitstreams one after another). Packets are returned
//! in the order in which they complete in the physical bitstream, tagged with
//! the serial number of their logical bitstream.
//!
//! The reader is strict: CRC mismatches, missing pages (sequence number gaps),
//! inconsistent continuation flags and multiplexing violations are reported
//! as errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Page = @import("Page.zig");

const PacketReader = @This();

pub const Packet = struct {
    /// Serial number of the logical bitstream the packet belongs to.
    serial_number: u32,
    /// Packet contents. Valid until the next call to `next` or `deinit`.
    data: []const u8,
    /// Index of the packet within its logical bitstream, starting at 0.
    packet_number: u64,
    /// The granule position of the page this packet ends on, if this is the
    /// last packet ending on that page. Per RFC 3533 the page granule
    /// position refers to that packet; other packets have `null`.
    granule_position: ?i64,
    /// First packet of its logical bitstream.
    bos: bool,
    /// Last packet of its logical bitstream.
    eos: bool,
};

pub const Error = error{
    /// A bos page uses the serial number of a logical bitstream that has not
    /// ended yet.
    DuplicateSerialNumber,
    /// A non-bos page has a serial number with no active logical bitstream.
    UnknownSerialNumber,
    /// A bos page appears after data pages of the current group.
    UnexpectedBos,
    /// A page sequence number was skipped.
    MissingPage,
    /// A page has the `continued` flag but there is no packet to continue.
    UnexpectedContinuation,
    /// A packet was left unfinished but the next page does not continue it.
    MissingContinuation,
    /// An eos page or the end of the input leaves a packet unfinished.
    IncompletePacket,
} || Page.ReadError || Allocator.Error;

const Stream = struct {
    /// Bytes of the packet being reassembled (or the last returned packet).
    buffer: std.ArrayList(u8) = .empty,
    next_sequence_number: u32,
    packet_count: u64 = 0,
};

gpa: Allocator,
reader: *Io.Reader,
page_buffer: *[Page.max_len]u8,
/// The page whose fragments are being consumed.
page: ?Page = null,
fragments: Page.FragmentIterator = undefined,
streams: std.AutoHashMapUnmanaged(u32, Stream) = .empty,
/// A non-bos page of the current group has been seen, so no more bos pages
/// are allowed until every logical bitstream of the group has ended.
group_has_data: bool = false,
/// Stream whose buffer holds the packet returned by the last `next` call.
returned_serial: ?u32 = null,

pub fn init(gpa: Allocator, reader: *Io.Reader) Allocator.Error!PacketReader {
    return .{
        .gpa = gpa,
        .reader = reader,
        .page_buffer = try gpa.create([Page.max_len]u8),
    };
}

pub fn deinit(pr: *PacketReader) void {
    var it = pr.streams.valueIterator();
    while (it.next()) |stream| stream.buffer.deinit(pr.gpa);
    pr.streams.deinit(pr.gpa);
    pr.gpa.destroy(pr.page_buffer);
    pr.* = undefined;
}

/// Returns the next complete packet, or `null` at the end of the input.
pub fn next(pr: *PacketReader) Error!?Packet {
    if (pr.returned_serial) |serial| {
        if (pr.streams.getPtr(serial)) |stream| stream.buffer.clearRetainingCapacity();
        pr.returned_serial = null;
    }

    while (true) {
        if (pr.page) |page| {
            const stream = pr.streams.getPtr(page.serial_number).?;
            while (pr.fragments.next()) |fragment| {
                try stream.buffer.appendSlice(pr.gpa, fragment.data);
                if (!fragment.complete) continue;

                const last_on_page = pr.fragments.segment_index == page.segment_table.len;
                const packet: Packet = .{
                    .serial_number = page.serial_number,
                    .data = stream.buffer.items,
                    .packet_number = stream.packet_count,
                    .granule_position = if (last_on_page) page.granule_position else null,
                    .bos = stream.packet_count == 0,
                    .eos = last_on_page and page.header_type.eos,
                };
                stream.packet_count += 1;
                pr.returned_serial = page.serial_number;
                return packet;
            }
            pr.page = null;
            if (page.header_type.eos) try pr.endStream(page.serial_number);
        }

        const page = try Page.read(pr.reader, pr.page_buffer) orelse {
            var it = pr.streams.valueIterator();
            while (it.next()) |stream| {
                if (stream.buffer.items.len > 0) return error.IncompletePacket;
            }
            return null;
        };
        try pr.acceptPage(page);
        pr.page = page;
        pr.fragments = page.fragments();
    }
}

/// Checks the page against the multiplexing and continuation rules and
/// updates the stream state accordingly.
fn acceptPage(pr: *PacketReader, page: Page) Error!void {
    if (page.header_type.bos) {
        if (pr.streams.contains(page.serial_number)) return error.DuplicateSerialNumber;
        if (pr.group_has_data) return error.UnexpectedBos;
        if (page.header_type.continued) return error.UnexpectedContinuation;
        try pr.streams.put(pr.gpa, page.serial_number, .{
            .next_sequence_number = page.sequence_number +% 1,
        });
        return;
    }

    const stream = pr.streams.getPtr(page.serial_number) orelse return error.UnknownSerialNumber;
    if (page.sequence_number != stream.next_sequence_number) return error.MissingPage;
    stream.next_sequence_number +%= 1;
    pr.group_has_data = true;

    const has_partial = stream.buffer.items.len > 0;
    if (page.header_type.continued and !has_partial) return error.UnexpectedContinuation;
    if (!page.header_type.continued and has_partial) return error.MissingContinuation;
}

fn endStream(pr: *PacketReader, serial_number: u32) Error!void {
    var kv = pr.streams.fetchRemove(serial_number).?;
    const incomplete = kv.value.buffer.items.len > 0;
    kv.value.buffer.deinit(pr.gpa);
    if (pr.streams.count() == 0) pr.group_has_data = false;
    if (incomplete) return error.IncompletePacket;
}

const testing = std.testing;
const PacketWriter = @import("PacketWriter.zig");

fn expectPacket(pr: *PacketReader, serial: u32, data: []const u8, granule: ?i64, bos: bool, eos: bool) !void {
    const packet = (try pr.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(serial, packet.serial_number);
    try testing.expectEqualSlices(u8, data, packet.data);
    try testing.expectEqual(granule, packet.granule_position);
    try testing.expectEqual(bos, packet.bos);
    try testing.expectEqual(eos, packet.eos);
}

test "round trip through PacketWriter" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const big = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 7);

    const a255: [255]u8 = @splat('a');
    const a510: [510]u8 = @splat('a');
    const packets = [_][]const u8{ "header", "", &a255, big, &a510, "tail" };

    const pw = try testing.allocator.create(PacketWriter);
    defer testing.allocator.destroy(pw);
    pw.* = .init(0xcafe, .{});
    for (packets, 0..) |p, i| {
        try pw.writePacket(&out.writer, p, @intCast(i));
        if (i == 0) try pw.flush(&out.writer);
    }
    try pw.finish(&out.writer);

    var r: Io.Reader = .fixed(out.written());
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();

    for (packets, 0..) |p, i| {
        const packet = (try pr.next()).?;
        try testing.expectEqual(@as(u32, 0xcafe), packet.serial_number);
        try testing.expectEqual(@as(u64, i), packet.packet_number);
        try testing.expectEqualSlices(u8, p, packet.data);
        try testing.expectEqual(i == 0, packet.bos);
        try testing.expectEqual(i == packets.len - 1, packet.eos);
        if (packet.granule_position) |g| try testing.expectEqual(@as(i64, @intCast(i)), g);
    }
    try testing.expectEqual(null, try pr.next());
}

test "grouped and chained logical bitstreams" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    const a = try testing.allocator.create(PacketWriter);
    defer testing.allocator.destroy(a);
    const b = try testing.allocator.create(PacketWriter);
    defer testing.allocator.destroy(b);

    // Group of two streams: both bos pages first.
    a.* = .init(1, .{});
    b.* = .init(2, .{});
    try a.writePacket(w, "a0", 0);
    try a.flush(w);
    try b.writePacket(w, "b0", 0);
    try b.flush(w);
    try a.writePacket(w, "a1", 10);
    try a.flush(w);
    try b.writePacket(w, "b1", 20);
    try b.finish(w);
    try a.finish(w); // nil eos page

    // Chained stream reusing serial number 1 after it ended.
    a.* = .init(1, .{});
    try a.writePacket(w, "c0", 5);
    try a.finish(w);

    var r: Io.Reader = .fixed(out.written());
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();

    try expectPacket(&pr, 1, "a0", 0, true, false);
    try expectPacket(&pr, 2, "b0", 0, true, false);
    try expectPacket(&pr, 1, "a1", 10, false, false);
    try expectPacket(&pr, 2, "b1", 20, false, true);
    try expectPacket(&pr, 1, "c0", 5, true, true);
    try testing.expectEqual(null, try pr.next());
}

test "only the last packet on a page carries the granule position" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var pw: PacketWriter = .init(9, .{});
    try pw.writePacket(&out.writer, "x", 1);
    try pw.writePacket(&out.writer, "y", 2);
    try pw.finish(&out.writer);

    var r: Io.Reader = .fixed(out.written());
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();
    try expectPacket(&pr, 9, "x", null, true, false);
    try expectPacket(&pr, 9, "y", 2, false, true);
    try testing.expectEqual(null, try pr.next());
}

fn encodePages(pages: []const Page) ![]u8 {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    for (pages) |page| try page.encode(&out.writer);
    return out.toOwnedSlice();
}

fn expectStreamError(expected: anyerror, pages: []const Page) !void {
    const bytes = try encodePages(pages);
    defer testing.allocator.free(bytes);
    var r: Io.Reader = .fixed(bytes);
    var pr: PacketReader = try .init(testing.allocator, &r);
    defer pr.deinit();
    while (true) {
        _ = (pr.next() catch |err| return testing.expectEqual(expected, err)) orelse
            return error.TestExpectedError;
    }
}

test "multiplexing and continuity violations" {
    const full = [_]u8{255};
    const body: [255]u8 = @splat(0);
    const bos: Page = .{ .header_type = .{ .bos = true }, .serial_number = 1, .sequence_number = 0, .segment_table = &.{}, .body = "" };
    const data: Page = .{ .serial_number = 1, .sequence_number = 1, .segment_table = &.{}, .body = "" };

    try expectStreamError(error.UnknownSerialNumber, &.{data});
    try expectStreamError(error.DuplicateSerialNumber, &.{ bos, bos });

    var other_bos = bos;
    other_bos.serial_number = 2;
    try expectStreamError(error.UnexpectedBos, &.{ bos, data, other_bos });

    var skipped = data;
    skipped.sequence_number = 2;
    try expectStreamError(error.MissingPage, &.{ bos, skipped });

    var continued = data;
    continued.header_type.continued = true;
    try expectStreamError(error.UnexpectedContinuation, &.{ bos, continued });

    var partial = data;
    partial.segment_table = &full;
    partial.body = &body;
    var after = data;
    after.sequence_number = 2;
    try expectStreamError(error.MissingContinuation, &.{ bos, partial, after });

    try expectStreamError(error.IncompletePacket, &.{ bos, partial });

    var partial_eos = partial;
    partial_eos.header_type.eos = true;
    try expectStreamError(error.IncompletePacket, &.{ bos, partial_eos });
}
