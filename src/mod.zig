//! engine2.http — 공용 HTTP 타입 및 유틸리티
//!
//! `Method`, `Status`는 `std.http`에서 re-export한다.
//! `HeaderMap`는 쓰기 가능한 HTTP 헤더 저장소를 제공한다.
//! `buildUrl`은 chzzk bot URL 빌드 패턴을 포팅했다.
//! `mimeFromPath`는 파일 확장자에서 MIME 타입을 컴파일타임 룩업한다.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

// ─────────────────────────────────────────────────────────────────────
//  플랫폼 감지
// ─────────────────────────────────────────────────────────────────────

/// 네이티브(OS) 빌드인가? (wasm32-freestanding이 아닌가)
pub const is_native = builtin.os.tag != .freestanding;

// ─────────────────────────────────────────────────────────────────────
//  Re-export (std.http)
// ─────────────────────────────────────────────────────────────────────

pub const Method = std.http.Method;
pub const Status = std.http.Status;

// ─────────────────────────────────────────────────────────────────────
//  HeaderMap — HTTP 헤더 key-value 저장소 (대소문자 구분 없음)
// ─────────────────────────────────────────────────────────────────────

/// 대소문자 구분 없는 HTTP 헤더 저장소.
/// key를 소문자로 정규화하여 저장한다.
pub const HeaderMap = struct {
    entries: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return .{ .entries = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *HeaderMap) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.entries.allocator.free(key.*);
        }
        self.entries.deinit();
    }

    /// 헤더를 설정한다. key는 대소문자 구분 없이 저장된다.
    pub fn set(self: *HeaderMap, key: []const u8, value: []const u8) !void {
        const lower = try self.entries.allocator.dupe(u8, key);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        // 기존 키가 있으면: 임시 키 해제 후, 기존 entry의 value만 덮어쓴다
        if (self.entries.getPtr(lower)) |value_ptr| {
            self.entries.allocator.free(lower);
            value_ptr.* = value;
        } else {
            try self.entries.put(lower, value);
        }
    }

    /// 헤더 값을 조회한다. key는 대소문자 구분 없이 찾는다.
    pub fn get(self: *const HeaderMap, key: []const u8) ?[]const u8 {
        var lower_buf: [256]u8 = undefined;
        const lower = if (key.len <= lower_buf.len) blk: {
            for (key, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            break :blk lower_buf[0..key.len];
        } else self.entries.allocator.dupe(u8, key) catch return null;
        defer if (key.len > lower_buf.len) self.entries.allocator.free(lower);

        return self.entries.get(lower);
    }
};

// ─────────────────────────────────────────────────────────────────────
//  MIME 타입
// ─────────────────────────────────────────────────────────────────────

/// 확장자 → MIME 타입 컴파일타임 해시 룩업 테이블 (O(1))
const mime_table = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".htm", "text/html; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".js", "application/javascript; charset=utf-8" },
    .{ ".mjs", "application/javascript; charset=utf-8" },
    .{ ".json", "application/json" },
    .{ ".xml", "application/xml" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".webp", "image/webp" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".ttf", "font/ttf" },
    .{ ".otf", "font/otf" },
    .{ ".eot", "application/vnd.ms-fontobject" },
    .{ ".wasm", "application/wasm" },
    .{ ".txt", "text/plain; charset=utf-8" },
    .{ ".pdf", "application/pdf" },
    .{ ".zip", "application/zip" },
    .{ ".gz", "application/gzip" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".wav", "audio/wav" },
    .{ ".ogg", "audio/ogg" },
    .{ ".mp4", "video/mp4" },
    .{ ".webm", "video/webm" },
    .{ ".map", "application/json" },
});

/// 파일 경로에서 확장자를 추출해 MIME 타입을 반환한다.
/// 알 수 없는 확장자는 `application/octet-stream`을 반환한다.
pub fn mimeFromPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return mime_table.get(ext) orelse "application/octet-stream";
}

// ─────────────────────────────────────────────────────────────────────
//  buildUrl — URL 쿼리 파라미터 빌드
// ─────────────────────────────────────────────────────────────────────

