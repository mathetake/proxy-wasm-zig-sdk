const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const allocator = std.heap.page_allocator;

fn ensureWasmBinary() !void {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/lib/example.wasm", .{cwd});
    defer allocator.free(wasm_path);
    const file = try std.fs.openFileAbsolute(wasm_path, .{});
    defer file.close();

    // Check Wasm header.
    var header_buf: [8]u8 = undefined;
    const read = try file.readAll(header_buf[0..]);
    assert(read == 8);

    const exp_header = [8]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    assert(std.mem.eql(u8, header_buf[0..], exp_header[0..]));
}

test "Run End-to-End test with Envoy proxy" {
    try ensureWasmBinary();
}
