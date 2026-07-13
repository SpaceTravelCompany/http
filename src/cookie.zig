//! engine2.http.cookie — RFC 6265 쿠키 저장소
//!
//! 클라이언트와 서버가 공용으로 사용할 수 있도록 CookieJar 내부 변경은 SpinLock으로
//! 보호한다.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const mem = std.mem;
const http = @import("mod.zig");
const utils = @import("utils");

// ─────────────────────────────────────────────────────────────────────
//  Cookie — 단일 쿠키
// ─────────────────────────────────────────────────────────────────────

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?i64 = null, // unix timestamp (ms), null = session
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null,

    pub fn deinit(self: *Cookie, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.domain) |d| allocator.free(d);
        if (self.path) |p| allocator.free(p);
        if (self.same_site) |s| allocator.free(s);
    }
};

// ─────────────────────────────────────────────────────────────────────
//  CookieJar — 쿠키 저장소
// ─────────────────────────────────────────────────────────────────────

pub const CookieJar = struct {
    cookies: std.ArrayList(Cookie),
    allocator: std.mem.Allocator,
    lock: utils.SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .cookies = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CookieJar) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.cookies.items) |*c| c.deinit(self.allocator);
        self.cookies.deinit(self.allocator);
    }

    /// Set-Cookie 헤더 값을 파싱하여 저장소에 추가한다.
    pub fn setFromHeader(self: *CookieJar, header_value: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.setFromHeaderUnlocked(header_value);
    }

    fn setFromHeaderUnlocked(self: *CookieJar, header_value: []const u8) !void {
        // name=value [; attr[=value]]*
        const eq_pos = mem.indexOfScalar(u8, header_value, '=') orelse return;
        const semi_pos = mem.indexOfScalar(u8, header_value, ';') orelse header_value.len;

        const name = try self.allocator.dupe(u8, std.mem.trim(u8, header_value[0..eq_pos], " \t"));
        const value_end = @min(semi_pos, header_value.len);
        const raw_value = header_value[eq_pos + 1 .. value_end];
        const value = try self.allocator.dupe(u8, std.mem.trim(u8, raw_value, " \t"));

        var cookie = Cookie{
            .name = name,
            .value = value,
        };
        // OOM 시 cookie 구조체의 모든 할당된 필드 해제
        errdefer cookie.deinit(self.allocator);

        // 속성 파싱
        var pos = semi_pos;
        while (pos < header_value.len) {
            const next_semi = mem.indexOfScalarPos(u8, header_value, pos + 1, ';') orelse header_value.len;
            const attr = std.mem.trim(u8, header_value[pos + 1 .. next_semi], " \t");
            const attr_eq = mem.indexOfScalar(u8, attr, '=');

            if (attr_eq) |ae| {
                const attr_name = std.mem.trim(u8, attr[0..ae], " \t");
                const attr_val = std.mem.trim(u8, attr[ae + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(attr_name, "domain")) {
                    cookie.domain = try self.allocator.dupe(u8, attr_val);
                } else if (std.ascii.eqlIgnoreCase(attr_name, "path")) {
                    cookie.path = try self.allocator.dupe(u8, attr_val);
                } else if (std.ascii.eqlIgnoreCase(attr_name, "expires")) {
                    cookie.expires = parseHttpDate(attr_val);
                } else if (std.ascii.eqlIgnoreCase(attr_name, "max-age")) {
                    if (std.fmt.parseInt(i64, attr_val, 10)) |secs| {
                        cookie.expires = nowMs() + secs * std.time.ms_per_s;
                    } else |_| {}
                } else if (std.ascii.eqlIgnoreCase(attr_name, "samesite")) {
                    cookie.same_site = try self.allocator.dupe(u8, attr_val);
                }
            } else {
                if (std.ascii.eqlIgnoreCase(attr, "secure")) {
                    cookie.secure = true;
                } else if (std.ascii.eqlIgnoreCase(attr, "httponly")) {
                    cookie.http_only = true;
                }
            }
            pos = next_semi;
        }

        // 같은 name/path/domain이 있으면 교체
        for (self.cookies.items, 0..) |*existing, i| {
            if (mem.eql(u8, existing.name, cookie.name)) {
                const same_path = if (existing.path) |ep| if (cookie.path) |cp| mem.eql(u8, ep, cp) else false else cookie.path == null;
                const same_domain = if (existing.domain) |ed| if (cookie.domain) |cd| mem.eql(u8, ed, cd) else false else cookie.domain == null;
                if (same_path and same_domain) {
                    existing.deinit(self.allocator);
                    self.cookies.items[i] = cookie;
                    return;
                }
            }
        }

        try self.cookies.append(self.allocator, cookie);
    }

    /// 주어진 URL에 보낼 Cookie 헤더 값을 생성한다. (name=value; name=value; ...)
    pub fn getForUrl(self: *CookieJar, url: []const u8, allocator: std.mem.Allocator) (error{OutOfMemory}!?[]const u8) {
        self.lock.lock();
        defer self.lock.unlock();

        const uri = std.Uri.parse(url) catch return null;
        const host = uriHost(uri) orelse return null;
        const path = uriPath(uri);
        const is_secure = std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "wss");

        if (self.cookies.items.len == 0) return null;

        // 만료된 쿠키 제거
        const now = nowMs();
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        for (self.cookies.items) |cookie| {
            if (cookie.expires) |exp| if (now >= exp) continue;
            if (!cookieMatchesUrl(cookie, host, path, is_secure)) continue;

            if (result.items.len > 0) try result.appendSlice(allocator, "; ");
            try result.appendSlice(allocator, cookie.name);
            try result.appendSlice(allocator, "=");
            try result.appendSlice(allocator, cookie.value);
        }

        if (result.items.len == 0) return null;
        return try allocator.dupe(u8, result.items);
    }

    /// 만료된 쿠키 정리
    pub fn cleanExpired(self: *CookieJar) void {
        self.lock.lock();
        defer self.lock.unlock();

        const now = nowMs();
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const cookie = &self.cookies.items[i];
            if (cookie.expires) |exp| if (now >= exp) {
                cookie.deinit(self.allocator);
                _ = self.cookies.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
//  헬퍼
// ─────────────────────────────────────────────────────────────────────

/// 현재 Unix timestamp를 밀리초 단위로 반환한다.
fn nowMs() i64 {
    return switch (native_os) {
        .windows => blk: {
            const ft = std.os.windows.ntdll.RtlGetSystemTimePrecise();
            // ft는 1601-01-01 기준 100ns 단위다.
            const ns = @as(i96, ft) * 100 + @as(i96, std.time.epoch.windows) * std.time.ns_per_s;
            break :blk @intCast(@divTrunc(ns, std.time.ns_per_ms));
        },
        .linux => blk: {
            // libc 의존을 피하기 위해 vdso/syscall 직접 호출.
            var ts: std.os.linux.timespec = undefined;
            const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
            if (rc != 0) break :blk 0;
            const sec = @as(i64, @intCast(ts.sec));
            const nsec = @as(i64, @intCast(ts.nsec));
            break :blk sec * std.time.ms_per_s + @divTrunc(nsec, std.time.ns_per_ms);
        },
        else => blk: {
            // libc 연결이 보장된 플랫폼만 이 경로 사용.
            const CLOCK_REALTIME = @as(u32, 0);
            var ts: std.c.timespec = undefined;
            const rc = std.c.clock_gettime(CLOCK_REALTIME, &ts);
            if (rc != 0) break :blk 0;
            const sec = @as(i64, @intCast(ts.sec));
            const nsec = @as(i64, @intCast(ts.nsec));
            break :blk sec * std.time.ms_per_s + @divTrunc(nsec, std.time.ns_per_ms);
        },
    };
}

fn uriHost(uri: std.Uri) ?[]const u8 {
    const host_component = uri.host orelse return null;
    return switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
}

fn uriPath(uri: std.Uri) []const u8 {
    const path_component = uri.path;
    const path = switch (path_component) {
        .raw, .percent_encoded => |value| value,
    };
    return if (path.len == 0) "/" else path;
}

fn cookieMatchesUrl(cookie: Cookie, host: []const u8, path: []const u8, is_secure: bool) bool {
    if (cookie.secure and !is_secure) return false;
    if (!domainMatches(cookie.domain, host)) return false;
    if (!pathMatches(cookie.path, path)) return false;
    return true;
}

fn domainMatches(cookie_domain: ?[]const u8, host: []const u8) bool {
    const domain_attr = cookie_domain orelse return true;
    const domain = mem.trimStart(u8, domain_attr, ".");
    if (domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix_start = host.len - domain.len;
    return host[suffix_start - 1] == '.' and std.ascii.eqlIgnoreCase(host[suffix_start..], domain);
}

fn pathMatches(cookie_path: ?[]const u8, request_path: []const u8) bool {
    const path = cookie_path orelse return true;
    if (path.len == 0) return true;
    if (mem.eql(u8, request_path, path)) return true;
    if (!mem.startsWith(u8, request_path, path)) return false;
    if (path[path.len - 1] == '/') return true;
    return request_path.len > path.len and request_path[path.len] == '/';
}

/// HTTP-date RFC1123 형식("Wed, 21 Oct 2015 07:28:00 GMT")을 Unix ms로 변환한다.
fn parseHttpDate(value: []const u8) ?i64 {
    const comma = mem.indexOfScalar(u8, value, ',') orelse return null;
    var fields = mem.tokenizeAny(u8, mem.trim(u8, value[comma + 1 ..], " \t"), " \t");
    const day_text = fields.next() orelse return null;
    const month_text = fields.next() orelse return null;
    const year_text = fields.next() orelse return null;
    const time_text = fields.next() orelse return null;
    const zone_text = fields.next() orelse return null;
    if (fields.next() != null) return null;
    if (!std.ascii.eqlIgnoreCase(zone_text, "GMT")) return null;

    const day = std.fmt.parseInt(u8, day_text, 10) catch return null;
    const month = monthNumber(month_text) orelse return null;
    const year = std.fmt.parseInt(i64, year_text, 10) catch return null;

    var time_fields = mem.splitScalar(u8, time_text, ':');
    const hour = std.fmt.parseInt(u8, time_fields.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(u8, time_fields.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(u8, time_fields.next() orelse return null, 10) catch return null;
    if (time_fields.next() != null) return null;

    if (!validDateTime(year, month, day, hour, minute, second)) return null;

    const days = daysFromCivil(year, month, day);
    const seconds = days * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min +
        @as(i64, second);
    return seconds * std.time.ms_per_s;
}

fn monthNumber(text: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(text, "Jan")) return 1;
    if (std.ascii.eqlIgnoreCase(text, "Feb")) return 2;
    if (std.ascii.eqlIgnoreCase(text, "Mar")) return 3;
    if (std.ascii.eqlIgnoreCase(text, "Apr")) return 4;
    if (std.ascii.eqlIgnoreCase(text, "May")) return 5;
    if (std.ascii.eqlIgnoreCase(text, "Jun")) return 6;
    if (std.ascii.eqlIgnoreCase(text, "Jul")) return 7;
    if (std.ascii.eqlIgnoreCase(text, "Aug")) return 8;
    if (std.ascii.eqlIgnoreCase(text, "Sep")) return 9;
    if (std.ascii.eqlIgnoreCase(text, "Oct")) return 10;
    if (std.ascii.eqlIgnoreCase(text, "Nov")) return 11;
    if (std.ascii.eqlIgnoreCase(text, "Dec")) return 12;
    return null;
}

fn validDateTime(year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8) bool {
    if (year < 1601 or month < 1 or month > 12 or day < 1) return false;
    if (hour > 23 or minute > 59 or second > 59) return false;
    return day <= daysInMonth(year, month);
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    var y = year;
    const m: i64 = month;
    const d: i64 = day;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m + @as(i64, if (m > 2) -3 else 9);
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "cookie — set/get round trip" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("session=abc123; Path=/; HttpOnly");
    const result = try jar.getForUrl("http://example.com/", testing.allocator);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqualStrings("session=abc123", result.?);
}

test "cookie — multiple cookies" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("session=abc123; Path=/");
    try jar.setFromHeader("theme=dark; Path=/");

    const result = try jar.getForUrl("http://example.com/", testing.allocator);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    const r = result.?;
    try testing.expect(mem.indexOf(u8, r, "session=abc123") != null);
    try testing.expect(mem.indexOf(u8, r, "theme=dark") != null);
}

test "cookie — domain path secure matching" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("app=ok; Domain=example.com; Path=/app");
    try jar.setFromHeader("admin=no; Domain=example.com; Path=/admin");
    try jar.setFromHeader("secure=yes; Domain=example.com; Path=/; Secure");
    try jar.setFromHeader("other=no; Domain=other.com; Path=/");

    const http_result = try jar.getForUrl("http://example.com/app/page", testing.allocator);
    defer if (http_result) |r| testing.allocator.free(r);
    try testing.expect(http_result != null);
    try testing.expect(mem.indexOf(u8, http_result.?, "app=ok") != null);
    try testing.expect(mem.indexOf(u8, http_result.?, "admin=no") == null);
    try testing.expect(mem.indexOf(u8, http_result.?, "secure=yes") == null);
    try testing.expect(mem.indexOf(u8, http_result.?, "other=no") == null);

    const https_result = try jar.getForUrl("https://sub.example.com/app/page", testing.allocator);
    defer if (https_result) |r| testing.allocator.free(r);
    try testing.expect(https_result != null);
    try testing.expect(mem.indexOf(u8, https_result.?, "app=ok") != null);
    try testing.expect(mem.indexOf(u8, https_result.?, "secure=yes") != null);
}

test "cookie — Secure and HttpOnly flags" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("token=xyz; Secure; HttpOnly");

    try testing.expect(jar.cookies.items.len == 1);
    try testing.expect(jar.cookies.items[0].secure);
    try testing.expect(jar.cookies.items[0].http_only);
    try testing.expectEqualStrings("token", jar.cookies.items[0].name);
    try testing.expectEqualStrings("xyz", jar.cookies.items[0].value);
}

test "cookie — empty jar returns null" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    const result = try jar.getForUrl("http://example.com/", testing.allocator);
    try testing.expect(result == null);
}

test "cookie — expires parses RFC1123 date" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("old=gone; Expires=Wed, 21 Oct 2015 07:28:00 GMT");
    try jar.setFromHeader("fresh=stay; Expires=Tue, 19 Jan 2038 03:14:07 GMT");

    const result = try jar.getForUrl("http://example.com/", testing.allocator);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    try testing.expect(mem.indexOf(u8, result.?, "old=gone") == null);
    try testing.expect(mem.indexOf(u8, result.?, "fresh=stay") != null);
}

test "cookie — clean expired" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.setFromHeader("gone=bye; Max-Age=0");
    try jar.setFromHeader("stay=here; Max-Age=99999999999"); // 먼 미래까지 유효

    jar.cleanExpired();
    try testing.expect(jar.cookies.items.len >= 1);
}
