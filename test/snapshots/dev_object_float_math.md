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
x64mac=0e20ebb9e34d1e0dd4cac063e208cf5091166cd27b32805bebd154ccb9178ab4
x64win=abb416c8158eb16632dde417f3702c4326b58a915ea6a8e32569a767fc99f4dd
x64mingw=abb416c8158eb16632dde417f3702c4326b58a915ea6a8e32569a767fc99f4dd
x64freebsd=3d312de9c93b1176e7c53fa4031d0952b69b10b9e5c3699774e2370717538b55
x64openbsd=046d3643c7e526379ab661b47be4d6559b0d827dfa07dfa6a658b5d211646643
x64netbsd=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64musl=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64glibc=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64linux=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64elf=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64v1mac=0e20ebb9e34d1e0dd4cac063e208cf5091166cd27b32805bebd154ccb9178ab4
x64v1win=abb416c8158eb16632dde417f3702c4326b58a915ea6a8e32569a767fc99f4dd
x64v1mingw=abb416c8158eb16632dde417f3702c4326b58a915ea6a8e32569a767fc99f4dd
x64v1freebsd=3d312de9c93b1176e7c53fa4031d0952b69b10b9e5c3699774e2370717538b55
x64v1openbsd=046d3643c7e526379ab661b47be4d6559b0d827dfa07dfa6a658b5d211646643
x64v1netbsd=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64v1musl=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64v1glibc=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64v1linux=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
x64v1elf=942667cca243ca4e7f8324a47b7de3c069bab3e0878342ce32440b24897a6759
arm64mac=485b72177639c910c0aa8ee122322a872a67f676d124a666b5eaa4e849bb6eda
arm64win=dd15537972c5466cb382b157983543565fe56340df0f2f690460d9b3bc6aa1dc
arm64mingw=dd15537972c5466cb382b157983543565fe56340df0f2f690460d9b3bc6aa1dc
arm64linux=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm64musl=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm64glibc=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm64v1win=dd15537972c5466cb382b157983543565fe56340df0f2f690460d9b3bc6aa1dc
arm64v1mingw=dd15537972c5466cb382b157983543565fe56340df0f2f690460d9b3bc6aa1dc
arm64v1linux=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm64v1musl=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm64v1glibc=3e4371a8dbe367096eae4311d256b2faa43fe6dac7ecbe53e8a556034ddd9c72
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
