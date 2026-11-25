app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# A crash ends the program: wasm has no crash exit (design.md "The Task Runtime").

main! : () => Try({}, Str)
main! = || {
	Stdout.line!("before the crash")
	Sleep.millis!(1)
	crash "the app crashed"
}
