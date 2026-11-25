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
x64mac=480ee47c032df1c1271a546afb1f299787585c301db250494251b67b102d487c
x64win=648ef515d2ed40ecca98bf798bcc3d4e7fa4c72e034651bdc867ccd357829d9d
x64mingw=648ef515d2ed40ecca98bf798bcc3d4e7fa4c72e034651bdc867ccd357829d9d
x64freebsd=f66106c87499c7d1f9cb5e05da883d98c18541bb040af523c2bf4588945e3f12
x64openbsd=3f3b90ae2bf26b37baf39ef6bdaec6f99f76d73843a70658f7ced4a77c169161
x64netbsd=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64musl=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64glibc=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64linux=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64elf=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64v1mac=480ee47c032df1c1271a546afb1f299787585c301db250494251b67b102d487c
x64v1win=648ef515d2ed40ecca98bf798bcc3d4e7fa4c72e034651bdc867ccd357829d9d
x64v1mingw=648ef515d2ed40ecca98bf798bcc3d4e7fa4c72e034651bdc867ccd357829d9d
x64v1freebsd=f66106c87499c7d1f9cb5e05da883d98c18541bb040af523c2bf4588945e3f12
x64v1openbsd=3f3b90ae2bf26b37baf39ef6bdaec6f99f76d73843a70658f7ced4a77c169161
x64v1netbsd=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64v1musl=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64v1glibc=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64v1linux=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
x64v1elf=c35fc27a40823c68980ed582246cb21fcc6b83e4f409d4f4d3118974ac308798
arm64mac=5b48816a5ce92d7a9d4f6438d745d7ed201b59e62b591fd8015ccc965541584a
arm64win=505c01b7860341a69f600cb3556a40123fa1dde2917f6095ccef5b40687c6861
arm64mingw=505c01b7860341a69f600cb3556a40123fa1dde2917f6095ccef5b40687c6861
arm64linux=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm64musl=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm64glibc=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm64v1win=505c01b7860341a69f600cb3556a40123fa1dde2917f6095ccef5b40687c6861
arm64v1mingw=505c01b7860341a69f600cb3556a40123fa1dde2917f6095ccef5b40687c6861
arm64v1linux=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm64v1musl=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm64v1glibc=8484e03de29a0f3130c547d3d0c0c0d4d07f29ba12d19e5702fff4cb15b563de
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
