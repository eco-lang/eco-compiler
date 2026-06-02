# Eco distribution bundle

The Stage B build produces a single distributable artifact: a directory
tree containing the static `eco` binary plus every file the AOT linker
needs at runtime. Shipped as both `.tar.gz` and `.zip`.

## Building the bundles

From inside the Alpine Stage B build environment (see
`docker/static-build.Dockerfile`):

```bash
cmake --preset ninja-clang-lld-linux-musl
cmake --build build-static --target eco
cmake --build build-static --target package
ls build-static/eco-0.1.0-x86_64-linux-musl.{tar.gz,zip}
```

Or via Docker:

```bash
docker build -f docker/static-build.Dockerfile --target eco-bundle -o ./dist .
ls dist/
```

Both archives carry the same tree.

## Bundle layout

```
eco-0.1.0-x86_64-linux-musl/
├─ bin/
│  └─ eco                                      (the static eco binary)
└─ lib/eco-runtime/
   ├─ ld.lld                                   (static, bundled)
   ├─ crt/
   │  ├─ crt1.o, crti.o, crtn.o                (musl)
   │  ├─ clang_rt.crtbegin-x86_64.o            (compiler-rt)
   │  └─ clang_rt.crtend-x86_64.o              (compiler-rt)
   ├─ libc.a, libc++.a, libc++abi.a, libunwind.a, libclang_rt.builtins-x86_64.a
   ├─ libcurl.a, libssl.a, libcrypto.a, libzip.a, libz.a
   └─ project/
      ├─ libEcoEntryStatic.a
      ├─ libEcoRuntimeStatic.a
      ├─ libEcoNativeDriverStatic.a
      ├─ libElmKernel_*.a                       (24 archives)
      └─ libEcoKernel_*.a                       ( 9 archives)
```

`bin/` and `lib/eco-runtime/` must remain siblings. The runtime resolver
in `eco` finds the runtime tree relative to the binary's own location
(`realpath("/proc/self/exe")` + `"/../lib/eco-runtime"`), so the bundle
can be extracted anywhere — `/opt/eco/`, `~/eco/`, `/usr/local/`,
wherever.

## Installation

```bash
# Pick an install prefix
sudo tar xzf eco-0.1.0-x86_64-linux-musl.tar.gz -C /opt/
sudo ln -sf /opt/eco-0.1.0-x86_64-linux-musl/bin/eco /usr/local/bin/eco

eco make src/Main.elm --output=main
```

No system packages required — no binutils, no glibc-dev, no clang, no
musl-tools. Just untar and run.

## ECO_RUNTIME_DIR override

Set `ECO_RUNTIME_DIR` if the runtime tree lives somewhere other than
`<exe>/../lib/eco-runtime/`:

```bash
ECO_RUNTIME_DIR=/path/to/extracted/lib/eco-runtime eco make ...
```

When set, this path is trusted unconditionally (no fallback) — useful
for debugging missing-file problems.

## Supported hosts

- Linux x86_64 only. The bundle is musl-static, so it runs identically
  on glibc and musl systems: Debian, Ubuntu, RHEL/CentOS/Rocky, Arch,
  Alpine, NixOS, …
- ARM64 and other architectures are not supported in v1
  (see [`plans/static-link-eco-binary.md`](../plans/static-link-eco-binary.md)).

## ABI of the produced binaries

`eco` produces **musl-static** ELF executables. The user code, every
project archive, the bundled libc/libc++/libunwind/compiler-rt — all
musl. The produced binaries have no `NEEDED` entries and require no
shared libraries at runtime, the same way `eco` itself does.

This is intentional: it means binaries produced on a Debian build host
run on Alpine, and vice versa. It is **not** glibc-compatible at the ABI
level — you cannot, for example, `dlopen()` a glibc-built `.so` from
a binary `eco` produced. If you need glibc-ABI outputs, that's Stage A
of the static-link plan; not in this distribution.
