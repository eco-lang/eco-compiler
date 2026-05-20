# Migrate npm Build to pnpm + Move Elm Toolchain into CMake

## Goal

Reduce the supply-chain surface and operational complexity of the JavaScript
build dependencies in `compiler/`. The lever isn't really "npm vs. pnpm" — it's
two underlying problems that pnpm only partially addresses:

1. The dev-dep tree contains tools (`jest`, `npm-run-all`, `onchange`,
   `uglify-js`, `terser`, `indexeddb-fs`) that aren't exercised by any code
   path CMake actually invokes, but they still get installed and execute
   lifecycle scripts on every `npm ci`.
2. The Elm toolchain binaries (`elm`, `elm-format`, `elm-test-rs`,
   `elm-review`, `guida`) are distributed as npm packages whose `install`
   script is a `binwrap`-style downloader. Each one runs arbitrary code at
   install time and fetches a platform-specific binary from a third-party
   host. Pinning their npm `package-lock.json` SHA pins the tiny wrapper, not
   the binary that actually lands on disk.

So the trajectory is:

- **Phase A** — prune dead devDeps. No tool changes; just shrink the tree
  before we touch the package manager.
- **Phase B** — move the five Elm-toolchain binaries out of npm into
  CMake `FetchContent` with per-platform pinned SHAs. After this, the only
  remaining npm deps are real Node libraries that are linked into the
  generated runner code.
- **Phase C** — switch the residual npm dep tree to pnpm with
  `ignore-scripts=true` and frozen-lockfile installs. With Phase B done, the
  remaining tree is small enough that strict resolution is cheap and the
  install-scripts gate doesn't break anything.

The plan covers `compiler/package.json` only. The other three `package.json`
files in the repo (`elm-io-lib/`, `elm-io-ports-example/`,
`compiler/elm-coverage/`) are out of scope — see Resolutions below.

## Resolutions (from review)

