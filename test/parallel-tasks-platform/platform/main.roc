platform ""
    requires {
        main! : () => I32
    }
    exposes [Meet, Sleep, Stdout]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_parallel_meet_all": Meet.all!,
        "roc_parallel_meet_rounds": Meet.rounds!,
        "roc_parallel_sleep_millis": Sleep.millis!,
        "roc_parallel_stdout_line": Stdout.line!,
    }
    concurrency: ParallelTasks
    targets: {
        inputs_dir: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libc.a"] },
    }

import Meet
import Sleep
import Stdout

main_for_host! : () => I32
main_for_host! = main!
