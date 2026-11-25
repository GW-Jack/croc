app [main!] { pf: platform "./platform/main.roc" }

import pf.Meet
import pf.Sleep
import pf.Stdout

# Meets the other three entries, and crashes until they met three times.
flaky! : () => U64
flaky! = || {
	_ = Meet.all!(4)
	Sleep.millis!(1)
	if Meet.rounds!() < 3 {
		crash "flaky crashed beside the others"
	}
	100
}

steady! : U64 -> (() => U64)
steady! = |n| || {
	var $i = 0.U64
	while $i < 3 {
		_ = Meet.all!(4)
		Sleep.millis!(n)
		$i = $i + 1
	}
	n
}

# Each run of `flaky!` crashes on a thread while the others run on theirs, and
# the crash reaches only its own supervisor.
main! : () => I32
main! = || {
	var $sum = 0.U64
	for! n in List.concurrently([steady!(1), steady!(2), steady!(3), || Concurrent.supervise!({ max_restarts: 2 }, flaky!)]) {
		$sum = $sum + n
	}
	Stdout.line!("sum ${$sum.to_str()} after ${Meet.rounds!().to_str()} meetings")
	0
}
