app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "Waiting.": on a platform with no tasks, an update
# that waits can never go on.

main! = || {
	count = Shared.new!(1)
	taken = count.update!(|n| if (n > 0) Set(n - 1, n) else Wait)
	Stdout.line!("took ${taken.to_str()}")
	again = count.update!(|n| if (n > 0) Set(n - 1, n) else Wait)
	Stdout.line!("took ${again.to_str()}")
}
