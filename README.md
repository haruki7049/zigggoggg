# zigggoggg
zigggoggg (pronounced as Zig Ogg) is an Ogg format Serializer &amp; De-serializer

It implements the Ogg encapsulation format defined in [RFC 3533](https://datatracker.ietf.org/doc/html/rfc3533).

## Features

- `Page`: encode and decode Ogg pages, with CRC-32 computation and verification
- `PacketWriter`: lace the packets of a logical bitstream into pages (packets spanning pages, bos/eos flags, nil eos pages)
- `PacketReader`: reassemble packets from a physical bitstream, including grouped and chained multiplexing

## Usage

```zig
const std = @import("std");
const ogg = @import("zigggoggg");

// Serialize
var pw: ogg.PacketWriter = .init(serial_number, .{});
try pw.writePacket(writer, ident_header, 0);
try pw.flush(writer); // put the first packet alone on the bos page
try pw.writePacket(writer, audio_packet, granule_position);
try pw.finish(writer); // emit the eos page

// Deserialize
var pr: ogg.PacketReader = try .init(allocator, reader);
defer pr.deinit();
while (try pr.next()) |packet| {
    // packet.serial_number, packet.data, packet.granule_position, ...
}
```
