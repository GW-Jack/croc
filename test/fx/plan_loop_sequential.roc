app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Plans And Concurrent Loops", "Sequential lowering.": a `for!`
# loop over a plan runs its entries one at a time, in order. `spawn` appends
# an entry, a background entry is dropped once only background entries are
# left, limits and shields change nothing, and leaving the loop early by
# `break`, `return` or `?` cancels the entries that haven't started.

entry! : Str, U64 -> (() => U64)
entry! = |name, n| || {
	Stdout.line!("run ${name}")
	n
}

ok! : Str, U64 -> (() => Try(U64, Str))
ok! = |name, n| || {
	Stdout.line!("run ${name}")
	Ok(n)
}

err! : Str -> (() => Try(U64, Str))
err! = |name| || {
	Stdout.line!("run ${name}")
	Err(name)
}

first_over! : U64 => U64
first_over! = |limit| {
	for! a in List.concurrently([entry!("i", 1), entry!("j", 5)]) {
		for! b in List.concurrently([entry!("k", a), entry!("l", a + 1), entry!("never", 0)]) {
			if b > limit {
				return b
			}
		}
	}
	0
}

sum_ok! : List(() => Try(U64, Str)) => Try(U64, Str)
sum_ok! = |fs| {
	var $sum = 0
	for! r in List.concurrently(fs) {
		$sum = $sum + r?
	}
	Ok($sum)
}

main! = || {
	var $sum = 0
	for! x in List.concurrently([entry!("a", 1), entry!("b", 2), entry!("c", 3)]) {
		Stdout.line!("got ${x.to_str()}")
		$sum = $sum + x
	}
	Stdout.line!("sum ${$sum.to_str()}")

	for! x in List.concurrently([entry!("d", 10)]) {
		Stdout.line!("got ${x.to_str()}")
		if x == 10 {
			spawn entry!("e", 20)
			for n in [1, 2] {
				match n {
					1 => spawn entry!("f", 30)
					_ => {}
				}
			}
		}
	}

	foreground = List.concurrently([entry!("fg", 2)]).limit(1).shielded()
	plan = List.concurrently([entry!("bg", 1)]).background().concat(foreground).concat(List.concurrently([entry!("late bg", 3)]).background())
	for! x in plan {
		Stdout.line!("got ${x.to_str()}")
	}

	for! x in List.concurrently([entry!("g", 1), entry!("h", 2)]) {
		Stdout.line!("got ${x.to_str()}")
		break
	}
	Stdout.line!("after break")

	Stdout.line!("first over ${first_over!(1).to_str()}")

	match sum_ok!([ok!("m", 1), err!("n"), ok!("o", 3)]) {
		Ok(total) => Stdout.line!("total ${total.to_str()}")
		Err(name) => Stdout.line!("failed at ${name}")
	}

	empty : List(() => U64)
	empty = []
	for! x in List.concurrently(empty) {
		Stdout.line!("never ${x.to_str()}")
	}
	Stdout.line!("done")
}
