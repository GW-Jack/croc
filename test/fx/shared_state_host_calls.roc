app [main!] { pf: platform "./platform/main_effects.roc" }

import pf.Effects
import pf.Stdout

# design.md "Shared State", "Programs without tasks.": a function value that may
# wait, called by Roc code, by the host, and by a function of the host's that
# Roc code called.

main! = || {
	count = Shared.new!(0.I64)

	# Waits until the count has reached `n`, then says so.
	reach! : Str -> Box((I64 => I64))
	reach! = |name| Box.box(
		|n| {
			so_far = count.update!(|c| if (c >= n) Keep(c) else Wait)
			Stdout.line!("${name} reached ${n.to_str()} at ${so_far.to_str()}")
			so_far
		},
	)
	bump! : Str -> Box((I64 => I64))
	bump! = |name| Box.box(
		|n| {
			count.modify!(|c| c + n)
			Stdout.line!("${name} bumped by ${n.to_str()}")
			n
		},
	)

	# The host calls one while the count is there already.
	Stdout.line!("host got ${Effects.call!(reach!("host call, too long to be small"), 0).to_str()}")

	# A function of the host's that Roc code calls, and one that calls a
	# function that may wait.
	plus! = Box.unbox(Effects.boxed_add!(40))
	Stdout.line!("plus ${plus!(2).to_str()}")
	around! = Box.unbox(Effects.boxed_around!(reach!("inner, too long to be small"), 100))
	Stdout.line!("around ${around!(0).to_str()}")

	# Each kind in a loop, where only the first two wait and the host's
	# function changes nothing.
	entry! : Box((I64 => I64)), I64 -> (() => I64)
	entry! = |box, n| || {
		f! = Box.unbox(box)
		f!(n)
	}
	for! n in List.concurrently([
		entry!(reach!("first, too long to be small"), 3),
		entry!(reach!("second, too long to be small"), 2),
		entry!(Effects.boxed_add!(1000), 1),
		entry!(bump!("third"), 2),
		|| {
			# The host runs a bump inside a run whose task called it.
			Effects.call!(bump!("fourth"), 1)
		},
	]) {
		Stdout.line!("end ${n.to_str()}")
	}
}
