app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# Three tasks that sleep at the same time and print as they wake, and a race
# between two timers (design.md "Host Contract", "WASI hosts.").

nap! : Shared(U64), U64 -> (() => Str)
nap! = |slept, millis| || {
	Sleep.millis!(millis)
	slept.modify!(|sum| sum + millis)
	Stdout.line!("slept ${millis.to_str()}")
	millis.to_str()
}

main! : () => Try({}, Str)
main! = || {
	slept = Shared.new!(0)
	var $naps = ""
	for! name in List.concurrently([nap!(slept, 90), nap!(slept, 1), nap!(slept, 45), nap!(slept, 0)]) {
		$naps = Str.concat($naps, "${name} ")
	}
	winner = Concurrent.race!(
		|| {
			Sleep.millis!(60000)
			"late"
		},
		[
			|| {
				Sleep.millis!(1)
				"early"
			},
		],
	)
	Stdout.line!("${$naps}${winner} ${slept.get!().to_str()}")
	Ok({})
}
