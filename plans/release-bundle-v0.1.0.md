# Release bundle v0.1.0 — `.deb` + `.zip` + `.tar.gz` with kernel sources and examples

Follow-up to [`stage-c-bundle-runtime.md`](stage-c-bundle-runtime.md). Stage C
got us a self-contained `bin/eco` + `lib/eco-runtime/` tree packaged as
`.tar.gz` / `.zip`. This plan finishes the first user-facing release:

- Add the **`eco/kernel` Elm package sources** (from `eco-kernel-cpp/`) to
  the bundle so user code can `import Eco.Console` / `Eco.File` / etc.
- Add the **`examples/`** tree as starter projects.
- Add a third generator — **`.deb`** for `/usr/local` installs — that
  lays out the **same** file tree as the `.zip` / `.tar.gz`.
- Leave the existing `.zip` / `.tar.gz` relocatable (unpack anywhere).

The goal: `unzip eco-0.1.0-x86_64-linux-musl.zip -d /usr/local` produces
**byte-for-byte the same files** that `dpkg -i eco_0.1.0_amd64.deb` would
install. Users can pick the packaging that fits their workflow without
behavioural divergence.

**Non-goal: the bundled `eco` cannot rebuild itself.** Binaries `eco`
produces — including any binary built from the compiler's own Elm
source — lack the MLIR/LLVM back-end (`EcoNativeDriverStatic` only gets
`--whole-archive`'d into the special `eco` target by the CMake build).
Anyone wanting to bootstrap or rebuild the compiler from source clones
the git repo and follows the README. This release is for *using* `eco`,
not for hacking on it.

## Scope

**In scope (v0.1.0):**

- Ship the **single `eco` binary** as the entire user-facing compiler.
  Drop every other build artifact from the bundle (`eco-compiler*`,
  `eco-boot-native`, `ecoc`, `ecogen`, `ecor`, test binaries). Stage 9b
  proves the **front-end** self-hosts (`eco-2` is byte-identical to
  `eco-compiler-boot-2`), but `eco-2` lacks the back-end and is **not**
  an `eco`-equivalent — see the "Non-goal" note above and the
  Stage 9b finding in [`stage9-eco-single-binary.md`](stage9-eco-single-binary.md).
- Add `share/eco/kernel/eco-kernel-cpp/` carrying the `eco/kernel` Elm
  package (sources + cached `.dat` / `docs.json` artifacts).
- Add `share/eco/examples/` carrying every example program **as source
  only** — `elm.json` + `src/*.elm`; no pre-built ELFs.
- Add the `DEB` CPack generator, target prefix `/usr/local`.
- Keep the existing kernel-resolution UX: users invoke `eco make` with
  `--local-package eco/kernel=/usr/local/share/eco/kernel/eco-kernel-cpp`
  (or wherever they extracted the bundle). Auto-discovery via
  `<exe>/../share/eco/kernel/` is **out of scope** for this release —
  tracked as a follow-up below.
- Strip the bundled `eco` binary (CPack's `CPACK_STRIP_FILES ON` already
  does this for the archive generators; verify the DEB generator does the
  same).
- Linux x86_64 only; MUSL ABI; matches Stage B/C.
- Smoke test: extract bundle → build `share/eco/examples/hello` →
  `./hello` prints `Hello World!`.

**Out of scope (defer):**

- **Self-build / `--native-driver` flag.** No CLI mode that wholes-archives
  `EcoNativeDriverStatic` into a produced binary; no shipping of the
  MLIR/LLVM back-end archives needed for such a link. Users wanting to
  rebuild `eco` from source clone the git repo and follow the README's
  bootstrap instructions. Adding back-end-embedded user binaries would
  require shipping ~700 MB of MLIR/LLVM static archives, which we don't
  want to inflict on regular users. Discussion captured in the chat
  transcript leading to this plan.
- **Auto-discovery of `share/eco/kernel/`** by the `eco` binary
  (`<exe>/../share/eco/kernel/eco-kernel-cpp` fallback + `ECO_KERNEL_DIR`
  env-var override). v0.1.0 requires the explicit `--local-package` flag.
- Bundling **`compiler/src/`** Elm sources. Even with them, the bundled
  `eco` couldn't produce a back-end-embedded compiler (see the self-build
  bullet above), so shipping the sources without a self-build mode is of
  limited value. Git is the path.
