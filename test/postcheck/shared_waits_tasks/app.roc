app [main!] { pf: platform "./platform/main.roc" }

import pf.Host

# design.md "Shared State", "Programs without tasks.": each of these programs,
# whose tasks wait for each other's updates, gives the same result and the same
# hosted calls when a platform without tasks runs them itself as when a host
# runs them that answers in place and resumes the ready task first in the tree.
# test/postcheck/shared_waits_none/app.roc holds the same program, whose
# platform has no tasks.

main! : Str => Str
main! = |name| {
	Host.log!("begin ${name}")
	result = match name {
		"queue" => queue!()
		"body" => body_waits!()
		"body_first" => body_first!()
		"nested" => nested!()
		"cancelled" => cancelled!()
		"oldest" => oldest!()
		_ => "unknown"
	}
	Host.log!("end ${name}")
	result
}

# Entries that wait for each other: a queue of one item between two that put
# and two that take.
queue! : () => Str
queue! = || {
	queue = Shared.new!([])
	put! : Str -> (() => Str)
	put! = |name| || {
		body = Host.fetch!(name)
		for part in ["one", "two", "three"] {
			item = "${body}, part ${part}, too long to be small"
			queue.update!(|items| if (items.is_empty()) Set(items.append(item), {}) else Wait)
			Host.log!("put ${item}")
		}
		body
	}
	take! : Str -> (() => Str)
	take! = |name| || {
		var $taken = name
		var $left = 3
		while $left > 0 {
			item = queue.update!(
				|items| match items {
					[first, .. as rest] => Set(rest, first)
					[] => Wait
				},
			)
			Host.log!("${name} took ${item}")
			$taken = Str.concat($taken, item)
			$left = $left - 1
		}
		$taken
	}
	var $joined = ""
	for! body in List.concurrently([take!("x"), put!("a"), take!("y"), put!("b")]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# The body waits for what its entries do. An entry that has not begun runs then,
# since nothing else can, and the ones after it only when they are asked for.
body_waits! : () => Str
body_waits! = || {
	done = Shared.new!(0)
	work! : Str -> (() => Str)
	work! = |name| || {
		body = Host.fetch!(name)
		done.update!(|n| Set(n + 1, {}))
		Host.log!("did ${name}")
		body
	}
	var $joined = ""
	for! body in List.concurrently([work!("a"), work!("b"), work!("c"), work!("d")]).concat(List.concurrently([work!("e"), work!("f")]).limit(1)) {
		Host.log!("got ${body}")
		so_far = done.update!(|n| if (n >= 3) Keep(n) else Wait)
		Host.log!("saw ${so_far.to_str()}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# The body waits for what its entries do, which can't suspend: the second does it
# while the first one's body waits.
body_first! : () => Str
body_first! = || {
	done = Shared.new!(0)
	work! : Str -> (() => Str)
	work! = |name| || {
		done.modify!(|n| n + 1)
		Host.log!("did ${name}")
		name
	}
	var $joined = ""
	for! body in List.concurrently([work!("a"), work!("b"), work!("c")]) {
		so_far = done.update!(|n| if (n >= 2) Keep(n) else Wait)
		Host.log!("got ${body} at ${so_far.to_str()}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# Entries of inner loops wait for entries of the outer one, and for each other.
nested! : () => Str
nested! = || {
	turn = Shared.new!(0)
	step! : U64, Str => {}
	step! = |mine, name| {
		turn.update!(|n| if (n == mine) Set(n + 1, {}) else Wait)
		Host.log!("turn ${name}")
	}
	inner! : U64, Str -> (() => Str)
	inner! = |base, name| || {
		var $joined = name
		for! body in List.concurrently([
			|| {
				step!(base + 4, "${name} late")
				"late "
			},
			|| {
				step!(base, "${name} early")
				"early "
			},
		]) {
			Host.log!("${name} got ${body}")
			$joined = Str.concat($joined, body)
		}
		$joined
	}
	var $joined = ""
	for! body in List.concurrently([
		inner!(1, "x"),
		inner!(2, "y"),
		|| {
			step!(0, "third")
			step!(3, "third")
			step!(4, "third")
			"third "
		},
	]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}

# A loop's exit cancels entries that wait, with a probe of their own, and one
# that a store has already woken; the next loop's entry waits on the same cell.
cancelled! : () => Str
cancelled! = || {
	cell = Shared.new!("")
	take! : Str -> (() => Str)
	take! = |name| || {
		Host.log!("wait ${name}")
		taken = cell.update!(|text| if (text.is_empty()) Wait else Set("", text))
		Host.log!("${name} took ${taken}")
		taken
	}
	put! : Str -> (() => Str)
	put! = |text| || {
		cell.update!(|_| Set(text, {}))
		"put"
	}
	first = exit_at!([take!("x"), take!("y"), put!("a text that is too long to be small")])
	second = exit_at!([take!("z"), put!("another that is too long to be small")])
	Str.concat(first, second)
}

exit_at! : List((() => Str)) => Str
exit_at! = |entries| {
	for! body in List.concurrently(entries) {
		Host.log!("got ${body}")
		if body == "put" {
			return body
		}
	}
	"none"
}

# The waiters a store lets go on do so oldest first, though a younger one comes
# first in the tree.
oldest! : () => Str
oldest! = || {
	gate = Shared.new!(0)
	count = Shared.new!(0)
	younger! : () => Str
	younger! = || {
		gate.update!(|n| if (n == 0) Wait else Keep({}))
		Host.log!("younger waits")
		n = count.update!(|left| if (left == 0) Wait else Set(left - 1, left))
		Host.log!("younger took ${n.to_str()}")
		"younger "
	}
	older! : () => Str
	older! = || {
		gate.update!(|_| Set(1, {}))
		Host.log!("older waits")
		n = count.update!(|left| if (left == 0) Wait else Set(left - 1, left))
		Host.log!("older took ${n.to_str()}")
		"older "
	}
	feeder! : () => Str
	feeder! = || {
		count.update!(|_| Set(2, {}))
		Host.log!("fed")
		"fed "
	}
	var $joined = ""
	for! body in List.concurrently([younger!, older!, feeder!]) {
		Host.log!("got ${body}")
		$joined = Str.concat($joined, body)
	}
	$joined
}
