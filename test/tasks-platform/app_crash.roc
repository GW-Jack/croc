app [main!] { pf: platform "./platform/main.roc" }

import pf.File
import pf.Stdout

# Crashes after its read returns, so the task crashes after a pause.
main! : () => I32
main! = || {
	text = match File.read_utf8!("test/tasks-platform/data/hello.txt") {
		Ok(contents) => contents
		Err(FileErr(reason)) => reason
	}
	Stdout.line!("read ${Str.count_utf8_bytes(text).to_str()} bytes")
	if Str.contains(text, "reference") {
		crash "the app crashed after its read"
	} else {
		0
	}
}
