app [main!] { pf: platform "./platform/main.roc" }

import pf.File
import pf.Sleep
import pf.Stdout

slept! : U64 -> (() => U64)
slept! = |millis| || {
	Sleep.millis!(millis)
	millis
}

bytes! : Str -> (() => U64)
bytes! = |name| || {
	match File.read_utf8!("test/tasks-platform/data/${name}") {
		Ok(text) => Str.count_utf8_bytes(text)
		Err(FileErr(_)) => 0
	}
}

# The entries run as child tasks. The sleeps overlap, so they arrive in the
# order they end, not in the order they are listed. Six entries share the
# four workers.
main! : () => I32
main! = || {
	for! millis in List.concurrently([slept!(600), slept!(300), slept!(1)]) {
		Stdout.line!("slept ${millis.to_str()}")
	}
	var $total = 0
	for! count in List.concurrently([bytes!("hello.txt"), bytes!("three_lines.txt"), bytes!("missing.txt"), bytes!("hello.txt"), bytes!("hello.txt"), bytes!("three_lines.txt")]).limit(5) {
		$total = $total + count
	}
	Stdout.line!("read ${$total.to_str()} bytes")
	0
}
