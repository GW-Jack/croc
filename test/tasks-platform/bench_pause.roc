app [main!] { pf: platform "./platform/main.roc" }

import pf.Clock
import pf.Scheduler
import pf.Stdout

# Times pauses with `nest` nested procedures paused, each holding a record
# (design.md "The Reference Platform", "Measuring records"). The outer
# frames (`main!`, `bench!`, `pause_times!`) add the same records at every
# nesting, so the difference between nestings is the cost per record.
main! : () => I32
main! = || {
	bench!(1)
	bench!(4)
	bench!(16)
	0
}

pauses : U64
pauses = 200000

bench! : U64 => {}
bench! = |nest| {
	_warm = pause_times!(nest, 10000)
	start = Clock.monotonic_ns!()
	sum = pause_times!(nest, pauses)
	elapsed = Clock.monotonic_ns!() - start
	Stdout.line!("nest ${nest.to_str()}: ${(elapsed / pauses).to_str()} ns per pause (check ${sum.to_str()})")
}

# Pauses `count` times, `nest` procedures deep, and sums what each returns,
# so no pause is dead code.
pause_times! : U64, U64 => U64
pause_times! = |nest, count| {
	var $sum = 0.U64
	var $i = 0.U64
	while $i < count {
		$sum = $sum + paused_at!(nest)
		$i = $i + 1
	}
	$sum
}

# `nest` nested calls, the innermost yielding. Each frame uses its callee's
# result after the call, so each one saves a record.
paused_at! : U64 => U64
paused_at! = |nest|
	if nest <= 1 {
		Scheduler.yield!()
		1
	} else {
		paused_at!(nest - 1) + 1
	}
