# Release snagging — first release prep

## Goal

Tidy the build, the user-facing surface, and the runtime cost profile of `eco`
ahead of the first tagged release. Five themes — each independently shippable
in the suggested order:

1. Flip `ECO_KERNEL_DEBUG` default OFF.
2. Slim and rename the CMake preset set.
3. Single-archive runtime libs, with build-type-driven flag gating: dev
   archives have asserts / GC-stats / debug syms / kernel-debug stderr on;
   release archives have all of that off.
4. Convert `ENABLE_GC_STATS` from a hardcoded `#define` into a single
   compile-time `ECO_GC_STATS` CMake option. Off in Release, on in Debug.
5. Wire a build-time version string. Baseline lives in `version.txt`
   (initially `0.1.0`). Default user-facing version is
   `<baseline>-dev-<git-describe>`; explicit `-DECO_VERSION_OVERRIDE=<x>`
   sets a fixed version (for tagged releases). Bump the artifact-format /
   cache directory key from `1.0.0` to `0.1.0`.

These are the explicit deliverables. Drive-by fixes (Readme tables, version
references in error text) ride along with the items they touch.

---

## Step-by-step plan

### Step 1 — `ECO_KERNEL_DEBUG` default OFF

Edit `CMakeLists.txt:97` to set the option default OFF. Update the new `dev`
preset (Step 2) to set `ECO_KERNEL_DEBUG=ON`; the `build` and `release`
presets inherit the default OFF.

Verification: `cmake --build build --target eco-quick` link is unaffected
because the macro flips a kernel `.cpp` recompile but `eco-quick` already
re-emits the affected static archives. Run the example compilation
(`compiler/examples/Hello.elm`) and check stderr is quiet.

### Step 2 — CMake preset cleanup

Replace the current 6 configure presets + 4 build presets with 3 + 3:

| Old name | New name | Binary dir | Build type | Notes |
|---|---|---|---|---|
| `ninja-clang-lld-linux-debug` | `dev` | `debug/` | `Debug` | Asserts on, `ECO_GC_STATS=ON`, `ECO_GC_DEBUG=ON`, `ECO_KERNEL_DEBUG=ON`. Inner-dev loop. |
| `ninja-clang-lld-linux` | `build` | `build/` | `RelWithDebInfo` | Bootstrap target's home. `-O2 -g -UNDEBUG`, `ECO_GC_STATS=ON` (default-on for non-Release), `ECO_KERNEL_DEBUG=OFF`. |
| `ninja-clang-lld-linux-musl` | `release` | `build-static/` | `Release` | Static musl. `-O2`, no `-g`, `-DNDEBUG`, no `-UNDEBUG`, `ECO_GC_STATS=OFF`, `ECO_KERNEL_DEBUG=OFF`. Strip post-link. |

Delete: `ninja-clang-lld-linux-ccache`, `ninja-clang-lld-linux-debug-ccache`,
`ninja-clang-lld-linux-profile`. Expose the dropped knobs as:

- `ECO_USE_CCACHE` — option, default OFF. When ON, sets
  `CMAKE_C_COMPILER_LAUNCHER=ccache` etc.
- `ECO_FRAME_POINTERS` — option, default OFF. Adds
  `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` when ON.

