const std = @import("std");
const allocator = @import("memory.zig").allocator;
const state = @import("state.zig");
const enums = @import("enums.zig");

/// hostcallErrors is a wrapper of erred enums.Status.
pub const hostcallErrors = error{
    NotFound,
    BadArgument,
    SerializationFailure,
    InvalidMemoryAccess,
    Empty,
    CasMismatch,
};

extern "env" fn proxy_log(
    enums.LogLevel,
    [*]const u8,
    usize,
) enums.Status;

/// log emits a message with a given level to the host.
pub fn log(level: enums.LogLevel, message: []const u8) hostcallErrors!void {
    switch (proxy_log(level, message.ptr, message.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
    return;
}

extern "env" fn proxy_set_tick_period_milliseconds(
    milliseconds: u32,
) enums.Status;

/// setTickPeriod sets a interval of onTick functions being called for the current context.
pub fn setTickPeriod(milliseconds: u32) void {
    switch (proxy_set_tick_period_milliseconds(milliseconds)) {
        .Ok => {},
        else => unreachable,
    }
}

extern "env" fn proxy_set_buffer_bytes(
    buffer_type: enums.BufferType,
    start: usize,
    max_size: usize,
    data_ptr: [*]const u8,
    data_size: usize,
) enums.Status;

fn setBufferBytes(buffer_type: enums.BufferType, start: usize, max_size: usize, data: []const u8) hostcallErrors!void {
    switch (proxy_set_buffer_bytes(buffer_type, start, max_size, data.ptr, data.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

/// appendBufferBytes appends the given data to the buffer of a specificed buffer_type.
pub fn appendBufferBytes(buffer_type: enums.BufferType, data: []const u8) hostcallErrors!void {
    try setBufferBytes(buffer_type, std.math.maxInt(usize), 0, data);
}

/// appendBufferBytes prepends the given data to the buffer of a specificed buffer_type.
pub fn prependBufferBytes(buffer_type: enums.BufferType, data: []const u8) hostcallErrors!void {
    try setBufferBytes(buffer_type, 0, 0, data);
}

/// appendBufferBytes replaces the buffer of a specificed buffer_type with the given data.
pub fn replaceBufferBytes(buffer_type: enums.BufferType, data: []const u8) hostcallErrors!void {
    try setBufferBytes(buffer_type, 0, std.math.maxInt(usize), data);
}

/// WasmData holds the byte data allocated by hosts. It is caller's responsibility to deallocate
/// it by calling deinit.
pub const WasmData = struct {
    const Self = @This();
    raw_data: []const u8,
    pub fn deinit(self: *Self) void {
        defer allocator.free(self.raw_data);
    }
};

extern "env" fn proxy_get_buffer_bytes(
    buffer_type: enums.BufferType,
    start: usize,
    max_size: usize,
    return_buffer_ptr: *[*]const u8,
    return_buffer_size: *usize,
) enums.Status;

/// getBufferBytes returns a WasmData holding the bytes allocated by host for the given buffer_type.
pub fn getBufferBytes(buffer_type: enums.BufferType, start: usize, max_size: usize) hostcallErrors!WasmData {
    var buf_ptr: [*]const u8 = undefined;
    var buf_len: usize = undefined;
    switch (proxy_get_buffer_bytes(buffer_type, start, max_size, &buf_ptr, &buf_len)) {
        .Ok => {
            return if (buf_ptr == undefined) hostcallErrors.NotFound else WasmData{ .raw_data = buf_ptr[0..buf_len] };
        },
        .NotFound => return hostcallErrors.NotFound,
        else => unreachable,
    }
}

/// HeaderMap holds the headers map (e.g. request/response HTTP headers/trailers) which is allocated by
/// hosts. It is caller's responsibility to deallocate this struct by calling deinit.
pub const HeaderMap = struct {
    const Self = @This();
    map: std.StringHashMap([]const u8),
    raw_data: []const u8,

    pub fn deinit(self: *Self) void {
        defer self.map.deinit();
        if (self.raw_data.len > 0) {
            defer allocator.free(self.raw_data);
        }
    }
};

extern "env" fn proxy_get_header_map_pairs(
    map_type: enums.MapType,
    return_buffer_data: *[*]const u8,
    return_buffer_size: *usize,
) enums.Status;

/// getHeaderMap returns a HeaderMap holding the bytes allocated by host for the given map_type.
pub fn getHeaderMap(map_type: enums.MapType) !HeaderMap {
    var buf_ptr: [*]const u8 = undefined;
    var buf_size: usize = undefined;
    switch (proxy_get_header_map_pairs(map_type, &buf_ptr, &buf_size)) {
        .Ok => {
            var map = std.StringHashMap([]const u8).init(allocator);
            const num_headers: u32 = std.mem.readIntSliceLittle(u32, buf_ptr[0..4]);
            var count: usize = 0;
            var size_index: usize = 4;
            var data_index: usize = 4 + num_headers * 4 * 2;
            while (count < num_headers) : (count += 1) {
                const key_size: u32 = std.mem.readIntSliceLittle(u32, buf_ptr[size_index .. 4 + size_index]);
                size_index += 4;
                var key: []const u8 = buf_ptr[data_index .. data_index + key_size];
                data_index += key_size + 1;

                const value_size: u32 = std.mem.readIntSliceLittle(u32, buf_ptr[size_index .. 4 + size_index]);
                size_index += 4;
                var value: []const u8 = buf_ptr[data_index .. data_index + value_size];
                data_index += value_size + 1;
                try map.put(key, value);
            }
            std.debug.assert(data_index == buf_size);
            return HeaderMap{ .map = map, .raw_data = buf_ptr[0..buf_size] };
        },
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

fn serializeHeaders(map: std.StringHashMap([]const u8)) ![]const u8 {
    var size: usize = 4;
    var iter = map.iterator();
    while (iter.next()) |header| {
        size += header.key.len + header.value.len + 10;
    }
    var buf = try allocator.alloc(u8, size);

    // Write the number of headers.
    std.mem.writeIntSliceLittle(usize, buf[0..4], map.count());

    // Write the lengths of key/values.
    var base: usize = 4;
    iter = map.iterator();
    while (iter.next()) |header| {
        std.mem.writeIntSliceLittle(usize, buf[base .. base + 4], header.key.len);
        std.mem.writeIntSliceLittle(usize, buf[base + 4 .. base + 8], header.value.len);
        base += 8;
    }

    // Write key/valuees.
    iter = map.iterator();
    while (iter.next()) |header| {
        // Copy key.
        std.mem.copy(u8, buf[base..], header.key);
        base += header.key.len;
        buf[base] = 0;
        base += 1;
        // Copy value.
        std.mem.copy(u8, buf[base..], header.value);
        base += header.value.len;
        buf[base] = 0;
        base += 1;
    }
    std.debug.assert(base == buf.len);
    return buf;
}

extern "env" fn proxy_set_header_map_pairs(
    map_type: enums.MapType,
    buf: [*]const u8,
    size: usize,
) enums.Status;

/// setHeaderMap *replaces* the underlying map in host with the given map.
pub fn setHeaderMap(map_type: enums.MapType, map: std.StringHashMap([]const u8)) !void {
    const buf = try serializeHeaders(map);
    defer allocator.free(buf);
    switch (proxy_set_header_map_pairs(map_type, buf.ptr, buf.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_get_header_map_value(
    map_type: enums.MapType,
    key_ptr: [*]const u8,
    key_size: usize,
    return_value_ptr: *[*]const u8,
    return_value_size: *usize,
) enums.Status;

/// getHeaderMapValue gets the value as WasmData of the given key in the map of map_type.
pub fn getHeaderMapValue(map_type: enums.MapType, key: []const u8) hostcallErrors!WasmData {
    var value_ptr: [*]const u8 = undefined;
    var value_size: usize = undefined;
    switch (proxy_get_header_map_value(map_type, key.ptr, key.len, &value_ptr, &value_size)) {
        .Ok => {
            return WasmData{ .raw_data = value_ptr[0..value_size] };
        },
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_replace_header_map_value(
    map_type: enums.MapType,
    key_ptr: [*]const u8,
    key_size: usize,
    value_ptr: [*]const u8,
    value_size: usize,
) enums.Status;

/// replaceHeaderMapValue replaces the value of the given key in the map of map_type.
pub fn replaceHeaderMapValue(map_type: enums.MapType, key: []const u8, value: []const u8) hostcallErrors!void {
    switch (proxy_replace_header_map_value(map_type, key.ptr, key.len, value.ptr, value.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_remove_header_map_value(
    map_type: enums.MapType,
    key_ptr: [*]const u8,
    key_size: usize,
) enums.Status;

/// replaceHeaderMapValue removes the value of the given key in the map of map_type.
pub fn removeHeaderMapValue(map_type: enums.MapType, key: []const u8) hostcallErrors!void {
    switch (proxy_remove_header_map_value(map_type, key.ptr, key.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_add_header_map_value(
    map_type: enums.MapType,
    key_ptr: [*]const u8,
    key_size: usize,
    value_ptr: [*]const u8,
    value_size: usize,
) enums.Status;

/// replaceHeaderMapValue adds the value of the given key in the map of map_type.
pub fn addHeaderMapValue(map_type: enums.MapType, key: []const u8, value: []const u8) hostcallErrors!void {
    switch (proxy_add_header_map_value(map_type, key.ptr, key.len, value.ptr, value.len)) {
        .Ok => {},
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_get_property(
    serialized_path_ptr: [*]const u8,
    serialized_path_size: usize,
    return_data_ptr: *[*]const u8,
    return_size_size: *usize,
) enums.Status;

/// getProperty gets the property as WasmData of the given path.
pub fn getProperty(path: []const []const u8) !WasmData {
    if (path.len == 0) {
        return hostcallErrors.BadArgument;
    }

    var size: usize = 0;
    for (path) |p| {
        size += p.len + 1;
    }

    var serialized_path = try allocator.alloc(u8, size);
    defer allocator.free(serialized_path);
    var index: usize = 0;
    for (path) |p| {
        std.mem.copy(u8, serialized_path[index .. index + p.len], p);
        index += p.len;
        serialized_path[index] = 0;
        index += 1;
    }
    var data_ptr: [*]const u8 = undefined;
    var data_size: usize = undefined;
    switch (proxy_get_property(serialized_path.ptr, serialized_path.len, &data_ptr, &data_size)) {
        .Ok => {
            return WasmData{ .raw_data = data_ptr[0..data_size] };
        },
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        .SerializationFailure => return hostcallErrors.SerializationFailure,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_get_shared_data(
    key_ptr: [*]const u8,
    key_size: usize,
    return_value_ptr: *[*]const u8,
    return_value_size: *usize,
    return_cas: *u32,
) enums.Status;

/// getSharedData gets the shared data as WasmData of the given key.
///return_cas can be used for setting a value on the same key via setSharedData call.
pub fn getSharedData(key: []const u8, return_cas: *u32) hostcallErrors!WasmData {
    var value_ptr: [*]const u8 = undefined;
    var value_size: usize = undefined;
    switch (proxy_get_shared_data(key.ptr, key.len, &value_ptr, &value_size, return_cas)) {
        .Ok => {
            return WasmData{ .raw_data = value_ptr[0..value_size] };
        },
        .NotFound => return hostcallErrors.NotFound,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_set_shared_data(
    key_ptr: [*]const u8,
    key_size: usize,
    value_ptr: [*]const u8,
    value_len: usize,
    cas: u32,
) enums.Status;

/// setSharedData sets the shared data as WasmData of the given key and the data.
pub fn setSharedData(key: []const u8, data: []const u8, cas: u32) hostcallErrors!void {
    switch (proxy_set_shared_data(key.ptr, key.len, data.ptr, data.len, cas)) {
        .Ok => {},
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        .CasMismatch => return hostcallErrors.CasMismatch,
        else => unreachable,
    }
}

extern "env" fn proxy_register_shared_queue(
    name_ptr: [*]const u8,
    name_size: usize,
    return_queue_id: *u32,
) enums.Status;

pub fn registerSharedQueue(name: []const u8) hostcallErrors!u32 {
    var queue_id: u32 = undefined;
    switch (proxy_register_shared_queue(name.ptr, name.len, &queue_id)) {
        .Ok => return queue_id,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_resolve_shared_queue(
    vm_id_ptr: [*]const u8,
    vm_id_size: usize,
    name_ptr: [*]const u8,
    name_size: usize,
    return_queue_id: *u32,
) enums.Status;

pub fn resolveSharedQueue(vm_id: []const u8, name: []const u8) hostcallErrors!u32 {
    var queue_id: u32 = undefined;
    switch (proxy_resolve_shared_queue(vm_id.ptr, vm_id.len, name.ptr, name.len, &queue_id)) {
        .Ok => {
            return queue_id;
        },
        .NotFound => return hostcallErrors.NotFound,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_dequeue_shared_queue(
    queue_id: u32,
    return_data_ptr: *[*]const u8,
    return_data_size: *usize,
) enums.Status;

pub fn dequeueSharedQueue(queue_id: u32) hostcallErrors!WasmData {
    var data_ptr: [*]const u8 = undefined;
    var data_size: usize = undefined;
    switch (proxy_dequeue_shared_queue(queue_id, &data_ptr, &data_size)) {
        .Ok => {
            return WasmData{ .raw_data = data_ptr[0..data_size] };
        },
        .NotFound => return hostcallErrors.NotFound,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        .Empty => return hostcallErrors.Empty,
        else => unreachable,
    }
}

extern "env" fn proxy_enqueue_shared_queue(
    queue_id: u32,
    data_ptr: [*]const u8,
    data_size: usize,
) enums.Status;

pub fn enqueueSharedQueue(queue_id: u32, data: []const u8) hostcallErrors!void {
    switch (proxy_enqueue_shared_queue(queue_id, data.ptr, data.len)) {
        .Ok => {},
        .NotFound => return hostcallErrors.NotFound,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_continue_stream(stream_type: enums.StreamType) enums.Status;

pub fn continueHttpRequest() void {
    switch (proxy_continue_stream(enums.StreamType.Request)) {
        .Ok => {},
        else => unreachable,
    }
}

pub fn continueHttpResponse() void {
    switch (proxy_continue_stream(enums.StreamType.Response)) {
        .Ok => {},
        else => unreachable,
    }
}

extern "env" fn proxy_send_local_response(
    status_code: u32,
    status_code_details_ptr: [*]const u8,
    status_code_details_size: usize,
    body_ptr: [*]const u8,
    body_size: usize,
    headers_buf_ptr: [*]const u8,
    headers_buf_size: usize,
    grpc_status: i32,
) enums.Status;

pub fn sendLocalResponse(
    status_code: u32,
    body: ?[]const u8,
    headers: ?std.StringHashMap([]const u8),
) !void {
    var headers_buf: ?[]const u8 = undefined;
    if (headers) |h| {
        headers_buf = try serializeHeaders(h);
    }
    defer {
        if (headers_buf) |buf| {
            allocator.free(buf);
        }
    }
    switch (proxy_send_local_response(
        status_code,
        undefined,
        0,
        if (body != null) body.?.ptr else undefined,
        if (body != null) body.?.len else 0,
        if (headers_buf != null) headers_buf.?.ptr else undefined,
        if (headers_buf != null) headers_buf.?.len else 0,
        -1,
    )) {
        .Ok => {},
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_http_call(
    cluster_ptr: [*]const u8,
    cluster_size: usize,
    headers_buf_ptr: [*]const u8,
    headers_buf_size: usize,
    body_ptr: [*]const u8,
    body_size: usize,
    tailers_buf_ptr: [*]const u8,
    tailers_buf_size: usize,
    timeout: u32,
    return_callout_id: *u32,
) enums.Status;

pub fn dispatchHttpCall(
    cluster: []const u8,
    headers: ?std.StringHashMap([]const u8),
    body: ?[]const u8,
    trailers: ?std.StringHashMap([]const u8),
    timeout_milliseconds: u32,
) !u32 {
    var headers_buf: ?[]const u8 = undefined;
    if (headers) |h| {
        headers_buf = try serializeHeaders(h);
    }
    defer {
        if (headers_buf) |buf| {
            allocator.free(buf);
        }
    }

    var trailers_buf: ?[]const u8 = undefined;
    if (trailers) |h| {
        trailers_buf = try serializeHeaders(h);
    }
    defer {
        if (trailers_buf) |buf| {
            allocator.free(buf);
        }
    }

    var callout_id: u32 = undefined;
    switch (proxy_http_call(
        cluster.ptr,
        cluster.len,
        if (headers_buf != null) headers_buf.?.ptr else undefined,
        if (headers_buf != null) headers_buf.?.len else 0,
        if (body != null) body.?.ptr else undefined,
        if (body != null) body.?.len else 0,
        if (trailers_buf != null) trailers_buf.?.ptr else undefined,
        if (trailers_buf != null) trailers_buf.?.len else 0,
        timeout_milliseconds,
        &callout_id,
    )) {
        .Ok => {
            state.current_state.registerCalloutId(callout_id);
            return callout_id;
        },
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_set_effective_context(context_id: u32) enums.Status;

pub fn setEffectiveContext(context_id: u32) void {
    switch (proxy_set_effective_context(context_id)) {
        .Ok => {},
        else => unreachable,
    }
}

extern "env" fn proxy_done() enums.Status;

pub fn done() void {
    switch (proxy_done()) {
        .Ok => {},
        else => unreachable,
    }
}

extern "env" fn proxy_define_metric(
    metric_type: enums.MetricType,
    name_ptr: [*]const u8,
    name_size: usize,
    return_metric_id: *u32,
) enums.Status;

pub fn defineMetric(metric_type: enums.MetricType, name: []const u8) hostcallErrors!u32 {
    var metric_id: u32 = undefined;
    switch (proxy_define_metric(metric_type, name.ptr, name.len, &metric_id)) {
        .Ok => return metric_id,
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_get_metric(
    metric_id: u32,
    return_value: *u64,
) enums.Status;

pub fn getMetric(metric_id: u32) hostcallErrors!u64 {
    var value: u64 = undefined;
    switch (proxy_get_metric(metric_id, &value)) {
        .Ok => return value,
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        .InvalidMemoryAccess => return hostcallErrors.InvalidMemoryAccess,
        else => unreachable,
    }
}

extern "env" fn proxy_record_metric(
    metric_id: u32,
    value: u64,
) enums.Status;

pub fn recordMetric(metric_id: u32, value: u64) hostcallErrors!void {
    switch (proxy_record_metric(metric_id, value)) {
        .Ok => {},
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        else => unreachable,
    }
}

extern "env" fn proxy_increment_metric(
    metric_id: u32,
    offset: i64,
) enums.Status;

pub fn incrementMetric(metric_id: u32, offset: i64) hostcallErrors!void {
    switch (proxy_increment_metric(metric_id, offset)) {
        .Ok => {},
        .NotFound => return hostcallErrors.NotFound,
        .BadArgument => return hostcallErrors.BadArgument,
        else => unreachable,
    }
}