- A separate **`eco-dbgsym` companion package** with the unstripped
  binary (Debian convention). v0.1.0 ships stripped only.
- **Upstreaming to Debian / Ubuntu** — this release targets `/usr/local`,
  so it deliberately doesn't comply with Debian's `/usr` policy for
  archive-managed packages. Future-problem.
- Glibc / ARM64 / macOS variants. MUSL Stage B only.
- GitHub Releases CI/CD wiring (manual upload from the Docker build).

## Layout

Single canonical tree, used identically by all three generators:

```
<prefix>/                                    # zip/tar.gz: archive root | deb: /usr/local
├─ bin/
│  └─ eco                                    Stage 9 unified compiler (static, stripped)
├─ lib/eco-runtime/                          (unchanged from Stage C)
│  ├─ ld.lld
│  ├─ crt/{crt1,crti,crtn,clang_rt.crtbegin-x86_64,clang_rt.crtend-x86_64}.o
│  ├─ libc.a libc++.a libc++abi.a libunwind.a libclang_rt.builtins-x86_64.a
│  ├─ libssl.a libcrypto.a libcurl.a libz.a libzip.a
│  └─ project/
│     ├─ libEcoEntryStatic.a, libEcoRuntimeStatic.a, libEcoNativeDriverStatic.a
│     ├─ libElmKernel_*.a   (24 files)
│     └─ libEcoKernel_*.a   ( 9 files)
└─ share/eco/                                NEW
   ├─ kernel/eco-kernel-cpp/                 the eco/kernel Elm package
   │  ├─ elm.json
   │  ├─ artifacts.dat
   │  ├─ typed-artifacts.dat
   │  ├─ docs.json
   │  └─ src/Eco/                            .elm sources + Kernel/*.js stubs
   └─ examples/
      └─ hello/
         ├─ elm.json
         └─ src/Hello.elm
```

Rationale:

- **`share/eco/kernel/eco-kernel-cpp/` not `lib/eco-runtime/kernel-src/`:**
  Elm sources are arch-independent text — exactly the FHS contract for
  `share/`. `lib/eco-runtime/` already means "files the AOT linker
  consumes" and mixing source files in confuses that boundary.
- **Preserve the `eco-kernel-cpp/` directory name** under
  `share/eco/kernel/` so the layout matches the in-tree path. Makes the
  required `--local-package` flag identical in form
  (`--local-package eco/kernel=…/eco-kernel-cpp`) regardless of whether
  the user points it at the source tree or the installed bundle.
- **No pre-built example binaries.** The in-tree `examples/hello` ELF is
  a build by-product; shipping it means users see a stale binary that
  doesn't match the `Hello.elm` they could rebuild.

## Implementation steps

### 1. Add `share/eco/kernel/` install rules

Top-level `CMakeLists.txt`, inside the existing
`if(ECO_STATIC_MUSL)` Bundle block. The `eco-kernel-cpp/` tree lives at
`${CMAKE_SOURCE_DIR}/eco-kernel-cpp/` and contains a mix of source
(`elm.json`, `src/Eco/**/*.elm`, `src/Eco/Kernel/*.js`) plus three
compiler caches at the top (`artifacts.dat`, `typed-artifacts.dat`,
`docs.json`). C++ headers + sources (`src/eco/*.{hpp,cpp}`) live in the
same tree but are **build inputs**, not redistributable artifacts — the
compiled archives already cover the runtime side. Install only the Elm
package half:

