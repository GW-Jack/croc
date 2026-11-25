app [main!] { pf: platform "./platform/main.roc" }

import pf.File
import pf.Sleep
import pf.Stdout

# One erased callable type whose members suspend, do I/O that can't, and only
# compute.
steps : Str -> List(Box((U64 => U64)))
steps = |label| [
	Box.box(
		|n| {
			Sleep.millis!(1)
			n + Str.count_utf8_bytes(label)
		},
	),
	Box.box(
		|n| {
			Stdout.line!("${label} at ${n.to_str()}")
			n + 1
		},
	),
	Box.box(|n| n * 2),
]

run_all! : List(Box((U64 => U64))), U64 => U64
run_all! = |boxes, start| {
	var $n = start
	for box in boxes {
		f! = Box.unbox(box)
		$n = f!($n)
	}
	$n
}

# A box that returns a box: a suspending call whose result is an erased
# callable, then a call through it.
later : Str -> Box((U64 => Box((Str => Str))))
later = |name| Box.box(
	|millis| {
		Sleep.millis!(millis)
		Box.box(
			|suffix| {
				Sleep.millis!(millis)
				"${name}${suffix} after ${millis.to_str()}"
			},
		)
	},
)

# Constants that hold boxed effectful functions.
pause : Box((U64 => U64))
pause = Box.box(
	|n| {
		Sleep.millis!(n)
		n
	},
)

# A constant read at two types: alone, where nothing can pause, and beside
# `pause`.
add : Box((U64 => U64))
add = Box.box(
	|n| {
		Stdout.line!("adding to ${n.to_str()}")
		n + 40
	},
)

either : Bool -> Box((U64 => U64))
either = |yes| if (yes) pause else add

# A pure boxed function of the same shape. Calls through it never suspend.
double : Box((U64 -> U64))
double = Box.box(|n| n * 2)

apply_pure : Box((U64 -> U64)), U64 -> U64
apply_pure = |box, n| Box.unbox(box)(n)

Task := { name : Str, run : Box((() => Try(Str, [Missing(Str)]))) }

read : Str -> Task
read = |name| {
	name,
	run: Box.box(
		|| {
			match File.read_utf8!("test/tasks-platform/data/${name}") {
				Ok(text) => Ok("${name} has ${Str.count_utf8_bytes(text).to_str()} bytes")
				Err(FileErr(_)) => Err(Missing(name))
			}
		},
	),
}

countdown! : Box((U64 => U64)), U64 => U64
countdown! = |box, n| {
	f! = Box.unbox(box)
	if (n == 0) f!(1) else countdown!(box, n - f!(1))
}

main! : () => I32
main! = || {
	Stdout.line!(run_all!(steps("a label too long to be small"), 1).to_str())

	outer! = Box.unbox(later("a name too long to be a small string "))
	inner! = Box.unbox(outer!(2))
	Stdout.line!(inner!("and a suffix"))

	wait! = Box.unbox(pause)
	Stdout.line!("paused ${wait!(3).to_str()}, doubled ${apply_pure(double, 21).to_str()}")
	Stdout.line!("counted down to ${countdown!(pause, 5).to_str()}")

	add! = Box.unbox(add)
	Stdout.line!("added ${add!(2).to_str()}")
	for yes in [True, False] {
		Stdout.line!("either ${countdown!(either(yes), 0).to_str()}")
	}

	for task in [read("hello.txt"), read("missing.txt")] {
		run! = Box.unbox(task.run)
		match run!() {
			Ok(text) => Stdout.line!(text)
			Err(Missing(name)) => Stdout.line!("no ${name}")
		}
	}

	# Boxed functions as the entries of a concurrent loop.
	var $total = 0
	for! n in List.concurrently(
		steps("child").map(
			|box| || {
				f! = Box.unbox(box)
				f!(10)
			},
		),
	) {
		$total = $total + n
	}
	Stdout.line!("entries total ${$total.to_str()}")
	0
}