Also touched: `Readme.md` build-targets section (add `eco`, `eco-bootstrap`,
`eco-verify`, `eco-quick` entries while we're there), any scripts that
reference the removed preset names, the bootstrap fix-loop guides under
`guides/`.

### Step 3 — Build-type-driven flag gating in a single archive set

No `_Release` flavour split. Instead, the existing `EcoRuntimeStatic`,
`EcoEntryStatic`, and per-module `ElmKernel_*` / `EcoKernel_*` archives are
built **once per build dir** with flags driven by build type / options:

| Compile flag | Dev (`Debug`) | Build (`RelWithDebInfo`) | Release (`Release`) |
|---|---|---|---|
| `-UNDEBUG` (asserts on) | yes | yes | **no** |
| `-DNDEBUG` (asserts off) | no | no | yes |
| `-g` (debug syms) | yes | yes | no |
| `-O0` / `-O2` | `-O0` | `-O2` | `-O2` |
| `ECO_GC_DEBUG` | ON | OFF | OFF |
| `ECO_GC_STATS` (Step 4) | ON | ON | OFF |
| `ECO_KERNEL_DEBUG` | ON | OFF | OFF |
| Strip linker | no | no | yes (`-Wl,--strip-all` post-link, or split debuginfo) |

The current `target_compile_options(... PRIVATE -UNDEBUG)` blocks
(`runtime/src/codegen/CMakeLists.txt:601,641`,
`eco-kernel-cpp/CMakeLists.txt:235`, `elm-kernel-cpp/CMakeLists.txt:327`,
top-level `CMakeLists.txt:183` for `ecor`) become conditional on a single
top-level CMake option `ECO_ASSERTS_ON`, default ON for any build type
other than Release. Adding `-DNDEBUG` to the release link line drops the
asserts.

Implication: the dev `build/` preset still produces a fast-enough `eco` for
the bootstrap target, but `release` (musl) drops asserts everywhere — that
**is** the meaningful runtime-cost reduction for shipped binaries.

Implication for AOT outputs: an AOT binary produced by `eco make` under the
`build` preset will have asserts on and stats compiled in. Under the
`release` preset, the same `eco make` produces a slim AOT. This is the
behaviour we want — one preset, one consistent flavour.

Verification: byte-size of `eco-2` produced from `build/` vs `build-static/`.
Bootstrap still green under both presets.

### Step 4 — Single-switch GC stats

Move `#define ENABLE_GC_STATS 1` (`runtime/src/allocator/GCStats.hpp:27`)
into a CMake option `ECO_GC_STATS`. Defaults driven by `CMAKE_BUILD_TYPE`:

- `Release` → `OFF`.
- Anything else (`Debug`, `RelWithDebInfo`) → `ON`.

The header reads the macro the build system defines and gates everything as
today.

`runtime/src/codegen/eco_entry.cpp:193-244` already wraps the
`printGCStatsOnce` infrastructure in `#if ENABLE_GC_STATS`. With
`ECO_GC_STATS=OFF`, the entire printer + atexit + signal-handler code
compiles out. With `ON`, the existing behaviour (print at exit / signal)
applies.

No CLI flag at `eco make` time, no env-var gate, no `--gc-stats` to thread
through the Elm parser. The user's preset choice decides.

Verification: AOT-built sample from the `release` preset exits without
printing the GC banner. Sample from `build/` still prints it. Bootstrap
unaffected.

### Step 5 — Versioning + cache directory key bump

Three sub-steps:

**5a. Add `version.txt` at repo root.**

Single-line file at `/work/version.txt` containing `0.1.0`. This is the
baseline marketing version, the single source of truth. Bumping the
marketing version = editing this file in a commit. No other file in the
repo hardcodes the marketing version.

`.gitignore` is not relevant — `version.txt` is tracked.

**5b. Split `V.compiler` into two values and inject build-time version.**

In Elm:

- `V.artifactFormat : Version` — drives `eco-stuff/<ver>/` (Stuff.elm),
  `Stuff.compilerVersion`, anywhere a cache-layout key is needed. Bumped to
  `Version 0 1 0` (was `1 0 0`).
- `Version_Build.userFacing : String` — drives the welcome banner
  (`Terminal/Main.elm:73`), `eco --version`
  (`Terminal/Terminal.elm:63-65` — exists already, just needs repointing),
  the HTTP `User-Agent` (`Builder/Http.elm:186`), `Exit` error text, REPL
  banner. Generated at CMake configure time.

`V.compiler` is removed (or kept as an alias for `V.artifactFormat` during
a transition window).

CMake configure step:

```cmake
# Baseline from the repo-tracked source of truth.
file(READ "${CMAKE_SOURCE_DIR}/version.txt" ECO_VERSION_BASE)
string(STRIP "${ECO_VERSION_BASE}" ECO_VERSION_BASE)

# Override wins. Otherwise: <base>-dev-<git-describe>.
if(ECO_VERSION_OVERRIDE)
    set(ECO_VERSION_USER_FACING "${ECO_VERSION_OVERRIDE}")
else()
    execute_process(COMMAND git -C ${CMAKE_SOURCE_DIR}
                    describe --tags --dirty --always
                    OUTPUT_VARIABLE ECO_GIT_DESCRIBE
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_QUIET)
    if(ECO_GIT_DESCRIBE)
        set(ECO_VERSION_USER_FACING "${ECO_VERSION_BASE}-dev-${ECO_GIT_DESCRIBE}")
    else()
        # Source tarball with no git history — fall back to the bare base.
        set(ECO_VERSION_USER_FACING "${ECO_VERSION_BASE}")
    endif()
endif()

configure_file(
    "${COMPILER_DIR}/cmake/Version_Build.elm.in"
    "${BUILD_KERNEL_DIR}/src/Compiler/Elm/Version_Build.elm"
    @ONLY)
```

Template `compiler/cmake/Version_Build.elm.in`:

```elm
module Compiler.Elm.Version_Build exposing (userFacing)


{-| Build-time-injected user-facing version string. Generated by CMake from
version.txt + git describe (or the ECO_VERSION_OVERRIDE override).
-}
userFacing : String
userFacing =
    "@ECO_VERSION_USER_FACING@"
```

Symlink `BUILD_KERNEL_DIR/src/Compiler/Elm/Version_Build.elm` into the
shadow source tree the same way other build-tree shadow sources land
(see the existing `file(CREATE_LINK ...)` pattern at
`compiler/CMakeLists.txt:119`). Stage 1's stock-Elm compile, Stage 5's
MLIR emit, and the elm-test-rs runner all just see it as a sibling
module of `Compiler.Elm.Version`.

Add the generated file to `.gitignore` so it doesn't accidentally get
committed.

Rewire callers:

- `Compiler/Elm/Version.elm:155-168` `compiler` constant → returns
  `Version 0 1 0`. (artifact format)
- `Terminal/Main.elm:73` welcome banner → use
  `Version_Build.userFacing`.
- `Terminal/Terminal.elm:64` `--version` printout →
  `Version_Build.userFacing`.
- `Builder/Http.elm:186` User-Agent → `"elm/" ++ Version_Build.userFacing`.
- `Builder/Stuff.elm:126` `compilerVersion` → keep on `V.compiler`
  (artifact format).
- `Terminal/Repl.elm:131` REPL banner → `Version_Build.userFacing`.
- `Builder/Reporting/Exit.elm:1579,1598` red version stamps in error
  reports → `Version_Build.userFacing`.

**5c. Cache directory key bump 1.0.0 → 0.1.0.**

Bumping `V.artifactFormat` rotates every `eco-stuff/<ver>/` cache.
Bootstrap will rebuild every cached object on first run after the bump —
expected. Old `eco-stuff/1.0.0/` caches stay on disk; per Q12 we just
mention them in release notes and let users clean up if they want.

Any infrastructure that references the literal `1.0.0` cache path (build
scripts, docker images, CI scripts) updates too.

Verification:

- `eco --version` on a fresh dev build prints `0.1.0-dev-<git-describe>`.
- Re-configure with `-DECO_VERSION_OVERRIDE=0.1.0` and confirm `eco --version`
  prints `0.1.0` exactly.
- `eco --help` welcome banner matches.
- `eco-stuff/0.1.0/` is created on first build of an example.
- HTTP requests carry `User-Agent: elm/0.1.0-dev-<hash>` (or the override).

---

## Suggested execution order

1. Step 1 (small, isolated; one rebuild)
2. Step 2 (no runtime impact; updates docs)
3. Step 5 (visible user-facing change; tests the configure-file machinery)
4. Step 3 (build-type-driven flag gating)
5. Step 4 (smallest change — flip one `#define` to a CMake option)

Each step is a separate PR.

---

## Open questions / assumptions

### Strategic / scoping

**Q1.** Locking artifact-format version to marketing version — **assumed
locked at `0.1.0` for this release.** Will split later if/when on-disk
layout changes independently of the marketing version.

**Q11 (release notes timing).** Notes accompany the PRs, not this plan.

**Q12 (old `eco-stuff/1.0.0/` caches).** Left in place; mention in release
notes.

### Mechanical / build-system

**Q7.** Does symlinking the generated `Version_Build.elm` into the
build-tree shadow work for Stages 1 and 5 alike? **Assumed yes** — same
pattern as the existing `BUILD_KERNEL_DIR/src` symlink.

**Q13.** Drive-by Readme updates (missing rows for `eco`, `eco-bootstrap`,
`eco-verify`, `eco-quick` in the bootstrap-chain table) — **fold into
Step 2**.

### Smaller items remaining

**Q14 (new).** Should the `release` preset's `-Wl,--strip-all` apply to the
ELF binary (`eco` and AOT outputs) at link time, or do we want split
debuginfo (`.debug` sidecar) for crash investigation post-release? The
plan currently assumes hard-strip. **Default: hard-strip; revisit if we
ever need to investigate a release crash.**

**Q15 (new).** Should `eco --version` print just the version string
(`0.1.0-dev-abc1234\n`), or include a longer string with build info
(version + commit + build date + compiler flags)? Long form is more useful
for bug reports; bare is simpler. **Default: bare for now; can grow into
long-form in a follow-up.**

---

## Out of scope (parked for separate work)

- `Map.!` Stage 3/7 flake — **fixed** (Task ordering bug).
- `StringRope` empty-string `==` — **fixed** in current runtime.
- HTTP 411 / gzip-decompression — **fixed**.
- `Tuple-slot boxing bug` — has its own open plan; not part of release prep.
- Codegen / monomorphization refactors — covered by other plans.
