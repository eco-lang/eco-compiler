# Plan: Self-contained macOS bundle

## Goal

A macOS user downloads the Darwin tarball, extracts it anywhere, and runs
`bin/eco make` with no Homebrew and no paths or environment variables to set.
Everything `eco` needs at run time is either part of macOS itself
(`libSystem`, `libc++`, `libcurl`, `libz`), ships in the bundle and is found
relative to `bin/eco`, or is the Xcode Command Line Tools, which provide the
linker and SDK for `eco make`.

Requiring the Command Line Tools for the final link is what most LLVM-based
compilers do on macOS (Rust, LDC, Crystal, Swift). Removing that last
prerequisite (the Zig approach) is the follow-up at the end of this plan, to
start once steps 1 and 2 ship.

This plan covers two steps:

1. Find Apple's toolchain when linking instead of baking its path in; set a
   minimum macOS version; link OpenSSL statically into `eco`; correct
   `docs/building-macos.md`.
2. Build LLVM/MLIR 21.1.8 ourselves (static, macOS 15.0 floor) in a
   `mac-llvm-build` workflow; link it statically into `eco`; drop brew's
   `llvm@21` from the build; prove the bundle with a CI smoke test on a
   runner with only the Command Line Tools and no brew LLVM or OpenSSL.

## Decisions

- **Apple Silicon (arm64) only.** No Intel, no universal binaries.
- **Minimum macOS 15.0.** Apple no longer supports anything older, and every
  Apple Silicon Mac can run macOS 15, so with arm64-only the floor excludes
  no hardware. It also:
  - matches the `macos-15` CI runner, so the floor is *tested* (the smoke
    test runs on it), not just declared — GitHub has no older arm64 runner
    to test a lower floor on;
  - matches Homebrew's bottles on that runner (built for 15.0), so brew's
    OpenSSL static libraries can stay;
  - avoids libc++ availability limits. A lower floor would hit at least
    floating-point `std::to_chars` (`runtime/src/allocator/StringOps.hpp:1183`,
    `runtime/src/allocator/RuntimeExports.cpp:126`), which Apple's libc++
    only provides from 13.3.

  The floor applies to `eco` and to the programs it builds (both link the
  runtime). It is one setting (`ECO_MACOS_MIN`), so it can move later.
- **Ad-hoc signing only.** No Apple Developer account yet, so no Developer ID
  signing or notarization. See *Gatekeeper* under Out of scope.
- **Pinned LLVM 21.1.8 built from source**, as on Windows
  (`experiments/win-llvm-build/build.ps1`) and Linux
  (`docker/llvm-alpine.Dockerfile`), and as Zig, Rust and LDC do. Linking
  brew's static archives was considered and rejected: brew builds LLVM to use
  its shared library, so its MLIR CMake targets pull in `libLLVM.dylib` (the
  two-copies problem 070705b4 worked around), and the archives may need
  further brew static libraries.
- **OpenSSL from brew, linked statically.** Brew's `openssl@3` ships
  `libssl.a`/`libcrypto.a` built for 15.0; no source build needed while the
  floor gate (step 1) passes.

## Where things stand

