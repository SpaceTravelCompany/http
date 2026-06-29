//! engine2.http.websocket.codec — RFC 6455 프레임 코덱
//!
//! 공용 Reader/Writer를 제공한다. 서버/클라이언트 어댑터가 masking 정책을 결정한다.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;

const ws = @import("mod.zig");
const Opcode = ws.Opcode;
const Message = ws.Message;
const CloseCode = ws.CloseCode;
const CloseReason = ws.CloseReason;

// ─────────────────────────────────────────────────────────────────────
//  Frame (raw parsed)
// ─────────────────────────────────────────────────────────────────────

pub const Frame = struct {
    fin: bool,
    rsv1: bool,
    rsv2: bool,
    rsv3: bool,
    opcode: Opcode,
    mask: bool,
    masking_key: [4]u8,
    payload_len: u64,
    payload: []const u8,
};

// ─────────────────────────────────────────────────────────────────────
//  free functions
// ─────────────────────────────────────────────────────────────────────

/// Xor mask/unmask: data를 key로 XOR (in-place, reversible)
pub fn maskData(data: []u8, key: [4]u8) void {
    for (data, 0..) |byte, i| {
        data[i] = byte ^ key[i % 4];
    }
}

/// 암호학적 난수 마스킹 키 생성. io.random을 사용한다 (Zig 0.16.0)
pub fn generateMaskingKey(io: std.Io) [4]u8 {
    var key: [4]u8 = undefined;
    io.random(&key);
    return key;
}

