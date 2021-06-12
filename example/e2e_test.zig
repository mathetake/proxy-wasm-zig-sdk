const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const allocator = std.heap.page_allocator;

test "Run End-to-End test with Envoy proxy" {
    try requireWasmBinary();
    const envoy = try requireRunAndWaitEnvoyStarted();
    defer _ = envoy.kill() catch unreachable;
    errdefer printFileReader(envoy.stderr.?.reader()) catch unreachable;
    try requireHttpHeaderOperations();
    try requireHttpBodyOperations();
    try requireHttpRandomAuth();
    try requireTcpDataSizeCounter();
}

const E2EError = error{
    EnvoyUnhealthy,
};

fn requireWasmBinary() !void {
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

fn requireRunAndWaitEnvoyStarted() !*std.ChildProcess {
    // Create a child process.
    const envoy_argv = [_][]const u8{ "envoy", "-c", "example/envoy.yaml", "--concurrency", "2" };
    const envoy = try std.ChildProcess.init(envoy_argv[0..], allocator);

    envoy.stdin_behavior = .Ignore;
    envoy.stdout_behavior = .Ignore;
    envoy.stderr_behavior = .Pipe;

    // Run the process.
    try envoy.spawn();
    errdefer _ = envoy.kill() catch unreachable;
    errdefer printFileReader(envoy.stderr.?.reader()) catch unreachable;

    // Check endpoints are healthy.
    for ([_][]const u8{
        "localhost:8001",
        "localhost:18000",
        "localhost:18001",
        "localhost:18002",
        "localhost:18003",
    }) |endpoint| {
        const argv = [_][]const u8{ "curl", "-s", "--head", endpoint };
        const exps = [_][]const u8{"HTTP/1.1"};
        try requireExecStdout(std.time.ns_per_ms * 100, 10, argv[0..], exps[0..]);
    }

    std.time.sleep(std.time.ns_per_s * 5);
    return envoy;
}

fn printFileReader(reader: std.fs.File.Reader) !void {
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 50 * 1024)) |line| {
        defer allocator.free(line);
        debug.print("{s}\n", .{line});
    }
}

fn requireExecStdout(comptime intervalInNanoSec: u64, comptime maxRetry: u64, argv: []const []const u8, expects: []const []const u8) !void {
    var i: u64 = 0;
    while (i < maxRetry) : (i += 1) {
        // Exec args.
        const res = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = argv });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        // Find all the expected strings.
        var j: u64 = 0;
        while (j < expects.len) : (j += 1) if (std.mem.indexOf(u8, res.stdout, expects[j]) == null) break;

        // If all found, break the loop.
        if (j == expects.len) break;
        std.time.sleep(intervalInNanoSec);
    }

    if (i == maxRetry) {
        return E2EError.EnvoyUnhealthy;
    }
}

fn requireHttpHeaderOperations() !void {
    {
        debug.print("Running shared-random-value test..\n", .{});
        const argv = [_][]const u8{ "curl", "--head", "localhost:18000/shared-random-value" };
        const exps = [_][]const u8{"shared-random-value"};
        try requireExecStdout(std.time.ns_per_ms * 1000, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running badclusters test..\n", .{});
        const argv = [_][]const u8{ "curl", "-s", "localhost:18000/badclusters" };
        const exps = [_][]const u8{"admin::127.0.0.1:8001::health_flags::healthy"};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running original headers test..\n", .{});
        const argv = [_][]const u8{ "curl", "-s", "--head", "localhost:18000?response-headers" };
        const exps = [_][]const u8{ "cache-control: no-cache, max-age=0, zig-original", "proxy-wasm: zig-sdk" };
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running force-500 test..\n", .{});
        const argv = [_][]const u8{ "curl", "-s", "--head", "localhost:18000/force-500" };
        const exps = [_][]const u8{"HTTP/1.1 500 Internal Server Error"};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running tick-count test..\n", .{});
        const argv = [_][]const u8{ "curl", "-s", "--head", "localhost:18000?tick-count" };
        const exps = [_][]const u8{"current-tick-count: "};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
}

fn requireHttpBodyOperations() !void {
    {
        debug.print("Running echo body test..\n", .{});
        const argv = [_][]const u8{ "curl", "-s", "localhost:18001/echo", "--data", "'this is my body'" };
        const exps = [_][]const u8{"this is my body"};
        try requireExecStdout(std.time.ns_per_ms * 1000, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running sha256 response body test..\n", .{});
        const argv = [_][]const u8{ "curl", "localhost:18001/stats?sha256-response" };
        const exps = [_][]const u8{"response body sha256"};
        try requireExecStdout(std.time.ns_per_ms * 1000, 50, argv[0..], exps[0..]);
    }
}

fn requireHttpRandomAuth() !void {
    const argv = [_][]const u8{ "curl", "-s", "--head", "localhost:18002" };
    {
        debug.print("Running OK under random auth..\n", .{});
        const exps = [_][]const u8{"HTTP/1.1 200 OK"};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running 403 at response..\n", .{});
        const exps = [_][]const u8{ "HTTP/1.1 403 Forbidden", "forbidden-at: response" };
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        debug.print("Running 403 at request..\n", .{});
        const exps = [_][]const u8{ "HTTP/1.1 403 Forbidden", "forbidden-at: request" };
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
}

fn requireTcpDataSizeCounter() !void {
    debug.print("Running TCP data size counter..\n", .{});
    {
        const argv = [_][]const u8{ "curl", "localhost:18003" };
        const exps = [_][]const u8{};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
    {
        const argv = [_][]const u8{ "curl", "localhost:8001/stats" };
        const exps = [_][]const u8{"zig_sdk_tcp_total_data_size:"};
        try requireExecStdout(std.time.ns_per_ms * 100, 50, argv[0..], exps[0..]);
    }
}
