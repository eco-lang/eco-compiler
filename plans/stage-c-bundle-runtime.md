# Stage C — distribution bundle (`eco` + `eco-runtime/` + `ld.lld`)

Companion to [`static-link-eco-binary.md`](static-link-eco-binary.md). That
plan brought Stage B to a working state: a fully-static `eco` binary built
under Alpine MUSL that produces statically-linked ELF outputs *as long as
the host has the right crt/libc/linker pieces under `/usr/lib`*. This plan
delivers the first slice of Stage C: a self-contained tarball/zip that
carries every file the AOT linker needs alongside `eco` itself, so a user
on Debian / Ubuntu / RHEL can extract it anywhere and run `eco make` with
no host toolchain installed.

## Scope

**In scope (v1):**

- Build a fully-static `ld.lld` inside the Alpine LLVM stage and bundle it
  alongside `eco`.
- Replace baked absolute paths in `EcoBootConfig.h` with basenames + a
  runtime resolver based on `realpath("/proc/self/exe")`.
- `install()` rules that lay out a deployable tree (`bin/eco` +
  `lib/eco-runtime/...`).
- CPack-driven `.tar.gz` and `.zip` bundles, version `0.1.0`.
- Strip the bundled `eco` and `ld.lld` binaries plus the project archives
  by default.
- Switch to compiler-rt's `clang_rt.crtbegin-x86_64.o` / `clang_rt.crtend-x86_64.o`
  so the bundle's crt files are consistent with the rest of the Stage B
  stack (libc++ + compiler-rt + libunwind).
- Drop every `-L` search-dir and bare `-l` flag from the AOT link line —
  every dependency is passed as an absolute path under `lib/eco-runtime/`.
- Linux x86_64 only; MUSL ABI for both the `eco` binary and its outputs.
- Smoke test in CI: extract the bundle, build `Hello.elm`, run the result.

**Out of scope (defer):**

- Glibc Stage A bundles. Stage B-only initially.
- In-process lld (link `lld::elf::link` into `eco` itself). The static
  `ld.lld` binary is the v1 answer; switching to in-process is a later
  size/perf optimization.
- ARM64 / other architectures.
- GitHub Releases CI/CD wiring.
- Reproducibility-grade builds (deterministic timestamps, etc.) beyond
  what CPack's defaults give us.

## Layout

```
eco-0.1.0-x86_64-linux-musl/
├─ bin/
│  └─ eco                                    (static, stripped)
└─ lib/eco-runtime/
   ├─ ld.lld                                 (static, stripped)
   ├─ crt/
   │  ├─ crt1.o                              (musl)
   │  ├─ crti.o                              (musl)
   │  ├─ crtn.o                              (musl)
   │  ├─ clang_rt.crtbegin-x86_64.o          (compiler-rt)
   │  └─ clang_rt.crtend-x86_64.o            (compiler-rt)
   ├─ libc.a                                 (musl)
   ├─ libc++.a                                (Alpine libc++-static)
   ├─ libc++abi.a                             (Alpine, bundled into libc++)
   ├─ libunwind.a                             (LLVM libunwind, /opt/llvm-mlir)
   ├─ libclang_rt.builtins-x86_64.a           (compiler-rt builtins)
   └─ project/
      ├─ libEcoEntryStatic.a
      ├─ libEcoRuntimeStatic.a
      ├─ libEcoNativeDriverStatic.a
      ├─ libElmKernel_Basics.a, …             (24 files)
      └─ libEcoKernel_File.a, …               ( 9 files)
```

Sibling layout (`bin/` next to `lib/eco-runtime/`) so the runtime resolver
can find files via `dirname(realpath("/proc/self/exe")) + "/../lib/eco-runtime"`.
Users can extract anywhere — `/opt/eco`, `~/eco`, `/usr/local`, doesn't
matter; the resolver is location-agnostic. `ECO_RUNTIME_DIR` env var
overrides for tests and non-FHS installs.

## Implementation steps

### 1. Static `ld.lld` inside the Alpine LLVM stage

