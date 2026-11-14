//! Packs the packets of one logical bitstream into Ogg pages.
//!
//! Packets are split into lacing values as described in RFC 3533 section 5:
//! a packet of `n` bytes becomes `n / 255` lacing values of 255 followed by a
//! final lacing value of `n % 255` (which is 0 when `n` is a multiple of 255,
//! including the zero-length packet). Packets that do not fit in the current
//! page continue on the next one, which then has the `continued` flag set.
//!
//! The first page written gets the `bos` flag and the page written by
//! `finish` gets the `eos` flag. Several `PacketWriter`s with distinct serial
//! numbers can write to the same `Io.Writer` to multiplex logical bitstreams
//! (RFC 3533 section 4); keeping the pages in an order that is valid for the
//! media mapping (for example, all bos pages first when grouping) is up to
//! the caller.
//!
//! Many media mappings require the first packet to be alone on the bos page
//! and header packets to end on a page boundary. Call `flush` after such
//! packets to force a page boundary.
//!
//! The writer keeps one page worth of data (about 64 KiB) inline, so prefer
//! not to put it on a small stack.

const std = @import("std");
const Io = std.Io;
const Page = @import("Page.zig");

const PacketWriter = @This();

pub const Options = struct {
    /// A page is emitted as soon as its body reaches this many bytes at the
    /// end of a packet. Pages are also emitted whenever the segment table is
    /// full. Use `Page.max_body_len` to only emit full pages.
    page_body_target: usize = 4096,
};

pub const Error = error{
    /// `finish` has already been called.
    StreamFinished,
} || Io.Writer.Error;

serial_number: u32,
options: Options,
/// Sequence number of the next page to be emitted.
sequence_number: u32 = 0,
/// Granule position of the last packet completed on the pending page.
granule_position: i64 = Page.no_granule_position,
/// The pending page starts with the continuation of a packet.
continued: bool = false,
/// The bos page has been emitted.
started: bool = false,
finished: bool = false,
segment_count: usize = 0,
segment_table: [Page.max_segments]u8 = undefined,
body_len: usize = 0,
body: [Page.max_body_len]u8 = undefined,

pub fn init(serial_number: u32, options: Options) PacketWriter {
    return .{ .serial_number = serial_number, .options = options };
}

/// Appends a packet. `granule_position` is the codec-defined position at the
/// end of this packet; it is written to the page on which the packet ends.
///
/// Pages are written to `w` as they fill up.
pub fn writePacket(pw: *PacketWriter, w: *Io.Writer, packet: []const u8, granule_position: i64) Error!void {
    if (pw.finished) return error.StreamFinished;

    var offset: usize = 0;
    while (true) {
        if (pw.segment_count == Page.max_segments) {
            // Every lacing value but the last one of a packet is 255, so a
            // non-zero offset means the packet continues on the next page.
            try pw.emitPage(w, .{ .eos = false, .next_continued = offset > 0 });
        }
        const lacing: u8 = @intCast(@min(packet.len - offset, 255));
        pw.segment_table[pw.segment_count] = lacing;
        pw.segment_count += 1;
        @memcpy(pw.body[pw.body_len..][0..lacing], packet[offset..][0..lacing]);
        pw.body_len += lacing;
        offset += lacing;
        if (lacing < 255) break;
    }
    pw.granule_position = granule_position;

    if (pw.body_len >= pw.options.page_body_target) try pw.flush(w);
}

/// Emits the pending page, if any, so that the next packet starts on a new
/// page.
pub fn flush(pw: *PacketWriter, w: *Io.Writer) Error!void {
    if (pw.finished) return error.StreamFinished;
    if (pw.segment_count == 0) return;
    try pw.emitPage(w, .{ .eos = false, .next_continued = false });
}

/// Emits the last page of the logical bitstream with the `eos` flag set.
///
/// If no data is pending, an empty eos page (allowed by RFC 3533 section 4)
/// is written.
pub fn finish(pw: *PacketWriter, w: *Io.Writer) Error!void {
    if (pw.finished) return error.StreamFinished;
    try pw.emitPage(w, .{ .eos = true, .next_continued = false });
    pw.finished = true;
}

const EmitOptions = struct {
    eos: bool,
    next_continued: bool,
};

fn emitPage(pw: *PacketWriter, w: *Io.Writer, options: EmitOptions) Io.Writer.Error!void {
    const page: Page = .{
        .header_type = .{ .continued = pw.continued, .bos = !pw.started, .eos = options.eos },
        .granule_position = pw.granule_position,
        .serial_number = pw.serial_number,
        .sequence_number = pw.sequence_number,
        .segment_table = pw.segment_table[0..pw.segment_count],
        .body = pw.body[0..pw.body_len],
    };
    page.encode(w) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        // The writer maintains both invariants itself.
        error.TooManySegments, error.BodyLengthMismatch => unreachable,
    };

    pw.started = true;
    pw.sequence_number +%= 1;
    pw.granule_position = Page.no_granule_position;
    pw.continued = options.next_continued;
    pw.segment_count = 0;
    pw.body_len = 0;
}

