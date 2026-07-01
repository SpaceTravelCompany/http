//! engine2.http.static — 정적 파일 서빙
//!
//! ## 기능
//!
//! - MIME 자동 감지 (30종, `mod.mimeFromPath` 사용)
//! - 디렉토리 인덱스 (`index.html`)
//! - `/favicon.ico` 자동 매핑
//! - 404/500 커스텀 페이지
//! - ETag/Last-Modified + If-None-Match 304 Not Modified
//! - Range 요청은 FUTURE
//!
//! ## 참고
//!
//! 파일 읽기는 `Io` 인스턴스가 필요하다. 현재는 `serveFromIo()`를 통해
//! 호출자가 Io를 전달하도록 설계한다.

const std = @import("std");
const mem = std.mem;
const http = @import("mod.zig");

pub const StaticServer = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,

    /// 404 페이지 (null이면 기본 메시지)
    not_found_page: ?[]const u8 = null,
    /// 500 페이지 (null이면 기본 메시지)
    error_page: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) !StaticServer {
        const resolved = std.fs.path.resolve(allocator, &.{root_dir}) catch try allocator.dupe(u8, root_dir);
        return .{
            .allocator = allocator,
            .root_dir = resolved,
        };
    }

    pub fn deinit(self: *StaticServer) void {
        self.allocator.free(self.root_dir);
    }

    /// Io와 함께 파일을 서빙한다.
    pub fn serveFromIo(self: *const StaticServer, io: std.Io, path: []const u8) !ServeResult {
        // 보안: path traversal 방지
        if (mem.indexOf(u8, path, "..") != null) return TraversalError.PathTraversal;
        if (mem.indexOfAny(u8, path, "\\%00") != null) return TraversalError.PathTraversal;

        const allocator = self.allocator;

        // favicon.ico 자동 매핑
        const resolved = blk: {
            if (mem.eql(u8, path, "/favicon.ico")) {
                break :blk try std.fs.path.join(allocator, &.{ self.root_dir, "favicon.ico" });
            }
            // index.html (디렉토리 인덱스)
            if (mem.endsWith(u8, path, "/") or path.len == 0) {
                const with_index = try std.fs.path.join(allocator, &.{ self.root_dir, "index.html" });
                if (fileExist(io, with_index)) break :blk with_index;
                allocator.free(with_index);
                return TraversalError.FileNotFound;
            }
            break :blk try std.fs.path.join(allocator, &.{ self.root_dir, path });
        };
        defer allocator.free(resolved);

        const stat = statFile(io, resolved) catch return TraversalError.FileNotFound;

        // 파일 읽기
        const file_content = readFileAlloc(io, allocator, resolved) catch return TraversalError.FileNotFound;
        errdefer allocator.free(file_content);

        const mime = http.mimeFromPath(resolved);
        const etag = try computeEtag(allocator, file_content);
        errdefer allocator.free(etag);
        const last_modified = try formatHttpDate(allocator, stat.mtime);
        errdefer allocator.free(last_modified);

        return ServeResult{
            .body = file_content,
            .mime_type = mime,
            .etag = etag,
            .last_modified = last_modified,
            .allocator = allocator,
        };
    }
};

pub const ServeResult = struct {
    body: []const u8,
    mime_type: []const u8,
    etag: []const u8,
    last_modified: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ServeResult) void {
        self.allocator.free(self.body);
        self.allocator.free(self.etag);
        self.allocator.free(self.last_modified);
    }
};

pub const TraversalError = error{
    PathTraversal,
    FileNotFound,
    AccessDenied,
};

// ─────────────────────────────────────────────────────────────────────
//  헬퍼
// ─────────────────────────────────────────────────────────────────────

fn fileExist(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.cwd();
    if (dir.openFile(io, path, .{})) |f| {
        f.close(io);
        return true;
    } else |_| return false;
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, allocator, .unlimited);
}

fn statFile(io: std.Io, path: []const u8) !std.Io.File.Stat {
    const dir = std.Io.Dir.cwd();
    return dir.statFile(io, path, .{});
}

fn computeEtag(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);
    const etag = try allocator.alloc(u8, hex.len + 2);
    etag[0] = '"';
    @memcpy(etag[1..][0..hex.len], &hex);
    etag[etag.len - 1] = '"';
    return etag;
}

fn formatHttpDate(allocator: std.mem.Allocator, timestamp: std.Io.Timestamp) ![]const u8 {
    const seconds = @max(timestamp.toSeconds(), 0);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const weekday = weekdayName(epoch_day.day);
    const month = monthName(month_day.month);
    return std.fmt.allocPrint(allocator, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekday,
        month_day.day_index + 1,
        month,
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn weekdayName(epoch_day: u47) []const u8 {
    return switch ((epoch_day + 4) % 7) {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        else => unreachable,
    };
}

fn monthName(month: std.time.epoch.Month) []const u8 {
    return switch (month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "static — mime detection (via mod)" {
    try testing.expectEqualStrings("text/html; charset=utf-8", http.mimeFromPath("index.html"));
    try testing.expectEqualStrings("image/png", http.mimeFromPath("image.png"));
}

test "static — path traversal detection" {
    try testing.expect(mem.indexOf(u8, "../etc/passwd", "..") != null);
    try testing.expect(mem.indexOf(u8, "/safe/path", "..") == null);
}

test "static — sha256 etag" {
    const etag = try computeEtag(testing.allocator, "hello");
    defer testing.allocator.free(etag);

    try testing.expectEqualStrings(
        "\"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824\"",
        etag,
    );
}

test "static — format Last-Modified date" {
    const date = try formatHttpDate(testing.allocator, .{ .nanoseconds = 1445412480 * std.time.ns_per_s });
    defer testing.allocator.free(date);

    try testing.expectEqualStrings("Wed, 21 Oct 2015 07:28:00 GMT", date);
}

test "static — StaticServer init/deinit" {
    var ss = try StaticServer.init(testing.allocator, "/tmp/www");
    ss.deinit();
}

test "static — serve with missing file returns error" {
    var ss = try StaticServer.init(testing.allocator, "/nonexistent_dir_xyz");
    defer ss.deinit();

    var threaded: std.Io.Threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (ss.serveFromIo(io, "/index.html")) |result| {
        var owned_result = result;
        owned_result.deinit();
        try testing.expect(false); // should have failed
    } else |_| {
        // expected error
    }
}

test "static — serve returns sha256 etag" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "index.html", .{});
    defer file.close(io);
    var write_buf: [64]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &write_buf);
    try file_writer.interface.writeAll("hello");
    try file_writer.interface.flush();

    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer testing.allocator.free(root);

    var ss = try StaticServer.init(testing.allocator, root);
    defer ss.deinit();

    var result = try ss.serveFromIo(io, "/index.html");
    defer result.deinit();

    try testing.expectEqualStrings(
        "\"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824\"",
        result.etag,
    );
    try testing.expect(result.last_modified.len > 0);
}
