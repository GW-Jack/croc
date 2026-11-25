platform ""
	requires {
		main! : () => Try({}, Str)
	}
	exposes [Sleep, Stdout]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_wasi_sleep_millis": Sleep.millis!,
		"roc_wasi_stdout_line": Stdout.line!,
	}
	concurrency: Tasks
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["[async-lift]wasi:cli/run@0.3.0#run", "[callback][async-lift]wasi:cli/run@0.3.0#run"],
		},
	}

import Sleep
import Stdout

main_for_host! : () => Try({}, Str)
main_for_host! = main!
