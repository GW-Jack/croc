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

main_for_host! : Str => Str
main_for_host! = |url| {
    first = keep_after_log!(url)
    second = keep_after_fetch!(url)
    main!(Str.concat(first, Str.concat(second, keep_list!(url))))
}

# Keeps a list of its own and the host's string across two pauses. Nothing
# else can hold the list.
keep_list! : Str => Str
keep_list! = |text| {
    var $bytes = Str.to_utf8(Str.inspect(Str.count_utf8_bytes(text)))
    _ = Host.fetch!("ping")
    $bytes = List.append($bytes, 33)
    kept = $bytes
    $bytes = List.append($bytes, 34)
    _ = Host.fetch!(text)
    Str.inspect(List.concat(kept, $bytes))
}

# Returns its own argument; may suspend.
keep_after_fetch! : Str => Str
keep_after_fetch! = |text| {
    _ = Host.fetch!("ping")
    text
}

# The same shape without a suspension site.
keep_after_log! : Str => Str
keep_after_log! = |text| {
    Host.log!("ping")
    text
}
