app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# design.md "Shared State", "Waiting.": an update that answers `Wait` pauses
# its task until other tasks have changed the state so that it would not.

# A queue that holds at most `limit` items.
push! : Shared(List(U64)), U64, U64 => {}
push! = |queue, limit, item| queue.update!(
	|items| if items.len() < limit {
		Set(items.append(item), {})
	} else {
		Wait
	},
)

take! : Shared(List(U64)) => U64
take! = |queue| queue.update!(
	|items| match items {
		[first, .. as rest] => Set(rest, first)
		[] => Wait
	},
)

produce! : Shared(List(U64)), U64 -> (() => [Produced, Consumed(U64)])
produce! = |queue, count| || {
	var $i = 1
	while $i <= count {
		push!(queue, 2, $i)
		$i = $i + 1
	}
	Produced
}

consume! : Shared(List(U64)), U64 -> (() => [Produced, Consumed(U64)])
consume! = |queue, count| || {
	var $i = 0
	var $sum = 0
	while $i < count {
		$sum = $sum + take!(queue)
		$i = $i + 1
	}
	Consumed($sum)
}

# Waits until it is `turn`'s turn, says so, and lets the next one go.
in_turn! : Shared(U64), Shared(List(U64)), U64 -> (() => {})
in_turn! = |turns, order, turn| || {
	turns.update!(
		|next| if next == turn {
			Keep({})
		} else {
			Wait
		},
	)
	order.modify!(|done| done.append(turn))
	turns.modify!(|next| next + 1)
}

show! : List(U64) => Str
show! = |numbers| {
	var $out = ""
	for number in numbers {
		$out = "${$out} ${number.to_str()}"
	}
	$out
}

main! : () => I32
main! = || {
	# Items go through a queue shorter than their number, both ways at once.
	queue = Shared.new!([])
	var $consumed = 0
	for! done in List.concurrently([produce!(queue, 50), consume!(queue, 50), produce!(queue, 50), consume!(queue, 50)]) {
		match done {
			Consumed(sum) => {
				$consumed = $consumed + sum
			}
			Produced => {}
		}
	}
	Stdout.line!("consumed ${$consumed.to_str()}")

	# A state where only one of several waiters would go on wakes that one.
	turns = Shared.new!(0)
	order = Shared.new!([])
	_ = List.concurrently([in_turn!(turns, order, 2), in_turn!(turns, order, 1), in_turn!(turns, order, 3), in_turn!(turns, order, 0)]).all!()
	Stdout.line!("turns${show!(order.get!())}")

	# Waiters go on oldest first, one for each permit.
	permits = Shared.new!(0)
	served = Shared.new!([])
	acquire! = |name| || {
		permits.update!(
			|n| if n > 0 {
				Set(n - 1, {})
			} else {
				Wait
			},
		)
		served.modify!(|names| names.append(name))
	}
	release! = || {
		var $i = 0
		while $i < 3 {
			Sleep.millis!(1)
			permits.modify!(|n| n + 1)
			$i = $i + 1
		}
	}
	_ = List.concurrently([acquire!(1), acquire!(2), acquire!(3), release!]).all!()
	Stdout.line!("served${show!(served.get!())}")

	# A waiter that goes on without storing passes the wake on.
	gate = Shared.new!(False)
	passed = Shared.new!(0)
	pass! = || {
		gate.update!(
			|open| if open {
				Keep({})
			} else {
				Wait
			},
		)
		passed.modify!(|n| n + 1)
	}
	open! = || {
		Sleep.millis!(1)
		gate.modify!(|_| True)
	}
	_ = List.concurrently([pass!, pass!, pass!, open!]).all!()
	Stdout.line!("passed ${passed.get!().to_str()}")

	# A waiter that is cancelled waits no more, and what comes after it goes on.
	lock = Shared.new!(1)
	never! = || {
		lock.update!(
			|n| if n == 0 {
				Keep(1)
			} else {
				Wait
			},
		)
	}
	soon! = || {
		Sleep.millis!(1)
		2
	}
	winner = Concurrent.race!(never!, [soon!])
	lock.modify!(|n| n - 1)
	Stdout.line!("winner ${winner.to_str()}, lock ${lock.get!().to_str()}")

	# A waiter whose function crashes on the new state crashes when it goes on.
	fragile = Shared.new!(0)
	attempts = Shared.new!(0)
	careful! = || {
		attempts.modify!(|n| n + 1)
		fragile.update!(
			|n| if n == 0 {
				Wait
			} else {
				crash "the waiting update crashed"
			},
		)
	}
	upset! = || {
		Sleep.millis!(1)
		fragile.modify!(|n| n + 1)
	}
	_ = Concurrent.both!(|| Concurrent.supervise!({ max_restarts: 1 }, careful!), upset!)
	0
}
