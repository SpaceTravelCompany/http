//! engine2.http.upload — multipart/form-data 파일 업로드 파싱
//!
//! ## 제한
//!
//! - 최대 100MB (동시 1건만 → 메모리 DoS 방지)
//! - 스트리밍 업로드는 FUTURE

const std = @import("std");
const mem = std.mem;

/// 최대 업로드 크기 (100MB)
pub const MAX_UPLOAD_SIZE: usize = 100 * 1024 * 1024;

/// 업로드된 파일
pub const UploadedFile = struct {
    field_name: []const u8,
    filename: []const u8,
    content_type: []const u8,
    data: []const u8,

    pub fn deinit(self: *UploadedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.field_name);
        allocator.free(self.filename);
        allocator.free(self.content_type);
        allocator.free(self.data);
    }
};

/// multipart/form-data 파싱 결과
pub const MultipartResult = struct {
    files: []UploadedFile,
    fields: std.StringHashMap([]const u8),

    pub fn deinit(self: *MultipartResult, allocator: std.mem.Allocator) void {
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        self.fields.deinit();
    }
};

/// multipart/form-data 바디를 파싱한다.
///
/// `content_type`은 `multipart/form-data; boundary=...` 형식이어야 한다.
/// `body`는 raw HTTP 바디다.
pub fn parseMultipart(allocator: std.mem.Allocator, content_type: []const u8, body: []const u8) !MultipartResult {
    // boundary 추출
    const boundary = extractBoundary(content_type) orelse return error.BoundaryNotFound;
    // allocPrint 대신 스택 버퍼 (boundary는 보통 짧음, 길면 error 반환)
    var delim_buf: [256]u8 = undefined;
    const boundary_delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary}) catch {
        return error.BoundaryTooLong;
    };

    if (body.len > MAX_UPLOAD_SIZE) return error.PayloadTooLarge;

    var files = std.ArrayList(UploadedFile).empty;
    errdefer {
        for (files.items) |*f| f.deinit(allocator);
        files.deinit(allocator);
    }

    var fields = std.StringHashMap([]const u8).init(allocator);
    errdefer fields.deinit();

    // 바디를 boundary로 분할
    var pos: usize = 0;
    while (pos < body.len) {
        // 다음 boundary 찾기
        const b_start = mem.indexOfPos(u8, body, pos, boundary_delim) orelse break;

        // boundary 바로 다음부터
        var part_start = b_start + boundary_delim.len;

        // 종료 boundary(--boundary--\n) 확인
        if (mem.startsWith(u8, body[part_start..], "--")) break;
        if (part_start >= body.len) break;

        // 개행 건너뛰기
        if (part_start < body.len and body[part_start] == '\r') part_start += 1;
        if (part_start < body.len and body[part_start] == '\n') part_start += 1;

        // 다음 boundary 위치
        const next_b = mem.indexOfPos(u8, body, part_start, boundary_delim) orelse body.len;

        // part 데이터 (헤더 + 빈 줄 + 본문)
        const part_data = body[part_start..next_b];
        const header_end = mem.indexOf(u8, part_data, "\r\n\r\n") orelse mem.indexOf(u8, part_data, "\n\n") orelse continue;

        const raw_headers = part_data[0..header_end];
        const content_start = header_end + (if (mem.startsWith(u8, part_data[header_end..], "\r\n\r\n")) @as(usize, 4) else 2);
        const content = if (content_start <= part_data.len) part_data[content_start..] else "";

        // Content-Disposition 파싱
        const disposition = extractHeaderValue(raw_headers, "Content-Disposition") orelse continue;
        const field_name = extractDispositionParam(disposition, "name") orelse continue;
        const filename = extractDispositionParam(disposition, "filename");
        const content_type_value = extractHeaderValue(raw_headers, "Content-Type") orelse "application/octet-stream";

        if (filename) |fn_val| {
            // 파일 업로드
            const file = UploadedFile{
                .field_name = try allocator.dupe(u8, field_name),
                .filename = try allocator.dupe(u8, fn_val),
                .content_type = try allocator.dupe(u8, content_type_value),
                .data = try allocator.dupe(u8, content),
            };
            try files.append(allocator, file);
        } else {
            // 일반 폼 필드
            const trimmed = std.mem.trimRight(u8, content, "\r\n \t");
            try fields.put(try allocator.dupe(u8, field_name), try allocator.dupe(u8, trimmed));
        }

        pos = next_b;
    }

    return MultipartResult{
        .files = try files.toOwnedSlice(allocator),
        .fields = fields,
    };
}

/// Content-Type 헤더에서 boundary 값을 추출한다.
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const b_pos = mem.indexOf(u8, content_type, "boundary=") orelse return null;
    var start = b_pos + "boundary=".len;
    // 따옴표 처리
    if (start < content_type.len and content_type[start] == '"') {
        start += 1;
        const end = mem.indexOfScalarPos(u8, content_type, start, '"') orelse content_type.len;
        return content_type[start..end];
    }
    const end = mem.indexOfScalarPos(u8, content_type, start, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[start..end], " \t");
}

/// raw 헤더 문자열에서 특정 헤더 값을 추출한다.
fn extractHeaderValue(raw_headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = mem.splitSequence(u8, raw_headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        if (mem.eql(u8, std.mem.trimRight(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
        }
    }
    return null;
}

/// Content-Disposition 값에서 `name="value"` 파라미터를 추출한다.
fn extractDispositionParam(disposition: []const u8, param: []const u8) ?[]const u8 {
    // param="..." 패턴 찾기
    var search_buf: [128]u8 = undefined;
    if (param.len + 3 > search_buf.len) return null;
    @memcpy(search_buf[0..param.len], param);
    search_buf[param.len] = '=';
    search_buf[param.len + 1] = '"';
    const search = search_buf[0 .. param.len + 2];

    const start = mem.indexOf(u8, disposition, search) orelse return null;
    const val_start = start + search.len;
    if (val_start >= disposition.len) return null;
    const after = disposition[val_start..];
    if (mem.indexOfScalar(u8, after, '"')) |end_quote| {
        return after[0..end_quote];
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────
//  테스트
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "upload — boundary extraction" {
    const ct = "multipart/form-data; boundary=----WebKitFormBoundary";
    const b = extractBoundary(ct);
    try testing.expect(b != null);
    try testing.expectEqualStrings("----WebKitFormBoundary", b.?);
}

test "upload — quoted boundary" {
    const ct = "multipart/form-data; boundary=\"----12345\"";
    const b = extractBoundary(ct);
    try testing.expect(b != null);
    try testing.expectEqualStrings("----12345", b.?);
}

test "upload — missing boundary" {
    const ct = "text/plain";
    try testing.expect(extractBoundary(ct) == null);
}

test "upload — parseMultipart minimal" {
    const allocator = testing.allocator;
    const boundary = "boundary123";
    const body =
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "value1\r\n" ++
        "--boundary123--\r\n";

    const result = try parseMultipart(allocator, "multipart/form-data; boundary=" ++ boundary, body);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.files.len);
    try testing.expect(result.fields.get("field1") != null);
    try testing.expectEqualStrings("value1", result.fields.get("field1").?);
}

test "upload — max size exceeded" {
    const allocator = testing.allocator;
    const large_body = [_]u8{0} ** (MAX_UPLOAD_SIZE + 1);
    try testing.expectError(error.PayloadTooLarge, parseMultipart(allocator, "multipart/form-data; boundary=x", &large_body));
}
