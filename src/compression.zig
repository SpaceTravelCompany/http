//! engine2.http.compression — HTTP 응답 압축 협상/인코딩
//!
//! gzip은 Zig stdlib flate encoder를 사용한다. 현재 deps/brotli는 FreeType WOFF2
//! 디코딩용 decoder-only 빌드라 `br` 응답 인코딩은 협상 대상에서 제외한다.

const std = @import("std");
const mem = std.mem;

pub const Encoding = enum {
    identity,
    gzip,
};

pub const Result = struct {
    body: []const u8,
    encoding: Encoding,
    owned: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
    }
};

pub fn negotiate(accept_encoding: ?[]const u8) Encoding {
    const header = accept_encoding orelse return .identity;
    var best = Encoding.identity;
    var best_q: u16 = 0;
    var wildcard_q: u16 = 0;

    var it = mem.splitScalar(u8, header, ',');
    while (it.next()) |raw_token| {
        const token = mem.trim(u8, raw_token, " \t");
        if (token.len == 0) continue;

        const semi = mem.indexOfScalar(u8, token, ';') orelse token.len;
        const name = mem.trim(u8, token[0..semi], " \t");
        const q = parseQ(token[semi..]) orelse 1000;
        if (q == 0) continue;

        if (std.ascii.eqlIgnoreCase(name, "gzip")) {
            if (q > best_q) {
                best = .gzip;
                best_q = q;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "identity")) {
            best_q = @max(best_q, q);
        } else if (mem.eql(u8, name, "*")) {
            // wildcard: 명시적으로 언급되지 않은 인코딩의 fallback
            wildcard_q = @max(wildcard_q, q);
        }
    }

    // gzip이 명시적으로 선택되지 않고 wildcard q가 더 높으면 identity 유지
    if (best == .identity and best_q >= wildcard_q) return .identity;
    // wildcard q가 identity/gzip q보다 높으면 gzip 사용 (gzip이 지원된다고 가정)
    if (wildcard_q > best_q and wildcard_q > 0) return .gzip;
    return best;
}

pub fn compress(allocator: std.mem.Allocator, body: []const u8, encoding: Encoding) !Result {
    return switch (encoding) {
        .identity => .{ .body = body, .encoding = .identity, .owned = false },
        .gzip => .{
            .body = try gzip(allocator, body),
            .encoding = .gzip,
            .owned = true,
        },
    };
}

pub fn encodingName(encoding: Encoding) []const u8 {
    return switch (encoding) {
        .identity => "identity",
        .gzip => "gzip",
    };
}

fn gzip(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
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

fn parseQ(params: []const u8) ?u16 {
    if (params.len == 0) return null;
    var it = mem.splitScalar(u8, params, ';');
    while (it.next()) |raw_param| {
        const param = mem.trim(u8, raw_param, " \t");
        if (!std.ascii.startsWithIgnoreCase(param, "q=")) continue;
        return parseQValue(param[2..]);
    }
    return null;
}

fn parseQValue(value: []const u8) ?u16 {
    const trimmed = mem.trim(u8, value, " \t");
    if (mem.eql(u8, trimmed, "1")) return 1000;
    if (mem.eql(u8, trimmed, "0")) return 0;
    if (!mem.startsWith(u8, trimmed, "0.")) return null;

    var q: u16 = 0;
    var scale: u16 = 100;
    for (trimmed[2..]) |c| {
        if (c < '0' or c > '9') break;
        if (scale == 0) break;
        q += @as(u16, c - '0') * scale;
        scale /= 10;
    }
    return q;
}

const testing = std.testing;

test "compression — negotiate gzip" {
    try testing.expectEqual(Encoding.gzip, negotiate("br, gzip;q=0.8"));
    try testing.expectEqual(Encoding.identity, negotiate(null));
    try testing.expectEqual(Encoding.identity, negotiate("gzip;q=0"));
}

test "compression — gzip roundtrip" {
    const compressed = try gzip(testing.allocator, "hello hello hello");
    defer testing.allocator.free(compressed);

    var in: std.Io.Reader = .fixed(compressed);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder: std.compress.flate.Decompress = .init(&in, .gzip, &buf);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try decoder.reader.streamRemaining(&out.writer);
    try testing.expectEqualStrings("hello hello hello", out.written());
}
