platform ""
	requires {
		main! : Str => Str
	}
	exposes [Host]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_host_fetch": Host.fetch!,
		"roc_host_log": Host.log!,
	}
	concurrency: Tasks
	targets: {}

import Host

main_for_host! : Str => Str
main_for_host! = |name| main!(name)
