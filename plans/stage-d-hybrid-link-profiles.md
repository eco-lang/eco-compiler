# Stage D — hybrid link profiles: glibc `.so`/`.node` outputs from the static-musl bundle

Follow-up to [stage-c-bundle-runtime.md](stage-c-bundle-runtime.md) and
[static-link-eco-binary.md](static-link-eco-binary.md). Supersedes the
"Glibc Stage A bundle" follow-up bullet (stage-c-bundle-runtime.md:396):
instead of shipping a *separate* glibc-flavored bundle, the existing
musl bundle gains a second, glibc-targeting set of link inputs, and the
single static `eco` binary selects a link profile per output kind. The
user-visible win: `eco make src/elm/Top.elm --output=build/elm.node`
works from the installed bundle, with no host toolchain present, and the
produced addon loads into stock (glibc) Node.

Today this fails by design at `runtime/src/codegen/EcoNativeDriver.cpp:409-413`
("shared-library output is not supported in the static-musl profile").
The refusal is correct for what the bundle currently contains: the link
inputs are musl-static-executable-only, and a `.node` is a dynamic
shared object that lives inside a glibc Node process. Stage D removes
the refusal by shipping what the second profile needs, not by relaxing
what the first profile promises.

Naming: Stages A/B got ".5" suffixes when an existing promise was
extended from `eco` itself to the binaries `eco` produces. Stage D is a
*new* promise (a second target ABI from one bundle), so it takes the
next letter.

## Scope

**In scope (v1):**

- `.so` and `.node` outputs from the installed static-musl bundle, linked
  against a bundled **glibc-ABI** archive set, with **no host toolchain
  or host dev files required at link time** (same zero-host-deps contract
  Stage C established for executables).
- Bundling the glibc CRT objects needed for `-shared` links
  (`crti.o`, `crtn.o`, `crtbeginS.o`, `crtendS.o`) — the selected
  "partially shipped CRT" option: fatter bundle, fewer host assumptions.
- A second compiled copy of the link-relevant project archives (runtime,
  22 ElmKernel + 9 EcoKernel, embed entry, node glue) plus dep/runtime
  statics (curl/ssl/crypto/zip/z, libc++/libc++abi/libunwind,
  compiler-rt builtins), all glibc-targeting and **verified PIC**, under
  `lib/eco-runtime/glibc/`.
- Fixing two latent bundle bugs Stage D collides with:
  `libEcoEmbedStatic.a` / `libEcoNodeGlue.a` are in **no** `install()`
  rule (`/work/CMakeLists.txt:329-339`), and `EcoNodeGlue` is not built
  at all in the Alpine release image (no `node_api.h`;
  `runtime/src/codegen/CMakeLists.txt:683-698`).
- Runtime (not configure-time) link-profile selection inside
  `linkExecutable`, keyed on output kind.
- A friendly musl-Node failure message, emitted from the generated
  `.js` shim (step 6) — the addon itself stays glibc-only.
- A `--link=static|dynamic` *policy decision* (recorded below). The flag
  itself is **not** needed in v1 — see the output-kind matrix: for every
  ending there is exactly one workable link kind until dynamic
  executables land, so v1 is defaults-only with no functional frontend
  changes.

**Out of scope (defer):**

- **Dynamic-glibc executables** (`--link=dynamic` for plain ELF
  outputs). Unlike `-shared` links, executables may not have undefined
  symbols, so they need `Scrt1.o`, glibc's `libc_nonshared.a`, and a
  host `libc.so.6`/`libm.so.6` to link against — a host-probing problem
  Stage D's shared-library case deliberately avoids. Phase 2; the
  `--link` flag plumbing (5 layers, see Decisions log Q8) lands with it.
- Export trimming of the program's own symbol surface (the unimplemented
  D6 item, native-ports-and-embedding.md:683-684; today's dev-built
  `.node` exports 1343 symbols). Stage D hides the *statically linked
  system/runtime archives* (required for correctness — Q5) but the
  `Main_*`/kernel symbols remain exported as today.
- Running glibc `.node` outputs on musl-hosted Node (Alpine). Detection
  + clear message is in scope (step 6); support is not.
- ARM64 / macOS, matching the rest of the bundle.
- Changing the dev (non-bundle, glibc host) build: it keeps the legacy
  configure-time-baked recipe untouched.

## Output-kind matrix

What `eco make --output=X` produces, which pipeline handles it, and what
link kind applies. Frontend dispatch is `parseOutput`
(`compiler/src/Terminal/Make.elm:748-766`) — only five `Output` cases
exist (`Make.elm:113-118`); `.o`/`.so`/`.node` and any unrecognized
name all reach the C++ driver as "ELF" and are sub-dispatched on the
file ending at `EcoNativeDriver.cpp:198-201`.

| `--output` ending | Artifact | Pipeline | Link kind: today (dev glibc build) | Link kind: today (musl bundle) | **Stage D default (musl bundle)** |
|---|---|---|---|---|---|
| *(omitted)* | `index.html` (one main) / `elm.js` (several) | JS codegen | n/a — no native link | n/a | n/a |
| `/dev/null`, `NUL`, `<¦null` | nothing (typecheck only) | none | n/a | n/a | n/a |
| `.js` | JavaScript file | JS codegen | n/a | n/a | n/a |
| `.html` | self-contained HTML | JS codegen | n/a | n/a | n/a |
| `.mlir` | MLIR module (bytecode; text with `--text-mlir`) | frontend IR dump | n/a | n/a | n/a |
| `.o` | relocatable object | native, **no link** (`EcoNativeDriver.cpp:198,243-244`) | profile-independent | profile-independent | profile-independent (PIC + `CodeModel::Small` always, `EcoBackend.cpp:82-84`) |
| *(anything else)* | ELF executable | native + link | glibc dynamic-PIE | **musl fully-static** | **static** (unchanged; `--link=dynamic` = phase 2) |
| `.so` | shared library, `eco_app_*` embed entry | native + link | glibc `-shared` (via ld.bfd) | **refused** (`EcoNativeDriver.cpp:409`) | **dynamic-glibc** (only possibility) |
| `.node` | N-API addon + sibling `.js` shim | native + link | glibc `-shared` + node glue | **refused** | **dynamic-glibc** (only possibility) |

Notes:

- The `.o` is genuinely profile-neutral: codegen never varies by output
  kind (`Reloc::PIC_`, `x86-64-v3`, no libc headers involved — the
  object is generated from MLIR). Only `linkExecutable` diverges.
- `--output=foo.eco` / `foo.wasm` fall through to the executable path
  today (no `.wasm` support exists; `.eci`/`.eco`/`.ecot` are internal
  cache artifact extensions, `compiler/src/Builder/Stuff.elm:133-151`).
  Pre-existing wart, unchanged by Stage D.
- The `--output` help text (`compiler/src/Terminal/Main.elm:253-258`)
  predates the native backend and mentions only JS//dev/null — update it
  while we are here (step 8).

## Default-policy decision

The tempting rule — *dynamic for everything unless the user asks for
static* — was considered and **rejected**. The matrix above shows why:

1. **For executables, static is the product.** Stage B.5's contract is
   that `eco`-produced binaries have no NEEDED entries and run on any
   Linux (design_docs/distribution.md:91-94). Defaulting executables to
   dynamic-glibc silently reintroduces exactly the host coupling Stages
   B/C existed to remove — and breaks musl hosts (Alpine) entirely.
