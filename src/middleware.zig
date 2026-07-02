//! engine2.http.middleware — 미들웨어 (로깅, CORS)
//!
//! `Middleware` 타입은 서버 라우터에서 체인으로 실행된다.
//! WebSocket 업그레이드 시 미들웨어 체인을 종료한다.

const std = @import("std");
const http = @import("mod.zig");

/// 미들웨어 함수 타입.
/// `next`를 호출하면 체인의 다음 미들웨어(또는 핸들러)가 실행된다.
pub const Middleware = *const fn (
    ctx: *Context,
    next: *const fn (ctx: *Context) anyerror!void,
) anyerror!void;

/// 미들웨어 컨텍스트. 서버가 요청마다 생성한다.
pub const Context = struct {
    method: http.Method,
    path: []const u8,
    status: http.Status,
    start_ns: i64, // 처리 시작 시간 (nanoseconds)
    body_size: usize,
    chain_state: ?*anyopaque = null, // 미들웨어 체인 상태 (Zig 0.16.0: inner fn 캡처 대체)
    io: std.Io, // Io 인스턴서 (logger 등에서 사용)
    res: ?*http.server.ResponseWriter = null, // 응답 빌더 (CORS 등에서 사용)
};

// ─────────────────────────────────────────────────────────────────────
//  Logger 미들웨어
// ─────────────────────────────────────────────────────────────────────

/// 요청 로깅 미들웨어. 처리 시간, 메서드, 경로, 상태 코드를 기록한다.
pub fn logger(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void {
    const io = ctx.io;
    const start = std.Io.Timestamp.toMilliseconds(
        std.Io.Timestamp.now(io, .awake),
    );
    ctx.start_ns = start;
    next(ctx) catch |err| {
        ctx.status = .internal_server_error;
        std.debug.print("[HTTP] {s} {s} → {d} (error: {t})\n", .{
            @tagName(ctx.method), ctx.path, @intFromEnum(ctx.status), err,
        });
        return err;
    };
    const elapsed = std.Io.Timestamp.toMilliseconds(
        std.Io.Timestamp.now(io, .awake),
    ) - start;
    std.debug.print("[HTTP] {s} {s} → {d} ({d}ms)\n", .{
        @tagName(ctx.method), ctx.path, @intFromEnum(ctx.status), elapsed,
    });
}

// ─────────────────────────────────────────────────────────────────────
//  CORS 미들웨어
// ─────────────────────────────────────────────────────────────────────

pub const CorsOptions = struct {
    allowed_origins: []const []const u8 = &.{"*"},
    allowed_methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "OPTIONS" },
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization", "X-Requested-With" },
    allow_credentials: bool = false,
    max_age: ?u64 = null,
};

/// CORS 미들웨어 생성 팩토리.
pub fn cors(comptime options: CorsOptions) Middleware {
    return struct {
        const AllowedOrigin = corsAllowedOrigin(options.allowed_origins);
        const AllowedMethods = options.allowed_methods;
        const AllowedHeaders = options.allowed_headers;
        const AllowCredentials = options.allow_credentials;
        const MaxAge = options.max_age;

        fn handler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void {
            const res = ctx.res orelse return;
            const allocator = res.headers.entries.allocator;

            // CORS 헤더 설정
            try res.setHeader("Access-Control-Allow-Origin", AllowedOrigin);
            const methods = try std.mem.join(allocator, ", ", AllowedMethods);
            try res.setHeader("Access-Control-Allow-Methods", methods);
            const headers = try std.mem.join(allocator, ", ", AllowedHeaders);
            try res.setHeader("Access-Control-Allow-Headers", headers);
            if (AllowCredentials) {
                res.setHeader("Access-Control-Allow-Credentials", "true") catch {};
            }
            if (MaxAge) |age| {
                const age_str = try std.fmt.allocPrint(allocator, "{d}", .{age});
                try res.setHeader("Access-Control-Max-Age", age_str);
            }

            // OPTIONS preflight → 체인 종료, 204 반환
            if (ctx.method == .OPTIONS) {
                ctx.status = .no_content;
                res.setStatus(.no_content);
                try res.send("");
                return;
            }
            try next(ctx);
        }
    }.handler;
}

fn corsAllowedOrigin(comptime origins: []const []const u8) []const u8 {
    if (origins.len > 0 and origins[0].len > 0 and origins[0][0] != '*') {
        return origins[0];
    }
    return "*";
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testNext(ctx: *Context) anyerror!void {
    ctx.status = .accepted;
}

fn failNext(ctx: *Context) anyerror!void {
    _ = ctx;
    return error.NextCalled;
}

test "middleware — cors with options" {
    const mw = cors(.{
        .allowed_origins = &.{"https://example.com"},
        .allow_credentials = true,
        .max_age = 86400,
    });
    _ = mw;
}

test "middleware — cors sets configured headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = http.server.ResponseWriter.init(allocator);
    var ctx = Context{
        .method = .GET,
        .path = "/",
        .status = .ok,
        .start_ns = 0,
        .body_size = 0,
        .io = undefined,
        .res = &res,
    };

    const mw = cors(.{
        .allowed_origins = &.{"https://example.com"},
        .allowed_methods = &.{ "GET", "POST" },
        .allowed_headers = &.{ "Content-Type", "X-Test" },
        .allow_credentials = true,
        .max_age = 86400,
    });
    try mw(&ctx, testNext);

    try testing.expectEqual(.accepted, ctx.status);
    try testing.expectEqualStrings("https://example.com", res.headers.get("Access-Control-Allow-Origin").?);
    try testing.expectEqualStrings("GET, POST", res.headers.get("Access-Control-Allow-Methods").?);
    try testing.expectEqualStrings("Content-Type, X-Test", res.headers.get("Access-Control-Allow-Headers").?);
    try testing.expectEqualStrings("true", res.headers.get("Access-Control-Allow-Credentials").?);
    try testing.expectEqualStrings("86400", res.headers.get("Access-Control-Max-Age").?);
}

test "middleware — cors preflight ends chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var res = http.server.ResponseWriter.init(arena.allocator());
    var ctx = Context{
        .method = .OPTIONS,
        .path = "/",
        .status = .ok,
        .start_ns = 0,
        .body_size = 0,
        .io = undefined,
        .res = &res,
    };

    const mw = cors(.{});
    try mw(&ctx, failNext);

    try testing.expectEqual(.no_content, ctx.status);
    try testing.expectEqual(.no_content, res.status);
    try testing.expect(res.has_sent);
}