| Area | Today | Problem |
|---|---|---|
| LLVM/MLIR in `eco` | Brew's aggregate `libLLVM.dylib` / `libMLIR.dylib` (`runtime/src/codegen/CMakeLists.txt:69-91`, `:914-920`; `compiler/CMakeLists.txt:840-850`). Introduced in 070705b4 to avoid two copies of LLVM state (brew's static MLIR archives' CMake targets drag in the dylib). | Bundle does not ship them; `eco` cannot start without `brew install llvm@21`. `docs/building-macos.md` says the bundle is self-contained. |
| AOT link of user programs | `linkExecutableDarwin` (`runtime/src/codegen/EcoNativeDriver.cpp:517-645`) runs `eco::config::darwinClang` with `-isysroot darwinSdkRoot`, both baked at configure time from `xcrun` (`runtime/src/codegen/CMakeLists.txt:1238-1256`, `:1616-1622`). | Paths point into the build host's Xcode; a user's Mac usually has different paths. The comment at `CMakeLists.txt:1616-1618` claims an `xcrun` fallback that does not exist. |
| Minimum macOS | Nothing sets `CMAKE_OSX_DEPLOYMENT_TARGET`; CI runs on `macos-15`. AOT objects use `sys::getDefaultTargetTriple()` (`runtime/src/codegen/EcoBackend.cpp:895`). Brew bottles (LLVM, OpenSSL) are built for the runner's macOS. | The floor is whatever the runner image and brew bottles happen to be (15 today) and would rise silently when the runner image changes. |
| OpenSSL | Brew `openssl@3` (TLS in `system-kernel-cpp/src/eco-system/Tls/`, SHA1 in `Http.cpp`, libzip). User programs link the static `libssl.a`/`libcrypto.a` shipped in the bundle (`minos 15.0`). But `eco` itself links brew's **dylibs**: `find_package(OpenSSL)` only prefers static libs under `ECO_STATIC OR WIN32` (`CMakeLists.txt:262-268`), so on Apple `OpenSSL::SSL` is `libssl.3.dylib`. | `eco` needs `brew install openssl@3` at run time. Seen in the v0.2.0 bundle from master run 38137345651 (`llvm-otool -L bin/eco`: `/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib`, `libcrypto.3.dylib`, next to `libLLVM.dylib` / `libMLIR.dylib`). |
| Bundle smoke test | `mac-aot.yml` runs `bin/eco --help` from the extracted tarball on the build runner. | Brew LLVM, brew OpenSSL and Xcode are present, so none of the problems above is caught; no `eco make` is run. |

## Step 1 — Link-time toolchain discovery, macOS floor, static OpenSSL, docs

Small, ships on its own, and leaves the bundle depending on the Command Line
Tools plus brew LLVM (until step 2).

1. **Find the toolchain when linking.** In `linkExecutableDarwin`, resolve
   once per process:
   - clang: `xcrun -f clang`; error if that fails.
   - SDK: `$SDKROOT` if set, else `xcrun --show-sdk-path`.
   - On failure, print: Xcode Command Line Tools are required, run
     `xcode-select --install`.

   Run `xcrun` through `llvm::sys::ExecuteAndWait` with stdout redirected to
   a temp file. Drop `darwinClang` / `darwinSdkRoot` from `EcoBootConfig.h`
   and the misleading comment with them.
