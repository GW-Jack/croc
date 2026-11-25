app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "Cleanups.": `finally!` and `on_failure!` where nothing
# is cancelled, so a cleanup runs only when its body returns.

main! = || {
	open = Shared.new!(["none"])
	note! = |name| open.modify!(|names| names.append("${name}, a name too long to be small"))
	length = open.finally!(
		|names| names.drop_last(1),
		|| {
			note!("outer")
			inner = open.finally!(
				|names| names.drop_last(1),
				|| {
					note!("inner")
					open.get!().len()
				},
			)
			Stdout.line!("inner saw ${inner.to_str()}")
			open.get!().len()
		},
	)
	Stdout.line!("outer saw ${length.to_str()}")
	open.on_failure!(|_| [], || note!("kept"))
	Stdout.line!("${open.get!().len().to_str()} left")
}
