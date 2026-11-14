//! An Ogg page (RFC 3533, section 6).
//!
//! A page is the unit of framing in an Ogg physical bitstream. It consists of
//! a 27-byte fixed header, a segment table of lacing values and the page body.
//!
//! ```text
//!  0                   1                   2                   3
//!  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 Byte
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! | capture_pattern: Magic number for page start "OggS"           | 0-3
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! | version       | header_type   | granule_position              | 4-7
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                                                               | 8-11
//! +                               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                               | bitstream_serial_number       | 12-15
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                               | page_sequence_number          | 16-19
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                               | CRC_checksum                  | 20-23
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! |                               |page_segments  | segment_table | 24-27
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! | ...                                                           | 28-
//! +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! ```
//!
//! All multi-byte fields are little endian.
//!
//! A `Page` never owns memory: `segment_table` and `body` are borrowed slices.

const std = @import("std");
const Io = std.Io;
const crc = @import("crc.zig");

const Page = @This();

/// The capture pattern every page starts with.
pub const capture_pattern = "OggS";
/// The only `stream_structure_version` defined by RFC 3533.
pub const version: u8 = 0;
/// Size of the fixed part of the header, excluding the segment table.
pub const header_len = 27;
/// Maximum number of lacing values in a segment table.
pub const max_segments = 255;
/// Maximum size of a page body.
pub const max_body_len = max_segments * 255;
/// Maximum size of a whole page (header, segment table and body): 65307 bytes.
pub const max_len = header_len + max_segments + max_body_len;
/// Granule position meaning "no packet finishes on this page".
pub const no_granule_position: i64 = -1;

/// Offsets of the fields in the fixed header.
const offset = struct {
    const version = 4;
    const header_type = 5;
    const granule_position = 6;
    const serial_number = 14;
    const sequence_number = 18;
    const checksum = 22;
    const segment_count = 26;
};

/// `header_type_flag` of a page.
pub const HeaderType = packed struct(u8) {
    /// The first packet on this page continues a packet of the previous page.
    continued: bool = false,
    /// First page of a logical bitstream ("bos").
    bos: bool = false,
    /// Last page of a logical bitstream ("eos").
    eos: bool = false,
    /// Bits not defined by RFC 3533. They are kept as is to make
    /// decode/encode round-trips lossless.
    reserved: u5 = 0,
};

pub const ParseError = error{
    /// The input does not start with "OggS".
    InvalidCapturePattern,
    /// `stream_structure_version` is not 0.
    UnsupportedVersion,
    /// The input ends before the page does.
    Truncated,
    /// The stored checksum does not match the page contents.
    ChecksumMismatch,
};

pub const EncodeError = error{
    /// `segment_table` has more than `max_segments` entries.
    TooManySegments,
    /// The sum of the lacing values differs from `body.len`.
    BodyLengthMismatch,
};

header_type: HeaderType = .{},
/// Position in the codec-defined time base, or `no_granule_position`.
granule_position: i64 = no_granule_position,
serial_number: u32,
sequence_number: u32,
/// Lacing values. At most `max_segments` entries.
segment_table: []const u8,
/// Page payload. Its length equals the sum of `segment_table`.
body: []const u8,

/// Size of the header including the segment table.
pub fn headerLen(page: Page) usize {
    return header_len + page.segment_table.len;
}

/// Size of the whole serialized page.
pub fn encodedLen(page: Page) usize {
    return page.headerLen() + page.body.len;
}

/// Checks the structural invariants that `encode` relies on.
pub fn validate(page: Page) EncodeError!void {
    if (page.segment_table.len > max_segments) return error.TooManySegments;
    if (lacedLen(page.segment_table) != page.body.len) return error.BodyLengthMismatch;
}

/// Computes the checksum of the page as it would be serialized.
pub fn checksum(page: Page) u32 {
    var header: [header_len]u8 = undefined;
    page.writeFixedHeader(&header, 0);
    var c = crc.Crc.init();
    c.update(&header);
    c.update(page.segment_table);
    c.update(page.body);
    return c.final();
}

/// Serializes the page, computing its checksum.
pub fn encode(page: Page, w: *Io.Writer) (EncodeError || Io.Writer.Error)!void {
    try page.validate();
    var header: [header_len]u8 = undefined;
    page.writeFixedHeader(&header, page.checksum());
    try w.writeAll(&header);
    try w.writeAll(page.segment_table);
    try w.writeAll(page.body);
}

/// Serializes the page into `buffer` and returns the written slice.
pub fn encodeToSlice(page: Page, buffer: []u8) (EncodeError || error{NoSpaceLeft})![]u8 {
    var w: Io.Writer = .fixed(buffer);
    page.encode(&w) catch |err| switch (err) {
        error.WriteFailed => return error.NoSpaceLeft,
        else => |e| return e,
    };
    return w.buffered();
}

