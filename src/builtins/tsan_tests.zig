//! The builtins' threaded tests, which `zig build run-test-builtins-tsan`
//! runs under ThreadSanitizer: concurrent refcount releases, wakes that
//! race a task's park, child tasks woken from worker threads, tasks of
//! one tree resumed at the same time, and shared state updated on several
//! threads. The builtins module tests run them
//! without it. This root only references the files, so it declares no test of
//! its own.

comptime {
    _ = @import("atomic_rc_test.zig");
    _ = @import("task_wake_test.zig");
    _ = @import("task_group_threads_test.zig");
    _ = @import("task_parallel_test.zig");
    _ = @import("task_cell_threads_test.zig");
}
