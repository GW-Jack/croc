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
x64mac=13577419cb3a4165ff43ef676f629c254a5725788b269bf661fbd485e53c633f
x64win=327d955fb46b95ab813e9c8619e166aeb7e02cff581124a5175dbefc7ace82d3
x64mingw=327d955fb46b95ab813e9c8619e166aeb7e02cff581124a5175dbefc7ace82d3
x64freebsd=1da83d8b365e864f6fbf63166a886d9bf464b18dbdb02cac6118c216d3277c80
x64openbsd=b99883109ff765c1e9ad80622d18b078daee9ec09990b1930964ecb233cd9a72
x64netbsd=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64musl=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64glibc=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64linux=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64elf=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64v1mac=13577419cb3a4165ff43ef676f629c254a5725788b269bf661fbd485e53c633f
x64v1win=327d955fb46b95ab813e9c8619e166aeb7e02cff581124a5175dbefc7ace82d3
x64v1mingw=327d955fb46b95ab813e9c8619e166aeb7e02cff581124a5175dbefc7ace82d3
x64v1freebsd=1da83d8b365e864f6fbf63166a886d9bf464b18dbdb02cac6118c216d3277c80
x64v1openbsd=b99883109ff765c1e9ad80622d18b078daee9ec09990b1930964ecb233cd9a72
x64v1netbsd=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64v1musl=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64v1glibc=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64v1linux=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
x64v1elf=c57bf4c1daa2d23f1b4ff0a41fa8a4ad2b79db511ef4e319793f2f1ac1cd010a
arm64mac=098e9ed28dc83ff3275ea7fc39ff7b967985d0677ec13c5e2b2bc6c26bf39811
arm64win=7d72e89b0c671897b34270d5d7080ad97c903a090739dcd2b88dc88ab157e4f1
arm64mingw=7d72e89b0c671897b34270d5d7080ad97c903a090739dcd2b88dc88ab157e4f1
arm64linux=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm64musl=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm64glibc=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm64v1win=7d72e89b0c671897b34270d5d7080ad97c903a090739dcd2b88dc88ab157e4f1
arm64v1mingw=7d72e89b0c671897b34270d5d7080ad97c903a090739dcd2b88dc88ab157e4f1
arm64v1linux=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm64v1musl=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm64v1glibc=4b4a8d675ab38154fcf44cdde0ff2fd59943208fa75dcce95e653fed9be2feb5
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