`docker/static-build.Dockerfile:76`: extend
`LLVM_ENABLE_PROJECTS="mlir"` to `"mlir;lld"`. The existing Stage-1 LLVM
configure line already passes
`-DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -lc++abi -fuse-ld=lld"`,
so the `ld.lld` driver built as part of the LLVM tools install inherits
those flags automatically. Add `-static` to that flag string (or split it
so only the tools build statically — see Q below) and run a `readelf -d`
assertion in the Dockerfile that `/opt/llvm-mlir/bin/ld.lld` has no
`NEEDED` entries, mirroring the existing check at
`docker/static-build.Dockerfile:157-161` for the `eco` binary.

### 2. Inventory the runtime files at CMake configure time

`runtime/src/codegen/CMakeLists.txt:769-789` already resolves most paths
via `_eco_query_clang_path`. Extend to also resolve:

- `clang_rt.crtbegin-x86_64.o`, `clang_rt.crtend-x86_64.o` (replacing the
  current `crtbegin.o`/`crtend.o` from gcc — see step 6).
- `libc.a` (musl) — query via
  `_eco_query_clang_path(ECO_LIBC_A libc.a)`.

Most of the rest are already in CMake variables today:
`ECO_LIBCXX_A`, `ECO_LIBCXXABI_A`, `ECO_COMPILER_RT_BUILTINS_A`, and the
project archives reachable via `$<TARGET_FILE:...>` generator expressions.

