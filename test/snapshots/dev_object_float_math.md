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
x64mac=7a7a1f7027f42ecc363106386145d5b627d8dd70d9431b54bdcf2eebe38ef8de
x64win=e13b161d6e25e964120d12d10d044aafda3964cf54b68de887495cc9b6b0f3f9
x64mingw=e13b161d6e25e964120d12d10d044aafda3964cf54b68de887495cc9b6b0f3f9
x64freebsd=d3f806b47515f3fcd6effe43dd1c01b5fbb3844a671b546ce1dfc1638d44ffe5
x64openbsd=7188d4be03f13cdb5ae697879664aff2660f3dc13b35714096f81bcce20d6df5
x64netbsd=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64musl=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64glibc=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64linux=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64elf=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64v1mac=7a7a1f7027f42ecc363106386145d5b627d8dd70d9431b54bdcf2eebe38ef8de
x64v1win=e13b161d6e25e964120d12d10d044aafda3964cf54b68de887495cc9b6b0f3f9
x64v1mingw=e13b161d6e25e964120d12d10d044aafda3964cf54b68de887495cc9b6b0f3f9
x64v1freebsd=d3f806b47515f3fcd6effe43dd1c01b5fbb3844a671b546ce1dfc1638d44ffe5
x64v1openbsd=7188d4be03f13cdb5ae697879664aff2660f3dc13b35714096f81bcce20d6df5
x64v1netbsd=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64v1musl=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64v1glibc=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64v1linux=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
x64v1elf=21af5d75ad27167faedc123c19dbe8c4727a16874a44cfeb86b65ad64e0fd7a4
arm64mac=71f388f634dae6609a01360780077c93136166decfd941acd1afd6804df76115
arm64win=c8694c3ed456e1269b59e3b22c4fb6ba0d112af5bb18594c80c696fb8621ddf8
arm64mingw=c8694c3ed456e1269b59e3b22c4fb6ba0d112af5bb18594c80c696fb8621ddf8
arm64linux=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm64musl=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm64glibc=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm64v1win=c8694c3ed456e1269b59e3b22c4fb6ba0d112af5bb18594c80c696fb8621ddf8
arm64v1mingw=c8694c3ed456e1269b59e3b22c4fb6ba0d112af5bb18594c80c696fb8621ddf8
arm64v1linux=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm64v1musl=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm64v1glibc=b05404ac416e3e6b4e4ae11a4717f44f30e6d94cdfb62b1bec6aa851ab4645e6
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
