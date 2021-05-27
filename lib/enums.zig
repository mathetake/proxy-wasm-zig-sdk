pub const Action = enum(i32) {
    Continue,
    Pause,
};

pub const BufferType = enum(i32) {
    HttpRequestbody,
    HttpResponseBody,
    DownstreamData,
    UpstreamData,
    HttpCallResponseBody,
    GrpcReceiveBuffer,
    VmConfiguration,
    PluginConfiguration,
};

pub const LogLevel = enum(i32) {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Critical,
};

pub const MapType = enum(i32) {
    HttpRequestHeaders,
    HttpRequestTrailers,
    HttpResponseHeaders,
    HttpResponseTrailers,
    GrpcReceiveInitialMetadata,
    GrpcReceiveTrailingMetadata,
    HttpCallResponseHeaders,
    HttpCallResponseTrailers,
};

pub const MetricType = enum(i32) {
    Counter,
    Gauge,
    Histogram,
};

pub const PeerType = enum(i32) {
    Unknown,
    Local,
    Remote,
};

pub const Status = enum(i32) {
    Ok = 0,
    NotFound = 1,
    BadArgument = 2,
    SerializationFailure = 3,
    InvalidMemoryAccess = 6,
    Empty = 7,
    CasMismatch = 8,
};

pub const StreamType = enum(i32) {
    Request,
    Response,
    Downstream,
    Upstream,
};
