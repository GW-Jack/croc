app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "The library.": the library types over `Shared`.
# Tasks here pause only where an update waits, so each section decides the
# order its tasks run in by what they wait for. `Concurrent.race!` cancels the
# task that loses, which shows each type's cleanup on a cancel.

# A gate that opens once: `open!` lets every task waiting in `pass!` go on.
pass! : Shared(Bool) => {}
pass! = |gate| gate.update!(
	|open| if open {
		Keep({})
	} else {
		Wait
	},
)

open! : Shared(Bool) => {}
open! = |gate| gate.modify!(|_| Bool.True)

# Waits until `count` reaches `at_least`.
reach! : Shared(U64), U64 => {}
reach! = |count, at_least| count.update!(
	|n| if n >= at_least {
		Keep({})
	} else {
		Wait
	},
)

# A task that wins a race once `loser` has paused.
winner! : Str -> (() => Str)
winner! = |name| || name

queue_section! : () => {}
queue_section! = || {
	queue = Concurrent.Queue.new!(2)
	produce! = || {
		queue.closing!(
			|| {
				var $i = 1.U64
				while $i <= 5 {
					_ = queue.push!($i)
					$i = $i + 1
				}
			},
		)
		0
	}
	consume! = || {
		var $sum = 0.U64
		for! item in queue.stream() {
			Stdout.line!("queue popped ${item.to_str()}")
			$sum = $sum + item
		}
		$sum
	}
	sums = Concurrent.all!([consume!, produce!])
	Stdout.line!("queue sum ${Str.join_with(sums.map(|n| n.to_str()), " ")}")

	small = Concurrent.Queue.new!(1)
	first = small.try_push!("a")
	second = small.try_push!("b")
	small.close!()
	third = small.push!("c")
	popped = small.pop!()
	after = small.pop!()
	show = |answer| match answer {
		Pushed => "Pushed"
		Full => "Full"
		Closed => "Closed"
	}
	shown_pop = |answer| match answer {
		Item(item) => "Item(${item})"
		Closed => "Closed"
	}
	Stdout.line!("queue ${show(first)} ${show(second)} ${show(third)} ${shown_pop(popped)} ${shown_pop(after)}")

	# A producer cancelled inside `closing!` closes the queue for its readers.
	cancelled = Concurrent.Queue.new!(4)
	gate = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| {
			cancelled.closing!(
				|| {
					_ = cancelled.push!("x")
					pass!(gate)
					"never"
				},
			)
		},
		[winner!("queue winner")],
	)
	left = cancelled.pop!()
	end = cancelled.pop!()
	Stdout.line!("queue ${won}, then ${shown_pop(left)} ${shown_pop(end)}")
}

reply_section! : () => {}
reply_section! = || {
	reply = Concurrent.Reply.new!()
	gate = Shared.new!(Bool.False)
	results = Concurrent.all!([
		|| match reply.wait!() {
			Done(answer) => "waiter got ${answer}"
			Dropped => "waiter saw it dropped"
		},
		|| {
			reply.answer!(
				|| {
					pass!(gate)
					"forty-two"
				},
			)
			"answered"
		},
		|| {
			open!(gate)
			"opened"
		},
	])
	Stdout.line!("reply ${Str.join_with(results, ", ")}")

	# An answer cancelled while it is being produced drops the reply.
	dropped = Concurrent.Reply.new!()
	never = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| {
			dropped.answer!(
				|| {
					pass!(never)
					"never"
				},
			)
			"never"
		},
		[winner!("reply winner")],
	)
	shown = match dropped.wait!() {
		Done(answer) => "Done(${answer})"
		Dropped => "Dropped"
	}
	Stdout.line!("reply ${won}, then ${shown}")
}

