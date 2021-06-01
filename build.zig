const std = @import("std");

const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    b.setPreferredReleaseMode(std.builtin.Mode.Debug);
    const mode = b.standardReleaseOptions();

    var examples = [_][2][]const u8{
        [2][]const u8{ "example", "example/example.zig" },
    };

    for (examples) |example| {
        const lib = b.addSharedLibrary(example[0], example[1], b.version(1,0,0));
        lib.setBuildMode(mode);
        lib.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
        lib.install();
        lib.addPackage(.{
            .name = "proxy-wasm-zig-sdk",
            .path = "lib/lib.zig",
        });
    }
}
