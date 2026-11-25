app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State": a handle names state that every copy of the handle
# reaches, an update's function runs on it with nothing between its read and
# its write, and the state can hold anything, functions and its own handle
# included.

count_to! : Shared(U64), U64 => {}
count_to! = |counter, limit| {
	var $i = 0.U64
	while $i < limit {
		counter.modify!(|n| n + 1)
		$i = $i + 1
	}
}

take! : Shared(List(Str)) => Try(Str, [Empty])
take! = |names| names.update!(
	|list| match list {
		[] => Keep(Err(Empty))
		[first, .. as rest] => Set(rest, Ok(first))
	},
)

Jobs : { pending : List(() => {}), done : U64 }

run_all! : Shared(Jobs) => {}
run_all! = |jobs| {
	next = jobs.update!(
		|state| match state.pending {
			[] => Keep(Finished)
			[job, .. as rest] => Set({ ..state, pending: rest }, Run(job))
		},
	)
	match next {
		Finished => {}
		Run(job) => {
			job()
			jobs.modify!(|state| { ..state, done: state.done + 1 })
			run_all!(jobs)
		}
	}
}

show : Try(Str, [Empty]) -> Str
show = |taken| match taken {
	Ok(name) => name
	Err(Empty) => "empty"
}

main! = || {
	# Two handles that start equal are different state, and a copy is the same.
	a = Shared.new!(0)
	b = Shared.new!(0)
	copy = a
	count_to!(a, 3)
	count_to!(copy, 4)
	count_to!(b, 1)
	Stdout.line!("counts ${a.get!().to_str()} ${copy.get!().to_str()} ${b.get!().to_str()}")

	# A loop makes a new cell on each iteration.
	var $cells = []
	for start in [10.U64, 20, 30] {
		$cells = $cells.append(Shared.new!(start))
	}
	for cell in $cells {
		cell.modify!(|n| n + 1)
	}
	var $total = 0
	for cell in $cells {
		$total = $total + cell.get!()
	}
	Stdout.line!("cells ${$total.to_str()}")

	# Counted states, taken apart and put back.
	names = Shared.new!(["a name too long to be stored inline", "another name too long to be stored inline"])
	names.modify!(|list| list.append("last"))
	before = names.get!()
	Stdout.line!("take ${show(take!(names))}")
	Stdout.line!("take ${show(take!(names))}")
	Stdout.line!("take ${show(take!(names))}")
	Stdout.line!("take ${show(take!(names))}")
	Stdout.line!("before ${before.len().to_str()}")

	# The state's functions capture other handles, and its own.
	log = Shared.new!([])
	jobs = Shared.new!({ pending: [], done: 0 })
	note = |text| || log.modify!(|lines| lines.append(text))
	more! = || jobs.modify!(|state| { ..state, pending: state.pending.append(note("three")) })
	jobs.modify!(|state| { ..state, pending: [note("one"), more!, note("two")] })
	run_all!(jobs)
	Stdout.line!("jobs ${jobs.get!().done.to_str()} ${Str.join_with(log.get!(), ", ")}")

	# Children reach their parent's state.
	shared = Shared.new!("")
	add = |text| || shared.update!(|so_far| Set(so_far.concat(text), text))
	results = Concurrent.all!([add("x"), add("y"), add("z")])
	Stdout.line!("children ${shared.get!()} ${Str.join_with(results, "")}")
	Stdout.line!("inspect ${Str.inspect(shared)}")
}
