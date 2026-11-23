app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Plans And Concurrent Loops": a `for!` over a plan checks, but no
# backend compiles it yet. It is reported, and the loop crashes when it runs
# instead of computing a result.
main! = || {
	Stdout.line!("before")
	var $sum = 0
	for! x in List.concurrently([|| 1.U64, || 2]) {
		$sum = $sum + x
	}
	Stdout.line!("after ${$sum.to_str()}")
}