fn writeFixedHeader(page: Page, header: *[header_len]u8, crc_value: u32) void {
    header[0..4].* = capture_pattern.*;
    header[offset.version] = version;
    header[offset.header_type] = @bitCast(page.header_type);
    std.mem.writeInt(i64, header[offset.granule_position..][0..8], page.granule_position, .little);
    std.mem.writeInt(u32, header[offset.serial_number..][0..4], page.serial_number, .little);
    std.mem.writeInt(u32, header[offset.sequence_number..][0..4], page.sequence_number, .little);
    std.mem.writeInt(u32, header[offset.checksum..][0..4], crc_value, .little);
    header[offset.segment_count] = @intCast(page.segment_table.len);
}

/// Parses one page from the start of `bytes` without copying.
///
/// The returned page borrows from `bytes`. Use `encodedLen` to find where the
/// next page starts.
pub fn parse(bytes: []const u8) ParseError!Page {
    if (bytes.len < header_len) {
        if (!std.mem.startsWith(u8, capture_pattern, bytes[0..@min(bytes.len, 4)]))
            return error.InvalidCapturePattern;
        return error.Truncated;
    }
    if (!std.mem.eql(u8, bytes[0..4], capture_pattern)) return error.InvalidCapturePattern;
    if (bytes[offset.version] != version) return error.UnsupportedVersion;

    const segment_count: usize = bytes[offset.segment_count];
    if (bytes.len < header_len + segment_count) return error.Truncated;
    const segment_table = bytes[header_len..][0..segment_count];
    const body_len = lacedLen(segment_table);
    const total_len = header_len + segment_count + body_len;
    if (bytes.len < total_len) return error.Truncated;

    const page: Page = .{
        .header_type = @bitCast(bytes[offset.header_type]),
        .granule_position = std.mem.readInt(i64, bytes[offset.granule_position..][0..8], .little),
        .serial_number = std.mem.readInt(u32, bytes[offset.serial_number..][0..4], .little),
        .sequence_number = std.mem.readInt(u32, bytes[offset.sequence_number..][0..4], .little),
        .segment_table = segment_table,
        .body = bytes[header_len + segment_count .. total_len],
    };

    const stored = std.mem.readInt(u32, bytes[offset.checksum..][0..4], .little);
    if (stored != page.checksum()) return error.ChecksumMismatch;

    return page;
}

pub const ReadError = ParseError || Io.Reader.Error;

/// Reads one page from `r` into `buffer` and parses it.
///
/// Returns `null` if `r` is at end of stream before the first byte of a page.
/// The returned page borrows from `buffer`.
pub fn read(r: *Io.Reader, buffer: *[max_len]u8) ReadError!?Page {
    const first = r.peekByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    if (first != capture_pattern[0]) return error.InvalidCapturePattern;

    const header = buffer[0..header_len];
    r.readSliceAll(header) catch |err| return truncatedOnEnd(err);
    if (!std.mem.eql(u8, header[0..4], capture_pattern)) return error.InvalidCapturePattern;

    const segment_count: usize = header[offset.segment_count];
    const segment_table = buffer[header_len..][0..segment_count];
    r.readSliceAll(segment_table) catch |err| return truncatedOnEnd(err);

    const body = buffer[header_len + segment_count ..][0..lacedLen(segment_table)];
    r.readSliceAll(body) catch |err| return truncatedOnEnd(err);

    return try parse(buffer[0 .. header_len + segment_count + body.len]);
}

fn truncatedOnEnd(err: Io.Reader.Error) ReadError {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// Sum of lacing values, i.e. the body length described by a segment table.
pub fn lacedLen(segment_table: []const u8) usize {
    var len: usize = 0;
    for (segment_table) |lacing| len += lacing;
    return len;
}

/// Iterates over the packet fragments contained in a page.
///
/// Each fragment is the part of one packet that lies in this page. A packet
/// may span several pages; `complete` tells whether the fragment ends its
/// packet.
pub const FragmentIterator = struct {
    page: Page,
    segment_index: usize = 0,
    body_offset: usize = 0,

    pub const Fragment = struct {
        data: []const u8,
        /// The packet ends within this page.
        complete: bool,
    };

    pub fn next(it: *FragmentIterator) ?Fragment {
        if (it.segment_index >= it.page.segment_table.len) return null;
        const start = it.body_offset;
        while (it.segment_index < it.page.segment_table.len) {
            const lacing = it.page.segment_table[it.segment_index];
            it.segment_index += 1;
            it.body_offset += lacing;
            if (lacing < 255) {
                return .{ .data = it.page.body[start..it.body_offset], .complete = true };
            }
        }
        return .{ .data = it.page.body[start..it.body_offset], .complete = false };
    }
};

pub fn fragments(page: Page) FragmentIterator {
    return .{ .page = page };
}

/// Number of packets that finish on this page.
pub fn completedPacketCount(page: Page) usize {
    var count: usize = 0;
    for (page.segment_table) |lacing| {
        if (lacing < 255) count += 1;
    }
    return count;
}

const testing = std.testing;

// A page that carries a single 4-byte packet. Bytes were built by hand
// following RFC 3533 section 6; the CRC was cross-checked with an
// independent bitwise implementation.
const sample_page = [_]u8{
    'O', 'g', 'g', 'S', // capture pattern
    0x00, // version
    0x02, // header type: bos
    0x2a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // granule position: 42
    0x78, 0x56, 0x34, 0x12, // serial number: 0x12345678
    0x00, 0x00, 0x00, 0x00, // page sequence number: 0
    0x7c, 0x95, 0x8b, 0x1b, // CRC
    0x01, // page segments
    0x04, // segment table
    0xde, 0xad, 0xbe, 0xef, // body
};

test "encode produces the RFC 3533 layout" {
    const page: Page = .{
        .header_type = .{ .bos = true },
        .granule_position = 42,
        .serial_number = 0x12345678,
        .sequence_number = 0,
        .segment_table = &.{4},
        .body = &.{ 0xde, 0xad, 0xbe, 0xef },
    };
    var buf: [max_len]u8 = undefined;
    const bytes = try page.encodeToSlice(&buf);
    try testing.expectEqualSlices(u8, &sample_page, bytes);
}

test "parse decodes every field" {
    const page = try parse(&sample_page);
    try testing.expectEqual(HeaderType{ .bos = true }, page.header_type);
    try testing.expectEqual(@as(i64, 42), page.granule_position);
    try testing.expectEqual(@as(u32, 0x12345678), page.serial_number);
    try testing.expectEqual(@as(u32, 0), page.sequence_number);
    try testing.expectEqualSlices(u8, &.{4}, page.segment_table);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, page.body);
    try testing.expectEqual(sample_page.len, page.encodedLen());
}