2. **Dynamic executables are the hardest case, not the easy default.**
   A `-shared` link may leave libc symbols undefined; an executable link
   may not. Defaulting executables to dynamic makes the *default* depend
   on host glibc dev files that the bundle's whole design avoids
   needing.
3. **For shared outputs there is no choice to default over.** A
   fully-static musl shared object is a contradiction (no dynamic
   section, two libcs in one process, no TLS/startup init under
   `dlopen`). `.so`/`.node` are glibc-dynamic or nothing.

**Decision: per-output-kind defaults, which in v1 are also the only
supported kinds.** Executables: musl-static. `.so`/`.node`:
dynamic-glibc. `--link=static` on a shared output stays a hard error
(today's message, reworded to say *why*); `--link=dynamic` on an
executable is deferred to phase 2 with the flag itself. No flag is
shipped in v1 because it would have no legal non-default value.

## Layout

Additions to the Stage C bundle (existing entries unchanged; current
layout in design_docs/distribution.md:30-48, which is stale in both
directions and gets refreshed in step 8):

```
eco-0.1.0-x86_64-linux-musl/
└─ lib/eco-runtime/
   ├─ ld.lld                          (existing — also drives the glibc -shared links)
   ├─ crt/, libc.a, libc++.a, …       (existing musl set, unchanged)
   ├─ project/                        (existing musl archives, unchanged)
   └─ glibc/                          (NEW — second link-input set, glibc ABI, all PIC)
      ├─ crt/
      │  ├─ crti.o, crtn.o            (glibc, harvested from the Debian builder)
      │  └─ crtbeginS.o, crtendS.o    (gcc, shared/PIC variants)
      ├─ libc++.a, libc++abi.a, libunwind.a
      ├─ libclang_rt.builtins-x86_64.a
      ├─ libcurl.a, libssl.a, libcrypto.a, libzip.a, libz.a
      └─ project/
         ├─ libEcoEmbedStatic.a       (host-embedding entry: eco_app_start/stop/join)
         ├─ libEcoNodeGlue.a          (N-API glue: napi_register_module_v1)
         ├─ libEcoRuntimeStatic.a
         ├─ libElmKernel_*.a          (22)
         └─ libEcoKernel_*.a          (9)
```

Rationale:

- **One bundle, two trees, one binary.** `RuntimeFile.subdir` is already
  a free-form string joined under `runtimeDir()`
  (`EcoBootConfig.cpp:70-94`), so `"glibc/crt"` / `"glibc/project"`
  need no resolver changes.
- **No `libEcoEntryStatic.a` / `libEcoNativeDriverStatic.a` in the glibc
  tree.** Shared outputs use the embed entry, and `linkExecutable` never
  consumes the native-driver archive (`EcoNativeDriver.cpp:478-507`; the
  `eco_native_*` weak stubs ride in `EcoEmbedStatic` via
  `eco_native_stub.cpp`, `runtime/src/codegen/CMakeLists.txt:659-662`).
  Dynamic *executables* are out of scope, so the standalone-`main()`
  archive has no glibc consumer in v1. The embed archives ship **only**
  here, not in the musl `project/` tree, where they would be dead weight
  the musl link line can never use (the inventory-driven install
  approach of stage-c-bundle-runtime.md:92-108).
- **No glibc `libc.a`/`Scrt1.o`**: `-shared` links need neither. libc
  symbols stay **undefined at link time** and bind at load time from the
  host process's glibc (Decisions log Q4) — the same mechanism the
  N-API symbols already use by design
  (plans/native-ports-and-embedding.md:366-368).
- **Self-contained by construction.** Unlike the dev-build `.node`
  (observed: 10 NEEDED entries including `libcurl.so.4`, `libzip.so.4`,
  `libunwind.so.1`, plus a dev-machine RUNPATH), the bundle-produced
  `.node` statically links curl/ssl/zip/z, libc++ and libunwind from
  `glibc/`, hidden via a scoped `--exclude-libs` list (Q5). Host
  requirements: glibc, `libm` present in the consuming process (always
  true under Node; C hosts of a `.so` must link `-lm` — see step 7), and
  for `.node` Node ≥ 16. Nothing else.

## Build environments and Docker pipeline

The release bundle is built by **docker/static-build.Dockerfile**
(`cmake --build build-static --target package` in the `eco-builder`
stage, :134-137; artifacts exported via the `eco-bundle` scratch stage,
:179-182). That stays true under Stage D, and the "hybrid" eco is **the
same musl-static binary** built there today — the new driver code
(LinkProfile, capability probe, shim) compiles in `eco-builder` with no
new dependencies; the hybrid *capability* is delivered as data (the
`glibc/` tree merged in step 3). What each environment's eco can
produce:

| Environment | eco flavor | Executable output | `.so`/`.node` output |
|---|---|---|---|
| **static-build.Dockerfile** (release bundle) | musl-static | musl fully-static | glibc-dynamic via bundled `glibc/` tree (**Stage D**) |
| **static-dev.Dockerfile** (interactive Alpine) | musl-static, build-tree paths | musl fully-static | step 5 capability error — no `glibc/` tree in the container; see note below |
| **eco-dev.Dockerfile** (interactive Debian — the standard dev container) | glibc-dynamic | glibc dynamic-PIE; with `-DECO_STATIC=ON` at configure time, Stage A.5 static-deps (glibc still dynamic). **Never musl-static** — that requires the Alpine toolchain + musl archive set | glibc `-shared` via host ld.bfd (legacy recipe, untouched by Stage D) |

Honest qualifications the matrix encodes:

- The dev (eco-dev) eco produces *dynamic* artifacts of every kind
  today and continues to, unchanged. Its "static" capability is the
  configure-time Stage A.5 profile (`ECO_STATIC=ON`, set by no preset),
  not a per-invocation choice — per-invocation profile selection is a
  Stage D feature of the *bundle* eco only, and even there only in the
  one direction the matrix shows. A glibc-hosted eco that emits
  musl-static executables would need the entire musl archive set and is
  nobody's requirement: the bundle eco already runs fine on glibc dev
  hosts.
- **static-dev note**: the interactive Alpine container mirrors
  `eco-builder` (its header demands the apk lists stay in sync — Stage
  D adds **no** apk packages to either, since the Node-API headers are
  vendored (step 1) and zlib vendoring is gated to the glibc-runtime
  configure, leaving Alpine on apk `zlib-static`). A build-tree eco
  inside static-dev has no `glibc/` tree, so `.so`/`.node` correctly
  hit the step 5 capability error. To exercise Stage D interactively:
  extract a `glibc-runtime-tree` (from the `glibc-runtime` stage or a
  release bundle) into a dir that also mirrors the musl runtime layout
  and set `ECO_RUNTIME_DIR` to it — which is why the step 4 probe must
  honor `ECO_RUNTIME_DIR`, not just the exe-relative path.

Per-Dockerfile change summary (details in the steps):

- **docker/static-build.Dockerfile** — changed (steps 2, 3, 7): new
  **self-contained** `glibc-runtime` stage `FROM debian:bookworm` +
  apt packages (no second LLVM image — see step 2),
  `COPY --from=glibc-runtime`, `-DECO_GLIBC_RUNTIME_TREE` cache arg,
  Debian + second-distro smoke stages, and the banner comment
  (previously "Three stages") updated. The release pipeline keeps
  exactly **one** prerequisite image (`eco-llvm-alpine`), as before
  Stage D.
- **docker/llvm-debian.Dockerfile** — **unchanged**; remains
  dev-environment-only. (An earlier revision of this plan promoted it
  to a release prerequisite carrying an LLVM-runtimes build; that
  coupling was challenged and removed — the archive-only configure
  gates MLIR off entirely, and the runtime statics come from apt,
  mirroring how the musl side takes them from Alpine apk.)
- **docker/static-dev.Dockerfile** — **no changes required**; the apk
  sync contract with `eco-builder` holds because `eco-builder` gains no
  packages either. Behavior note above.
- **docker/eco-dev.Dockerfile** — **no changes required**: node headers
  are already present (NodeSource node 22 ships `/usr/include/node`;
  verified in the running container), rapidcheck is installed, and the
  dev link recipes are untouched. After step 1 the node-headers
  dependency disappears entirely.

## Implementation steps

### 1. Vendor the Node-API headers

`EcoNodeGlue` is gated on `find_path(ECO_NODE_API_INCLUDE_DIR node_api.h
PATHS /usr/include/node /usr/local/include/node)`
(`runtime/src/codegen/CMakeLists.txt:683-698`); absent headers silently
disable `.node` output and bake an empty `nodeGlueLib` buildPath
(`:1071-1077`). The release Alpine image has no node headers
(docker/static-build.Dockerfile:60-71 installs `nodejs npm` only).

Vendor the four ABI-stable, MIT-licensed headers (`node_api.h`,
`node_api_types.h`, `js_native_api.h`, `js_native_api_types.h`, pinned
at NAPI version 8 to match `eco_node_addon.cpp:24`) under
`runtime/third_party/node-api-headers/`, and make the `find_path`
default to them. `EcoNodeGlue` then builds unconditionally on every
host, including Alpine. Keep the env override for people who want
system headers.

### 2. Build the glibc archive set in a Debian builder stage

No glibc stage exists in the release pipeline today (the only Debian
images are the dev environment, docker/llvm-debian.Dockerfile +
docker/eco-dev.Dockerfile). Add one — **self-contained, from
`debian:bookworm` + apt; no LLVM source image**. The stage's archives
are compiled by apt clang either way, and the LLVM runtime statics come
from apt packages, mirroring exactly how the musl side takes
libc++/compiler-rt from Alpine apk (docker/static-build.Dockerfile's
`libc++-static compiler-rt`; the Alpine LLVM image builds only
libunwind, docker/llvm-alpine.Dockerfile:66). Four sub-parts:

- **Gate the MLIR half of runtime/src/codegen/CMakeLists.txt** behind
  `if(NOT ECO_GLIBC_OUTPUT_RUNTIME)`: `find_package(MLIR)`, TableGen,
  the dialect/pass libraries, `EcoNativeDriverStatic`, `ecoc`/`ecogen`/
  `EcoRunner` and `eco-boot-native`. What stays is the
  toolchain-independent half the file also owns: EcoEntry/Embed/
  NodeGlue/RuntimeStatic targets, kernel module lists, linker/crt
  discovery, EcoBootConfig.h generation. The archive-only mode must
  replicate the semantically relevant compile flags HandleLLVMOptions
  injected for the surviving targets (`-ffunction-sections
  -fdata-sections -fno-semantic-interposition
  -fvisibility-inlines-hidden`; EH is per-target opt-in in both modes —
  verified against the full build's compile commands).
- **Source the runtime statics from apt**: `libc++-14-dev`
  `libc++abi-14-dev` `libclang-rt-14-dev` `libunwind-14-dev`, with
  `-DLLVM_INSTALL_PREFIX=/usr/lib/llvm-14` pointing the existing
  discovery at the apt layout (libc++/libc++abi via the musl block's
  `clang -print-file-name` queries; builtins via
  `--print-libgcc-file-name -rtlib=compiler-rt`; libunwind reuses
  `cmake/LLVMLibunwind.cmake`'s result — extended to search the apt
  header nest `/usr/include/libunwind/`, which carries the
  `__libunwind_config.h` marker; the nongnu `libunwind-dev` package
  must NOT be installed). libc++ major skew vs the musl side (14 vs
  21) is harmless: the profiles never cross-link and the archives are
  self-contained in produced outputs. PIC-ness of the distro archives
  is **not assumed** — the audit below gates them (and has now
  verified bookworm's: all pass).
- **Vendor zlib with `-fPIC`.** Debian bookworm's `libz.a` is **not
  PIC** (verified: a trial `ld.lld -shared --whole-archive libz.a` fails
  with `relocation R_X86_64_PC32 cannot be used against symbol
  'z_errmsg'`), and zlib members are pulled into every shared link
  (vendored curl uses gzip Content-Encoding; libzip requires z). Add a
  zlib FetchContent build next to the existing curl/libzip vendoring —
  it inherits the global PIC flag (`/work/CMakeLists.txt:7`). **Gate it
  on `ECO_GLIBC_OUTPUT_RUNTIME`** so the Alpine/musl path keeps using
  apk `zlib-static` unchanged (and static-dev.Dockerfile's apk-sync
  contract stays untouched). Debian's OpenSSL 3 statics are PIC
  (checked), so ssl/crypto stay system archives; the audit below
  catches regressions.
- **New stage `glibc-runtime` in docker/static-build.Dockerfile**:
  `FROM debian:bookworm AS glibc-runtime` (digest-pin like the Alpine
  bases) + one apt install (toolchain, `libssl-dev` for
  eco-kernel-cpp's `find_package(OpenSSL REQUIRED)`, and the four LLVM
  runtime dev packages above). Configure — note the real preset names
  are `dev`/`build`/`release` (CMakePresets.json; the
  `ninja-clang-lld-*` family in CLAUDE.md/distribution.md is stale):

  ```
  cmake --preset build -B build-glibc-runtime \
        -DECO_STATIC=ON -DECO_GLIBC_OUTPUT_RUNTIME=ON \
        -DLLVM_INSTALL_PREFIX=/usr/lib/llvm-14
  cmake --build build-glibc-runtime --target eco-glibc-runtime-tree
  ```

  `ECO_STATIC=ON` is required: the vendored `libcurl_static`/`zip`
  targets only exist under it (`/work/CMakeLists.txt:151-213`,
  `eco-kernel-cpp/CMakeLists.txt:40-66`).
  `ECO_GLIBC_OUTPUT_RUNTIME=ON` makes this an **archive-only**
  configure: it gates off `add_subdirectory(compiler)`,
  `add_subdirectory(test)` and the `find_package(rapidcheck REQUIRED)`
  that rides with it (`/work/CMakeLists.txt:241,274`) — the Debian LLVM
  image has no node/pnpm/rapidcheck and must not need them. What gets
  built is an explicit list (do **not** reuse `_eco_project_targets`,
  which exists only inside the `if(ECO_STATIC_MUSL)` block and contains
  `EcoEntryStatic`/`EcoNativeDriverStatic` — the latter would drag the
  whole MLIR object graph into a stage meant to take minutes):
  `EcoRuntimeStatic`, `EcoEmbedStatic`, `EcoNodeGlue`, the 22
  `ElmKernel_*` and 9 `EcoKernel_*` targets, `libcurl_static`, `zip`,
  and the vendored zlib.
- **`eco-glibc-runtime-tree` staging target**: copies the archives, the
  LLVM runtime statics, and the configure-discovered glibc CRT objects
  (`ECO_CRTI_O`, `ECO_CRTN_O`, `ECO_CRTBEGIN_O`, `ECO_CRTEND_O` —
  already probed via `clang -print-file-name`,
  `runtime/src/codegen/CMakeLists.txt:843-868`; on Debian these resolve
  to glibc's `crti.o`/`crtn.o` and gcc's `crtbeginS.o`/`crtendS.o`) into
  `/out/glibc-runtime-tree/{crt,project,*.a}`, then runs a **PIC
  audit**: a trial `ld.lld -shared --whole-archive <archive>` per staged
  archive (undefined symbols allowed, output discarded) so a non-PIC
  archive can never reach the bundle. The audit also dumps the combined
  UND symbol set so the real glibc floor is *computed*, recorded in the
  tree as `GLIBC_FLOOR`, and surfaced in docs (see Q4 — it is not
  inferable from the dev-built `.node`).

### 3. Merge the glibc tree into the bundle

In docker/static-build.Dockerfile's main Alpine builder:

```dockerfile
COPY --from=glibc-runtime /out/glibc-runtime-tree /opt/eco-glibc-runtime
```

and pass `-DECO_GLIBC_RUNTIME_TREE=/opt/eco-glibc-runtime` to the
existing musl configure. Top-level /work/CMakeLists.txt (next to the
existing Bundle rules at :300-408):

```cmake
if(ECO_STATIC_MUSL AND ECO_GLIBC_RUNTIME_TREE)
    install(DIRECTORY ${ECO_GLIBC_RUNTIME_TREE}/
            DESTINATION lib/eco-runtime/glibc
            COMPONENT Bundle)
endif()
```

The `ECO_BUNDLE_STRIP` rule needs no change — its
`file(GLOB_RECURSE … *.a *.o)` over `lib/eco-runtime`
(`/work/CMakeLists.txt:395-396`) already covers the new subtree. The
bundle remains buildable without the tree (no `glibc/` dir → shared
outputs keep failing, with the improved error from step 5); CI builds
always pass it.

### 4. Declare the glibc inputs in EcoBootConfig.h

Add a second constants block to the generated header
(`runtime/src/codegen/CMakeLists.txt:1119+`). These are
**bundle-resolved only** — `buildPath` is empty because the Alpine
configure cannot see Debian build paths, and the dev build never uses
them:

```cpp
// --- Stage D: glibc output-profile inputs (bundle-only) ---
inline RuntimeFile glibcCrtiObj      {"crti.o",       "glibc/crt", ""};
inline RuntimeFile glibcCrtnObj      {"crtn.o",       "glibc/crt", ""};
inline RuntimeFile glibcCrtbeginObj  {"crtbeginS.o",  "glibc/crt", ""};
inline RuntimeFile glibcCrtendObj    {"crtendS.o",    "glibc/crt", ""};
inline RuntimeFile glibcLibcxxA      {"libc++.a",     "glibc", ""};
inline RuntimeFile glibcLibcxxabiA   {"libc++abi.a",  "glibc", ""};
inline RuntimeFile glibcUnwindA      {"libunwind.a",  "glibc", ""};
inline RuntimeFile glibcBuiltinsA    {"libclang_rt.builtins-x86_64.a", "glibc", ""};
inline RuntimeFile glibcCurlA        {"libcurl.a",    "glibc", ""};
/* …ssl/crypto/zip/z, embed/nodeGlue/runtime + kernel vectors with
   subdir "glibc/project", mirroring the existing declarations… */
```

Plus a runtime capability probe in EcoBootConfig.cpp:

```cpp
// True when the installed bundle carries the Stage D glibc output
// profile: stat($ECO_RUNTIME_DIR/glibc) when the env override is set,
// else stat(<exe>/../lib/eco-runtime/glibc) — mirroring runtimeDir()
// (EcoBootConfig.cpp:51-59). The env branch is what lets an
// interactive static-dev container exercise Stage D against an
// extracted glibc-runtime tree (see "Build environments").
bool hasGlibcOutputProfile();
```

### 5. Refactor `linkExecutable` to select a profile at runtime

Today the profile is the compile-time constant `ecoStaticMusl`
threaded through ~15 `if`s (`EcoNativeDriver.cpp:343-624`). Keep that
constant as the *bundle flavor*, but stop letting it imply the *output
profile*. Replace the hard refusal at :409-413 with:

```cpp
// Output profile selection. The musl bundle links executables
// fully-static (Stage B.5) and shared outputs against the bundled
// glibc archive set (Stage D). A fully-static musl shared object
// remains a contradiction in terms; what changed is that the bundle
// now carries a second set of link inputs for exactly this case.
if (sharedLib && eco::config::ecoStaticMusl &&
    !eco::config::hasGlibcOutputProfile()) {
    llvm::errs() << "Error: this eco bundle lacks the glibc output "
                    "profile (lib/eco-runtime/glibc/), which .so/.node "
                    "outputs require: shared libraries cannot be "
                    "fully-static musl objects\n";
    return 1;
}
```

and restructure the arg construction around a small profile object so
the three recipes stop interleaving:

```cpp
struct LinkProfile {
    llvm::StringRef kindFlag;            // "-static" | "-pie" | "-shared"
    std::vector<std::string> crtPre;     // resolved crt prologue
    std::vector<std::string> crtPost;    // resolved crt epilogue
    std::vector<std::string> projectLibs;// entry/embed+glue, runtime, kernels
    std::vector<std::string> sysLibs;    // libc/c++/curl/… (abs paths or -l)
    std::vector<std::string> hideLibs;   // --exclude-libs basenames
    bool noDependentLibraries;
    bool zNotext;
    /* … */
};
```

The Stage D glibc-shared profile (musl bundle, `.so`/`.node`):

```
<bundled ld.lld>  --eh-frame-hdr  -shared  -z notext  --no-dependent-libraries  -o <out>
glibc/crt/crti.o  glibc/crt/crtbeginS.o
<objectFile>
--start-group
  --whole-archive glibc/project/libEcoEmbedStatic.a
                  [glibc/project/libEcoNodeGlue.a if .node]
  --no-whole-archive
  glibc/project/libEcoRuntimeStatic.a
  glibc/project/libElmKernel_*.a (Utils whole-archived)  glibc/project/libEcoKernel_*.a
--end-group
glibc/libc++.a glibc/libc++abi.a
glibc/libcurl.a glibc/libssl.a glibc/libcrypto.a glibc/libzip.a glibc/libz.a
glibc/libclang_rt.builtins-x86_64.a
glibc/libunwind.a
glibc/libc_nonshared.a   (atexit/at_quick_exit/pthread_atfork/__stack_chk_fail_local — NOT in libc.so.6)
--exclude-libs <every archive on this line EXCEPT libEcoEmbedStatic.a / libEcoNodeGlue.a>
glibc/crt/crtendS.o  glibc/crt/crtn.o
```

Deliberate properties:

- **Linker = the already-bundled static `ld.lld`** (`resolveFile(bundledLinker)`,
  today musl-gated at :379-381). A linker is target-ABI-agnostic;
  `systemLinker` (Alpine garbage in the bundle) is never touched.
- **`-z notext` is required, not optional.** The emitted objects carry
  `R_X86_64_64` relocations in the allocatable `.llvm_stackmaps`
  section; lld refuses them in *any* position-independent output —
  PIE **and** `-shared` (the repo already recorded the PIE half:
  static-link-eco-binary.md:70-73, `runtime/src/codegen/CMakeLists.txt:830-832`).
  Today's dev `.so`/`.node` links work only because they go through
  ld.bfd (`systemLinker`), which emits the same thing with a
  `DT_TEXTREL` warning. `-z notext` makes lld match bfd: the dynamic
  loader applies the absolute relocs at load time — which the embed
  runtime *depends on*, since it parses the in-memory section assuming
  relocations were applied (`eco_embed.cpp:146-151`). Residual cost:
  `DT_TEXTREL` (dirty pages at load; SELinux `allow_execmod` denials on
  hardened hosts) — see Risk register; removing the TEXTREL entirely is
  a recorded follow-up.
- **`--no-dependent-libraries` stays.** Clang-built `libc++.a` embeds
  `.deplibs` autolink hints (`-lpthread`/`-lrt`); with an
  all-absolute-paths link line and no `-L` dirs, resolving them is a
  hard error — the exact failure already documented for the musl
  profile at `EcoNativeDriver.cpp:396-404`, and the Debian-built
  libc++ carries the same hints.
- **No `-L`, no `-l`, no rpath**: every input is an absolute bundle
  path; libunwind is the static archive, so the dev recipe's
  `-rpath <unwindLibDir>` hazard (observed RUNPATH
  `/opt/llvm-mlir/...` in shipped artifacts) disappears.
- **libc/libm/pthread symbols stay undefined** (no `-z defs`;
  lld's `-shared` default). They bind at `dlopen` from the glibc
  already in the host process — identical mechanism to the 22
  `napi_*` UND symbols in today's dev-built `.node`.
- **`--exclude-libs` is a scoped list, NOT `ALL`.** lld applies
  `--exclude-libs` to whole-archived members too — `ALL` would demote
  `napi_register_module_v1` and `eco_app_*` to local (verified
  empirically: with `ALL`, all three vanish from `.dynsym` and the
  addon dies with "Module did not self-register"). The list names
  **every archive on the link line except the two whole-archived entry
  libs** (`libEcoEmbedStatic.a`, `libEcoNodeGlue.a`): the
  system/runtime statics AND `libEcoRuntimeStatic.a` + the kernel
  archives. Hiding is **the** correctness mechanism, not hygiene, for
  two reasons found the hard way:
  1. The symbols libc++abi/libunwind share with Node's
     libstdc++/libgcc_s are the *unmangled* ABI surface (`operator
     new/delete`, `__cxa_*`, `_Unwind_*`, the plain-`std::`
     typeinfos) — hidden visibility makes the addon's internal
     references non-preemptible and keeps them out of `.dynsym`. The
     `std::__1` mangling only shrinks the overlap; it is not a second
     safety net.
  2. clang's `__builtin_cpu_supports` (used by srell in
     `ElmKernel_Regex`) emits a direct `R_X86_64_PC32` to
     `__cpu_model`, hard-assuming a link-local definition — legal only
     when the providing archive (compiler-rt builtins) is hidden.
     Hiding the kernel archives kills this entire
     compiler-assumed-non-preemptible class.
  Side benefit: the simulated `.node`'s export surface drops from 1343
  symbols (dev build) to ~327 — most of the D6 follow-up delivered
  early. The program's own symbols (`eco_app_*`,
  `napi_register_module_v1`, `Main_*`…) remain exported.

The embed/glue whole-archive structure (:478-487) is
profile-independent and unchanged.

### 6. Teach the `.js` shim to fail clearly on musl Node

The shim emitted after a `.node` link (`EcoNativeDriver.cpp:611-621`)
currently emits a bare `module.exports = require('./<base>.node');`.
A glibc-ABI addon loaded by musl Node (Alpine) fails there with a raw
loader error. Wrap the require:

```js
try {
    module.exports = require('./elm.node');
} catch (e) {
    if (!process.report?.getReport?.().header?.glibcVersionRuntime) {
        throw new Error("this addon is glibc-ABI; musl-libc Node " +
                        "(e.g. Alpine) is not supported by eco .node " +
                        "outputs", { cause: e });
    }
    throw e;
}
```

(`glibcVersionRuntime` is absent on musl builds of Node — a stable,
documented discriminator.) This is the entirety of v1's musl-Node
"detection"; the link itself cannot know which Node will load the
artifact.

### 7. Smoke tests (release pipeline)

The existing Alpine smoke step (a `RUN` inside the `eco-builder` stage,
docker/static-build.Dockerfile:147-163) cannot exercise `.node`:
Alpine's node is musl — the glibc-ABI addon must not be tested there.
Add a **glibc smoke stage** `FROM debian:bookworm-slim` + NodeSource
Node 22 + gcc, with the embed test sources `COPY`d from the build
context (a JS port-echo harness, `test/embed/echo_host.js`, must be
**added** — today test/embed contains only the C hosts; the node-side
acceptance harness lived out-of-repo in elm-actor-kafka):

1. Extract the tarball; `eco make … --output=build/elm.node` on the
   port-echo program (E2E convention,
   plans/native-ports-and-embedding.md:768-793); run the bounce under
   node **through the generated `.js` shim**; assert round-trip.
2. `readelf` assertions on `build/elm.node`: **no NEEDED, no RUNPATH**
   (libc unlinked ⇒ an empty NEEDED set is expected and correct);
   `DT_TEXTREL` present (the `-z notext` consequence — assert it so a
   silent behavior change is caught); `.dynsym` **must contain**
   `napi_register_module_v1` and `eco_app_start` (the `--exclude-libs`
   scoping regression test) and **must not contain** `curl_easy_init`,
   `zip_open`, `_ZSt9terminatev`, `__cxa_throw`, `_Unwind_RaiseException`
   (the hidden-runtime test).
3. `.so` variant: compile `test/embed/echo_host.c` with host gcc
   against the produced `elm.so` — assert it **fails without `-lm`**
   and succeeds with `-lm` (the addon carries UND `libm` symbols from
   `ElmKernel_Basics`' `<cmath>` use and deliberately has no NEEDED to
   pull libm in; the host contract is explicit, step 8). Run the
   bounce.
4. Alpine side: keep asserting static executables; assert a `.node`
   build *with `lib/eco-runtime/glibc/` deleted* fails with the step 5
   error text; assert `require()` of a glibc `.node` under Alpine node
   produces the step 6 shim message.
5. A second glibc distro (Fedora or Arch container): install bundle,
   build + run the `.node` — proves no Debian-path coupling leaked in.

### 8. Frontend & docs touch-ups (no functional frontend change)

- Update the stale `--output` help text
  (`compiler/src/Terminal/Main.elm:253-258`) to enumerate
  `.js`/`.html`/`.mlir`/`.o`/`.so`/`.node`/executable.
- design_docs/distribution.md: replace the "not glibc-compatible at the
  ABI level … that's Stage A; not in this distribution" paragraph
  (:89-100) with the two-profile contract, the output-kind matrix from
  this plan, and the `.so` host contract (`-lm`, glibc floor from the
  step 2 `GLIBC_FLOOR` record); refresh the layout listing (already
  stale: omits `share/eco/…`, says "24" ElmKernel archives where there
  are 22).

## Affected files (estimated diff)

| File | Change |
|---|---|
| `runtime/third_party/node-api-headers/*` | new — vendored NAPI v8 headers (4 files) |
| `runtime/src/codegen/CMakeLists.txt` | node-headers default to vendored; Stage D constants block in `EcoBootConfig.h` generation; MLIR half gated under `ECO_GLIBC_OUTPUT_RUNTIME` (with HandleLLVMOptions flag replication for the surviving targets) |
| `runtime/src/codegen/EcoBootConfig.cpp` | `hasGlibcOutputProfile()` probe |
| `runtime/src/codegen/EcoNativeDriver.cpp` | `LinkProfile` refactor of `linkExecutable`; glibc-shared recipe (`-z notext`, scoped `--exclude-libs`); replace :409 refusal with capability-gated error; musl-detecting `.js` shim |
| `/work/CMakeLists.txt` | `ECO_GLIBC_OUTPUT_RUNTIME` option gating `compiler/`+`test/`+`ecor`/rapidcheck; zlib vendoring; apt runtime-statics discovery; `eco-glibc-runtime-tree` staging target; `install(DIRECTORY …/glibc)` Bundle rule (before the strip rule) |
| `cmake/GlibcRuntimeAudit.cmake`, `cmake/glibc_floor.sh` | new — PIC trial-link audit (mirrors real-link hiding) + glibc-floor computation |
| `cmake/LLVMLibunwind.cmake` | also search the apt header nest `/usr/include/libunwind/` |
| `docker/static-build.Dockerfile` | self-contained `glibc-runtime` stage `FROM debian:bookworm` + apt; `COPY --from`; `-DECO_GLIBC_RUNTIME_TREE`; new Debian + second-distro smoke stages; banner comment ("Three stages") updated |
| `test/embed/echo_host.js` | new — node-side port-echo harness for the smoke stage |
| `compiler/src/Terminal/Main.elm` | `--output` help text |
| `design_docs/distribution.md` | two-profile ABI contract; host contract; layout refresh |

Deliberately **unchanged**: `docker/llvm-debian.Dockerfile` (stays
dev-environment-only — the release pipeline does not consume it),
`docker/static-dev.Dockerfile` (no new apk packages on either side of
its sync contract with `eco-builder`) and `docker/eco-dev.Dockerfile`
(node headers already present; legacy link recipes untouched) — see
"Build environments".

No functional compiler (Elm) changes (help text only); no codegen or
runtime-representation changes; no invariants touched — the diff is
link-line, shim, and packaging.

## Verification

- `cmake --build build-static --target package` inside the release
  pipeline; tarball size budget grows from <80 MB to **<120 MB**
  (second archive set, debug-stripped).
- Debian smoke stage (step 7) green, including the positive `.dynsym`
  assertions and the `-lm` both-ways check.
- Alpine smoke step still green: static executables, zero NEEDED;
  capability error with `glibc/` removed; shim message under musl node.
- Second-distro smoke green (no Debian-path coupling).
- Dev-build regression: `eco make` of the port-echo program to
  `/tmp/elm.so` on a dev host + compile/run `echo_host.c` against it —
  the legacy recipe path. (Note: no automated test currently matches a
  TEST_FILTER for embed; this is a scripted check until the embed loop
  joins the suite.)
- `eco make --output=app` (executable) byte-identical link line before
  vs after the `LinkProfile` refactor (capture via `eco-boot-native`,
  which exposes `linkExecutable` directly with `--verbose`,
  `runtime/src/codegen/eco-boot.cpp:356-373`). Run the comparison for
  all three legacy profiles: dev glibc-dynamic, dev `ECO_STATIC=ON`
  (Stage A.5), and musl-static.
- eco-dev container regression (the standard dev environment): build
  eco with `--preset build`, produce an executable, a `.so` and a
  `.node`, confirm artifacts and link lines match pre-Stage-D behavior
  (glibc dynamic-PIE + bfd `-shared`); confirm `-DECO_STATIC=ON`
  configure still yields Stage A.5 static-deps executables.
- static-dev container: `.so`/`.node` link fails with the step 5
  capability error; with `ECO_RUNTIME_DIR` pointed at a merged runtime
  dir containing `glibc/`, the link succeeds.

## Decisions log

- **Q1: Two bundles or one?** One. A second glibc bundle
  (stage-c-bundle-runtime.md:396's framing) would duplicate `eco`, the
  kernel package and the examples, and still couldn't produce static
  executables and `.node` from one install. **Resolution: one bundle,
  two link-input trees, one binary.**
- **Q2: Two `eco` binaries (`eco-static` + `eco`)?** No. Both link
  recipes already coexist in every binary (`linkExecutable`'s branches);
  only the selection is constexpr. A dynamic-profile `eco` binary would
  re-inherit configure-time host-path baking (Alpine garbage constants,
  `CMakeLists.txt:1015-1023`). **Resolution: runtime selection in the
  one musl-static binary.**
- **Q3: Where do glibc archives come from?** A Debian builder stage.
  The musl-compiled project archives are PIC
  (`CMAKE_POSITION_INDEPENDENT_CODE ON`, `/work/CMakeLists.txt:7`) but
  compiled against musl headers — cross-libc header/runtime mixing is
  unsupported. **Resolution: full second compile on
  debian:bookworm.**
- **Q4: Link against host libc.so at link time, or leave libc
  undefined?** Probing host libs would reintroduce host assumptions and
  per-distro path knowledge; undefined-at-link is already the proven
  N-API model in this codebase. Consequence to state honestly: the
  output carries **no DT_VERNEED at all** — version checks do not
  exist, a too-old glibc fails only when a referenced symbol is
  entirely absent (clean `dlopen` error), and a symbol that exists
  under an older default binds silently to it. The real floor is
  whatever the newest-introduced referenced symbol is; it must be
  **computed** from the staged archives' UND set (step 2's audit), not
  inferred from the dev-built `.node` (whose `GLIBC_2.34` refs come
  from *its* versioned link against `-lc -lpthread` — they do not
  transfer). Alternative if this ever bites: ship Zig-style stub
  shared objects to restore NEEDED+versioned refs (follow-up).
  **Resolution: leave libc undefined; zero host files consumed at link
  time; floor computed and recorded by the builder.**
- **Q5: Which C++ runtime for the glibc set?** libc++/libc++abi/LLVM
  libunwind, static PIC — symmetric with the musl side, no
  gcc/libstdc++.a dependency. Correctness against Node's
  libstdc++/libgcc_s rests **solely** on hiding these archives via the
  scoped `--exclude-libs` list (the shared symbols are the unmangled
  ABI surface: `operator new/delete`, `__cxa_*`, `_Unwind_*`,
  plain-`std::` typeinfos; hidden ⇒ non-preemptible internal binding +
  absent from `.dynsym`). `std::__1` mangling merely shrinks the
  overlap. **Resolution: as stated; libstdc++ rejected; `ALL` rejected
  (hides the whole-archived N-API/embed entry points — verified).**
- **Q5b: Where do the C++ runtime statics come from?** Apt packages on
  the builder (`libc++-14-dev`/`libc++abi-14-dev`/`libclang-rt-14-dev`/
  `libunwind-14-dev`) — symmetric with the musl side's Alpine apk
  sourcing — NOT a custom LLVM runtimes build. The major-version skew
  vs the musl side's LLVM-21 libc++ is harmless (profiles never
  cross-link; the archives are self-contained in produced outputs);
  PIC-ness is enforced by the staging audit, not assumed (bookworm's
  pass). **Resolution: apt; an earlier eco-llvm-debian coupling was
  removed after challenge — the release pipeline keeps exactly one
  prerequisite image.**
- **Q6: CRT for the shared link?** Ship glibc `crti.o`/`crtn.o` + gcc
  `crtbeginS.o`/`crtendS.o` harvested at Debian configure time (the
  selected "partially shipped" option). `Scrt1.o` deliberately not
  shipped until dynamic executables (phase 2). Licensing: gcc CRT files
  carry the GCC Runtime Library Exception; glibc's carry the linking
  exception — same basis on which toolchains (e.g. Zig) redistribute
  them; record in the bundle's license notes. **Resolution: ship 4 CRT
  objects under `glibc/crt/`.**
- **Q7: Default link kind per output ending?** See "Default-policy
  decision". **Resolution: executables static, `.so`/`.node`
  dynamic-glibc; no `--link` flag until a second legal value exists.**
- **Q8: `--link` flag plumbing (recorded for phase 2).** Five layers:
  flag spec + chomp (`compiler/src/Terminal/Main.elm:236-345`),
  `FlagsData`/`BuildContext` threading
  (`compiler/src/Terminal/Make.elm:87-102,168-273`), the
  `Eco.NativeDriver.lowerAndLink` kernel API + JS stub + Task_Binding
  payload (`eco-kernel-cpp/src/Eco/NativeDriver.elm:46-48`,
  `eco-kernel-cpp/src/eco/NativeDriver.cpp:39-98`), the C ABI
  (`EcoNativeAPI.h:30`, `EcoNativeDriver.cpp:632-647`,
  `eco_native_stub.cpp:21-27`), and `EcoNativeOptions`
  (`EcoNativeDriver.h:23-42`).

## Risk register

- **DT_TEXTREL in shared outputs.** Inherent to loader-applied
  `R_X86_64_64` relocs in `.llvm_stackmaps` (which the embed runtime
  requires applied, `eco_embed.cpp:146-151`). Costs: non-shareable
  dirty pages at load; SELinux `allow_execmod`/`textrel` denials on
  hardened hosts. Today's bfd-linked dev addons already carry it; the
  smoke test pins it. Removing it (rebasing stackmap entries from the
  on-disk section instead) is a follow-up.
- **Non-PIC system archives.** New failure mode unique to `-shared`
  (static executables never cared). Known instance: Debian's `libz.a`
  → vendored. The step 2 PIC audit makes this a build-time failure,
  never a user-visible one.
- **Two C++ runtimes in one Node process.** Mitigated solely by the
  scoped `--exclude-libs` hiding (Q5); the smoke `.dynsym` assertions
  are the regression fence. No exceptions cross the C N-API boundary.
- **TLS under `dlopen`.** The addon defines TLS symbols
  (`Allocator::tl_heap_`, `g_in_minor_gc`; ~10 `thread_local` sites in
  the AOT-linked runtime archives, none in kernels) with
  general-dynamic model (no `-ftls-model` anywhere) — the dlopen-safe
  model. Already flagged and accepted in
  native-ports-and-embedding.md:855-856; the smoke test exercises the
  real loader path.
- **Unversioned libc references.** No DT_VERNEED ⇒ no load-time
  version enforcement (Q4). Mitigation: computed `GLIBC_FLOOR` in the
  bundle + documented; stub-libs follow-up if real-world skew appears.
- **`.so` host contract.** UND `libm` (and on glibc < 2.34, `pthread`)
  symbols with no NEEDED: C hosts must link `-lm`; `dlopen`-style hosts
  must already have libm loaded (Node always does — it NEEDs libm
  itself). Documented in step 8; smoke-tested both ways in step 7.3.
- **Cross-libc behavior skew between `eco` (musl) and its glibc
  outputs.** Precedent: the readdir-ordering incident
  (static-link-eco-binary.md:521-540). The *compiler* stays musl; only
  *produced artifacts* change ABI — same exposure as Stage B.5 already
  accepted for executables, now with glibc semantics on the output
  side, which is what Node hosts expect anyway.
- **Bundle size** roughly +35-50 % (second archive set). Budgeted in
  Verification; the recursive strip glob applies as-is.
- **lld on glibc objects.** The bundled lld is musl-*hosted* but
  target-ABI-agnostic; with `-z notext` it reproduces what bfd does for
  today's working dev addons. Verified end-to-end by the smoke stages.

## Implementation status (2026-06-11)

Implemented in full; every claim below verified in the eco-dev container
unless marked "awaits the docker pipeline".

**Verified here:**

- **Legacy link lines byte-identical** across the refactor for all three
  output kinds (exe PIE / `.so` / `.node`), captured pre/post via
  `eco-boot-native --verbose`. Suite green: **1480/1480** via
  `cmake --build build --target check`.
- **Stage D link recipe end-to-end (hand-simulated)**: a real
  Elm-compiled object (with `.llvm_stackmaps` + `R_X86_64_64`) linked
  with the bundled-recipe arg list against a real staged tree —
  `ld.lld` refuses without `-z notext` (exact predicted error), succeeds
  with it; produced `.node` has **0 NEEDED**, `DT_TEXTREL`,
  `napi_register_module_v1` + `eco_app_start` exported, kernels/curl/zip
  hidden, dynsym 327 vs dev-build 1343.
- **Debian-side archive build E2E, fully decoupled**: configured with
  `env -u CMAKE_PREFIX_PATH` (MLIR provably invisible) and
  `-DLLVM_INSTALL_PREFIX=/usr/lib/llvm-14`, runtime statics discovered
  from freshly apt-installed `libc++-14-dev`/`libc++abi-14-dev`/
  `libclang-rt-14-dev`/`libunwind-14-dev` — i.e. byte-for-byte the
  configuration the docker `glibc-runtime` stage runs. 424 targets
  compiled from scratch; `--target eco-glibc-runtime-tree` staged 43
  archives + 4 CRT objects; **PIC audit passed including the real apt
  libc++/libc++abi/libunwind/builtins statics** (Debian's archives are
  PIC — proven, not assumed); `GLIBC_FLOOR` computed = **2.36**
  (bookworm; higher than the dev `.node`'s 2.34 — vindicates "compute,
  don't infer"). The Stage D link hand-simulation was repeated against
  this real-runtime tree: 0 NEEDED, `DT_TEXTREL`, entry symbols
  exported, runtime hidden, dynsym 308.
- Audit negative test: a non-PIC archive injected into the tree fails
  the trial link with `FATAL_ERROR`.
- Shim: emitted for `.node`, `node --check` clean; glibc branch
  rethrows the original loader error (musl branch is Alpine-smoke
  territory).

**Awaits the docker pipeline (not runnable in this container):**
the Alpine bundle merge + package, both smoke stages, and a real
`.node` echo-bounce under Node from the *installed bundle*. (A dev-eco
`.node` echo round-trip was verified live: elm-aws-codegen built with
`--output=src/elm.node` processed all 30 AWS specs through its ports
under Node 22 and wrote all stubs, exiting cleanly — `node src/index.js`
runs unchanged from the JS target, see the event-loop-liveness fix
below.)

**Event-loop liveness fix (same day):** a native `.node` did not keep
Node alive while the eco thread had work pending — the output port TSFNs
are unref'd ("JS parity": an idle subscription shouldn't pin the loop),
so `node src/index.js` drained and exited before the eco thread posted
its async port output, writing no stubs. The JS target doesn't have this
because it processes ports synchronously on the main thread. Fix
(runtime, not Stage D specific): a `Scheduler` activity hook
(`setActivityHook` / `setLivenessBaseline`, discounting the one embed
lifetime hold) reports busy↔idle transitions; the embed layer forwards
them via a new `eco_set_idle_hook` C ABI; the addon refs a dedicated
keepalive TSFN while busy and unrefs when idle. Result: a batch host runs
to completion and exits on its own (verified: bare `node src/index.js`
processes all 30 specs, writes 20 stubs, exit 0), while a timer/stdin
host still controls lifetime — exact JS parity. Full E2E suite green
(1480/1480) confirms no scheduler regression.

**Two bugs found by the real bundle, fixed (same day):** building the
actual `.deb` and running an elm-aws-codegen `.node` under Node surfaced
two faults the hand-simulation missed because it linked but never
`dlopen`'d the artifact into a process. (1) **`undefined symbol:
atexit`** at load — the recipe links no libc, but `atexit` (and
`at_quick_exit`, `pthread_atfork`, `__stack_chk_fail_local`, old
`__libc_csu_*`) is NOT a dynamic export of `libc.so.6`; it lives only in
`libc_nonshared.a`, the static half of glibc's `-lc` GROUP script.
eco_embed registers an `atexit` teardown hook, so every produced
`.so`/`.node` referenced it with nothing to bind. Fix: ship
`libc_nonshared.a` in the glibc tree and link it (its members call
`__cxa_atexit` + `__dso_handle`, so no NEEDED entry is added). (2)
**libstdc++/libc++ mismatch** — the `glibc-runtime` stage configures
with the `build` preset, which (unlike `release`) doesn't set
`-stdlib=libc++`, so on Debian clang the archives compiled against GCC
libstdc++ (`std::__cxx11`) while the recipe links libc++ (`std::__1`);
the next undefined symbol after `atexit` would have been a libstdc++
ostringstream VTT. Fix: `add_compile_options(-stdlib=libc++)` under
`ECO_GLIBC_OUTPUT_RUNTIME`, matching the musl side. Both verified
end-to-end in-container: the corrected recipe, linked against a
freshly-rebuilt tree, now `require()`s clean under real Node
(`exports: ["Elm"]`) and resolves every symbol under RTLD_NOW once
libc/libm/napi are present. The docker `glibc-smoke` stage's
build-and-run-a-.node step is exactly what catches this class; the
in-container check now also `dlopen`s, not just links.

**Decoupling addendum (same day):** the original implementation made
`eco-llvm-debian` a release prerequisite (runtimes built in that
image). Challenged and removed: the `glibc-runtime` stage is now
self-contained `FROM debian:bookworm` + apt, the MLIR half of the
codegen CMakeLists is gated off in archive-only mode, and
`llvm-debian.Dockerfile` is back to its dev-only form. Validated here
with the real apt packages (see the E2E bullet above). One residual
follow-up: capture a digest pin for the `debian:bookworm` base (no
registry access from this container).

**Deviations from the plan as written:**

- `LinkProfile` is an enum + per-site selection rather than a struct of
  vectors — preserving byte-identical legacy lines took precedence over
  the restructure; the constexpr-implies-profile coupling is gone
  either way.
- `--exclude-libs` list widened to all non-entry archives (see step 5 —
  the `__cpu_model` discovery; most of D6 lands early as a result).
- The PIC audit trial links each archive **with the tree's compiler-rt
  builtins and `--exclude-libs=ALL`** to mirror the real link's
  preemptibility — a lone-archive trial false-fails on `__cpu_model`.
  Verified it still hard-fails genuinely non-PIC objects.
- Debian's `libz.a` actually *passes* the preemptibility-corrected
  trial (its PC32-vs-`z_errmsg` failure was preemption-class, fixed by
  hiding) — the risk-register claim "every shared link fails" was
  overstated. Vendored zlib kept anyway: guaranteed PIC, version-pinned
  to bookworm's 1.2.13.
- Floor computation lives in `cmake/glibc_floor.sh` (separate file;
  CMake-string escaping of the awk pipeline was unmaintainable) and
  joins under `LC_ALL=C`.
- `ECO_GLIBC_LLVM_RUNTIMES_DIR` defaults via `LLVM_INSTALL_PREFIX` with
  an `/opt/llvm-mlir` fallback (the `build` preset doesn't set the
  prefix).
- Vendored Node-API headers taken from Node v22.22.3 (MIT; NAPI ≥ 8
  satisfied; see runtime/third_party/node-api-headers/README.md).
- `test/embed/echo_host.js` adapts to PortEchoTest's actual
  program-initiated-echo semantics (documented in its header): assert
  the init-time `echoOut 42` round-trip + silent-drop contract for
  sends after the program unsubscribes.
- Drive-by fix (pre-existing, unrelated): `test/elm/elm.json` had
  `elm/json` only as an *indirect* dependency, so the recently added
  `JsonEncodeBigStringTest.elm` (`import Json.Encode`) could never have
  compiled; promoted to direct. Its stale per-target caches needed an
  `eco-stuff` clear (the known corrupt-cache-on-dep-change class).
- A.5 (`ECO_STATIC=ON` glibc exe) link line was code-reviewed, not
  byte-diffed — no pre-change baseline existed in this container; its
  branches reduce to the same `hostProfile`/`ecoStatic` predicates as
  the diffed dev profile.

## Follow-ups (separate plans)

- **Dynamic-glibc executables + `--link` flag** (phase 2): `Scrt1.o` +
  `libc_nonshared.a` shipping, host `libc.so.6` probing, the Q8
  plumbing, and `--link=static|dynamic` validation per output kind.
- **TEXTREL removal**: stop relying on loader-applied absolute relocs
  in `.llvm_stackmaps` (parse on-disk values and rebase by the module
  load bias), then drop `-z notext`.
- **Export trimming (D6)**: version script limiting `.node` exports to
  `napi_register_module_v1` + `eco_*`; today's 1343-symbol surface
  rides on top of the scoped `--exclude-libs`.
- **Glibc floor management**: stub shared objects (Zig approach) for
  NEEDED+versioned refs, and/or building the glibc set on bullseye
  (2.31) or a manylinux-style sysroot to lower the floor.
- **musl-hosted Node**: a third, musl-dynamic profile — only if demand
  materializes.
- **Embed E2E in the test suite**: wire `test/embed/echo_host.{c,js}`
  into an automated target so dev-build regressions of the legacy
  shared recipe are caught by CI, not scripts.
- **`.o` output documentation**: profile-neutral relocatable objects
  are quietly useful (host-side linking into arbitrary toolchains);
  document the contract.
