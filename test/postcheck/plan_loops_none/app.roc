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
		"boxed" => boxed!()
		"supervise_crash" => supervise_crash!()
		"shared" => shared!()
		"cleanups" => cleanups!()
		"cycles" => cycles!()
		"cleanups_crash" => cleanups_crash!()
		"stalled" => stalled!()
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

# Each entry holds a permit through its pause, and counts itself lost if it
# doesn't come back from there. Leaving the loop cancels those that haven't.
cleanups! : () => Str
cleanups! = || {
	permits = Shared.new!(3)
	lost = Shared.new!([])
	hold! : Str -> (() => Str)
	hold! = |name| || {
		permits.modify!(|n| n - 1)
		permits.finally!(
			|n| n + 1,
			|| lost.on_failure!(
				|names| names.append("${name}, whose name is too long to be small"),
				|| Host.fetch!(name),
			),
		)
	}
	var $joined = ""
	for! body in List.concurrently([hold!("a"), hold!("b")]) {
		$joined = Str.concat($joined, body)
	}
	for! body in List.concurrently([hold!("c"), hold!("d"), hold!("e")]) {
		$joined = Str.concat($joined, body)
		break
	}
	"${$joined} ${permits.get!().to_str()} ${Str.join_with(lost.get!(), ";")}"
}

# Each entry's state holds a function that holds the state's handle. One of them
# is also in the loop's own state, which is on a cycle too.
cycles! : () => Str
cycles! = || {
	kept : Shared(List(() => Str))
	kept = Shared.new!([])
	kept.modify!(|functions| functions.append(|| "kept ${kept.get!().len().to_str()}"))
	knot! : Str, Bool -> (() => Str)
	knot! = |name, keep| || {
		own : Shared(List(() => Str))
		own = Shared.new!([])
		count! : () => Str
		count! = || "${name} ${own.get!().len().to_str()}, a string too long to be small"
		own.modify!(|functions| functions.append(count!))
		if keep {
			kept.modify!(|functions| functions.append(count!))
		}
		Host.fetch!(name)
	}
	var $joined = ""
	for! body in List.concurrently([knot!("a", False), knot!("b", True), knot!("c", False)]) {
		$joined = Str.concat($joined, body)
	}
	for function! in kept.get!() {
		$joined = Str.concat($joined, function!())
	}
	$joined
}

# Every run crashes inside two cleanups. The inner one's runs first, after the
# run's entries are gone.
cleanups_crash! : () => Str
cleanups_crash! = || {
	order = Shared.new!("")
	tries : Shared(U64)
	tries = Shared.new!(0)
	result = Concurrent.supervise!(
		{ max_restarts: 2 },
		|| {
			number = tries.update!(|n| Set(n + 1, n))
			order.finally!(
				|text| "${text}outer ${number.to_str()} ",
				|| order.on_failure!(
					|text| "${text}inner ${number.to_str()} ",
					|| {
						for! body in List.concurrently([work!("x"), || order.on_failure!(|text| "${text}entry ", work!("y"))]) {
							if number < 2 and Str.count_utf8_bytes(body) > 0 {
								crash "the body crashed"
							}
						}
						"done "
					},
				),
			)
		},
	)
	Str.concat(result, order.get!())
}

# Entries that wait for state no task is left to store: the one that began to wait
# last crashes, and the supervisor's next attempt finds the state it needs.
stalled! : () => Str
stalled! = || {
	order = Shared.new!("")
	tries : Shared(U64)
	tries = Shared.new!(0)
	result = Concurrent.supervise!(
		{ max_restarts: 1 },
		|| {
			opened = Shared.new!(tries.update!(|n| Set(n + 1, n)))
			pass! : Str -> (() => Str)
			pass! = |name| || order.on_failure!(
				|text| "${text}${name} ",
				|| {
					body = Host.fetch!(name)
					opened.update!(|n| if (n == 0) Wait else Keep({}))
					body
				},
			)
			var $joined = ""
			for! body in List.concurrently([pass!("a"), pass!("b")]) {
				$joined = Str.concat($joined, body)
			}
			$joined
		},
	)
	Str.concat(result, order.get!())
}

