//! engine2.http.server — HTTP/1.1 서버 + 라우터 + WebSocket 서버 (네이티브 전용)
//!
//! Zig `std.http.Server`는 per-connection 파서이므로,
//! TCP accept + 이벤트 루프 + 라우팅을 직접 구현한다.
//!
//! ## 사용
//!
//! ```zig
//! var server = try HttpServer.init(allocator, 8080);
//! defer server.deinit();
//!
//! try server.get("/api/hello", handler);
//! try server.use(middleware.logger);
//! try server.listen();
//! ```

const std = @import("std");
const mem = std.mem;
const http = @import("mod.zig");
const utils = @import("utils");
const websocket = @import("websocket/mod.zig");

// ─────────────────────────────────────────────────────────────────────
//  타입 정의
// ─────────────────────────────────────────────────────────────────────

/// 핸들러 함수.
/// 예외 발생 시 자동 500 + 로그
pub const Handler = *const fn (allocator: std.mem.Allocator, req: *const Request, res: *ResponseWriter) anyerror!void;

/// WebSocket 핸들러
pub const WsHandler = *const fn (allocator: std.mem.Allocator, ws: *WsConnection) anyerror!void;

/// 미들웨어 함수
pub const Middleware = http.middleware.Middleware;

/// 요청 추상화
pub const Request = struct {
    method: http.Method,
    path: []const u8,
    query: ?[]const u8,
    headers: http.HeaderMap,
    body: ?[]const u8,
};

/// 응답 빌더 (write-only)
pub const ResponseWriter = struct {
    status: http.Status = .ok,
    headers: http.HeaderMap,
    has_sent: bool = false,
    accept_encoding: ?[]const u8 = null,

    // 내부: 실제 응답 전송 대상
    server_req: ?*std.http.Server.Request = null,

    pub fn init(allocator: std.mem.Allocator) ResponseWriter {
        return .{ .headers = http.HeaderMap.init(allocator) };
    }

    pub fn deinit(self: *ResponseWriter) void {
        self.headers.deinit();
    }

    pub fn setStatus(self: *ResponseWriter, status: http.Status) void {
        self.status = status;
    }

    pub fn setHeader(self: *ResponseWriter, key: []const u8, value: []const u8) !void {
        try self.headers.set(key, value);
    }

    /// JSON 응답 전송
    pub fn json(self: *ResponseWriter, value: anytype) !void {
        const allocator = self.headers.entries.allocator;
        const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(json_str);

        try self.setHeader("Content-Type", "application/json");
        try self.send(json_str);
    }

    /// HTML 응답 전송
    pub fn html(self: *ResponseWriter, body: []const u8) !void {
        try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.send(body);
    }

    /// 응답 전송 (실제로는 내부 server_req.respond() 호출)
    pub fn send(self: *ResponseWriter, body: []const u8) !void {
        if (self.has_sent) return;
        self.has_sent = true;

        if (self.server_req) |req| {
            var compressed = try compressResponseBody(self.headers.entries.allocator, body, self.accept_encoding, &self.headers);
            defer compressed.deinit(self.headers.entries.allocator);

            const extra_headers = try self.extraHeaders();
            defer self.headers.entries.allocator.free(extra_headers);

            try req.respond(compressed.body, .{
                .status = self.status,
                .extra_headers = extra_headers,
            });
        }
    }

    fn extraHeaders(self: *ResponseWriter) ![]std.http.Header {
        const allocator = self.headers.entries.allocator;
        var items = try allocator.alloc(std.http.Header, self.headers.entries.count());
        errdefer allocator.free(items);

        var i: usize = 0;
        var it = self.headers.entries.iterator();
        while (it.next()) |entry| : (i += 1) {
            items[i] = .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
        }
        return items;
    }
};

// ─────────────────────────────────────────────────────────────────────
//  Route
// ─────────────────────────────────────────────────────────────────────

const Route = struct {
    method: http.Method,
    prefix: []const u8,
    handler: Handler,
};

