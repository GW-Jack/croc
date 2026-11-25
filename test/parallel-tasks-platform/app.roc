app [main!] { pf: platform "./platform/main.roc" }

import pf.Meet
import pf.Sleep
import pf.Stdout

# Copies and drops the shared strings many times, so their counts change on
# every thread at once. The count of kept copies is the same every time.
churn : List(Str), U64 -> U64
churn = |words, rounds| {
	var $kept = []
	var $total = 0.U64
	var $round = 0.U64
	while $round < rounds {
		for word in words {
			$kept = $kept.append(word)
		}
		if $kept.len() > 64 {
			$total = $total + $kept.len()
			$kept = []
		}
		$round = $round + 1
	}
	$total + $kept.len()
}

entry! : List(Str), U64 -> (() => U64)
entry! = |words, millis| || {
	# Only entries that run on four threads at the same time all meet.
	met = Meet.all!(4)
	before = churn(words, 2000)
	Sleep.millis!(millis)
	after = churn(words, 2000)
	if met {
		before + after + millis
	} else {
		0
	}
}

nested! : List(Str) -> (() => U64)
nested! = |words| || {
	var $sum = 0.U64
	for! n in List.concurrently([entry!(words, 1), entry!(words, 2), entry!(words, 1), entry!(words, 2)]) {
		$sum = $sum + n
	}
	$sum
}

main! : () => I32
main! = || {
	# Made while the program runs, so the strings are counted and no literal.
	made = Meet.rounds!().to_str()
	words = ["a string too long to be small, number one${made}", "a string too long to be small, number two${made}", "a string too long to be small, number three${made}"]
	var $total = 0.U64
	for! n in List.concurrently([entry!(words, 20), entry!(words, 1), entry!(words, 10), entry!(words, 5)]) {
		$total = $total + n
	}
	Stdout.line!("total ${$total.to_str()}")
	Stdout.line!("nested ${(nested!(words))().to_str()}")

	# A loop that leaves early while its other entries run or sleep.
	for! first in List.concurrently([entry!(words, 600000), entry!(words, 1), entry!(words, 600000), entry!(words, 600000)]) {
		Stdout.line!("first ${first.to_str()}")
		break
	}
	Stdout.line!("${words.len().to_str()} words")
	0
}
