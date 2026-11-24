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
x64mac=7aaedda9c0ab26344f3bf0c5761b73845ab003a389aced5e816348bbeb6d4c43
x64win=f332275c9dcae178e705f86f737c2c23ffd590e65684a8111dec1280ad675251
x64mingw=f332275c9dcae178e705f86f737c2c23ffd590e65684a8111dec1280ad675251
x64freebsd=14520ddc3177ed4e1c959a12642d76656a4e96e067854b4564eeadc7c048d54c
x64openbsd=6b5b260e83a9db62f4f9b7fc4417a7f60eb311059acb34e1b70a84014f1d0251
x64netbsd=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64musl=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64glibc=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64linux=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64elf=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64v1mac=7aaedda9c0ab26344f3bf0c5761b73845ab003a389aced5e816348bbeb6d4c43
x64v1win=f332275c9dcae178e705f86f737c2c23ffd590e65684a8111dec1280ad675251
x64v1mingw=f332275c9dcae178e705f86f737c2c23ffd590e65684a8111dec1280ad675251
x64v1freebsd=14520ddc3177ed4e1c959a12642d76656a4e96e067854b4564eeadc7c048d54c
x64v1openbsd=6b5b260e83a9db62f4f9b7fc4417a7f60eb311059acb34e1b70a84014f1d0251
x64v1netbsd=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64v1musl=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64v1glibc=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64v1linux=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
x64v1elf=c33a6a04e5bf969addbf120d76c75580079b2dc49f1e9d37dec056cae072431c
arm64mac=0bb70094d98cc4bff239490dd4d77edff87ea3f6ff1080e3e111f36a7cf8cb18
arm64win=c9be3c75f8ebbb3b080faffa643ae18fb5725237df0a9e0192449d689c2c7bcb
arm64mingw=c9be3c75f8ebbb3b080faffa643ae18fb5725237df0a9e0192449d689c2c7bcb
arm64linux=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm64musl=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm64glibc=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm64v1win=c9be3c75f8ebbb3b080faffa643ae18fb5725237df0a9e0192449d689c2c7bcb
arm64v1mingw=c9be3c75f8ebbb3b080faffa643ae18fb5725237df0a9e0192449d689c2c7bcb
arm64v1linux=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm64v1musl=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm64v1glibc=185402006a72a503a1dab5d1b02bf275b4d80d4968421de361dc0bc7c2054e47
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
