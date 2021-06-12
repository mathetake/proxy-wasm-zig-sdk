const std = @import("std");

const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    b.setPreferredReleaseMode(std.builtin.Mode.Debug);
    const mode = b.standardReleaseOptions();

    const lib = b.addSharedLibrary("example", "example/example.zig", b.version(1, 0, 0));
    lib.setBuildMode(mode);
    lib.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    lib.install();
    lib.addPackage(.{
        .name = "proxy-wasm-zig-sdk",
        .path = "lib/lib.zig",
    });

    // e2e test setup.
    var e2e_test = b.addTest("example/e2e_test.zig");
    e2e_test.setBuildMode(mode);
    e2e_test.step.dependOn(&lib.step);

    const e2e_test_setp = b.step("e2e", "Run End-to-End test with Envoy proxy");
    e2e_test_setp.dependOn(&e2e_test.step);
}
