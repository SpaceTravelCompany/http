//! engine2.http.client — REST 클라이언트 (네이티브)
//!
//! Zig 0.16.0 `std.http.Client`를 래핑한다.
//! 동기 방식으로 동작하며, getJson/postJson/fetch를 제공한다.
//!
//! ## retry 정책
//!
//! - 5xx 또는 네트워크 에러 시 재시도
    //! - 네트워크 에러/5xx는 메서드 무관하게 3회 재시도
//! - 지수 백오프 (1s, 2s, 4s) + 100ms jitter

const std = @import("std");
const mem = std.mem;
const http = @import("mod.zig");

pub const WriteBufferSize: usize = 16384;
pub const MaxBufferedBodySize: u64 = 16 * 1024 * 1024;

// ─────────────────────────────────────────────────────────────────────
//  HttpClient
// ─────────────────────────────────────────────────────────────────────

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !HttpClient {
        var client: std.http.Client = .{
            .allocator = allocator,
            .io = io,
            .write_buffer_size = WriteBufferSize,
        };
        _ = &client; // initial mutation for init pattern
        return HttpClient{
            .allocator = allocator,
            .client = client,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// GET + JSON 파싱 한 줄 (chzzk bot get_json 패턴)
    /// 최적화: arena로 fetch 수명 관리 → caller allocator는 최종 JSON만 소유.
    pub fn getJson(self: *HttpClient, comptime T: type, allocator: std.mem.Allocator, url: []const u8) !T {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const response = try self.fetch(aa, .{
            .method = .GET,
            .url = url,
        });

        if (response.status != .ok and response.status != .no_content) return error.HttpError;

        return std.json.parseFromSliceLeaky(T, allocator, response.body, .{ .allocate = .alloc_always });
    }

    /// POST + JSON body + 응답 파싱 (chzzk bot post_json 패턴)
    /// 최적화: arena로 fetch + body_json 수명 관리.
    pub fn postJson(self: *HttpClient, comptime T: type, allocator: std.mem.Allocator, url: []const u8, body: anytype) !T {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const body_json = try std.json.Stringify.valueAlloc(aa, body, .{});

        const response = try self.fetch(aa, .{
            .method = .POST,
            .url = url,
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = body_json,
        });

        if (response.status != .ok and response.status != .created and response.status != .no_content) return error.HttpError;

        return std.json.parseFromSliceLeaky(T, allocator, response.body, .{ .allocate = .alloc_always });
    }

    /// 범용 fetch: 원샷 HTTP 요청. body 버퍼링.
    pub fn fetch(self: *HttpClient, allocator: std.mem.Allocator, opts: FetchOptions) !Response {
        if (opts.timeout_ms) |timeout_ms| {
            return try fetchWithTimeout(self, allocator, opts, timeout_ms);
        }

        return try fetchInternal(self, allocator, opts);
    }

    fn fetchInternal(self: *HttpClient, allocator: std.mem.Allocator, opts: FetchOptions) !Response {
        const uri = try std.Uri.parse(opts.url);

        // retry 루프: 네트워크 에러/5xx는 메서드 무관하게 재시도
        const max_retries: u32 = 3;
        var last_err: ?anyerror = null;

        var retry_i: u32 = 0;
        while (retry_i < max_retries) : (retry_i += 1) {
            if (retry_i > 0) {
                // 지수 백오프 (1s, 2s, 4s) + 100ms jitter
                const delay_ms = (@as(u64, 1) << @as(u6, @intCast(retry_i - 1))) * 1000;
                var jitter_buf: [1]u8 = undefined;
                self.client.io.random(&jitter_buf);
                const jitter = @as(u64, jitter_buf[0]) * 100 / 256; // 0~99 범위
                const total_ms = delay_ms + jitter;
                const dur = std.Io.Duration.fromMilliseconds(@intCast(total_ms));
                try std.Io.sleep(self.client.io, dur, .awake);
            }

            // RequestOptions 구성 (header_storage는 전달받은 allocator 사용)
            var req_headers: []const std.http.Header = &.{};
            var header_storage: std.ArrayList(std.http.Header) = .empty;
            defer header_storage.deinit(allocator);

            if (opts.headers) |h| {
                try header_storage.ensureTotalCapacity(allocator, h.len);
                for (h) |entry| {
                    header_storage.appendAssumeCapacity(.{ .name = entry.name, .value = entry.value });
                }
                req_headers = header_storage.items;
            }

            var req = self.client.request(opts.method, uri, .{
                .extra_headers = req_headers,
            }) catch |err| {
                last_err = err;
                if (isRetryableError(err) and retry_i + 1 < max_retries) continue;
                return err;
            };
            defer req.deinit();

            if (opts.body) |body| {
                const request_body = try allocator.dupe(u8, body);
                defer allocator.free(request_body);
                req.sendBodyComplete(request_body) catch |err| {
                    last_err = err;
                    if (isRetryableError(err) and retry_i + 1 < max_retries) continue;
                    return err;
                };
            } else {
                req.sendBodiless() catch |err| {
                    last_err = err;
                    if (isRetryableError(err) and retry_i + 1 < max_retries) continue;
                    return err;
                };
            }

            // 응답 헤더 수신
            var redirect_buf: [8192]u8 = undefined;
            var std_response = req.receiveHead(&redirect_buf) catch |err| {
                last_err = err;
                if (isRetryableError(err) and retry_i + 1 < max_retries) continue;
                return err;
            };

            const status = std_response.head.status;

            // 응답 본문 읽기
            const body = readResponseBody(allocator, &req, &std_response) catch |err| {
                last_err = err;
                if (isRetryableError(err) and retry_i + 1 < max_retries) continue;
                return err;
            };

            // 5xx 재시도
            if (isServerError(status) and retry_i + 1 < max_retries) {
                allocator.free(body);
                continue;
            }

            return Response{
                .status = status,
                .body = body,
                .allocator = allocator,
            };
        }

        return last_err orelse error.HttpError;
    }

    pub fn rawClient(self: *HttpClient) *std.http.Client {
        return &self.client;
    }
};

// ─────────────────────────────────────────────────────────────────────
//  FetchOptions & Response
// ─────────────────────────────────────────────────────────────────────

pub const FetchOptions = struct {
    method: http.Method = .GET,
    url: []const u8,
    headers: ?[]const HeaderEntry = null,
    body: ?[]const u8 = null,
    /// 요청 전체 제한 시간. null이면 제한 없음.
    timeout_ms: ?u64 = null,
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
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

// ─────────────────────────────────────────────────────────────────────
//  헬퍼
// ─────────────────────────────────────────────────────────────────────

fn isIdempotent(method: http.Method) bool {
    return switch (method) {
        .GET, .PUT, .DELETE, .HEAD, .OPTIONS, .TRACE => true,
        else => false,
    };
}

fn isServerError(status: http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 500 and code < 600;
}

fn isRetryableError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.TlsInitializationFailed, error.BrokenPipe,
        error.ConnectionResetByPeer, error.ConnectionTimedOut, error.Unexpected,
        error.ReadFailed => true,
        else => false,
    };
}