```cmake
install(DIRECTORY ${CMAKE_SOURCE_DIR}/eco-kernel-cpp/
        DESTINATION share/eco/kernel/eco-kernel-cpp
        COMPONENT Bundle
        FILES_MATCHING
            PATTERN "elm.json"
            PATTERN "artifacts.dat"
            PATTERN "typed-artifacts.dat"
            PATTERN "docs.json"
            PATTERN "src/Eco/*.elm"
            PATTERN "src/Eco/**/*.elm"
            PATTERN "src/Eco/Kernel/*.js"
            PATTERN ".gitignore" EXCLUDE
            PATTERN "elm-stuff" EXCLUDE)
```

The two `*.elm` patterns cover both `src/Eco/Foo.elm` and the nested
`src/Eco/IO/Error.elm` / `src/Eco/Http/Error.elm` / `src/Eco/Process/Error.elm`.
`FILES_MATCHING` makes any C++ source (`src/eco/*.{hpp,cpp}`) — which
lives in a sibling lowercase `eco/` directory — drop out automatically.

### 2. Add `share/eco/examples/` install rules

```cmake
install(DIRECTORY ${CMAKE_SOURCE_DIR}/examples/
        DESTINATION share/eco/examples
        COMPONENT Bundle
        FILES_MATCHING
            PATTERN "elm.json"
            PATTERN "src/*.elm"
            PATTERN "src/**/*.elm"
            PATTERN ".gitignore" EXCLUDE
            PATTERN "elm-stuff" EXCLUDE)
```

The `examples/hello` pre-built ELF and any `elm-stuff/` cache fall out by
not matching the explicit `PATTERN` list. `FILES_MATCHING` over a
directory walk only copies what matches — there's no `EXCLUDE PATTERN
"hello"` needed because `hello` (the ELF) doesn't match any `PATTERN`.

### 3. Add the `DEB` generator

Top-level `CMakeLists.txt`, inside the existing
`if(ECO_STATIC_MUSL)` CPack block. Extend `CPACK_GENERATOR` to include
`DEB`, and configure the Debian-specific knobs:

```cmake
list(APPEND CPACK_GENERATOR "DEB")
set(CPACK_DEBIAN_PACKAGE_NAME       "eco")
set(CPACK_DEBIAN_PACKAGE_VERSION    "${CPACK_PACKAGE_VERSION}")
set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "amd64")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "thesett <anthropic@thesett.com>")
set(CPACK_DEBIAN_PACKAGE_SECTION    "devel")
# Static binary, no runtime deps — verified by readelf -d in the Stage C
# smoke test. No Depends: line needed; CPack writes an empty one.
set(CPACK_DEBIAN_PACKAGE_DEPENDS    "")
set(CPACK_DEBIAN_PACKAGE_DESCRIPTION
    "Eco — Elm compiler with static AOT runtime (experimental Stage B MUSL build)")
# Install files under /usr/local rather than the archive default of root.
# Per-generator override: archive generators (TGZ/ZIP) keep their default
# (root-relative, relocatable). DEB rewrites every install() destination
# to be rooted at /usr/local.
set(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION TRUE)
```

`CPACK_PACKAGING_INSTALL_PREFIX` is a single-valued knob that all
generators inherit. Two ways to make it `/usr/local` for `DEB` only:

1. **Run `cpack -G DEB` separately** with
   `-D CPACK_PACKAGING_INSTALL_PREFIX=/usr/local` on the command line.
   Then run `cpack -G "TGZ;ZIP"` without it. Simple and explicit.
2. Use `CPACK_PROJECT_CONFIG_FILE` — a separate `.cmake` script that
   CPack `include`s per generator. Inside, branch on
   `${CPACK_GENERATOR}` and set the prefix.

Option 2 is the cleaner answer because the existing
`cmake --build build --target package` target invokes CPack once with
all generators. Add `cmake/CPackProjectConfig.cmake`:

```cmake
# Per-generator overrides. CPack re-includes this file once per generator
# in the CPACK_GENERATOR list with ${CPACK_GENERATOR} set.
if(CPACK_GENERATOR STREQUAL "DEB")
    set(CPACK_PACKAGING_INSTALL_PREFIX "/usr/local")
    set(CPACK_PACKAGE_FILE_NAME "eco_0.1.0_amd64")  # Debian naming convention
