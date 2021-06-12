const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const allocator = std.heap.page_allocator;

fn printFileReader(reader: std.fs.File.Reader) !void {
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 50 * 1024)) |line| {
        defer allocator.free(line);
        debug.print("{s}\n", .{line});
    }
}

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

fn runAndWaitEnvoyStarted() !*std.ChildProcess {
    // Create a child process.
    const argv = [_][]const u8{ "envoy", "-c", "example/envoy.yaml", "--concurrency", "2" };
    const envoy = try std.ChildProcess.init(argv[0..], allocator);

    envoy.stdin_behavior = .Ignore;
    envoy.stdout_behavior = .Ignore;
    envoy.stderr_behavior = .Pipe;

    // Run the process
    try envoy.spawn();
    std.time.sleep(std.time.ns_per_ms * 1000);
    errdefer printFileReader(envoy.stderr.?.reader()) catch unreachable;
    errdefer _ = envoy.kill() catch unreachable;

    // Check endpoints are healthy.
    for ([_][]const u8{ "localhost:8001", "localhost:18000", "localhost:18001", "localhost:18002" }) |endpoint| {
        var i: usize = 0;
        while (i < 100) {
            std.time.sleep(std.time.ns_per_ms * 100);

            // Exec curl (TODO: After Http client is supported in stdlib, then use it here and elsewhere in this file.)
            const argv2 = [_][]const u8{ "curl", "-s", "--head", endpoint };
            const res = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = argv2[0..] });
            defer allocator.free(res.stdout);
            defer allocator.free(res.stderr);

            // If OK, then break.
            if (std.mem.indexOf(u8, res.stdout, "HTTP/1.1 200 OK") != null)
                break;
        }

        // Envoy not healthy.
        if (i == 100) {
            std.debug.panic("endpoint {s} not healthy", .{endpoint});
        }
    }
    return envoy;
}

test "Run End-to-End test with Envoy proxy" {
    try ensureWasmBinary();
    const envoy = try runAndWaitEnvoyStarted();
    defer _ = envoy.kill() catch unreachable;
}
