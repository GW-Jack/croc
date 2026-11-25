//! ABI lock for what generated Rust glue adds for a `ParallelTasks` platform
//! (design.md "Host Contract", "Glue"). The build generates
//! `roc_platform_abi.rs` for test/parallel-tasks-platform and compiles this
//! crate with `-D warnings`. test/glue/tasks-abi locks the rest.
#![no_std]

mod roc_platform_abi;
use roc_platform_abi as abi;
use abi::{RocPoll, RocTask, RocTaskStatus};
use core::ffi::c_void;

const _: unsafe extern "C" fn() -> *mut *mut RocTask = abi::roc_task_thread_slot;

// The declarations of a mode with tasks.
const _: unsafe extern "C" fn(*mut RocTask) -> RocTaskStatus = abi::roc_task_resume;
const _: unsafe extern "C" fn(*mut RocTask, *mut c_void, u64) -> RocPoll = abi::roc_parallel_sleep_millis;
const _: unsafe extern "C" fn(*mut i32) -> *mut RocTask = abi::roc_main;
