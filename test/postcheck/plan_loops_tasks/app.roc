app [main!] { pf: platform "./platform/main.roc" }

import pf.Host

# design.md "Plans And Concurrent Loops", "Sequential equivalence": each of
# these plan loops gives the same result and the same hosted calls when its
# entries run as child tasks, on a host that answers in place and resumes the
# ready task first in the tree, as when they run one at a time.
# test/postcheck/plan_loops_none/app.roc holds the same program, whose platform
# has no tasks.

main! : Str => Str
main! = |name| {
	Host.log!("begin ${name}")
	result = match name {
		"basic" => basic!()
		"limits" => limits!()
		"spawn" => spawn_case!()
		"background" => background!()
		"break" => break_case!()
		"return" => return_case!()
		"try" => try_case!()
		"nested" => nested!()
		"children" => children!()
		"after_break" => after_break!()
		"supervise" => supervise!()
		"supervise_crash" => supervise_crash!()
		"shared" => shared!()
		_ => "unknown"
	}
	Host.log!("end ${name}")
	result
}

work! : Str -> (() => Str)
work! = |name| || {
	Host.log!("start ${name}")
	body = Host.fetch!(name)
	Host.log!("finish ${name}")
	body
}

# Three entries, all started at once and taken in order.
basic! : () => Str
basic! = || {
	var $joined = ""
	for! body in List.concurrently([work!("a"), work!("b"), work!("c")]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Limits leave the order alone: they only keep later entries from starting.
limits! : () => Str
limits! = || {
	var $joined = ""
	plan = List.concurrently([work!("a"), work!("b"), work!("c")]).limit(1).concat(List.concurrently([work!("d"), work!("e")]).limit(2))
	for! body in plan {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Spawned entries come after the loop's own, in the order they are spawned.
spawn_case! : () => Str
spawn_case! = || {
	var $joined = ""
	for! body in List.concurrently([work!("a"), work!("b")]) {
		Host.log!("got ${body}")
		if body == "a/body" {
			spawn work!("c")
			spawn work!("d")
		}
		if body == "b/body" {
			spawn work!("e")
		}
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Background entries run in plan order until only they are left.
background! : () => Str
background! = || {
	var $joined = ""
	plan = List.concurrently([work!("bg1")]).background()
		.concat(List.concurrently([work!("f1")]))
		.concat(List.concurrently([work!("bg2")]).background())
		.concat(List.concurrently([work!("f2")]))
		.concat(List.concurrently([work!("bg3")]).background())
	for! body in plan {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Leaving the loop cancels the entries that haven't started.
break_case! : () => Str
break_case! = || {
	var $last = "none"
	for! body in List.concurrently([work!("a"), work!("b"), work!("c")]) {
		Host.log!("got ${body}")
		$last = body
		if body == "b/body" {
			break
		}
	}
	$last
}

first_match! : Str, Str => Str
first_match! = |outer_name, wanted| {
	for! outer in List.concurrently([work!("${outer_name}-a"), work!("${outer_name}-b")]) {
		for! inner in List.concurrently([work!("${outer}-x"), work!("${outer}-y")]) {
			Host.log!("inner ${inner}")
			if inner == wanted {
				return inner
			}
		}
	}
	"no match"
}

# A return leaves every enclosing loop, innermost first.
return_case! : () => Str
return_case! = || {
	found = first_match!("o", "o-b/body-x/body")
	Host.log!("found ${found}")
	first_match!("p", "p-a/body-x/body")
}

check! : Str -> (() => Try(Str, Str))
check! = |name| || {
	Host.log!("check ${name}")
	body = Host.fetch!(name)
	if name == "bad" {
		Err(body)
	} else {
		Ok(body)
	}
}

all_ok! : List(() => Try(Str, Str)) => Try(Str, Str)
all_ok! = |checks| {
	var $joined = ""
	for! result in List.concurrently(checks) {
		$joined = Str.concat($joined, result?)
	}
	Ok($joined)
}

# ? leaves the loop like a return.
try_case! : () => Str
try_case! = || {
	match all_ok!([check!("a"), check!("bad"), check!("c")]) {
		Ok(joined) => joined
		Err(body) => "err ${body}"
	}
}

# An entry runs its own loop, so a child's tasks are children of a child.
nested_entry! : Str -> (() => Str)
nested_entry! = |name| || {
	Host.log!("enter ${name}")
	var $joined = name
	for! body in List.concurrently([work!("${name}-1"), work!("${name}-2")]) {
		$joined = Str.concat($joined, body)
	}
	Host.log!("leave ${name}")
	$joined
}

nested! : () => Str
nested! = || {
	var $joined = ""
	for! body in List.concurrently([nested_entry!("o1"), nested_entry!("o2"), work!("o3")]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# The loop's body runs between the results, interleaved with later entries.
children! : () => Str
children! = || {
	var $joined = ""
	for! body in List.concurrently([work!("a"), work!("b")]) {
		Host.log!("body ${body}")
		inner = Host.fetch!("${body}-again")
		$joined = Str.concat($joined, inner)
	}
	$joined
}

# The code after a loop that can break is reached by two paths, and holds a
# concurrent loop of its own.
after_break! : () => Str
after_break! = || {
	var $joined = ""
	var $i = 0.U64
	while $i < 3 {
		if Host.fetch!("w") == "stop" {
			break
		}
		$i = $i + 1
	}
	for! body in List.concurrently([work!("a"), work!("b")]) {
		if body == "a/body" {
			break
		}
	}
	for! body in List.concurrently([work!("c"), work!("d")]) {
		$joined = Str.concat($joined, body)
	}
	$joined
}

# A supervised function that fetches, one that doesn't, one that supervises
# another and runs a loop, and supervised entries.
supervise! : () => Str
supervise! = || {
	fetched = Concurrent.supervise!({ max_restarts: 3 }, work!("a"))
	Host.log!("fetched ${fetched}")
	logged = Concurrent.supervise!(
		{ max_restarts: 0 },
		|| {
			Host.log!("no fetch")
			Str.concat(fetched, "!")
		},
	)
	nested = Concurrent.supervise!(
		{ max_restarts: 1 },
		|| {
			var $joined = Concurrent.supervise!({ max_restarts: 1 }, work!("b"))
			for! body in List.concurrently([work!("c"), work!("d")]) {
				$joined = Str.concat($joined, body)
			}
			$joined
		},
	)
	var $joined = Str.concat(logged, nested)
	for! body in List.concurrently([|| Concurrent.supervise!({ max_restarts: 1 }, work!("e")), work!("f")]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Every run crashes after its loop. The inner supervise! gives up after its
# third run, and the outer one restarts it once. A `None` build would crash in
# the first run, so it doesn't run this case.
supervise_crash! : () => Str
supervise_crash! = || {
	Concurrent.supervise!(
		{ max_restarts: 1 },
		|| {
			Host.log!("outer")
			Concurrent.supervise!({ max_restarts: 2 }, || crashing!("x"))
		},
	)
}

crashing! : Str => Str
crashing! = |name| {
	Host.log!("run")
	var $bytes = 0
	for! body in List.concurrently([work!(name)]) {
		$bytes = $bytes + Str.count_utf8_bytes(body)
	}
	if $bytes > 0 {
		crash "the run crashed"
	}
	name
}

# Entries that update one state between their pauses.
shared! : () => Str
shared! = || {
	log = Shared.new!([])
	note! : Str -> (() => Str)
	note! = |name| || {
		body = Host.fetch!(name)
		log.modify!(|entries| entries.append("${body}, a string too long to be small"))
		body
	}
	var $joined = ""
	for! body in List.concurrently([note!("a"), note!("b"), note!("c")]) {
		$joined = Str.concat($joined, body)
	}
	Host.log!("logged ${log.get!().len().to_str()}")
	Str.concat($joined, Str.join_with(log.get!(), ";"))
}
