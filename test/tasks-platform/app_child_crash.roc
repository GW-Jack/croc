app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

entry! : U64 -> (() => U64)
entry! = |millis| || {
	Sleep.millis!(millis)
	if millis == 1 {
		crash "an entry crashed after its sleep"
	}
	millis
}

# The crash of one entry cancels the other, which is asleep, and crashes the
# root with its message.
main! : () => I32
main! = || {
	for! millis in List.concurrently([entry!(600000), entry!(1)]) {
		Stdout.line!("slept ${millis.to_str()}")
	}
	0
}
