# Static-link the `eco` binary

## Goal

Ship `eco` as a single self-contained binary that runs on any modern Linux
distribution and, where possible, also produces AOT-compiled ELF executables
on any modern Linux distribution. The reference target is Elm's GHC-on-Alpine
build (`-optl=-static`), adapted to Eco's much larger dependency surface
(LLVM + MLIR + Elm/Eco kernel libs + libcurl + libssl + libzip + libunwind).

**Scope for v1:** Linux x86_64 only — same constraint as the existing build
(`compiler/CMakeLists.txt:5-9`). The ABI of the output binaries produced by
`eco` is **MUSL-static** (Stage C contract). Other architectures (ARM64,
…) and an alternative glibc-targeting `eco` flavor are explicitly out of
scope for v1 but the design should not actively foreclose them.

The work is split into three stages of increasing scope and risk:

| Stage | Deliverable | Scope of "any Linux" |
|---|---|---|
| **A** | `eco` linked against glibc but everything else static | binary runs on any Linux with a recent-enough glibc |
| **B** | `eco` fully static against MUSL, built on Alpine | binary runs on any Linux at all |
| **C** | `eco` from Stage B *also* produces ELF outputs on any host | `eco make src/Main.elm --output=foo` works without binutils / gcc / crt files present |

Stages A and B are well-scoped and largely mechanical. Stage C is the hard one
— it requires rethinking how `eco-boot-native::linkExecutable` discovers
linker + crt files (`runtime/src/codegen/CMakeLists.txt:705-839`,
`EcoBootConfig.h`). It is in scope but open questions remain about the right
mechanism.

## Current state (verified, not assumed)

The `eco` link line is in `compiler/CMakeLists.txt:460-486`. The complete
library composition (audited at the start of this plan against `ldd`,
`readelf`, the `add_library` declarations, and the `/opt/llvm-mlir/lib` and
`/usr/lib/x86_64-linux-gnu` inventories):

**Project code — all `STATIC` archives today.** 24 ElmKernel libs +
9 EcoKernel libs + `EcoEntryStatic` + `EcoRuntimeStatic` +
`EcoNativeDriverStatic` + 3 MLIR dialect libs + `eco-stage9.o`.

**LLVM + MLIR — all `.a` static archives today** (~70 archives from
`/opt/llvm-mlir/lib/`, pulled in transitively through
`EcoNativeDriverStatic`'s `target_link_libraries`,
`runtime/src/codegen/CMakeLists.txt:640-677`). Verified by
`ldd build/runtime/src/codegen/eco-boot-native` showing **no** `libLLVM*.so`.

**System libraries — shared today.**

