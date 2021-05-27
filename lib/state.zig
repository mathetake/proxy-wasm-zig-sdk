const allocator = @import("memory.zig").allocator;
const contexts = @import("contexts.zig");
const enums = @import("enums.zig");
const hostcalls = @import("hostcalls.zig");
const std = @import("std");

pub var current_state: State = .{
    .new_root_context = null,
    .root_contexts = std.AutoHashMap(u32, *contexts.RootContext).init(allocator),
    .stream_contexts = std.AutoHashMap(u32, *contexts.TcpContext).init(allocator),
    .http_contexts = std.AutoHashMap(u32, *contexts.HttpContext).init(allocator),
    .callout_id_to_context_ids = std.AutoHashMap(u32, u32).init(allocator),
    .active_id = 0,
};

pub const State = struct {
    const Self = @This();
    new_root_context: ?fn (context_id: usize) *contexts.RootContext,
    root_contexts: std.AutoHashMap(u32, *contexts.RootContext),
    stream_contexts: std.AutoHashMap(u32, *contexts.TcpContext),
    http_contexts: std.AutoHashMap(u32, *contexts.HttpContext),
    callout_id_to_context_ids: std.AutoHashMap(u32, u32),
    active_id: u32,

    pub fn registerCalloutId(self: *Self, callout_id: u32) void {
        self.callout_id_to_context_ids.put(callout_id, self.active_id) catch unreachable;
    }
};

export fn proxy_on_context_create(context_id: u32, root_context_id: u32) void {
    if (root_context_id == 0) {
        var context = current_state.new_root_context.?(context_id);
        current_state.root_contexts.put(context_id, context) catch unreachable;
        return;
    }
    // We should exist with unreachable when the root contexts do not exist.
    const root = current_state.root_contexts.get(root_context_id).?;

    // Try to create a stream context.
    if (root.newTcpContext(context_id)) |stream_contex| {
        current_state.stream_contexts.put(context_id, stream_contex) catch unreachable;
        return;
    }

    // Try to create a http context.
    // If we fail to create, then the state is stale.
    var http_context = root.newHttpContext(context_id).?;
    current_state.http_contexts.put(context_id, http_context) catch unreachable;
}

export fn proxy_on_done(context_id: u32) bool {
    if (current_state.root_contexts.get(context_id)) |root_context| {
        current_state.active_id = context_id;
        return root_context.onPluginDone();
    }
    return true;
}

export fn proxy_on_log(context_id: u32) void {
    if (current_state.stream_contexts.get(context_id)) |stream_context| {
        current_state.active_id = context_id;
        stream_context.onLog();
        return;
    } else if (current_state.http_contexts.get(context_id)) |http_context| {
        current_state.active_id = context_id;
        http_context.onLog();
    }
}

export fn proxy_on_delete(context_id: u32) void {
    if (current_state.root_contexts.get(context_id)) |root_context| {
        root_context.onDelete();
        return;
    } else if (current_state.stream_contexts.get(context_id)) |stream_context| {
        stream_context.onDelete();
        return;
    }

    // Must fail with unreachable when the target context does not exist.
    var http_context = current_state.http_contexts.get(context_id).?;
    http_context.onDelete();
}

export fn proxy_on_vm_start(context_id: u32, configuration_size: usize) bool {
    var vm_context = current_state.root_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return vm_context.onVmStart(configuration_size);
}

export fn proxy_on_configure(context_id: u32, configuration_size: usize) bool {
    var root_context = current_state.root_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return root_context.onPluginStart(configuration_size);
}

export fn proxy_on_tick(context_id: u32) void {
    var root_context = current_state.root_contexts.get(context_id).?;
    current_state.active_id = context_id;
    root_context.onTick();
}

export fn proxy_on_queue_ready(context_id: u32, queue_id: u32) void {
    var root_context = current_state.root_contexts.get(context_id).?;
    current_state.active_id = context_id;
    root_context.onQueueReady(queue_id);
}

export fn proxy_on_new_connection(context_id: u32) enums.Action {
    var stream_context = current_state.stream_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return stream_context.onNewConnection();
}

export fn proxy_on_downstream_data(context_id: u32, data_size: usize, end_of_stream: bool) enums.Action {
    var stream_context = current_state.stream_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return stream_context.onDownstreamData(data_size, end_of_stream);
}

export fn proxy_on_downstream_connection_close(context_id: u32, peer_type: enums.PeerType) void {
    var stream_context = current_state.stream_contexts.get(context_id).?;
    current_state.active_id = context_id;
    stream_context.onDownstreamClose(peer_type);
}

export fn proxy_on_upstream_data(context_id: u32, data_size: usize, end_of_stream: bool) enums.Action {
    var stream_context = current_state.stream_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return stream_context.onUpstreamData(data_size, end_of_stream);
}

export fn proxy_on_upstream_connection_close(context_id: u32, peer_type: enums.PeerType) void {
    var stream_context = current_state.stream_contexts.get(context_id).?;
    current_state.active_id = context_id;
    stream_context.onUpstreamClose(peer_type);
}

export fn proxy_on_request_headers(context_id: u32, num_headers: usize, end_of_stream: bool) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpRequestHeaders(num_headers, end_of_stream);
}

export fn proxy_on_request_body(context_id: u32, body_size: usize, end_of_stream: bool) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpRequestBody(body_size, end_of_stream);
}

export fn proxy_on_request_trailers(context_id: u32, num_trailers: usize) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpRequestTrailers(num_trailers);
}

export fn proxy_on_response_headers(context_id: u32, num_headers: usize, end_of_stream: bool) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpResponseHeaders(num_headers, end_of_stream);
}

export fn proxy_on_response_body(context_id: u32, body_size: usize, end_of_stream: bool) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpResponseBody(body_size, end_of_stream);
}

export fn proxy_on_response_trailers(context_id: u32, num_trailers: usize) enums.Action {
    var http_context = current_state.http_contexts.get(context_id).?;
    current_state.active_id = context_id;
    return http_context.onHttpResponseTrailers(num_trailers);
}

export fn proxy_on_http_call_response(_: u32, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void {
    const context_id: u32 = current_state.callout_id_to_context_ids.get(callout_id).?;
    if (current_state.root_contexts.get(context_id)) |context| {
        hostcalls.setEffectiveContext(context_id);
        current_state.active_id = context_id;
        context.onHttpCalloutResponse(callout_id, num_headers, body_size, num_trailers);
    } else if (current_state.stream_contexts.get(context_id)) |context| {
        hostcalls.setEffectiveContext(context_id);
        current_state.active_id = context_id;
        context.onHttpCalloutResponse(callout_id, num_headers, body_size, num_trailers);
    } else if (current_state.http_contexts.get(context_id)) |context| {
        hostcalls.setEffectiveContext(context_id);
        current_state.active_id = context_id;
        context.onHttpCalloutResponse(callout_id, num_headers, body_size, num_trailers);
    } else {
        unreachable;
    }
}
