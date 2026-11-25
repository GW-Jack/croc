app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# design.md "Shared State": tasks of one tree update the same state between
# their pauses, and an update that crashes poisons the state it was updating.

# Adds `n` to the total and its name to the log, after a pause, `times` times.
worker! : Shared(U64), Shared(List(Str)), Str, U64, U64 -> (() => U64)
worker! = |total, log, name, n, times| || {
	var $i = 0.U64
	while $i < times {
		Sleep.millis!(1)
		total.modify!(|sum| sum + n)
		log.modify!(|names| names.append(name))
		$i = $i + 1
	}
	n * times
}

main! : () => I32
main! = || {
	total = Shared.new!(0)
	log = Shared.new!([])
	var $returned = 0
	for! sum in List.concurrently(
		[
			worker!(total, log, "a", 1, 3),
			worker!(total, log, "b", 10, 2),
			worker!(total, log, "c", 100, 1),
		],
	) {
		$returned = $returned + sum
	}
	Stdout.line!("returned ${$returned.to_str()}")
	Stdout.line!("total ${total.get!().to_str()}")
	Stdout.line!("logged ${log.get!().len().to_str()}")

	# A run of a supervised function has the state its first run left.
	attempts = Shared.new!(0.U64)
	third = Concurrent.supervise!(
		{ max_restarts: 5 },
		|| {
			attempt = attempts.update!(|n| Set(n + 1, n + 1))
			Sleep.millis!(1)
			if attempt < 3 {
				crash "not yet"
			}
			attempt
		},
	)
	Stdout.line!("attempt ${third.to_str()}")

	# The first run crashes inside its update. The second finds the state
	# poisoned, and so does anything else.
	account = Shared.new!(["opened"])
	_ = Concurrent.supervise!(
		{ max_restarts: 1 },
		|| {
			Stdout.line!("updating")
			account.modify!(
				|entries| if entries.len() == 1 {
					crash "the update crashed"
				} else {
					entries
				},
			)
		},
	)
	0
}
