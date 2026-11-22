platform ""
    requires {} { main! : Str => Str }
    exposes []
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_host_fetch": Host.fetch!,
        "roc_host_log": Host.log!,
    }
    concurrency: Tasks
    targets: {}

import Host

## Crashes where the URL's marker says: before the first pause, between the
## two, or (in the app) after the last.
main_for_host! : Str => Str
main_for_host! = |url| {
    Host.log!(url)
    first = Host.fetch!(before(url))
    second = Host.fetch!(between(url, first))
    main!(Str.concat(first, second))
}

before : Str -> Str
before = |url| if Str.contains(url, "#before") { crash "crashed before the first pause" } else { url }

between : Str, Str -> Str
between = |url, first| if Str.contains(first, "#between") { crash "crashed between the pauses" } else { url }