const WsRoute = struct {
    prefix: []const u8,
    handler: WsHandler,
    protocol: ?[]const u8,
    max_message_size: usize,
};

const StaticRoute = struct {
    prefix: []const u8,
    server: http.static.StaticServer,
};

// ─────────────────────────────────────────────────────────────────────
//  WsOptions — ws() 등록 옵션
// ─────────────────────────────────────────────────────────────────────

pub const WsOptions = struct {
    protocol: ?[]const u8 = null,
    max_message_size: usize = websocket.max_message_size_default,
};

pub const TlsOptions = struct {
    cert_pem: []const u8,
    key_pem: []const u8,
};

pub const Http2Options = struct {
    tls: ?TlsOptions = null,
};

// ─────────────────────────────────────────────────────────────────────
//  HttpServer
// ─────────────────────────────────────────────────────────────────────

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    routes: std.ArrayList(Route),
    ws_routes: std.ArrayList(WsRoute),
    static_routes: std.ArrayList(StaticRoute),
    middlewares: std.ArrayList(Middleware),
    max_body_size: usize = 16 * 1024 * 1024, // 기본 16 MiB

    pub fn init(allocator: std.mem.Allocator, port: u16) HttpServer {
        return .{
            .allocator = allocator,
            .port = port,
            .routes = .empty,
            .ws_routes = .empty,
            .static_routes = .empty,
            .middlewares = .empty,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        for (self.routes.items) |r| self.allocator.free(r.prefix);
        self.routes.deinit(self.allocator);
        for (self.ws_routes.items) |r| {
            self.allocator.free(r.prefix);
            if (r.protocol) |p| self.allocator.free(p);
        }
        self.ws_routes.deinit(self.allocator);
        for (self.static_routes.items) |*r| {
            self.allocator.free(r.prefix);
            r.server.deinit();
        }
        self.static_routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    pub fn get(self: *HttpServer, path: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, path, handler);
    }

    pub fn post(self: *HttpServer, path: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, path, handler);
    }

    pub fn put(self: *HttpServer, path: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, path, handler);
    }

    pub fn delete(self: *HttpServer, path: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, path, handler);
    }

    fn addRoute(self: *HttpServer, method: http.Method, path: []const u8, handler: Handler) !void {
        try self.routes.append(self.allocator, .{
            .method = method,
            .prefix = try self.allocator.dupe(u8, path),
            .handler = handler,
        });
    }

    pub fn use(self: *HttpServer, mw: Middleware) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    pub fn serveStatic(self: *HttpServer, prefix: []const u8, dir: []const u8) !void {
        try self.static_routes.append(self.allocator, .{
            .prefix = try self.allocator.dupe(u8, prefix),
            .server = try http.static.StaticServer.init(self.allocator, dir),
        });
    }

    /// WebSocket 경로 등록 (subprotocol 없음)
    pub fn wsSimple(self: *HttpServer, path: []const u8, handler: WsHandler) !void {
        try self.wsOpts(path, handler, .{});
    }

    /// WebSocket 경로 등록 (옵션 지정)
    pub fn wsOpts(self: *HttpServer, path: []const u8, handler: WsHandler, opts: WsOptions) !void {
        const proto = if (opts.protocol) |p| try self.allocator.dupe(u8, p) else null;
        try self.ws_routes.append(self.allocator, .{
            .prefix = try self.allocator.dupe(u8, path),
            .handler = handler,
            .protocol = proto,
            .max_message_size = opts.max_message_size,
        });
    }

    pub fn listenTls(self: *HttpServer, opts: TlsOptions) !void {
        _ = self;
        _ = opts;
        return error.UnsupportedServerTls;
    }

    pub fn listenHttp2(self: *HttpServer, opts: Http2Options) !void {
        _ = self;
        _ = opts;
        return error.UnsupportedHttp2;
    }

    /// 이벤트 루프 시작 (blocking)
    pub fn listen(self: *HttpServer) !void {
        // Threaded Io 생성 — http.Server init과 네트워크 accept에 사용
        var threaded_io = std.Io.Threaded.init(self.allocator, .{});
        errdefer threaded_io.deinit();
        const io = threaded_io.io();

        const address = try std.Io.net.IpAddress.parse("0.0.0.0", self.port);
        var listener = try std.Io.net.IpAddress.listen(&address, io, .{
            .reuse_address = true,
        });
        defer listener.deinit(io);

        var connection_pool = utils.ThreadPool.init(
            self.allocator,
            connectionWorkerCount(),
            &utils.noOpWorker,
            null,
            &utils.noOpWorker,
            null,
        );
        defer connection_pool.deinit();
        try connection_pool.start();

        std.debug.print("[HTTP] 서버 시작: 0.0.0.0:{d}\n", .{self.port});

        // Threaded Io는 listen()이 반환할 때 해제되지만,
        // while(true) 루프이므로 실제로는 listen()이 종료되지 않는다.

        var consecutive_accept_errors: u32 = 0;
        while (true) {
            const conn = listener.accept(io) catch |err| {
                consecutive_accept_errors += 1;
                std.debug.print("[HTTP] accept error (#{d}): {}\n", .{ consecutive_accept_errors, err });
                // 연속 에러 시 백오프 (최대 1초)
                if (consecutive_accept_errors > 3) {
                    const backoff_ms = @min(@as(u64, 1000), @as(u64, 50) << @intCast(@min(consecutive_accept_errors - 4, 10)));
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
                }
                continue;
            };
            consecutive_accept_errors = 0;

            // 각 커넥션을 개별 스레드로 처리
            const ctx = try self.allocator.create(ConnContext);
            ctx.* = .{ .server = self, .conn = conn, .io = io };
            connection_pool.addTask(.{
                .proc = &handleConnectionTask,
                .data = ctx,
            });
        }
    }

    fn matchRoute(self: *HttpServer, method: http.Method, path: []const u8) ?Handler {
        var best: ?Handler = null;
        var best_len: usize = 0;

        for (self.routes.items) |route| {
            if (route.method != method) continue;
            if (pathMatchesRoutePrefix(path, route.prefix)) {
                if (route.prefix.len > best_len) {
                    best = route.handler;
                    best_len = route.prefix.len;
                }
            }
        }

        return best;
    }

    fn matchWsRoute(self: *HttpServer, path: []const u8) ?WsRoute {
        var best: ?*const WsRoute = null;
        var best_len: usize = 0;

        for (self.ws_routes.items) |*route| {
            if (pathMatchesRoutePrefix(path, route.prefix)) {
                if (route.prefix.len > best_len) {
                    best = route;
                    best_len = route.prefix.len;
                }
            }
        }

        return if (best) |b| b.* else null;
    }

    fn matchStaticRoute(self: *HttpServer, path: []const u8) ?*StaticRoute {
        var best: ?*StaticRoute = null;
        var best_len: usize = 0;

        for (self.static_routes.items) |*route| {
            if (pathMatchesRoutePrefix(path, route.prefix) and route.prefix.len > best_len) {
                best = route;
                best_len = route.prefix.len;
            }
        }

        return best;
    }

    pub fn matchWsRouteForTest(self: *HttpServer, path: []const u8) ?WsRoute {
        return self.matchWsRoute(path);
    }

    pub fn matchStaticRouteForTest(self: *HttpServer, path: []const u8) ?*StaticRoute {
        return self.matchStaticRoute(path);
    }

    fn runMiddleware(self: *HttpServer, aa: std.mem.Allocator, io: std.Io, req: *const Request, res: *ResponseWriter, handler: Handler) !void {
        const middlewares = self.middlewares.items;
        const handler_fn = handler;

        var ctx = Context{
            .method = req.method,
            .path = req.path,
            .status = .ok,
            .start_ms = 0,
            .body_size = if (req.body) |b| b.len else 0,
            .io = io,
            .res = res,
        };

        if (middlewares.len == 0) {
            try handler_fn(aa, req, res);
            return;
        }

        // 체인 실행 — Zig 0.16.0: inner fn 캡처 불가 → chain_state로 전달
        var chain = MiddlewareChainState{
            .middlewares = middlewares,
            .index = 0,
            .handler = handler_fn,
            .aa = aa,
            .req = req,
            .res = res,
        };
        ctx.chain_state = @ptrCast(&chain);
        try middlewares[0](&ctx, runNext);
    }
};

