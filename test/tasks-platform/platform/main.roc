platform ""
    requires {
        main! : () => I32
    }
    exposes [Stdout, Stdin, File, Sleep, Scheduler, Clock]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_tasks_clock_monotonic_ns": Clock.monotonic_ns!,
        "roc_tasks_file_read_utf8": File.read_utf8!,
        "roc_tasks_scheduler_yield": Scheduler.yield!,
        "roc_tasks_sleep_millis": Sleep.millis!,
        "roc_tasks_stdin_line": Stdin.line!,
        "roc_tasks_stdout_line": Stdout.line!,
    }
    concurrency: Tasks
    targets: {
        inputs_dir: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
    }

import Stdout
import Stdin
import File
import Sleep
import Scheduler
import Clock

main_for_host! : () => I32
main_for_host! = main!
