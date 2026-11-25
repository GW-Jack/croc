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
x64mac=dc25093fc9ef91d83e46dfcc1e39e31af5276fa7d4d8d4aa17240844bb53b622
x64win=2a3ddb63d5884e543a6c04e6f458a4437b0fedbd9594b7d999bd0f2050c23029
x64mingw=2a3ddb63d5884e543a6c04e6f458a4437b0fedbd9594b7d999bd0f2050c23029
x64freebsd=57ebda4b053d4b0c527bd3cff179a7e8f7b95d9098e9778fa71a1feabd5787ef
x64openbsd=a215dccce29012920882208cccda919bcdd2a450b4f2182e54b002eab987ff89
x64netbsd=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64musl=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64glibc=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64linux=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64elf=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64v1mac=dc25093fc9ef91d83e46dfcc1e39e31af5276fa7d4d8d4aa17240844bb53b622
x64v1win=2a3ddb63d5884e543a6c04e6f458a4437b0fedbd9594b7d999bd0f2050c23029
x64v1mingw=2a3ddb63d5884e543a6c04e6f458a4437b0fedbd9594b7d999bd0f2050c23029
x64v1freebsd=57ebda4b053d4b0c527bd3cff179a7e8f7b95d9098e9778fa71a1feabd5787ef
x64v1openbsd=a215dccce29012920882208cccda919bcdd2a450b4f2182e54b002eab987ff89
x64v1netbsd=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64v1musl=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64v1glibc=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64v1linux=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
x64v1elf=a40f393d1a6f16550265458e5504ae6055357a5c80dbb648cd4e119685a273dc
arm64mac=7be8aa53a71c23c6f959e3ca783fb06b0a973190cdffceef64d9f59c3501f53f
arm64win=3358493676f9aafe7cac958690eef9d43b295454347ed60b6873c48e3376615b
arm64mingw=3358493676f9aafe7cac958690eef9d43b295454347ed60b6873c48e3376615b
arm64linux=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm64musl=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm64glibc=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm64v1win=3358493676f9aafe7cac958690eef9d43b295454347ed60b6873c48e3376615b
arm64v1mingw=3358493676f9aafe7cac958690eef9d43b295454347ed60b6873c48e3376615b
arm64v1linux=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm64v1musl=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm64v1glibc=22a8846f81af964d86f9231e9c97ebef9af0b152fc1aeb8c8b11e177129efb6d
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