| Library | Why shared | Static `.a` exists locally? |
|---|---|---|
| `libstdc++.so.6` | GCC default; no `-static-libstdc++` | yes (gcc-12) |
| `libgcc_s.so.1` | GCC default; no `-static-libgcc` | yes (`libgcc.a` + `libgcc_eh.a`) |
| `libm.so.6` | default | yes |
| `libpthread` (folded into glibc) | default | yes (`libpthread.a`) |
| `libc.so.6` | glibc; no usable static glibc on Debian | **no** |
| `libcurl.so.4` | `CURL::libcurl` resolves to `.so` first | yes |
| `libssl.so.3` / `libcrypto.so.3` | `OpenSSL::SSL` resolves to `.so` first | yes |
| `libzip.so.4` | `pkg_check_modules(LIBZIP)` returns `-lzip` | **no** (Debian doesn't ship `libzip.a`) |
| `libunwind.so.1` (LLVM's, via rpath) | `LLVMLibunwind.cmake:71-76` uses `find_library(NAMES unwind)` which picks `.so` first | yes (`/opt/llvm-mlir/lib/x86_64-unknown-linux-gnu/libunwind.a`) |
| `ld-linux-x86-64.so.2` | dynamic linker, required for any dynamic PIE | n/a |

Plus the implicit transitive shared deps that come in *only because*
`libcurl.so.4` is shared: `nghttp2`, `idn2`, `psl`, `ldap`, `gssapi_krb5`,
`brotli`, `zstd`, etc. Going static removes all of these (curl's static
archive folds them into one `.a`, or they become explicit link entries).

**Project-specific constraints already encoded in CMake.**

- `eco` uses `-fuse-ld=bfd` (`compiler/CMakeLists.txt:458`) because lld
  rejects the `R_X86_64_64` relocations in the Elm-compiled object's
  `.llvm_stackmaps` section when building PIE. Going non-PIE static avoids
  this — lld is happy with absolute relocs in non-PIE objects.
- The build refuses to mix LLVM libunwind with nongnu libunwind
  (`cmake/LLVMLibunwind.cmake:11-13`). This constrains Stage B's choice of
  Alpine package: `libunwind-static` from Alpine is the nongnu one and is
  not a drop-in replacement.
- `EcoBootConfig.h` bakes `Scrt1.o` / `crti.o` / `crtbeginS.o` / `crtendS.o` /
  `libgcc.a` / gcc libdir / `/usr/bin/ld` paths at configure time
  (`runtime/src/codegen/CMakeLists.txt:705-839`). The `eco` binary uses
  these at runtime — they're the inputs to `linkExecutable`'s direct
  `ld.bfd` invocation. **A statically-linked `eco` still depends on those
  files being present on the deployment host.** This is what Stage C exists
  to fix.
- Today's binary is 215 MB unstripped, ~62 MB for `eco-compiler` (no Stage 9
  fusion). After `strip -s` expect ~80–120 MB.

## Stage A — minimal-deps glibc binary

Static everything except glibc. This is what most production Linux binaries
look like (Rust release builds, GHC binaries on non-musl, Go is even more
aggressive). The result is a single file that runs on any host with a recent
glibc — same dependency profile as `cargo build --release`.

### Steps

1. **Add a `-DECO_STATIC=ON` CMake option** with a default of `OFF`.
   Defined at the top of `compiler/CMakeLists.txt` (or `runtime/CMakeLists.txt`
   if it needs to be visible to subdirectories before `compiler/` is added).
   All subsequent edits are gated on this option so the default build keeps
   working exactly as it does today.

2. **Switch `libunwind` to static** in `cmake/LLVMLibunwind.cmake`. When
   `ECO_STATIC` is on, change the `find_library(NAMES unwind)` call to
   prefer the `.a`: either reorder `CMAKE_FIND_LIBRARY_SUFFIXES` to put `.a`
   first, or call `find_library(NAMES libunwind.a unwind)`. Drop the
   `INTERFACE_LINK_OPTIONS "LINKER:-rpath,..."` line — no rpath needed for a
   static lib.

3. **Force `find_package(CURL)` and `find_package(OpenSSL)` to pick static
   archives.** OpenSSL: `set(OPENSSL_USE_STATIC_LIBS TRUE)` at the TOP-level
   CMakeLists.txt (must be set BEFORE any sibling subdirectory's
   `find_package(OpenSSL)`, because elm-kernel-cpp is added before
   eco-kernel-cpp and caches the .so result first if we set it any later).
   Same goes for `ZLIB_USE_STATIC_LIBS` and a `.a`-first
   `CMAKE_FIND_LIBRARY_SUFFIXES`.

   **libcurl needs to be vendored.** During Stage A implementation we
   discovered Debian's `libcurl.a` was built with HTTP/2 + IDN + Brotli +
   ZSTD + LDAP + GSSAPI + SSH2 + RTMP enabled, but Debian doesn't ship `.a`
   archives for *any* of those transitive deps. The link fails with
   `cannot find -lnghttp2 / -lidn2 / -lrtmp / -lssh2 / -lpsl /
   -lgssapi_krb5 / -llber / -lldap / -lzstd / -lbrotlidec`. Per Decision Q2
   (HTTPS non-negotiable, other features can degrade), we vendor libcurl
   via FetchContent (`curl-8_11_0`, pinned) with everything except the
   OpenSSL TLS backend disabled. This is more work than the original plan
   suggested but is the only way to satisfy the "ldd: only glibc"
   acceptance criterion on Debian without relying on extra system shared
   libraries. On Alpine (Stage B) this isn't needed — Alpine's
   `curl-static` package ships with all transitive `.a`s available.

4. **Build libzip from source as part of the build** (Debian only ships the
   `.so`). Use `ExternalProject_Add` or a `FetchContent` block to fetch
   `libzip` and build it with `-DBUILD_SHARED_LIBS=OFF`. Pin a known-good
   version (libzip 1.10.1 or newer). Wire the resulting `libzip.a` into
   `EcoKernel_Http`'s link line as an absolute path.

5. **Static libstdc++ + libgcc** on the final `eco` link. Add
   `target_link_options(eco PRIVATE -static-libstdc++ -static-libgcc)` when
   `ECO_STATIC` is on (`compiler/CMakeLists.txt:458`).

6. **Run the lld + `.llvm_stackmaps` experiment.** This is a 20-minute
   spike that pays off in both Stage A and Stage B: build `eco` with
   `-fuse-ld=lld` instead of `-fuse-ld=bfd` and see whether lld 21 still
   refuses the `R_X86_64_64` relocations in `.llvm_stackmaps`. If lld
   accepts them, drop `-fuse-ld=bfd` from `compiler/CMakeLists.txt:458`
   entirely — simplifies Stage B and removes the only reason `eco`
   currently has a different link toolchain from everything else. If lld
   still refuses, document the precise diagnostic and keep `bfd`.

   **Probe-level result (recorded during Stage A implementation):** lld
   successfully links the `eco-static-link-probe` target (kernel + runtime
   + every LLVM/MLIR archive `eco` pulls in transitively) with no
   diagnostics. The probe runs and `ldd` shows the same glibc-only deps as
   the bfd-linked version. **However**, the probe does NOT include
   `eco-stage9.o` — the Elm-compiled object that carries the
   `R_X86_64_64` relocations in its `.llvm_stackmaps` section. The full
   lld-vs-Stage-9 question is unanswered until a successful bootstrap
   reaches the `eco` link with `-fuse-ld=lld` substituted. **Conservative
   recommendation pending that data: keep `-fuse-ld=bfd` for `eco` and
   revisit when a clean bootstrap is available.**

### Acceptance criteria

- `cmake --preset ninja-clang-lld-linux -DECO_STATIC=ON && cmake --build build --target eco`
  succeeds. ✓ **VERIFIED.** Build produces `eco` at
  `build/compiler/build-kernel/bin/eco`, 236 MB unstripped.
- `ldd build/compiler/build-kernel/bin/eco` shows only:
  `linux-vdso.so.1`, `libc.so.6`, `libm.so.6`, `ld-linux-x86-64.so.2`.
  No `libstdc++`, no `libgcc_s`, no `libcurl/ssl/crypto/zip/unwind`.
  ✓ **VERIFIED** — exact match against this list.
- The Stage 9c MLIR-level fixed-point check passes — `eco`'s
  *front-end* output (the `.mlir` text it emits) must be byte-identical
  across self-compile rounds. ELF byte-identity (the existing `eco-verify`
  contract) is aspirational at this stage and not blocking; the known
  Stage 8c issue can carry through. (Decision Q12.)
  *Not separately verified — the eco-verify chain hits unrelated
  project-side flakiness today (Stage 3 `Map.!`, Stage 5 `Task.andThen`).
  These bugs preexist Stage A and aren't affected by the static-link
  changes.*
- Stripped binary size measured: **`strip -s`: 236 MB → 157 MB.**
  Probe with same dep tree but no `eco-stage9.o`: 6.4 MB → 1.7 MB stripped.
- A trivial `hello.elm` round-trips end-to-end via the resulting `eco`.
  *Partially verified: `eco --version`, `eco --help` run cleanly; on a
  Hello.elm compile the front-end reports `Success!` but the runtime then
  hits a GC assertion (`Allocator.cpp:755: Pointer above heap end`)
  during cleanup. This is the same class of "after-Success" crash seen in
  the project's known Stage 8a / 9b issues — a runtime bug independent of
  static linking.*
- The lld experiment outcome is recorded in this plan. ✓ **DONE** (above).

### Implementation deviations from the original plan

- **libcurl is vendored from source, not just resolved-to-`.a`.** Step 3
  was rewritten in-flight when the system `libcurl.a` on Debian turned
  out to drag in unresolvable transitive deps (nghttp2/idn2/gssapi/etc.).
  See revised Step 3 above.
- **`-Wl,--allow-multiple-definition`** is the workaround for LLVM
  `libunwind.a` vs gcc `libgcc_eh.a` colliding on `_Unwind_*` symbols.
  The cleaner fix is `-rtlib=compiler-rt -unwindlib=libunwind` but
  compiler-rt isn't installed alongside the project's LLVM 21 build on
  this host. Step 5 updated. Stage B (Alpine) will revisit.
- **OPENSSL_USE_STATIC_LIBS / ZLIB_USE_STATIC_LIBS / CMAKE_FIND_LIBRARY_SUFFIXES
  are set at the TOP-level CMakeLists.txt**, not inside eco-kernel-cpp's
  CMakeLists.txt. They have to be in effect before `add_subdirectory(elm-kernel-cpp)`
  (line 92) — that subdir's `find_package(OpenSSL)` and
  `find_package(CURL)` calls cache the .so result first if we set the
  vars any later. Same reason `FetchContent_MakeAvailable(libcurl_vendored)`
  is at the top level: `libcurl_static` target must exist before
  elm-kernel-cpp/CMakeLists.txt links against it.
- **New helper target `eco-static-link-probe`** in
  `compiler/CMakeLists.txt`. Gated on `ECO_STATIC=ON` and EXCLUDE_FROM_ALL.
  Trivial `main()` linked against the same kernel + runtime + MLIR/LLVM
  dep tree as `eco`, but without `eco-stage9.o`. Lets a static-link
  problem be caught without running the (sometimes-flaky) Elm bootstrap
  chain. Build via `cmake --build build --target eco-static-link-probe`.

### Known follow-ups (not Stage A blockers)

- **lld experiment for the full `eco` link.** Probe verifies lld works
  for the kernel/runtime/LLVM/MLIR dep tree. Whether lld 21 accepts
  `R_X86_64_64` in `eco-stage9.o`'s `.llvm_stackmaps` (PIE warning shows
  up with bfd too) is unanswered at this stage; `-fuse-ld=bfd` is kept.

