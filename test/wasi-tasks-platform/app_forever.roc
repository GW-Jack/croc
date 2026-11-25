app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# A program that only ends when it is cancelled: one task sleeps, one waits for
# shared state no task changes, and two print.

main! : () => Try({}, Str)
main! = || {
	held = Shared.new!("state that is too long to be stored inline")
	for! _ in List.concurrently([
		|| Sleep.millis!(60000),
		|| held.update!(|_| Wait),
		|| {
			Stdout.line!("running")
			Sleep.millis!(60000)
			Stdout.line!("a cancelled task printed")
		},
		|| {
			Stdout.line!("running too")
			Sleep.millis!(60000)
		},
	]) {}
	Ok({})
}
