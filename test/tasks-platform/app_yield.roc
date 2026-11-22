app [main!] { pf: platform "./platform/main.roc" }

import pf.Clock
import pf.Scheduler
import pf.Stdout

# Yields five times, three procedures deep, and checks the clock moves
# forward across the yields.
main! : () => I32
main! = || {
	before = Clock.monotonic_ns!()
	var $sum = 0.U64
	var $i = 0.U64
	while $i < 5 {
		$sum = $sum + yielded_at!(3)
		$i = $i + 1
	}
	after = Clock.monotonic_ns!()
	Stdout.line!("yielded 5 times, sum ${$sum.to_str()}")
	if after >= before { 0 } else { 1 }
}

yielded_at! : U64 => U64
yielded_at! = |nest|
	if nest <= 1 {
		Scheduler.yield!()
		1
	} else {
		yielded_at!(nest - 1) + 1
	}
