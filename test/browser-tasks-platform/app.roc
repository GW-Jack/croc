app [main!] { pf: platform "./platform/main.roc" }

import pf.Console
import pf.Http
import pf.Sleep

# Fetch three pages at once on a JavaScript event loop, and race two timers
# (design.md "Host Contract", "Browser hosts.").

fetch! : Shared(U64), Str -> (() => Str)
fetch! = |bytes, url| || {
	match Http.get!(url) {
		Ok(text) => {
			bytes.modify!(|sum| sum + text.count_utf8_bytes())
			Console.log!("${url}: ${text}")
			text
		}
		Err(message) => {
			Console.log!("${url} failed: ${message}")
			"none"
		}
	}
}

main! : () => Str
main! = || {
	bytes = Shared.new!(0)
	var $pages = ""
	for! page in List.concurrently([fetch!(bytes, "/slow"), fetch!(bytes, "/quick"), fetch!(bytes, "/missing")]) {
		$pages = Str.concat($pages, "${page} ")
	}
	winner = Concurrent.race!(
		|| {
			Sleep.millis!(5000)
			"late"
		},
		[
			|| {
				Sleep.millis!(1)
				"early"
			},
		],
	)
	"${$pages}${winner} ${bytes.get!().to_str()}"
}