2. **macOS floor.** Default `CMAKE_OSX_DEPLOYMENT_TARGET` to `15.0` as a
   cache entry before `project()` in the top-level `CMakeLists.txt` (one
   place for every preset; FetchContent'd libzip inherits it), and derive
   `ECO_MACOS_MIN` from it.
   - Bake `ECO_MACOS_MIN` into `EcoBootConfig.h` (`darwinMacosMin`).
   - `createEcoTargetMachine` on `__APPLE__`: use `arm64-apple-macosx<min>`
     instead of the host default triple, so AOT objects carry the floor in
     `LC_BUILD_VERSION`.
   - `linkExecutableDarwin`: pass `-mmacosx-version-min=<min>`.
   - Add a mac-aot check that fails if any Mach-O we ship or link (`eco`,
     a produced `hello`, the brew `libssl.a`/`libcrypto.a` members) has
     `minos` above `ECO_MACOS_MIN`, and fail on "built for newer macOS
     version" linker warnings. This catches a runner-image or bottle change.
3. **Static OpenSSL in `eco`.** Set `OPENSSL_USE_STATIC_LIBS TRUE` on Apple
   too (top-level `CMakeLists.txt:262`, before any subdirectory's
   `find_package(OpenSSL)`), and point `OPENSSL_ROOT_DIR` at
   `/opt/homebrew/opt/openssl@3`.
4. **Docs.** `docs/building-macos.md`: state that the bundle currently needs
   the Command Line Tools and `brew install llvm@21`, and the 15.0 floor.
   Remove "self-contained" until step 2 makes it true.

**Gate:** mac-aot green. `otool -L bin/eco` lists no `openssl` entry. On the
runner, `vtool -show-build` on a produced `hello` reports `minos 15.0`; the
floor check above passes.

## Step 2 — `mac-llvm-build`: static LLVM/MLIR, clean-runner smoke test

Replaces brew's LLVM with our own static build targeted at macOS 15.0, so
`eco` loads nothing from `/opt/homebrew`. OpenSSL stays on brew's static
libraries (built for 15.0 on the `macos-15` runner, checked by step 1's
floor gate); building it ourselves is only needed if that gate ever trips.

1. **Build script** `experiments/mac-llvm-build/build.sh` (runnable on a dev
   Mac too), producing one install prefix (the "mac deps tree"):
   - LLVM 21.1.8 source tarball, configured with AppleClang:
     `-G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=mlir
     -DLLVM_TARGETS_TO_BUILD=AArch64 -DCMAKE_OSX_ARCHITECTURES=arm64
     -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DLLVM_BUILD_LLVM_DYLIB=OFF
     -DLLVM_LINK_LLVM_DYLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF
     -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_Z3_SOLVER=OFF
     -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF
     -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_ASSERTIONS=OFF
     -DLLVM_PARALLEL_LINK_JOBS=1` plus the test/docs/examples/benchmarks
     `OFF` flags `build.ps1` uses. `LLVM_PARALLEL_LINK_JOBS=1` because the
     `macos-15` runner has 3 vCPUs / 7 GB.
   - Hard-fail checks at the end: `otool -L` on `bin/mlir-opt` lists only
     `/usr/lib/*`; `vtool -show-build` on `bin/mlir-opt` and a sample of `.a`
     members reports `minos` ≤ 15.0.
2. **Workflow** `.github/workflows/mac-llvm-build.yml`, mirroring
   `win-llvm-build.yml`: `macos-15`, `timeout-minutes: 330`, ccache for
   rebuilds, Actions cache keyed
   `mac-llvm-mlir-21.1.8-arm64-macos15.0-release-v1`, weekly keep-warm cron,
   `workflow_dispatch`. Warm the cache **on master** (branch caches are
   invisible to master). Expected size ~0.5–0.8 GB against ~7.5 GB already
   used of the 10 GB Actions budget. If eviction becomes a problem, move the
   tree to a GitHub release asset, which does not count against the cache.
3. **CMake.**
   - `mac-build` preset: `CMAKE_PREFIX_PATH=$env{ECO_MAC_DEPS_DIR}` (as
     `win-build` does with `$LLVM_DIR`), `CMAKE_OSX_ARCHITECTURES=arm64`.
   - `runtime/src/codegen/CMakeLists.txt`: delete the Apple aggregate-dylib
     branch (`ECO_MLIR_LIBS` / `ECO_LLVM_LIBS`, `:69-91`), the
     `MLIRExecutionEngine` workaround for `libMLIR.dylib` (`:548-592`) and the
     Apple `ECO_AOT_MLIR_LLVM_LIBS` branch (`:914-920`). Use the static
     component lists on Apple too, with the backend components chosen by host
     arch (AArch64 on Darwin, X86 elsewhere).
   - `compiler/CMakeLists.txt:840-850`: update the comment about brew dylibs.
4. **mac-aot.yml:** drop `llvm@21` from `brew install` (keep `openssl@3`);
   restore the deps tree with `fail-on-cache-miss` (same contract as the
   Windows and Linux LLVM caches); set `ECO_MAC_DEPS_DIR`.
5. **Clean-runner smoke test.** New job `bundle-smoke` in `mac-aot.yml`,
   `needs: aot`, on a fresh `macos-15` runner (the floor itself), downloading
   the tarball artifact. It reproduces a typical user's Mac: Command Line
   Tools, no Xcode app, no brew LLVM or OpenSSL.
   - Move `/Applications/Xcode*.app`, `/opt/homebrew/opt/llvm*` and
     `/opt/homebrew/opt/openssl*` aside with `sudo mv`; select the Command
     Line Tools with `sudo xcode-select -s /Library/Developer/CommandLineTools`;
     assert `xcrun --show-sdk-path` points under `CommandLineTools`.
   - Extract into a directory whose path contains a space; run under
     `env -i PATH=/usr/bin:/bin HOME=<fresh dir>`.
   - `bin/eco --help`; `bin/eco make` on `compiler/examples/src/Hello.elm`
     (as the Linux smoke in `docker/static-build.Dockerfile:298-314` does);
     run `./hello` and fail on SIGSEGV/SIGABRT. Also build and run
     `Quotes.elm` (uses `elm/http`). With a clean `HOME`, `eco make`
     downloads and unpacks the packages itself, which exercises eco's own
     curl, libzip/zlib and OpenSSL code.
   - Checks: `otool -L` on `bin/eco` and on the outputs shows only
     `/usr/lib/*` and `/System/Library/*`; `vtool -show-build` shows
     `minos 15.0`; `codesign -dv` shows `adhoc`.
   - `eco make` fetches packages over the network; the runner has network,
     and offline use is not a goal here.
6. **Docs.**
   - `docs/building-macos.md`: prerequisites switch from brew `llvm@21` to
     the deps tree (run `build.sh`, roughly an hour on an M-series Mac); the
     bundle section says the only user prerequisite is the Command Line Tools
     (`xcode-select --install`).
   - `docs/getting-started.md`: the user install path,
     `curl -L <url> | tar xz` (a `curl` download is not quarantined, see
     Gatekeeper below).

**Gates** (in mac-aot):
- The full suite stays green: elm-tests, `test` (JIT E2E — the JIT now uses
  static LLVM; the RuntimeDyld unwind fix in `runtime/src/jit/EcoJIT.cpp`
  must still hold), the Stage 6-9 bootstrap and the AOT E2E tests.
- `otool -L build/compiler/build-kernel/bin/eco`: only `/usr/lib/*` and
  `/System/Library/*`. Fail on any `/opt/homebrew` or `@rpath` entry.
- Step 1's floor check passes with `eco` now carrying static LLVM.
- `bundle-smoke` green.

## Risks

- **Runner image changes.** When GitHub retires `macos-15`, brew bottles on
  the new image target the newer macOS, so brew's OpenSSL would raise the
  floor. The step 1 gate fails loudly; then either raise `ECO_MACOS_MIN` or
  build OpenSSL into the deps tree (`no-shared -mmacosx-version-min=15.0`).
- **LLVM build on a 3-vCPU / 7 GB runner.** Expected 2-3 h cold. If it OOMs,
  lower parallelism further; the cap is 6 h.
- **Static LLVM vs the JIT.** The JIT has only run against brew's dylibs on
  macOS. The JIT E2E suite must pass on the static build before step 2 lands.
- **Actions cache budget.** One more LLVM tree; see step 2.2.

## Follow-up (after steps 1 and 2 ship): no Command Line Tools needed

Remove the last prerequisite by linking user programs with a bundled
`ld64.lld` against bundled `.tbd` stubs, as Zig does with its own linker.
`eco` only links (`.o` + `.a`); it never compiles C, so it needs no SDK
headers. What a link needs from the SDK is the `.tbd` stub for each system
library: `libSystem`, `libc++`, `libcurl`, `libz`.

1. **Build lld.** Add `lld` to `LLVM_ENABLE_PROJECTS` in `mac-llvm-build`
   and bump the cache key. Brew's `lld` links brew's `libLLVM.dylib`, so it
   is not shippable.
2. **Ship the linker** as a separate executable,
   `lib/eco-runtime/ld64.lld` (the real `lld` binary, stripped), mirroring
   Linux Stage C's bundled static `ld.lld` (`eco::config::bundledLinker`,
   resolved by `resolveFile()`). Its `buildPath` is the deps-tree copy, so
   build-time links (bootstrap, AOT E2E) and the installed bundle use the
   same binary. Linking lld into `eco` in-process would save bundle size but
   adds re-entrancy and error-handling work; it stays a later option.
