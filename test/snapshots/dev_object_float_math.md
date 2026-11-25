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
x64mac=b88b370331223226e3d369097e15c05f32e3914fc526e52dcb6eac5b9ffe40ed
x64win=8465f80d8a37e4dc536a41779478a61d703b757bf8896003f2fa6e863f460f04
x64mingw=8465f80d8a37e4dc536a41779478a61d703b757bf8896003f2fa6e863f460f04
x64freebsd=d4ae903312775bebd7515c0ef19b7f34d398136254f405d08e53981ddb05ad43
x64openbsd=113e02376328e57b9fb45d4fa1be34dc15bd4a38a2bddc377113fb2b33edd55a
x64netbsd=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64musl=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64glibc=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64linux=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64elf=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64v1mac=b88b370331223226e3d369097e15c05f32e3914fc526e52dcb6eac5b9ffe40ed
x64v1win=8465f80d8a37e4dc536a41779478a61d703b757bf8896003f2fa6e863f460f04
x64v1mingw=8465f80d8a37e4dc536a41779478a61d703b757bf8896003f2fa6e863f460f04
x64v1freebsd=d4ae903312775bebd7515c0ef19b7f34d398136254f405d08e53981ddb05ad43
x64v1openbsd=113e02376328e57b9fb45d4fa1be34dc15bd4a38a2bddc377113fb2b33edd55a
x64v1netbsd=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64v1musl=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64v1glibc=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64v1linux=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
x64v1elf=95cf219ecac59b0fe40e89f8402c7eb65f7dfe4085bca3927819e581894e7705
arm64mac=c4e97d8b7bbc20886e9b8edbf4893640c4776ca4fa19e41e83b522955fb9ffe2
arm64win=8889945504e85e15638716eae1e730edf4738a2f22e2e3dc3a20f60633b8ac24
arm64mingw=8889945504e85e15638716eae1e730edf4738a2f22e2e3dc3a20f60633b8ac24
arm64linux=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm64musl=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm64glibc=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm64v1win=8889945504e85e15638716eae1e730edf4738a2f22e2e3dc3a20f60633b8ac24
arm64v1mingw=8889945504e85e15638716eae1e730edf4738a2f22e2e3dc3a20f60633b8ac24
arm64v1linux=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm64v1musl=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm64v1glibc=392fdf984c8e8f4a4026863a3efd3ce77bb088230c82a72b22b8332efb50edaf
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
