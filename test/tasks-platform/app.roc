app [main!] { pf: platform "./platform/main.roc" }

import pf.File
import pf.Sleep
import pf.Stdin
import pf.Stdout

# Reads a path from each line of standard input until the input ends and
# reports each file's size. The task pauses for a worker at every read and
# every sleep.
main! : () => I32
main! = || {
	var $read = 0.U64
	var $failed = 0.U64
	var $path = Stdin.line!()
	while $path != "" {
		match File.read_utf8!($path) {
			Ok(text) => {
				Stdout.line!("${$path}: ${Str.count_utf8_bytes(text).to_str()} bytes")
				$read = $read + 1
			}
			Err(FileErr(reason)) => {
				Stdout.line!("${$path}: ${reason}")
				$failed = $failed + 1
			}
		}
		Sleep.millis!(1)
		$path = Stdin.line!()
	}
	Stdout.line!("read ${$read.to_str()}, failed ${$failed.to_str()}")
	if $failed == 0 { 0 } else { 1 }
}