Build a single `ECO_RUNTIME_INSTALL_FILES` list aggregating absolute paths
for every file in the layout above. Keep the project archives separate
(they're CMake TARGETS, installed via `install(TARGETS …)`).

### 3. `install()` rules

All gated on `ECO_STATIC_MUSL` so non-MUSL builds are untouched. In
`compiler/CMakeLists.txt` after the `eco` target:

```cmake
if(ECO_STATIC_MUSL)
    install(TARGETS eco RUNTIME DESTINATION bin)
endif()
```

In `runtime/src/codegen/CMakeLists.txt` (or a new top-level
`cmake/Install.cmake` invoked from the top `CMakeLists.txt`):

```cmake
if(ECO_STATIC_MUSL)
    # crt objects in a subdir
    install(FILES
        ${ECO_CRT1_O_STATIC} ${ECO_CRTI_O} ${ECO_CRTN_O}
        ${ECO_CRTBEGIN_O_STATIC} ${ECO_CRTEND_O_STATIC}
        DESTINATION lib/eco-runtime/crt)

    # flat libraries
    install(FILES
        ${ECO_LIBC_A} ${ECO_LIBCXX_A} ${ECO_LIBCXXABI_A}
        ${LLVM_LIBUNWIND_LIBRARY} ${ECO_COMPILER_RT_BUILTINS_A}
        DESTINATION lib/eco-runtime)

    # bundled ld.lld — query its absolute path once, install as executable
    find_program(ECO_LLD_BIN ld.lld PATHS /opt/llvm-mlir/bin REQUIRED
                 NO_DEFAULT_PATH)
    install(PROGRAMS ${ECO_LLD_BIN} DESTINATION lib/eco-runtime)

    # project archives — TARGETS form so we don't repeat absolute paths
    install(TARGETS
        EcoEntryStatic EcoRuntimeStatic EcoNativeDriverStatic
        ElmKernel_Basics ElmKernel_Bitwise ElmKernel_Char ElmKernel_String
        ElmKernel_List ElmKernel_Utils ElmKernel_JsArray ElmKernel_Debug
        ElmKernel_Scheduler ElmKernel_Platform ElmKernel_Process
        ElmKernel_VirtualDom ElmKernel_Json ElmKernel_Browser ElmKernel_Bytes
        ElmKernel_File ElmKernel_Http ElmKernel_Parser ElmKernel_Regex
        ElmKernel_Time ElmKernel_Url ElmKernel_EffectRegistry
        EcoKernel_File EcoKernel_Console EcoKernel_Env EcoKernel_Process
        EcoKernel_MVar EcoKernel_NativeDriver EcoKernel_Runtime EcoKernel_Http
        EcoKernel_Crash
        ARCHIVE DESTINATION lib/eco-runtime/project)
endif()
```

### 4. `EcoBootConfig.h` — basenames + runtime resolver (Approach 4A)

`runtime/src/codegen/CMakeLists.txt:834-...` generates `EcoBootConfig.h`
today with absolute path strings. Change it to emit basenames only, plus
the resolver function:

```cpp
// Auto-generated by CMake. Do not edit.
#pragma once
#include <string>
#include <vector>

namespace eco { namespace config {

// Resolves the eco-runtime directory at runtime. Returns
// $ECO_RUNTIME_DIR if set, else dirname(realpath("/proc/self/exe"))
// + "/../lib/eco-runtime". Linux-only; Stage B is Linux x86_64-only by
// design (see plans/static-link-eco-binary.md scope).
std::string runtimeDir();

// Convenience: runtimeDir() + "/" + name, with optional subdirectory.
std::string runtimeFile(const char *name, const char *subdir = nullptr);

// File basenames, looked up via runtimeFile() at use sites.
inline const char *crt1ObjStatic     = "crt1.o";
inline const char *crtiObj           = "crti.o";
inline const char *crtnObj           = "crtn.o";
inline const char *crtbeginObjStatic = "clang_rt.crtbegin-x86_64.o";
inline const char *crtendObjStatic   = "clang_rt.crtend-x86_64.o";
inline const char *libcStaticA       = "libc.a";
inline const char *libcxxStaticA     = "libc++.a";
inline const char *libcxxabiStaticA  = "libc++abi.a";
inline const char *unwindLib         = "libunwind.a";
inline const char *compilerRtBuiltinsA = "libclang_rt.builtins-x86_64.a";
inline const char *systemLinker      = "ld.lld";

// Project archives — basenames; resolved against
// runtimeFile(name, "project") at use sites.
inline std::vector<std::string> elmKernelLibs() {
    return {"libElmKernel_Basics.a", /* … 24 entries … */};
}
inline std::vector<std::string> ecoKernelLibs() {
    return {"libEcoKernel_File.a", /* … 9 entries … */};
}
inline const char *entryLib   = "libEcoEntryStatic.a";
inline const char *runtimeLib = "libEcoRuntimeStatic.a";

}}
```

The `runtimeDir()` / `runtimeFile()` implementation goes in a new
`EcoBootConfig.cpp` (compiled into `EcoNativeDriverStatic`):

```cpp
#include "eco/EcoBootConfig.h"
#include <cstdlib>
#include <libgen.h>
#include <limits.h>
#include <unistd.h>

namespace eco { namespace config {

std::string runtimeDir() {
    if (const char *env = std::getenv("ECO_RUNTIME_DIR"))
        return env;
    char buf[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return {};
    buf[n] = '\0';
    // dirname() may mutate its argument; copy first.
    std::string exe(buf);
    auto pos = exe.find_last_of('/');
    std::string binDir = (pos == std::string::npos) ? "." : exe.substr(0, pos);
    return binDir + "/../lib/eco-runtime";
}

std::string runtimeFile(const char *name, const char *subdir) {
    std::string p = runtimeDir();
    if (subdir && *subdir) { p += '/'; p += subdir; }
    p += '/'; p += name;
    return p;
}

}}
```

### 5. Update `linkExecutable`

`runtime/src/codegen/EcoNativeDriver.cpp:331-...`: every reference to a
baked path becomes a `runtimeFile()` lookup. Also drop every `-L` and
bare `-l` flag, replacing them with absolute paths under `lib/eco-runtime/`:

- `args.push_back(eco::config::crt1ObjStatic);` →
  `args.push_back(runtimeFile(eco::config::crt1ObjStatic, "crt"));`
- Similarly for `crtiObj`, `crtbeginObjStatic`, `crtendObjStatic`, `crtnObj`.
- `args.push_back(entryLib);` → `args.push_back(runtimeFile(entryLib, "project"));`
- Same for `runtimeLib` and every entry in `elmKernelLibs()` / `ecoKernelLibs()`.
- `args.push_back("-lc");` → `args.push_back(runtimeFile(libcStaticA));`
- `args.push_back(eco::config::libcxxStaticA);` → `runtimeFile(libcxxStaticA)`.
- `args.push_back(eco::config::libcxxabiStaticA);` → `runtimeFile(libcxxabiStaticA)`.
- Drop the `-L${libSearchDirs}` loop at lines 392-397 and the `-L${gccLibDir}`
  line at 398-399 entirely.
- Drop the `librarySearchDirs()` and `kernelSystemLibs()` config functions
  (no longer referenced) and their CMake generation.
- The vendored libcurl / libssl / libcrypto / libzip / libz statics
  (lines 474-478) already use absolute paths from `$<TARGET_FILE:...>`;
  switch those to `runtimeFile()` and install them under `lib/eco-runtime/`
  too. (See dependency list in step 2.)
- `eco::config::systemLinker` → `runtimeFile(eco::config::systemLinker)`.

### 6. Switch crtbegin/crtend to compiler-rt

In step 2, replace the `_eco_query_clang_path(ECO_CRTBEGIN_O_STATIC crtbegin.o)`
call (currently resolving to `/usr/lib/gcc/x86_64-alpine-linux-musl/14.2.0/crtbegin.o`)
with `_eco_query_clang_path(ECO_CRTBEGIN_O_STATIC clang_rt.crtbegin-x86_64.o)`.
Same for `crtend.o` → `clang_rt.crtend-x86_64.o`. Both are provided by the
compiler-rt apk package already installed in
`docker/static-build.Dockerfile:116`. Confirm at configure time with a
message; fail loudly if the file doesn't resolve (it'll come back as the
input filename when not found — guard against that).