| Question | Decision |
|---|---|
| `compiler/elm-coverage/` in scope? | **No.** It's used for the manual coverage workflow (`guides/test-coverage-howto.md`) and depends on binwrap install scripts. It stays on npm, scoped under its own subdirectory, and is not touched by this plan. |
| `elm-io-ports-example/` and `elm-io-lib/` in scope? | **No.** Out of scope; address in a follow-up if needed. |
| Platform support | **Linux x86_64 only.** Matches `CMakePresets.json`. macOS/Windows deferred. |
| CMake wrapper target for `elm-test-rs` | **Yes.** Add `cmake --build build --target elm-tests` that invokes the fetched binary with `--project ${BUILD_XHR_DIR}`. |
| `guida` binary source | **N/A — drop the dep.** We build guida.js ourselves with the stock elm compiler; the npm `guida` wrapper is unused. Drop in Phase A. |
| Vendor runtime libs? | **No — overkill.** But audit which are actually needed (see below). |
| Runtime library audit | `jszip` is only `require()`'d by `lib/index.js`, which is itself only reachable via the dead `build.sh api` code path (CMake doesn't touch it). **Drop `jszip` in Phase A.** The remaining five (`adm-zip`, `form-data`, `mock-xmlhttprequest`, `tmp`, `which`) are exercised by `bin/index.js`, `bin/eco-boot-runner.js`, `bin/eco-io-handler.js`. `lib/index.js` itself is left as-is; removing it is a separate cleanup. |
| `elm-review` under `ignore-scripts=true` | **Try it empirically.** If it breaks, drop `elm-review` from devDeps (it's lint-only, not on the build hot path). |
| Phasing | **One PR, internally phased A → B → C.** |
| Interim `--ignore-scripts` for `npm ci` | **No, not before Phase B.** Today's `npm ci` *needs* install scripts to run — that's how `node_modules/.bin/elm` (and friends) get downloaded via binwrap. Adding `--ignore-scripts` to the current CMake invocation would break Stage 1. Once Phase B removes the binwrap wrappers, `--ignore-scripts` becomes safe; Phase C bakes it into `.npmrc`. |
| Lock-file commit policy | **Commit `pnpm-lock.yaml`.** That's pnpm's expected workflow with `frozen-lockfile=true`. |

## Evidence from current state

### `compiler/package.json` script inventory

| Script | Invoked by CMake? | Invoked by docs/CI? | Status |
|---|---|---|---|
| `build` | No | No | Dead — wraps `build:*` |
| `build:bin` | No | No (CMake calls `elm make` directly) | Dead |
| `buildself` | No | No (CMake reimplements Stages 2–8) | Dead |
| `watch` | No | Developer convenience | Optional — could move to a Makefile/justfile |
| `test` | Indirectly (CMake calls `elm-test-rs` directly via `cmake --build … --target check` paths) | `cd compiler && npx elm-test-rs …` is in CLAUDE.md | Keep but rewrite — `elm-test-rs` becomes CMake-fetched |
| `elm-format` | No | Developer convenience | Optional — could be a CMake target |

Confirmed by `compiler/CMakeLists.txt`: stages 1–8 are driven directly via
`${ELM_EXECUTABLE}` (line 64), `${NODE_EXECUTABLE} bin/index.js make` (line
120), and `${NODE_EXECUTABLE} bin/eco-boot-runner.js make` (lines 144, 174,
213). Only `npm ci --prefer-offline` (line 53) ever runs a package manager.

### `compiler/package.json` dependency usage

Runtime (`require()`d by `bin/*.js`, `lib/*.js`, or `scripts/replacements.js`):

| Package | Used by |
|---|---|
| `adm-zip` | `bin/eco-boot-runner.js:27`, `bin/eco-io-handler.js:28` |
| `form-data` | `bin/eco-boot-runner.js:30` |
| `jszip` | `lib/index.js:2` (XHR-mode build only) |
| `mock-xmlhttprequest` | `bin/index.js:3`, `bin/eco-boot-runner.js:31`, `lib/index.js:1` |
| `tmp` | `bin/eco-boot-runner.js:29` |
| `which` | `bin/eco-boot-runner.js:28`, `bin/eco-io-handler.js:29` |

Not `require()`d anywhere:

| Package | Listed in | Confirmed dead? |
|---|---|---|
| `indexeddb-fs` | `dependencies` | Yes — `grep require\(['\"]indexeddb-fs\` returns nothing |
| `terser` | `dependencies` | Yes — no require, no shell invocation |
| `uglify-js` | `devDependencies` | Yes — only appears in `scripts/build-self.sh:49` inside a commented-out line |
| `jest` | `devDependencies` | Effectively yes — no jest tests exist; only used by `eslint-plugin-jest` for lint rules |
| `eslint-plugin-jest` | `devDependencies` | Used in `eslint.config.mjs:4` to enable jest-style lint rules; remove together with `jest` |
| `npm-run-all` | `devDependencies` | Yes — only used by the dead `build` script |
| `onchange` | `devDependencies` | Used only by the `watch` script (dev convenience) |
| `elm-test` | `devDependencies` | Yes — repo uses `elm-test-rs`; `elm-test` is the older Node-based runner |

Toolchain binaries (binwrap-installed wrappers):

| Package | Real binary fetched from | Used as |
|---|---|---|
| `elm` | `https://github.com/elm/compiler/releases` | `compiler/node_modules/.bin/elm` (CMakeLists.txt:31) |
| `elm-format` | `https://github.com/avh4/elm-format/releases` | `npm run elm-format` (dev) |
| `elm-test-rs` | `https://github.com/mpizenberg/elm-test-rs/releases` | `npx elm-test-rs --project build-xhr` (CLAUDE.md test commands) |
| `elm-review` | npm-internal binwrap | dev/lint only |
| `guida` | npm | dev only (the `bin/index.js` runs the *built* guida.js, not this) |

### Sizes (current state)

- `node_modules/`: 165 MB, 429 packages
- `package-lock.json`: 7,694 lines

After Phase A + B the tree should shrink to the six runtime libraries plus
`eslint` + `@eslint/js` + `globals` (lint only). Expected residual
`node_modules` size after pruning: ~10–20 MB.

## Step-by-step plan

### Phase A — Prune dead devDeps

#### A1. Remove dead packages from `compiler/package.json`

From `dependencies`:
- `indexeddb-fs` (unreferenced)
- `terser` (unreferenced)
- `jszip` (only used by dead `lib/index.js` → `build.sh api` path)

From `devDependencies`:
- `jest` (no jest tests exist)
- `eslint-plugin-jest` (companion to jest)
- `npm-run-all` (used only by dead `build` script)
- `uglify-js` (only appears commented-out in `scripts/build-self.sh:49`)
- `elm-test` (repo uses `elm-test-rs`)
- `guida` (CMake doesn't invoke `node_modules/.bin/guida`; we build guida.js ourselves)

#### A2. Drop dead npm scripts

Remove from `scripts`:
- `build` (depended on `npm-run-all` and `build:bin`)
- `build:bin` (CMake invokes `elm make` directly)
- `buildself` (CMake reimplements this as Stages 2–8 in `compiler/CMakeLists.txt`)

Keep:
- `test` — still useful for `cd compiler && npm test`
- `elm-format` — dev convenience
- `watch` — keep if the developer ergonomics matter; drop if `onchange`
  removal is desired

If `watch` is dropped, also remove `onchange` from devDeps.

#### A3. Drop the `eslint-plugin-jest` rules from `compiler/eslint.config.mjs`

Lines 4 and 35–47 — the entire `jest` plugin block.

#### A4. Regenerate the lockfile

`rm package-lock.json && npm install` (or `pnpm import` in Phase C). Verify
the new `node_modules` still satisfies every `require()` in `bin/`, `lib/`,
and `scripts/`.

#### A5. Update `compiler/CMakeLists.txt:44`

`COMPILER_CONFIG_FILES` lists `"${COMPILER_DIR}/package.json"` and
`"${COMPILER_DIR}/package-lock.json"` — both stay, but the
`add_custom_command` at line 51 that runs `npm ci --prefer-offline` continues
to track them.

#### A6. Smoke test

Run a clean `cmake --preset ninja-clang-lld-linux && cmake --build build
--target check`. No code paths should reference the removed packages.

### Phase B — Move Elm toolchain binaries to CMake `FetchContent`

#### B1. Identify the binaries and pin versions

For each, pick the exact version currently resolved by
`compiler/package-lock.json` so the migration is bit-for-bit equivalent, then
pin the upstream SHA256 per platform.

| Tool | Current npm version | Upstream binary source |
|---|---|---|
| `elm` | `0.19.1-6` (npm wrapper) → `elm 0.19.1` binary | github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz |
| `elm-format` | `0.8.7` | github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-linux-x64.tgz |
| `elm-test-rs` | `3.0.1-0` | github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_linux.tar.gz |
| `elm-review` | `2.13.2` (Node) | Keep in npm; Phase C tries with `ignore-scripts=true`. Drop entirely if broken. |

`guida` is intentionally **not** moved to CMake fetch — we don't use the
npm-published guida binary at all. Stage 1 builds `guida.js` from source
using the stock elm compiler; Stage 2+ runs that `guida.js` via Node. The
`guida` devDep is purely dead weight and is removed in Phase A.

#### B2. Add a new `compiler/cmake/toolchain.cmake` module

```
# compiler/cmake/toolchain.cmake
include(FetchContent)

set(TOOLCHAIN_DIR "${CMAKE_BINARY_DIR}/toolchain")
file(MAKE_DIRECTORY "${TOOLCHAIN_DIR}/bin")

# elm 0.19.1
FetchContent_Declare(elm_binary
  URL      https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz
  URL_HASH SHA256=<pin>
  DOWNLOAD_NO_EXTRACT TRUE
)
FetchContent_MakeAvailable(elm_binary)
# gunzip + chmod +x into ${TOOLCHAIN_DIR}/bin/elm

# elm-format 0.8.7
FetchContent_Declare(elm_format
  URL      https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-linux-x64.tgz
  URL_HASH SHA256=<pin>
)
FetchContent_MakeAvailable(elm_format)
# tar extracts elm-format into ${TOOLCHAIN_DIR}/bin/

# elm-test-rs 3.0.1
FetchContent_Declare(elm_test_rs
  URL      https://github.com/mpizenberg/elm-test-rs/releases/download/v3.0.1/elm-test-rs_linux.tar.gz
  URL_HASH SHA256=<pin>
)
FetchContent_MakeAvailable(elm_test_rs)
# tar extracts elm-test-rs into ${TOOLCHAIN_DIR}/bin/

set(ELM_EXECUTABLE        "${TOOLCHAIN_DIR}/bin/elm"        CACHE FILEPATH "")
set(ELM_FORMAT_EXECUTABLE "${TOOLCHAIN_DIR}/bin/elm-format" CACHE FILEPATH "")
set(ELM_TEST_RS_EXECUTABLE "${TOOLCHAIN_DIR}/bin/elm-test-rs" CACHE FILEPATH "")
```

Linux x86_64 only (per resolution). If `CMAKE_SYSTEM_NAME` is anything
else, `message(FATAL_ERROR ...)` to make the limitation explicit.

#### B3. Repoint `compiler/CMakeLists.txt`

- Replace `set(ELM_EXECUTABLE "${COMPILER_DIR}/node_modules/.bin/elm")` at
  line 31 with `include(cmake/toolchain.cmake)` at the top of the file. The
  variable name stays the same.
- The `add_custom_command` calling `elm make` (line 63) keeps the same
  variable reference.

#### B4. Add a `check-format` and similar CMake target for `elm-format`

Optional, but if we're moving the binary into CMake it makes sense to add
the wrapper here too rather than via `npm run elm-format`. Single-line
custom target.

#### B5. Add `elm-tests` CMake wrapper target

```cmake
add_custom_target(elm-tests
    COMMAND ${ELM_TEST_RS_EXECUTABLE} --project ${BUILD_XHR_DIR} --fuzz 1
    DEPENDS guida
    WORKING_DIRECTORY ${COMPILER_DIR}
    COMMENT "Running elm-test-rs against build-xhr shadow root"
    USES_TERMINAL
)
```

Update `CLAUDE.md` to mention `cmake --build build --target elm-tests`.
Manual invocation becomes
`${BUILD_DIR}/toolchain/bin/elm-test-rs --project ${BUILD_DIR}/compiler/build-xhr --fuzz N`.

#### B6. Drop the toolchain packages from `compiler/package.json`

From `devDependencies`:
- `elm`
- `elm-format`
- `elm-test-rs`

(`guida` was already dropped in Phase A.)

Keep:
- `elm-review` (try it under Phase C's `ignore-scripts=true`; drop if broken)
- `eslint`, `@eslint/js`, `globals` (pure-JS lint tools)

#### B7. Regenerate `package-lock.json`

After Phase A + B6, the dependency tree should be: `adm-zip`, `form-data`,
`mock-xmlhttprequest`, `tmp`, `which` (runtime) +
`@eslint/js`, `eslint`, `elm-review`, `globals`, `onchange` (dev, if
`watch` is kept).

Expected tree size: ~30 packages, down from 429.

### Phase C — Switch from npm to pnpm

This phase is only worthwhile after Phase A + B. With ~30 packages, pnpm's
strict resolution catches phantom deps cheaply, and `ignore-scripts=true`
is risk-free (Phase B removed all the binwrap install scripts).

#### C1. Initialize pnpm

```
cd compiler
corepack enable
corepack prepare pnpm@<pinned-version> --activate
pnpm import     # consumes package-lock.json → pnpm-lock.yaml
rm package-lock.json
```

Pin the pnpm version in `compiler/package.json` via
`"packageManager": "pnpm@<version>"` so contributors get the same binary
through corepack.

#### C2. Add `compiler/.npmrc`

```
ignore-scripts=true
strict-peer-dependencies=true
auto-install-peers=false
frozen-lockfile=true
```

#### C3. Update `compiler/CMakeLists.txt`

- Replace `find_program(NPM_EXECUTABLE npm REQUIRED)` (line 6) with
  `find_program(PNPM_EXECUTABLE pnpm REQUIRED)`.
- Replace `COMMAND ${NPM_EXECUTABLE} ci --prefer-offline` (line 53) with
  `COMMAND ${PNPM_EXECUTABLE} install --frozen-lockfile --prefer-offline`.
- Repoint the stamp dependency from `package-lock.json` to
  `pnpm-lock.yaml`.

#### C4. Update CLAUDE.md, scripts, and docs

`compiler/scripts/build.sh` references `node_modules/.bin/elm` — under
pnpm the path is the same (pnpm creates `node_modules/.bin/`). No change
required, but Phase B already removed the elm binary from this location
anyway.

Search-and-replace `npm ci` and `npm install` mentions in:
- `compiler/README.md` (if present)
- `/work/CLAUDE.md`
- `/work/guides/*.md` (if any reference npm)

#### C5. CI / contributor docs

Document the `corepack enable` step. Mention that pnpm's content-addressable
store (`~/.local/share/pnpm/store/`) is global and benefits from being
preserved across builds, but otherwise behaves like npm for this project.

#### C6. Verify

`cmake --preset ninja-clang-lld-linux && cmake --build build --target full`
should produce a clean build. Confirm no install scripts ran (`pnpm
install --frozen-lockfile` should print "Lifecycle scripts: ignored").

## Acceptance checks

- `rm -rf compiler/node_modules build/` then full configure + `--target full`
  succeeds, producing identical guida.js / eco-boot.js / native binaries
  byte-for-byte vs. pre-migration.
- `cd compiler && pnpm install --frozen-lockfile` completes without running
  any install/postinstall scripts.
- `cd compiler && pnpm test` (which wraps `elm-test-rs`) passes.
- `find compiler/node_modules -maxdepth 2 -type d | wc -l` ≤ 50 packages
  (down from 429).
- `compiler/package.json` lists no binwrap-style toolchain wrappers.
- `compiler/.npmrc` enforces `ignore-scripts=true` and
  `frozen-lockfile=true`.
- Tests pass under `cmake --build build --target check`.

## Open questions

All previously open questions are now resolved (see the **Resolutions**
table at the top). The remaining uncertainty is **empirical**, not a
design decision:

- Does `elm-review` continue to function under pnpm's
  `ignore-scripts=true`? Verified during Phase C; if not, drop it.

## Assumptions

- The `bin/index.js` / `bin/eco-boot-runner.js` `require()` graph is the
  full picture of what npm packages get touched at runtime. (Confirmed by
  grep; double-check during implementation.)
- The current `elm 0.19.1` binary fetched via the npm `elm` wrapper is
  identical to the upstream GitHub release. (Confirmed: the npm `elm`
  package's install script downloads from the same URL.)
- `elm-test-rs` will accept `--project <absolute-path>` rather than just
  a relative path. (Verified by reading `compiler/CMakeLists.txt` Stage 1
  patterns, but worth re-checking.)
- `pnpm import` produces a `pnpm-lock.yaml` semantically equivalent to the
  current `package-lock.json` for the residual six runtime libs. (Almost
  certainly true; pnpm's importer is stable for trees this small.)
- No CI exists today, so a phased migration won't break a pipeline. (Per
  `cmake-output-relocation.md`: "No CI yet; not a concern.")
- The runner JavaScript (`bin/index.js`, `bin/eco-boot-runner.js`,
  `bin/eco-io-handler.js`) needs `node_modules` on its `require` path at
  runtime; this is unchanged across all three phases.

## Notes on related prior plans

- `plans/cmake-output-relocation.md` — relocated build outputs under
  `${CMAKE_BINARY_DIR}`. This plan extends that pattern to the Elm
  toolchain binaries themselves (Phase B fetches them under
  `${CMAKE_BINARY_DIR}/toolchain/`).
- `plans/bootstrap-build-roots.md` — established the two-directory
  bootstrap (build-xhr / build-kernel). Both directories already point at
  `${ELM_EXECUTABLE}`; Phase B redefines that variable without touching the
  consumers.
