//! engine2.http.websocket.subprotocol — Sec-WebSocket-Protocol 협상
//!
//! RFC 6455 §4.1 / §1.9, RFC 7230 §3.2.6 (token 규칙)

const std = @import("std");
const mem = std.mem;
const ws = @import("mod.zig");

/// 클라이언트가 보낸 `Sec-WebSocket-Protocol` 헤더값을 파싱한다.
/// 콤마(`,`) 분리, 각 토큰의 OWS 트림, token 문자(rfc 7230) 검증.
pub fn parseList(header_value: []const u8, allocator: std.mem.Allocator) (error{ProtocolError, OutOfMemory}![]const []const u8) {
    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);

    var it = mem.splitScalar(u8, header_value, ',');
    while (it.next()) |token| {
        const trimmed = mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue; // skip empty
        if (!isValidToken(trimmed)) return error.ProtocolError;
        try result.append(allocator, trimmed);
    }

    return result.toOwnedSlice(allocator);
}

/// 클라이언트 offer 목록에서 서버 offer 중 첫 번째 매칭 항목을 반환한다.
/// 매칭은 대소문자 구분 (RFC 6455 §1.9: case-sensitive).
pub fn selectFromOffer(client_offer: []const []const u8, server_offer: []const []const u8) ?[]const u8 {
    for (server_offer) |srv| {
        for (client_offer) |cli| {
            if (mem.eql(u8, srv, cli)) return srv;
        }
    }
    return null;
}

/// 클라이언트 측: 서버가 응답한 subprotocol 값이 client_offer에 포함되는지 확인.
pub fn validateSelected(selected: []const u8, client_offer: []const []const u8) bool {
    for (client_offer) |offer| {
        if (mem.eql(u8, selected, offer)) return true;
    }
    return false;
}

/// `Sec-WebSocket-Protocol` 요청 헤더값 직렬화.
/// protocols가 비었으면 null 반환 (헤더 생략).
pub fn formatHeaderValue(protocols: []const []const u8, allocator: std.mem.Allocator) (error{OutOfMemory}!?[]const u8) {
    if (protocols.len == 0) return null;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (protocols, 0..) |p, i| {
        if (i > 0) try result.appendSlice(allocator, ", ");
        try result.appendSlice(allocator, p);
    }
    const owned = try result.toOwnedSlice(allocator);
    const as_const: []const u8 = owned;
    return as_const;
}

/// RFC 7230 §3.2.6 token 검증
fn isValidToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.',
        '0'...'9', 'A'...'Z', '^', '_', '`', 'a'...'z', '|', '~' => true,
        else => false,
    };
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

test "subprotocol — parseList single" {
    const allocator = testing.allocator;
    const result = try parseList("chat", allocator);
    defer allocator.free(result);
    try expectEqual(@as(usize, 1), result.len);
    try expectEqualStrings("chat", result[0]);
}

test "subprotocol — parseList multiple" {
    const allocator = testing.allocator;
    const result = try parseList("chat, superchat", allocator);
    defer allocator.free(result);
    try expectEqual(@as(usize, 2), result.len);
    try expectEqualStrings("chat", result[0]);
    try expectEqualStrings("superchat", result[1]);
}

test "subprotocol — parseList with OWS" {
    const allocator = testing.allocator;
    const result = try parseList("  chat  ,  superchat  ", allocator);
    defer allocator.free(result);
    try expectEqual(@as(usize, 2), result.len);
    try expectEqualStrings("chat", result[0]);
    try expectEqualStrings("superchat", result[1]);
}

test "subprotocol — parseList invalid token" {
    const allocator = testing.allocator;
    const result = parseList("chat, bad@protocol", allocator);
    try expect(result == error.ProtocolError);
}

test "subprotocol — selectFromOffer match" {
    const client = [_][]const u8{ "chat", "superchat" };
    const server = [_][]const u8{ "superchat", "echo" };
    const selected = selectFromOffer(&client, &server);
    try expect(selected != null);
    try expectEqualStrings("superchat", selected.?);
}

test "subprotocol — selectFromOffer no match" {
    const client = [_][]const u8{ "chat", "superchat" };
    const server = [_][]const u8{ "echo", "test" };
    try expect(selectFromOffer(&client, &server) == null);
}

test "subprotocol — validateSelected match" {
    const client = [_][]const u8{ "chat", "superchat" };
    try expect(validateSelected("chat", &client));
    try expect(!validateSelected("echo", &client));
}

test "subprotocol — formatHeaderValue" {
    const allocator = testing.allocator;
    const protocols = [_][]const u8{ "chat", "superchat" };
    const result = (try formatHeaderValue(&protocols, allocator)).?;
    defer allocator.free(result);
    try expectEqualStrings("chat, superchat", result);
}

test "subprotocol — formatHeaderValue empty" {
    const allocator = testing.allocator;
    const result = try formatHeaderValue(&.{}, allocator);
    try expect(result == null);
}
