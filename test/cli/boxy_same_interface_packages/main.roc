## Two packages whose `Common` modules have one interface and different
## bodies: distinct modules, whose workers and types must stay distinct.
app [main!] {
	left: "./left/main.roc",
	right: "./right/main.roc",
	pf: platform "../../fx/platform/main.roc",
}

import pf.Stdin
import pf.Stdout
import left.Common as Left
import right.Common as Right

main! = || {
	n = Stdin.line!().count_utf8_bytes()
	Stdout.line!(Left.tell(Left.make(n)))
	Stdout.line!(Right.tell(Right.make(n)))
}
