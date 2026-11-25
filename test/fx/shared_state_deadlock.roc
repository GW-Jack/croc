app [main!] { pf: platform "./platform/main.roc" }

import pf.Stdout

# design.md "Shared State", "Waiting.": on a platform with no tasks, an update
# that waits can never go on.

take! = |count| count.update!(|n| if (n > 0) Set(n - 1, n) else Wait)

main! = || {
	count = Shared.new!(1)
	Stdout.line!("took ${take!(count).to_str()}")
	Stdout.line!("took ${take!(count).to_str()}")
}
