app [main!] { pf: platform "./platform/main_effects.roc" }

import pf.Effects
import pf.Stdout

# design.md "Shared State", "Programs without tasks.": a function the host called
# waits for a task of the run that called the host, which can't go on until the
# host returns.

main! = || {
	ready = Shared.new!(0.I64)
	wait! = Box.box(|n| ready.update!(|r| if (r == n) Keep(r) else Wait))
	for! n in List.concurrently([
		|| {
			Stdout.line!("waiting")
			Effects.call!(wait!, 1)
		},
		|| {
			ready.modify!(|_| 1)
			2
		},
	]) {
		Stdout.line!("end ${n.to_str()}")
	}
}
