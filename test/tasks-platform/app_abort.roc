app [main!] { pf: platform "./platform/main.roc" }

import pf.File
import pf.Sleep
import pf.Stdin
import pf.Stdout

slept! : U64 -> (() => Str)
slept! = |millis| || {
	Sleep.millis!(millis)
	"slept ${millis.to_str()}"
}

line! : () => Str
line! = || Stdin.line!()

# Leaving a loop aborts what its entries wait for. The long sleeps and the
# read of standard input hold workers, or wait for one; every worker must come
# back for the read that follows, and the program must end at once.
main! : () => I32
main! = || {
	for! first in List.concurrently([slept!(50), line!, slept!(600000), slept!(600000), slept!(600000), slept!(600000), slept!(600000)]) {
		Stdout.line!(first)
		break
	}
	match File.read_utf8!("test/tasks-platform/data/hello.txt") {
		Ok(text) => Stdout.line!("read ${Str.count_utf8_bytes(text).to_str()} bytes")
		Err(FileErr(reason)) => Stdout.line!(reason)
	}
	Stdout.line!("line: ${Stdin.line!()}")
	0
}
