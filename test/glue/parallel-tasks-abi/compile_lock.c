/* ABI lock for what the generated C header adds for a `ParallelTasks` platform
 * (design.md "Host Contract", "Glue"). The build generates roc_platform_abi.h
 * for test/parallel-tasks-platform and compiles this file with -Werror on
 * every lock target. test/glue/tasks-abi locks the rest. */
#include "roc_platform_abi.h"

/* The host defines this, so this file can: its declared type must match. */
static RocTask* roc_lock_running;
RocTask** roc_task_thread_slot(void) { return &roc_lock_running; }

/* The declarations of a mode with tasks. */
RocTaskStatus (*const roc_lock_task_resume)(RocTask*) = roc_task_resume;
RocPoll (*const roc_lock_sleep)(RocTask*, void*, uint64_t) = roc_parallel_sleep_millis;
RocTask* (*const roc_lock_main)(int32_t*) = roc_main;
