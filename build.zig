const std = @import("std");

const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    b.setPreferredReleaseMode(std.builtin.Mode.Debug);
    const mode = b.standardReleaseOptions();

    const bin = b.addExecutable("example", "example/example.zig");
    bin.setBuildMode(mode);
    bin.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    bin.addPackage(.{
        .name = "proxy-wasm-zig-sdk",
        .path = .{ .path = "lib/lib.zig" },
    });
    bin.wasi_exec_model = .reactor;
    bin.install();

    // e2e test setup.
    var e2e_test = b.addTest("example/e2e_test.zig");
    e2e_test.setBuildMode(mode);
    e2e_test.step.dependOn(&bin.step);

    const e2e_test_setp = b.step("e2e", "Run End-to-End test with Envoy proxy");
    e2e_test_setp.dependOn(&e2e_test.step);
}
