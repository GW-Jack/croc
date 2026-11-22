app [main!] { pf: platform "./platform/main.roc" }

import pf.Host

# The platform fetches once before calling `main!`, and `main!` fetches
# again and then crashes, so the task crashes after its last pause.
main! : Str => Str
main! = |text| crash_after(Host.fetch!(text))

crash_after : Str -> Str
crash_after = |answer|
    if Str.contains(answer, "fetched") {
        crash "the app crashed after its fetch"
    } else {
        answer
    }
