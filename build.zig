const std = @import("std");
const builtin = @import("builtin");

pub fn defaultTargetQuery() std.Target.Query {
    return if (builtin.target.os.tag == .windows) .{
        .abi = .msvc,
    } else .{};
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = defaultTargetQuery() });
    const optimize = b.standardOptimizeOption(.{});

    // ── utils (외부 패키지, SpinLock / ThreadPool / noOpWorker 사용) ──
    const utils_dep = b.dependency("utils", .{
        .target = target,
        .optimize = optimize,
    });
    const utils_mod = utils_dep.module("utils");

    // 패키지 모듈. 다른 프로젝트에서 `b.dependency("http", ...).module("http")`로 가져온다.
    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("utils", utils_mod);

    // test/check 스텝은 패키지 모듈을 직접 사용해 단위 테스트를 실행한다.
    const tests = b.addTest(.{
        .root_module = http_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "단위 테스트");
    test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "전체 컴파일 체크");
    check_step.dependOn(&run_tests.step);
}
