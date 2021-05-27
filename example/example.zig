const std = @import("std");
const proxywasm = @import("proxy-wasm-zig-sdk");
const allocator = proxywasm.allocator;
const contexts = proxywasm.contexts;
const enums = proxywasm.enums;
const hostcalls = proxywasm.hostcalls;

extern fn __wasm_call_ctors() void;

const vm_id = "ziglang_vm";

// Must behave as a WASI reactor since otherwise the program exits with proc_exit.
// That means we must NOT define "pub fn main() void" in the root of your program.
export fn _initialize() void {
    // Call the WASI-libc constructors just in case they are used somewhere.
    __wasm_call_ctors();
    // Set up the global RootContext function.
    proxywasm.setNewRootContextFunc(newRootContext);
}

// newRootContext is used for creating root contexts for
// each plugin configuration (i.e. config.configuration field in envoy.yaml).
fn newRootContext(context_id: usize) *contexts.RootContext {
    var context: *Root = allocator.create(Root) catch unreachable;
    context.init();
    return &context.root_context;
}

// PluginConfiguration is a schema of the configuration.
// We parse a given configuration in json to this.
const PluginConfiguration = struct {
    root: []const u8,
    http: []const u8,
    tcp: []const u8,
};

// We implement interfaces defined in contexts.RootContext (the fields suffixed with "Impl")
// for this "Root" type. See https://www.nmichaels.org/zig/interfaces.html for detail.
const Root = struct {
    const Self = @This();
    // Store the "implemented" contexts.RootContext.
    root_context: contexts.RootContext = undefined,

    // Store the parsed plugin configuration in onPluginStart.
    plugin_configuration: PluginConfiguration,

    // The counter metric ID for storing total data received by tcp filter.
    tcp_total_data_size_counter_metric_id: ?u32 = null,
    // The guage metric ID for storing randam values in onTick function.
    random_gauge_metric_id: ?u32 = null,
    // The counter metric ID for storing the number of onTick being called.
    tick_counter_metric_id: ?u32 = null,
    // The shared queue ID of receiving user-agents.
    user_agent_shared_queue_id: ?u32 = null,

    const tcp_total_data_size_counter_metric_name = "zig_sdk_tcp_total_data_size";
    const random_gauge_metric_name = "random_gauge";
    const tick_counter_metric_name = "on_tick_count";
    const user_agent_shared_queue_name = "user-agents";

    const random_shared_data_key = "random_data";
    const random_property_path = "random_property";

    // Initialize root_context.
    fn init(self: *Self) void {
        // TODO: If we inline this initialization as a part of default value of root_context,
        // we have "Uncaught RuntimeError: table index is out of bounds" on proxy_on_vm_start.
        // Needs investigation.
        self.root_context = contexts.RootContext{
            .onVmStartImpl = onVmStart,
            .onPluginStartImpl = onPluginStart,
            .onPluginDoneImpl = onPluginDone,
            .onDeleteImpl = onDelete,
            .newHttpContextImpl = newHttpContext,
            .newTcpContextImpl = newTcpContext,
            .onQueueReadyImpl = onQueueReady,
            .onTickImpl = onTick,
            .onHttpCalloutResponseImpl = null,
        };
    }

    // Implement types.RootContext.onVmStart.
    fn onVmStart(root_context: *contexts.RootContext, configuration_size: usize) bool {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Log the VM configuration.
        if (configuration_size > 0) {
            var configuration = hostcalls.getVmConfiguration(configuration_size) catch unreachable;
            defer configuration.deinit();
            const message = std.fmt.allocPrint(
                allocator,
                "vm configuration: {s}",
                .{configuration.raw_data},
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }
        return true;
    }

    // Implement types.RootContext.onPluginStart.
    fn onPluginStart(root_context: *contexts.RootContext, configuration_size: usize) bool {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Get plugin configuration data.
        std.debug.assert(configuration_size > 0);
        var plugin_config_data = hostcalls.getPluginConfiguration(configuration_size) catch unreachable;
        defer plugin_config_data.deinit();

        // Parse it to ConfigurationData struct.
        var stream = std.json.TokenStream.init(plugin_config_data.raw_data);
        self.plugin_configuration = std.json.parse(
            PluginConfiguration,
            &stream,
            .{ .allocator = allocator },
        ) catch unreachable;

        // Log the given and parsed configuration.
        const message = std.fmt.allocPrint(
            allocator,
            "plugin configuration: root=\"{s}\", http=\"{s}\", stream=\"{s}\"",
            .{
                self.plugin_configuration.root,
                self.plugin_configuration.http,
                self.plugin_configuration.tcp,
            },
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;

        if (std.mem.eql(u8, self.plugin_configuration.root, "singleton")) {
            // Set tick if the "root" configuration is set to "singleton".
            hostcalls.setTickPeriod(5000);

            // Register the shared queue named "user-agent-queue".
            _ = hostcalls.registerSharedQueue(user_agent_shared_queue_name) catch unreachable;
        }
        return true;
    }

    // Implement contexts.RootContext.onPluginDone.
    fn onPluginDone(root_context: *contexts.RootContext) bool {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Log the given and parsed configuration.
        const message = std.fmt.allocPrint(
            allocator,
            "shutting down the plugin with configuration: root=\"{s}\", http=\"{s}\", stream=\"{s}\"",
            .{
                self.plugin_configuration.root,
                self.plugin_configuration.http,
                self.plugin_configuration.tcp,
            },
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        return true;
    }

    // Implement contexts.RootContext.onDelete.
    fn onDelete(root_context: *contexts.RootContext) void {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Destory the configura allocated during json parsing.
        std.json.parseFree(PluginConfiguration, self.plugin_configuration, .{ .allocator = allocator });
        // Destroy myself.
        allocator.destroy(self);
    }

    // Implement contexts.RootContext.newHttpContext.
    fn newTcpContext(root_context: *contexts.RootContext, context_id: u32) ?*contexts.TcpContext {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Switch type of HcpContext based on the configuration.
        if (std.mem.eql(u8, self.plugin_configuration.tcp, "total-data-size-counter")) {
            // Initialize tick counter metric id.
            if (self.tcp_total_data_size_counter_metric_id == null) {
                self.tcp_total_data_size_counter_metric_id = hostcalls.defineMetric(
                    enums.MetricType.Counter,
                    tcp_total_data_size_counter_metric_name,
                ) catch unreachable;
            }
            // Create TCP context with TcpTotalDataSizeCounter implementation.
            var context: *TcpTotalDataSizeCounter = allocator.create(TcpTotalDataSizeCounter) catch unreachable;
            context.init(context_id, self.tcp_total_data_size_counter_metric_id.?);
            return &context.tcp_context;
        }
        return null;
    }

    // Implement contexts.RootContext.newHttpContext.
    fn newHttpContext(root_context: *contexts.RootContext, context_id: u32) ?*contexts.HttpContext {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Switch type of HttpContext based on the configuration.
        if (std.mem.eql(u8, self.plugin_configuration.http, "header-operation")) {
            // Initialize tick counter metric id.
            if (self.tick_counter_metric_id == null) {
                self.tick_counter_metric_id = hostcalls.defineMetric(enums.MetricType.Counter, tick_counter_metric_name) catch unreachable;
            }
            // Resolve the "user-agents" shared queue
            if (self.user_agent_shared_queue_id == null) {
                self.user_agent_shared_queue_id = hostcalls.resolveSharedQueue(vm_id, user_agent_shared_queue_name) catch null;
            }
            // Create HTTP context with HttpHeaderOperation implementation.
            var context: *HttpHeaderOperation = allocator.create(HttpHeaderOperation) catch unreachable;
            context.init(context_id, self.tick_counter_metric_id.?, random_shared_data_key, self.user_agent_shared_queue_id);
            return &context.http_context;
        } else if (std.mem.eql(u8, self.plugin_configuration.http, "body-operation")) {
            // Create HTTP context with HttpBodyOperation implementation.
            var context: *HttpBodyOperation = allocator.create(HttpBodyOperation) catch unreachable;
            context.init();
            return &context.http_context;
        } else if (std.mem.eql(u8, self.plugin_configuration.http, "random-auth")) {
            // Create HTTP context with HttpRandomAuth implementation.
            var context: *HttpRandomAuth = allocator.create(HttpRandomAuth) catch unreachable;
            context.init();
            return &context.http_context;
        }
        return null;
    }

    // Implement types.RootContext.onTick.
    fn onQueueReady(root_context: *contexts.RootContext, quque_id: u32) void {
        // We know that this is called for user-agents queue since that's the only queue we registered.

        // Since we are in a singleton, we can assume that this Wasm VM is the only VM to dequeue this queue.
        // So we can ignore the error returned by dequeueSharedQueue including Empty error.
        var ua = hostcalls.dequeueSharedQueue(quque_id) catch unreachable;
        defer ua.deinit();

        // Log the user-agent.
        const message = std.fmt.allocPrint(allocator, "user-agent {s} is dequeued.", .{ua.raw_data}) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }

    // Implement types.RootContext.onTick.
    fn onTick(root_context: *contexts.RootContext) void {
        const self: *Self = @fieldParentPtr(Self, "root_context", root_context);

        // Log the current timestamp.
        const message = std.fmt.allocPrint(
            allocator,
            "on tick called at {d}",
            .{std.time.nanoTimestamp()},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;

        // Initialize the metric id of the tick counter.
        if (self.tick_counter_metric_id == null) {
            self.tick_counter_metric_id = hostcalls.defineMetric(enums.MetricType.Counter, tick_counter_metric_name) catch unreachable;
        }

        // Increment the tick counter.
        hostcalls.incrementMetric(self.tick_counter_metric_id.?, 1) catch unreachable;

        // Initialize the metric id of the random gauge.
        if (self.random_gauge_metric_id == null) {
            self.random_gauge_metric_id = hostcalls.defineMetric(enums.MetricType.Gauge, random_gauge_metric_name) catch unreachable;
        }

        // Record a cryptographically secure random value on the gauge.
        var buf: [8]u8 = undefined;
        std.crypto.randomBytes(buf[0..]) catch unreachable;
        hostcalls.recordMetric(self.random_gauge_metric_id.?, std.mem.readIntLittle(u64, buf[0..])) catch unreachable;

        // Insert the random value to the shared key value store.
        hostcalls.setSharedData(random_shared_data_key, buf[0..], 0) catch unreachable;
    }
};

const TcpTotalDataSizeCounter = struct {
    const Self = @This();
    // Store the "implemented" contexts.TcpContext.
    tcp_context: contexts.TcpContext = undefined,

    context_id: u32 = undefined,
    total_data_size_counter_metric_id: u32 = undefined,

    fn init(self: *Self, context_id: u32, metric_id: u32) void {
        self.context_id = context_id;
        self.total_data_size_counter_metric_id = metric_id;
        self.tcp_context = contexts.TcpContext{
            .onNewConnectionImpl = onNewConnection,
            .onDownstreamDataImpl = onDownstreamData,
            .onDownstreamCloseImpl = onDownstreamClose,
            .onUpstreamDataImpl = onUpstreamData,
            .onUpstreamCloseImpl = onUpstreamClose,
            .onLogImpl = onLog,
            .onHttpCalloutResponseImpl = null,
            .onDeleteImpl = onDelete,
        };

        const message = std.fmt.allocPrint(
            allocator,
            "TcpTotalDataSizeCounter context created: {d}",
            .{self.context_id},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }
    // Implement types.TcpContext.onNewConnection.
    fn onNewConnection(tcp_context: *contexts.TcpContext) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        const message = std.fmt.allocPrint(
            allocator,
            "connection established: {d}",
            .{self.context_id},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        return enums.Action.Continue;
    }

    // Implement types.TcpContext.onDownstreamData.
    fn onDownstreamData(tcp_context: *contexts.TcpContext, data_size: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        // Increment the total data size counter.
        if (data_size > 0) {
            hostcalls.incrementMetric(self.total_data_size_counter_metric_id, data_size) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement types.TcpContext.onDownstreamClose.
    fn onDownstreamClose(tcp_context: *contexts.TcpContext, peer_type: enums.PeerType) void {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        // Get source addess of this connection.
        const path: [2][]const u8 = [2][]const u8{ "source", "address" };
        var source_addess = hostcalls.getProperty(path[0..]) catch unreachable;
        defer source_addess.deinit();

        // Log the downstream remote addess.
        const message = std.fmt.allocPrint(
            allocator,
            "downstream connection for peer at {s}",
            .{source_addess.raw_data},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }

    // Implement types.TcpContext.onUpstreamData.
    fn onUpstreamData(tcp_context: *contexts.TcpContext, data_size: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        // Increment the total data size counter.
        if (data_size > 0) {
            hostcalls.incrementMetric(self.total_data_size_counter_metric_id, data_size) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement types.TcpContext.onUpstreamClose.
    fn onUpstreamClose(tcp_context: *contexts.TcpContext, peer_type: enums.PeerType) void {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        // Get source addess of this connection.
        const path: [2][]const u8 = [2][]const u8{ "upstream", "address" };
        var upstream_addess = hostcalls.getProperty(path[0..]) catch unreachable;
        defer upstream_addess.deinit();

        // Log the upstream remote addess.
        const message = std.fmt.allocPrint(
            allocator,
            "upstream connection for peer at {s}",
            .{upstream_addess.raw_data},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }

    // Implement contexts.TcpContext.onLog.
    fn onLog(tcp_context: *contexts.TcpContext) void {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        const message = std.fmt.allocPrint(
            allocator,
            "tcp context {d} is at logging phase..",
            .{self.context_id},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }

    // Implement contexts.TcpContext.onDelete.
    fn onDelete(tcp_context: *contexts.TcpContext) void {
        const self: *Self = @fieldParentPtr(Self, "tcp_context", tcp_context);

        const message = std.fmt.allocPrint(
            allocator,
            "deleting tcp context {d}..",
            .{self.context_id},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;

        // Destory myself.
        allocator.destroy(self);
    }
};

const HttpHeaderOperation = struct {
    const Self = @This();
    // Store the "implemented" contexts.HttoContext.
    http_context: contexts.HttpContext = undefined,

    context_id: usize = 0,
    random_shared_data_key: []const u8 = undefined,
    request_path: hostcalls.WasmData = undefined,
    tick_counter_metric_id: u32 = 0,
    user_agent_shared_queue_id: ?u32 = null,

    // Initialize this context.
    fn init(self: *Self, context_id: usize, tick_counter_metric_id: u32, random_shared_data_key: []const u8, user_agent_queue_id: ?u32) void {
        self.context_id = context_id;
        self.tick_counter_metric_id = tick_counter_metric_id;
        self.random_shared_data_key = random_shared_data_key;
        self.user_agent_shared_queue_id = user_agent_queue_id;
        self.http_context = contexts.HttpContext{
            .onHttpRequestHeadersImpl = onHttpRequestHeaders,
            .onHttpRequestBodyImpl = null,
            .onHttpRequestTrailersImpl = onHttpRequestTrailers,
            .onHttpResponseHeadersImpl = onHttpResponseHeaders,
            .onHttpResponseBodyImpl = null,
            .onHttpResponseTrailersImpl = onHttpResponseTrailers,
            .onHttpCalloutResponseImpl = null,
            .onLogImpl = onLog,
            .onDeleteImpl = onDelete,
        };

        const message = std.fmt.allocPrint(
            allocator,
            "HttpHeaderOperation context created: {d}",
            .{self.context_id},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
    }

    // Implement contexts.HttpContext.onHttpRequestHeaders.
    fn onHttpRequestHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Get request headers.
        var headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpRequestHeaders) catch unreachable;
        defer headers.deinit();

        // Log request headers.
        var iter = headers.map.iterator();
        while (iter.next()) |entry| {
            const message = std.fmt.allocPrint(
                allocator,
                "request header: --> key: {s}, value: {s} ",
                .{ entry.key, entry.value },
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }

        // Enqueue the user-agent to the shared queue if it exits.
        if (self.user_agent_shared_queue_id) |queue_id| {
            var ua = hostcalls.getHeaderMapValue(enums.MapType.HttpRequestHeaders, "user-agent") catch unreachable;
            defer ua.deinit();
            hostcalls.enqueueSharedQueue(queue_id, ua.raw_data) catch unreachable;
            const message = std.fmt.allocPrint(
                allocator,
                "user-agent {s} queued.",
                .{ua.raw_data},
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }

        // Get the :path header value.
        self.request_path = hostcalls.getHeaderMapValue(enums.MapType.HttpRequestHeaders, ":path") catch unreachable;

        // Replace "/badclusters" -> "/clusters" to perform header replacement.
        if (std.mem.indexOf(u8, self.request_path.raw_data, "/badclusters")) |_| {
            hostcalls.replaceHeaderMapValue(enums.MapType.HttpRequestHeaders, ":path", "/clusters") catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpRequestTrailers.
    fn onHttpRequestTrailers(http_context: *contexts.HttpContext, num_trailers: usize) enums.Action {
        // Log request trailers.
        var headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpRequestTrailers) catch unreachable;
        defer headers.deinit();
        var iter = headers.map.iterator();
        while (iter.next()) |entry| {
            const message = std.fmt.allocPrint(
                allocator,
                "request trailer: --> key: {s}, value: {s} ",
                .{ entry.key, entry.value },
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpResponseHeaders.
    fn onHttpResponseHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Get response headers.
        var headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpResponseHeaders) catch unreachable;
        defer headers.deinit();

        // Log response headers.
        var iter = headers.map.iterator();
        while (iter.next()) |entry| {
            const message = std.fmt.allocPrint(
                allocator,
                "response header: <-- key: {s}, value: {s} ",
                .{ entry.key, entry.value },
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }

        if (std.mem.indexOf(u8, self.request_path.raw_data, "response-headers")) |_| {
            // Perform set_header_map and proxy_add_header_map_value
            // when the request :path contains "response-headers".
            headers.map.put("proxy-wasm", "zig-sdk") catch unreachable;
            hostcalls.setHeaderMap(enums.MapType.HttpResponseHeaders, headers.map) catch unreachable;
            hostcalls.addHeaderMapValue(enums.MapType.HttpResponseHeaders, "cache-control", " zig-original") catch unreachable;
        } else if (std.mem.indexOf(u8, self.request_path.raw_data, "force-500")) |_| {
            // Forcibly reutrn 500 status if :path contains "force-500" and remove "cache-control" header.
            hostcalls.removeHeaderMapValue(enums.MapType.HttpResponseHeaders, "cache-control") catch unreachable;
            hostcalls.replaceHeaderMapValue(enums.MapType.HttpResponseHeaders, ":status", "500") catch unreachable;
        } else if (std.mem.indexOf(u8, self.request_path.raw_data, "tick-count")) |_| {
            // Return the tick counter's value in the response header if :path contains "tick-count".
            const tick_count = hostcalls.getMetric(self.tick_counter_metric_id) catch unreachable;
            // Cast the u64 to the string.
            var buffer: [20]u8 = undefined;
            _ = std.fmt.bufPrintIntToSlice(buffer[0..], tick_count, 10, false, .{});
            // Set the stringed value in response headers.
            hostcalls.addHeaderMapValue(enums.MapType.HttpResponseHeaders, "current-tick-count", buffer[0..]) catch unreachable;
        } else if (std.mem.indexOf(u8, self.request_path.raw_data, "shared-random-value")) |_| {
            // Insert the random value in the shared data in a response header if :path contains "shared-random-value".
            var cas: u32 = undefined;
            var data = hostcalls.getSharedData(
                self.random_shared_data_key,
                &cas,
            ) catch return enums.Action.Continue;
            defer data.deinit();
            // Read the random value as u64 and format it as string.
            const value: u64 = std.mem.readIntSliceLittle(u64, data.raw_data);
            var buffer: [20]u8 = undefined;
            _ = std.fmt.bufPrintIntToSlice(buffer[0..], value, 10, false, .{});
            // Put it in the header.
            hostcalls.addHeaderMapValue(enums.MapType.HttpResponseHeaders, "shared-random-value", buffer[0..]) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpResponseTrailers.
    fn onHttpResponseTrailers(http_context: *contexts.HttpContext, num_trailers: usize) enums.Action {
        // Log response trailers.
        var headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpResponseTrailers) catch unreachable;
        defer headers.deinit();
        var iter = headers.map.iterator();
        while (iter.next()) |entry| {
            const message = std.fmt.allocPrint(
                allocator,
                "response trailer: <--- key: {s}, value: {s} ",
                .{ entry.key, entry.value },
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onLog.
    fn onLog(http_context: *contexts.HttpContext) void {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Log the upstream cluster name.
        const path: [1][]const u8 = [1][]const u8{"cluster_name"};
        var cluster_name = hostcalls.getProperty(path[0..]) catch unreachable;
        defer cluster_name.deinit();
        const address_msg = std.fmt.allocPrint(allocator, "upstream cluster: {s} ", .{cluster_name.raw_data}) catch unreachable;
        defer allocator.free(address_msg);
        hostcalls.log(enums.LogLevel.Info, address_msg) catch unreachable;

        // Log the request/response headers if :path contains "on-log-headers".
        if (std.mem.indexOf(u8, self.request_path.raw_data, "on-log-headers")) |_| {
            // Headers are all avaialable in onLog phase.
            var request_headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpRequestHeaders) catch unreachable;
            defer request_headers.deinit();
            var response_headers: hostcalls.HeaderMap = hostcalls.getHeaderMap(enums.MapType.HttpResponseHeaders) catch unreachable;
            defer response_headers.deinit();

            // Log all the request/response headers.
            var iter = request_headers.map.iterator();
            while (iter.next()) |entry| {
                const message = std.fmt.allocPrint(
                    allocator,
                    "request header on log: --> key: {s}, value: {s} ",
                    .{ entry.key, entry.value },
                ) catch unreachable;
                defer allocator.free(message);
                hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
            }
            iter = response_headers.map.iterator();
            while (iter.next()) |entry| {
                const message = std.fmt.allocPrint(
                    allocator,
                    "response header on log: <-- key: {s}, value: {s} ",
                    .{ entry.key, entry.value },
                ) catch unreachable;
                defer allocator.free(message);
                hostcalls.log(enums.LogLevel.Info, message) catch unreachable;
            }
        }
    }

    // Implement contexts.HttpContext.onDelete.
    fn onDelete(http_context: *contexts.HttpContext) void {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Destory the allocated WasmData.
        self.request_path.deinit();
        // Destory myself.
        allocator.destroy(self);
    }
};

const HttpBodyOperation = struct {
    const Self = @This();
    // Store the "implemented" contexts.HttoContext.
    http_context: contexts.HttpContext = undefined,

    request_path: hostcalls.WasmData = undefined,
    total_request_body_size: usize,
    total_response_body_size: usize,

    // Initialize this context.
    fn init(self: *Self) void {
        self.http_context = contexts.HttpContext{
            .onHttpRequestHeadersImpl = onHttpRequestHeaders,
            .onHttpRequestBodyImpl = onHttpRequestBody,
            .onHttpRequestTrailersImpl = null,
            .onHttpResponseHeadersImpl = onHttpResponseHeaders,
            .onHttpResponseBodyImpl = onHttpResponseBody,
            .onHttpResponseTrailersImpl = null,
            .onHttpCalloutResponseImpl = null,
            .onLogImpl = null,
            .onDeleteImpl = onDelete,
        };
    }

    // Implement contexts.HttpContext.onHttpRequestHeaders.
    fn onHttpRequestHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Get the :path header value.
        self.request_path = hostcalls.getHeaderMapValue(enums.MapType.HttpRequestHeaders, ":path") catch unreachable;
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpRequestBody.
    fn onHttpRequestBody(http_context: *contexts.HttpContext, body_size: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Switch based on the request path.
        // If we have "echo" in :path, then Pause and send the entire body as-is.
        if (std.mem.indexOf(u8, self.request_path.raw_data, "echo")) |_| {
            // Increment total_request_body_size to have the entire body size.
            self.total_request_body_size += body_size;

            // end_of_stream = true means that we've already seen the entire body and it is buffered in the host.
            // so retrieve the body via getBufferBytes and pass it as response body in sendLocalResponse.
            if (end_of_stream) {
                var body = hostcalls.getBufferBytes(enums.BufferType.HttpRequestbody, 0, self.total_request_body_size) catch unreachable;
                defer body.deinit();
                // Send the local response with the whole reuqest body.
                hostcalls.sendLocalResponse(200, body.raw_data, null) catch unreachable;
            }
            return enums.Action.Pause;
        }
        // Otherwise just noop.
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpResponseHeaders.
    fn onHttpResponseHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Remove Content-Length header if sha256-response, otherwise client breaks because we change the response.
        if (std.mem.indexOf(u8, self.request_path.raw_data, "sha256-response")) |_| {
            hostcalls.removeHeaderMapValue(enums.MapType.HttpResponseHeaders, "Content-Length") catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onHttpResponseBody.
    fn onHttpResponseBody(http_context: *contexts.HttpContext, body_size: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);
        if (std.mem.indexOf(u8, self.request_path.raw_data, "echo")) |_| {
            return enums.Action.Continue;
        } else if (std.mem.indexOf(u8, self.request_path.raw_data, "sha256-response")) |_| {
            // Increment total_request_body_size to have the entire body size.
            self.total_response_body_size += body_size;

            // Wait until we see the entire body.
            if (!end_of_stream) {
                return enums.Action.Pause;
            }

            // Calculate the sha256 of the entire response body.
            var body = hostcalls.getBufferBytes(enums.BufferType.HttpResponseBody, 0, self.total_response_body_size) catch unreachable;
            defer body.deinit();
            var checksum: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body.raw_data, &checksum, .{});

            // Log the calculated sha256 of response body.
            const message = std.fmt.allocPrint(
                allocator,
                "response body sha256: {x}",
                .{checksum},
            ) catch unreachable;
            defer allocator.free(message);
            hostcalls.log(enums.LogLevel.Info, message) catch unreachable;

            // Set the calculated sha256 to the response body.
            hostcalls.setBufferBytes(enums.BufferType.HttpResponseBody, 0, self.total_request_body_size, message) catch unreachable;
        }
        return enums.Action.Continue;
    }

    // Implement contexts.HttpContext.onDelete.
    fn onDelete(http_context: *contexts.HttpContext) void {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Destory myself.
        allocator.destroy(self);
    }
};

const HttpRandomAuth = struct {
    const Self = @This();
    // Store the "implemented" contexts.HttoContext.
    http_context: contexts.HttpContext = undefined,
    dispatch_request_headers: hostcalls.HeaderMap = undefined,

    request_callout_id: u32 = undefined,
    response_callout_id: u32 = undefined,

    // Initialize this context.
    fn init(self: *Self) void {
        self.http_context = contexts.HttpContext{
            .onHttpRequestHeadersImpl = onHttpRequestHeaders,
            .onHttpRequestBodyImpl = null,
            .onHttpRequestTrailersImpl = null,
            .onHttpResponseHeadersImpl = onHttpResponseHeaders,
            .onHttpResponseBodyImpl = null,
            .onHttpResponseTrailersImpl = null,
            .onHttpCalloutResponseImpl = onHttpCalloutResponse,
            .onLogImpl = null,
            .onDeleteImpl = onDelete,
        };
    }

    // Implement contexts.HttpContext.onHttpRequestHeaders.
    fn onHttpRequestHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Get the original response headers.
        self.dispatch_request_headers = hostcalls.getHeaderMap(enums.MapType.HttpRequestHeaders) catch unreachable;

        // Set the path to "/uuid" to get the random response and the method to GET
        self.dispatch_request_headers.map.put(":path", "/uuid") catch unreachable;
        self.dispatch_request_headers.map.put(":method", "GET") catch unreachable;

        // Dispatch a HTTP request to httpbin, and Pause until we receive the response.
        self.request_callout_id = hostcalls.dispatchHttpCall(
            "httpbin",
            self.dispatch_request_headers.map,
            null,
            null,
            5000,
        ) catch unreachable;
        return enums.Action.Pause;
    }

    // Implement contexts.HttpContext.onHttpResponseHeaders.
    fn onHttpResponseHeaders(http_context: *contexts.HttpContext, num_headers: usize, end_of_stream: bool) enums.Action {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        self.response_callout_id = hostcalls.dispatchHttpCall(
            "httpbin",
            self.dispatch_request_headers.map,
            null,
            null,
            5000,
        ) catch unreachable;
        return enums.Action.Pause;
    }

    // Implement contexts.HttpContext.onDelete.
    fn onDelete(http_context: *contexts.HttpContext) void {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // Free the request headers.
        self.dispatch_request_headers.deinit();

        // Destory myself.
        allocator.destroy(self);
    }

    // Implement contexts.HttpContext.onHttpCalloutResponse.
    fn onHttpCalloutResponse(http_context: *contexts.HttpContext, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void {
        const self: *Self = @fieldParentPtr(Self, "http_context", http_context);

        // (Debug) Check the callout ID.
        std.debug.assert(
            self.request_callout_id == callout_id or self.response_callout_id == callout_id,
        );

        // Get the response body of the callout.
        var raw_body = hostcalls.getBufferBytes(enums.BufferType.HttpCallResponseBody, 0, body_size) catch unreachable;
        defer raw_body.deinit();

        // Parse it to ConfigurationData struct.
        comptime const httpbinUUIDResponseBody = struct { uuid: []const u8 };
        var stream = std.json.TokenStream.init(raw_body.raw_data);
        var body = std.json.parse(
            httpbinUUIDResponseBody,
            &stream,
            .{ .allocator = allocator },
        ) catch unreachable;
        defer std.json.parseFree(httpbinUUIDResponseBody, body, .{ .allocator = allocator });

        // Log the received response from httpbin.
        const message = std.fmt.allocPrint(
            allocator,
            "uuid={s} received",
            .{body.uuid},
        ) catch unreachable;
        defer allocator.free(message);
        hostcalls.log(enums.LogLevel.Info, message) catch unreachable;

        if (body.uuid[0] % 2 == 0) {
            // If the first byte of uuid is even, then send the local response with 403.
            var responseHeaders = std.StringHashMap([]const u8).init(allocator);
            defer responseHeaders.deinit();
            if (self.request_callout_id == callout_id) {
                responseHeaders.put("forbidden-at", "request") catch unreachable;
            } else {
                responseHeaders.put("forbidden-at", "response") catch unreachable;
            }
            hostcalls.sendLocalResponse(403, "Forbidden by Ziglang.\n", responseHeaders) catch unreachable;
        } else {
            // Othewise, continue the originaol request.
            if (self.request_callout_id == callout_id) {
                hostcalls.continueHttpRequest();
            } else {
                hostcalls.continueHttpResponse();
            }
        }
    }
};