/// 미들웨어 체인 상태 (Zig 0.16.0: inner fn 대신 Context.chain_state에 저장)
const MiddlewareChainState = struct {
    middlewares: []const Middleware,
    index: usize,
    handler: Handler,
    aa: std.mem.Allocator,
    req: *const Request,
    res: *ResponseWriter,
};

/// 체인의 다음 미들웨어(또는 핸들러) 실행
fn runNext(ctx: *Context) anyerror!void {
    const chain = @as(*MiddlewareChainState, @ptrCast(@alignCast(ctx.chain_state orelse return)));
    chain.index += 1;
    if (chain.index < chain.middlewares.len) {
        try chain.middlewares[chain.index](ctx, runNext);
    } else {
        try chain.handler(chain.aa, chain.req, chain.res);
    }
}

// ─────────────────────────────────────────────────────────────────────
//  ConnContext — handleConnectionThread로 전달할 커넥션 컨텍스트
// ─────────────────────────────────────────────────────────────────────

const ConnContext = struct {
    server: *HttpServer,
    conn: std.Io.net.Stream,
    io: std.Io,
};

/// 기본 커넥션 worker 수. 최소 1개를 보장해 ThreadPool의 no-worker drop 경로를 피한다.
fn connectionWorkerCount() usize {
    return @max(std.Thread.getCpuCount() catch 1, 1);
}

