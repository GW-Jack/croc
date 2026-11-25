app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "Programs without tasks.": tasks that wait for each
# other's updates on a platform that has no tasks.

main! = || {
	queue = Shared.new!([])
	put! : Str -> (() => Str)
	put! = |name| || {
		for part in ["one", "two"] {
			item = "${name}, part ${part}, too long to be small"
			queue.update!(|items| if (items.is_empty()) Set(items.append(item), {}) else Wait)
			Stdout.line!("put ${item}")
		}
		name
	}
	take! : Str -> (() => Str)
	take! = |name| || {
		var $left = 2
		while $left > 0 {
			item = queue.update!(
				|items| match items {
					[first, .. as rest] => Set(rest, first)
					[] => Wait
				},
			)
			Stdout.line!("${name} took ${item}")
			$left = $left - 1
		}
		name
	}
	for! name in List.concurrently([take!("x"), put!("a"), take!("y"), put!("b")]) {
		Stdout.line!("end ${name}")
	}

	# The body waits, so an entry that nothing asked for yet runs.
	done = Shared.new!(0.U64)
	work! : Str -> (() => Str)
	work! = |name| || {
		done.update!(|n| Set(n + 1, {}))
		Stdout.line!("did ${name}")
		name
	}
	for! name in List.concurrently([work!("a"), work!("b"), work!("c")]) {
		so_far = done.update!(|n| if (n >= 2) Keep(n) else Wait)
		Stdout.line!("end ${name} at ${so_far.to_str()}")
	}
}
