app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdin
import pf.Stdout

# Reads one line, after a pause, and crashes unless it is a number.
number! : Str -> (() => U64)
number! = |name| || {
	Sleep.millis!(1)
	line = Stdin.line!()
	Stdout.line!("${name} read ${line}")
	match U64.from_str(line) {
		Ok(n) => n
		Err(_) => {
			crash "${name} did not read a number"
		}
	}
}

# Crashes without pausing.
nonzero! : U64 -> (() => U64)
nonzero! = |n| || {
	Stdout.line!("nonzero ${n.to_str()}")
	if n == 0 {
		crash "nonzero was zero"
	}
	n
}

main! : () => I32
main! = || {
	# The third run reads a number, with one restart left.
	first = Concurrent.supervise!({ max_restarts: 3 }, number!("first"))
	Stdout.line!("first is ${first.to_str()}")

	# A function that doesn't pause is supervised too.
	second = Concurrent.supervise!({ max_restarts: 0 }, nonzero!(first))
	Stdout.line!("second is ${second.to_str()}")

	# The inner one gives up after its one restart, which the outer one restarts:
	# that run reads a number.
	third = Concurrent.supervise!(
		{ max_restarts: 1 },
		|| {
			Stdout.line!("outer started")
			Concurrent.supervise!({ max_restarts: 1 }, number!("inner"))
		},
	)
	Stdout.line!("third is ${third.to_str()}")

	# Two supervised entries of a loop overlap, and the crash of a run of one
	# doesn't cancel the other.
	var $sum = 0
	for! n in List.concurrently(
		[
			|| Concurrent.supervise!(
				{ max_restarts: 1 },
				|| {
					Sleep.millis!(200)
					100
				},
			),
			|| Concurrent.supervise!({ max_restarts: 1 }, number!("entry")),
		],
	) {
		Stdout.line!("arrived ${n.to_str()}")
		$sum = $sum + n
	}
	Stdout.line!("sum is ${$sum.to_str()}")

	# Three runs, then the crash of the last is the program's.
	_ = Concurrent.supervise!({ max_restarts: 2 }, number!("last"))
	0
}
