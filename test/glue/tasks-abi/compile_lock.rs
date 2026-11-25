//! ABI lock for the task ABI in generated Rust glue (design.md "Host
//! Contract", "Glue"). The build generates `roc_platform_abi.rs` for
//! test/tasks-platform, a `concurrency: Tasks` platform, and compiles this
//! crate with `-D warnings`, so a changed value or signature in the RustGlue
//! template is a compile error. The values are `builtins.task.Status`'s order,
//! which the Zig lock checks against the runtime.
#![no_std]

mod roc_platform_abi;
use roc_platform_abi as abi;
use abi::{RocPoll, RocStr, RocTask, RocTaskStatus};
use core::ffi::c_void;

const _: () = assert!(RocPoll::Ready as u32 == 0 && RocPoll::Pending as u32 == 1);
const _: () = assert!(
    RocTaskStatus::Pending as u32 == 0
        && RocTaskStatus::Done as u32 == 1
        && RocTaskStatus::Cancelled as u32 == 2
        && RocTaskStatus::Crashed as u32 == 3
);

// The program's runtime calls, and the host's.
const _: unsafe extern "C" fn(*mut RocTask) -> RocTaskStatus = abi::roc_task_resume;
const _: unsafe extern "C" fn(*mut RocTask) = abi::roc_task_wake;
const _: unsafe extern "C" fn(*mut RocTask) = abi::roc_task_cancel;
const _: unsafe extern "C" fn(*mut RocTask) = abi::roc_task_free;
const _: unsafe extern "C" fn(*mut RocTask, *mut usize) -> *const u8 = abi::roc_task_crash_message;
const _: unsafe extern "C" fn(*mut RocTask) = abi::roc_task_ready;
const _: unsafe extern "C" fn(*mut RocTask) = abi::roc_task_abort;

// A suspending hosted function takes the task and its result pointer first;
// the pointer is untyped when the result has no bytes.
const _: unsafe extern "C" fn(*mut RocTask, *mut abi::FileReadUtf8Result, RocStr) -> RocPoll = abi::roc_tasks_file_read_utf8;
const _: unsafe extern "C" fn(*mut RocTask, *mut RocStr) -> RocPoll = abi::roc_tasks_stdin_line;
const _: unsafe extern "C" fn(*mut RocTask, *mut c_void) -> RocPoll = abi::roc_tasks_scheduler_yield;
const _: unsafe extern "C" fn(*mut RocTask, *mut c_void, u64) -> RocPoll = abi::roc_tasks_sleep_millis;
// One without the marker keeps its natural signature.
const _: unsafe extern "C" fn(RocStr) = abi::roc_tasks_stdout_line;

// A provided procedure takes its result pointer last and returns its task.
const _: unsafe extern "C" fn(*mut i32) -> *mut RocTask = abi::roc_main;
