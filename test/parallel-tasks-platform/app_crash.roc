app [main!] { pf: platform "./platform/main.roc" }

import pf.Meet
import pf.Sleep
import pf.Stdout

entry! : U64 -> (() => U64)
entry! = |millis| || {
	met = Meet.all!(4)
	if met and millis == 1 {
		crash "an entry crashed while three others ran"
	}
	Sleep.millis!(millis)
	millis
}

# The crash ends the task its own thread runs, and no other: the sleeping
# entries are cancelled, and the root crashes with its message.
main! : () => I32
main! = || {
	for! millis in List.concurrently([entry!(600000), entry!(1), entry!(600000), entry!(600000)]) {
		Stdout.line!("slept ${millis.to_str()}")
	}
	0
}
