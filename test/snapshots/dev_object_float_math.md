# META
~~~ini
description=F32/F64 arithmetic, comparisons, and F64 to I64 conversion in host-called functions
type=dev_object
~~~
# SOURCE
## app.roc
~~~roc
app [main] { pf: platform "./platform.roc" }

main : F64, F32, I64 -> I64
main = |x, y, n| {
    scaled = x * 2.5 - I64.to_f64(n) / 3.0
    narrowed = F32.to_f64(y * 1.5 + 0.25)
    total = if scaled > narrowed { scaled - narrowed } else { narrowed + scaled }
    F64.to_i64_wrap(total)
}
~~~
## platform.roc
~~~roc
platform ""
    requires {} { main : F64, F32, I64 -> I64 }
    exposes []
    packages {}
    provides { "roc_main": main_for_host }
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: [app] },
    }

main_for_host : F64, F32, I64 -> I64
main_for_host = main
~~~
# MONO
~~~roc
# platform
main_for_host = <required>

# app
main = |x, y, n| {
	scaled = x * 2.5 - to_f64(n) / 3
	narrowed = to_f64(y * 1.5 + 0.25)
	total = if (scaled > narrowed) {
		scaled - narrowed
	} else {
		narrowed + scaled
	}
	to_i64_wrap(total)
}

~~~
# DEV OUTPUT
~~~ini
x64mac=9d3a06e8e4b69610b87c158303b91b28bc88848b2073396a2a92c27c5f60703f
x64win=c2a24d46e31cfdc0a7a367d44b0d033ec1aa57ce804625eca5ecd0a7ef4c60bf
x64mingw=c2a24d46e31cfdc0a7a367d44b0d033ec1aa57ce804625eca5ecd0a7ef4c60bf
x64freebsd=53b5111ad1e967ce4d2dda7fb083002967692692ceca909bad2bf8e51f690634
x64openbsd=37a98ac708cf321b2d089cdfe374afdb62f4f8f3cacd54bfd7c06d8ce3fc7611
x64netbsd=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64musl=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64glibc=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64linux=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64elf=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64v1mac=9d3a06e8e4b69610b87c158303b91b28bc88848b2073396a2a92c27c5f60703f
x64v1win=c2a24d46e31cfdc0a7a367d44b0d033ec1aa57ce804625eca5ecd0a7ef4c60bf
x64v1mingw=c2a24d46e31cfdc0a7a367d44b0d033ec1aa57ce804625eca5ecd0a7ef4c60bf
x64v1freebsd=53b5111ad1e967ce4d2dda7fb083002967692692ceca909bad2bf8e51f690634
x64v1openbsd=37a98ac708cf321b2d089cdfe374afdb62f4f8f3cacd54bfd7c06d8ce3fc7611
x64v1netbsd=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64v1musl=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64v1glibc=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64v1linux=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
x64v1elf=d0abc54a7fb5c9b45ea0091136cc76a21d4eb0d5002138e755a64d16092dd765
arm64mac=1f087f5406524fccaf51941bf9dc41bf1002a0d1827b28e02df6487a47199d37
arm64win=f3ba2cd27db01bb0ca7bd500cc25ce3adb3ce6adb2c417533ec57cd3931693f9
arm64mingw=f3ba2cd27db01bb0ca7bd500cc25ce3adb3ce6adb2c417533ec57cd3931693f9
arm64linux=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm64musl=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm64glibc=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm64v1win=f3ba2cd27db01bb0ca7bd500cc25ce3adb3ce6adb2c417533ec57cd3931693f9
arm64v1mingw=f3ba2cd27db01bb0ca7bd500cc25ce3adb3ce6adb2c417533ec57cd3931693f9
arm64v1linux=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm64v1musl=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm64v1glibc=005a541699c2f8942e91506447a9b19db890d77cdca953bb6a61a029b2155de7
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
