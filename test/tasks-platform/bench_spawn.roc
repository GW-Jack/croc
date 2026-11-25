app [main!] { pf: platform "./platform/main.roc" }

import pf.Clock
import pf.Scheduler
import pf.Stdout

# Times concurrent loops whose entries pause once. `rounds` loops of `width`
# entries run one after another, so the cost per entry covers starting it,
# its pause, its arrival and the loop's share of making and freeing the
# running set. "inline" makes the same calls in order, with no loop.
main! : () => I32
main! = || {
	each!(1)
	each!(4)
	each!(16)
	each!(64)
	Stdout.line!("chain: ${per!(|n| chain!(n), 100000).to_str()} ns per spawn")
	0
}

entries : U64
entries = 100000

each! : U64 => {}
each! = |width| {
	rounds = entries / width
	loops = per!(|n| loops!(n / width, width), rounds * width)
	inline = per!(|n| inline!(n), rounds * width)
	Stdout.line!("width ${width.to_str()}: ${loops.to_str()} ns per entry, inline ${inline.to_str()} ns")
}

per! : (U64 => U64), U64 => U64
per! = |run!, n| {
	_warm = run!(n / 10)
	start = Clock.monotonic_ns!()
	sum = run!(n)
	elapsed = Clock.monotonic_ns!() - start
	if sum == 0 {
		0
	} else {
		elapsed / n
	}
}

entry : U64 -> (() => U64)
entry = |n| || {
	Scheduler.yield!()
	n + 1
}

loops! : U64, U64 => U64
loops! = |rounds, width| {
	var $sum = 0.U64
	var $round = 0.U64
	while $round < rounds {
		var $list = []
		var $i = 0.U64
		while $i < width {
			$list = $list.append(entry($i))
			$i = $i + 1
		}
		for! n in List.concurrently($list) {
			$sum = $sum + n
		}
		$round = $round + 1
	}
	$sum
}

inline! : U64 => U64
inline! = |n| {
	var $sum = 0.U64
	var $i = 0.U64
	while $i < n {
		f! = entry($i)
		$sum = $sum + f!()
		$i = $i + 1
	}
	$sum
}

# One entry at a time, each arrival spawning the next.
chain! : U64 => U64
chain! = |n| {
	var $sum = 0.U64
	for! value in List.concurrently([entry(0)]) {
		$sum = $sum + 1
		if value < n {
			spawn entry(value)
		}
	}
	$sum
}
