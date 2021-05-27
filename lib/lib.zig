pub const allocator = @import("memory.zig").allocator;
pub const contexts = @import("contexts.zig");
pub const enums = @import("enums.zig");
pub const hostcalls = @import("hostcalls.zig");
const state = @import("state.zig");

/// setNewRootContextFunc is the entrypoint for setting up this entire Wasm VM.
/// The given function is responsible for creating contexts.RootContext and is called when
/// hosts initialize plugins for each plugin configuration.
/// Deallocation of contexts created inside the function should only be performed in RootContext.onDelete.
pub fn setNewRootContextFunc(func: fn (context_id: usize) *contexts.RootContext) void {
    state.current_state.new_root_context = func;
}

export fn proxy_abi_version_0_2_0() void {}