Rationale: the rest of Stage B's runtime is compiler-rt + libc++ + LLVM
libunwind. Mixing in gcc's crtbegin pulls a foreign init/fini ABI that's
historically *worked* but is unprincipled. Bundling compiler-rt's variant
keeps the dependency story clean — eco only ever links against artifacts
from a single C++ runtime stack.

### 7. Add CPack configuration

Top-level `CMakeLists.txt`:

```cmake
if(ECO_STATIC_MUSL)
    set(CPACK_PACKAGE_NAME "eco")
    set(CPACK_PACKAGE_VERSION "0.1.0")
    set(CPACK_PACKAGE_FILE_NAME "eco-0.1.0-x86_64-linux-musl")
    set(CPACK_GENERATOR "TGZ;ZIP")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
        "Eco — Elm compiler with static AOT runtime (Stage B / MUSL)")
    set(CPACK_PACKAGE_VENDOR "thesett")
    set(CPACK_STRIP_FILES ON)            # strips bin/eco + lib/eco-runtime/ld.lld
    set(CPACK_PACKAGE_DESCRIPTION_FILE   # optional
        "${CMAKE_SOURCE_DIR}/plans/stage-c-bundle-runtime.md")
    include(CPack)
endif()
```

CPack's `STRIP_FILES` handles executables but not `.a` archives. For
those, add a post-install custom step or use `objcopy --strip-debug` in
the `install(TARGETS … ARCHIVE …)` rule via an intermediate
`install(CODE "...")` block. Add a CMake option
`ECO_BUNDLE_STRIP=ON` (default ON) gating archive stripping for users
who want debug info in the produced binaries.