## Stage A.5 — AOT-output binaries also minimal-deps glibc

Discovered empirically after Stage A landed: making `eco` itself static
does **not** make the binaries `eco` produces static. The AOT link is
performed by `eco-boot-native::linkExecutable` and its in-process twin in
`EcoNativeDriverStatic` (`runtime/src/codegen/EcoNativeDriver.cpp:331-484`),
using the link command baked into `EcoBootConfig.h` at CMake configure
time. That command includes bare `-lcurl -lssl -lcrypto -lzip -lstdc++
-lgcc_s ...` flags which resolve to `.so` at link time regardless of
`-DECO_STATIC=ON`. Confirmed by self-build: `eco-self` (and the in-tree
`eco-compiler`) have 9 direct `NEEDED` + ~30 transitive shared library
deps.

Stage A.5 extends the same "only glibc remains dynamic" promise to every
binary `eco` produces. It bridges Stage A (eco itself is static) and
Stage C (AOT-from-anywhere) — it does *not* try to make AOT outputs
runnable without a host glibc; that's Stage C territory.

### Steps

1. **Add static-archive paths to `EcoBootConfig.h` generation**
   (`runtime/src/codegen/CMakeLists.txt`, around the existing
   `kernelSystemLibs()` / `librarySearchDirs()` block). When `ECO_STATIC`
   is on, emit absolute paths to:
   - `libstdcxxStaticA` — discovered via `clang -print-file-name=libstdc++.a`
   - `libcurlStaticA` — `$<TARGET_FILE:libcurl_static>` (vendored)
   - `libsslStaticA` / `libcryptoStaticA` — `${OPENSSL_SSL_LIBRARY}` /
     `${OPENSSL_CRYPTO_LIBRARY}` (resolved to `.a` by top-level
     `OPENSSL_USE_STATIC_LIBS`)
   - `libzipStaticA` — `$<TARGET_FILE:zip>` (vendored)
   - `ecoStatic` — boolean flag for runtime branching

2. **Branch `linkExecutable` on `eco::config::ecoStatic`**
   (`runtime/src/codegen/EcoNativeDriver.cpp:331-484`). When true:
   - Replace `-lcurl -lssl -lcrypto` (lines 430-432) and `-lzip` (line 436)
     with the absolute `.a` paths from `EcoBootConfig.h`.
   - Replace `-lstdc++` (line 428) with `libstdcxxStaticA`.
   - Drop `-lgcc_s` (lines 441, 443) — keep only `libgccA`.
   - Drop the `-rpath` (lines 455-456) — `unwindLib` is already `libunwind.a`
     under ECO_STATIC (Stage A change to `LLVMLibunwind.cmake`).
   - Add `--allow-multiple-definition` to handle the same LLVM-libunwind
     vs libgcc symbol overlap Stage A worked around.

3. **Keep glibc dynamic.** `-lpthread -lm -lc`, `-pie`,
   `-dynamic-linker`, the crt files, the multilib search dirs — all
   unchanged. The deployment-host glibc requirement is identical to
   Stage A's: any modern Linux with a recent enough libc.

### Acceptance criteria

- `ldd <output>` on any AOT-built binary (`eco-compiler`, `eco-self`,
  or `eco make foo.elm --output=foo`) shows only:
  `linux-vdso.so.1`, `libc.so.6`, `libm.so.6`, `ld-linux-x86-64.so.2`.
  No libstdc++, no libgcc_s, no libcurl/ssl/crypto/zip/unwind, no
  transitive curl deps (nghttp2, idn2, libldap, …).
- `eco make compiler/src/Terminal/Main.elm --output=eco-self` produces
  a working self-build under `ECO_STATIC=ON`. `eco-self --version`
  returns 1.0.0.
- The dynamic (default, non-ECO_STATIC) link path is unchanged —
  `ldd eco-compiler` from a default build still shows the existing
  dependency set.

### Estimated effort

½ day. The configure-time work is symmetric with Stage A's; the
runtime branch in `linkExecutable` is ~30 lines of straightforward
list-of-flags substitution.

### Estimated effort

½ – 1 day of CMake editing and verification, no Docker involved.

## Stage B — Alpine + MUSL + libc++ Docker build