endif()
```

and wire it via `set(CPACK_PROJECT_CONFIG_FILE
"${CMAKE_SOURCE_DIR}/cmake/CPackProjectConfig.cmake")` before
`include(CPack)`.

### 4. Confirm DEB strip behaviour

`CPACK_STRIP_FILES ON` is already set for the archive generators. Verify
the DEB generator honours it for `bin/eco` and `lib/eco-runtime/ld.lld`
(it should — `CPACK_STRIP_FILES` is generator-agnostic in CPack 3.x).

Static archive stripping in `lib/eco-runtime/project/lib*.a` and the
system archives already runs at install time via the
`install(CODE "…strip --strip-debug…")` block in the top-level
`CMakeLists.txt`. That runs once per `cmake --install` invocation,
regardless of generator. Already correct.

### 5. Dockerfile updates

`docker/static-build.Dockerfile`:

- The `apk add --no-cache zip` line is already there from Stage C; no
  change needed for `.deb`. CPack's DEB generator is pure CMake/Python
  and uses the host's `tar` + `ar` — no `dpkg-deb` dependency.
- After the existing `--target package` step, list the three artifacts:

  ```dockerfile
  RUN ls -lh build/eco-0.1.0-x86_64-linux-musl.tar.gz \
            build/eco-0.1.0-x86_64-linux-musl.zip \
            build/eco_0.1.0_amd64.deb
  ```

- Replace the existing `eco-bundle` stage so all three artifacts ship:

  ```dockerfile
  FROM scratch AS eco-bundle
  COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.tar.gz /
  COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.zip    /
  COPY --from=eco-builder /eco/build/eco_0.1.0_amd64.deb                /
  ```

### 6. Smoke test (Dockerfile)

Extend the Stage C smoke test to use the bundled examples + kernel
sources rather than reaching back into the source tree:

```dockerfile
RUN tar -xzf build/eco-0.1.0-x86_64-linux-musl.tar.gz -C /tmp/ \
 && cd /tmp/eco-0.1.0-x86_64-linux-musl/share/eco/examples/hello \
 && /tmp/eco-0.1.0-x86_64-linux-musl/bin/eco make src/Hello.elm \
        --local-package eco/kernel=/tmp/eco-0.1.0-x86_64-linux-musl/share/eco/kernel/eco-kernel-cpp \
        --output=hello \
 && ./hello | grep -q "Hello World!" \
 && readelf -d ./hello | (grep -q NEEDED && echo FAIL || echo OK)
```

This exercises three new things over Stage C: (a) the example sources
ship correctly, (b) the kernel Elm sources resolve correctly via
explicit `--local-package`, and (c) the produced ELF still has no
NEEDED entries (output statics survive the bundle layout change).

Add a parallel test for the `.deb`:

```dockerfile
RUN apk add --no-cache dpkg \
 && mkdir -p /tmp/deb-root \
 && dpkg-deb -x build/eco_0.1.0_amd64.deb /tmp/deb-root \
 && test -x /tmp/deb-root/usr/local/bin/eco \
 && test -f /tmp/deb-root/usr/local/share/eco/kernel/eco-kernel-cpp/elm.json \
 && test -f /tmp/deb-root/usr/local/share/eco/examples/hello/elm.json