fn isQuietReceiveHeadError(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.EndOfStream,
        error.Canceled,
        => true,
        else => false,
    };
}

/// ThreadPool worker entry. Task.data는 `ConnContext` 포인터다.
fn handleConnectionTask(data: ?*anyopaque) void {
    const ctx = @as(*ConnContext, @ptrCast(@alignCast(data)));
    handleConnectionThread(ctx);
}

/// 개별 HTTP 커넥션을 처리한다.
/// `listen()`에서 accept된 각 커넥션마다 ThreadPool task로 실행된다.
fn handleConnectionThread(ctx: *ConnContext) void {
    defer ctx.server.allocator.destroy(ctx);
    defer ctx.conn.close(ctx.io);

    // 요청당 ArenaAllocator — HeaderMap, body, ResponseWriter 등 모든 임시 할당 관리
    var arena = std.heap.ArenaAllocator.init(ctx.server.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;

    var stream_reader = std.Io.net.Stream.reader(ctx.conn, ctx.io, &read_buf);
    var stream_writer = std.Io.net.Stream.writer(ctx.conn, ctx.io, &write_buf);

    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    const req_head = server.receiveHead() catch |err| {
        if (isQuietReceiveHeadError(err)) return;
        std.debug.print("[HTTP] receiveHead error: {}\n", .{err});
        return;
    };

    // ── WebSocket Upgrade 확인 ──
    const upgrade = req_head.upgradeRequested();
    if (upgrade == .websocket) {
        const ws_key = upgrade.websocket orelse {
            (@constCast(&req_head)).respond("Bad Request", .{ .status = .bad_request }) catch {};
            return;
        };

        const target = splitTarget(req_head.head.target);
        const path = target.path;

        // WS 라우트 매칭
        const ws_route = ctx.server.matchWsRoute(path);
        const handler = ws_route orelse {
            (@constCast(&req_head)).respond("Bad Request", .{ .status = .bad_request }) catch {};
            return;
        };

        // Subprotocol negotiation
        var selected_protocol: ?[]const u8 = null;
        if (handler.protocol) |srv_proto| {
            // Read client's Sec-WebSocket-Protocol header
            var client_proto_list: ?[]const []const u8 = null;
            defer if (client_proto_list) |list| aa.free(list);
            {
                var it = req_head.iterateHeaders();
                while (it.next()) |hdr| {
                    if (std.ascii.eqlIgnoreCase(hdr.name, "sec-websocket-protocol")) {
                        client_proto_list = websocket.subprotocol.parseList(hdr.value, aa) catch |err| switch (err) {
                            error.ProtocolError => null,
                            else => null,
                        };
                        break;
                    }
                }
            }
            if (client_proto_list) |list| {
                const client_offer = list;
                const server_offer = [_][]const u8{srv_proto};
                if (websocket.subprotocol.selectFromOffer(client_offer, &server_offer)) |matched| {
                    selected_protocol = matched;
                }
                // If no match, selected_protocol stays null (no subprotocol)
            }
        }

        // WebSocket upgrade
        var ws_stream = websocket.server.WsStream.upgrade(aa, @constCast(&req_head), .{
            .key = ws_key,
            .protocol = selected_protocol,
            .max_message_size = handler.max_message_size,
        }, ctx.io) catch |err| {
            std.debug.print("[WS] upgrade error: {}\n", .{err});
            return;
        };

        // 핸들러 실행
        if (handler.handler(aa, &ws_stream)) {
            // success
        } else |err| {
            std.debug.print("[WS] handler error: {}\n", .{err});
        }
        // deinit은 핸들러가 호출했거나 여기서 cleanup
        // NOTE: 핸들러가 ws.deinit()을 호출하는 책임이 있음.
        // 만약 핸들러가 호출하지 않았다면 여기서 deinit이 필요하지만,
        // arena deinit이 모든 할당을 정리하므로 명시적 deinit은 safety check 용도.
        // ws_stream은 arena 할당이라 명시적 deinit을 호출해도 안전.
        ws_stream.deinit();
        return;
    }

    const method = req_head.head.method;
    const target = splitTarget(req_head.head.target);
    const path = target.path;

    // 라우트 매칭
    const route = ctx.server.matchRoute(method, path);
    const handler = route orelse {
        if (ctx.server.matchStaticRoute(path)) |static_route| {
            const static_path = staticPathForRoute(path, static_route.prefix);
            var static_result = static_route.server.serveFromIo(ctx.io, static_path) catch |err| {
                const status: http.Status = switch (err) {
                    error.PathTraversal, error.AccessDenied => .forbidden,
                    error.FileNotFound => .not_found,
                    else => .internal_server_error,
                };
                (@constCast(&req_head)).respond("", .{ .status = status }) catch {};
                return;
            };
            defer static_result.deinit();

            const extra_headers = [_]std.http.Header{
                .{ .name = "Content-Type", .value = static_result.mime_type },
                .{ .name = "ETag", .value = static_result.etag },
                .{ .name = "Last-Modified", .value = static_result.last_modified },
            };
            if (requestHeaderValue(&req_head, "if-none-match")) |if_none_match| {
                if (etagMatches(if_none_match, static_result.etag)) {
                    (@constCast(&req_head)).respond("", .{
                        .status = .not_modified,
                        .extra_headers = &extra_headers,
                    }) catch {};
                    return;
                }
            }

            var response_headers: [5]std.http.Header = undefined;
            var response_header_count: usize = 0;
            appendHeader(&response_headers, &response_header_count, "Content-Type", static_result.mime_type);
            appendHeader(&response_headers, &response_header_count, "ETag", static_result.etag);
            appendHeader(&response_headers, &response_header_count, "Last-Modified", static_result.last_modified);

            var compressed = compressStaticBody(aa, static_result.body, requestHeaderValue(&req_head, "accept-encoding"), &response_headers, &response_header_count) catch |err| { std.debug.print("compress error: {}\n", .{err}); return; };
            defer compressed.deinit(aa);

            (@constCast(&req_head)).respond(compressed.body, .{
                .status = .ok,
                .extra_headers = response_headers[0..response_header_count],
            }) catch {};
            return;
        }
        (@constCast(&req_head)).respond("", .{ .status = .not_found }) catch {};
        return;
    };

    // Request 생성 — 모든 할당은 arena에서 (개별 deinit 불필요)
    var headers = http.HeaderMap.init(aa);
    {
        var it = req_head.iterateHeaders();
        while (it.next()) |hdr| {
            headers.set(hdr.name, hdr.value) catch |err| {
                std.debug.print("[HTTP] header parse error: {}\n", .{err});
                (@constCast(&req_head)).respond("Internal Server Error", .{ .status = .internal_server_error }) catch {};
                return;
            };
        }
    }

    var body_buf: [8192]u8 = undefined;
    var body_reader = (@constCast(&req_head)).readerExpectNone(&body_buf);
    const body = body_reader.allocRemaining(aa, .limited(ctx.server.max_body_size)) catch |err| {
        std.debug.print("[HTTP] body read error: {}\n", .{err});
        return;
    };

    var req = Request{
        .method = method,
        .path = path,
        .query = target.query,
        .headers = headers,
        .body = if (body.len > 0) body else null,
    };

    var res = ResponseWriter.init(aa);
    res.server_req = @constCast(&req_head);
    res.accept_encoding = headers.get("accept-encoding");

    // 미들웨어 체인 실행 → handler 호출 (handler에 aa 전달)
    ctx.server.runMiddleware(aa, ctx.io, &req, &res, handler) catch {
        std.debug.print("[HTTP] handler error for {s} {s}\n", .{ @tagName(method), path });
        if (!res.has_sent) {
            (@constCast(&req_head)).respond("Internal Server Error", .{ .status = .internal_server_error }) catch {};
        }
    };
    // arena.deinit()이 모든 할당(headers, body, res, handler 임시)을 한 번에 해제
}

const TargetParts = struct {
    path: []const u8,
    query: ?[]const u8,
};

fn splitTarget(target: []const u8) TargetParts {
    const query_start = mem.indexOfScalar(u8, target, '?') orelse {
        return .{
            .path = if (target.len == 0) "/" else target,
            .query = null,
        };
    };
    const path = target[0..query_start];
    const query = target[query_start + 1 ..];
    return .{
        .path = if (path.len == 0) "/" else path,
        .query = query,
    };
}

fn pathMatchesRoutePrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or mem.eql(u8, prefix, "/")) return true;
    if (!mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn staticPathForRoute(path: []const u8, prefix: []const u8) []const u8 {
    if (prefix.len == 0 or mem.eql(u8, prefix, "/")) return path;
    const rest = path[prefix.len..];
    return if (rest.len == 0) "/" else rest;
}

fn requestHeaderValue(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return mem.trim(u8, header.value, " \t");
    }
    return null;
}

fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    var it = mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw_tag| {
        const tag = mem.trim(u8, raw_tag, " \t");
        if (mem.eql(u8, tag, "*") or mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

fn compressResponseBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    accept_encoding: ?[]const u8,
    headers: *http.HeaderMap,
) !http.compression.Result {
    if (body.len == 0 or headers.get("content-encoding") != null) {
        return .{ .body = body, .encoding = .identity, .owned = false };
    }

    const encoding = http.compression.negotiate(accept_encoding);
    var compressed = try http.compression.compress(allocator, body, encoding);
    errdefer compressed.deinit(allocator);

    if (compressed.encoding != .identity) {
        try headers.set("Content-Encoding", http.compression.encodingName(compressed.encoding));
        try headers.set("Vary", "Accept-Encoding");
    }
    return compressed;
}

fn compressStaticBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    accept_encoding: ?[]const u8,
    headers: *[5]std.http.Header,
    header_count: *usize,
) !http.compression.Result {
    if (body.len == 0) return .{ .body = body, .encoding = .identity, .owned = false };

    var compressed = try http.compression.compress(allocator, body, http.compression.negotiate(accept_encoding));
    errdefer compressed.deinit(allocator);

    if (compressed.encoding != .identity) {
        appendHeader(headers, header_count, "Content-Encoding", http.compression.encodingName(compressed.encoding));
        appendHeader(headers, header_count, "Vary", "Accept-Encoding");
    }
    return compressed;
}

