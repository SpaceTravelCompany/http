//! engine2.http.template — HTML 템플릿 엔진
//!
//! ## 지원 구문
//!
//! - `{{variable}}` — 변수 치환 (HTML escape)
//! - `{{{raw_variable}}}` — 원시 변수 치환 (escape 없음)
//! - `{% include "path" %}` — 다른 템플릿 include
//! - `{{asset "path"}}` — 에셋 경로 변환 (cdn_prefix 등)
//!
//! 반환값은 allocator로 할당되며, 호출자가 해제 책임을 진다.
//!
//! ## 사용
//!
//! ```zig
//! const html = try template.render(allocator, "<h1>{{title}}</h1>", .{ .title = "Hello" });
//! defer allocator.free(html);
//! ```

const std = @import("std");
const mem = std.mem;

/// 컴파일타임 타입 기반 템플릿 렌더링.
/// `tmpl`에서 `{{key}}` 패턴을 `vars`의 필드 값으로 치환한다.
pub fn render(allocator: std.mem.Allocator, tmpl: []const u8, vars: anytype) ![]const u8 {
    const fields = @typeInfo(@TypeOf(vars)).@"struct".fields;

    // tmpl 크기만큼 사전 할당 (치환 후 크기가 비슷하다는 가정)
    var result = try std.ArrayList(u8).initCapacity(allocator, tmpl.len);
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < tmpl.len) {
        const open = mem.indexOfPos(u8, tmpl, pos, "{{") orelse {
            try result.appendSlice(allocator, tmpl[pos..]);
            break;
        };

        try result.appendSlice(allocator, tmpl[pos..open]);

        // {{{raw}}} — 원시 치환 (escape 없음)
        if (open + 2 < tmpl.len and tmpl[open + 2] == '{') {
            pos = open + 3;
            const close = mem.indexOfPos(u8, tmpl, pos, "}}}") orelse {
                try result.appendSlice(allocator, tmpl[open..]);
                break;
            };
            const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
            pos = close + 3;

            var found = false;
            inline for (fields) |field| {
                if (mem.eql(u8, field.name, key)) {
                    const value = @field(vars, field.name);
                    try renderRawValue(allocator, &result, value, field.type);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.appendSlice(allocator, "{{{ERROR:");
                try result.appendSlice(allocator, key);
                try result.appendSlice(allocator, "}}}");
            }
            continue;
        }

        pos = open + 2;

        const close = mem.indexOfPos(u8, tmpl, pos, "}}") orelse {
            try result.appendSlice(allocator, tmpl[open..]);
            break;
        };

        const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
        pos = close + 2;

        // include / asset 구문은 그대로 삽입
        if (mem.startsWith(u8, key, "include ") or mem.startsWith(u8, key, "asset ")) {
            try result.appendSlice(allocator, key);
            continue;
        }

        var found = false;
        inline for (fields) |field| {
            if (mem.eql(u8, field.name, key)) {
                const value = @field(vars, field.name);
                try renderValue(allocator, &result, value, field.type);
                found = true;
                break;
            }
        }

        if (!found) {
            try result.appendSlice(allocator, "{{ERROR:");
            try result.appendSlice(allocator, key);
            try result.appendSlice(allocator, "}}");
        }
    }

    return result.toOwnedSlice(allocator);
}

fn renderRawValue(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: anytype, comptime T: type) !void {
    const info = @typeInfo(T);

    switch (info) {
        .int, .comptime_int => {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try result.appendSlice(allocator, s);
        },
        .float, .comptime_float => {
            var buf: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try result.appendSlice(allocator, s);
        },
        .bool => {
            try result.appendSlice(allocator, if (value) "true" else "false");
        },
        .optional => {
            if (value) |v| {
                try renderRawValue(allocator, result, v, @TypeOf(v));
            }
        },
        .pointer => {
            if (comptime isStringType(T)) {
                const slice: []const u8 = value;
                try result.appendSlice(allocator, slice);
            } else {
                try result.appendSlice(allocator, "[value]");
            }
        },
        else => {
            try result.appendSlice(allocator, "[unsupported]");
        },
    }
}

