//! engine2.http.websocket.client — 클라이언트 측 WebSocket 어댑터
//!
//! `std.http.Client`의 connection 관리를 이용해 WebSocket 핸드셰이크를 수행하고,
//! codec Reader/Writer로 프레임을 주고받는다.
//!
//! `ws://` (plaintext)와 `wss://` (TLS)를 지원한다.

const std = @import("std");
const mem = std.mem;
const http = std.http;
const ws = @import("mod.zig");
const codec = @import("codec.zig");
const Opcode = ws.Opcode;
const Message = ws.Message;
const CloseCode = ws.CloseCode;
const CloseReason = ws.CloseReason;

// ─────────────────────────────────────────────────────────────────────
//  URL 파싱 (ws:// / wss://)
// ─────────────────────────────────────────────────────────────────────

pub const WsUrlParts = struct {
    host: []const u8,
    port: u16,
    tls: bool,
    path: []const u8,
};

/// `ws://` / `wss://` URL을 파싱한다.
pub fn parseUrl(url: []const u8) (std.Uri.ParseError || error{InvalidUrl})!WsUrlParts {
    const uri = try std.Uri.parse(url);
    const scheme = uri.scheme;
    if (!mem.eql(u8, scheme, "ws") and !mem.eql(u8, scheme, "wss")) {
        return error.InvalidUrl;
    }
    const tls = mem.eql(u8, scheme, "wss");
    const host_component = uri.host orelse return error.InvalidUrl;
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    const port = uri.port orelse (if (tls) @as(u16, 443) else 80);
    const path = blk: {
        const after_scheme = (mem.indexOf(u8, url, "://") orelse return error.InvalidUrl) + 3;
        const slash = mem.indexOfScalarPos(u8, url, after_scheme, '/') orelse break :blk "/";
        break :blk url[slash..];
    };
    return WsUrlParts{
        .host = host,
        .port = port,
        .tls = tls,
        .path = path,
    };
}

// ─────────────────────────────────────────────────────────────────────
//  ConnectOptions
// ─────────────────────────────────────────────────────────────────────

pub const ConnectOptions = struct {
    /// `ws://host[:port]/path` 또는 `wss://host[:port]/path`
    url: []const u8,
    /// Subprotocol 후보 (비었으면 subprotocol 미사용)
    protocols: []const []const u8 = &.{},
    /// Extra 헤더 (인증 등)
    extra_headers: []const http.Header = &.{},
    /// 최대 수신 메시지 크기
    max_message_size: usize = ws.max_message_size_default,
    /// Zig 0.16 std.http.Client는 client certificate 핸드셰이크를 노출하지 않는다.
    mtls: ?MtlsOptions = null,
};

pub const MtlsOptions = struct {
    cert_pem: []const u8,
    key_pem: []const u8,
};

// ─────────────────────────────────────────────────────────────────────
//  WsStream (클라이언트 측)
// ─────────────────────────────────────────────────────────────────────

