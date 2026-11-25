app [main!] { pf: platform "./platform/main.roc" }

import pf.Sleep
import pf.Stdout

# Two tasks that stream through shared state, which wait for each other's
# updates between timers (design.md "Shared State", "Waiting."), and fail the
# program once both are done.

main! : () => Try({}, Str)
main! = || {
	queue = Shared.new!([])
	for! name in List.concurrently([
		|| {
			var $i = 0.U64
			while $i < 4 {
				item = queue.update!(
					|items| match items {
						[first, .. as rest] => Set(rest, first)
						[] => Wait
					},
				)
				Stdout.line!("took ${item}")
				$i = $i + 1
			}
			"consumer"
		},
		|| {
			var $i = 0.U64
			while $i < 4 {
				Sleep.millis!(1)
				queue.modify!(|items| items.append("item ${$i.to_str()}, too long to be stored inline"))
				$i = $i + 1
			}
			"producer"
		},
	]) {
		Stdout.line!("${name} is done")
	}
	Err("the queue is closed, and nothing more will come")
}
