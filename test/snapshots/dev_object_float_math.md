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
x64mac=8b71a8d0890f389d94998c55216c695fdd891365a1fa46d7c4f09baf250755b4
x64win=09cd68a353971a0f55e3b1b66a53c07534bae25b8bd8698dda3d941801b35961
x64mingw=09cd68a353971a0f55e3b1b66a53c07534bae25b8bd8698dda3d941801b35961
x64freebsd=fd731e0ae9cfc27eb30484e3f25dedc6fc03f8b616d340fe87d7c7de4c320020
x64openbsd=495ca7eefa8ccec32c48cc1815ad8a78c84754bef6049b5cd58a4bff68917f00
x64netbsd=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64musl=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64glibc=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64linux=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64elf=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64v1mac=8b71a8d0890f389d94998c55216c695fdd891365a1fa46d7c4f09baf250755b4
x64v1win=09cd68a353971a0f55e3b1b66a53c07534bae25b8bd8698dda3d941801b35961
x64v1mingw=09cd68a353971a0f55e3b1b66a53c07534bae25b8bd8698dda3d941801b35961
x64v1freebsd=fd731e0ae9cfc27eb30484e3f25dedc6fc03f8b616d340fe87d7c7de4c320020
x64v1openbsd=495ca7eefa8ccec32c48cc1815ad8a78c84754bef6049b5cd58a4bff68917f00
x64v1netbsd=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64v1musl=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64v1glibc=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64v1linux=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
x64v1elf=7eaeeedda86eec11a2a5adbeb82f17ebd15c3969124fca67c06805ccaa3d278a
arm64mac=8a4f455ca8b24e826c9b264be8db039b9c792daad3ce52ad86e606ab63df4d4e
arm64win=c1d0dd81868a948e14f43e0533bc46d7493339a85001abceb0b5d75a3a7cfb92
arm64mingw=c1d0dd81868a948e14f43e0533bc46d7493339a85001abceb0b5d75a3a7cfb92
arm64linux=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm64musl=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm64glibc=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm64v1win=c1d0dd81868a948e14f43e0533bc46d7493339a85001abceb0b5d75a3a7cfb92
arm64v1mingw=c1d0dd81868a948e14f43e0533bc46d7493339a85001abceb0b5d75a3a7cfb92
arm64v1linux=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm64v1musl=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm64v1glibc=198996d31295103a058644ef2ba167bd862e59cd76535d984b44fb2aad0cfda0
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