semaphore_section! : () => {}
semaphore_section! = || {
	permits = Concurrent.Semaphore.new!(2)
	inside = Shared.new!(0.U64)
	most = Shared.new!(0.U64)
	gate = Shared.new!(Bool.False)
	work! : U64 -> (() => U64)
	work! = |n| || permits.with!(
		|| {
			now = inside.update!(|k| Set(k + 1, k + 1))
			most.modify!(
				|m| if now > m {
					now
				} else {
					m
				},
			)
			pass!(gate)
			inside.modify!(|k| k - 1)
			n
		},
	)
	opener! = || {
		reach!(inside, 2)
		open!(gate)
		0
	}
	done = Concurrent.all!([work!(1), work!(2), work!(3), work!(4), opener!])
	Stdout.line!("semaphore ran ${Str.join_with(done.map(|n| n.to_str()), " ")}, at most ${most.get!().to_str()} at once")

	# A holder cancelled while it holds the permit gives it back.
	single = Concurrent.Semaphore.new!(1)
	never = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| single.with!(
			|| {
				pass!(never)
				"never"
			},
		),
		[winner!("semaphore winner")],
	)
	again = match single.try_with!(|| "ran") {
		Ran(answer) => answer
		Busy => "busy"
	}
	inner! = || match single.try_with!(|| "nested") {
		Ran(_) => "nested ran"
		Busy => "nested busy"
	}
	busy = match single.try_with!(inner!) {
		Ran(answer) => answer
		Busy => "busy"
	}
	Stdout.line!("semaphore ${won}, then ${again}, ${busy}")
}

pool_section! : () => {}
pool_section! = || {
	opened = Shared.new!(0.U64)
	pool = Concurrent.Pool.new!(["conn-a"])
	gate = Shared.new!(Bool.False)
	open_conn! = || {
		n = opened.update!(|k| Set(k + 1, k + 1))
		"conn-new-${n.to_str()}"
	}
	used = Concurrent.all!([
		|| pool.with!(
			open_conn!,
			|conn| {
				pass!(gate)
				"first used ${conn}"
			},
		),
		|| pool.with!(open_conn!, |conn| "second used ${conn}"),
		|| {
			open!(gate)
			"opened"
		},
	])
	Stdout.line!("pool ${Str.join_with(used, ", ")}")

	# A borrower cancelled while it uses its resource loses it, so the next one
	# opens a replacement.
	never = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| pool.with!(
			open_conn!,
			|conn| {
				pass!(never)
				conn
			},
		),
		[winner!("pool winner")],
	)
	next = pool.with!(open_conn!, |conn| conn)
	Stdout.line!("pool ${won}, then ${next}, opened ${opened.get!().to_str()}")
}

latch_section! : () => {}
latch_section! = || {
	latch = Concurrent.Latch.new!(2)
	results = Concurrent.all!([
		|| {
			latch.wait!()
			"waiter went on"
		},
		|| latch.counting_down!(|| "first counted"),
		|| {
			latch.count_down!()
			"second counted"
		},
	])
	Stdout.line!("latch ${Str.join_with(results, ", ")}")

	# A task cancelled inside `counting_down!` still counts down.
	cancelled = Concurrent.Latch.new!(1)
	never = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| cancelled.counting_down!(
			|| {
				pass!(never)
				"never"
			},
		),
		[winner!("latch winner")],
	)
	cancelled.wait!()
	Stdout.line!("latch ${won}, then open")
}

barrier_section! : () => {}
barrier_section! = || {
	barrier = Concurrent.Barrier.new!(3)
	log = Shared.new!([])
	party! : Str -> (() => Str)
	party! = |name| || {
		barrier.arrive_and_wait!()
		log.modify!(|names| names.append("${name}1"))
		barrier.arrive_and_wait!()
		log.modify!(|names| names.append("${name}2"))
		name
	}
	_ = Concurrent.all!([party!("a"), party!("b"), party!("c")])
	Stdout.line!("barrier ${Str.join_with(log.get!(), " ")}")

	# A party cancelled while it waits takes its arrival back, so the other two
	# open the barrier together.
	pair = Concurrent.Barrier.new!(2)
	won = Concurrent.race!(
		|| {
			pair.arrive_and_wait!()
			"never"
		},
		[winner!("barrier winner")],
	)
	both = Concurrent.all!([
		|| {
			pair.arrive_and_wait!()
			"x"
		},
		|| {
			pair.arrive_and_wait!()
			"y"
		},
	])
	Stdout.line!("barrier ${won}, then ${Str.join_with(both, " ")}")
}