# Functions of one erased callable type: the first suspends in a tasks build,
# and the others can't, whichever of them a call enters. A box may return a
# box, be held by a record or a constant, or be an entry of a loop.
Step : { name : Str, run : Box((Str => Str)) }

steps : Str -> List(Step)
steps = |label| [
	{ name: "fetch", run: Box.box(|name| Host.fetch!("${label} ${name}")) },
	{
		name: "log",
		run: Box.box(
			|name| {
				Host.log!("${label} logs ${name}")
				"${name} logged by ${label}"
			},
		),
	},
	{ name: "pure", run: Box.box(|name| "${name} and ${label}") },
]

# A box that returns a box: both calls suspend, and the second captures what
# the first fetched.
fetcher : Str -> Box((Str => Box((Str => Str))))
fetcher = |prefix| Box.box(
	|name| {
		first = Host.fetch!("${prefix} ${name}")
		Box.box(|suffix| Str.concat(first, Host.fetch!(suffix)))
	},
)

constant : Box((Str => Str))
constant = Box.box(
	|name| {
		Host.log!("constant")
		Host.fetch!(name)
	},
)

# A constant read at two types, alone and through `either`: calls through it
# alone never suspend, and those through the other type may.
common : Box((Str => Str))
common = Box.box(
	|name| {
		Host.log!("common ${name}")
		Str.concat(name, " common")
	},
)

either : Bool -> Box((Str => Str))
either = |yes| if (yes) constant else common

# The same inside a list, a record and a recursive type.
Tree := [Leaf(Box((Str => Str))), Node(List(Tree))]

tree : Tree
tree = Node([Leaf(common), Node([Leaf(constant), Leaf(common)])])

walk! : Tree, Str => Str
walk! = |node, name| match node {
	Leaf(box) => repeat!(box, name, 0)
	Node(kids) => {
		var $name = name
		for kid in kids {
			$name = walk!(kid, $name)
		}
		$name
	}
}

compose : Box((Str => Str)), Box((Str => Str)) -> Box((Str => Str))
compose = |first, second| Box.box(
	|name| {
		first! = Box.unbox(first)
		second! = Box.unbox(second)
		first!(second!(name))
	},
)

# Boxed pure functions of the same shape never suspend.
pure_box : Box((Str -> Str))
pure_box = Box.box(|name| "pure ${name}")

call_pure : Box((Str -> Str)), Str -> Str
call_pure = |box, name| Box.unbox(box)(name)

repeat! : Box((Str => Str)), Str, U64 => Str
repeat! = |box, name, count| {
	f! = Box.unbox(box)
	if (count == 0) f!(name) else repeat!(box, f!(name), count - 1)
}

boxed! : () => Str
boxed! = || {
	var $joined = ""
	for step in steps("a label too long to be a small string") {
		f! = Box.unbox(step.run)
		$joined = Str.concat($joined, f!(step.name))
	}
	outer! = Box.unbox(fetcher("a prefix too long to be a small string"))
	inner! = Box.unbox(outer!("outer"))
	$joined = Str.concat($joined, inner!("inner"))
	constant! = Box.unbox(constant)
	$joined = Str.concat($joined, constant!("c"))
	$joined = Str.concat($joined, call_pure(pure_box, "p"))
	$joined = Str.concat($joined, repeat!(constant, "r", 2))
	common! = Box.unbox(common)
	$joined = Str.concat($joined, common!("alone"))
	yes = Str.count_utf8_bytes($joined) > 1
	for box in [either(!yes), either(yes), common] {
		$joined = Str.concat($joined, repeat!(box, "e", 1))
	}
	$joined = Str.concat($joined, walk!(tree, "t"))
	$joined = Str.concat($joined, repeat!(compose(common, either(yes)), "m", 1))
	for! body in List.concurrently(
		steps("entry").map(
			|step| || {
				f! = Box.unbox(step.run)
				f!(step.name)
			},
		),
	) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}
