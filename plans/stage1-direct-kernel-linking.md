---
status: done
updated: 2026-11-26
---

# Plan: every stock-Elm build links eco's real JS kernels, and the XHR path goes

## 0. Review log (2026-11-26)

An adversarial review of the first draft of this plan, checked against the tree. Each finding is
folded into the section named.

| # | Severity | Finding | Fixed in |
|---|---|---|---|
| R1 | High (existing bug) | Three scripts build stock-Elm output and run only `apply-overrides.js`, never the eco/system linker: `test/scripts/cli-errors.test.js` (`apiRunner`, ~line 291), `test/scripts/dc-corpus.py` (`format`, ~line 137) and `compiler/scripts/coverage/cov.py` (`build_instrumented_guida`, ~line 201). Since plans/compiler-io-on-eco-system.md their outputs hold eco/system stubs. Checked: API.Main built and post-processed as `apiRunner` does fails at load with `TODO in module System on line 769`. `cov.py` also never copies `src-system`, which its `elm.json` lists. | P1.6, P3.4 |
| R2 | High | elm-coverage passes its own `--compiler` to elm-test-rs (`compiler/elm-coverage/lib/runner.js` ~line 118), and its `bin/fake-elm` runs the `elm` it finds on `PATH` (`which.sync("elm")`). The wrapper cannot reach coverage runs through `--compiler`; it must be the `elm` on `PATH` there. | D2, P3.4 |
| R3 | High | The draft's wrapper fell back to `elm` on `PATH`. With R2's `PATH` shim that `elm` is the wrapper itself: endless recursion. The wrapper never looks `elm` up on `PATH`. | P3.1 |
| R4 | High | Generating eco/kernel's modules while `compiler/src-xhr` is still a source directory gives two `Eco.MVar` (etc.) and stock Elm refuses the project. The generator skips any module a project source directory defines; removing `src-xhr` (P4) is then what switches eco/kernel over. | P2.2 |
| R5 | Medium | The draft's P4 gate "guida.js holds no `XMLHttpRequest`" is wrong: the compiler keeps elm/http (`Builder/Http.elm` uses elm/http's `Http.header`; eco/system has no `Http` module), and stock Elm includes elm/http's kernel, which names `XMLHttpRequest`. | P4.9 |
| R6 | Medium | The draft's "remove elm/http if unused" is moot for the same reason: it stays. | P4.6 |
| R7 | Medium | The draft named lifted stubs `ecoKernel_<Home>_<fn>`. Use camelCase, `ecoKernelStub<Home><Fn>`; checked to compile and to generalize (one stub used at two types) with stock Elm 0.19.1. | P2.4 |
| R8 | Medium | The linker checks that each wrapper's target is defined by the linked kernels, not that the elm/core kernel names those kernels import (`_Scheduler_binding`, `_Utils_Tuple3`, …) are defined. Stock Elm includes a whole elm/core kernel module when the program uses it (checked: `_Utils_Tuple3` is in a one-module program) but none the program never touches; a missing name is a `ReferenceError` at run time. | P1.3 |
| R9 | Medium | Finding modules from `compiler/tests` imports (D4) means the generator must re-run when a test changes: its CMake rule depends on `compiler/tests/**/*.elm`. | P2.7 |
| R10 | Medium | More stock-Elm entry points: `CLAUDE.md`'s manual elm-test-rs command, `compiler/package.json`'s `test` script, and its `watch` script, which writes an unprocessed `guida.js` (broken since the compiler-io plan, as R1). | P1.6, P3.3 |
| R11 | Low | `string64`: the JS kernel starts from `(seed ^ 2166136261) % 2^31`, negative for seed 0 (−2,128,831,035); the twin from the non-negative residue (18,652,613). Harmless: `Data.HashMap` iterates in insertion order whatever the hash (`compiler/src/Data/HashMap.elm` line 27); a hash only picks a bucket. | §2.2 |
| R12 | Low | D7 assumed a crashing test shows as a failed run. elm-test-rs runs tests in worker threads, where `process.exit` may end only the worker. Checked in P4 instead of assumed. | P4.8 |
| R13 | Low | The draft's `check-stage1-overrides.sh` was vacuous until the compiler itself uses FNV. Dropped: with one script the order is structural, and P1's unit test covers it. | P1 |
| R14 | Low | The draft's wrapper found the generated directory by walking up from elm-test-rs's working directory. Every caller can pass it: an explicit variable with one documented default. | P3.1 |
| R15 | Low | Renaming `js-kernel-overrides.test.js` churns the `run-js-kernel-override-tests` target for nothing; new tests go in new files run by the same target. | P1.7 |

## 1. Goal

Every build of the compiler by stock `elm make` gets eco's real JavaScript kernels (eco/system's and
eco/kernel's) and the kernel overrides through one post-processing step: Stage 1 (`guida.js`), the
elm-test bundle (Linux and Windows), the coverage builds, and the API.Main builds of the CLI tests.
What is left of the XHR path goes: `compiler/src-xhr`, `Eco.XHR`, `bin/eco-io-handler.js`, the mock
XHR server in `bin/index.js`, the `mock-xmlhttprequest` dependency, and the MVar value overrides with
the value-override kind.

Why: the compiler is to use eco/system's `HashedDict`. That needs eco/system's FNV, JsArray2 and
SeqDictTrie kernels and the SeqDict-equality and Hashed-printing kernel overrides in every stock-Elm
build. Today the elm-test build gets no post-processing, and Stage 1 applies the overrides before it
links the kernels, so it would skip those two (§2.1).