const FetchSelectResult = union(enum) {
    response: anyerror!Response,
    timeout: anyerror!void,
};

fn fetchWithTimeout(
    self: *HttpClient,
    allocator: std.mem.Allocator,
    opts: FetchOptions,
    timeout_ms: u64,
) !Response {
    var select_buffer: [2]FetchSelectResult = undefined;
    var select = std.Io.Select(FetchSelectResult).init(self.client.io, &select_buffer);

    var worker_opts = opts;
    worker_opts.timeout_ms = null;

    select.async(.response, fetchWorker, .{ self, allocator, worker_opts });
    select.async(.timeout, timeoutWorker, .{ self.client.io, timeout_ms });

    const result = try select.await();
    switch (result) {
        .response => |response_result| {
            defer select.cancelDiscard();
            return response_result;
        },
        .timeout => |timeout_result| {
            _ = timeout_result catch {};
            select.cancelDiscard();
            return error.Timeout;
        },
    }
}

fn fetchWorker(self: *HttpClient, allocator: std.mem.Allocator, opts: FetchOptions) anyerror!Response {
    return self.fetchInternal(allocator, opts);
}

fn timeoutWorker(io: std.Io, timeout_ms: u64) anyerror!void {
    const duration = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms));
    try std.Io.sleep(io, duration, .awake);
    return error.Timeout;
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "client — init/deinit" {
    var client = try HttpClient.init(testing.allocator, std.testing.io);
    defer client.deinit();
    try testing.expect(client.allocator.ptr == testing.allocator.ptr);
    try testing.expect(client.allocator.vtable == testing.allocator.vtable);
}