test "parse rejects corrupted pages" {
    var bytes = sample_page;
    bytes[bytes.len - 1] ^= 0xff;
    try testing.expectError(error.ChecksumMismatch, parse(&bytes));

    bytes = sample_page;
    bytes[0] = 'X';
    try testing.expectError(error.InvalidCapturePattern, parse(&bytes));

    bytes = sample_page;
    bytes[offset.version] = 1;
    try testing.expectError(error.UnsupportedVersion, parse(&bytes));

    try testing.expectError(error.Truncated, parse(sample_page[0 .. sample_page.len - 1]));
    try testing.expectError(error.Truncated, parse(sample_page[0..10]));
}

test "parse keeps reserved header bits" {
    const page: Page = .{
        .header_type = .{ .eos = true, .reserved = 0b10101 },
        .serial_number = 1,
        .sequence_number = 7,
        .segment_table = &.{},
        .body = &.{},
    };
    var buf: [max_len]u8 = undefined;
    const decoded = try parse(try page.encodeToSlice(&buf));
    try testing.expectEqual(page.header_type, decoded.header_type);
    try testing.expectEqual(no_granule_position, decoded.granule_position);
}

test "encode rejects inconsistent pages" {
    var buf: [max_len]u8 = undefined;
    const bad_len: Page = .{ .serial_number = 0, .sequence_number = 0, .segment_table = &.{3}, .body = "ab" };
    try testing.expectError(error.BodyLengthMismatch, bad_len.encodeToSlice(&buf));

    const many: [256]u8 = @splat(0);
    const too_many: Page = .{ .serial_number = 0, .sequence_number = 0, .segment_table = &many, .body = "" };
    try testing.expectError(error.TooManySegments, too_many.encodeToSlice(&buf));

    var small: [8]u8 = undefined;
    const ok: Page = .{ .serial_number = 0, .sequence_number = 0, .segment_table = &.{}, .body = "" };
    try testing.expectError(error.NoSpaceLeft, ok.encodeToSlice(&small));
}

test "read pages from a stream" {
    const stream = sample_page ++ sample_page;
    var r: Io.Reader = .fixed(&stream);
    var buf: [max_len]u8 = undefined;
    for (0..2) |_| {
        const page = (try read(&r, &buf)).?;
        try testing.expectEqual(@as(u32, 0x12345678), page.serial_number);
    }
    try testing.expectEqual(null, try read(&r, &buf));

    var truncated: Io.Reader = .fixed(sample_page[0..20]);
    try testing.expectError(error.Truncated, read(&truncated, &buf));
}

test "fragments follow lacing values" {
    // Packets: 300 bytes (255 + 45), 0 bytes, 255 bytes (255 + 0), then a
    // packet continuing on the next page (255).
    var body: [300 + 255 + 255]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i);
    const page: Page = .{
        .serial_number = 0,
        .sequence_number = 0,
        .segment_table = &.{ 255, 45, 0, 255, 0, 255 },
        .body = &body,
    };
    var it = page.fragments();
    const expected = [_]struct { usize, usize, bool }{
        .{ 0, 300, true },
        .{ 300, 300, true },
        .{ 300, 555, true },
        .{ 555, 810, false },
    };
    for (expected) |e| {
        const f = it.next().?;
        try testing.expectEqualSlices(u8, body[e[0]..e[1]], f.data);
        try testing.expectEqual(e[2], f.complete);
    }
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(@as(usize, 3), page.completedPacketCount());
}