Out of scope: renaming `build-xhr` (D5); building Stage 1 with `--optimize` (D6).

## 2. Where things stand (2026-11-26)

### 2.1 Stage 1 post-processing

Stock `elm make` builds `build/compiler/build-xhr/bin/guida.js` from `compiler/src`, `compiler/src-xhr`,
the generated `build-xhr/src-system` and `version` (`compiler/cmake/bootstrap/build-xhr/elm.json`). The
CMake rule (`compiler/CMakeLists.txt` ~lines 186–208) and `compiler/scripts/build.sh` then run, in order:

1. `scripts/apply-overrides.js <out>`: inserts each `kind kernel` override of
   `compiler/kernel-overrides/` whose required kernels are present, at the kernel/Elm boundary (the
   first line starting `var $`), and replaces the definitions named by the three `kind value` files
   `MVarStash.js`, `MVarUnstashing.js`, `MVarUnstashingTaken.js` (group `mvar-stash`, all or none).
   An override requiring `Eco.Kernel.FNV` (`SeqDictEquality.js`, `HashedDebug.js`) is skipped, because
   FNV is not in the file yet.
2. `scripts/link-stage1-system-kernels.js <out> <src-system>`: replaces each stub definition listed in
   `src-system/kernels.json` with `var <global> = _Eco_<Home>_<fn>;`, and inserts before the boundary
   the kernel files `system-kernel-cpp/src/Eco/Kernel/<Home>.js` they need, closed under Eco kernel
   imports, rendered as eco's JS backend renders them in development mode.

`scripts/make-stage1-system.js <src-system>` writes `src-system`: stock-Elm copies of the eco/system
modules in its hard-coded `ROOTS` and their imports, via `system-kernel-cpp/scripts/stock-elm-rewrite.js`
(shared with `make-docs-package.js`, which builds eco/system's `docs.json`). Each kernel reference must
be the whole body of a top-level definition named `k…`; the stub is `(Debug.todo "eco/system kernel
<Home>.<fn>")`, and the linker's leftover check searches the output for the text `eco/system kernel`.
`compiler/src-system` links to the generated directory (`compiler/CMakeLists.txt` ~line 143), so
`compiler/elm.json` (editor tooling, elm-review) sees it.

eco's own JS backend (Stages 2–5) does both jobs while generating code, kernels first, then the
override section (`Compiler/GenerateJs/Generate.elm`, `KernelOverride.elm`); no script touches its
output. `Compiler/GenerateJs/KernelOverride/Files.elm` holds only `kind kernel` overrides.

### 2.2 eco/kernel in Stage 1: hand-written twins in `compiler/src-xhr`

| Module | Twin | XHR |
|---|---|---|
| `Eco.MVar` | eco-io ops `MVar.*`; values stay JS objects via the stash value overrides | yes |
| `Eco.GC` | eco-io ops `GC.minor`/`GC.major` (same `globalThis.gc` code as `Eco/Kernel/GC.js`) | yes |
| `Eco.Hash` | pure Elm over code points | no |
| `Eco.Crash` | `Debug.todo` | no |
| `Eco.NativeDriver` | fails, as `Eco/Kernel/NativeDriver.js` does | no |
| `Eco.IO.Error` | copy of `eco-kernel-cpp/src/Eco/IO/Error.elm`, same API | no |
| `Eco.XHR` | the transport; crashes through the compiler's `System.Crash` | — |

eco/kernel's modules (`eco-kernel-cpp/src/Eco/*.elm`) call kernels inline, 15 references:
`Crash.crash`; `GC.minorGC`, `GC.majorGC`; `Hash.stringWithSeed` (×2), `Hash.string64`; `MVar.new`,
`read`, `take`, `put`, `drop`; `NativeDriver.lowerAndLink`, `lowerAndLinkBytes`. Their JS kernels
(`eco-kernel-cpp/src/Eco/Kernel/*.js`) import `Eco.Kernel.Scheduler` and `Elm.Kernel.Utils`;
`Eco.Kernel.Scheduler` names no Eco kernel and so resolves to elm/core's `_Scheduler_*`
(`Generate.resolveKernelGlobal`). Kernel homes do not collide between the packages (eco/system:
Bitmap, ChildProcess, Dom, FileSystem, FNV, HttpServer, HttpStream, JsArray2, Liveness, SeqDictTrie,
Socket, Stream, System, Terminal, Tls, WebSocket; eco/kernel: Crash, GC, Hash, MVar, NativeDriver).

Measured (cold Stage 2 compile through Stage 1, P0.2): 12,876 eco-io ops, all MVar (read 7,268, put
2,098, take 1,366, new 1,097, drop 1,047), none GC; the mock XHR and Elm Http code take ~0.1 s of
70.8 s sampled CPU. Wall 1:10.45, peak RSS 1.85 GB. Removing XHR is a simplification, not a speed-up.

Differences from Stages 2+ that this plan removes:
- `MVar.drop`: the handler fails the waiting tasks; native and JS abandon them.
- `Hash`: code points vs UTF-16 code units (they differ above U+FFFF), and `string64`'s sign (R11). One
  such hash reaches disk: the local-package fingerprint (`Builder/File.elm` `fingerprintPackageSource`).
- `Crash`: `Debug.todo` throws; the kernel prints the stack and exits 1. `fatalOnProgramThrow` in the
  handler and the exit hook in `bin/index.js` exist only because XHR could swallow such a throw.

### 2.3 The elm-test build and the other stock-Elm builds

`elm-tests` (`compiler/CMakeLists.txt` ~line 318) runs `elm-test-rs --project build/compiler/build-xhr
--fuzz 1` with no post-processing. Stock Elm evaluates a top-level `stub = Debug.todo …` when the
script loads, so a stub any test reaches crashes the whole bundle. Today the bundle reaches
`Eco.Hash.string`, `stringWithSeed`, `string64` and `Eco.Crash.crash` (pure-Elm twins today) and no
MVar, GC, NativeDriver or eco/system wrapper. Windows CI runs the same target
(`.github/workflows/win-aot.yml`, step "elm-tests").

Other stock-Elm builds: R1's three scripts, `package.json` `watch` (R10), and coverage's elm-test run
through elm-coverage's `fake-elm` (R2).

### 2.4 Prototype (scratchpad, 2026-11-26; nothing in the tree)

elm-test-rs 3.0.1 takes `--compiler <path>` and calls it once, as
`make --output=<project>/elm-stuff/tests-0.19.1/js/Runner.elm.js src/Runner.elm`. A wrapper running
stock `elm`, then the linker, then `apply-overrides.js`:
- ran a HashedDict test module (insert/get; `==` across a removal hole; `Debug.toString` of a
  `Hashed`): 3/3 pass; without the overrides step the two override tests fail (negative control);
- compiled, linked and overrode the real 22k-test bundle (`elm-test-rs make`) in ~2 s.

It needed, in scratch copies: the generator to accept any wrapper name (eco/system's `Hash`, `FNV`,
`JsArray2`, `SeqDictTrie` use `hash = Eco.Kernel.FNV.hash`); `Array` in the linker's table of Elm
modules a kernel imports (`FNV.js` imports `Array.foldl`); and a test description containing
"eco/system kernel" tripped the leftover check.

## 3. Decisions

- **D1. One post-processing script, two passes, fixed order.** `compiler/scripts/post-process-stock-elm.js`
  is the only way any stock-Elm output is post-processed. It links kernels, then applies kernel
  overrides: the order eco's backend emits them in, and the overrides choose by which kernels are
  present. The passes stay separate modules: their inputs differ (generated stubs and kernel files vs
  `compiler/kernel-overrides/`, which the backend also embeds) and so do their mechanisms (linking
  replaces stub definitions and adds kernel text; an override rebinds an existing name at load and
  usually calls the original).
- **D2. The elm-test build gets D1 through a wrapper standing in for `elm`**: given to elm-test-rs with
  `--compiler` for `elm-tests`, and put first on `PATH` as `elm` for coverage runs, where elm-coverage
  owns `--compiler` (R2).
- **D3. eco/kernel's sources do not change.** The generator lifts each inline kernel reference into a
  generated top-level stub in the stock-Elm copy only. Rewriting eco/kernel into wrappers would add a
  call layer on native hot paths (`Eco.Hash`, `Eco.MVar`) for nothing.
- **D4. The modules to generate are found, not listed**: the eco/system and eco/kernel modules imported
  by `compiler/src` and `compiler/tests`, closed under their imports, minus any module a project
  source directory defines (R4).
- **D5. `build-xhr` keeps its name** here; renaming it touches CMake, scripts, docs, CI and `CLAUDE.md`,
  and is a follow-up.
- **D6. Stage 1 stays without `--optimize`**: the stubs are `Debug.todo`, which `--optimize` rejects.
- **D7. Kernel `Crash` in tests.** A test reaching `Eco.Crash.crash` gets the kernel's behaviour (stack,
  `process.exit(1)`) instead of a throw. The suite must not reach it; P4.8 checks that elm-test-rs then
  reports a failure.