fn renderValue(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: anytype, comptime T: type) !void {
    const info = @typeInfo(T);

    switch (info) {
        .int, .comptime_int => {
            // allocPrint 대신 bufPrint — 스택 버퍼 사용
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try appendEscaped(allocator, result, s);
        },
        .float, .comptime_float => {
            var buf: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try appendEscaped(allocator, result, s);
        },
        .bool => {
            try result.appendSlice(allocator, if (value) "true" else "false");
        },
        .optional => {
            if (value) |v| {
                try renderValue(allocator, result, v, @TypeOf(v));
            }
        },
        .pointer => {
            if (comptime isStringType(T)) {
                const slice: []const u8 = value;
                try appendEscaped(allocator, result, slice);
            } else {
                try result.appendSlice(allocator, "[value]");
            }
        },
        else => {
            try result.appendSlice(allocator, "[unsupported]");
        },
    }
}

/// 런타임 StringHashMap 기반 템플릿 렌더링.
pub fn renderDynamic(allocator: std.mem.Allocator, tmpl: []const u8, vars: std.StringHashMap([]const u8)) ![]const u8 {
    // tmpl 크기만큼 사전 할당
    var result = try std.ArrayList(u8).initCapacity(allocator, tmpl.len);
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < tmpl.len) {
        const open = mem.indexOfPos(u8, tmpl, pos, "{{") orelse {
            try result.appendSlice(allocator, tmpl[pos..]);
            break;
        };

        try result.appendSlice(allocator, tmpl[pos..open]);
        pos = open + 2;

        const close = mem.indexOfPos(u8, tmpl, pos, "}}") orelse {
            try result.appendSlice(allocator, tmpl[open..]);
            break;
        };

        const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
        pos = close + 2;

        if (mem.startsWith(u8, key, "include ") or mem.startsWith(u8, key, "asset ")) {
            try result.appendSlice(allocator, key);
            continue;
        }

        if (vars.get(key)) |val| {
            try appendEscaped(allocator, &result, val);
        } else {
            try result.appendSlice(allocator, "{{ERROR:");
            try result.appendSlice(allocator, key);
            try result.appendSlice(allocator, "}}");
        }
    }

    return result.toOwnedSlice(allocator);
}

/// HTML escape 하여 result에 추가
fn appendEscaped(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&#39;"),
            else => try result.append(allocator, c),
        }
    }
}

// ── comptime template rendering ──

/// comptime HTML escape: escape된 문자열의 길이를 반환한다.
fn comptimeEscapedLen(value: []const u8) usize {
    var len: usize = 0;
    for (value) |c| {
        len += switch (c) {
            '<' => 4,
            '>' => 4,
            '&' => 5,
            '"' => 6,
            '\'' => 5,
            else => 1,
        };
    }
    return len;
}

