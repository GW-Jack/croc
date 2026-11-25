app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "Waiting.": a probe meets a state its update would
# crash on, which is gone again when its task runs, so nothing crashes. The probe's
# frames are left as a crash leaves them.

main! = || {
	count = Shared.new!(0.U64)
	wait! : () => Str
	wait! = || {
		left = count.update!(|n| if (n == 0) Wait else Set(0, 10 // (n - 1)))
		"left ${left.to_str()}"
	}
	store! : () => Str
	store! = || {
		count.update!(|_| Set(1, {}))
		count.update!(|_| Set(3, {}))
		"stored"
	}
	for! text in List.concurrently([wait!, store!]) {
		Stdout.line!(text)
	}
}