- **D8. Windows.** Windows CI runs `elm-tests`, so the wrapper works there: its logic is one Node script
  with a `.cmd` launcher, and a fallback launcher executable if elm-test-rs cannot start a `.cmd`
  (P3.2). Windows is checked by the CI job only.

## 4. P0 — baseline

1. Snapshot the tree into `snapshots/` (`pre-stage1-linking-<date>.tgz`, as for earlier plans).
2. Record in §11: (a) the cold Stage 2 compile through the current Stage 1, in a scratch directory with a
   fresh `eco-stuff`:
   ```sh
   S=<scratch dir>; mkdir -p $S; cp build/compiler/build-kernel/elm.json $S/
   ln -s /work/compiler/src $S/src; ln -s /work/build/compiler/version $S/version
   cd $S && /usr/bin/time -v env GUIDA_JS_PATH=/work/build/compiler/build-xhr/bin/guida.js \
     node --stack-size=65536 --max-old-space-size=16384 --expose-gc /work/compiler/bin/index.js make \
     --optimize --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
     --local-package eco/system=/work/system-kernel-cpp --output=$S/out.js /work/compiler/src/Terminal/Main.elm
   ```
   (2026-11-26: 1:10.45 wall, 1.85 GB); (b) the `elm-tests` duration (2026-11-26: 2,218 s, 22,162 pass).
3. Confirm R1: `node --test --test-name-pattern "API" test/scripts/cli-errors.test.js` fails with the
   API.Main load error. It must pass after P1.

## 5. P1 — one post-processing script, and every caller on it

1. **Split the passes into libraries without CLIs.**
   - Rename `scripts/link-stage1-system-kernels.js` to `scripts/link-stock-elm-kernels.js`; delete its
     `main` and `require.main` block; export `link(text, entries, kernelDirs)`, `renderKernel`,
     `LinkError`.
   - `scripts/apply-overrides.js`: delete `main` and the `require.main` block; keep `apply`,
     `ApplyError`, `definitionSpan` exported (the linker requires `definitionSpan`).
