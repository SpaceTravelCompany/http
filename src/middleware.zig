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
};

// ─────────────────────────────────────────────────────────────────────
//  Logger 미들웨어
// ─────────────────────────────────────────────────────────────────────

/// 요청 로깅 미들웨어. 처리 시간, 메서드, 경로, 상태 코드를 기록한다.
pub fn logger(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
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
    _ = options;
    return struct {
        fn handler(ctx: *Context, next: *const fn (ctx: *Context) anyerror!void) anyerror!void {
            // 실제 응답 헤더 설정은 ResponseWriter가 처리.
            // 여기서는 OPTIONS preflight 처리만 담당.
            if (ctx.method == .OPTIONS) {
                ctx.status = .no_content;
                return; // Preflight: 체인 종료, 204 반환
            }
            try next(ctx);
        }
    }.handler;
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
