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
x64mac=faac96dc24f2e330e518da51d96800ca6eccd1f27b1482a17db45ab0b102a994
x64win=d019ab5cc98f35c12f3958f87a0f2bcff8be6de60fc33ed4921bd608c37ffab8
x64mingw=d019ab5cc98f35c12f3958f87a0f2bcff8be6de60fc33ed4921bd608c37ffab8
x64freebsd=63ab961b8f2df23f816408f0682a70ec9ee8ed5b494e89b2c1fd5855585cb6da
x64openbsd=b1067c76490ff51fc70a5ae37a54e08481d3cf8544eb62482f2477f2999960da
x64netbsd=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64musl=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64glibc=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64linux=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64elf=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64v1mac=faac96dc24f2e330e518da51d96800ca6eccd1f27b1482a17db45ab0b102a994
x64v1win=d019ab5cc98f35c12f3958f87a0f2bcff8be6de60fc33ed4921bd608c37ffab8
x64v1mingw=d019ab5cc98f35c12f3958f87a0f2bcff8be6de60fc33ed4921bd608c37ffab8
x64v1freebsd=63ab961b8f2df23f816408f0682a70ec9ee8ed5b494e89b2c1fd5855585cb6da
x64v1openbsd=b1067c76490ff51fc70a5ae37a54e08481d3cf8544eb62482f2477f2999960da
x64v1netbsd=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64v1musl=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64v1glibc=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64v1linux=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
x64v1elf=ccc6cbe5ea27ef5fd6f78756074e9e3888dddc4de85d432fbdf0bdba26881a55
arm64mac=980151fb83078de27e64a0989e896bd85c9d6fed9867b280b8352274f2fb9f67
arm64win=816f273a1009e6e194d2e1e2989592a964c08aa5213bec74c2fe383a65c6e9b4
arm64mingw=816f273a1009e6e194d2e1e2989592a964c08aa5213bec74c2fe383a65c6e9b4
arm64linux=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm64musl=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm64glibc=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm64v1win=816f273a1009e6e194d2e1e2989592a964c08aa5213bec74c2fe383a65c6e9b4
arm64v1mingw=816f273a1009e6e194d2e1e2989592a964c08aa5213bec74c2fe383a65c6e9b4
arm64v1linux=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm64v1musl=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm64v1glibc=a0492d01a60afddf2aaae38fd3c962452b96667ee722443b6a8f040340d6e0cc
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
