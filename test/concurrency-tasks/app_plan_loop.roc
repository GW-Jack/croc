app [main!] { pf: platform "./platform/main.roc" }

import pf.Host

# design.md "Plans And Concurrent Loops", "Sequential lowering.": a plan loop
# whose entries fetch may suspend, so a `concurrency: Tasks` build needs the
# task form, which only `--specialize=yes` lowers.
main! : Str => Str
main! = |text| {
	var $joined = text
	for! fetched in List.concurrently([|| Host.fetch!("a"), || Host.fetch!("b")]) {
		$joined = Str.concat($joined, fetched)
	}
	$joined
}