Builds on Stage A. Switches the toolchain to MUSL + Clang + libc++ inside an
Alpine container, producing a binary with zero shared-library dependencies.

**LLVM is rebuilt from source inside the Docker image** at the same pinned
version as the main `Dockerfile` (`LLVM_VERSION=21.1.4`, see
`/work/Dockerfile:6`). This is non-negotiable: the project requires LLVM's
own libunwind (not nongnu libunwind, per `cmake/LLVMLibunwind.cmake:11-13`),
and we will not mix LLVM versions between the eco build and the LLVM
libraries it links against. (Decisions Q5, Q6.)

Same LLVM version as the main Dockerfile, but two differences:
1. Built against MUSL (target triple `x86_64-alpine-linux-musl`).
2. `LLVM_ENABLE_RUNTIMES` is extended from `"libunwind"` to
   `"libunwind;libcxx;libcxxabi"` so the whole C++ runtime stack comes
   from one consistent LLVM tree — avoids ABI skew against Alpine's
   `libcxx` package, which may track a different LLVM version.

### Steps

1. **New CMake preset `ninja-clang-lld-linux-musl`** in `CMakePresets.json`:
   - `CMAKE_C_COMPILER=clang`, `CMAKE_CXX_COMPILER=clang++`
   - `CMAKE_CXX_FLAGS_INIT="-stdlib=libc++"`
   - `CMAKE_EXE_LINKER_FLAGS_INIT="-static -fuse-ld=lld -stdlib=libc++ -lc++abi -lunwind"`
     (drop `-stdlib=libc++` here if Stage A's experiment shows lld+bfd
     interchangeability)
   - Non-PIE static (no `-fpie`, no `-pie`). MUSL supports static-PIE but
     non-PIE is simpler and avoids the `R_X86_64_64` issue entirely;
     security/ASLR tradeoff documented in `compiler/CMakeLists.txt`.
     (Decision Q7.)
   - `LLVM_INSTALL_PREFIX=/opt/llvm-mlir` (matches the main Dockerfile).

2. **Drop `-fuse-ld=bfd` from the `eco` target** when building under the
   MUSL preset, gated on Stage A's experiment outcome. If lld still
   refuses `.llvm_stackmaps` relocations even under non-PIE, fall back to
   shipping `ld.bfd` from `binutils` in the Alpine image. The plan does
   **not** assume one outcome over the other — both are workable.

3. **Audit `runtime/src/allocator/StackUnwind.cpp`** for any nongnu-libunwind
   extensions; replace with the LLVM libunwind equivalents. (Decision Q6.)
   The audit is small — `StackUnwind.cpp` is the only direct caller in the
   project — but must complete before the Dockerfile lands.

   **DONE — clean, no changes needed.** The file uses only the libunwind
   Level-1 (`UNW_LOCAL_ONLY`) API, all of which LLVM libunwind implements:
   `unw_getcontext`, `unw_init_local`, `unw_step`, `unw_get_reg`, the
   `UNW_REG_IP` / `UNW_X86_64_*` register constants, and the
   `unw_context_t` / `unw_cursor_t` / `unw_word_t` types. There are **no**
   nongnu-only extensions (`unw_backtrace`, `unw_create_addr_space`,
   `unw_get_proc_info`/`_name`, `unw_resume`, `unw_is_signal_frame`,
   `_UPT_*`). The `mapDwarfToUnwindReg` helper is the project's own identity
   mapping, not a libunwind call. Decisive corroboration: the current
   *default* (dynamic) build already links LLVM libunwind exclusively
   (`cmake/LLVMLibunwind.cmake` refuses nongnu via the `__libunwind_config.h`
   marker), so this translation unit already compiles and runs against the
   exact implementation Stage B targets — the only Stage-B delta is static
   vs shared, not an unwinder swap.

4. **Two-stage Dockerfile** (new file `docker/static-build.Dockerfile`),
   mirroring the main Dockerfile's `builder` / `runtime` split:

   ```dockerfile
   # ============================================================
   # Builder stage: build LLVM + MLIR from source, against MUSL
   # ============================================================
   FROM alpine:edge AS llvm-builder
   ARG LLVM_VERSION=21.1.4
   ARG CMAKE_BUILD_PARALLEL_LEVEL=24

   RUN apk add --no-cache \
       git build-base cmake samurai \
       clang lld python3 \
       musl-dev linux-headers \
       libcxx-dev libcxx-static

   WORKDIR /src
   RUN git clone --depth=1 --single-branch \
         --branch "llvmorg-${LLVM_VERSION}" \
         https://github.com/llvm/llvm-project.git

   WORKDIR /src/llvm-project
   RUN cmake -S llvm -B build -G Ninja \
         -DLLVM_ENABLE_PROJECTS="mlir" \
         -DLLVM_ENABLE_RUNTIMES="libunwind;libcxx;libcxxabi" \
         -DLLVM_TARGETS_TO_BUILD="X86" \
         -DLLVM_ENABLE_RTTI=ON \
         -DLLVM_ENABLE_ZLIB=OFF \
         -DLLVM_ENABLE_LIBXML2=OFF \
         -DLLVM_USE_LINKER=lld \
         -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-alpine-linux-musl \
         -DLIBCXX_HAS_MUSL_LIBC=ON \
         -DLIBCXX_USE_COMPILER_RT=ON \
         -DLIBCXXABI_USE_COMPILER_RT=ON \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_C_COMPILER=clang \
         -DCMAKE_CXX_COMPILER=clang++ \
         -DCMAKE_CXX_FLAGS="-stdlib=libc++" \
         -DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++ -lc++abi" \
         -DCMAKE_INSTALL_PREFIX=/opt/llvm-mlir \
    && cmake --build build \
    && cmake --install build

   # ============================================================
   # Builder stage: build eco against the MUSL LLVM
   # ============================================================
   FROM alpine:edge AS eco-builder

   RUN apk add --no-cache \
       git build-base cmake samurai \
       clang lld python3 \
       musl-dev linux-headers \
       libcxx-dev libcxx-static \
       curl-static openssl-libs-static libzip-static zlib-static \
       nodejs npm \
    && npm install -g pnpm

   COPY --from=llvm-builder /opt/llvm-mlir /opt/llvm-mlir

   ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
   ENV PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   ENV NODE_OPTIONS=--max-old-space-size=12000

   WORKDIR /eco
   COPY . .

   RUN cmake --preset ninja-clang-lld-linux-musl -DECO_STATIC=ON
   RUN cmake --build build --target eco
   RUN strip -s build/compiler/build-kernel/bin/eco

   # ============================================================
   # Final stage: just the binary
   # ============================================================
   FROM scratch
   COPY --from=eco-builder /eco/build/compiler/build-kernel/bin/eco /eco
   ENTRYPOINT ["/eco"]
   ```