3. **Generate minimal stubs** with a new script
   (`runtime/scripts/gen-darwin-stubs.py`), run as a CMake custom command
   after all user-link archives are built. It needs the SDK, so building
   `eco` still requires the Command Line Tools; using it does not.
   - Symbols needed: the undefined symbols (`nm -u -j`) of every archive on
     the user link line (project, kernel, eco/system archives, libzip,
     libssl, libcrypto), plus a curated list of symbols LLVM codegen can emit
     on its own (`memcpy`/`memmove`/`memset`/`bzero`, the libm functions
     behind LLVM math intrinsics, `___stack_chk_*`, `___chkstk_darwin`, the
     C++ personality/unwind symbols the Eco codegen uses).
   - Resolve each symbol against the SDK `.tbd` files. Anything exported from
     `usr/lib/system/*` is attributed to the umbrella
     `/usr/lib/libSystem.B.dylib` (this is what ld64 records for re-exported
     symbols anyway). Same for `libc++abi` → `/usr/lib/libc++.1.dylib`.
   - Emit TBD v4 files (`targets: [ arm64-macos ]`, the SDK's install name,
     current and compatibility versions) containing only those symbols, under
     `darwin-sdk/usr/lib/` so `-syslibroot` works unchanged.
   - Fail the build on any needed symbol that no stub or archive provides.
     This is also where compiler-rt needs show up (e.g.
     `___isPlatformVersionAtLeast`). If any appear, add compiler-rt builtins
     to `mac-llvm-build` and ship `libclang_rt.osx.a`.
   - Record the SDK version the stubs came from in `EcoBootConfig.h` for
     `-platform_version`.
   - **Licensing:** the stubs hold only symbol names, install names and
     version numbers needed to link, generated from what our code uses, not
     copies of the SDK files. Zig ships darwin stubs the same way. Needs the
     user's sign-off before the first release that includes them.
