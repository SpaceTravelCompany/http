//! engine2.http.websocket.server — 서버 측 WebSocket 어댑터
//!
//! `std.http.Server.Request.respondWebSocket()`을 호출해 101 Switching Protocols를
//! 송신한 후, codec Reader/Writer로 WebSocket 메시지를 주고받는다.

const std = @import("std");
const http = std.http;
const ws = @import("mod.zig");
const codec = @import("codec.zig");
const Opcode = ws.Opcode;
const Message = ws.Message;
const CloseCode = ws.CloseCode;
const CloseReason = ws.CloseReason;

// ─────────────────────────────────────────────────────────────────────
//  UpgradeOptions
// ─────────────────────────────────────────────────────────────────────

pub const UpgradeOptions = struct {
    /// `req_head.upgradeRequested().websocket` 값 (Sec-WebSocket-Key)
    key: []const u8,
    /// 서버가 선택한 subprotocol (null=없음)
    protocol: ?[]const u8 = null,
    /// extra 헤더 (Sec-WebSocket-Protocol 포함 가능)
    extra_headers: []const http.Header = &.{},
    /// 최대 수신 메시지 크기
    max_message_size: usize = ws.max_message_size_default,
};

// ─────────────────────────────────────────────────────────────────────
//  WsStream (서버 측)
// ─────────────────────────────────────────────────────────────────────

pub const WsStream = struct {
    allocator: std.mem.Allocator,
    reader: codec.Reader,
    writer: codec.Writer,
    closed: bool,
    selected_protocol: ?[]const u8,

    /// HTTP 업그레이드(101) 후 WebSocket 스트림 생성.
    pub fn upgrade(allocator: std.mem.Allocator, req: *http.Server.Request, opts: UpgradeOptions, io: std.Io) !WsStream {
        // extra_headers에 Sec-WebSocket-Protocol 추가
        var final_headers: [8]http.Header = undefined;
        var final_count: usize = 0;
        if (opts.protocol) |proto| {
            final_headers[final_count] = .{ .name = "Sec-WebSocket-Protocol", .value = proto };
            final_count += 1;
        }
        for (opts.extra_headers) |h| {
            if (final_count >= 8) break; // BoundedArray full → drop extra (safe)
            final_headers[final_count] = h;
            final_count += 1;
        }

        const std_ws = try req.respondWebSocket(.{
            .key = opts.key,
            .extra_headers = final_headers[0..final_count],
        });

        const reader = codec.Reader.init(allocator, std_ws.input, std_ws.output, opts.max_message_size, false, io);
        const writer = codec.Writer.init(std_ws.output);

        return WsStream{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .closed = false,
            .selected_protocol = opts.protocol,
        };
    }

    pub fn deinit(self: *WsStream) void {
        if (!self.closed) {
            self.close(.going_away, "") catch {};
        }
        self.reader.deinit();
    }

    pub fn readMessage(self: *WsStream, allocator: std.mem.Allocator) !Message {
        const msg = try self.reader.nextMessage(allocator);
        return msg;
    }

    pub fn writeMessage(self: *WsStream, opcode: Opcode, data: []const u8) !void {
        // Server→Client: no mask
        try self.writer.sendMessage(opcode, data, null);
    }

    pub fn writeFragmented(self: *WsStream, first_opcode: Opcode, parts: []const []const u8) !void {
        try self.writer.sendFragmented(first_opcode, parts, null);
    }

    pub fn writePing(self: *WsStream, payload: []const u8) !void {
        try self.writer.sendPing(payload, null);
    }

    pub fn writePong(self: *WsStream, payload: []const u8) !void {
        try self.writer.sendPong(payload, null);
    }

    pub fn close(self: *WsStream, code: CloseCode, reason: []const u8) !void {
        if (self.closed) return;
        self.closed = true;
        try self.writer.sendClose(code, reason, null);
    }

    pub fn closeReason(self: *const WsStream) ?CloseReason {
        return self.reader.getCloseReason();
    }

    pub fn selectedProtocol(self: *const WsStream) ?[]const u8 {
        return self.selected_protocol;
    }
};