watch_section! : () => {}
watch_section! = || {
	watch = Concurrent.Watch.new!("v0")
	seen = Concurrent.all!([
		|| {
			var $version = watch.current!().version
			var $values = []
			while $version < 2 {
				latest = watch.changed!($version)
				$version = latest.version
				$values = $values.append(latest.value)
			}
			Str.join_with($values, " ")
		},
		|| {
			watch.publish!("v1")
			"published v1"
		},
		|| {
			watch.publish!("v2")
			"published v2"
		},
	])
	Stdout.line!("watch ${Str.join_with(seen, ", ")}")
}

rwlock_section! : () => {}
rwlock_section! = || {
	lock = Concurrent.RwLock.new!()
	log = Shared.new!([])
	readers_in = Shared.new!(0.U64)
	gate = Shared.new!(Bool.False)
	note! = |line| log.modify!(|lines| lines.append(line))
	_ = Concurrent.all!([
		|| lock.read!(
			|| {
				note!("r1 in")
				readers_in.modify!(|n| n + 1)
				pass!(gate)
				note!("r1 out")
			},
		),
		|| lock.read!(
			|| {
				note!("r2 in")
				readers_in.modify!(|n| n + 1)
				pass!(gate)
				note!("r2 out")
			},
		),
		|| {
			reach!(readers_in, 2)
			lock.write!(|| note!("w"))
		},
		|| {
			reach!(readers_in, 2)
			lock.read!(|| note!("r3"))
		},
		|| {
			reach!(readers_in, 2)
			open!(gate)
		},
	])
	Stdout.line!("rwlock ${Str.join_with(log.get!(), ", ")}")

	# A writer cancelled while it waits withdraws its claim.
	held = Concurrent.RwLock.new!()
	release = Shared.new!(Bool.False)
	reading = Shared.new!(Bool.False)
	results = Concurrent.all!([
		|| held.read!(
			|| {
				open!(reading)
				pass!(release)
				"first reader let go;"
			},
		),
		|| {
			pass!(reading)
			won = Concurrent.race!(
				|| held.write!(|| "never"),
				[winner!("writer cancelled")],
			)
			after = held.read!(|| "then a reader got in")
			open!(release)
			"${won}, ${after}"
		},
	])
	Stdout.line!("rwlock ${Str.join_with(results, " ")}")
}

memo_section! : () => {}
memo_section! = || {
	memo = Concurrent.Memo.new!()
	loads = Shared.new!(0.U64)
	waiting = Shared.new!(0.U64)
	gate = Shared.new!(Bool.False)
	load! = |key| {
		loads.modify!(|n| n + 1)
		pass!(gate)
		"value of ${key}"
	}
	asker! : Str -> (() => Str)
	asker! = |name| || {
		waiting.modify!(|n| n + 1)
		value = memo.get!("k", load!)
		"${name}: ${value}"
	}
	got = Concurrent.all!([
		asker!("a"),
		asker!("b"),
		asker!("c"),
		|| {
			reach!(waiting, 3)
			open!(gate)
			"opened"
		},
	])
	Stdout.line!("memo ${Str.join_with(got, ", ")}, loaded ${loads.get!().to_str()} time")

	# A loader cancelled while it loads unmarks the key, and the next asker loads it.
	never = Shared.new!(Bool.False)
	won = Concurrent.race!(
		|| memo.get!(
			"j",
			|_| {
				pass!(never)
				"never"
			},
		),
		[winner!("memo winner")],
	)
	value = memo.get!("j", |key| "fresh ${key}")
	Stdout.line!("memo ${won}, then ${value}")
}

main! = || {
	queue_section!()
	reply_section!()
	semaphore_section!()
	pool_section!()
	latch_section!()
	barrier_section!()
	watch_section!()
	rwlock_section!()
	memo_section!()
}