2. **The script** `scripts/post-process-stock-elm.js`:
   - `postProcess(text, generatedDir)`: reads `<generatedDir>/kernels.json` and returns
     `apply(link(text, entries, KERNEL_DIRS), lib.load(lib.DIR))`.
   - `KERNEL_DIRS`: `system-kernel-cpp/src/Eco/Kernel` and `eco-kernel-cpp/src/Eco/Kernel`, absolute,
     from `__dirname`.
   - CLI `node post-process-stock-elm.js <output.js> [<generated dir>]`; the default generated dir is
     `$ECO_STAGE1_GENERATED`, else `<repo>/build/compiler/build-xhr/src-system` (`src-stage1` from P2).
     Writes through `<output>.tmp` and a rename. Exit 0; 1 with `post-process-stock-elm: <file>:
     <message>` on stderr for a `LinkError`, `ApplyError` or `OverrideError`; 2 for bad usage.
3. **Linker changes** (`link-stock-elm-kernels.js`):
   - Kernel files are looked up in `kernelDirs`; a home found in two is a `LinkError`. The inserted
     `// --- <path>` line names the file's repo-relative path.
   - `ecoImports(home)` keeps only homes with a file in `kernelDirs`. Any other `import Eco.Kernel.X`
     is elm/core's: not linked, and rendered `_X_name` (`renderKernel` already does so when `X` is not
     in `linked`).
   - `ELM_MODULE_PACKAGE` becomes the elm/core module set: `Array, Basics, Bitwise, Char, Debug, Dict,
     List, Maybe, Platform, Platform.Cmd, Platform.Sub, Process, Result, Set, String, Task, Tuple`, all
     `elm$core`.
   - New check (R8): every name a linked kernel's header imports from an `Elm.Kernel.*` module, or from
     an `Eco.Kernel.*` module with no file, rendered `_<Home>_<name>`, must be defined above the
     boundary (`var <name> =` or `function <name>(` at column 0); else a `LinkError` naming it.
   - The marker becomes `// ECO KERNELS (compiler/scripts/post-process-stock-elm.js)`.
   - Leftover check: stubs become `Debug.todo "ECO_STAGE1_KERNEL_STUB <Home>.<fn>"` (P1.4), and the
     check searches for `'ECO_STAGE1_KERNEL_STUB ` with stock Elm's opening single quote, so only a
     string that starts with the token matches.
   - `kernels.json` entries may carry `package`; messages name it when present.
4. **Generator stub text** (`make-stage1-system.js`): `STUB` becomes `ECO_STAGE1_KERNEL_STUB`; the
   count check in `main` counts the new text.
5. **Value overrides stay** until P4: `apply` still replaces the MVar group in Stage 1.
6. **Callers**: each replaces its separate `apply-overrides.js` and linker calls by one call of the
   script.
   - `compiler/CMakeLists.txt` Stage 1 rule: one `COMMAND ${NODE_EXECUTABLE}
     ${COMPILER_DIR}/scripts/post-process-stock-elm.js ${COMPILER_OUTPUT} ${STAGE1_SYSTEM_DIR}`.
     `DEPENDS` gains the three scripts and `eco-kernel-cpp/src/Eco/Kernel/*.js`;
     `COMPILER_CONFIG_FILES` lists `post-process-stock-elm.js` and `link-stock-elm-kernels.js`.
   - `compiler/scripts/build.sh`: the same, after `elm make`.
   - `test/scripts/cli-errors.test.js` `apiRunner`: post-process `api.js` with the script (R1).
   - `test/scripts/dc-corpus.py` `format`: the same (R1).
   - `compiler/scripts/coverage/cov.py` `build_instrumented_guida`: copy `build-xhr/src-system` into
     `out_dir` (as it copies `src`), and post-process with the script instead of `apply-overrides.js`
     (R1). Its elm-test run is P3.4.
   - `compiler/package.json` `watch`: `onchange "src/**/*.elm" -- sh scripts/build.sh bin` (R10).
7. **Tests**, new file `test/scripts/stock-elm-post-process.test.js`, added to the
   `run-js-kernel-override-tests` target (R15). Small synthetic stock-Elm texts and temporary kernel
   directories passed as `kernelDirs`:
   - an `Eco.Kernel.Scheduler` import renders `_Scheduler_binding` and links nothing;
   - a kernel importing `Array` renders `$elm$core$Array$foldl`;
   - a kernel importing an elm/core kernel name the text does not define fails (R8);
   - a string literal holding `… ECO_STAGE1_KERNEL_STUB …` mid-text passes; a remaining stub fails;
   - an override requiring an Eco kernel that only the link pass adds is applied (the order bug);
   - a second run fails on the marker;
   - a home present in two kernel directories fails.
8. **Gate**: `guida` builds; `run-js-kernel-override-tests`; `elm-tests`;
   `node --test test/scripts/cli-errors.test.js` (its API tests now pass, P0.3);
   `python3 test/scripts/dc-corpus.py format <scratch out>` completes.

## 6. P2 — the generator handles both packages

Rename `scripts/make-stage1-system.js` to `scripts/make-stage1-kernels.js`, and the output directory
`build-xhr/src-system` to `build-xhr/src-stage1`.

