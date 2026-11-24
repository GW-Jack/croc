app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Plans And Concurrent Loops", "The library.": `all!`, `all_ok!`,
# `race!` and `both!` are `for!` loops over plans. Where the entries can't
# pause, each loop runs them one at a time in input order, so `all_ok!` never
# starts the entries after the first `Err`, `race!` never starts any function
# after its first, and a background entry after the others never starts.
# `supervise!` runs its function once, as no child task.

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

show : List(U64) -> Str
show = |numbers| Str.join_with(numbers.map(|n| n.to_str()), ", ")

show_try : Try(List(U64), Str) -> Str
show_try = |result|
	match result {
		Ok(numbers) => "Ok(${show(numbers)})"
		Err(name) => "Err(${name})"
	}

main! = || {
	early = List.concurrently([entry!("early bg", 100)]).background()
	middle = List.concurrently([entry!("a", 1), entry!("b", 2)]).limit(1).shielded()
	late = List.concurrently([entry!("late bg", 200)]).background()
	Stdout.line!("all ${show(early.concat(middle).concat(late).all!())}")

	Stdout.line!("Concurrent.all ${show(Concurrent.all!([entry!("c", 3), entry!("d", 4)]))}")

	Stdout.line!("all_ok ${show_try(List.concurrently([ok!("e", 5), ok!("f", 6)]).all_ok!())}")

	Stdout.line!("Concurrent.all_ok ${show_try(Concurrent.all_ok!([ok!("g", 7), err!("h"), ok!("never", 0)]))}")

	Stdout.line!("race ${Concurrent.race!(entry!("i", 9), [entry!("never", 0)]).to_str()}")

	(first, second) = Concurrent.both!(entry!("j", 10), || "k")
	Stdout.line!("both ${first.to_str()} ${second}")

	Stdout.line!("supervise ${Concurrent.supervise!({ max_restarts: 1 }, entry!("l", 11)).to_str()}")
}
