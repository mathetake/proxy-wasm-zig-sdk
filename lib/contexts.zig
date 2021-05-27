const enums = @import("enums.zig");

pub const RootContext = struct {
    const Self = @This();
    // Implementations used by interfaces.
    // Note that these are optional so we can have the "default" (nop) implementation.

    /// onVmStart is called after the VM is created and _initialize is called.
    /// During this call, hostcalls.getVmConfiguration is available and can be used to
    /// retrieve the configuration set at vm_config.configuration in envoy.yaml
    /// Note that only one RootContext is called on this function;
    /// There's Wasm VM: RootContext = 1: N correspondence, and
    /// each RootContext corresponds to each config.configuration, not vm_config.configuration.
    onVmStartImpl: ?fn (self: *Self, configuration_size: usize) bool = null,

    /// onPluginStart is called after onVmStart and for each different plugin configurations.
    /// During this call, hostcalls.getPluginConfiguration is available and can be used to
    /// retrieve the configuration set at config.configuration in envoy.yaml
    onPluginStartImpl: ?fn (self: *Self, configuration_size: usize) bool = null,

    /// onPluginDone is called right before deinit is called.
    /// Return false to indicate it's in a pending state to do some more work left,
    /// And must call hostcalls.done after the work is done to invoke deinit and other
    /// cleanup in the host implementation.
    onPluginDoneImpl: ?fn (self: *Self) bool = null,

    /// onDelete is called when the host is deleting this context.
    onDeleteImpl: ?fn (self: *Self) void = null,

    /// newTcpContext is used for creating HttpContext for http filters.
    /// Return null to indicate this RootContext is not for HTTP streams.
    /// Deallocation of contexts created here should only be performed in HttpContext.onDelete.
    newHttpContextImpl: ?fn (self: *Self, context_id: u32) ?*HttpContext = null,

    /// newTcpContext is used for creating TcpContext for tcp filters.
    /// Return null to indicate this RootContext is not for TCP streams.
    /// Deallocation of contexts created here should only be performed in TcpContext.onDelete.
    newTcpContextImpl: ?fn (self: *Self, context_id: u32) ?*TcpContext = null,

    /// onQueueReady is called when the queue is ready after calling hostcalls.RegisterQueue.
    /// Note that the queue is dequeued by another VM running in another thread, so possibly
    /// the queue is empty during onQueueReady.
    onQueueReadyImpl: ?fn (self: *Self, quque_id: u32) void = null,

    /// onQueueReady is called when the queue is ready after calling hostcalls.RegisterQueue.
    /// Note that the queue is dequeued by another VM running in another thread, so possibly
    /// the queue is empty during onQueueReady.
    onTickImpl: ?fn (self: *Self) void = null,

    /// onHttpCalloutResponse is called when a dispatched http call by hostcalls.dispatchHttpCall
    /// has received a response.
    onHttpCalloutResponseImpl: ?fn (self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void = null,

    // The followings are only used by SDK internally. See state.zig.
    pub fn onVmStart(self: *Self, configuration_size: usize) bool {
        if (self.onVmStartImpl) |impl| {
            return impl(self, configuration_size);
        }
        return true;
    }

    pub fn onPluginStart(self: *Self, configuration_size: usize) bool {
        if (self.onPluginStartImpl) |impl| {
            return impl(self, configuration_size);
        }
        return true;
    }

    pub fn onPluginDone(self: *Self) bool {
        if (self.onPluginDoneImpl) |impl| {
            return impl(self);
        }
        return true;
    }

    pub fn onDelete(self: *Self) void {
        if (self.onDeleteImpl) |impl| {
            return impl(self);
        }
    }

    pub fn newTcpContext(self: *Self, context_id: u32) ?*TcpContext {
        if (self.newTcpContextImpl) |impl| {
            return impl(self, context_id);
        }
        return null;
    }

    pub fn newHttpContext(self: *Self, context_id: u32) ?*HttpContext {
        if (self.newHttpContextImpl) |impl| {
            return impl(self, context_id);
        }
        return null;
    }

    pub fn onQueueReady(self: *Self, quque_id: u32) void {
        if (self.onQueueReadyImpl) |impl| {
            impl(self, quque_id);
        }
    }

    pub fn onTick(self: *Self) void {
        if (self.onTickImpl) |impl| {
            impl(self);
        }
    }

    pub fn onHttpCalloutResponse(self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void {
        if (self.onHttpCalloutResponseImpl) |impl| {
            impl(self, callout_id, num_headers, body_size, num_trailers);
        }
    }
};

pub const TcpContext = struct {
    const Self = @This();
    // Implementations used by interfaces.
    // Note that these types are optional so we can have the "default" (nop) implementation.

    /// onNewConnection is called when the tcp connection is established between Down and Upstreams.
    onNewConnectionImpl: ?fn (self: *Self) enums.Action = null,

    /// onDownstreamData is called when the data fram arrives from the downstream connection.
    onDownstreamDataImpl: ?fn (self: *Self, data_size: usize, end_of_stream: bool) enums.Action = null,

    /// onDownstreamClose is called when the downstream connection is closed.
    onDownstreamCloseImpl: ?fn (self: *Self, peer_type: enums.PeerType) void = null,

    /// onUpstreamData is called when the data fram arrives from the upstream connection.
    onUpstreamDataImpl: ?fn (self: *Self, data_size: usize, end_of_stream: bool) enums.Action = null,

    /// onUpstreamClose is called when the upstream connection is closed.
    onUpstreamCloseImpl: ?fn (self: *Self, peer_type: enums.PeerType) void = null,

    /// onUpstreamClose is called before the host calls onDelete.
    /// You can retreive the stream information (such as remote addesses, etc.) during this calls
    /// Can be used for implementing logging feature.
    onLogImpl: ?fn (self: *Self) void = null,

    /// onDelete is called when the host is deleting this context.
    onDeleteImpl: ?fn (self: *Self) void = null,

    /// onHttpCalloutResponse is called when a dispatched http call by hostcalls.dispatchHttpCall
    /// has received a response.
    onHttpCalloutResponseImpl: ?fn (self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void = null,

    // The followings are only used by SDK internally. See state.zig.
    pub fn onDownstreamData(self: *Self, data_size: usize, end_of_stream: bool) enums.Action {
        if (self.onDownstreamDataImpl) |impl| {
            return impl(self, data_size, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onDownstreamClose(self: *Self, peer_type: enums.PeerType) void {
        if (self.onDownstreamCloseImpl) |impl| {
            impl(self, peer_type);
        }
    }

    pub fn onNewConnection(self: *Self) enums.Action {
        if (self.onNewConnectionImpl) |impl| {
            return impl(self);
        }
        return enums.Action.Continue;
    }

    pub fn onUpstreamData(self: *Self, data_size: usize, end_of_stream: bool) enums.Action {
        if (self.onDownstreamDataImpl) |impl| {
            return impl(self, data_size, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onUpstreamClose(self: *Self, peer_type: enums.PeerType) void {
        if (self.onUpstreamCloseImpl) |impl| {
            impl(self, peer_type);
        }
    }

    pub fn onLog(self: *Self) void {
        if (self.onLogImpl) |impl| {
            impl(self);
        }
    }

    pub fn onHttpCalloutResponse(self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void {
        if (self.onHttpCalloutResponseImpl) |impl| {
            impl(self, callout_id, num_headers, body_size, num_trailers);
        }
    }

    pub fn onDelete(self: *Self) void {
        if (self.onDeleteImpl) |impl| {
            impl(self);
        }
    }
};

pub const HttpContext = struct {
    const Self = @This();
    // Implementations used by interfaces.
    // Note that these types are optional so we can have the "default" (nop) implementation.

    /// onHttpRequestHeaders is called when request headers arrives.
    onHttpRequestHeadersImpl: ?fn (self: *Self, num_headers: usize, end_of_stream: bool) enums.Action = null,

    /// onHttpRequestHeaders is called when a request body *frame* arrives.
    /// Note that this is possibly called multiple times until we see end_of_stream = true,
    onHttpRequestBodyImpl: ?fn (self: *Self, body_size: usize, end_of_stream: bool) enums.Action = null,

    /// onHttpRequestTrailers is called when request trailers arrives.
    onHttpRequestTrailersImpl: ?fn (self: *Self, num_trailers: usize) enums.Action = null,

    /// onHttpResponseHeaders is called when response headers arrives.
    onHttpResponseHeadersImpl: ?fn (self: *Self, num_headers: usize, end_of_stream: bool) enums.Action = null,

    /// onHttpResponseBody is called when a response body *frame* arrives.
    /// Note that this is possibly called multiple times until we see end_of_stream = true,
    onHttpResponseBodyImpl: ?fn (self: *Self, body_size: usize, end_of_stream: bool) enums.Action = null,

    /// onHttpResponseTrailers is called when response trailers arrives.
    onHttpResponseTrailersImpl: ?fn (self: *Self, num_trailers: usize) enums.Action = null,

    /// onUpstreamClose is called before the host calls onDelete.
    /// You can retreive the HTTP request/response information (such headers, etc.) during this calls
    /// Can be used for implementing logging feature.
    onLogImpl: ?fn (self: *Self) void = null,

    /// onDelete is called when the host is deleting this context.
    onDeleteImpl: ?fn (self: *Self) void = null,

    /// onHttpCalloutResponse is called when a dispatched http call by hostcalls.dispatchHttpCall
    /// has received a response.
    onHttpCalloutResponseImpl: ?fn (self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void = null,

    // The followings are only used by SDK internally. See state.zig.
    pub fn onHttpRequestHeaders(self: *Self, num_headers: usize, end_of_stream: bool) enums.Action {
        if (self.onHttpRequestHeadersImpl) |impl| {
            return impl(self, num_headers, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onHttpRequestBody(self: *Self, body_size: usize, end_of_stream: bool) enums.Action {
        if (self.onHttpRequestBodyImpl) |impl| {
            return impl(self, body_size, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onHttpRequestTrailers(self: *Self, num_trailers: usize) enums.Action {
        if (self.onHttpRequestTrailersImpl) |impl| {
            return impl(self, num_trailers);
        }
        return enums.Action.Continue;
    }

    pub fn onHttpResponseHeaders(self: *Self, num_headers: usize, end_of_stream: bool) enums.Action {
        if (self.onHttpResponseHeadersImpl) |impl| {
            return impl(self, num_headers, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onHttpResponseBody(self: *Self, body_size: usize, end_of_stream: bool) enums.Action {
        if (self.onHttpResponseBodyImpl) |impl| {
            return impl(self, body_size, end_of_stream);
        }
        return enums.Action.Continue;
    }

    pub fn onHttpResponseTrailers(self: *Self, num_trailers: usize) enums.Action {
        if (self.onHttpResponseTrailersImpl) |impl| {
            return impl(self, num_trailers);
        }
        return enums.Action.Continue;
    }

    pub fn onLog(self: *Self) void {
        if (self.onLogImpl) |impl| {
            impl(self);
        }
    }

    pub fn onHttpCalloutResponse(self: *Self, callout_id: u32, num_headers: usize, body_size: usize, num_trailers: usize) void {
        if (self.onHttpCalloutResponseImpl) |impl| {
            impl(self, callout_id, num_headers, body_size, num_trailers);
        }
    }

    pub fn onDelete(self: *Self) void {
        if (self.onDeleteImpl) |impl| {
            impl(self);
        }
    }
};
