app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep

# A crash ends the program: wasm has no crash exit (design.md "The Task Runtime").

main! : () => Str
main! = || {
	Sleep.millis!(1)
	crash "the app crashed"
}
