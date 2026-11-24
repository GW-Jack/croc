platform ""
	requires {
		main! : Str => Str
	}
	exposes []
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_host_fetch": Host.fetch!,
	}
	concurrency: Tasks
	targets: {}

import Host

main_for_host! : Str => Str
main_for_host! = |url| {
	match fetch_ok!(url) {
		Ok(body) => main!(body)
		Err(message) => message
	}
}

# A call that pauses returns a tag union its caller reads only after the
# operation finished.
fetch_ok! : Str => Try(Str, Str)
fetch_ok! = |url| Ok(Host.fetch!(url))
