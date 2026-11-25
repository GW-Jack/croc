platform ""
	requires {
		main! : () => Str
	}
	exposes [Console, Http, Sleep]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_browser_console_log": Console.log!,
		"roc_browser_http_get": Http.get!,
		"roc_browser_sleep_millis": Sleep.millis!,
	}
	concurrency: Tasks
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["host_start", "host_resume", "host_cancel", "host_free", "host_wake", "host_wake_get", "host_result", "host_release_result", "host_alloc", "host_dealloc", "host_live_allocations"],
		},
	}

import Console
import Http
import Sleep

main_for_host! : () => Str
main_for_host! = main!