```

`dpkg-deb -x` works without a running dpkg database — it just extracts
the data tarball. Confirms the layout, doesn't try a real install (which
would need a Debian/Ubuntu host).

### 7. Documentation

Extend the Stage C `docs/distribution.md` (created by that plan):

- New "Installing from the `.deb`" section: `sudo dpkg -i
  eco_0.1.0_amd64.deb`, files land in `/usr/local/{bin,lib,share}/eco*`.
- New "Building with kernel imports" section showing the
  `--local-package eco/kernel=/usr/local/share/eco/kernel/eco-kernel-cpp`
  flag, and a worked example using `share/eco/examples/hello`.
- "Why no auto-discovery yet" note pointing at the follow-up.

## Affected files (estimated diff)

| File | Change |
|---|---|
| `CMakeLists.txt` | Two `install(DIRECTORY …)` blocks for `share/eco/kernel/` and `share/eco/examples/`; CPack DEB generator config; wire `CPACK_PROJECT_CONFIG_FILE` |
| `cmake/CPackProjectConfig.cmake` | New — per-generator overrides, primarily `CPACK_PACKAGING_INSTALL_PREFIX=/usr/local` for `DEB` |
| `docker/static-build.Dockerfile` | List `.deb` next to `.tar.gz`/`.zip`; extend `eco-bundle` stage; expanded smoke test |
| `docs/distribution.md` | `.deb` install section; kernel-import worked example |
| `plans/static-link-eco-binary.md` | Mark v0.1.0 release scope done; reference this plan |

No source changes to `eco`, the runtime, or the kernel are required —
this is purely a packaging change.

## Verification

- `cmake --build build-static --target package` produces all three
  artifacts:
  - `build-static/eco-0.1.0-x86_64-linux-musl.tar.gz`
  - `build-static/eco-0.1.0-x86_64-linux-musl.zip`
  - `build-static/eco_0.1.0_amd64.deb`
- `unzip -l eco-0.1.0-x86_64-linux-musl.zip` and `tar tzf
  eco-0.1.0-x86_64-linux-musl.tar.gz` and `dpkg-deb -c
  eco_0.1.0_amd64.deb` show the **same set of file paths** (the only
  difference is the leading prefix: archive root vs `./usr/local/`).
- `dpkg-deb -I eco_0.1.0_amd64.deb` shows package name `eco`, version
  `0.1.0`, architecture `amd64`, empty `Depends:` line.
- After `dpkg -i` on a Debian host: `which eco` → `/usr/local/bin/eco`;
  `ls /usr/local/share/eco/kernel/eco-kernel-cpp/src/Eco/` lists the 11
  exposed kernel modules.
- Smoke-test build of `hello` via the `.zip` extraction → runs, prints
  "Hello World!", `readelf -d ./hello` has no NEEDED entries.
- Bundle size targets (informational, no hard cap):
  - `.tar.gz` ≤ 80 MB
  - `.zip` ≤ 100 MB
  - `.deb` ≤ 100 MB (similar to `.zip` — `.deb`'s data tarball is gzip
    or xz, same compression class).

## Follow-ups (separate plans)

- **Kernel auto-discovery.** Extend `EcoBootConfig` so `eco` looks for
  the `eco/kernel` package at `<exe>/../share/eco/kernel/eco-kernel-cpp`
  by default (mirroring the existing `<exe>/../lib/eco-runtime/`
  resolver), plus an `ECO_KERNEL_DIR` env-var override. Drops the
  `--local-package` requirement from the worked example. Requires a
  small change to the front-end's package resolver, hence a separate
  plan.
- **README bootstrap section.** Add a "Building from source" section to
  the project README pointing users at `cmake --preset
  ninja-clang-lld-linux-musl` + `cmake --build build-static --target
  bootstrap`. The current README assumes dev context; release users need
  an explicit pointer that says "if you want to rebuild the compiler,
  start here." Cheap doc work; just out of scope for this plan because
  it's not a bundle change.
- **`eco-dbgsym` companion package.** Debian convention — ship the
  unstripped `eco` separately so users can opt in to debug symbols.
- **GitHub Releases CI/CD.** Tag-triggered GH Action that runs the
  Docker build and uploads all three artifacts.
- **Debian / Ubuntu upstreaming.** Move to `/usr` prefix, add `Depends:
  libc6` or similar, conform to debian-policy. Significant work; defer
  until the experimental release has shaken out.
- **More examples.** v0.1.0 ships just `hello`; subsequent releases can
  add `http-client`, `file-io`, `mvar-counter`, etc., as the kernel API
  surface stabilises.
