app [main!] { pf: platform "./platform/main.roc" }

main! = |text| if Str.contains(text, "#after") { crash "crashed after the last pause" } else { Str.concat(text, "!") }
