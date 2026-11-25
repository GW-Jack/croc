main! = |args| {
	gate = Shared.new!(0.I64)
	wait_for! : Str -> Box((I64 => I64))
	wait_for! = |name| Box.box(
		|n| {
			got = gate.update!(|g| if (g >= n) Keep(g) else Wait)
			echo!("${name} saw ${got.to_str()}\n")
			got + n
		},
	)
	add! : Box((I64 => I64))
	add! = Box.box(
		|n| {
			gate.modify!(|g| g + n)
			n
		},
	)
	first! = if (args.len() > 100) add! else wait_for!("first, a name too long to be small")
	entry! : Box((I64 => I64)), I64 -> (() => I64)
	entry! = |box, n| || {
		f! = Box.unbox(box)
		f!(n)
	}
	var $sum = 0.I64
	for! r in List.concurrently([
		entry!(first!, 5),
		entry!(add!, 2),
		entry!(wait_for!("second, a name too long to be small"), 2),
		entry!(add!, 3),
	]) {
		$sum = $sum + r
	}
	echo!("sum ${$sum.to_str()}\n")
	Ok({})
}
