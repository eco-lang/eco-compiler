---
status: partial
updated: 2026-11-17
remaining: "CI on ci/llvm-24-upgrade: llvm-build must publish the four LLVMs first (hours), then linux-aot, mac-aot and win-aot green, with whatever musl/macOS/Windows fixes they turn up; GHCR package visibility; the LLVM 21 vs 24 benchmark; merge; then delete the old 21.1.8 Actions caches and retire lib-max-spike; decide on a version.txt bump"
---

# The LLVM 24 upgrade, and MAX as a dependency

## Implementation status (2026-11-17)

Implemented on `ci/llvm-24-upgrade` (one branch, at the user's direction: P1-P4 together, not P1
on master first):

- **§1 pinning:** `deps/versions.env`, `deps/max/` (pyproject, `uv.lock`, `.python-version`),
  `scripts/deps.sh` (show, get, max, llvm, follow-max, uv, python, lock, check, max-pin,
  latest-max, artifact). `cmake/EcoVersions.cmake` reads the pins. uv's `required-version` is a
  minimum (`>=`); images and CI install exactly `UV_VERSION`.
- **§2 publishing:** `.github/workflows/llvm-build.yml` replaces the four per-platform LLVM
  workflows; `.github/actions/fetch-llvm` is what every consumer uses. **Deviation:** the macOS
  and Windows trees are OCI artifacts on GHCR (pushed and pulled with ORAS), not GitHub Release
  assets: one registry and one login for all four, no 2 GB asset limit, and no `llvm-*`
  prereleases on the releases page. Artifact names are `<commit>-<recipe hash>`, so a recipe
  change builds anew and nothing is overwritten.
- **§3:** `cmake/EcoLlvmPin.cmake` (both checks, tested), slim `FROM scratch` LLVM images,
  `eco-dev` taking `LLVM_IMAGE`/`LLVM_COMMIT`/`UV_VERSION` without defaults (uv from Astral's
  image, no install script), `local-dev/build-images.sh`, `dev.sh`'s label check. The `-git`
  Dockerfiles are gone.
- **§4:** recipes on the commit (Alpine, macOS and Windows by shallow fetch; Windows with
  long paths and no CRLF conversion); docs and presets point at `deps/versions.env`; the
  vendored LLVM libc keeps its own 21.1.8 pin. Not yet built on musl, macOS or Windows: CI will.
- **§5 MAX:** settled in P2: the `max` wheel alone suffices (it pulls `max-core`, `mojo-compiler`
  and `max-mojo-libs`; about 600 MB); `libmax` is in `site-packages/modular/lib`, the C headers in
  `site-packages/max/include`. `cmake/EcoMax.cmake` (`ECO_MAX` AUTO/ON/OFF; OFF in every release
  and Windows preset), `runtime/src/max/` (`MaxLoader`, `MaxVerify`), `test/max/`
  (`max-smoke-test`, 15 checks, in `full` when MAX is on; CI requires it on Linux and macOS).
  **Finding for the guard:** parsing with eco's MLIR is not enough. Bytecode that eco's MLIR
  writes for MAX ops with properties parses in eco but makes MAX's reader fail and then
  segfault; MAX accepts the same graph with properties as plain attributes. So `verifyModule`
  refuses properties on MAX ops in bytecode, and refuses MAX's custom syntax (eco can't parse
  it; generic form only).
- **§6:** both deprecations migrated: 1,139 `create<Op>` calls, and 14 ops' formats to
  `prop-dict` (210 fixture lines and the `Ops.td` examples moved to `<{...}>`); the legacy flag is
  gone. `docs/llvm-pins.md` logs it.