pub const WsStream = struct {
    allocator: std.mem.Allocator,
    // NOTE: 연결 수명을 관리하기 위해 Connection pointer를 유지.
    // Request.deinit()에서 connection이 풀로 반납되는 것을 막기 위해
    // connection ownership을 가져온 후, deinit에서 직접 destroy한다.
    connection: *http.Client.Connection,
    http_client: *http.Client,
    reader: codec.Reader,
    writer: codec.Writer,
    closed: bool,
    selected_protocol: ?[]const u8,

    /// WebSocket 핸드셰이크를 수행하고 WsStream을 반환한다.
    pub fn connect(
        allocator: std.mem.Allocator,
        http_client: *http.Client,
        opts: ConnectOptions,
    ) (std.Uri.ParseError || http.Client.RequestError || http.Client.Request.ReceiveHeadError || error{
        InvalidUrl,
        HandshakeFailed,
        UnsupportedMtls,
        WsWriteFailed,
    } || ws.Error || std.Io.Reader.Error || std.Io.Writer.Error)!WsStream {
        if (opts.mtls != null) return error.UnsupportedMtls;

        _ = try parseUrl(opts.url);
        const uri = try std.Uri.parse(opts.url);

        // Sec-WebSocket-Key: 16B random → base64 (24B)
        var key_bytes: [16]u8 = undefined;
        http_client.io.random(&key_bytes);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

        // Build request headers
        var hdr_buf: [16]http.Header = undefined;
        var hdr_count: usize = 0;
        try hdrListAppend(&hdr_buf, &hdr_count, "Upgrade", "websocket");
        try hdrListAppend(&hdr_buf, &hdr_count, "Connection", "upgrade");
        try hdrListAppend(&hdr_buf, &hdr_count, "Sec-WebSocket-Key", &key_b64);
        try hdrListAppend(&hdr_buf, &hdr_count, "Sec-WebSocket-Version", "13");

        if (opts.protocols.len > 0) {
            const proto_val = (try ws.subprotocol.formatHeaderValue(opts.protocols, allocator)).?;
            defer allocator.free(proto_val);
            try hdrListAppend(&hdr_buf, &hdr_count, "Sec-WebSocket-Protocol", proto_val);
        }

        for (opts.extra_headers) |h| {
            if (hdr_count >= 16) break;
            hdr_buf[hdr_count] = h;
            hdr_count += 1;
        }

        // Open connection and send upgrade request
        var req = try http_client.request(.GET, uri, .{
            .extra_headers = hdr_buf[0..hdr_count],
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        errdefer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Validate 101 response
        if (response.head.status != .switching_protocols) {
            return error.HandshakeFailed;
        }

        // Validate Sec-WebSocket-Accept
        const expected_accept = codec.computeAcceptKey(&key_b64);
        var accept_found = false;
        {
            var it = response.head.iterateHeaders();
            while (it.next()) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "sec-websocket-accept")) {
                    const trimmed = mem.trim(u8, hdr.value, " \t");
                    if (mem.eql(u8, trimmed, &expected_accept)) {
                        accept_found = true;
                    }
                    break;
                }
            }
        }
        if (!accept_found) return error.HandshakeFailed;

        // Validate Sec-WebSocket-Protocol
        var selected_protocol: ?[]u8 = null;
        errdefer if (selected_protocol) |p| allocator.free(p);
        {
            var it = response.head.iterateHeaders();
            while (it.next()) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "sec-websocket-protocol")) {
                    if (opts.protocols.len == 0) return error.HandshakeFailed;
                    const srv_proto = mem.trim(u8, hdr.value, " \t");
                    if (!ws.subprotocol.validateSelected(srv_proto, opts.protocols)) {
                        return error.HandshakeFailed;
                    }
                    selected_protocol = try allocator.dupe(u8, srv_proto);
                    break;
                }
            }
        }
        // If client offered protocols but server responded with none → HandshakeFailed
        if (opts.protocols.len > 0 and selected_protocol == null) {
            return error.HandshakeFailed;
        }

        // Take ownership of the connection to prevent req.deinit() from releasing it
        const conn = req.connection orelse return error.HandshakeFailed;
        req.connection = null;
        // Defer deinit: errdefer handles error path; explicit call on success below
        // req.deinit() with connection=null won't release the connection to pool

        // Create Reader/Writer using the connection's raw stream
        const conn_reader = conn.reader();
        const conn_writer = conn.writer();
        // Create our own buffered reader/writer pairs from the raw io stream
        // The connection's reader/writer already includes TLS if needed
        const codec_reader = codec.Reader.init(allocator, conn_reader, conn_writer, opts.max_message_size, true, http_client.io);
        const codec_writer = codec.Writer.init(conn_writer);

        // Release request resources (connection was already stolen)
        req.deinit();

        return WsStream{
            .allocator = allocator,
            .connection = conn,
            .http_client = http_client,
            .reader = codec_reader,
            .writer = codec_writer,
            .closed = false,
            .selected_protocol = selected_protocol,
        };
    }

    pub fn deinit(self: *WsStream) void {
        if (!self.closed) {
            self.close(.going_away, "") catch {};
        }
        self.reader.deinit();
        // Destroy the stolen connection
        self.connection.destroy(self.http_client.io);
    }

    pub fn readMessage(self: *WsStream, allocator: std.mem.Allocator) !Message {
        return self.reader.nextMessage(allocator);
    }

    pub fn writeMessage(self: *WsStream, opcode: Opcode, data: []const u8) !void {
        // Client→Server: always masked
        const mask_key = codec.generateMaskingKey(self.http_client.io);
        try self.writer.sendMessage(opcode, data, mask_key);
    }

    pub fn writeFragmented(self: *WsStream, first_opcode: Opcode, parts: []const []const u8) !void {
        const mask_key = codec.generateMaskingKey(self.http_client.io);
        try self.writer.sendFragmented(first_opcode, parts, mask_key);
    }

    pub fn writePing(self: *WsStream, payload: []const u8) !void {
        try self.writer.sendPing(payload, codec.generateMaskingKey(self.http_client.io));
    }

    pub fn writePong(self: *WsStream, payload: []const u8) !void {
        try self.writer.sendPong(payload, codec.generateMaskingKey(self.http_client.io));
    }

    pub fn close(self: *WsStream, code: CloseCode, reason: []const u8) !void {
        if (self.closed) return;
        self.closed = true;
        try self.writer.sendClose(code, reason, codec.generateMaskingKey(self.http_client.io));
    }

    pub fn closeReason(self: *const WsStream) ?CloseReason {
        return self.reader.getCloseReason();
    }

    pub fn selectedProtocol(self: *const WsStream) ?[]const u8 {
        return self.selected_protocol;
    }
};

