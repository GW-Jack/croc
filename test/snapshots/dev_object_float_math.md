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
x64mac=64a18d84e30e1eaa7107fca7c8380531376fa8bd426ce0013e1c85f6e08bcf6c
x64win=161b01433de656609d2a5f10d08d442edebbdf9097065ad3afb46884864b788e
x64mingw=161b01433de656609d2a5f10d08d442edebbdf9097065ad3afb46884864b788e
x64freebsd=71a4aa4412f29fd6987ce58076c2bc2c4959fce102c65a14b62fb3e0f16743c8
x64openbsd=10570adc4fcee340e77ce36717e965e2613996d8c2769359f2482d77f582833d
x64netbsd=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64musl=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64glibc=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64linux=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64elf=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64v1mac=64a18d84e30e1eaa7107fca7c8380531376fa8bd426ce0013e1c85f6e08bcf6c
x64v1win=161b01433de656609d2a5f10d08d442edebbdf9097065ad3afb46884864b788e
x64v1mingw=161b01433de656609d2a5f10d08d442edebbdf9097065ad3afb46884864b788e
x64v1freebsd=71a4aa4412f29fd6987ce58076c2bc2c4959fce102c65a14b62fb3e0f16743c8
x64v1openbsd=10570adc4fcee340e77ce36717e965e2613996d8c2769359f2482d77f582833d
x64v1netbsd=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64v1musl=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64v1glibc=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64v1linux=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
x64v1elf=64da48a3d01acf23af595ebe66674a46e435eca31ef1bd4dd6f5046ea23ce157
arm64mac=a9faf3acd106ec1e35b790d554b7bfb71f50b81dc3f4025b55dc2e760e6b986f
arm64win=ef1dce06577cf683c5fd7b43fe248de7794ab616f5ca77cd8603f91700d7dd88
arm64mingw=ef1dce06577cf683c5fd7b43fe248de7794ab616f5ca77cd8603f91700d7dd88
arm64linux=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm64musl=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm64glibc=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm64v1win=ef1dce06577cf683c5fd7b43fe248de7794ab616f5ca77cd8603f91700d7dd88
arm64v1mingw=ef1dce06577cf683c5fd7b43fe248de7794ab616f5ca77cd8603f91700d7dd88
arm64v1linux=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm64v1musl=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm64v1glibc=ee0a71b7204a1d5c74b6a850a9ec17c781cbabc6293dc219a58c61fcce81cd15
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