- **§7:** `test/scripts/upgrade-gates.sh`. **§10.6:** `.github/workflows/max-watch.yml`.
- **Linux gates, 2026-11-17** (everything above in place): `full` 3091/3091, JS 265 (8 skipped),
  node-addon, driver CLI, MAX smoke 15/15, elm-tests 21,510/0, the 9-stage bootstrap with both
  fixed points, and AOT E2E with no unexpected failures. Gate B leaves about 20 GB of test
  binaries; the first run filled the disk and failed 407 tests at their compile step, all of which
  pass on a re-run with space (`upgrade-gates.sh` now clears them first and checks for 25 GB).
- **Unplanned:** the `eco-tensor` E2E suite (the-sett/elm-max's programs on native code) is
  removed: its sources, `spikes/max/tensor-e2e`, left with the spike and are in neither this
  repository's history on GitHub nor the elm-max repository, and their absence stopped configure.

## Goal

1. Move all of eco (Linux glibc, Linux musl static and release, macOS, Windows, CI, dev images,
   docs) from LLVM 21.1.8 to the llvm-project commit that Modular MAX pins, so eco and MAX share
   one LLVM/MLIR.
2. Bring MAX into eco as a pinned build dependency, fetched as its Python package with uv, ready
   for eco to consume tensor work directly. Today eco only reaches MAX through the elm-max
   package; nothing in eco links or loads it.
3. Pin both LLVM and MAX in one small, easily edited place, so that version upgrades are routine,
   and a MAX patch or minor release is as cheap as it can be.

## Where things stand

**The port.** The `lib-max-spike` branch builds eco against
`8d4fc8f1d17e64e1826346a0230a87b50ec371e4` (`24.0.0git`, MAX 26.7.0's pin) on Linux glibc only.
It needed 8 API fixes (strict-properties legacy flag, `eco.global` symbol trait and visibility
accessors, Required/OptionalPassInfoMixin, PassInstrumentation `Any` -> `IRUnitRef`,
`BranchInst` -> `CondBrInst`, `lookupTarget(Triple)`, the JIT `ObjectLinkingLayerCreator`
signature, `make_scope_exit` -> `llvm::scope_exit`) plus test-harness fixes so runners use their
own `BUILD_DIR`. Gates passed 2026-11-10: bootstrap (both fixed points), `full` 3091/3091, JS 265,
node-addon, driver-cli. The code is LLVM-24-only (`Ops.td` sets a field LLVM 21 lacks), so every
platform must move together. Still pending: the LLVM 21 vs 24 benchmark on the benchmark machine.
git does not work inside the dev container (the worktree's `.git` points at a host path), so
branch work happens on the host.

**LLVM appears in 30-odd places.** Four LLVM build recipes (`docker/llvm-debian.Dockerfile`,
`docker/llvm-alpine.Dockerfile`, `experiments/mac-llvm-build/build.sh`,
`experiments/win-llvm-build/build.ps1`) plus the spike's `llvm-debian-git` and `eco-dev-llvm-git`
Dockerfiles; seven workflows' env, cache keys and step names; default image tags in `eco-dev`,
`static-dev`, `static-build`; `CMakePresets.json` descriptions; `Readme.md`, `docs/building*.md`
and code comments. LLVM builds live in the Actions cache: branch-scoped, evicted after 7 idle days
(hence four weekly "safety touch" crons), inside a 10 GB budget shared with ccache.

**MAX packaging (PyPI, checked 2026-11-17).**

- `max` is the engine wheel: CPython 3.10-3.14, `manylinux_2_34` x86_64 and aarch64, and macOS 13+
  arm64. No Windows, no musl. About 290 MB.
- `modular` is a meta-package: `max[benchmark]`, `max[serve]` and `mojo` at matching versions. The
  spike installed `modular==26.7.0` on Python 3.11, which pulls in serving and benchmarking
  extras eco doesn't need.
- Versions are `YY.N.P`: 25.3 ... 25.7, 26.1 ... 26.7, with one patch release so far (25.6.1).
- `libmax` has a C API (`M_compileModelSync` and friends) under the MAX License: object-code
  redistribution under its terms, telemetry on by default (`MODULAR_TELEMETRY_ENABLED=0` stops
  it).

**MAX's LLVM pin** is in `bazel/public-patches/llvm_source.bzl` of github.com/modular/modular.
MAX bumps it almost weekly; each release carries a new one. Releases come every 5-7 weeks:

| MAX    | Date       | LLVM pin   |
|--------|------------|------------|
| 26.5.0 | 2026-08-11 | 21b0fc84c2 |
| 26.6.0 | 2026-09-17 | 4154b56ccc |
| 26.7.0 | 2026-10-22 | 8d4fc8f1d1 |

The pin file only exists from 26.5 on (earlier MAX wasn't buildable from source), so there's no
history of what a patch release does to it. A patch release is expected to keep its minor's pin;
the tooling below checks rather than assumes.

## Decisions taken

- Master moves to MAX's LLVM commit on every platform (not a release on master with MAX's commit as
  an option).
- eco pins a **MAX version**, and the LLVM commit follows from it. We move when we want a new MAX,
  not on MAX's release schedule.
- MAX comes from PyPI through uv.

## 1. Version pinning

### 1.1 `deps/versions.env`: the one place versions are written

```sh
# Versions eco builds against. Edit with scripts/deps.sh, not by hand.

# Modular MAX, from PyPI (deps/max/ holds the uv project and lock).
MAX_VERSION=26.7.0

# llvm-project commit. LLVM_FOLLOWS=max: must equal MAX_VERSION's pin
# (scripts/deps.sh check enforces it). LLVM_FOLLOWS=independent: set by hand.
LLVM_FOLLOWS=max
LLVM_COMMIT=8d4fc8f1d17e64e1826346a0230a87b50ec371e4

# Tools that fetch the above.
UV_VERSION=0.13.5
PYTHON_VERSION=3.11
```

Plain `KEY=VALUE` lines, because every consumer can read that without a parser:
- shell (`. deps/versions.env`);
- CMake (`file(STRINGS)`);
- GitHub Actions (`cat deps/versions.env >> "$GITHUB_ENV"`);
- PowerShell (a two-line split);
- Docker builds (via `--build-arg`, passed by the scripts and workflows that run them).

`LLVM_COMMIT` is always 40 hex digits; a release tag is resolved to its commit when it's set, so
everything downstream keys on one kind of value.

### 1.2 `deps/max/`: the uv project for MAX

- `pyproject.toml`: `requires-python` from `PYTHON_VERSION`, `dependencies = ["max==26.7.0"]` (or
  the minimal set P2 finds; see 5.1), with `[tool.uv]` pinning `required-version` to `UV_VERSION`.
- `uv.lock`: committed, with hashes, so every machine and CI leg installs byte-identical wheels.
- `.python-version`: uv fetches its own Python, so the host's Python doesn't matter.

`scripts/deps.sh` writes the pins into `pyproject.toml` from `versions.env` and re-locks, so
`versions.env` stays the only file anyone edits.

### 1.3 `scripts/deps.sh`

- `show`: every pin, plus whether this machine's LLVM install and MAX env match them.
- `max <version>`:
  1. Set `MAX_VERSION` and re-lock `deps/max/` (`uv lock`).
  2. Read the LLVM pin at `max/v<version>`; with `LLVM_FOLLOWS=max`, set `LLVM_COMMIT` to it.
  3. Report one of two outcomes:
     - "LLVM unchanged: no LLVM rebuild, no port", or
     - "LLVM moves `<old>` -> `<new>`: LLVM builds and a port follow".

  If the pin file has moved in modular's repo, it fails loudly.
- `llvm <commit|llvmorg-tag>`: set `LLVM_COMMIT` by hand, which requires `LLVM_FOLLOWS=independent`.
- `uv <version>`, `python <version>`: tool bumps, re-locking as needed.
- `check`: fails when any of these hold:
  - `LLVM_COMMIT` doesn't match MAX's pin under `LLVM_FOLLOWS=max`;
  - `deps/max/` is out of step with `versions.env`;
  - a version is hard-coded anywhere else: a llvm-project commit, an `llvmorg-` tag, `21.1.8`,
    or a MAX version. An allowlist covers historical plans and benchmark logs.

  It runs in linux-aot's lint step.

### 1.4 Consumers

| Consumer | Reads | Uses |
|---|---|---|
| `llvm-*.Dockerfile`, mac/win LLVM scripts | `LLVM_COMMIT` | shallow fetch of the commit, verified with `rev-parse`; writes `<prefix>/ECO_LLVM_COMMIT` |
| `llvm-build.yml`, `-aot` workflows | all | artifact names, cache keys, `paths` filters (`deps/**`) |
| CMake | `LLVM_COMMIT`, `MAX_VERSION`, `UV_VERSION` | install checks (section 3), the MAX env (section 5) |
| `local-dev/build-images.sh`, `dev.sh` | `LLVM_COMMIT`, `UV_VERSION` | image tags and checks |
| docs, preset descriptions | none | say "the versions in `deps/versions.env`" |

### 1.5 What each upgrade costs

| Upgrade | Edit | LLVM rebuild | Code port | Images |
|---|---|---|---|---|
| MAX patch, same LLVM pin (expected) | `deps.sh max 26.7.1` | no | no | no; reconfigure re-syncs the MAX env |
| MAX minor (new LLVM pin) | `deps.sh max 26.8.0` | yes, automatic | usually 0-2 API fixes | `build-images.sh` pulls the new LLVM |
| uv or Python | `deps.sh uv ...` | no | no | eco-dev rebuild for uv |

LLVM artifacts are keyed by commit, never by MAX version. So a MAX release that keeps its pin
reuses every LLVM build already published, and only the uv env changes.

## 2. LLVM builds published per commit

Replace the Actions-cache LLVM entries with artifacts any branch can read, built once per commit:

- **Linux:** images `ghcr.io/eco-lang/eco-llvm-debian:<commit>` and
  `ghcr.io/eco-lang/eco-llvm-alpine:<commit>`.
- **macOS and Windows:** the install trees as `.tar.zst` assets on a prerelease tagged
  `llvm-<commit12>`. Check that the Windows tree compresses under the 2 GB per-asset limit, and
  split it if not.

`llvm-build.yml` (`workflow_dispatch`, plus a push trigger on `deps/versions.env`) replaces the
four `*-llvm-build` workflows. It runs a four-way matrix, and each leg skips when its artifact for
the commit already exists. The `-aot` workflows pull the artifact for `LLVM_COMMIT`; if it's
missing they fail with "run llvm-build for `<commit>`". Alpine keeps whatever measures its current
workflow uses against the hosted runner's out-of-memory failures (it has no inline fallback today).

Results:
- **One build per commit.** A bump tested on a `ci/` branch is reused unchanged by master after
  the merge.
- **No LLVM in the Actions cache.** The four keep-alive crons go, and ccache and the MAX env cache
  get the budget.
- **Fast new dev boxes.** A new box pulls LLVM in minutes instead of building it for an hour.

## 3. Builds and images tied to the pins

- **CMake guard.**
  - Configure fails when the found LLVM's `ECO_LLVM_COMMIT` differs from `LLVM_COMMIT`, naming
    both and the fix.
  - It records the commit in the cache. A later configure of the same tree that finds another
    commit fails with "this build tree was configured against `<old>`; delete it and
    reconfigure". This prevents LLVM 21 and LLVM 24 objects getting mixed in one tree.
- **One Linux image chain.**
  - `llvm-debian.Dockerfile` and `llvm-alpine.Dockerfile` take `LLVM_COMMIT`. The spike's
    `llvm-debian-git` and `eco-dev-llvm-git` variants go.
  - `eco-dev`, `static-dev`, `static-build` and `eco-dev-genmc` take the LLVM image by commit and
    carry the label `org.eco.llvm.commit`.
  - `eco-dev` gets uv by `COPY --from=ghcr.io/astral-sh/uv:<UV_VERSION>`, with no installer
    script. `UV_CACHE_DIR` sits on the home volume, so MAX wheels download once per box.
- **`local-dev/build-images.sh`** reads the pins, pulls the LLVM images (or builds them with
  `--local`), then builds `eco-dev` and `eco-local-dev`.
- **`dev.sh`** compares the image label with `LLVM_COMMIT`, and stops with the rebuild command
  when they differ.

A new box is then: clone, `local-dev/build-images.sh`, `dev.sh`.

## 4. The LLVM 24 port across eco

### 4.1 Code

Rebase `lib-max-spike` onto master (on the host) and take only the port. That's the 8 API fixes,
the `Ops.td` change and the test-harness `BUILD_DIR` fixes. Leave out the spike's other work.
Re-run the Linux gates after the rebase, because master has moved since the branch point.

### 4.2 Linux glibc

Done on the branch. Remaining: build from the published image, and run the gates (section 7).

### 4.3 Linux musl (static `eco`, release builds)

- Build the Alpine LLVM at the commit (musl + libc++).
- `static-build.Dockerfile` and `static-dev.Dockerfile` follow the new image.
- Check the tag-built release path (`release.yml`) end to end on a `ci/` branch.

### 4.4 macOS arm64

- `mac-llvm-build/build.sh` fetches the commit instead of the 21.1.8 tarball.
- Expect AppleClang/ld64 issues in eco's port, both in the trunk LLVM build and in eco's code.
- Re-check `check-macho-floor.sh` (the macOS 15.0 floor), the `mac-release` bundle, and the JIT
  unwind handling, which has been fragile on macOS before. The ORC signature change touches it.

### 4.5 Windows

- `win-llvm-build/build.ps1` fetches the commit.
- Building a trunk snapshot of LLVM with clang-cl and /MT is the riskiest leg: Windows bugs at an
  arbitrary trunk commit are likelier than at a release.
- Re-check the COFF JIT path and the Windows bundle.
- MAX is not involved: there's no Windows wheel.

### 4.6 Docs and comments

`Readme.md`, `docs/building.md`, `docs/building-macos.md`, `docs/building-windows.md`, the
`CMakePresets.json` descriptions, and the comments in `runtime/src/codegen/CMakeLists.txt` and
the Dockerfiles: replace version numbers with a pointer to `deps/versions.env`. Historical plans
and benchmark logs stay as written.

### 4.7 Vendored LLVM libc

`runtime/third_party/llvm-libc` (musl memcpy and friends) is verbatim source, independent of the
LLVM eco links. Keep it at 21.1.8. Reword its README ("the same release as eco's LLVM") so it
reads as its own pin, refreshed only for performance reasons.

### 4.8 Performance

Run the pending LLVM 21 vs 24 benchmark on the benchmark machine before the merge, on both
compile time and the runtime benchmarks. The cold-versus-warm trap in Stage 7a is documented;
compare like with like.

## 5. MAX as a dependency

### 5.1 What gets installed

The smallest package set that gives `libmax`, its C API and what graph compilation needs at run
time. That's `max` alone, or `max` plus `mojo` if compiling kernels needs it. P2 establishes which,
by installing each set into an empty env and compiling the spike's MNIST graph through the C API.
`modular` (what the spike used) also pulls the serving and benchmarking extras, so avoid it unless
that test needs it. Also establish where the C API headers come from: the wheel, or modular's
repository at the tag. If they come from the repository, vendor them under `deps/max/include/`
at the tag, recording provenance as for llvm-libc.

### 5.2 Platforms

`ECO_MAX` is a CMake option: `AUTO` (the default), `ON` or `OFF`.
- `AUTO` turns it on where wheels exist: Linux glibc x86_64/aarch64 (Debian bookworm's glibc 2.36
  meets `manylinux_2_34`) and macOS arm64.
- It's off on Windows and in the static musl build. A static musl binary can't load a glibc
  library.
- When eco gains MAX-backed features, a program that needs them on a profile without MAX gets
  eco's friendly "this profile can't build that" error with a fix-it link, the same as other
  profile limits. It's never a silent fallback.

### 5.3 Build integration

`cmake/max.cmake`, used when `ECO_MAX` is on:

- Checks `uv --version` against `UV_VERSION`.
- Runs `uv sync --frozen --project deps/max` into `build/toolchain/max/`. uv hardlinks from its
  cache, so a second build tree costs little.
- Provides an `Eco::MaxCApi` interface target (include dirs only, no link).
- Generates `max_config.h`: `MAX_VERSION`, the env's location, and the paths the `MODULAR_*`
  variables need.
- Reconfiguring after `deps.sh max ...` re-syncs the env. That's the whole of a MAX patch upgrade.

### 5.4 Run-time loading

`runtime/src/max/MaxLoader.{hpp,cpp}` loads `libmax` with `dlopen` on first use rather than
linking it:
- eco and its programs start without a 290 MB library;
- builds without MAX link unchanged;
- eco never ships MAX code.

The loader:
- resolves the C API symbols it uses, and fails with a clear message if any is missing;
- sets `MODULAR_MAX_PACKAGE_ROOT`, `MODULAR_MOJO_MAX_PACKAGE_ROOT` and
  `MODULAR_MOJO_MAX_IMPORT_PATH` from the env;
- sets `MODULAR_TELEMETRY_ENABLED=0` unless the user has set it;
- sets the two busy-wait variables (`MODULAR_THREAD_BUSY_WAIT_US`,
  `MODULAR_RUNTIME_THREAD_BUSY_WAIT_TIME_US`) together or not at all, because setting one alone
  aborts MAX;
- checks the loaded MAX's version against `MAX_VERSION` and refuses a mismatch by name.

`M_compileModelSync` segfaults on IR it can't parse, so eco verifies every module before handing
it to MAX (structural MLIR verification; MAX's dialects are unregistered in eco). Locating MAX for
an installed eco, outside a build tree, is left to the plan that adds the first user-facing MAX
feature; until then, MAX is a build and test dependency.

### 5.5 Tests

`MaxSmokeTest`:
- loads MAX through the loader;
- compiles and runs a small graph written as MLIR bytecode (an add and a matmul), and checks the
  numbers;
- checks the bad-IR guard: a deliberately broken module must be rejected before MAX sees it.

It runs wherever `ECO_MAX` is on: the Linux glibc gate job and mac-aot. Those two get
`astral-sh/setup-uv` at `UV_VERSION` and an Actions cache of the uv cache keyed on `uv.lock`
(about 300 MB per platform, affordable once LLVM leaves the cache). Windows and the musl jobs skip
it, and their logs say why.

### 5.6 Licence and distribution

eco's releases and bundles don't contain MAX: it's fetched from PyPI on the machine that uses it,
under the MAX License. eco's README states this, along with the telemetry default.

### 5.7 Out of scope

Which tensor features move into eco, and how; the elm-max package and its examples (a separate
repository, which keeps its own `modular==` pin in step by hand); GPU.

## 6. Keeping future bumps small

- **Migrate APIs before upstream removes them.** The port left two deprecated APIs in place:
  - about 3,300 `builder.create<Op>(...)` calls (the new form is `Op::create(builder, ...)`);
  - 11 ops still on the legacy prop-dict assembly format (`useStrictPropertiesInAssemblyFormat =
    0`).

  Each removal would land as one large break in whatever bump it falls in. Migrating them in
  mechanical, separately reviewable commits keeps every bump small.
- **`docs/llvm-pins.md`** logs each bump: the MAX version, LLVM commit, date, and the API changes
  it needed. The first entry is the 8 fixes above.

## 7. Gates

`test/scripts/upgrade-gates.sh` runs once, with output teed:
1. a fresh configure;
2. `check`;
3. `full`;
4. the 9-stage bootstrap;
5. `MaxSmokeTest`;
6. the MAX interop smoke test: the spike's `check-bytecode`, and MNIST, expecting the known exact
   results.

That's the Linux acceptance test for any upgrade. The three `-aot` workflows (with
`MaxSmokeTest` on Linux and macOS) cover the rest.

## 8. Phases

- **P1, pinning and publishing on LLVM 21.1.8.** Land sections 1-3 on master with
  `LLVM_FOLLOWS=independent` and `LLVM_COMMIT` at 21.1.8's commit. LLVM doesn't change, so CI
  staying green proves the new plumbing. Then delete the old LLVM Actions-cache entries and the
  keep-alive crons.
- **P2, MAX as a dependency.** Section 5 on master. It doesn't need LLVM 24: nothing passes MLIR
  through eco's LLVM to MAX yet. P2 and P3 can run in parallel.
- **P3, LLVM 24.** On `ci/llvm-24`:
  1. `deps.sh max 26.7.0` with `LLVM_FOLLOWS=max`. If 26.8 is out by then, use it and skip
     `8d4fc8f1`.
  2. `llvm-build` builds the four LLVMs.
  3. Port the code (section 4.1), then work through the platform legs (4.3-4.5) until all three
     `-aot` workflows are green on the branch.
  4. Update the docs (4.6), run the benchmark (4.8) and the gates.
  5. Merge. Master reuses the branch's LLVM artifacts.
  6. Retire `lib-max-spike`.
- **P4, deprecation cleanup.** Section 6.

## 9. A routine upgrade afterwards

1. On a `ci/` branch, run `scripts/deps.sh max <version>`, then push.
2. If LLVM is unchanged: the uv env re-syncs and the gates run. That's a one-commit change.
3. If LLVM moves: `llvm-build` runs unattended; locally run `local-dev/build-images.sh`, fix the
   API breaks, and log them in `docs/llvm-pins.md`.
4. Run `test/scripts/upgrade-gates.sh`; the `-aot` workflows go green; merge.
5. Other dev boxes are told by `dev.sh`, and fixed by `build-images.sh`.

## 10. Decisions for the user

1. **Publishing LLVM builds** publicly under eco-lang on GHCR and GitHub Releases. LLVM's
   Apache-2.0 with LLVM exception allows it, with the licence included. The fallback is the
   Actions cache, which keeps the double build after each merge and the cache-budget pressure.
2. **Workflow edits.** P1 replaces the four LLVM workflows and the LLVM steps of the `-aot`
   workflows; P2 adds uv and MAX steps to linux-aot and mac-aot.
3. **MAX telemetry** off by default in eco (proposed above).
4. **No MAX on Windows or in static musl builds.** No wheel exists for either, so tensor features
   will be glibc and macOS only, unless a second engine comes later.
5. **The first release on LLVM 24:** whether it warrants a version bump in `version.txt`.
6. **Watching MAX (optional):** a cheap scheduled job, with no builds, that opens an issue when a
   new `max/v*` tag appears, giving its LLVM pin and whether it differs from ours.

## Risks

- **Windows on a trunk snapshot** (4.5) is the leg most likely to need upstream patches. If it
  blocks, the fallback is to pick the nearest MAX release whose pin builds there, which this plan's
  tooling makes a one-line change.
- **MAX's pin file may move** in modular's repository; `deps.sh max` fails loudly rather than
  guess.
- **MAX patch releases may move the pin.** That's unknown, with one data point; the tooling
  reports it either way, and the cost is an LLVM build, not a surprise.
- **The ~2 GB per-asset limit** on GitHub Releases for the Windows LLVM tree.