fn appendHeader(headers: *[5]std.http.Header, count: *usize, name: []const u8, value: []const u8) void {
    if (count.* >= headers.len) return;
    headers[count.*] = .{ .name = name, .value = value };
    count.* += 1;
}

// ─────────────────────────────────────────────────────────────────────
//  WebSocket 타입 re-export (native only)
// ─────────────────────────────────────────────────────────────────────

/// WebSocket 연결. 서버 핸들러에 전달된다.
pub const WsConnection = websocket.server.WsStream;
/// WebSocket opcode
pub const WsOpcode = websocket.Opcode;
/// WebSocket 메시지
pub const WsMessage = websocket.Message;
/// Close code
pub const WsCloseCode = websocket.CloseCode;

// ─────────────────────────────────────────────────────────────────────
//  Context (미들웨어용)
// ─────────────────────────────────────────────────────────────────────

pub const Context = http.middleware.Context;

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testHandler(allocator: std.mem.Allocator, req: *const Request, res: *ResponseWriter) anyerror!void {
    _ = allocator;
    _ = req;
    try res.json(.{ .status = "ok" });
}

fn testWsHandler(allocator: std.mem.Allocator, ws: *WsConnection) anyerror!void {
    _ = allocator;
    _ = ws;
}

test "server — init/deinit" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();
    try testing.expect(srv.port == 8080);
}

