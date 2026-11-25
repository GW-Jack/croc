app [main!] { pf: platform "./platform/main.roc" }

import pf.Console
import pf.Sleep

# Two tasks that stream through shared state, which wait for each other's
# updates between timers (design.md "Shared State", "Waiting.").

main! : () => Str
main! = || {
	queue = Shared.new!([])
	taken = Shared.new!([])
	var $done = ""
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
				taken.modify!(|all| all.append(item))
				$i = $i + 1
			}
			"consumer "
		},
		|| {
			var $i = 0.U64
			while $i < 4 {
				Sleep.millis!(1)
				queue.modify!(|items| items.append("item ${$i.to_str()}"))
				$i = $i + 1
			}
			"producer "
		},
	]) {
		Console.log!(name)
		$done = Str.concat($done, name)
	}
	"${$done}${Str.join_with(taken.get!(), ", ")}"
}