fn readResponseBody(
    allocator: std.mem.Allocator,
    req: *std.http.Client.Request,
    response: *std.http.Client.Response,
) ![]u8 {
    const encoded_body = try readEncodedResponseBody(allocator, req, response);

    if (response.head.content_encoding == .identity) return encoded_body;
    defer allocator.free(encoded_body);

    return try decompressResponseBody(allocator, encoded_body, response.head.content_encoding);
}

fn readEncodedResponseBody(
    allocator: std.mem.Allocator,
    req: *std.http.Client.Request,
    response: *std.http.Client.Response,
) ![]u8 {
    return switch (response.head.transfer_encoding) {
        .none => blk: {
            const content_length = response.head.content_length orelse return try allocator.alloc(u8, 0);
            if (content_length > MaxBufferedBodySize) return error.StreamTooLong;
            break :blk req.reader.in.readAlloc(allocator, @intCast(content_length));
        },
        .chunked => blk: {
            var transfer_buffer: [64]u8 = undefined;
            const body_reader = req.reader.bodyReader(&transfer_buffer, .chunked, null);
            break :blk readBodyReaderAlloc(allocator, body_reader);
        },
    };
}

fn decompressResponseBody(
    allocator: std.mem.Allocator,
    encoded_body: []const u8,
    content_encoding: std.http.ContentEncoding,
) ![]u8 {
    if (encoded_body.len == 0) return try allocator.alloc(u8, 0);

    const buffer_len: usize = switch (content_encoding) {
        .identity => return try allocator.dupe(u8, encoded_body),
        .gzip, .deflate => std.compress.flate.max_window_len,
        .zstd => std.compress.zstd.default_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };

    const decompress_buffer = try allocator.alloc(u8, buffer_len);
    defer allocator.free(decompress_buffer);

    var input: std.Io.Reader = .fixed(encoded_body);
    var decompress: std.http.Decompress = undefined;
    const reader = decompress.init(&input, decompress_buffer, content_encoding);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try reader.streamRemaining(&out.writer);
    if (out.written().len > MaxBufferedBodySize) return error.StreamTooLong;
    return try out.toOwnedSlice();
}

fn readBodyReaderAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = reader.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) break;
        if (out.written().len + n > MaxBufferedBodySize) return error.StreamTooLong;
        try out.writer.writeAll(buf[0..n]);
    }

    return try out.toOwnedSlice();
}

fn skipNetworkTests() bool {
    return true;
}

test "client — public request methods compile" {
    if (skipNetworkTests()) return error.SkipZigTest;

    var client = try HttpClient.init(testing.allocator, std.testing.io);
    defer client.deinit();

    const Payload = struct { ok: bool };
    var get_response = try client.fetch(testing.allocator, .{ .url = "http://127.0.0.1/" });
    defer get_response.deinit();
    _ = try client.getJson(Payload, testing.allocator, "http://127.0.0.1/");
    _ = try client.postJson(Payload, testing.allocator, "http://127.0.0.1/", Payload{ .ok = true });
}

test "client — isIdempotent" {
    try testing.expect(isIdempotent(.GET));
    try testing.expect(isIdempotent(.PUT));
    try testing.expect(isIdempotent(.DELETE));
    try testing.expect(!isIdempotent(.POST));
    try testing.expect(!isIdempotent(.PATCH));
}

test "client — isServerError" {
    try testing.expect(isServerError(@as(http.Status, @enumFromInt(500))));
    try testing.expect(isServerError(@as(http.Status, @enumFromInt(503))));
    try testing.expect(!isServerError(@as(http.Status, @enumFromInt(200))));
    try testing.expect(!isServerError(@as(http.Status, @enumFromInt(404))));
}

test "client — decompress gzip response body" {
    const compressed = try gzipForTest(testing.allocator, "hello compressed");
    defer testing.allocator.free(compressed);

    const plain = try decompressResponseBody(testing.allocator, compressed, .gzip);
    defer testing.allocator.free(plain);

    try testing.expectEqualStrings("hello compressed", plain);
}

fn gzipForTest(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(body.len + 32, 64));
    errdefer out.deinit();

    const work = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(work);

    var encoder = try std.compress.flate.Compress.init(
        &out.writer,
        work,
        .gzip,
        .default,
    );
    try encoder.writer.writeAll(body);
    try encoder.finish();
    return try out.toOwnedSlice();
}


