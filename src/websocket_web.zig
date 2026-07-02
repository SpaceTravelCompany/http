//! engine2.http.websocket_web — WebSocket 클라이언트 WASM
//!
//! JS `new WebSocket()`를 통해 브라우저 WebSocket API를 사용한다.

const std = @import("std");

const wasm = struct {
    extern "env" fn engine2_ws_connect(url_ptr: usize, url_len: usize, protocols_json_ptr: usize, protocols_json_len: usize) u32;
    extern "env" fn engine2_ws_status(handle: u32) u32;
    extern "env" fn engine2_ws_next_message_len(handle: u32) usize;
    extern "env" fn engine2_ws_next_message_opcode(handle: u32) u32;
    extern "env" fn engine2_ws_read_message(handle: u32, out_ptr: usize, out_len: usize) usize;
    extern "env" fn engine2_ws_write(handle: u32, opcode: u32, data_ptr: usize, data_len: usize) u32;
    extern "env" fn engine2_ws_close(handle: u32, code: u32, reason_ptr: usize, reason_len: usize) void;
    extern "env" fn engine2_ws_destroy(handle: u32) void;
    extern "env" fn engine2_ws_error(handle: u32, out_ptr: usize, out_len: usize) usize;
};

pub const ConnectionStatus = enum(u32) {
    invalid = 0,
    connecting = 1,
    open = 2,
    closed = 3,
    failed = 4,
};

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    internal_error = 1011,
    _,
};

pub const Message = struct {
    data: []const u8,
    opcode: Opcode,
    owned: bool,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.data);
    }
};

pub const SmallMessage = struct {
    data: [125]u8,
    len: usize,
    opcode: Opcode,
};

pub const WebWebSocket = struct {
    allocator: std.mem.Allocator,
    next_handle: u32,

    pub fn init(allocator: std.mem.Allocator) WebWebSocket {
        return .{
            .allocator = allocator,
            .next_handle = 1,
        };
    }

    pub fn deinit(self: *WebWebSocket) void {
        _ = self;
    }

    /// WebSocket 연결 시작 → handle 반환
    pub fn connect(self: *WebWebSocket, url: []const u8) !u32 {
        return self.connectWithProtocols(url, &.{});
    }

    pub fn connectWithProtocols(self: *WebWebSocket, url: []const u8, protocols: []const []const u8) !u32 {
        const protocols_json = try std.json.Stringify.valueAlloc(self.allocator, protocols, .{});
        defer self.allocator.free(protocols_json);
        const handle = wasm.engine2_ws_connect(
            @intFromPtr(url.ptr),
            url.len,
            @intFromPtr(protocols_json.ptr),
            protocols_json.len,
        );
        if (handle == 0) return error.ConnectFailed;
        self.next_handle = @max(self.next_handle, handle + 1);
        return handle;
    }

    /// JS 이벤트 핸들러가 상태를 갱신하므로 현재는 no-op이다.
    pub fn poll(self: *WebWebSocket) !void {
        _ = self;
    }

    pub fn status(self: *WebWebSocket, handle: u32) ConnectionStatus {
        _ = self;
        return @enumFromInt(wasm.engine2_ws_status(handle));
    }

    /// 대기 중인 메시지를 하나 복사해 가져온다. 메시지가 없으면 null.
    pub fn read(self: *WebWebSocket, handle: u32) !?[]const u8 {
        const len = wasm.engine2_ws_next_message_len(handle);
        if (len == 0) return null;
        const out = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(out);
        const written = wasm.engine2_ws_read_message(handle, @intFromPtr(out.ptr), out.len);
        if (written > out.len) return error.MessageTooLarge;
        return out[0..written];
    }

    pub fn readMessage(self: *WebWebSocket, handle: u32) !?Message {
        const opcode_raw = wasm.engine2_ws_next_message_opcode(handle);
        const data = (try self.read(handle)) orelse return null;
        return .{
            .data = data,
            .opcode = @enumFromInt(@as(u4, @intCast(opcode_raw))),
            .owned = true,
        };
    }

    /// 기본 write는 text 메시지로 전송한다.
    pub fn write(self: *WebWebSocket, handle: u32, data: []const u8) !void {
        try self.writeMessage(handle, .text, data);
    }

    pub fn writeMessage(self: *WebWebSocket, handle: u32, opcode: Opcode, data: []const u8) !void {
        _ = self;
        const ok = wasm.engine2_ws_write(handle, @intFromEnum(opcode), @intFromPtr(data.ptr), data.len);
        if (ok != 1) return error.WriteFailed;
    }

    /// close: 연결 종료
    pub fn close(self: *WebWebSocket, handle: u32) void {
        _ = self;
        wasm.engine2_ws_close(handle, @intFromEnum(CloseCode.normal), 0, 0);
    }

    pub fn closeWithReason(self: *WebWebSocket, handle: u32, code: CloseCode, reason: []const u8) void {
        _ = self;
        wasm.engine2_ws_close(handle, @intFromEnum(code), @intFromPtr(reason.ptr), reason.len);
    }

    pub fn destroy(self: *WebWebSocket, handle: u32) void {
        _ = self;
        wasm.engine2_ws_destroy(handle);
    }

    pub fn errorText(self: *WebWebSocket, allocator: std.mem.Allocator, handle: u32) ![]const u8 {
        _ = self;
        const len = wasm.engine2_ws_error(handle, 0, 0);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        const written = wasm.engine2_ws_error(handle, @intFromPtr(out.ptr), out.len);
        return out[0..@min(written, out.len)];
    }
};

pub const WebSocket = WebWebSocket;

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "websocket_web — init/deinit" {
    var ws = WebWebSocket.init(testing.allocator);
    defer ws.deinit();
    try testing.expect(ws.allocator.ptr == testing.allocator.ptr);
    try testing.expect(ws.allocator.vtable == testing.allocator.vtable);
}

test "websocket_web — poll noop" {
    var ws = WebWebSocket.init(testing.allocator);
    defer ws.deinit();
    try ws.poll();
}