/// chzzk bot build_url 1:1 포팅.
///
/// `buildUrl(allocator, "https://api.com/auth", .{ "clientId", "abc", "state", "xyz" })`
/// → `"https://api.com/auth?clientId=abc&state=xyz"`
///
/// `params`는 짝수 개의 `[]const u8`으로 구성된 튜플이어야 한다.
/// 인자 수가 홀수면 컴파일 에러가 발생한다.
///
/// 최적화: 먼저 최종 길이를 계산한 후 단일 할당으로 처리한다.
pub fn buildUrl(allocator: std.mem.Allocator, base: []const u8, params: anytype) ![]const u8 {
    const fields = @typeInfo(@TypeOf(params)).@"struct".fields;
    if (fields.len % 2 != 0) @compileError("buildUrl: params must be even (key-value pairs)");

    if (fields.len == 0) {
        return try allocator.dupe(u8, base);
    }

    // 1차 패스: 최종 길이 계산 (할당 없음)
    var total_len: usize = base.len + 1; // base + '?'
    {
        comptime var i: usize = 0;
        inline while (i < fields.len) : (i += 2) {
            const key = @field(params, fields[i].name);
            const value = @field(params, fields[i + 1].name);
            if (i > 0) total_len += 1; // '&'
            total_len += key.len + 1; // '='
            total_len += urlEncodedLen(value);
        }
    }

    // 단일 할당
    var buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    // 2차 패스: 버퍼 채우기
    var pos: usize = 0;
    @memcpy(buf[0..base.len], base);
    pos += base.len;
    buf[pos] = '?';
    pos += 1;

    {
        comptime var i: usize = 0;
        inline while (i < fields.len) : (i += 2) {
            const key = @field(params, fields[i].name);
            const value = @field(params, fields[i + 1].name);
            if (i > 0) {
                buf[pos] = '&';
                pos += 1;
            }
            @memcpy(buf[pos..][0..key.len], key);
            pos += key.len;
            buf[pos] = '=';
            pos += 1;
            pos += urlEncodeTo(buf[pos..], value);
        }
    }

    return buf[0..pos];
}

/// URL 인코딩된 길이 계산 (할당 없음)
fn urlEncodedLen(input: []const u8) usize {
    var len: usize = 0;
    for (input) |c| {
        len += if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') 1 else 3;
    }
    return len;
}

/// URL 인코딩하여 버퍼에 쓰고, 쓴 길이 반환
fn urlEncodeTo(buf: []u8, input: []const u8) usize {
    var idx: usize = 0;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            buf[idx] = c;
            idx += 1;
        } else {
            _ = std.fmt.bufPrint(buf[idx..], "%{X:0>2}", .{c}) catch unreachable;
            idx += 3;
        }
    }
    return idx;
}

// ─────────────────────────────────────────────────────────────────────
//  서브모듈
// ─────────────────────────────────────────────────────────────────────

pub const cookie = @import("cookie.zig");
pub const compression = @import("compression.zig");
pub const middleware = @import("middleware.zig");
pub const template = @import("template.zig");
pub const upload = @import("upload.zig");
pub const static = @import("static.zig");
pub const client = if (is_native) @import("client.zig") else @import("client_web.zig");
pub const websocket = if (is_native) @import("websocket/mod.zig") else @import("websocket_web.zig");
pub const server = if (is_native) @import("server.zig") else @import("server_stub.zig");

// web 스텁 re-export (통합 테스트에서 접근)
pub const client_web = @import("client_web.zig");
pub const websocket_web = @import("websocket_web.zig");

// 서브모듈 강제 참조 — Zig 0.16 lazy analysis에서 서브모듈 테스트 블록이
// 의미론적 분석 대상에 포함되도록 한다. 이게 없으면 `zig build test`에서
// mod.zig의 테스트만 실행되고 서브모듈의 91개 테스트는 누락된다.
comptime {
    _ = cookie;
    _ = compression;
    _ = middleware;
    _ = template;
    _ = upload;
    _ = static;
    _ = websocket;
    _ = client;
    _ = client_web;
    _ = websocket_web;
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

test "mod — buildUrl basic" {
    const allocator = std.testing.allocator;
    const url = try buildUrl(allocator, "https://api.example.com/auth", .{ "clientId", "abc", "state", "xyz" });
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.example.com/auth?clientId=abc&state=xyz", url);
}

test "mod — buildUrl no params" {
    const allocator = std.testing.allocator;
    const url = try buildUrl(allocator, "https://api.example.com/ping", .{});
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.example.com/ping", url);
}

test "mod — buildUrl single pair" {
    const allocator = std.testing.allocator;
    const url = try buildUrl(allocator, "https://api.example.com/search", .{ "q", "zig language" });
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.example.com/search?q=zig%20language", url);
}

test "mod — HeaderMap set/get" {
    var hm = HeaderMap.init(std.testing.allocator);
    defer hm.deinit();

    try hm.set("Content-Type", "application/json");
    try hm.set("X-Custom", "hello");
    try std.testing.expectEqualStrings("application/json", hm.get("content-type").?);
    try std.testing.expectEqualStrings("application/json", hm.get("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("hello", hm.get("x-custom").?);
    try std.testing.expect(hm.get("nonexistent") == null);
}

test "mod — mimeFromPath" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFromPath("index.html"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFromPath("/path/to/page.htm"));
    try std.testing.expectEqualStrings("application/json", mimeFromPath("data.json"));
    try std.testing.expectEqualStrings("image/png", mimeFromPath("image.png"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFromPath("file.unknown"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeFromPath("app.js"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeFromPath("style.css"));
}
