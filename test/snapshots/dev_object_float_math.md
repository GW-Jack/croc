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
x64mac=665eafe94d47b67f433595a9eedb1e842e2375c585ddeab6bf5ffec039a0ce42
x64win=19fe10fad6448651dbb3a6d5a5e66991191ec1dc4136b941966e3be0632fc60a
x64mingw=19fe10fad6448651dbb3a6d5a5e66991191ec1dc4136b941966e3be0632fc60a
x64freebsd=c143938ccfef37ac2deb750b13292ba9234b520606a2fc19734c1060c771987b
x64openbsd=08cda683f8620783313a029290180293125126bf24714eacd5f870a40cba2552
x64netbsd=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64musl=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64glibc=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64linux=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64elf=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64v1mac=665eafe94d47b67f433595a9eedb1e842e2375c585ddeab6bf5ffec039a0ce42
x64v1win=19fe10fad6448651dbb3a6d5a5e66991191ec1dc4136b941966e3be0632fc60a
x64v1mingw=19fe10fad6448651dbb3a6d5a5e66991191ec1dc4136b941966e3be0632fc60a
x64v1freebsd=c143938ccfef37ac2deb750b13292ba9234b520606a2fc19734c1060c771987b
x64v1openbsd=08cda683f8620783313a029290180293125126bf24714eacd5f870a40cba2552
x64v1netbsd=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64v1musl=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64v1glibc=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64v1linux=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
x64v1elf=09c6f09ccb5eb8dc69c2da2a46f64ebeb622b7b8cd24d82a13539f9ff359d879
arm64mac=cbfbb065ffdef74de89a3f953c1dd2760f69a092d9b7f9a4af0cb0e610e77dfd
arm64win=337efcd604c3d47e06c0eda19ec1b9ce2d5f011173dccdc9927cafa99156aa14
arm64mingw=337efcd604c3d47e06c0eda19ec1b9ce2d5f011173dccdc9927cafa99156aa14
arm64linux=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm64musl=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm64glibc=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm64v1win=337efcd604c3d47e06c0eda19ec1b9ce2d5f011173dccdc9927cafa99156aa14
arm64v1mingw=337efcd604c3d47e06c0eda19ec1b9ce2d5f011173dccdc9927cafa99156aa14
arm64v1linux=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm64v1musl=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm64v1glibc=ee2329fdd46ee5c49ee27a733113680fa6373f383d9be9ef9bcbe04334a4f1a4
arm32linux=NOT_IMPLEMENTED
arm32musl=NOT_IMPLEMENTED
wasm32=NOT_IMPLEMENTED
wasm32v1=NOT_IMPLEMENTED
~~~
