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
x64mac=cc79515141c59e912c35e8567568d7075da70fc89966991557b2bd5767966e21
x64win=aee08b627a551564ed03809850cca3af3af8042128667d7d28df80867b747059
x64mingw=aee08b627a551564ed03809850cca3af3af8042128667d7d28df80867b747059
x64freebsd=327bdf824cf051cafa081b50d192f38e446b448e31aca400e87593f414942e1f
x64openbsd=241eb8b66c05f95fc1b34d144b0c9ce790a35316eb3eb53f3494f9c4d1d839a1
x64netbsd=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64musl=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64glibc=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64linux=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64elf=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64v1mac=cc79515141c59e912c35e8567568d7075da70fc89966991557b2bd5767966e21
x64v1win=aee08b627a551564ed03809850cca3af3af8042128667d7d28df80867b747059
x64v1mingw=aee08b627a551564ed03809850cca3af3af8042128667d7d28df80867b747059
x64v1freebsd=327bdf824cf051cafa081b50d192f38e446b448e31aca400e87593f414942e1f
x64v1openbsd=241eb8b66c05f95fc1b34d144b0c9ce790a35316eb3eb53f3494f9c4d1d839a1
x64v1netbsd=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64v1musl=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64v1glibc=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64v1linux=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
x64v1elf=a98b1f666ba7a53c558bbd8c7702cac5c83acc9cbd5ff8292524087e5334294b
arm64mac=72cc6e748572fbad13d8e2f27af0a4bd747394229da87ecd22e893dadc4d343d
arm64win=c771620c7cd01a3c9c38545355ca3faa0dbe07bdfa0a8a789a784fed2f2c691f
arm64mingw=c771620c7cd01a3c9c38545355ca3faa0dbe07bdfa0a8a789a784fed2f2c691f
arm64linux=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm64musl=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm64glibc=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm64v1win=c771620c7cd01a3c9c38545355ca3faa0dbe07bdfa0a8a789a784fed2f2c691f
arm64v1mingw=c771620c7cd01a3c9c38545355ca3faa0dbe07bdfa0a8a789a784fed2f2c691f
arm64v1linux=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm64v1musl=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm64v1glibc=587952147acbc2deff99dc63479e79116534418fbfbbdca34223c9e0cab7095d
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