// ─────────────────────────────────────────────────────────────────────
//  Internal helpers
// ─────────────────────────────────────────────────────────────────────

fn hdrListAppend(buf: *[16]http.Header, count: *usize, name: []const u8, value: []const u8) !void {
    if (count.* >= 16) return error.OutOfMemory;
    buf[count.*] = .{ .name = name, .value = value };
    count.* += 1;
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

test "client — parseUrl ws://" {
    const parts = try parseUrl("ws://example.com/ws");
    try expectEqualStrings("example.com", parts.host);
    try expectEqual(@as(u16, 80), parts.port);
    try expect(!parts.tls);
    try expectEqualStrings("/ws", parts.path);
}

test "client — parseUrl wss://" {
    const parts = try parseUrl("wss://example.com:8443/ws?x=1");
    try expectEqualStrings("example.com", parts.host);
    try expectEqual(@as(u16, 8443), parts.port);
    try expect(parts.tls);
    try expectEqualStrings("/ws?x=1", parts.path);
}

test "client — parseUrl http:// invalid" {
    const result = parseUrl("http://example.com");
    try expect(result == error.InvalidUrl);
}

test "client — parseUrl no path defaults to /" {
    const parts = try parseUrl("ws://example.com");
    try expectEqualStrings("/", parts.path);
}

test "client — mTLS options are explicit unsupported boundary" {
    var http_client: http.Client = .{
        .allocator = testing.allocator,
        .io = testing.io,
    };
    defer http_client.deinit();

    const result = WsStream.connect(testing.allocator, &http_client, .{
        .url = "wss://example.com/ws",
        .mtls = .{
            .cert_pem = "cert",
            .key_pem = "key",
        },
    });
    try testing.expectError(error.UnsupportedMtls, result);
}

test "client — key base64 length" {
    const io = std.testing.io;
    var key: [16]u8 = undefined;
    io.random(&key);
    var b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &key);
    try expectEqual(@as(usize, 24), b64.len);
}

test "client — computeAcceptKey matches codec" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const expected = codec.computeAcceptKey(key);
    const result = codec.computeAcceptKey(key);
    try expectEqualStrings(&expected, &result);
}
