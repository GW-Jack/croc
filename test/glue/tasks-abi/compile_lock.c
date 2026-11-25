/* ABI lock for the task ABI in the generated C header (design.md "Host
 * Contract", "Glue"). The build generates roc_platform_abi.h for
 * test/tasks-platform, a `concurrency: Tasks` platform, and compiles this file
 * with -Werror on every lock target, so a changed value or signature in the
 * CGlue template is a compile error. The values are builtins.task.Status's
 * order, which the Zig lock checks against the runtime. */
#include "roc_platform_abi.h"

_Static_assert(ROC_READY == 0 && ROC_PENDING == 1, "RocPoll values");
_Static_assert(ROC_TASK_PENDING == 0 && ROC_TASK_DONE == 1 && ROC_TASK_CANCELLED == 2 && ROC_TASK_CRASHED == 3,
               "RocTaskStatus values");
_Static_assert(sizeof(RocPoll) == 4 && sizeof(RocTaskStatus) == 4, "task enums are 32 bits");

/* The program's runtime calls. */
RocTaskStatus (*const roc_lock_task_resume)(RocTask*) = roc_task_resume;
void (*const roc_lock_task_wake)(RocTask*) = roc_task_wake;
void (*const roc_lock_task_cancel)(RocTask*) = roc_task_cancel;
void (*const roc_lock_task_free)(RocTask*) = roc_task_free;
const uint8_t* (*const roc_lock_task_crash_message)(RocTask*, size_t*) = roc_task_crash_message;

/* The host defines these, so this file can: their declared types must match. */
void roc_task_ready(RocTask* task) { (void)task; }
void roc_task_abort(RocTask* task) { (void)task; }

/* A suspending hosted function takes the task and its result pointer first;
 * the pointer is untyped when the result has no bytes. */
RocPoll (*const roc_lock_file_read)(RocTask*, FileReadUtf8Result*, RocStr) = roc_tasks_file_read_utf8;
RocPoll (*const roc_lock_stdin_line)(RocTask*, RocStr*) = roc_tasks_stdin_line;
RocPoll (*const roc_lock_yield)(RocTask*, void*) = roc_tasks_scheduler_yield;
RocPoll (*const roc_lock_sleep)(RocTask*, void*, uint64_t) = roc_tasks_sleep_millis;
/* One without the marker keeps its natural signature. */
void (*const roc_lock_stdout_line)(RocStr) = roc_tasks_stdout_line;

/* A provided procedure takes its result pointer last and returns its task. */
RocTask* (*const roc_lock_main)(int32_t*) = roc_main;