/// Sec-WebSocket-Accept 계산 (RFC 6455 §4.2.2)
pub fn computeAcceptKey(key: []const u8) [28]u8 {
    var sha1 = crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

/// close frame payload 인코딩 (big-endian u16 + UTF-8 reason)
pub fn encodeClosePayload(code: CloseCode, reason: []const u8, buf: *[128]u8) []u8 {
    const code_u16 = @intFromEnum(code);
    buf[0] = @truncate(code_u16 >> 8);
    buf[1] = @truncate(code_u16 & 0xFF);
    const reason_len = @min(reason.len, buf.len - 2);
    @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
    return buf[0 .. 2 + reason_len];
}

/// close frame payload 디코딩
pub const ClosePayload = struct { code: CloseCode, reason: []const u8, valid: bool };

pub fn decodeClosePayload(payload: []const u8) ClosePayload {
    if (payload.len < 2) return .{ .code = @enumFromInt(@as(u16, 1005)), .reason = "", .valid = false };
    const code_val: u16 = (@as(u16, payload[0]) << 8) | payload[1];
    const reason = if (payload.len > 2) payload[2..] else "";
    const valid = switch (code_val) {
        1000...1003 => true,
        1007...1011 => true,
        3000...4999 => true,
        else => false,
    };
    return .{ .code = @enumFromInt(code_val), .reason = reason, .valid = valid };
}

// ─────────────────────────────────────────────────────────────────────
//  Internal: write raw frame bytes
// ─────────────────────────────────────────────────────────────────────

/// 내부: raw frame bytes를 스트림에 쓴다. mask가 있으면 payload를 mask 처리한다.
fn writeFrameRaw(out: *std.Io.Writer, opcode: Opcode, data: []const u8, fin: bool, mask_key: ?[4]u8) !void {
    const has_mask = mask_key != null;
    var h0: u8 = @intFromEnum(opcode);
    if (fin) h0 |= 0x80;

    const len = data.len;

    try out.writeByte(h0);
    if (len <= 125) {
        var h1: u8 = @intCast(len);
        if (has_mask) h1 |= 0x80;
        try out.writeByte(h1);
    } else if (len <= 0xFFFF) {
        var h1: u8 = 126;
        if (has_mask) h1 |= 0x80;
        try out.writeByte(h1);
        try out.writeInt(u16, @intCast(len), .big);
    } else {
        var h1: u8 = 127;
        if (has_mask) h1 |= 0x80;
        try out.writeByte(h1);
        try out.writeInt(u64, len, .big);
    }

    if (has_mask) {
        const key = mask_key.?;
        try out.writeAll(&key);
        // Mask the data before writing (chunked to avoid large stack)
        var masked_buf: [8192]u8 = undefined;
        var offset: usize = 0;
        while (offset < len) {
            const chunk_size = @min(masked_buf.len, len - offset);
            const chunk = data[offset..][0..chunk_size];
            @memcpy(masked_buf[0..chunk_size], chunk);
            maskData(masked_buf[0..chunk_size], key);
            try out.writeAll(masked_buf[0..chunk_size]);
            offset += chunk_size;
        }
    } else {
        try out.writeAll(data);
    }
}

// ─────────────────────────────────────────────────────────────────────
//  Writer
// ─────────────────────────────────────────────────────────────────────

/// RFC 6455 프레임 라이터.
pub const Writer = struct {
    out: *std.Io.Writer,

    pub fn init(out_stream: *std.Io.Writer) Writer {
        return .{ .out = out_stream };
    }

    /// 단일 FIN=1 프레임 전송 + flush.
    /// `mask_key` = `null` → MASK=0 (서버→클라이언트), `some` → masking (클라이언트→서버)
    pub fn sendMessage(self: *Writer, opcode: Opcode, data: []const u8, mask_key: ?[4]u8) !void {
        try self.sendMessageUnflushed(opcode, data, mask_key);
        try self.flush();
    }

    /// 단일 FIN=1 프레임 전송 (flush 없음)
    pub fn sendMessageUnflushed(self: *Writer, opcode: Opcode, data: []const u8, mask_key: ?[4]u8) !void {
        try self.writeFrame(opcode, data, true, mask_key);
    }

    /// 분할 메시지 전송.
    /// parts가 1개 이하면 일반 FIN=1 단일 프레임으로 전송한다.
    pub fn sendFragmented(self: *Writer, first_opcode: Opcode, parts: []const []const u8, mask_key: ?[4]u8) !void {
        if (parts.len <= 1) {
            const data = if (parts.len == 1) parts[0] else "";
            try self.writeFrame(first_opcode, data, true, mask_key);
            try self.flush();
            return;
        }
        try self.writeFrame(first_opcode, parts[0], false, mask_key);
        // parts.len >= 2, loop over remaining parts
        const remaining = parts[1..];
        for (remaining, 0..) |part, i| {
            const is_last = i == remaining.len - 1;
            try self.writeFrame(.continuation, part, is_last, mask_key);
        }
        try self.flush();
    }

    /// Control frame 전송 (FIN=1, payload ≤125 보장 필요)
    pub fn sendControl(self: *Writer, opcode: Opcode, payload: []const u8, mask_key: ?[4]u8) !void {
        std.debug.assert(payload.len <= 125);
        try self.writeFrame(opcode, payload, true, mask_key);
        try self.flush();
    }

    /// Close frame 전송
    pub fn sendClose(self: *Writer, code: CloseCode, reason: []const u8, mask_key: ?[4]u8) !void {
        var buf: [128]u8 = undefined;
        const payload = encodeClosePayload(code, reason, &buf);
        try self.writeFrame(.close, payload, true, mask_key);
        try self.flush();
    }

    /// Ping 전송 (편의)
    pub fn sendPing(self: *Writer, payload: []const u8, mask_key: ?[4]u8) !void {
        try self.sendControl(.ping, payload, mask_key);
    }

    /// Pong 전송 (편의)
    pub fn sendPong(self: *Writer, payload: []const u8, mask_key: ?[4]u8) !void {
        try self.sendControl(.pong, payload, mask_key);
    }

    pub fn flush(self: *Writer) !void {
        try self.out.flush();
    }

    fn writeFrame(self: *Writer, opcode: Opcode, data: []const u8, fin: bool, mask_key: ?[4]u8) !void {
        try writeFrameRaw(self.out, opcode, data, fin, mask_key);
    }
};

// ─────────────────────────────────────────────────────────────────────
//  Reader
// ─────────────────────────────────────────────────────────────────────

/// RFC 6455 프레임 리더.
/// `in`에서 프레임을 읽고, `out`으로 자동 ping/pong 응답을 보낸다.
pub const Reader = struct {
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    max_message_size: usize,
    allocator: std.mem.Allocator,
    /// 클라이언트 측이면 true: 자동 응답(pong/close echo)에 masking 적용
    mask_outgoing: bool,
    /// 난수 생성용 Io (Zig 0.16.0에서 std.crypto.random 대체)
    io: std.Io,

    // Fragmentation state
    frag_opcode: ?Opcode,
    frag_assembly: std.ArrayList(u8),
    pending_close: ?CloseReason,

    pub fn init(
        allocator: std.mem.Allocator,
        in_stream: *std.Io.Reader,
        out_stream: *std.Io.Writer,
        max_size: usize,
        mask_outgoing: bool,
        io: std.Io,
    ) Reader {
        return .{
            .in = in_stream,
            .out = out_stream,
            .max_message_size = max_size,
            .allocator = allocator,
            .mask_outgoing = mask_outgoing,
            .io = io,
            .frag_opcode = null,
            .frag_assembly = std.ArrayList(u8).empty,
            .pending_close = null,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.frag_assembly.deinit(self.allocator);
    }

    pub fn getCloseReason(self: *const Reader) ?CloseReason {
        return self.pending_close;
    }

    /// raw frame 하나를 읽고 unmask한 payload를 반환한다.
    /// control frame에 대해 자동 응답(ping→pong, close→echo)을 수행한다.
    pub fn nextFrame(self: *Reader) (std.Io.Reader.Error || error{ProtocolError, WsWriteFailed})!Frame {
        const header = try self.in.takeArray(2);
        const h0: packed struct(u8) {
            opcode: u4,
            rsv3: u1,
            rsv2: u1,
            rsv1: u1,
            fin: u1,
        } = @bitCast(header[0]);
        const h1: packed struct(u8) {
            payload_len: u7,
            mask: u1,
        } = @bitCast(header[1]);

        const fin = h0.fin == 1;
        const rsv1 = h0.rsv1 == 1;
        const rsv2 = h0.rsv2 == 1;
        const rsv3 = h0.rsv3 == 1;
        const opcode: Opcode = @enumFromInt(h0.opcode);
        const mask = h1.mask == 1;
        var extended_len: u64 = h1.payload_len;

        if (h1.payload_len == 126) {
            extended_len = try self.in.takeInt(u16, .big);
        } else if (h1.payload_len == 127) {
            extended_len = try self.in.takeInt(u64, .big);
        }

        const masking_key: [4]u8 = if (mask) blk: {
            break :blk (try self.in.takeArray(4)).*;
        } else [_]u8{ 0, 0, 0, 0 };

        const payload_raw = try self.in.take(@intCast(extended_len));

        // Unmask in-place
        if (mask) {
            maskData(payload_raw, masking_key);
        }

        // RSV bits must be 0 (RFC 6455 §5.2)
        if (rsv1 or rsv2 or rsv3) return error.ProtocolError;

        // Control frame validation
        switch (opcode) {
            .ping, .pong, .close => {
                if (!fin) return error.ProtocolError;
                if (extended_len > 125) return error.ProtocolError;
            },
            else => {},
        }

        // Auto-respond control frames
        switch (opcode) {
            .ping => {
                try self.sendControlFrame(.pong, payload_raw);
            },
            .close => {
                const parsed = decodeClosePayload(payload_raw);
                if (!parsed.valid) {
                    var buf: [128]u8 = undefined;
                    const encoded = encodeClosePayload(CloseCode{ .protocol_error = 1002 }, "", &buf);
                    try self.sendControlFrame(.close, encoded);
                    self.pending_close = CloseReason{ .code = @enumFromInt(@as(u16, 1002)), .reason = "" };
                    return error.ProtocolError;
                }
                var buf: [128]u8 = undefined;
                const encoded = encodeClosePayload(parsed.code, parsed.reason, &buf);
                try self.sendControlFrame(.close, encoded);
                self.pending_close = CloseReason{ .code = parsed.code, .reason = parsed.reason };
            },
            else => {},
        }

        return Frame{
            .fin = fin,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .opcode = opcode,
            .mask = mask,
            .masking_key = masking_key,
            .payload_len = extended_len,
            .payload = payload_raw,
        };
    }

    /// 완성된 text/binary 메시지를 반환한다.
    /// control frame / fragmentation / RSV 검증을 모두 처리한다.
    pub fn nextMessage(self: *Reader, allocator: std.mem.Allocator) (std.Io.Reader.Error || ws.Error)!Message {
        while (true) {
            if (self.pending_close != null) return error.ConnectionClosed;

            const frame = self.nextFrame() catch |err| switch (err) {
                error.ProtocolError => return error.ProtocolError,
                else => |e| return e,
            };

            switch (frame.opcode) {
                .text, .binary => {
                    if (frame.opcode == .text) {
                        if (!std.unicode.utf8ValidateSlice(frame.payload)) return error.UnsupportedData;
                    }
                    if (frame.fin) {
                        const data = try allocator.dupe(u8, frame.payload);
                        return Message{ .data = data, .opcode = frame.opcode, .owned = true };
                    } else {
                        if (self.frag_opcode != null) return error.ProtocolError;
                        if (frame.payload.len > self.max_message_size) return error.MessageOversize;
                        self.frag_opcode = frame.opcode;
                        try self.frag_assembly.ensureUnusedCapacity(self.allocator, frame.payload.len);
                        self.frag_assembly.appendSliceAssumeCapacity(frame.payload);
                    }
                },
                .continuation => {
                    const active_opcode = self.frag_opcode orelse return error.ProtocolError;
                    if (active_opcode == .text) {
                        if (!std.unicode.utf8ValidateSlice(frame.payload)) return error.UnsupportedData;
                    }
                    const new_len = self.frag_assembly.items.len + frame.payload.len;
                    if (new_len > self.max_message_size) {
                        self.frag_opcode = null;
                        self.frag_assembly.clearRetainingCapacity();
                        return error.MessageOversize;
                    }
                    try self.frag_assembly.ensureUnusedCapacity(self.allocator, frame.payload.len);
                    self.frag_assembly.appendSliceAssumeCapacity(frame.payload);
                    if (frame.fin) {
                        const data = try allocator.dupe(u8, self.frag_assembly.items);
                        const result_opcode = active_opcode;
                        self.frag_opcode = null;
                        self.frag_assembly.clearRetainingCapacity();
                        return Message{ .data = data, .opcode = result_opcode, .owned = true };
                    }
                },
                .ping => continue, // auto-pong already sent in nextFrame
                .pong => continue,
                .close => return error.ConnectionClosed, // echo + pending_close already in nextFrame
                else => return error.ProtocolError,
            }
        }
    }

    fn sendControlFrame(self: *Reader, opcode: Opcode, payload: []const u8) ws.Error!void {
        var w = Writer.init(self.out);
        const mk: ?[4]u8 = if (self.mask_outgoing) generateMaskingKey(self.io) else null;
        w.sendControl(opcode, payload, mk) catch return error.WsWriteFailed;
    }
};

// ─────────────────────────────────────────────────────────────────────
//  테스트 (pure functions only; integration tests는 server/client 테스트에서)
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

test "codec — maskData roundtrip" {
    var data: [5]u8 = .{ 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const key = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try expect(mem.eql(u8, &data, "Hello"));
    maskData(&data, key);
    try expect(!mem.eql(u8, &data, "Hello"));
    maskData(&data, key);
    try expect(mem.eql(u8, &data, "Hello"));
}

test "codec — generateMaskingKey randomness" {
    const io = std.testing.io;
    const key1 = generateMaskingKey(io);
    const key2 = generateMaskingKey(io);
    try expect(!mem.eql(u8, &key1, &key2));
}

test "codec — computeAcceptKey RFC 6455 §1.3" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    const result = computeAcceptKey(key);
    try expectEqualStrings(expected, &result);
}

test "codec — encodeClosePayload / decodeClosePayload" {
    var buf: [128]u8 = undefined;
    const encoded = encodeClosePayload(CloseCode{ .normal = 1000 }, "bye", &buf);
    const parsed = decodeClosePayload(encoded);
    try expect(parsed.valid);
    try expectEqual(@intFromEnum(CloseCode.normal), @intFromEnum(parsed.code));
    try expectEqualStrings("bye", parsed.reason);
}

test "codec — decodeClosePayload invalid code 1004" {
    const payload = [_]u8{ 0x03, 0xEC }; // 1004 big-endian
    const parsed = decodeClosePayload(&payload);
    try expect(!parsed.valid);
}

test "codec — decodeClosePayload empty" {
    const parsed = decodeClosePayload("");
    try expect(!parsed.valid);
}

test "codec — decodeClosePayload code 3000 (registered)" {
    const payload = [_]u8{ 0x0B, 0xB8 }; // 3000 big-endian
    const parsed = decodeClosePayload(&payload);
    try expect(parsed.valid);
    try expectEqual(@as(u16, 3000), @intFromEnum(parsed.code));
}
