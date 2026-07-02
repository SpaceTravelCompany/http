//! engine2.http.client — REST 클라이언트 WASM
//!
//! 브라우저 빌드에서는 JS `fetch()`를 handle 기반 비동기 API로 호출한다.

const std = @import("std");
const http = @import("mod.zig");

const wasm = struct {
    extern "env" fn engine2_http_fetch(
        method_ptr: usize,
        method_len: usize,
        url_ptr: usize,
        url_len: usize,
        headers_json_ptr: usize,
        headers_json_len: usize,
        body_ptr: usize,
        body_len: usize,
    ) u32;
    extern "env" fn engine2_http_poll_request(handle: u32) u32;
    extern "env" fn engine2_http_response_status(handle: u32) u32;
    extern "env" fn engine2_http_response_body_len(handle: u32) usize;
    extern "env" fn engine2_http_response_body(handle: u32, out_ptr: usize, out_len: usize) usize;
    extern "env" fn engine2_http_request_error(handle: u32, out_ptr: usize, out_len: usize) usize;
    extern "env" fn engine2_http_destroy_request(handle: u32) void;
};

pub const RequestStatus = enum(u32) {
    invalid = 0,
    pending = 1,
    complete = 2,
    failed = 3,
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const FetchOptions = struct {
    method: http.Method = .GET,
    url: []const u8,
    headers: ?[]const HeaderEntry = null,
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }

    pub fn json(self: *const Response, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{});
    }

    pub fn text(self: *const Response) []const u8 {
        return self.body;
    }
};

pub const WebHttpClient = struct {
    allocator: std.mem.Allocator,
    next_handle: u32,

    pub fn init(allocator: std.mem.Allocator) WebHttpClient {
        return .{
            .allocator = allocator,
            .next_handle = 1,
        };
    }

    pub fn deinit(self: *WebHttpClient) void {
        _ = self;
    }

    /// GET 요청을 등록하고 JS fetch request handle을 반환한다.
    pub fn get(self: *WebHttpClient, comptime T: type, url: []const u8) !u32 {
        _ = T;
        return self.fetchAsync(.{
            .method = .GET,
            .url = url,
        });
    }

    /// POST JSON 요청을 등록하고 JS fetch request handle을 반환한다.
    pub fn post(self: *WebHttpClient, comptime T: type, url: []const u8, body: anytype) !u32 {
        _ = T;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const body_json = try std.json.Stringify.valueAlloc(aa, body, .{});
        const headers = [_]HeaderEntry{.{ .name = "Content-Type", .value = "application/json" }};
        return self.fetchAsync(.{
            .method = .POST,
            .url = url,
            .headers = &headers,
            .body = body_json,
        });
    }

    /// 범용 비동기 fetch. 반환 handle은 `requestStatus`/`response`로 폴링한다.
    pub fn fetchAsync(self: *WebHttpClient, opts: FetchOptions) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const headers_json = try encodeHeaders(aa, opts.headers);
        const method = @tagName(opts.method);
        const body = opts.body orelse "";
        const handle = wasm.engine2_http_fetch(
            @intFromPtr(method.ptr),
            method.len,
            @intFromPtr(opts.url.ptr),
            opts.url.len,
            @intFromPtr(headers_json.ptr),
            headers_json.len,
            @intFromPtr(body.ptr),
            body.len,
        );
        if (handle == 0) return error.FetchStartFailed;
        self.next_handle = @max(self.next_handle, handle + 1);
        return handle;
    }

    /// 네이티브 `fetch`와 같은 Response 타입을 반환하되, 브라우저에서는 완료된 handle만 처리한다.
    /// 완료되지 않은 요청의 handle은 자동으로 해제된다.
    pub fn fetch(self: *WebHttpClient, allocator: std.mem.Allocator, opts: FetchOptions) !Response {
        const handle = try self.fetchAsync(opts);
        if (self.requestStatus(handle) != .complete) {
            self.destroyRequest(handle);
            return error.Pending;
        }
        return try self.response(allocator, handle);
    }

    /// JS Promise가 상태를 갱신하므로 현재는 no-op이다. 프레임 루프 대칭성을 위해 남긴다.
    pub fn poll(self: *WebHttpClient) !void {
        _ = self;
    }

    pub fn requestStatus(self: *WebHttpClient, handle: u32) RequestStatus {
        _ = self;
        return @enumFromInt(wasm.engine2_http_poll_request(handle));
    }

    /// 완료된 요청의 JSON 결과를 파싱한다.
    /// 반환된 Parsed(T)의 deinit()을 호출자가 해제해야 한다.
    pub fn result(self: *WebHttpClient, comptime T: type, handle: u32) !std.json.Parsed(T) {
        var res = try self.response(self.allocator, handle);
        defer res.deinit();
        return try res.json(T, self.allocator);
    }

    /// 완료된 요청의 Response를 복사해 가져온다.
    pub fn response(self: *WebHttpClient, allocator: std.mem.Allocator, handle: u32) !Response {
        _ = self;
        const request_status = @as(RequestStatus, @enumFromInt(wasm.engine2_http_poll_request(handle)));
        switch (request_status) {
            .complete => {},
            .failed => return error.FetchFailed,
            .pending => return error.Pending,
            .invalid => return error.InvalidHandle,
        }

        const code = wasm.engine2_http_response_status(handle);
        if (code == 0) return error.InvalidResponse;
        const body_len = wasm.engine2_http_response_body_len(handle);
        const body = try allocator.alloc(u8, body_len);
        errdefer allocator.free(body);
        const written = wasm.engine2_http_response_body(handle, @intFromPtr(body.ptr), body.len);
        if (written > body.len) return error.ResponseTooLarge;
        return .{
            .status = @enumFromInt(@as(u10, @intCast(code))),
            .body = body[0..written],
            .allocator = allocator,
        };
    }

    /// handle의 HTTP 상태 코드. 완료 전이거나 실패면 null.
    pub fn status(self: *WebHttpClient, handle: u32) ?http.Status {
        _ = self;
        const code = wasm.engine2_http_response_status(handle);
        if (code == 0) return null;
        return @enumFromInt(@as(u10, @intCast(code)));
    }

    pub fn errorText(self: *WebHttpClient, allocator: std.mem.Allocator, handle: u32) ![]const u8 {
        _ = self;
        const len = wasm.engine2_http_request_error(handle, 0, 0);
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        const written = wasm.engine2_http_request_error(handle, @intFromPtr(out.ptr), out.len);
        return out[0..@min(written, out.len)];
    }

    pub fn destroyRequest(self: *WebHttpClient, handle: u32) void {
        _ = self;
        wasm.engine2_http_destroy_request(handle);
    }
};

pub const HttpClient = WebHttpClient;

fn encodeHeaders(allocator: std.mem.Allocator, headers: ?[]const HeaderEntry) ![]const u8 {
    return if (headers) |items|
        try std.json.Stringify.valueAlloc(allocator, items, .{})
    else
        try allocator.dupe(u8, "[]");
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "client_web — init/deinit" {
    var client = WebHttpClient.init(testing.allocator);
    defer client.deinit();
    try testing.expect(client.allocator.ptr == testing.allocator.ptr);
    try testing.expect(client.allocator.vtable == testing.allocator.vtable);
}

test "client_web — poll noop" {
    var client = WebHttpClient.init(testing.allocator);
    defer client.deinit();
    try client.poll();
}