const testing = std.testing;

fn collectPages(bytes: []const u8, out: []Page) ![]Page {
    var rest = bytes;
    var n: usize = 0;
    while (rest.len > 0) : (n += 1) {
        out[n] = try Page.parse(rest);
        rest = rest[out[n].encodedLen()..];
    }
    return out[0..n];
}

test "single packet stream" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var pw: PacketWriter = .init(7, .{});
    try pw.writePacket(&out.writer, "hello", 5);
    try pw.finish(&out.writer);
    try testing.expectError(error.StreamFinished, pw.writePacket(&out.writer, "x", 6));

    var buf: [4]Page = undefined;
    const pages = try collectPages(out.written(), &buf);
    try testing.expectEqual(@as(usize, 1), pages.len);
    try testing.expectEqual(Page.HeaderType{ .bos = true, .eos = true }, pages[0].header_type);
    try testing.expectEqual(@as(i64, 5), pages[0].granule_position);
    try testing.expectEqual(@as(u32, 7), pages[0].serial_number);
    try testing.expectEqualSlices(u8, &.{5}, pages[0].segment_table);
    try testing.expectEqualStrings("hello", pages[0].body);
}

test "flush separates header packets and finish writes a nil eos page" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var pw: PacketWriter = .init(1, .{});
    try pw.writePacket(&out.writer, "ident", 0);
    try pw.flush(&out.writer);
    try pw.writePacket(&out.writer, "", 0);
    try pw.writePacket(&out.writer, "data", 10);
    try pw.flush(&out.writer);
    try pw.flush(&out.writer); // no-op
    try pw.finish(&out.writer);

    var buf: [4]Page = undefined;
    const pages = try collectPages(out.written(), &buf);
    try testing.expectEqual(@as(usize, 3), pages.len);

    try testing.expect(pages[0].header_type.bos);
    try testing.expectEqualSlices(u8, &.{5}, pages[0].segment_table);

    try testing.expect(!pages[1].header_type.bos);
    try testing.expectEqualSlices(u8, &.{ 0, 4 }, pages[1].segment_table);
    try testing.expectEqual(@as(i64, 10), pages[1].granule_position);

    try testing.expectEqual(Page.HeaderType{ .eos = true }, pages[2].header_type);
    try testing.expectEqual(@as(usize, 0), pages[2].segment_table.len);
    try testing.expectEqual(Page.no_granule_position, pages[2].granule_position);

    for (pages, 0..) |page, i| try testing.expectEqual(@as(u32, @intCast(i)), page.sequence_number);
}

test "large packets span pages with the continued flag" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // 255 * 255 bytes need 255 lacing values of 255 and a terminating 0,
    // which does not fit in one segment table.
    const packet = try testing.allocator.alloc(u8, 255 * 255);
    defer testing.allocator.free(packet);
    for (packet, 0..) |*b, i| b.* = @truncate(i *% 31);

    var pw: PacketWriter = .init(3, .{ .page_body_target = Page.max_body_len });
    try pw.writePacket(&out.writer, packet, 99);
    try pw.finish(&out.writer);

    var buf: [4]Page = undefined;
    const pages = try collectPages(out.written(), &buf);
    try testing.expectEqual(@as(usize, 2), pages.len);

    try testing.expectEqual(Page.HeaderType{ .bos = true }, pages[0].header_type);
    try testing.expectEqual(@as(usize, 255), pages[0].segment_table.len);
    try testing.expectEqual(Page.no_granule_position, pages[0].granule_position);
    try testing.expectEqualSlices(u8, packet, pages[0].body);

    try testing.expectEqual(Page.HeaderType{ .continued = true, .eos = true }, pages[1].header_type);
    try testing.expectEqualSlices(u8, &.{0}, pages[1].segment_table);
    try testing.expectEqual(@as(i64, 99), pages[1].granule_position);
}

test "a full segment table at a packet boundary does not set continued" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var pw: PacketWriter = .init(3, .{ .page_body_target = Page.max_body_len });
    for (0..256) |i| try pw.writePacket(&out.writer, "", @intCast(i));
    try pw.finish(&out.writer);

    var buf: [4]Page = undefined;
    const pages = try collectPages(out.written(), &buf);
    try testing.expectEqual(@as(usize, 2), pages.len);
    try testing.expectEqual(@as(i64, 254), pages[0].granule_position);
    try testing.expect(!pages[1].header_type.continued);
    try testing.expectEqual(@as(i64, 255), pages[1].granule_position);
}