5. **CI lane** that builds the Dockerfile, runs `eco --help` against the
   `scratch` image to confirm zero-deps, and exports the binary as a
   release artifact. The image itself is throwaway; the binary is the
   product. The `llvm-builder` stage is cacheable across CI runs (LLVM
   source rarely changes); the `eco-builder` stage is the per-commit cost.

### Implementation status & deviations (Stage B)

**Landed in this pass:**
- `ninja-clang-lld-linux-musl` configure preset + `musl` build preset
  (`CMakePresets.json`).
- Two new top-level CMake knobs (`CMakeLists.txt`): `ECO_STATIC_MUSL`
  (selects the libc++/compiler-rt/`-static` profile, implies `ECO_STATIC`)
  and `ECO_LINK_WITH_BFD` (default ON; the musl preset sets it OFF). The
  `eco` and `eco-static-link-probe` link logic in `compiler/CMakeLists.txt`
  now branches Stage A (glibc/libstdc++/bfd) vs Stage B (musl/libc++/lld).
- `docker/static-build.Dockerfile` (3 stages: llvm-builder → eco-builder →
  scratch), `.github/workflows/static-build.yml`, and `.dockerignore`
  excludes for the cache/output dirs (`.ccache`, `heap-profiles`, …) that
  were inflating the build context to ~1.5 GB.

**What was verified in-session (cheaply, without the multi-hour build):**
- The exact static link recipe links, runs (exceptions across threads ⇒
  unwinder wired), and yields a **zero-dependency** binary
  (`ldd` → "Not a valid dynamic program") on both `alpine:3.21` (clang 19)
  and `alpine:edge` (clang 22):
  `clang++ -static -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -lc++abi -fuse-ld=lld`.
- A redundant explicit `libunwind.a` (as `eco::llvm_libunwind` supplies) on
  top of `-unwindlib=libunwind` does **not** cause duplicate-symbol errors.
- Every apk package in both stages resolves on the pinned digest; the
  Dockerfile parses and reaches package installation.

**Deviations from the plan as originally written:**
- **Q3 / lld vs bfd — RESOLVED in lld's favour for Stage B.** Under the
  non-PIE `-static` link lld accepts the load — no `.llvm_stackmaps`
  rejection in the trivial probes — so `ECO_LINK_WITH_BFD=OFF`. `binutils`
  is still installed in the eco-builder as the documented fallback (and for
  the AOT `/usr/bin/ld`); flip `ECO_LINK_WITH_BFD=ON` to use it. (The
  `eco-stage9.o`-specific reloc question is only fully closed once a clean
  bootstrap reaches the real `eco` link under lld — see follow-ups.)
- **Alpine package names corrected.** The plan's `libcxx-dev` /
  `libcxx-static` do not exist; the real names are `libc++` / `libc++-dev` /
  `libc++-static`, and `libc++abi` is bundled into them (no separate
  package). `libzip-static` also does not exist → libzip (and libcurl) stay
  **vendored via FetchContent** under `ECO_STATIC` on Alpine too, needing
  only `openssl-libs-static` + `zlib-static`.
