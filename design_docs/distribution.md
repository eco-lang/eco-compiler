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
├─ lib/eco-runtime/
│  ├─ ld.lld                                   (static, bundled — also drives the glibc -shared links)
│  ├─ crt/
│  │  ├─ crt1.o, crti.o, crtn.o                (musl)
│  │  ├─ clang_rt.crtbegin-x86_64.o            (compiler-rt)
│  │  └─ clang_rt.crtend-x86_64.o              (compiler-rt)
│  ├─ libc.a, libc++.a, libc++abi.a, libunwind.a, libclang_rt.builtins-x86_64.a
│  ├─ libcurl.a, libssl.a, libcrypto.a, libzip.a, libz.a
│  ├─ project/
│  │  ├─ libEcoEntryStatic.a
│  │  ├─ libEcoRuntimeStatic.a
│  │  ├─ libEcoNativeDriverStatic.a
│  │  ├─ libElmKernel_*.a                      (22 archives)
│  │  └─ libEcoKernel_*.a                      ( 9 archives)
│  └─ glibc/                                   (second link-input set, glibc ABI, all PIC — Stage D)
│     ├─ crt/
│     │  ├─ crti.o, crtn.o                     (glibc, harvested from the Debian builder)
│     │  └─ crtbeginS.o, crtendS.o             (gcc, shared/PIC variants)
│     ├─ libc++.a, libc++abi.a, libunwind.a
│     ├─ libclang_rt.builtins-x86_64.a
│     ├─ libcurl.a, libssl.a, libcrypto.a, libzip.a, libz.a
│     └─ project/
│        ├─ libEcoEmbedStatic.a                (host-embedding entry: eco_app_start/stop/join)
│        ├─ libEcoNodeGlue.a                   (N-API glue: napi_register_module_v1)
│        ├─ libEcoRuntimeStatic.a
│        ├─ libElmKernel_*.a                   (22)
│        └─ libEcoKernel_*.a                   ( 9)
└─ share/eco/
   ├─ kernel/eco-kernel-cpp/                   (the eco/kernel Elm package sources)
   └─ examples/hello/                          (starter example: elm.json + src/Hello.elm)
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

Two output profiles ship in one bundle (see
[`plans/stage-d-hybrid-link-profiles.md`](../plans/stage-d-hybrid-link-profiles.md)):

**Executables are musl fully-static**, unchanged. The user code, every
project archive, the bundled libc/libc++/libunwind/compiler-rt — all
musl. The produced binaries have no `NEEDED` entries and require no
shared libraries at runtime, the same way `eco` itself does. This is
intentional: a binary produced on a Debian host runs on Alpine, and
vice versa.

**`.so` and `.node` outputs are glibc-ABI**, linked from the bundled
`lib/eco-runtime/glibc/` tree. A shared object lives inside a host
process and cannot be a fully-static musl artifact, so these outputs
target the libc the host is already running:

- A produced `.node` loads into stock glibc Node ≥ 16; a produced `.so`
  into any glibc C/C++ host.
- Self-contained: curl/ssl/zip/z, libc++, libunwind and compiler-rt are
  statically linked in and hidden — the artifact has **no `NEEDED`
  entries** and no RUNPATH. libc/libm symbols are left undefined at
  link time and bind at load time from the glibc already in the host
  process.
- C hosts linking against a produced `.so` must add `-lm`: the artifact
  carries undefined libm symbols and has no `NEEDED` entry to pull libm
  in itself. (Node hosts need nothing extra — node already loads libm.)
- The minimum glibc version is computed when the bundle is built and
  recorded in `lib/eco-runtime/glibc/GLIBC_FLOOR`.
- musl-hosted Node (Alpine) is **not supported** for `.node` outputs.
  The generated `.js` shim detects musl Node and reports this clearly
  instead of leaking a raw loader error.

## Output kinds

What `eco make --output=X` produces from the installed bundle:

| `--output` ending | Artifact | Link profile |
|---|---|---|
| *(omitted)* | `index.html` (one main) / `elm.js` (several) | n/a — JS codegen |
| `/dev/null` | nothing (typecheck only) | n/a |
| `.js` | JavaScript file | n/a — JS codegen |
| `.html` | self-contained HTML page | n/a — JS codegen |
| `.mlir` | MLIR module dump (bytecode; text with `--text-mlir`) | n/a — no native link |
| `.o` | relocatable object (always PIC) | profile-neutral, no link |
| `.so` | shared library (C embedding API, `eco_app_*`) | dynamic-glibc |
| `.node` | Node.js addon + sibling `.js` shim | dynamic-glibc |
| *(anything else)* | ELF executable | musl fully-static |
