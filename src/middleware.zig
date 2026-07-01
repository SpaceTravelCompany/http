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
pub fn cors(options: CorsOptions) Middleware {
    return struct {
        fn handler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void {
            const res = ctx.res orelse return;

            // CORS 헤더 설정
            const origin = if (options.allowed_origins.len > 0 and options.allowed_origins[0].len > 0 and options.allowed_origins[0][0] != '*')
                options.allowed_origins[0]
            else
                "*";
            res.setHeader("Access-Control-Allow-Origin", origin) catch {};
            res.setHeader("Access-Control-Allow-Methods", joinWith(options.allowed_methods, ", ")) catch {};
            res.setHeader("Access-Control-Allow-Headers", joinWith(options.allowed_headers, ", ")) catch {};
            if (options.allow_credentials) {
                res.setHeader("Access-Control-Allow-Credentials", "true") catch {};
            }
            if (options.max_age) |age| {
                const age_str = std.fmt.allocPrint(res.headers.entries.allocator, "{d}", .{age}) catch return;
                defer res.headers.entries.allocator.free(age_str);
                res.setHeader("Access-Control-Max-Age", age_str) catch {};
            }

            // OPTIONS preflight → 체인 종료, 204 반환
            if (ctx.method == .OPTIONS) {
                ctx.status = .no_content;
                return;
            }
            try next(ctx);
        }
    }.handler;
}

/// 문자열 배열을 구분자로 연결. 스택 버퍼 사용 (짧은 CORS 헤더에 적합).
fn joinWith(items: []const []const u8, sep: []const u8) []const u8 {
    // 고정 버퍼 — CORS 헤더는 보통 256바이트 이내
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) {
            const copy_len = @min(sep.len, buf.len - pos);
            @memcpy(buf[pos..pos + copy_len], sep[0..copy_len]);
            pos += copy_len;
        }
        const copy_len = @min(item.len, buf.len - pos);
        @memcpy(buf[pos..pos + copy_len], item[0..copy_len]);
        pos += copy_len;
    }
    return buf[0..pos];
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;



test "middleware — cors with options" {
    const mw = cors(.{
        .allowed_origins = &.{"https://example.com"},
        .allow_credentials = true,
        .max_age = 86400,
    });
    _ = mw;
}