1. **Structure.** Export `generate({ packages, projectSourceDirs, scanDirs, outDir })`. The CLI is
   `node make-stage1-kernels.js <outDir> <project elm.json>` and fills the options:
   - `packages`: `{ name: "eco/system", src: system-kernel-cpp/src }`, `{ name: "eco/kernel", src: eco-kernel-cpp/src }`;
   - `projectSourceDirs`: the `source-directories` of the given `elm.json`, resolved against its
     directory, minus `outDir`;
   - `scanDirs`: `compiler/src`, `compiler/tests`.
2. **Roots (D4, R4).** Every `import X` in `scanDirs/**/*.elm` where `X`'s file exists in exactly one
   package and in no `projectSourceDirs` directory; `X` in two packages is an error. Then their imports,
   closed under the same two rules. While `src-xhr` is a source directory, eco/kernel's modules are
   therefore not generated.
3. **Whole-body wrappers.** A top-level definition with any lower-case name whose body is exactly
   `Eco.Kernel.<Home>.<fn>` (multiline regex
   `^([a-z]\w*)\s*=\s*\n\s+Eco\.Kernel\.([A-Z]\w*)\.([a-z]\w*)\s*$`) is listed as today:
   `{ global: "$author$project$<Module$path>$<name>", package, home, fn }`.
4. **Inline references (D3, R7).** `rewrite`'s `kernelRef(home, fn)` callback decides what each
   reference becomes. The generator first finds the whole-body wrappers (step 3) and their line
   numbers; `rewrite` gets a `kernelRef` that also receives the reference's offset (add that argument
   in `stock-elm-rewrite.js`; `make-docs-package.js` ignores it). For a reference on a wrapper's body
   line it returns the stub text as today; for any other it returns `ecoKernelStub<Home><Fn>` (`Fn` is
   `fn` with its first letter upper-cased) and records the name. After the rewrite, the generator
   appends to the module, once per recorded name:
   ```elm


   ecoKernelStubMVarRead =
       Debug.todo "ECO_STAGE1_KERNEL_STUB MVar.read"
   ```
   and lists `{ global: "$author$project$Eco$MVar$ecoKernelStubMVarRead", package: "eco/kernel",
   home: "MVar", fn: "read" }`. A recorded name the module already defines is an error.
5. **Effect modules** are rewritten as today.
6. **Outputs** as today: `<Module/Path>.elm` written only when changed, stale ones deleted,
   `kernels.json`, and a `GENERATED` stamp naming the new script.
7. **CMake** (`compiler/CMakeLists.txt`):
   - `STAGE1_SYSTEM_DIR` becomes `STAGE1_KERNELS_DIR = ${BUILD_XHR_DIR}/src-stage1`.
   - The generator rule runs `make-stage1-kernels.js ${STAGE1_KERNELS_DIR} ${BUILD_XHR_DIR}/elm.json`
     and depends on `system-kernel-cpp/src/**/*.elm`, `eco-kernel-cpp/src/**/*.elm`,
     `compiler/src/**/*.elm`, `compiler/tests/**/*.elm` (R9), the build-xhr `elm.json`, the script and
     `stock-elm-rewrite.js`.
   - The directory link `compiler/src-system` becomes `compiler/src-stage1`.