Bundle outputs land in the build dir as
`eco-0.1.0-x86_64-linux-musl.tar.gz` and `…zip`. Building them:
`cmake --build build-static --target package` (CPack's built-in target).

### 8. Update the Dockerfile

`docker/static-build.Dockerfile:152` — after `cmake --build build --target eco`,
add:

```dockerfile
RUN apk add --no-cache zip   # CPack's ZIP generator needs the zip binary
RUN cmake --build build --target package
RUN ls -lh build/eco-0.1.0-x86_64-linux-musl.tar.gz build/eco-0.1.0-x86_64-linux-musl.zip
```

Stage 3 (currently `FROM scratch AS eco-static` shipping just the binary)
stays for backward compat. Add a parallel stage:

```dockerfile
FROM scratch AS eco-bundle
COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.tar.gz /
COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.zip    /
```

so `docker build --target eco-bundle -o ./dist .` drops both artifacts
into `./dist/`.

### 9. Smoke test inside the Dockerfile

Right after the `package` step:

```dockerfile
RUN tar -xzf build/eco-0.1.0-x86_64-linux-musl.tar.gz -C /tmp/ \
 && cp compiler/examples/src/Hello.elm /tmp/eco-0.1.0-x86_64-linux-musl/Hello.elm \
 && cd /tmp/eco-0.1.0-x86_64-linux-musl \
 && ./bin/eco make Hello.elm --output=hello \
 && ./hello \
 && readelf -d ./hello | (grep -q NEEDED && echo FAIL || echo OK)
```

This is the v1 acceptance test: the bundle, extracted in a temp dir
inside the same Alpine container, produces a runnable static binary.
Validation on a Debian host is manual for now (see follow-ups).

### 10. Documentation

New `docs/distribution.md` covering: bundle layout, extraction, the
`ECO_RUNTIME_DIR` override, supported hosts (any Linux x86_64), and the
"the produced binaries are MUSL-static — they will run anywhere but they
are not glibc binaries" caveat.

## Affected files (estimated diff)

| File | Change |
|---|---|
| `docker/static-build.Dockerfile` | `+lld` in LLVM_ENABLE_PROJECTS, `apk add zip`, `--target package`, new `eco-bundle` stage, smoke test |
| `runtime/src/codegen/CMakeLists.txt` | crtbegin → clang_rt; add libc.a resolution; rewrite EcoBootConfig.h generation; drop search-dir / kernelSystemLibs blocks |
| `runtime/src/codegen/EcoBootConfig.cpp` | new file — `runtimeDir()` / `runtimeFile()` |
| `runtime/src/codegen/EcoNativeDriver.cpp` | ~15 call-site rewrites; drop -L/-l blocks |
| `compiler/CMakeLists.txt` | `install(TARGETS eco …)` |
| `CMakeLists.txt` (top-level) | `install(TARGETS …)` for all project archives; CPack config |
| `docs/distribution.md` | new |
| `plans/static-link-eco-binary.md` | mark Stage C step 1 (this PR) done; update Stage C status |

## Verification

- `readelf -d eco-0.1.0-x86_64-linux-musl/bin/eco` — no NEEDED entries.
- `readelf -d eco-0.1.0-x86_64-linux-musl/lib/eco-runtime/ld.lld` — no NEEDED entries.
- `cd /tmp && tar xf eco-0.1.0-x86_64-linux-musl.tar.gz && eco-…/bin/eco make Hello.elm` — works inside the Alpine container (smoke test).
- Manual: same command on a Debian / Ubuntu host with *no* binutils, *no* musl-dev, *no* gcc installed — works (this is the actual Stage C win).
- `./hello` from the produced binary — runs, exits 0.
- `readelf -d ./hello` — no NEEDED entries (output binary is also fully static).
- Bundle size targets: `.tar.gz` < 80 MB, `.zip` < 100 MB after `CPACK_STRIP_FILES`.

## Follow-ups (separate plans)

- **In-process lld** — replace fork+exec of `ld.lld` with
  `lld::elf::link(…)`. Requires lld's `liblldELF.a` etc. in
  `/opt/llvm-mlir/lib`; step 1's `lld` addition to LLVM_ENABLE_PROJECTS
  already produces them, so a future PR can flip the switch without
  another LLVM rebuild.
- **GitHub Releases CI/CD** — GH Action that runs the docker build on tag
  push and uploads the `.tar.gz` + `.zip` artifacts.
- **Glibc Stage A bundle** — same approach, glibc-side. Lower priority
  since the MUSL bundle already runs on glibc hosts.
- **Reproducible builds** — pinned timestamps, sorted archive contents,
  etc.
- **Cross-architecture (ARM64)** — multi-bundle build matrix in CI.
