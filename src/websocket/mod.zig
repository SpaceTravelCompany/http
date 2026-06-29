//! engine2.http.websocket — RFC 6455 WebSocket 공용 모듈
//!
//! 네이티브(OS) 빌드에서만 사용한다. WASM 전용 `websocket_web.zig`와는 독립적.
//!
//! ## 구조
//!
//! - `mod.zig`      — 공용 타입 (Opcode, Message, CloseCode, CloseReason) + 서브모듈 re-export
//! - `codec.zig`    — 프레임 코덱 (maskData, generateMaskingKey, computeAcceptKey, Reader, Writer)
//! - `subprotocol.zig` — Sec-WebSocket-Protocol 파싱/선택/검증
//! - `server.zig`   — 서버 측 WsStream (std.http.Server.Request.respondWebSocket 래퍼)
//! - `client.zig`   — 클라이언트 측 WsStream (ws:// / wss://, std.http.Client 기반)

const std = @import("std");
const http = @import("../mod.zig");

// ─────────────────────────────────────────────────────────────────────
//  공용 타입
// ─────────────────────────────────────────────────────────────────────

/// WebSocket opcode (RFC 6455 §11.8)
pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

/// 완성된 text/binary 메시지.
/// 호출자는 `data`의 수명을 관리해야 한다 (`owned` 참고).
pub const Message = struct {
    data: []const u8,
    opcode: Opcode,
    /// `true`면 caller가 `allocator.free(data)` 책임.
    owned: bool,
};

/// Close code (RFC 6455 §7.4.1)
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    internal_error = 1011,
    _,
};

/// Close frame의 code + reason
pub const CloseReason = struct {
    code: CloseCode,
    reason: []const u8,
};

/// WebSocket 전용 오류 집합
pub const Error = error{
    ProtocolError,
    UnsupportedData,
    PolicyViolation,
    MessageOversize,
    InvalidCloseCode,
    InvalidUtf8,
    IncompleteFrame,
    HandshakeFailed,
    ConnectionClosed,
    WsWriteFailed,
};

/// 기본 수신 메시지 최대 크기 (16 MiB)
pub const max_message_size_default: usize = 16 * 1024 * 1024;

// ─────────────────────────────────────────────────────────────────────
//  서브모듈 re-export
// ─────────────────────────────────────────────────────────────────────

pub const codec = @import("codec.zig");
pub const subprotocol = @import("subprotocol.zig");
pub const server = @import("server.zig");
pub const client = @import("client.zig");

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "websocket — Opcode enum values" {
    try expectEqual(@as(u4, 0), @intFromEnum(Opcode.continuation));
    try expectEqual(@as(u4, 1), @intFromEnum(Opcode.text));
    try expectEqual(@as(u4, 2), @intFromEnum(Opcode.binary));
    try expectEqual(@as(u4, 8), @intFromEnum(Opcode.close));
    try expectEqual(@as(u4, 9), @intFromEnum(Opcode.ping));
    try expectEqual(@as(u4, 10), @intFromEnum(Opcode.pong));
}

test "websocket — CloseCode enum values" {
    try expectEqual(@as(u16, 1000), @intFromEnum(CloseCode.normal));
    try expectEqual(@as(u16, 1002), @intFromEnum(CloseCode.protocol_error));
    try expectEqual(@as(u16, 1009), @intFromEnum(CloseCode.message_too_big));
}

test "websocket — max_message_size_default" {
    try expectEqual(@as(usize, 16 * 1024 * 1024), max_message_size_default);
}