8. **Renames to `src-stage1`**: `compiler/cmake/bootstrap/build-xhr/elm.json` and `compiler/elm.json`
   (`source-directories`), `compiler/.gitignore` (drop the `src-system` line),
   `compiler/review/src/ReviewConfig.elm` (the ignored directory and its comment), `scripts/build.sh`,
   `cov.py` (P1.6's copy), the script's default (P1.2). Delete the old
   `build/compiler/build-xhr/src-system` directory and `compiler/src-system` link by hand once.
9. **Tests**, new file `test/scripts/stage1-kernels-generator.test.js`, in the same target, with
   temporary package directories:
   - a whole-body wrapper with any name is listed and its body stubbed;
   - an inline reference becomes `ecoKernelStub…`, its definition is appended once though the reference
     is used twice, and it is listed;
   - a module defined in a project source directory is not generated;
   - a module in two packages fails; an appended name clashing with a definition fails.
10. **Gate**: `guida` builds; the generated eco/system modules equal the old ones except the stub text
    (diff the two directories); `kernels.json` lists the same eco/system globals; no eco/kernel module is
    generated yet; `elm-tests`.

## 7. P3 — the elm-test build on Linux and Windows, and coverage

1. **Wrapper logic** `compiler/scripts/elm-stock-post-processed.js` (Node, no dependencies):
   - The real `elm`: `$ECO_STOCK_ELM`, else `<repo>/build/toolchain/bin/elm` (`elm.exe` on Windows). If
     that file does not exist, exit 2 with a message naming `ECO_STOCK_ELM`. Never `PATH` (R3).
   - Run it with every argument: `spawnSync(real, args, { stdio: "inherit" })`, no shell. If it cannot
     start, exit 1 with the error; if it exits non-zero, exit with its status.
   - If `args[0] === "make"`, an argument `--output=<file>` is present, `<file>` is not `/dev/null` or
     `NUL` (case-insensitive), and the file exists: `postProcess` it with the generated dir
     `$ECO_STAGE1_GENERATED`, else `<repo>/build/compiler/build-xhr/src-stage1` (R14). On an error,
     print it and exit 1.
   - Exit 0.
2. **Launchers** (D8), each only starting node on the script with every argument:
   - `compiler/scripts/elm-stock-post-processed` (POSIX `sh`, mode 755):
     `exec node "$(dirname "$0")/elm-stock-post-processed.js" "$@"`.
   - `compiler/scripts/elm-stock-post-processed.cmd`:
     `@node "%~dp0elm-stock-post-processed.js" %*` then `@exit /b %ERRORLEVEL%`.
   - Fallback, only if step 6's Windows check fails:
     `compiler/scripts/elm-stock-post-processed-launcher.cpp`, built by CMake under `WIN32` as
     `elm-stock-post-processed.exe`. It builds the command line `node "<its dir>\elm-stock-post-processed.js"`
     followed by its own arguments, each quoted by the `CommandLineToArgvW` rules, runs it with
     `CreateProcessW`, waits and returns its exit code. The `elm-tests` target then uses it.
3. **Entry points.**
   - `elm-tests` target (`compiler/CMakeLists.txt`): add `--compiler <launcher>` (the `.cmd` under
     `WIN32`, the `sh` one otherwise) and, in its `${CMAKE_COMMAND} -E env`,
     `ECO_STOCK_ELM=${ELM_EXECUTABLE}` and `ECO_STAGE1_GENERATED=${STAGE1_KERNELS_DIR}`.
   - `compiler/package.json` `test`: add `--compiler scripts/elm-stock-post-processed`.
   - `CLAUDE.md`, "Running Tests": `build/toolchain/bin/elm-test-rs --project build/compiler/build-xhr
     --compiler compiler/scripts/elm-stock-post-processed --fuzz 1` (R10).
4. **Coverage** (`cov.py`; Linux only) (R2):
   - New helper `shim_dir(root)`: writes `<root>/.coverage/shim/elm` (sh, mode 755):
     `exec node <COMPILER>/scripts/elm-stock-post-processed.js "$@"`.
   - `tool_env()` takes the shim dir: `PATH` = shim dir, then `TOOLCHAIN`, then the rest; sets
     `ECO_STOCK_ELM=<TOOLCHAIN>/elm` and `ECO_STAGE1_GENERATED=<BUILD>/compiler/build-xhr/src-stage1`.
     elm-coverage's `fake-elm` then runs the shim, which post-processes before `fake-elm` injects its
     counters; the injection matches `$author$project$Coverage$track`, which linking does not touch.
   - `build_instrumented_guida`: drop P1.6's separate post-process call; the shim does it.
   - `cmd_workspace`: also link `src-stage1` to `build/compiler/build-xhr/src-stage1`.
   - Check: a quick `cov.py` run with `--filter "LinkedKernels"` writes coverage data.
5. **Test** `compiler/tests/Stage1/LinkedKernelsTest.elm`, a guard of the build rather than of a
   compiler module, so it has no `src` counterpart. The prototype's three cases:
   - `HashedDict.empty |> insert (Hash.hashed "a") 1 |> insert (Hash.hashed "b") 2 |> get (Hash.hashed "b")`
     is `Just 2`;
   - `HashedDict.singleton (Hash.hashed "a") 1` equals the dict holding `"x"` then `"a"` with `"x"` removed;
   - `Debug.toString (Hash.hashed "a")` is `"\"a\""`.

   Without post-processing the bundle crashes at load; without the overrides, cases 2 and 3 fail. Its
   imports make the generator emit `HashedDict`, `Hash`, `SeqDict`, `SeqDictTrie`, `JsArray2`, `FNV`
   and `Bitmap` (D4).
6. **Gate**: `elm-tests` on Linux, in full (22,162 + 3; duration against P0.2b, about 2 s more for the
   post-processing). On Windows: the CI `elm-tests` step passes with `LinkedKernelsTest` among the tests
   run. Give one of its test descriptions a space and a double quote, so a launcher that mangles
   arguments shows. If elm-test-rs cannot start the `.cmd`, switch to step 2's fallback.

## 8. P4 — eco/kernel switches to its real kernels; the XHR path goes

1. Remove `src-xhr` from `compiler/cmake/bootstrap/build-xhr/elm.json` and `compiler/elm.json`, and its
   `eco_create_dir_link` (`compiler/CMakeLists.txt` ~line 136). The generator now emits `Eco.MVar`,
   `Eco.GC`, `Eco.Hash`, `Eco.Crash`, `Eco.NativeDriver` and `Eco.IO.Error` (P2.2), with lifted stubs.
2. Delete `compiler/src-xhr/` (seven files).
3. Delete the value overrides:
   - `compiler/kernel-overrides/MVarStash.js`, `MVarUnstashing.js`, `MVarUnstashingTaken.js`;
   - in `scripts/kernel-overrides-lib.js`, `kind value`, `value` and `group` (a `kind value` file is
     now refused);
   - in `apply-overrides.js`, step 2 and its header lines;
   - in `gen-kernel-overrides.mjs`, the value-override filter and its comment.

   `Files.elm` is unchanged (it never held them), and `check-kernel-overrides.sh` must pass. In
   `test/scripts/js-kernel-overrides.test.js` delete the two value-group tests (~lines 318–348) and add
   "a `kind value` file is refused" to the grammar test.
4. `compiler/bin/index.js` becomes:
   ```js
   #!/usr/bin/env node
   // Runs the Stage 1 compiler: guida.js, built by stock elm and post-processed by
   // scripts/post-process-stock-elm.js. CMake passes its path in GUIDA_JS_PATH; the default is the
   // `build` preset's.
   const path = require("path");
   const guidaPath = process.env.GUIDA_JS_PATH ||
       path.join(__dirname, "../../build/compiler/build-xhr/bin/guida.js");
   const { Elm } = require(guidaPath);
   Elm.Terminal.Main.init();
   ```
   Delete `compiler/bin/eco-io-handler.js` and `test/scripts/eco-io-handler-builder.test.js`. In
   `cli-errors.test.js` (~line 304) and `dc-corpus.py` (`runner_js`, ~line 68), delete the two
   `.replace` calls for `eco-io-handler` and `mock-xmlhttprequest`.
5. `compiler/package.json`: remove `mock-xmlhttprequest`; regenerate `pnpm-lock.yaml` with
   `pnpm install`, so CMake's `--frozen-lockfile` install passes.
6. elm/http stays (R6). `compiler/elm-application.json`: remove `Eco.XHR` from its module list.
7. `compiler/review/src/ReviewConfig.elm`: remove the `src-xhr/` entries (~lines 52, 62, 67, 77–78).
8. Behaviour checks:
   - **Crash in tests** (D7, R12): in a scratch copy of the build-xhr project, a test calling
     `Eco.Crash.crash "x"`, run through the wrapper, must make elm-test-rs exit non-zero. If it reports a
     pass or hangs, stop and record it for a decision: making the test build's crash throw would need a
     test-only kernel override, which JSGEN_001 does not allow.
   - **`MVar.drop`** abandons waiters, as native does; nothing in the compiler drops an MVar it waits on.
   - **Hash**: `test/eco-kernel/src/HashNegativeSeedTest.elm`'s comment names the twin; reword it. An
     existing local-package fingerprint of a path above U+FFFF differs once, and the cache copy is
     refreshed.
9. Gate (R5): Stage 1 builds; `guida.js` contains no `eco-io`, and `_MVar_store` only inside the linked
   `eco-kernel-cpp/src/Eco/Kernel/MVar.js` block; `bin/index.js` requires nothing but `path` and
   `guida.js`; `elm-tests`; `run-compiler-io-tests`; the node CLI tests.

## 9. P5 — documents and invariants

- `design_docs/invariants.csv`:
  - JSGEN_001 (d) — "Stage 1 (guida.js) … compiler/src-xhr … value overrides" becomes: every stock-Elm
    build (Stage 1, the elm-test bundle, coverage and API builds) is post-processed only by
    `compiler/scripts/post-process-stock-elm.js`, which links the Eco kernels the output reaches and then
    applies the kernel overrides, failing without writing on any mismatch; there are no value overrides.
  - IO_ERR_002, FORBID_IO_001: drop "XHR" from the boundaries they name.
- `design_docs/theory/workflow/bootstrap.md` (the Stage 1 paragraph, and the crash-function paragraph:
  Stage 1 has no HTTP tree, and is unoptimized because of the stubs), `design_docs/theory/kernels/kernels.md`,
  `design_docs/theory/kernels/system-libraries.md`, `design_docs/theory/compiler/build-driver.md`.
- `guides/bootstrap.md`; `docs/options.md` (delete the eco-io rows, ~232, 235, 236; keep
  `GUIDA_JS_PATH`; the scope note at line 51 drops `compiler/src-xhr/**`); `docs/build-targets.md` if a
  target changed.
- Comments: the top-level `CMakeLists.txt` (~1531, ~1599, "via the XHR mock + eco-io-handler"),
  `test/ElmE2ETestBase.hpp` (~364–366), `compiler/CMakeLists.txt` (the Stage 1 rule comment, "XHR"),
  `eco-kernel-cpp/src/Eco/GC.elm` and `Eco/IO/Error.elm` (they name the XHR twin),
  `benchmarks/lss-loop-snap.sh` (`DIRS` drops `compiler/src-xhr`), `cov.py` docstrings.
- History stays: older `plans/`, `benchmarks/*.md`, `guides/mem-hints.md`, `compiler/recomment-bugs*`,
  `eco-lib-bugs-triage.md`.
- This plan: `status`, `updated`, §11.

## 10. P6 — final verification

Run each once, output tee'd to a file under `/tmp`:
- `cmake --build build --target full` (Gate A: JIT E2E through Stage 1, JS E2E, the override and
  generator tests, compiler-io tests, script checks);
- `cmake --build build --target bootstrap` (4b, 8c, 9b);
- `cmake --build build --target elm-tests`;
- `node --test test/scripts/{builder-cli,cli-builder,cli-errors,cli-terminal-render}.test.js`;
- `test/scripts/check-kernel-overrides.sh`; the TLA canary is unaffected (no runtime C++ change);
- timings against P0.2: the cold Stage 2 compile (expect flat) and the `elm-tests` duration; flag 5 %
  or more;
- Windows: the CI run of `win-aot.yml`, `elm-tests` green.

Risks:
- elm-test-rs calls the compiler another way (another subcommand, several `--output`s): the wrapper
  passes everything through and post-processes only `make --output=<file>`; `LinkedKernelsTest` fails
  loudly if the bundle was not post-processed.
- A stub reached but not listed fails post-processing with its name: fix the generator, not the wrapper.
- elm-test-rs on Windows cannot start a `.cmd`, or mangles its arguments: P3.2's fallback launcher.

## 11. Implementation record

### 11.1 Deviations from the plan

- **P1 and P2 landed together**, in one build: the script's default generated dir is `src-stage1` from the
  start, and there was no interim `src-system` state.
- **Inline references are found by placeholders, not offsets (P2.4).** `make-stage1-kernels.js` gives
  `rewrite` a `kernelRef` that returns a numbered placeholder; afterwards a placeholder that is the whole
  body of a definition becomes the stub text, any other the lifted name. `stock-elm-rewrite.js` is
  unchanged apart from its header comment, so `docs.json` cannot change.
- **A generator bug, found by the first eco/kernel build and fixed (P2.3).** The whole-body pattern ended in
  `\s*$` under the multiline flag, so `$` matched the end of the reference's line, and a body continuing on
  the next line (`new =\n    Eco.Kernel.MVar.new\n        |> Task.map MVar`) was taken for a whole body:
  the link pass replaced all of `Eco.MVar.new` with the raw kernel, dropping `Task.map MVar`, and Stage 1
  failed with `MVar not found: undefined`. The reference must now be followed only by blank lines and a
  column-0 line or the end; a generator test covers it. The old `make-stage1-system.js` had the same
  pattern; no eco/system wrapper was affected (the fix changed only `Eco.MVar.new`'s entry).
- **D7 / R12, decided in the implementation:** a test reaching `Eco.Crash.crash` made elm-test-rs hang
  (stopped by a 600 s timeout): `process.exit` in a worker thread ends only the worker. Rather than stop,
  `eco-kernel-cpp/src/Eco/Kernel/Crash.js` now throws the same error in a worker thread
  (`worker_threads.isMainThread` false) and keeps print-and-exit on the main thread, so Stage 1 and the
  eco-built JS stages behave as before. Checked: the scratch test now fails with "This test failed because
  it threw an exception: Error: deliberate crash". The C++ kernel is unchanged.
- **Coverage shim location (P3.4):** `build/compiler/coverage-elm-shim/elm`, written by `cov.py`'s
  `elm_shim_dir()`, instead of under each workspace's `.coverage`.
- **`definitionSpan` tests** moved from the deleted value-group tests to a direct test of the function,
  which the link pass still uses.
- **More stale text than §9 listed:** the theory documents (`build-driver.md`, `system-libraries.md`)
  still described per-module plain-Elm twins of files, console and process modules that the compiler-io
  plan had already removed; rewritten to the current design. `HashNegativeSeedTest.elm`'s comment and the
  stale-cache comment in `compiler/CMakeLists.txt` also named the twins.
- **Not done:** the Windows fallback launcher (only needed if the CI check fails); `compiler/lib/` was
  deleted before implementation (below).

### 11.2 Verification (2026-11-26)

- P0: snapshot `snapshots/pre-stage1-linking-2026-11-26.tgz`. Baselines: cold Stage 2 compile 1:10.45,
  1.85 GB; `elm-tests` 2,218 s, 22,162 pass. R1 confirmed before the change (API.Main load error).
- Unit tests: `stock-elm-post-process.test.js` 7/7, `stage1-kernels-generator.test.js` 6/6.
- P1: `cli-errors.test.js` API test passes; `dc-corpus.py format` completes (1,809 files; 137 timed out,
  which the script counts and excludes from comparisons; one output is the API formatter's own stack
  overflow on a 17-argument alias, recorded as output).
- P3: the guard test passes through the wrapper (3/3) and crashes the bundle at load without it.
- P4: `guida.js` holds no `eco-io`; `_Eco_MVar_store` only in the linked `MVar.js` block; `bin/index.js`
  requires only `path` and `guida.js`; `check-kernel-overrides.sh` OK; pnpm lockfile diff removes only
  `mock-xmlhttprequest`.
- `full` (the cached `~/.eco/0.2.0/packages/eco/{kernel,system}` moved to `/tmp/claude-1000/eco-cache-backup-2`
  first): passes — JIT E2E 3,172/3,172, JS E2E eco-system 261 + 10 skipped and elm-conformance 35, the
  override and post-processing tests 25/25, compiler-io 11/11, node addon and driver CLI checks.
- `--target bootstrap`: passes, including 4b (JS fixed point), 8c (native fixed point) and 9b.
- `elm-tests`: 22,165/22,165 (22,162 + `LinkedKernelsTest`'s 3), 2,159 s (baseline 2,218 s, −2.7 %).
- Node CLI tests (`builder-cli`, `cli-builder`, `cli-errors`, `cli-terminal-render`): 52/52.
- Cold Stage 2 compile through the new Stage 1 (P0.2's command): 1:07.29, 1.64 GB (baseline 1:10.45,
  1.85 GB; −4.5 % wall, −11 % RSS). Its output is byte-identical to the bootstrap's `eco-boot.js`.
- `cov.py quick --filter "eco kernels linked"`: elm-test under coverage passes 3/3 through elm-coverage and
  the `PATH` shim, and writes coverage data (the quick file was deleted afterwards).
- ESLint on the new and changed scripts: clean, apart from a pre-existing `no-control-regex` error in
  `kernel-overrides-lib.js` line 33, which this plan did not touch.
- Not run here: Windows. The `.cmd` launcher and its argument passing are checked by the next
  `win-aot.yml` run (`elm-tests` step, with `LinkedKernelsTest`); if elm-test-rs cannot start a `.cmd`,
  P3.2's fallback launcher is the fix.

### 11.3 Follow-ups

- Windows CI confirmation of P3.2 (above).
- Rename `build-xhr` (D5): it no longer has anything to do with XHR.
- `kernel-overrides-lib.js`'s pre-existing ESLint error.

- 2026-11-26: the stale, untracked `compiler/lib/guida.js` (4.7 MB, 2026-11-19; `scripts/build.sh api`'s
  output, built with `src-xhr`, ignored by `compiler/.gitignore`) was deleted, with the empty
  `compiler/lib/`. `build.sh api` still writes there when run, and after P1 post-processes it like Stage 1.
