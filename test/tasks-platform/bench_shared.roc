app [main!] { pf: platform "./platform/main.roc" }

import pf.Clock
import pf.Scheduler
import pf.Stdout

# Times updates of shared state: alone, of a list changed in place, of state
# that holds its own handle, by tasks that pause between updates, and by two
# tasks that wait for each other at every update.
main! : () => I32
main! = || {
	count = 2000000
	say!("get!", per!(|n| gets!(Shared.new!(n), n), count))
	say!("modify!", per!(|n| modifies!(Shared.new!(0.U64), n), count))
	say!("update!", per!(|n| updates!(Shared.new!(0.U64), n), count))
	say!("modify! of a list", per!(|n| pushes!(Shared.new!([0.U64]), n), count))
	say!("no shared state", per!(|n| plain!(n), count))
	say!("yield and modify!", per!(|n| paused!(Shared.new!(1), n, Bool.True), 200000))
	say!("yield", per!(|n| paused!(Shared.new!(1), n, Bool.False), 200000))
	say!("turns", per!(|n| turns!(n), 200000))
	0
}

say! : Str, U64 => {}
say! = |name, tenths| Stdout.line!("${name}: ${(tenths / 10).to_str()}.${(tenths % 10).to_str()} ns")

per! : (U64 => U64), U64 => U64
per! = |run!, n| {
	_warm = run!(n / 10)
	start = Clock.monotonic_ns!()
	sum = run!(n)
	elapsed = Clock.monotonic_ns!() - start
	if sum == 0 {
		0
	} else {
		elapsed * 10 / n
	}
}

gets! : Shared(U64), U64 => U64
gets! = |h, n| {
	var $sum = 0.U64
	var $i = 0.U64
	while $i < n {
		$sum = $sum + h.get!()
		$i = $i + 1
	}
	$sum
}

modifies! : Shared(U64), U64 => U64
modifies! = |h, n| {
	var $i = 0.U64
	while $i < n {
		step = $i
		h.modify!(|x| x + step)
		$i = $i + 1
	}
	h.get!() + 1
}

updates! : Shared(U64), U64 => U64
updates! = |h, n| {
	var $sum = 0.U64
	var $i = 0.U64
	while $i < n {
		$sum = $sum + h.update!(|x| Set(x + 1, x))
		$i = $i + 1
	}
	$sum + 1
}

pushes! : Shared(List(U64)), U64 => U64
pushes! = |h, n| {
	var $i = 0.U64
	while $i < n {
		step = $i
		h.modify!(|xs| xs.append(step))
		$i = $i + 1
	}
	h.get!().len()
}

plain! : U64 => U64
plain! = |n| {
	var $sum = 1.U64
	var $i = 0.U64
	while $i < n {
		$sum = $sum + $i
		$i = $i + 1
	}
	$sum
}

paused! : Shared(U64), U64, Bool => U64
paused! = |h, n, share| {
	var $i = 0.U64
	while $i < n {
		Scheduler.yield!()
		if share {
			h.modify!(|x| x + 1)
		}
		$i = $i + 1
	}
	h.get!()
}

turn : Shared(U64), U64, U64 -> (() => U64)
turn = |h, n, mine| || {
	var $i = 0.U64
	while $i < n {
		h.update!(
			|x| if x % 2 == mine {
				Set(x + 1, {})
			} else {
				Wait
			},
		)
		$i = $i + 1
	}
	1
}

turns! : U64 => U64
turns! = |n| {
	h = Shared.new!(0.U64)
	var $sum = 0.U64
	for! x in List.concurrently([turn(h, n / 2, 0), turn(h, n / 2, 1)]) {
		$sum = $sum + x
	}
	$sum
}