test "server — route registration" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.get("/api/hello", testHandler);
    try srv.post("/api/data", testHandler);

    try testing.expect(srv.routes.items.len == 2);
}

test "server — matchRoute" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.get("/api", testHandler);
    try srv.get("/api/hello", testHandler);

    const h1 = srv.matchRoute(.GET, "/api/hello");
    try testing.expect(h1 != null);

    const h2 = srv.matchRoute(.GET, "/api");
    try testing.expect(h2 != null);

    const h3 = srv.matchRoute(.GET, "/nonexistent");
    try testing.expect(h3 == null);
}

test "server — splitTarget parses query" {
    const with_query = splitTarget("/api/items?limit=10&cursor=abc");
    try testing.expectEqualStrings("/api/items", with_query.path);
    try testing.expectEqualStrings("limit=10&cursor=abc", with_query.query.?);

    const without_query = splitTarget("/api/items");
    try testing.expectEqualStrings("/api/items", without_query.path);
    try testing.expect(without_query.query == null);

    const root_query = splitTarget("?health=1");
    try testing.expectEqualStrings("/", root_query.path);
    try testing.expectEqualStrings("health=1", root_query.query.?);
}

test "server — middleware registration" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.use(http.middleware.logger);

    try testing.expect(srv.middlewares.items.len == 1);
}

test "server — static route registration" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.serveStatic("/assets", ".");

    try testing.expect(srv.static_routes.items.len == 1);
    try testing.expectEqualStrings("/assets", srv.static_routes.items[0].prefix);
    try testing.expect(srv.matchStaticRouteForTest("/assets/app.js") != null);
    try testing.expect(srv.matchStaticRouteForTest("/assets") != null);
    try testing.expect(srv.matchStaticRouteForTest("/assets2/app.js") == null);
}

test "server — static route path mapping" {
    try testing.expect(pathMatchesRoutePrefix("/assets/app.js", "/assets"));
    try testing.expect(!pathMatchesRoutePrefix("/assets2/app.js", "/assets"));
    try testing.expectEqualStrings("/app.js", staticPathForRoute("/assets/app.js", "/assets"));
    try testing.expectEqualStrings("/", staticPathForRoute("/assets", "/assets"));
    try testing.expectEqualStrings("/index.html", staticPathForRoute("/index.html", "/"));
}

