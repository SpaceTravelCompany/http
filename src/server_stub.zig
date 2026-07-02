//! engine2.http.server — WASM 스텁
//!
//! WASM(freestanding) 타겟에서는 HTTP 서버가 동작하지 않는다.
//! 모든 메서드가 즉시 `error.NotSupported`를 반환하거나
//! 컴파일 에러를 발생시킨다.

const std = @import("std");
const http = @import("mod.zig");

pub const Handler = *const fn (allocator: std.mem.Allocator, req: *const Request, res: *ResponseWriter) anyerror!void;
pub const WsHandler = *const fn (allocator: std.mem.Allocator, ws: *WsConnection) anyerror!void;
pub const Middleware = *const fn (ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void;

pub const Context = struct {
    method: http.Method,
    path: []const u8,
    status: http.Status,
    start_ms: i64,
    body_size: usize,
};

pub const Request = struct {
    method: http.Method,
    path: []const u8,
    query: ?[]const u8,
    headers: http.HeaderMap,
    body: ?[]const u8,
};

pub const ResponseWriter = struct {
    status: http.Status = .ok,
    headers: http.HeaderMap,
    pub fn init(allocator: std.mem.Allocator) ResponseWriter {
        return .{ .headers = http.HeaderMap.init(allocator) };
    }
    pub fn deinit(self: *ResponseWriter) void { self.headers.deinit(); }
    pub fn setStatus(self: *ResponseWriter, status: http.Status) void { self.status = status; }
    pub fn setHeader(self: *ResponseWriter, key: []const u8, value: []const u8) !void { try self.headers.set(key, value); }
    pub fn json(self: *ResponseWriter, value: anytype) !void { _ = self; _ = value; return error.NotSupported; }
    pub fn html(self: *ResponseWriter, body: []const u8) !void { _ = self; _ = body; return error.NotSupported; }
    pub fn send(self: *ResponseWriter, body: []const u8) !void { _ = self; _ = body; return error.NotSupported; }
};

pub const WsConnection = struct {
    pub fn readSmallMessage(self: *WsConnection) !SmallMessage { _ = self; return error.NotSupported; }
    pub fn writeMessage(self: *WsConnection, data: []const u8, opcode: WsOpcode) !void { _ = self; _ = data; _ = opcode; return error.NotSupported; }
    pub fn close(self: *WsConnection) void { _ = self; }
};
pub const WsOpcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };
pub const WsCloseCode = enum(u16) {
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
pub const SmallMessage = struct { data: [125]u8, len: usize, opcode: WsOpcode };
pub const WsMessage = struct { data: []const u8, opcode: WsOpcode, owned: bool };

pub const WsOptions = struct {
    protocol: ?[]const u8 = null,
    max_message_size: usize = 16 * 1024 * 1024,
};

pub const HttpServer = struct {
    pub fn init(allocator: std.mem.Allocator, port: u16) HttpServer { _ = allocator; _ = port; return .{}; }
    pub fn deinit(self: *HttpServer) void { _ = self; }
    pub fn get(self: *HttpServer, path: []const u8, handler: Handler) !void { _ = self; _ = path; _ = handler; return error.NotSupported; }
    pub fn post(self: *HttpServer, path: []const u8, handler: Handler) !void { _ = self; _ = path; _ = handler; return error.NotSupported; }
    pub fn put(self: *HttpServer, path: []const u8, handler: Handler) !void { _ = self; _ = path; _ = handler; return error.NotSupported; }
    pub fn delete(self: *HttpServer, path: []const u8, handler: Handler) !void { _ = self; _ = path; _ = handler; return error.NotSupported; }
    pub fn use(self: *HttpServer, mw: Middleware) !void { _ = self; _ = mw; return error.NotSupported; }
    pub fn serveStatic(self: *HttpServer, prefix: []const u8, dir: []const u8) !void { _ = self; _ = prefix; _ = dir; return error.NotSupported; }
    pub fn ws(self: *HttpServer, path: []const u8, handler: WsHandler) !void { return self.wsSimple(path, handler); }
    pub fn wsSimple(self: *HttpServer, path: []const u8, handler: WsHandler) !void { _ = self; _ = path; _ = handler; return error.NotSupported; }
    pub fn wsOpts(self: *HttpServer, path: []const u8, handler: WsHandler, opts: WsOptions) !void { _ = self; _ = path; _ = handler; _ = opts; return error.NotSupported; }
    pub fn listen(self: *HttpServer) !void { _ = self; return error.NotSupported; }
};