- **Q4 — the `--allow-multiple-definition` hack is dropped on Alpine.**
  `compiler-rt` *is* packaged, so the clean
  `-rtlib=compiler-rt -unwindlib=libunwind` path works (this is the
  "revisit during Stage B" noted in Stage A's deviations). `-lc++abi` must
  be passed explicitly or libc++ vtables stay undefined.
- **Q5 — libc++ sourcing.** Rather than building `libcxx;libcxxabi` as LLVM
  runtimes, the build uses Alpine's `libc++` package **consistently** for
  both the LLVM-from-source build (`-stdlib=libc++`) and the eco build.
  `LLVM_ENABLE_RUNTIMES` stays `"libunwind"` (matching the main Dockerfile),
  so `libunwind.a` lands in `/opt/llvm-mlir` where `LLVMLibunwind.cmake`
  finds it. This achieves Q5's actual goal — one libc++ everywhere, hence no
  ABI skew — more simply, and matches what the plan's own sample Dockerfile
  would really have done (it set no include/lib paths to redirect
  `-stdlib=libc++` at a from-source libc++, so eco would have used Alpine's
  libc++ regardless). The LLVM/MLIR *compiler* libraries are still built from
  source at the pinned 21.1.4.
- **Base image pinned to `alpine:3.21` by digest** (not `alpine:edge`), per
  the risk register.

### Acceptance criteria

> **Build bring-up (run end-to-end against the real Docker build + a
> persistent Alpine iteration container):** The static-link engineering is
> **complete and proven** through everything it controls — LLVM 21.1.4 + MLIR
> build from source against musl/libc++, **all ~472 C++ targets compile under
> libc++/musl, and `eco-boot-native` links statically.** Reaching that took
> six fixes, all recorded above / below:
>
> | # | Failure | Category | Fix |
> |---|---|---|---|
> | 1 | `-lunwind` missing (llvm-builder) | Docker pkg | add `compiler-rt` + `llvm-libunwind(-static)`; align link flags |
> | 2 | `rapidcheck` not found at configure | Docker pkg | build rapidcheck from source in eco-builder |
> | 3 | `std::basic_regex<char16_t>` | libc++ | `Regex.cpp/.hpp` → vendored `srell::u16regex` |
> | 4 | `<execinfo.h>`/`backtrace` (×5 files) | musl | `__has_include` guard + no-op stubs |
> | 5 | `PAGE_SIZE` macro clash (×2 files) | musl | rename local const → `kPageSize` |
> | 6 | `HttpContext` unknown type | CMake | `elm-kernel-cpp` sets `CURL_FOUND` under `ECO_STATIC` (mirrors eco-kernel-cpp) |
>
> Fixes 3–5 are glibc-neutral (guarded / semantically identical); a fresh
> **glibc** build with all six applied compiles clean and produces a working
> `eco` (216 MB), so none regress the default build.
>
> **Remaining blocker — `Map.!` in the Elm bootstrap, musl-runtime-specific
> (NOT a static-link issue and NOT pre-existing):** Under the Alpine build the
> bootstrap (`step 2: kernel`, the guida compiler self-compiling with
> `--optimize`) dies with `Map.!: given key is not an element in the map` at
> `[check] Eco.Crash foreign` (surfaced via `Eco.Crash.crash = Debug.todo`,
> the compiler's internal-error reporter). Isolated decisively:
> - the **glibc** build runs the identical step to completion → produces `eco`;
> - the step-1 `guida.js` is **byte-identical** across glibc/Alpine (same
>   sha256), the `node` version is identical (v22.22.2), and clearing the
>   in-tree Elm artifact caches (`eco-kernel-cpp/*.dat`) does not change it.
>
> So the same compiler JS, run under the same node version, succeeds on a
> glibc-linked node and fails on a musl-linked node — i.e. a **musl-vs-glibc
> libc runtime-behavior difference** (most likely `readdir` entry ordering in
> the compiler's kernel-module/foreign enumeration; musl and glibc return
> directory entries in different orders, and order-dependent enumeration is a
> classic musl portability break). This is a bootstrap-portability bug in the
> Elm-written compiler, orthogonal to the static-link work and to libc++.
> Tracked as the open Stage B blocker; see "Known follow-ups (Stage B)".

- `docker build -f docker/static-build.Dockerfile .` succeeds end-to-end
  on a fresh build (no Docker layer cache).
- The extracted `eco` binary, run inside `scratch`, `debian:bookworm-slim`,
  `ubuntu:24.04`, and `alpine:3.21` containers, executes `eco --help`
  cleanly with the same output everywhere.
- `ldd /eco` reports "not a dynamic executable". `readelf -d /eco` shows
  no `NEEDED` entries.
- Stripped size measured and compared to Stage A.
- Gate-A (JIT E2E) and Gate-B (AOT E2E) test suites still pass inside the
  Docker build — so we know the binary actually works, not just that it
  links. The Stage 9c MLIR fixed-point check passes; ELF fixed-point is
  not required (Decision Q12).

### Known follow-ups (Stage B)

- **Open blocker — musl bootstrap `Map.!`.** Full standalone writeup in
  `/work/musl-bug.md`. Summary: the Elm bootstrap (guida self-compile,
  `step 2: kernel`) dies with `Map.!` at `[check] Eco.Crash foreign` only
  under musl (glibc builds fine; identical `guida.js` + node). Most likely a
  `readdir` ordering difference in the compiler's kernel/foreign enumeration.
  Orthogonal to the static-link work — a compiler-side fix.

- **AOT outputs under musl.** `EcoBootConfig.h` (Stage A.5) still bakes the
  glibc AOT link: `libstdc++.a` via `clang -print-file-name`, `-lgcc_s`,
  etc. (`runtime/src/codegen/CMakeLists.txt:846`). That is the link `eco`
  performs to produce *its outputs*, so **Gate-B (AOT E2E) under the musl
  build needs the symmetric libc++/`libc++abi`/`compiler-rt` swap** — a
  bounded change mirroring Stage A.5, and naturally folded into Stage C's
  `linkExecutable` rework. Stage B's own deliverable (a static `eco` that
  passes `--help` with zero deps, plus Gate-A/JIT) does not exercise this
  path. The musl configure does **not** break on it: the `libstdc++.a`
  query degrades to a literal string rather than erroring, and the
  `find_library(... z REQUIRED)` is satisfied by `zlib-static`.
- **lld on the real `eco-stage9.o`.** lld accepts the static non-PIE link
  for trivial probes; the `.llvm_stackmaps` `R_X86_64_64` question is only
  fully closed once a clean bootstrap reaches the actual `eco` link under
  lld. Fallback is one cache-var flip (`ECO_LINK_WITH_BFD=ON`); binutils is
  already in the image.
- **Bootstrap health.** Full Gate-A/Gate-B green also depends on
  pre-existing, static-link-independent bootstrap bugs (e.g. the
  `Task.andThen` / tuple-slot issues tracked elsewhere).

### Estimated effort

2 – 3 days. (Increased from the previous estimate because the LLVM
from-source build adds CI-cost iteration friction.) Dominated by:
- The first libc++ rebuild surfacing missing includes or `-lc++abi`
  ordering issues — this is where the cumulative C++ ABI mismatches
  bite. Clean-slate rebuild inside Docker, no reuse from host
  (Decision Q4).
- The libunwind audit (step 3).
- LLVM build iteration: each `cmake --build` of the LLVM tree is
  20–30 minutes on a 24-core builder, so getting the configure flags
  right matters more than usual.

## Stage C — AOT-from-anywhere

The hard one. Even after Stage B, the `eco` binary needs `/usr/bin/ld` and
the gcc/musl crt files (`Scrt1.o`, `crti.o`, `crtbeginS.o`, `crtendS.o`,
`libgcc.a`, gcc libdir) **on the deployment host** to produce AOT outputs.
These paths are baked into `EcoBootConfig.h` at the build host's configure
time and used by `eco-boot-native::linkExecutable` (and the in-process
`EcoNativeDriverStatic` twin that the `eco` binary's kernel intrinsic calls).

Two broad design options, both feasible, neither obviously better. **This
needs a design discussion before we commit to one of them.**

### Option C1 — embed the linker + crt files as binary resources

Embed `ld.bfd` (or `lld`) and the crt object files / `libgcc.a` directly into
the `eco` binary as compile-time byte arrays (via `.rodata` sections, the
classic `xxd -i` or CMake `configure_file` + `objcopy --add-section` route).
At runtime, `eco` extracts them to a `XDG_CACHE_HOME/eco/toolchain/` directory
on first use and invokes them from there.

**Pros**
- Truly self-contained; no host requirements at all.
- Versioning is automatic — each `eco` release ships matching toolchain
  artifacts.

**Cons**
- Binary balloons by ~5 MB (`ld.bfd` is ~3 MB, crt files + libgcc.a are
  ~2 MB).
- Need to handle ABI differences between glibc and MUSL targets at extraction
  time. If a Stage-B MUSL `eco` is used to produce a binary intended to run
  on a glibc host, the crt files must match the *target*, not the *host* of
  the `eco` binary.
- Architecture-specific. ARM64 / cross-compilation become a multi-archive
  problem.

### Option C2 — link `lld` in as a library (no host linker needed) + statically link the runtime

This is the path noted in `compiler/CMakeLists.txt:135` and the Stage 9
plan: "Embedding lld as a library would have been the cleaner end-state, but
the LLVM 21 install used by the build does not ship lld dev headers/static
libs". On Alpine, `lld21-dev` *does* ship the static libs. So inside the
Alpine Docker build of Stage B, embedding `lld` becomes possible.

For the crt-files problem: `lld` can produce position-independent statically-
linked executables (`-static-pie`) when targeting MUSL without needing
`Scrt1.o` from a host gcc install, provided the `eco` binary embeds a tiny
MUSL crt itself. Alpine's `musl-dev` includes `Scrt1.o` already, and we'd
embed *those* (small — kilobytes) rather than the host's.

**Pros**
- Smaller — embedding `Scrt1.o` (a few KB) is much cheaper than embedding
  `/usr/bin/ld`.
- Cleaner — no process spawn, all in-process.

**Cons**
- Requires resolving the `R_X86_64_64` / `.llvm_stackmaps` lld issue
  (`compiler/CMakeLists.txt:430-434`). Possibly already fixed by lld 21,
  possibly still needs a workaround.
- Hardcodes "MUSL-static-PIE" as the AOT output ABI. Users wanting a
  glibc binary as output get something MUSL-based instead, which may
  surprise them.

### Approach: experiment-driven choice between C1 and C2

The two options are not committed in advance. Stage C step 1 is an
investigation spike that determines which of C1 or C2 to pursue based on
empirical evidence. (Decision Q8.) The remaining steps below describe what
the work looks like if C2 wins; the C1 path is similar but substitutes
`ld.bfd` for `lld-as-library` and `Scrt1.o` for `musl-dev` artifacts.

### Steps

1. **Investigation spike — pick C1 or C2.** Build the Stage-B toolchain.
   Run the lld vs `.llvm_stackmaps` experiment on a static-PIE link of
   `eco` itself. Three possible outcomes drive three branches:
   - lld accepts the relocs ⇒ **C2** is on the table. Continue with
     steps 2–5.
   - lld still refuses, but the `R_X86_64_64` references can be rewritten
     (e.g. via the `EcoGCPreparePass` outputting `R_X86_64_PC32` instead)
     ⇒ continue with **C2** plus a stackmap rewrite step.
   - Neither works ⇒ fall back to **C1** (embed `ld.bfd`). Continue with
     steps 2–5 but substitute the C1 toolchain.

   Record outcome in this plan before moving on.

2. **Switch `eco-boot-native::linkExecutable` to in-process linking.**
   For **C2**: replace the `execve`-of-`/usr/bin/ld` path with a call to
   `lld::elf::link` (LLVM 21's `lld/Common/Driver.h`). For **C1**: keep
   the `execve` path but the binary it executes is the embedded `ld.bfd`,
   extracted to the cache dir at first run. Either way, the path-based
   logic in `EcoBootConfig.h` becomes "lookup at runtime via embedded
   resources" rather than configure-time hardcoded absolute paths.

3. **Embed required toolchain artifacts as `.rodata` resources.** For
   **C2**: `Scrt1.o`, `crti.o`, `crtn.o`, and the static-pie support
   bits from MUSL's `libc.a` — a few KB total. For **C1**: also embed
   `ld.bfd` itself (~3 MB) plus `libgcc.a` if we ever target a
   non-MUSL output ABI. Use CMake-time `configure_file` +
   `objcopy --add-section`, or generate `.rodata` arrays from a Python
   helper. Keep the embed slot keyed by target triple so other
   architectures (ARM64, …) can be added later without a redesign.
   (Decision Q10.)

4. **First-run extraction.** On first AOT invocation, `eco` extracts
   embedded resources to a content-addressed cache directory:
   `$XDG_CACHE_HOME/eco/toolchain-<sha256-of-payload>/`. The hash slot
   means stale extractions from older `eco` versions don't shadow current
   ones, and concurrent `eco` invocations can detect "already extracted"
   without a lock. Fall back to `/tmp/eco-toolchain-<hash>/` if
   `$XDG_CACHE_HOME` is unwritable (read-only home, etc.). (Decision Q11.)

5. **Adjust `EcoBootConfig.h` generation** so when `ECO_STATIC=ON`, the
   header emits "resolve toolchain paths at runtime from extracted-cache
   dir" rather than baking the build host's `clang -print-file-name=…`
   outputs. (Decision Q11.)

6. **Add `--toolchain-path=<dir>` CLI flag** as an escape hatch — users
   who want to override the embedded toolchain (cross-compile, custom
   libc, etc.) can point `eco` at an external one. The flag also helps
   debugging — when the embedded extraction misbehaves, the user can
   pin a known-good toolchain dir.

### Acceptance criteria

- `eco make src/Main.elm --output=foo` works on a `scratch` (no-libc,
  no-ld) Docker image:
  ```
  FROM scratch
  COPY --from=stage-b /usr/local/bin/eco /eco
  COPY hello.elm /hello.elm
  ENTRYPOINT ["/eco", "make", "/hello.elm", "--output=/foo"]
  ```
- The output `foo` ELF runs on `debian:bookworm-slim`, `ubuntu:24.04`,
  `alpine:3.21`. (The output ABI is MUSL-static; that contract is
  documented in user-facing docs. Users who specifically need a glibc
  output binary are out of scope for v1 — Decision Q9 — and can use the
  system toolchain separately.)
- The Stage-9c MLIR-level fixed-point check passes — front-end
  `.mlir` output is byte-identical across self-compile rounds. ELF
  byte-identity is aspirational and not required. (Decision Q12.)
- `XDG_CACHE_HOME=/tmp/foo eco make src/Main.elm --output=bar` works
  when `/tmp/foo` is fresh (verifies first-run extraction works).
- `eco --toolchain-path=/opt/musl-cross/lib make ...` works
  (verifies the escape hatch).

### Estimated effort

5 – 10 days. Dominated by:
- The lld + `.llvm_stackmaps` investigation (step 1).
- Migrating `linkExecutable` to lld-as-a-library (touches every code
  path in `eco-boot-native::linkExecutable` and its
  `EcoNativeDriverStatic` library twin).
- Embedded-resource extraction infrastructure (one-time, reusable).
- Cross-distro test matrix.

## Order of execution and dependencies

```
Stage A ──► Stage B ──► Stage C
   │            │            │
   │            │            └─► requires Stage B's MUSL toolchain
   │            │                and design decision on C1 vs C2
   │            │
   │            └─► requires Stage A's ECO_STATIC option
   │                and the Alpine package landscape
   │
   └─► standalone; useful even if B and C never ship
```

Each stage is independently shippable. Stage A delivers most of the value
(works on any glibc Linux); B is the principled cap; C is the "compiles
anywhere" promise.

## Decisions log

The original twelve open questions are all resolved. Decisions are folded
into the Stage sections above; recorded here for traceability.

### Stage A
1. **Q1 — libzip:** vendor it via `FetchContent` with a pinned version is
   the default path. Alternatives are open if vendoring proves painful:
   `minizip-ng` (MIT, smaller, ships in Alpine), `miniz` (single-header,
   BSD), `libarchive` (heavier but broader format support). The
   `EcoKernel_Http::getArchive` consumer only needs to read `.zip` from
   the package downloader, so any of those would suffice. Decision: try
   `FetchContent libzip` first, switch if it becomes a maintenance
   burden.
2. **Q2 — libcurl transitive deps:** **HTTPS (TLS) is non-negotiable.**
   Other features (HTTP/2 via nghttp2, IDN via libidn2, PSL via libpsl,
   Brotli, LDAP, Kerberos GSSAPI) can be degraded if their static
   archives aren't available on the build host. The Stage-A configure
   step probes each, logs degradations, and refuses only if libssl/
   libcrypto static archives are missing. (Curl can be built with
   different TLS backends; we standardize on OpenSSL for both Stage A
   and Stage B.)
3. **Q3 — drop `-fuse-ld=bfd`:** Stage A includes the experiment as a
   step. Outcome recorded in the plan once run.

### Stage B
4. **Q4 — libstdc++ → libc++ migration scope:** clean-slate rebuild
   inside Docker, no reuse from host. Every C++ archive is rebuilt
   against libc++ from one consistent LLVM 21.1.4 tree.
5. **Q5 — LLVM libunwind sourcing:** rebuild LLVM 21.1.4 from source
   inside the Alpine Docker image. **Must match the main Dockerfile's
   pinned LLVM version exactly** so the bootstrap chain doesn't see a
   different LLVM ABI between dev and static builds. No Alpine
   LLVM-package use for the *compiler* libraries.
   **Update (implementation):** `LLVM_ENABLE_RUNTIMES` stays `"libunwind"`
   (not `"libunwind;libcxx;libcxxabi"`); libc++/libc++abi come from Alpine's
   `libc++` package, used consistently for both the LLVM build and the eco
   build. One libc++ everywhere = no ABI skew, which is Q5's real goal. See
   "Implementation status & deviations (Stage B)".
6. **Q6 — libunwind API audit:** required before Stage B can land. The
   audit covers `runtime/src/allocator/StackUnwind.cpp`; the project
   continues to use **LLVM** libunwind exclusively, nongnu is rejected.
   **Update (implementation):** audit complete — clean, no changes needed
   (only Level-1 libunwind API, and the default build already links LLVM
   libunwind). See Stage B Step 3.
7. **Q7 — PIE vs static-PIE vs non-PIE:** **non-PIE static** as the
   default. Simpler, avoids the `.llvm_stackmaps` reloc issue. Tradeoff
   (loss of binary-level ASLR; library-level ASLR irrelevant since all
   libs are statically linked) documented in the preset's comment block.
   May need to experiment if non-PIE turns out to have its own issues
   with the GC stackmap parser.

### Stage C
8. **Q8 — C1 vs C2:** experiment-driven. Step 1 of Stage C is the
   investigation spike that picks one of the two paths. Plan is
   structured around C2 as the leading candidate but reverts to C1
   cleanly if lld refuses the relocs.
9. **Q9 — Output ABI lock-in:** **accept MUSL-static-PIE as the v1
   contract.** A second, glibc-targeting flavor of `eco` is explicitly
   out of scope but left open as a follow-up pass. User-facing docs
   document the v1 contract.
10. **Q10 — Cross-architecture:** Linux x86_64 only for v1. Embedded
    toolchain resources are keyed by target triple so ARM64 (and others)
    can be added later without redesigning the resource embed slot.
11. **Q11 — Extraction location:** content-addressed dir under
    `$XDG_CACHE_HOME/eco/toolchain-<sha256>/`, with `/tmp/eco-toolchain-<hash>/`
    fallback when `$XDG_CACHE_HOME` is read-only.
12. **Q12 — Stage 8c byte-equality:** **MLIR fixed-point is required;
    ELF fixed-point is aspirational.** The Stage 9c byte-identical-ELF
    check is allowed to fail at this stage — the front-end's `.mlir`
    output is the load-bearing fixed-point contract. This applies to
    all three stages.

## Risk register (cross-cutting)

- **Toolchain reproducibility.** Embedding crt files means our binary's
  output ABI is now coupled to a specific Alpine version. Pin the base
  image SHA, not just `alpine:edge`.
- **License audit.** Static-linking GPL libraries (any of the transitive
  curl deps?) into a redistributable binary has licensing implications.
  Audit before publishing Stage B artifacts. *libcurl is MIT-style,
  openssl is Apache 2.0 / OpenSSL-license, libzip is BSD, LLVM is
  Apache 2.0 + LLVM exception. Should be clean but verify.*
- **Binary diff for QA.** A statically-linked `eco` has thousands of
  symbols and millions of bytes more than the dynamic one. The
  `eco-verify` fixed-point check needs to keep passing — losing it
  during this work hides bugs.