4. **Rewrite `linkExecutableDarwin`** to run:
   `ld64.lld -arch arm64 -platform_version macos <min> <sdk-ver>
   -syslibroot <bundle>/lib/eco-runtime/darwin-sdk -o <out> <objs>
   -force_load libEcoEntryStatic.a … <archives> -lc++ -lcurl -lz -lSystem`
   (plus `libclang_rt.osx.a` if needed).
   - One Darwin link path: every AOT link (the bootstrap stages, the AOT E2E
     suite and the installed bundle) goes through `ld64.lld` + stubs, so no
     dev-only path hides bundle bugs. Delete the clang-driver path and step
     1's `xcrun` discovery for executables.
   - No `-dead_strip`, so `__LLVM_STACKMAPS` survives.
   - lld ad-hoc signs arm64 output by default; check with `codesign -dv`.
   - `eco-boot`'s relocatable `ld -r` join of partition objects
     (`runtime/src/codegen/eco-boot.cpp:851`, `:1098`) stays on the host
     linker: ld64.lld has no `-r`, and only the build-time `eco-boot-native`
     uses it. `EcoNativeDriver` (what the installed `eco` uses) has no `-r`
     path.
5. **Bundle contents** (`CMakeLists.txt` BundleDarwin block): add
   `lib/eco-runtime/ld64.lld` and `lib/eco-runtime/darwin-sdk/`.
6. **Smoke test:** `bundle-smoke` also moves
   `/Library/Developer/CommandLineTools` aside and asserts
   `xcrun --show-sdk-path` fails.
7. **Docs:** the bundle has no prerequisites; layout gains `ld64.lld` and
   `darwin-sdk/`.

**Gates:** mac-aot green with every bootstrap stage and AOT E2E test linked
by `ld64.lld` + stubs (the main lld coverage: GC stack walks through
lld-written `__unwind_info`, stackmaps found at run time); `bundle-smoke`
green without the Command Line Tools.

**Follow-up risks:**
- **lld Mach-O output vs the GC.** Stack walking depends on unwind info and
  the stackmap section. Earlier macOS unwind trouble was RuntimeDyld-specific
  (JIT), but the AOT E2E GC tests and the bootstrap must pass under lld.
- **Stub gaps.** A symbol emitted by codegen but missing from the curated
  list only fails for programs that hit it. Mitigation: all shipped archives'
  undefined symbols are covered mechanically; make `eco`'s link error name
  the missing symbol and say it is an eco bug; the AOT E2E suite runs through
  the stubs.
- **Bundle size.** Adds `ld64.lld` (tens of MB stripped).

## Out of scope

- **Gatekeeper.** A tarball downloaded by a browser is quarantined, and an
  ad-hoc-signed `eco` is then blocked until the user allows it in System
  Settings (or runs `xattr -d com.apple.quarantine`). `curl` downloads are
  not quarantined. A proper fix needs Developer ID signing + notarization
  (Apple Developer account) or a channel such as npm or Homebrew. Follow-up.
- Intel / universal binaries.
- npm and Homebrew distribution.
- `.dylib` / `.node` outputs on Darwin.
- Replacing OpenSSL with CommonCrypto / Network.framework.
- Windows and Linux changes.

## Process

- One branch, `ci/mac-self-contained` (CI builds `ci/**`), one step at a
  time; each step lands on master when its gates are green.
- Workflow changes in this plan: `mac-aot.yml` (steps 1-2) and the new
  `mac-llvm-build.yml` (step 2).