test "server — etag matching" {
    try testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try testing.expect(etagMatches("\"old\", \"abc\"", "\"abc\""));
    try testing.expect(etagMatches("*", "\"abc\""));
    try testing.expect(!etagMatches("\"other\"", "\"abc\""));
}

test "server — ResponseWriter init/deinit" {
    var rw = ResponseWriter.init(testing.allocator);
    defer rw.deinit();

    rw.setStatus(.ok);
    try rw.setHeader("X-Custom", "test");
}

test "server — ResponseWriter converts headers" {
    var rw = ResponseWriter.init(testing.allocator);
    defer rw.deinit();

    try rw.setHeader("X-Custom", "test");
    try rw.setHeader("Content-Type", "text/plain");

    const headers = try rw.extraHeaders();
    defer testing.allocator.free(headers);

    try testing.expect(headers.len == 2);
    var saw_custom = false;
    var saw_content_type = false;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-custom")) {
            saw_custom = true;
            try testing.expectEqualStrings("test", header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            saw_content_type = true;
            try testing.expectEqualStrings("text/plain", header.value);
        }
    }
    try testing.expect(saw_custom);
    try testing.expect(saw_content_type);
}

test "server — ws route registration" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.wsSimple("/echo", testWsHandler);
    try testing.expect(srv.ws_routes.items.len == 1);
}

test "server — ws route with protocol" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.wsOpts("/chat", testWsHandler, .{ .protocol = "chat" });
    try testing.expect(srv.ws_routes.items.len == 1);
    try testing.expectEqualStrings("chat", srv.ws_routes.items[0].protocol.?);
}

test "server — ws route stores max message size" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.wsOpts("/chat", testWsHandler, .{ .max_message_size = 4096 });

    try testing.expectEqual(@as(usize, 4096), srv.ws_routes.items[0].max_message_size);
}

test "server — matchWsRoute" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try srv.wsSimple("/ws", testWsHandler);
    try srv.wsSimple("/ws/echo", testWsHandler);

    const r1 = srv.matchWsRouteForTest("/ws/echo");
    try testing.expect(r1 != null);
    try testing.expect(r1.?.prefix.len > 0);

    const r2 = srv.matchWsRouteForTest("/ws");
    try testing.expect(r2 != null);

    const r3 = srv.matchWsRouteForTest("/nonexistent");
    try testing.expect(r3 == null);
}

test "server — WsOpcode value" {
    try testing.expectEqual(@as(u4, 1), @intFromEnum(WsOpcode.text));
    try testing.expectEqual(@as(u4, 8), @intFromEnum(WsOpcode.close));
}

test "server — WsCloseCode value" {
    try testing.expectEqual(@as(u16, 1000), @intFromEnum(WsCloseCode.normal));
    try testing.expectEqual(@as(u16, 1002), @intFromEnum(WsCloseCode.protocol_error));
}

test "server — unsupported TLS and HTTP/2 APIs fail explicitly" {
    var srv = HttpServer.init(testing.allocator, 8080);
    defer srv.deinit();

    try testing.expectError(error.UnsupportedServerTls, srv.listenTls(.{
        .cert_pem = "cert",
        .key_pem = "key",
    }));
    try testing.expectError(error.UnsupportedHttp2, srv.listenHttp2(.{}));
}

test "server — response compression adds headers" {
    var rw = ResponseWriter.init(testing.allocator);
    defer rw.deinit();
    rw.accept_encoding = "gzip";

    var compressed = try compressResponseBody(testing.allocator, "hello hello hello", rw.accept_encoding, &rw.headers);
    defer compressed.deinit(testing.allocator);

    try testing.expectEqual(http.compression.Encoding.gzip, compressed.encoding);
    try testing.expectEqualStrings("gzip", rw.headers.get("content-encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", rw.headers.get("vary").?);
}