/// comptime HTML escape: 버퍼에 escape된 문자열을 쓰고 쓴 바이트 수를 반환한다.
fn comptimeAppendEscaped(buf: []u8, value: []const u8) usize {
    var pos: usize = 0;
    for (value) |c| {
        switch (c) {
            '<' => {
                @memcpy(buf[pos..][0..4], "&lt;");
                pos += 4;
            },
            '>' => {
                @memcpy(buf[pos..][0..4], "&gt;");
                pos += 4;
            },
            '&' => {
                @memcpy(buf[pos..][0..5], "&amp;");
                pos += 5;
            },
            '"' => {
                @memcpy(buf[pos..][0..6], "&quot;");
                pos += 6;
            },
            '\'' => {
                @memcpy(buf[pos..][0..5], "&#39;");
                pos += 5;
            },
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

/// 문자열 타입(`[]const u8` 또는 `*const [N:0]u8`)인지 확인한다.
fn isStringType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size == .slice and ptr.child == u8) return true;
    if (ptr.size == .one) {
        const child = @typeInfo(ptr.child);
        if (child == .array and child.array.child == u8) return true;
    }
    return false;
}

/// comptime 값의 출력 길이를 계산한다.
/// `escaped`가 true면 HTML escape를 고려한 길이를 반환한다.
fn comptimeValueLen(comptime value: anytype, comptime escaped: bool) usize {
    const T = @typeInfo(@TypeOf(value));
    switch (T) {
        .int, .comptime_int, .float, .comptime_float => {
            return std.fmt.count("{d}", .{value});
        },
        .bool => {
            return if (value) 4 else 5;
        },
        .optional => {
            if (value) |v| {
                return comptimeValueLen(v, escaped);
            }
            return 0;
        },
        .pointer => {
            if (comptime isStringType(@TypeOf(value))) {
                const slice: []const u8 = value;
                if (escaped) return comptimeEscapedLen(slice);
                return slice.len;
            }
            return 7;
        },
        else => {
            return 13;
        },
    }
}

/// comptime: 값을 버퍼에 포맷하고 쓴 바이트 수를 반환한다.
/// `escaped`가 true면 HTML escape를 적용한다.
fn comptimeFormatValue(buf: []u8, comptime value: anytype, comptime escaped: bool) usize {
    const T = @typeInfo(@TypeOf(value));
    switch (T) {
        .int, .comptime_int, .float, .comptime_float => {
            return (std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable).len;
        },
        .bool => {
            if (value) {
                @memcpy(buf[0..4], "true");
                return 4;
            } else {
                @memcpy(buf[0..5], "false");
                return 5;
            }
        },
        .optional => {
            if (value) |v| {
                return comptimeFormatValue(buf, v, escaped);
            }
            return 0;
        },
        .pointer => {
            if (comptime isStringType(@TypeOf(value))) {
                const slice: []const u8 = value;
                if (escaped) return comptimeAppendEscaped(buf, slice);
                @memcpy(buf[0..slice.len], slice);
                return slice.len;
            }
            @memcpy(buf[0..7], "[value]");
            return 7;
        },
        else => {
            @memcpy(buf[0..13], "[unsupported]");
            return 13;
        },
    }
}

/// 템플릿의 총 출력 길이를 계산한다 (comptime).
fn countLen(comptime tmpl: []const u8, comptime vars: anytype) usize {
    const fields = @typeInfo(@TypeOf(vars)).@"struct".fields;
    var total: usize = 0;
    var pos: usize = 0;

    while (pos < tmpl.len) {
        const open = mem.indexOfPos(u8, tmpl, pos, "{{") orelse {
            total += tmpl.len - pos;
            break;
        };

        // literal before {{
        total += open - pos;
        pos = open;

        // check for {{{ (raw variable)
        if (open + 2 < tmpl.len and tmpl[open + 2] == '{') {
            pos = open + 3;
            const close = mem.indexOfPos(u8, tmpl, pos, "}}}") orelse {
                total += tmpl[open..].len;
                break;
            };
            const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
            pos = close + 3;

            // find key in vars
            var found = false;
            inline for (fields) |field| {
                if (mem.eql(u8, field.name, key)) {
                    total += comptimeValueLen(@field(vars, field.name), false);
                    found = true;
                    break;
                }
            }
            if (!found) {
                @compileError("comptimeRender: missing template key '" ++ key ++ "' (raw)");
            }
        } else {
            // {{ (escaped variable)
            pos = open + 2;
            const close = mem.indexOfPos(u8, tmpl, pos, "}}") orelse {
                total += tmpl[open..].len;
                break;
            };
            const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
            pos = close + 2;

            if (mem.startsWith(u8, key, "include ") or mem.startsWith(u8, key, "asset ")) {
                // include/asset은 comptime에서 {{...}} 전체를 literal로 보존
                total += (close + 2) - open;
            } else {
                var found = false;
                inline for (fields) |field| {
                    if (mem.eql(u8, field.name, key)) {
                        total += comptimeValueLen(@field(vars, field.name), true);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("comptimeRender: missing template key '" ++ key ++ "' (escaped)");
                }
            }
        }
    }

    return total;
}

/// 템플릿을 파싱하여 버퍼를 채운다 (comptime).
/// 쓴 바이트 수를 반환한다.
fn fillBuffer(buf: []u8, comptime tmpl: []const u8, comptime vars: anytype) usize {
    const fields = @typeInfo(@TypeOf(vars)).@"struct".fields;
    var pos: usize = 0;
    var written: usize = 0;

    while (pos < tmpl.len) {
        const open = mem.indexOfPos(u8, tmpl, pos, "{{") orelse {
            const remaining = tmpl.len - pos;
            @memcpy(buf[written..][0..remaining], tmpl[pos..]);
            written += remaining;
            break;
        };

        // copy literal before {{
        const literal_len = open - pos;
        if (literal_len > 0) {
            @memcpy(buf[written..][0..literal_len], tmpl[pos..open]);
            written += literal_len;
        }
        pos = open;

        // check for {{{ (raw)
        if (open + 2 < tmpl.len and tmpl[open + 2] == '{') {
            pos = open + 3;
            const close = mem.indexOfPos(u8, tmpl, pos, "}}}") orelse {
                const remaining = tmpl[open..].len;
                @memcpy(buf[written..][0..remaining], tmpl[open..]);
                written += remaining;
                break;
            };
            const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
            pos = close + 3;

            var found = false;
            inline for (fields) |field| {
                if (mem.eql(u8, field.name, key)) {
                    written += comptimeFormatValue(buf[written..], @field(vars, field.name), false);
                    found = true;
                    break;
                }
            }
            if (!found) unreachable;
        } else {
            // {{ (escaped)
            pos = open + 2;
            const close = mem.indexOfPos(u8, tmpl, pos, "}}") orelse {
                const remaining = tmpl[open..].len;
                @memcpy(buf[written..][0..remaining], tmpl[open..]);
                written += remaining;
                break;
            };
            const key = std.mem.trim(u8, tmpl[pos..close], " \t\r\n");
            pos = close + 2;

            if (mem.startsWith(u8, key, "include ") or mem.startsWith(u8, key, "asset ")) {
                // include/asset은 comptime에서 {{...}} 전체를 literal로 보존
                const full_len = (close + 2) - open;
                @memcpy(buf[written..][0..full_len], tmpl[open .. close + 2]);
                written += full_len;
            } else {
                var found = false;
                inline for (fields) |field| {
                    if (mem.eql(u8, field.name, key)) {
                        written += comptimeFormatValue(buf[written..], @field(vars, field.name), true);
                        found = true;
                        break;
                    }
                }
                if (!found) unreachable;
            }
        }
    }

    return written;
}

/// 컴파일타임 템플릿 렌더링.
///
/// `tmpl`에서 `{{key}}`를 `vars`의 필드 값으로 치환한다 (HTML escape 적용).
/// `{{{key}}}`는 raw 치환 (escape 없음).
/// `include`/`asset` 구문은 literal로 삽입한다.
/// 존재하지 않는 키는 `@compileError`를 발생시킨다.
///
/// 사용:
/// ```zig
/// const html = comptime comptimeRender("<h1>{{title}}</h1>", .{ .title = "Hello" });
/// ```
pub inline fn comptimeRender(comptime tmpl: []const u8, comptime vars: anytype) *const [countLen(tmpl, vars):0]u8 {
    comptime {
        @setEvalBranchQuota(10000);
        var buf: [countLen(tmpl, vars):0]u8 = undefined;
        const written = fillBuffer(&buf, tmpl, vars);
        buf[written] = 0;
        const final = buf;
        return &final;
    }
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "template — simple variable" {
    const allocator = testing.allocator;
    const result = try render(allocator, "<h1>{{title}}</h1>", .{ .title = "Hello, World!" });
    defer allocator.free(result);
    try testing.expectEqualStrings("<h1>Hello, World!</h1>", result);
}

test "template — multiple variables" {
    const allocator = testing.allocator;
    const result = try render(allocator, "{{greeting}}, {{name}}!", .{ .greeting = "Hello", .name = "Alice" });
    defer allocator.free(result);
    try testing.expectEqualStrings("Hello, Alice!", result);
}

test "template — HTML escape" {
    const allocator = testing.allocator;
    const result = try render(allocator, "<p>{{content}}</p>", .{ .content = "<script>alert('xss')</script>" });
    defer allocator.free(result);
    try testing.expectEqualStrings("<p>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;</p>", result);
}

test "template — missing variable" {
    const allocator = testing.allocator;
    const result = try render(allocator, "{{title}} {{nonexistent}}", .{ .title = "Hi" });
    defer allocator.free(result);
    try testing.expect(mem.indexOf(u8, result, "ERROR") != null);
}

test "template — dynamic render" {
    const allocator = testing.allocator;
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("name", "Bob");

    const result = try renderDynamic(allocator, "Hello, {{name}}!", vars);
    defer allocator.free(result);
    try testing.expectEqualStrings("Hello, Bob!", result);
}

test "template — int value" {
    const allocator = testing.allocator;
    const result = try render(allocator, "Count: {{count}}", .{ .count = @as(u32, 42) });
    defer allocator.free(result);
    try testing.expectEqualStrings("Count: 42", result);
}

// ── comptimeRender tests ──

test "comptimeRender — basic" {
    comptime {
        const result = comptimeRender("<h1>{{title}}</h1>", .{ .title = "Hello, World!" });
        try testing.expectEqualStrings("<h1>Hello, World!</h1>", result);
    }
}

test "comptimeRender — multiple vars" {
    comptime {
        const result = comptimeRender("{{greeting}}, {{name}}!", .{ .greeting = "Hello", .name = "Alice" });
        try testing.expectEqualStrings("Hello, Alice!", result);
    }
}

test "comptimeRender — HTML escape" {
    comptime {
        const result = comptimeRender("<p>{{content}}</p>", .{ .content = "<script>alert('xss')</script>" });
        try testing.expectEqualStrings("<p>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;</p>", result);
    }
}

test "comptimeRender — raw triple brace" {
    comptime {
        const result = comptimeRender("<div>{{{raw}}}</div>", .{ .raw = "<b>bold</b>" });
        try testing.expectEqualStrings("<div><b>bold</b></div>", result);
    }
}

test "comptimeRender — int/float/bool" {
    comptime {
        const result = comptimeRender("i={{i}} f={{f}} b={{b}}", .{
            .i = @as(comptime_int, 42),
            .f = @as(comptime_float, 3.14),
            .b = true,
        });
        try testing.expectEqualStrings("i=42 f=3.14 b=true", result);
    }
}

test "comptimeRender — optional and string pointer" {
    comptime {
        const result = comptimeRender("a={{a}} b={{b}}", .{
            .a = @as(?[]const u8, "opt"),
            .b = "sentinel",
        });
        try testing.expectEqualStrings("a=opt b=sentinel", result);
    }
}

test "comptimeRender — include/asset literal" {
    comptime {
        const result = comptimeRender("{{include \"header.html\"}} {{asset \"/img.png\"}}", .{});
        try testing.expectEqualStrings("{{include \"header.html\"}} {{asset \"/img.png\"}}", result);
    }
}

test "comptimeRender — null optional" {
    comptime {
        const result = comptimeRender("a={{a}}b={{b}}", .{
            .a = @as(?[]const u8, null),
            .b = @as(?u32, null),
        });
        try testing.expectEqualStrings("a=b=", result);
    }
}
