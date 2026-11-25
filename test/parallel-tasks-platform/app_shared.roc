app [main!] { pf: platform "./platform/main.roc" }

import pf.Meet
import pf.Sleep
import pf.Stdout

# design.md "Shared State", "Updates on several threads.": updates of one cell
# on four threads at once happen one after another, and the counts of what
# the states share change on every thread.

# Adds to the number, keeps a word of the list and copies the state out.
work! : Shared((U64, List(Str))), Str, U64 -> (() => U64)
work! = |state, word, count| || {
	# An entry that never pauses would run in its loop's own task.
	Sleep.millis!(1)
	met = Meet.all!(4)
	var $seen = 0.U64
	var $i = 0.U64
	while $i < count {
		state.modify!(
			|(n, words)| (
				n + 1,
				if words.len() > 8 {
					[word]
				} else {
					words.append(word)
				},
			),
		)
		(_, words) = state.get!()
		for kept in words {
			$seen = $seen + kept.count_utf8_bytes() % 2
		}
		$i = $i + 1
	}
	if met and $seen <= count * 9 {
		count
	} else {
		0
	}
}

# A queue that holds at most `limit` items.
push! : Shared(List(Str)), U64, Str => {}
push! = |queue, limit, item| queue.update!(
	|items| if items.len() < limit {
		Set(items.append(item), {})
	} else {
		Wait
	},
)

take! : Shared(List(Str)) => Str
take! = |queue| queue.update!(
	|items| match items {
		[first, .. as rest] => Set(rest, first)
		[] => Wait
	},
)

produce! : Shared(List(Str)), Str, U64 -> (() => U64)
produce! = |queue, word, count| || {
	var $i = 0.U64
	while $i < count {
		push!(queue, 3, "${word} ${$i.to_str()}")
		$i = $i + 1
	}
	0
}

consume! : Shared(List(Str)), U64 -> (() => U64)
consume! = |queue, count| || {
	var $i = 0.U64
	var $bytes = 0.U64
	while $i < count {
		$bytes = $bytes + take!(queue).count_utf8_bytes()
		$i = $i + 1
	}
	$bytes
}

main! : () => I32
main! = || {
	# Made while the program runs, so the strings are counted and no literal.
	made = Meet.rounds!().to_str()
	word = "a string too long to be small, number one${made}"

	state = Shared.new!((0.U64, []))
	var $done = 0.U64
	for! n in List.concurrently([work!(state, word, 3000), work!(state, word, 3000), work!(state, word, 3000), work!(state, word, 3000)]) {
		$done = $done + n
	}
	(total, words) = state.get!()
	Stdout.line!("did ${$done.to_str()}, counted ${total.to_str()}, kept ${words.len().to_str()}")

	# Items go through a short queue, with tasks waiting at both ends.
	queue = Shared.new!([])
	var $bytes = 0.U64
	for! n in List.concurrently([produce!(queue, word, 500), consume!(queue, 500), produce!(queue, word, 500), consume!(queue, 500)]) {
		$bytes = $bytes + n
	}
	Stdout.line!("took ${$bytes.to_str()} bytes, left ${queue.get!().len().to_str()}")

	# Tasks that wait while the entry that ends the loop cancels them.
	gate = Shared.new!([word])
	waits! = || gate.update!(
		|items| if items.is_empty() {
			Keep(0.U64)
		} else {
			Wait
		},
	)
	soon! = || {
		Sleep.millis!(1)
		gate.modify!(|items| items.append(word))
		2
	}
	for! first in List.concurrently([waits!, waits!, waits!, soon!]) {
		Stdout.line!("first ${first.to_str()}, ${gate.get!().len().to_str()} items")
		break
	}

	# An update that crashes poisons its cell for the tasks that wait on it.
	fragile = Shared.new!(0.U64)
	attempts = Shared.new!(0.U64)
	careful! = || {
		attempts.modify!(|n| n + 1)
		fragile.update!(
			|n| if n == 0 {
				Wait
			} else {
				Keep({})
			},
		)
	}
	upset! = || {
		Sleep.millis!(1)
		fragile.modify!(
			|n| if n == 0 {
				crash "an update crashed"
			} else {
				n
			},
		)
	}
	_ = Concurrent.both!(
		|| Concurrent.supervise!({ max_restarts: 1 }, careful!),
		|| Concurrent.supervise!({ max_restarts: 1 }, upset!),
	)
	0
}
