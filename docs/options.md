# Options and Flags Reference

This page lists every flag, option and switch that changes how Eco builds, compiles or runs. It covers:

- the Elm front-end (`eco make` and the other commands, `ECO_*` environment variables, `eco-config.json`),
- the C++ backend tools (`eco-boot-native`, `ecoc`, `ecogen`, `ecor`, the test runners) and the lowering environment variables,
- the runtime heap and garbage collector (`ECO_HEAP_CONFIG` JSON keys and `ECO_GC_*` environment variables),
- build-time configuration (CMake options, cache variables, presets, preprocessor switches).

Every default was read from the source; `Source` columns give `path:line`, checked on 2026-09-28. Line numbers drift, so treat them as a starting point.

## Where settings come from

| Stage | How you set it | Read by | Section |
|---|---|---|---|
| Configure / build | `cmake --preset …`, `-DECO_…=ON` | CMake, the C++ preprocessor | [Build-time configuration](#build-time-configuration) |
| Front-end compile | `eco make` flags, `eco-config.json` (`--config`), `ECO_*` env | the Elm front-end, once per `make` | [Elm front-end](#elm-front-end) |
| Lowering (MLIR → LLVM → object) | tool flags, `ECO_*` env | `eco-boot-native`, `ecoc`, the JIT test runner, and `eco` in-process | [C++ backend tools](#c-backend-tools-and-native-driver) |
| Program run time | `ECO_HEAP_CONFIG` (a JSON file path), `ECO_GC_*` / `ECO_NURSERY_*` / `ECO_TENURE_*` env | the runtime, on the first heap initialization | [Runtime: heap and GC](#runtime-heap-and-gc) |

Precedence in each stage: the front-end applies env **over** `eco-config.json` **over** built-in defaults; the runtime applies env **over** the `ECO_HEAP_CONFIG` file **over** the struct defaults. Environment variables set on `eco` itself affect both its own compile and, through lowering, the code it generates; heap variables affect only the process whose heap they configure (the compiler, or the compiled program when you run it).

## Gotchas

These are the places where a setting does not do what its name suggests. Each is described in more detail in its section.

- **Boolean env values are not parsed uniformly.** Front-end switches use four rules (`B4`, `B3`, `SET`, and a one-way off switch); backend switches use five (`presence`, `0 = off`, `1 = on`, …). For example `ECO_VALUE_EQ=false` leaves value equality **on** (only `0`/`off` turn it off), and `ECO_FCA_SCAN=0` turns the scan **on** (any value enables it). Check the Values column.
- **`eco-config.json`: a `"mono"` object without `"engine"` selects the `subst` engine**, not the built-in default `solver`.
- **`eco make --debug`, `--optimize` and `--sourcemaps` affect only JS/HTML output.** The MLIR and native paths ignore them.
- **The unified `eco` binary cannot reach backend CLI options** (opt level, split, gc-sections, IR dumps). It always uses the defaults; only the lowering env variables change what it emits.
- **`ECO_HEAP_CONFIG` is a file path, not inline JSON.** An unknown key or an out-of-range value aborts heap initialization.
- **Only 10 of the 88 heap keys have an env override** (`ECO_GC_*`, `ECO_NURSERY_*`, `ECO_TENURE_*`); the rest need a JSON file.
- **No heap config JSON is compiled in.** `build/compiler/build-kernel/heap-config.json` is used only when a harness points `ECO_HEAP_CONFIG` at it.
- **Unit tests ignore `ECO_HEAP_CONFIG` and `ECO_GC_*`** apart from the first-init heap split: each test resets the allocator with its own config. Use the `ECO_TEST_*` variables instead.
- **"Auto" GC thread counts depend on the CPU count** (affinity mask and cgroup quota), so results from different machines or `taskset` settings are not comparable unless the counts are pinned.
- **`ECO_HEAP_VALIDATE` builds change heap defaults** (eden flip on, one extra nursery extent, P1 census aborts), so their GC counters differ from a normal build.
- **Build-type-dependent CMake defaults stick.** `ECO_GC_DEBUG`, `ECO_GC_STATS` and `ECO_ASSERTS_ON` are chosen on the first configure only.
- **`ECO_P1_CENSUS` and `ECO_HEAP_TRACE` are both a CMake option and a runtime env var.** The option compiles the feature in; the variable switches it on.
- **`AOT_E2E_JOBS` and `MLIR_EQUIV_JOBS` override an explicit `--jobs`.**
- **E2E binary caches do not track the environment.** To A/B a lowering variable, delete the outputs first.

## Contents

- [Elm front-end](#elm-front-end)
- [C++ backend tools and native driver](#c-backend-tools-and-native-driver)
- [Runtime: heap and GC](#runtime-heap-and-gc)
- [Build-time configuration](#build-time-configuration)

## Elm front-end

Scope: `compiler/src/**`, `compiler/src-xhr/**`, and the shipped JS glue `compiler/bin/*.js`, `compiler/lib/index.js`. All paths are repo-relative. Line numbers were checked against the tree on 2026-09-28.

### 1. CLI commands and flags (`eco <command>`)

Flag syntax, from `compiler/src/Terminal/Terminal/Chomp.elm:404-442`: a value flag takes `--flag=value` or `--flag value`. In the second form the value must not start with `-`. An on/off flag is a bare `--flag`. An unknown flag is a hard error that suggests the closest match.

**Top level** (`compiler/src/Terminal/Terminal.elm:64-93`)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| (no args) / `--help` | none | Prints the overview of enabled commands | compiler/src/Terminal/Terminal.elm:68 |
| `--version` | none | Prints `Version_Build.userFacing` (currently `0.1.1`; CMake generates it) and exits 0 | compiler/src/Terminal/Terminal.elm:74 |
| `<cmd> ... --help` | anywhere in the args | Prints help for that command | compiler/src/Terminal/Terminal.elm:84 |

**Registered commands** (`compiler/src/Terminal/Main.elm:46-55`)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `init` | enabled; no args | Creates elm.json, `src/` and a starter `src/Main.elm` | compiler/src/Terminal/Main.elm:119 |
| `make` | enabled; `[FILE.elm ...]` (zero or more) | Compiles to JS, HTML, MLIR or native. With no files it builds the package's exposed modules (docs) | compiler/src/Terminal/Main.elm:314 |
| `install` | enabled; `[author/project]` (0 or 1) | Adds a package dependency | compiler/src/Terminal/Main.elm:395 |
| `uninstall` | enabled; `[author/project]` (0 or 1) | Removes a package dependency | compiler/src/Terminal/Main.elm:467 |
| `bump` | enabled; no args, no flags | Computes the next package version from API changes | compiler/src/Terminal/Main.elm:520 |
| `diff` | enabled; no args, `VER`, `VER VER`, or `author/project VER VER`; no flags | Detects API changes | compiler/src/Terminal/Main.elm:575 |
| `repl` | **DISABLED** (`Terminal.disabled`, so an "unknown command") | Interactive REPL | compiler/src/Terminal/Main.elm:49,180 |
| `test` | **DISABLED** | Runs elm-test style tests | compiler/src/Terminal/Main.elm:54,671 |

**`make` flags**

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `--output` | path; no default (without it: `index.html` for 1 main, `elm.js` for several, nothing for 0) | Format comes from the extension (`Make.parseOutput`). `.html` gives Html, `.js` gives JS, `.mlir` gives MLIR. `/dev/null`, `NUL` or `<\|null` typecheck only. Any other non-empty name (including `.o`, `.so`, `.node`) gives a native target through `Eco.NativeDriver.lowerAndLink` | compiler/src/Terminal/Main.elm:253; compiler/src/Terminal/Make.elm:707 |
| `--debug` | on/off; off | JS/HTML only: time-travel debugger mode. An error if combined with `--optimize`. MLIR and native outputs ignore it | compiler/src/Terminal/Main.elm:240; compiler/src/Terminal/Make.elm:489 |
| `--optimize` | on/off; off | JS/HTML only: Prod mode. MLIR and native outputs ignore it (they never read `desiredMode`) | compiler/src/Terminal/Main.elm:246 |
| `--sourcemaps` | on/off; off | JS/HTML only: source maps. It reaches the MLIR writers but they ignore it (`_`) | compiler/src/Terminal/Main.elm:251; compiler/src/Builder/Generate.elm:2213 |
| `--report` | only `json` | Emits diagnostics as JSON | compiler/src/Terminal/Main.elm:261; compiler/src/Terminal/Make.elm:678 |
| `--docs` | path ending `.json` | Writes the package docs JSON | compiler/src/Terminal/Main.elm:268; compiler/src/Terminal/Make.elm:742 |
| `--Xpackage-errors` | on/off; off | Shows full errors when a dependency package fails to compile (experimental) | compiler/src/Terminal/Main.elm:275 |
| `--builddir` | a plain dir name (no `/` or `\`) | Puts artifacts under `eco-stuff/<ver>/<builddir>/` so builds can run in parallel | compiler/src/Terminal/Main.elm:279; compiler/src/Terminal/Make.elm:766 |
| `--kernel-package` | `author/project` | Gives the application kernel-code privileges under that package name (e.g. `eco/compiler`) | compiler/src/Terminal/Main.elm:286; compiler/src/Terminal/Make.elm:816 |
| `--local-package` | `author/project=path` | Resolves that dependency from a local directory. Without it, `eco/kernel` falls back to `dirname(exe)/../share/eco/kernel/eco-kernel-cpp` if that exists | compiler/src/Terminal/Main.elm:291; compiler/src/Builder/Stuff.elm:346 |
| `--text-mlir` | on/off; off (binary bytecode) | Writes MLIR as text instead of bytecode, for both `.mlir` and the temporary native `.mlir` | compiler/src/Terminal/Main.elm:296; compiler/src/Terminal/Make.elm:334 |
| `--refresh-registry` | on/off; off | Ignores the 30-minute registry TTL (`Registry.ForceRefresh`) | compiler/src/Terminal/Main.elm:300; compiler/src/Builder/Deps/Registry.elm:94 |
| `--config` | any non-empty path; default `<root>/eco-config.json` | Path to the tunable `eco-config.json` (see §3). A missing explicit path is a hard error; a missing default file is silently ignored | compiler/src/Terminal/Main.elm:304; compiler/src/Builder/Eco/Config.elm:36-72 |
| `--stats` | on/off; off | Collects front-end per-phase and per-module timing stats and prints them to stderr | compiler/src/Terminal/Main.elm:309 |

**Other command flags**

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `init --package` | on/off | Creates a package elm.json instead of an application one | compiler/src/Terminal/Main.elm:115 |
| `init --yes` | on/off | Answers yes to every prompt | compiler/src/Terminal/Main.elm:116 |
| `install --test` | on/off | Installs as a test dependency | compiler/src/Terminal/Main.elm:390 |
| `install --yes` | on/off | Answers yes to every prompt | compiler/src/Terminal/Main.elm:391 |
| `install --refresh-registry` | on/off | Ignores the 30-minute registry TTL | compiler/src/Terminal/Main.elm:392 |
| `uninstall --yes` | on/off | Answers yes to every prompt | compiler/src/Terminal/Main.elm:464 |
| `repl --interpreter` (disabled) | path, e.g. `node` | Chooses the JS interpreter | compiler/src/Terminal/Main.elm:170 |
| `repl --no-colors` (disabled) | on/off | Turns off REPL colors | compiler/src/Terminal/Main.elm:172 |
| `test --seed` (disabled) | int; default random | Fuzzer seed. **Its help text is swapped with `--fuzz`'s** | compiler/src/Terminal/Main.elm:667,702; compiler/src/Terminal/Test.elm:726 |
| `test --fuzz` (disabled) | int; default 100 | Runs per fuzz test (parsed into `maybeRuns`) | compiler/src/Terminal/Main.elm:666,703 |
| `test --report` (disabled) | `json` \| `junit` \| `console`; default console | Test report format | compiler/src/Terminal/Main.elm:668; compiler/src/Terminal/Test.elm:1307 |

**Library API** (`compiler/lib/index.js` drives `API.Main`, which reads a JSON argument through `Eco.Env.rawArgs`)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `{"command":"make", path, debug, optimize, sourcemaps}` | all fields required | Compiles one file to JS | compiler/src/API/Main.elm:194 |
| `{"command":"format", content}` | string | Formats Elm source | compiler/src/API/Main.elm:201 |
| `{"command":"install"\|"uninstall", pkg}` | `author/project` | Changes dependencies | compiler/src/API/Main.elm:205,209 |
| `{"command":"diagnostics", content \| path}` | one of the two | Syntax-checks a module | compiler/src/API/Main.elm:213 |
| (bad or missing JSON) | none | Falls back to `MakeArgs "" False False False` | compiler/src/API/Main.elm:147,150 |

### 2. Environment variables read by the front-end

Every `ECO_*` variable except `ECO_HOME` and `ECO_STAMP_GUARD_CENSUS` is read once per `make`, in `applyEnvOverrides` (`compiler/src/Builder/Eco/Config.elm:115-458`). The overrides apply **on top of** `eco-config.json` or the built-in defaults, in the listed order, so a later variable wins over an earlier broadcast. The value then feeds `Config.hash`, which keys the Details/artifact cache. Rows tagged **(hash)** add a cache token when non-default or enabled. Rows tagged **(no-hash)** are output-only or failure-only.

All reads go through `Utils.envLookupEnv`, then `Eco.Env.lookup`, then the XHR `Env.lookup` or the native kernel.

Parsing classes (inputs are trimmed and lower-cased unless stated otherwise):
- **B4**: `1|true|yes|on` turns on, `0|off` turns off, anything else is ignored. **`false`/`no` are NOT recognized as off.**
- **B3**: `1|true|yes` turns on, `0|false|no` turns off, anything else is ignored.
- **SET**: `1|true|yes` turns on. Anything else leaves the config unchanged (the variable cannot turn anything off).
- **INT**: `String.toInt` after trim. Non-numeric values are ignored.

#### 2a. Monomorphizer / LSS

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_MONO_ENGINE` | `subst\|solver\|diff` (case-insensitive); default `solver` | Feature: picks the monomorphizer engine. `diff` runs both engines and asserts they match. An unknown value prints a stderr warning and keeps the current engine. (hash, when non-default) | compiler/src/Builder/Eco/Config.elm:117 |
| `ECO_MONO_DIFF_DUMP` | SET; off | Debug: EngineDiff embeds full renderings on a mismatch | compiler/src/Builder/Eco/Config.elm:121 |
| `ECO_MONO_LSS` | exactly `0` \| `1` (`keyed`/`unkeyed` act as `1`); on | Feature: lambda-set specialization (solver engine only). `0` is the escape hatch | compiler/src/Builder/Eco/Config.elm:126 |
| `ECO_MONO_LSS_REPORT` | SET; off | Census: prints the LSS census to stderr after mono (no-hash) | compiler/src/Builder/Eco/Config.elm:131 |
| `ECO_MONO_LSS_MAX_SPECS` | INT (no range check); 0 = unlimited | Tuning: per-global keyed spec budget `maxSpecsPerGlobal` (hash `lssB=`) | compiler/src/Builder/Eco/Config.elm:136 |
| `ECO_MONO_LSS_MAX_SET_SIZE` | INT; 0 = unlimited | Tuning: a lambda set larger than this widens to LTop (hash) | compiler/src/Builder/Eco/Config.elm:141 |
| `ECO_MONO_LSS_INSTANCE_QUAL_MAX` | INT >= 0 (negative ignored); 8 | Tuning: cap on distinct member ids per local-multi let-function; 0 = unlimited (hash `lssIQM=`) | compiler/src/Builder/Eco/Config.elm:146 |
| `ECO_MONO_LSS_QCENSUS` | B3; off | Census: records, solves and scores the shadow inclusion constraints `Q`; costs compile time (hash `lssQC=`) | compiler/src/Builder/Eco/Config.elm:151 |
| `ECO_MONO_LSS_CENSUS` | B3; off | Census: collects the AbiCloning per-site census Dicts (byHost/niGuard/shape/papSites) (hash `lssCen=`) | compiler/src/Builder/Eco/Config.elm:156 |
| `ECO_MONO_LSS_ARROW_CENSUS` | B3; off | Census: applied vs never-applied arrow split. **Needs `ECO_MONO_LSS_REPORT` too** (hash `lssAC=`) | compiler/src/Builder/Eco/Config.elm:161 |
| `ECO_SPEC_TYPE_NODE_LIMIT` | INT; 400000; 0 disables | Watchdog (MONO_030): maximum MonoType nodes in one spec key; the compile fails above it (no-hash) | compiler/src/Builder/Eco/Config.elm:166 |
| `ECO_SPEC_BREADTH_LIMIT` | INT; 50000; 0 disables | Watchdog (MONO_030): maximum created specs per global (no-hash) | compiler/src/Builder/Eco/Config.elm:171 |
| `ECO_MONO_VALIDATE` | SET; off | Debug/CI: runs the MONO_029 layout validator, pre-mono `assertMinted` and the post-prune checks, and fails the compile on a violation. Env-only, not settable from JSON (no-hash) | compiler/src/Builder/Eco/Config.elm:176 |
| `ECO_STAMP_GUARD_CENSUS` | exact `1\|true\|yes`, **case-sensitive, not trimmed**; off | Census: per-module `[stampguard] walked= skipped= annWalked= annSkipped=` line on stderr, read once per module in the type-check phase. Not part of EcoConfig | compiler/src/Compiler/Compile.elm:574 |

#### 2b. Inliner / pre-mono transforms

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_INLINE_REPORT` | SET; off | Census: prints the inline census to stderr (no-hash) | compiler/src/Builder/Eco/Config.elm:181 |
| `ECO_INLINE_HOF_THRESHOLD` | INT (no clamp); 25 | Tuning: post-mono budget for candidates with a called function parameter; effective budget = `max postMonoThreshold hofThreshold` (hash `hthr=`) | compiler/src/Builder/Eco/Config.elm:186 |
| `ECO_INLINE_FPI` | INT (no clamp); 4 | Tuning: BROADCAST that sets both the pre- and post-mono fixpoint round counts | compiler/src/Builder/Eco/Config.elm:191 |
| `ECO_INLINE_LOOPIFY` | only `0\|false\|no` does anything (turns it off); on | Feature: recursive-HOF loopification (hash `loop=`) | compiler/src/Builder/Eco/Config.elm:196 |
| `ECO_ARITY_RAISE` | SET; off | Experimental: staged-spec arity raising (H6.2 U2b) (hash `ar=`) | compiler/src/Builder/Eco/Config.elm:201 |
| `ECO_ARITY_RAISE_MIN_APPLIED` | INT, clamped to 0..100; 0 | Tuning: raise only when at least this % of results are applied. Only matters with `ECO_ARITY_RAISE` (hash `arm=`) | compiler/src/Builder/Eco/Config.elm:206 |
| `ECO_INLINE_PARTIAL_HOF` | B3; off | Feature: lets HOF-budget candidates inline at strictly-partial call sites (hash `phof=`) | compiler/src/Builder/Eco/Config.elm:211 |
| `ECO_INLINE_PRESERVE_SETS` | B3; on | Feature: post-mono inliner declines the strictly-partial inline that clears an LSS member; overrides PARTIAL_HOF (hash `psets=`) | compiler/src/Builder/Eco/Config.elm:216 |
| `ECO_INLINE_PRUNE_DEAD` | B3; on | Feature: prunes dead specs after MonoInlineSimplify (hash `prune=`) | compiler/src/Builder/Eco/Config.elm:221 |
| `ECO_INLINE_THRESHOLD` | INT, `max 0`; 10 | Tuning: BROADCAST that sets the pre-mono, post-mono and eta thresholds. `0` means "no inlining anywhere" (hash `thr=`) | compiler/src/Builder/Eco/Config.elm:226 |
| `ECO_INLINE_PRE_MONO` | B3; **off** (since 2026-09-15) | Feature: runs `InlineSimplify` before mono (hash `preInl=`) | compiler/src/Builder/Eco/Config.elm:231 |
| `ECO_INLINE_POST_MONO` | B3; on | Feature: runs `MonoInlineSimplify` after mono (hash `postInl=`) | compiler/src/Builder/Eco/Config.elm:236 |
| `ECO_INLINE_ETA_EXPAND` | B3; on | Feature: `PreMono.EtaExpand` (eta-expansion to declared arity) (hash `eta=`) | compiler/src/Builder/Eco/Config.elm:241 |
| `ECO_INLINE_ETA_ONLY` | comma list of module-name prefixes; unset or empty = all | Debug/bisect: restricts EtaExpand to matching modules. Setting it to `""` overrides a JSON `etaOnly` | compiler/src/Builder/Eco/Config.elm:246 |
| `ECO_INLINE_ALIAS_FORWARD` | B3; on | Feature: `PreMono.AliasForward` (hash `afwd=`) | compiler/src/Builder/Eco/Config.elm:251 |
| `ECO_INLINE_PRE_MONO_THRESHOLD` | INT, `max 0`; 10 | Tuning: InlineSimplify size gate; overrides the broadcast (hash `preThr=`) | compiler/src/Builder/Eco/Config.elm:256 |
| `ECO_INLINE_POST_MONO_THRESHOLD` | INT, `max 0`; 10 | Tuning: MonoInlineSimplify budget (hash `postThr=`) | compiler/src/Builder/Eco/Config.elm:261 |
| `ECO_ETA_THRESHOLD` | INT, `max 0`; 10 | Tuning: EtaExpand cheapness gate (not an inline budget) (hash `etaThr=`) | compiler/src/Builder/Eco/Config.elm:266 |
| `ECO_INLINE_PRE_MONO_FPI` | INT; 4 | Tuning: pre-mono inliner round count (hash `preFpi=`) | compiler/src/Builder/Eco/Config.elm:271 |
| `ECO_INLINE_POST_MONO_FPI` | INT; 4 | Tuning: post-mono inliner round count (hash `postFpi=`) | compiler/src/Builder/Eco/Config.elm:276 |

#### 2c. CAF / borrow / list / aggregate / kernel-op / CSE

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_CAF_MEMO` | B3; on | Feature: CAF memoization, a lazy once-init `eco.global` slot per nullary SpecId (hash `cafm=`) | compiler/src/Builder/Eco/Config.elm:281 |
| `ECO_CAF_CENSUS` | SET; off | Census: inner-CAF opportunity census to stderr (no-hash) | compiler/src/Builder/Eco/Config.elm:286 |
| `ECO_CAF_HOIST` | B3; off | Feature: hoists closed inner expressions into memoized CAF slots (hash `cafh=`) | compiler/src/Builder/Eco/Config.elm:291 |
| `ECO_CAF_HOIST_MIN_NODES` | INT; 3 | Tuning: size floor for hoisting (hash `cafhN=`) | compiler/src/Builder/Eco/Config.elm:296 |
| `ECO_CAF_HOIST_MAX` | INT; 8192 | Tuning: global hoist budget (hash `cafhM=`) | compiler/src/Builder/Eco/Config.elm:301 |
| `ECO_CAF_DEDUPE` | B3; off | Feature: merges structurally identical nullary specs (hash `cafd=`) | compiler/src/Builder/Eco/Config.elm:306 |
| `ECO_BORROW` | `1\|true\|yes\|on` gives census oracle (reify off); `rc` gives reify=RRc (currently a no-op); `0\|off` disables; off | Feature/analysis: borrow inference (GlobalOpt Phase 6) | compiler/src/Builder/Eco/Config.elm:311 |
| `ECO_BORROW_REPORT` | SET (`1\|true\|yes`); off | Census: borrow census to stderr. **Also enables the borrow pass** (no-hash) | compiler/src/Builder/Eco/Config.elm:316 |
| `ECO_LIST_CHUNKS` | B4; on | Feature: chunked-list codegen (hash `lchunks=`) | compiler/src/Builder/Eco/Config.elm:321 |
| `ECO_LIST_REPORT` | SET; off | Census: List-combinator recognition census to stderr (no-hash) | compiler/src/Builder/Eco/Config.elm:326 |
| `ECO_LIST_CONS_INTRINSIC` | B4; on | Feature: `x :: xs` lowers to `eco.construct.list` (hash `lcons=`) | compiler/src/Builder/Eco/Config.elm:331 |
| `ECO_LIST_MAP_TEMPLATE` | B4; off | Feature: licensed `List.map` specs use the `eco.list.map` op. Inert unless chunks is on (hash `lmapt=`) | compiler/src/Builder/Eco/Config.elm:336 |
| `ECO_AGG_PROMOTE` | B4; on | Feature: non-escaping let tuples become `eco.make.tuple2/3` (hash `aggp`) | compiler/src/Builder/Eco/Config.elm:341 |
| `ECO_CTOR_INLINE` | B4; on | Feature: saturated constructor calls are inlined as `eco.construct.custom` (hash `ctori`) | compiler/src/Builder/Eco/Config.elm:346 |
| `ECO_SRET_RESULTS` | B4; on | Feature: tuple-returning functions get a multi-result `$sret` worker (hash `sretr`) | compiler/src/Builder/Eco/Config.elm:351 |
| `ECO_PSPLIT_PARAMS` | B4; on | Feature: projection-only aggregate params get a `$psplit` worker (hash `psplit`) | compiler/src/Builder/Eco/Config.elm:356 |
| `ECO_SRET_TAILFUNC` | B4; on | Feature: widens sret to tail funcs; no-op unless SRET_RESULTS (hash `srtf=`) | compiler/src/Builder/Eco/Config.elm:361 |
| `ECO_SRET_FRESH` | B4; on | Feature: widens sret to helper-mediated results; no-op unless SRET_RESULTS (hash `sretf=`) | compiler/src/Builder/Eco/Config.elm:366 |
| `ECO_BORROW_OPT` | B4; off | Feature: oracle-coupled transforms. On also enables borrow; applied after `ECO_BORROW`, so it wins over `ECO_BORROW=0` (hash `bopt=`) | compiler/src/Builder/Eco/Config.elm:371 |
| `ECO_STRING_LENGTH_OP` | B4; on | Feature: emits the inline `eco.string.length` op (hash `strlen=`) | compiler/src/Builder/Eco/Config.elm:376 |
| `ECO_APPEND_SPLIT` | B4; on | Feature: typed `eco.string.append` / `eco.list.append` where the type is known (hash `apsplit=`) | compiler/src/Builder/Eco/Config.elm:381 |
| `ECO_STRING_ORDER_INTRINSIC` | B4; on | Feature: String `lt/le/gt/ge` lower to `eco.string.cmp3` (hash `strord=`) | compiler/src/Builder/Eco/Config.elm:386 |
| `ECO_VALUE_EQ` | B4; on | Feature: boxed structural `==` lowers to `eco.value.eq` (hash `veq=`) | compiler/src/Builder/Eco/Config.elm:391 |
| `ECO_KERNEL_GCLEAF_EMIT` | B4; on | Feature: stamps `eco.gc_leaf` on eligible kernel declarations. This is the front-end switch; the backend switch is `ECO_KERNEL_GCLEAF` (hash `kgcl=`) | compiler/src/Builder/Eco/Config.elm:396 |
| `ECO_KERNEL_FACTS_DCE` | B4; on | Feature: the dead-let gate may drop droppable kernel calls (hash `kfdce=`) | compiler/src/Builder/Eco/Config.elm:401 |
| `ECO_KERNEL_COST_CLASSES` | B4; on | Feature: the inliner prices kernel calls by KernelFacts cost class instead of a flat 6 (hash `kcc=`) | compiler/src/Builder/Eco/Config.elm:406 |
| `ECO_KERNEL_COST_INLINE` | INT >= 0; 1 | Tuning: cost of a kernel call that lowers to an op | compiler/src/Builder/Eco/Config.elm:411 |
| `ECO_KERNEL_COST_GCLEAF` | INT >= 0; 4 | Tuning: cost of a CGcLeaf kernel call | compiler/src/Builder/Eco/Config.elm:416 |
| `ECO_KERNEL_COST_ALLOC` | INT >= 0; 8 | Tuning: cost of a CAlloc kernel call | compiler/src/Builder/Eco/Config.elm:421 |
| `ECO_KERNEL_COST_HOF` | INT >= 0; 20 | Tuning: cost of a CHof kernel call | compiler/src/Builder/Eco/Config.elm:426 |
| `ECO_CSE` | `1\|true\|yes\|on` / `0\|false\|no\|off`; off | Feature: Mono-level CSE of pure calls (hash `cse=`) | compiler/src/Builder/Eco/Config.elm:431 |
| `ECO_CSE_REPORT` | same as ECO_CSE; off | Census: CSE C1 census to stderr (no-hash) | compiler/src/Builder/Eco/Config.elm:436 |
| `ECO_CSE_MIN_COST` | INT >= 0; 5 | Tuning: cost floor for a CSE candidate (hash only when CSE is on) | compiler/src/Builder/Eco/Config.elm:441 |
| `ECO_CSE_MAX_PER_DEF` | INT >= 0; 64 | Tuning: cap on merge groups per definition (hash only when CSE is on) | compiler/src/Builder/Eco/Config.elm:446 |
| `ECO_CALL_PURITY` | B4; on | Feature: stamps `eco.cse_safe` on droppable direct kernel calls (hash `cpur=`) | compiler/src/Builder/Eco/Config.elm:451 |

#### 2d. Paths, registry, JS glue

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_HOME` | path; default is the app-data dir for `eco` (`~/.eco` on Linux in the Node XHR handler; the native kernel resolves it separately) | Package cache and home directory | compiler/src/Builder/Stuff.elm:411 |
| `GUIDA_REGISTRY` | URL; `https://package.elm-lang.org` | Package registry base URL (inherited from Guida) | compiler/src/Builder/Deps/Website.elm:25 |
| `GUIDA_JS_PATH` | path; `../../build/compiler/build-xhr/bin/guida.js` | `bin/index.js` (the npm `guida` bin) loads the compiled compiler JS from here | compiler/bin/index.js:34 |
| `APPDATA` | Windows only | Base for `File.appDataDir` in the XHR IO handler | compiler/bin/eco-io-handler.js:363 |
| (any name) | none | Generic `Env.lookup` passthrough: `process.env[name]` in the Node runners; `lib/index.js` uses the caller-supplied `config.env`, not `process.env` | compiler/bin/eco-io-handler.js:471; compiler/bin/eco-boot-runner.js:360; compiler/lib/index.js:199 |

`compiler/bin/eco-boot-runner.js:486` loads `../build-kernel/bin/eco-boot.js` from a hard-coded path; no environment variable changes it.

**Mentioned in front-end comments but NOT read by the front-end:** `ECO_KERNEL_GCLEAF` and `ECO_STRING_LEN_INLINE` (backend knobs), `ECO_DISPATCH_STATS` (runtime), `ECO_VERSION_OVERRIDE` (a CMake `-D` define that feeds the generated `Version_Build.elm`), and `ECO_MONO_DIFF` (a stderr message prefix, not a variable). None of the 70 variables that are read is dead: each one flows into an EcoConfig field or a Task that is used.

### 3. `eco-config.json` keys and compile-time defaults

`Compiler.Eco.Config.default` is at `compiler/src/Compiler/Eco/Config.elm:650-724`; the decoder is at `:731-937`. Every JSON field is optional and merges over the default; unknown keys, including `version`, are ignored. The env vars in §2 override these values.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `inline.{preMonoThreshold,postMonoThreshold,etaThreshold}` | int; 10 / 10 / 10 | Per-pass size budgets | compiler/src/Compiler/Eco/Config.elm:790-792 |
| `inline.whitelist` / `inline.blacklist` | string list; [] / [] | Whitelist is added to the built-in `defaultWhitelist` (MonoInlineSimplify.elm:990, Bytes.Encode primitives and similar); blacklist is subtracted | compiler/src/Compiler/Eco/Config.elm:793-794 |
| `inline.maxPerFunction` | int; 1000 | Maximum inlines per function | compiler/src/Compiler/Eco/Config.elm:795 |
| `inline.{pre,post}MonoFixpointIterations` | int; 4 / 4 | Round counts | compiler/src/Compiler/Eco/Config.elm:796-797 |
| `inline.hofThreshold` | int; 25 | HOF budget | compiler/src/Compiler/Eco/Config.elm:798 |
| `inline.loopify` / `arityRaise` / `raiseAppliedShareMin` | true / false / 0 | See the matching env rows | compiler/src/Compiler/Eco/Config.elm:799-801 |
| `inline.partialHof` / `preserveSets` / `pruneDead` | false / true / true | See the matching env rows | compiler/src/Compiler/Eco/Config.elm:802-804 |
| `inline.preMono` / `postMono` / `etaExpand` / `aliasForward` | false / true / true / true | Pass switches | compiler/src/Compiler/Eco/Config.elm:805-807,816 |
| `inline.etaOnly` / `inline.report` | [] / false | Debug | compiler/src/Compiler/Eco/Config.elm:808-809 |
| `inline.kernelFactsDce` / `kernelCostClasses` | true / true | Kernel-opt-11 | compiler/src/Compiler/Eco/Config.elm:810-811 |
| `inline.kernelCost{Inline,GcLeaf,Alloc,Hof}` | 1 / 4 / 8 / 20 | Kernel call cost vector | compiler/src/Compiler/Eco/Config.elm:812-815 |
| `bytesFusion.enabled` | bool; true | **JSON-only (no env var).** Bytes encoder/decoder fusion in MLIR codegen | compiler/src/Compiler/Eco/Config.elm:822; compiler/src/Compiler/Generate/MLIR/Expr.elm:3279 |
| `logicalTypes.customMaxFields` | int; 8, clamped to [1,24] with a stderr warning | **JSON-only.** Maximum fields for unboxed-aggregate single-ctor custom types | compiler/src/Compiler/Eco/Config.elm:845,963 |
| `cafMemo.{enabled,census,dedupe}` | true / false / false | CAF memoization | compiler/src/Compiler/Eco/Config.elm:828-830 |
| `cafMemo.hoist.{enabled,minNodes,maxHoists}` | false / 3 / 8192 | CAF hoisting | compiler/src/Compiler/Eco/Config.elm:837-839 |
| `mono.engine` | `subst\|solver\|diff`; built-in default `solver` | Engine. **Quirk: if the `mono` object is present but has no `engine`, the decoder's fallback string is `"subst"`, so the engine silently becomes subst.** An unknown string gives solver | compiler/src/Compiler/Eco/Config.elm:899 |
| `mono.lss.{enabled,maxSetSize,maxSpecsPerGlobal,report,qCensus,arrowCensus}` | true / 0 / 0 / false / false / false | LSS knobs | compiler/src/Compiler/Eco/Config.elm:919-927 |
| `mono.lss.instanceQualMaxInstances` / `mono.lss.census` | 8 / false | Stamp config | compiler/src/Compiler/Eco/Config.elm:936-937 |
| `mono.limits.{specTypeNodes,specBreadth}` | 400000 / 50000 | Watchdogs | compiler/src/Compiler/Eco/Config.elm:909-910 |
| `borrow.{enabled,reify,report,validate,oracleOpt}` | false / `"off"` (`off\|rc`) / false / false / false | Borrow. **`validate` is JSON-only** | compiler/src/Compiler/Eco/Config.elm:863-867 |
| `list.{chunks,consIntrinsic,mapTemplate}` | true / true / false | `list.report` is env-only | compiler/src/Compiler/Eco/Config.elm:769-771 |
| `cse.{enabled,minCost,maxPerDef}` | false / 5 / 64 | `cse.report` is env-only | compiler/src/Compiler/Eco/Config.elm:782-784 |
| `aggPromote`, `ctorInline`, `sretResults`, `psplitParams`, `sretFresh`, `sretTailFuncs`, `stringLengthOp`, `appendSplit`, `stringOrderIntrinsic`, `valueEq`, `kernelGcLeaf`, `callPurityAttrs` | bool; all true | Top-level feature switches (see the env rows) | compiler/src/Compiler/Eco/Config.elm:741-752 |
| (env-only fields) `mono.diffDump`, `mono.validate` | false | Only the env vars can set these | compiler/src/Compiler/Eco/Config.elm:893-894 |

Hard-coded source constants that behave like tuning knobs but have no switch:

| Name | Values / default | Effect | Source |
|---|---|---|---|
| Registry TTL | 30 min | How long before registry.dat is re-fetched; `--refresh-registry` bypasses it | compiler/src/Builder/Deps/Registry.elm:94 |
| `maxJoinRounds` | 100 | LSS_010 flush-round cap; the compile fails loudly beyond it | compiler/src/Compiler/MonoSolver/Monomorphize.elm:4108 |
| `maxSaturationPasses` | 5 | Stale-read re-translation cap | compiler/src/Compiler/MonoSolver/Monomorphize.elm:4510 |
| `maxIterConst` | 20 | Borrow fixpoint iteration cap | compiler/src/Compiler/GlobalOpt/Borrow.elm:126 |
| `maxTypedSlots` | 26 | MLIR typed-slot cap (containers: 32 Record / 24 Custom) | compiler/src/Compiler/Generate/MLIR/Types.elm:488 |
| `ctorTypedSlotCap` | 24 | AbiCloning copy of the constructor typed-slot bound | compiler/src/Compiler/GlobalOpt/AbiCloning.elm:3002 |
| `fingerprintDepth` | 4 | AbiCloning layout-fingerprint depth | compiler/src/Compiler/GlobalOpt/AbiCloning.elm:288 |
| `nullConsCapacity` | 1023 | Maximum constructor index for embedded null-constructor constants | compiler/src/Compiler/Data/CtorTag.elm:89 |
| `topSlowCap` | 5 | `--stats`: number of slowest modules listed | compiler/src/Builder/Eco/FEStats.elm:155 |

## C++ backend tools and native driver

Scope: command-line tools built from `runtime/src/` and `test/`, the in-process native driver used by the unified `eco` binary, backend (MLIR/LLVM lowering) environment variables, and kernel C++ environment variables and debug toggles. Heap/GC/allocator settings (`ECO_HEAP_CONFIG`, `ECO_GC_*`, nursery/tenure/P1-census env, heap JSON keys) are in [Runtime: heap and GC](#runtime-heap-and-gc). The one exception is `ECO_GC_EXIT_MAJOR`, which is listed below because it is read in the program entry code.

How environment values are read. Most backend switches use one of five patterns. The Values column says which one applies:

- **default-on, `0` = off**: the switch is on when the variable is unset, empty, or any value other than the exact string `0`.
- **default-off, `1` = on**: the switch is on only when the value is exactly `1` (or starts with `1` where noted).
- **presence**: the switch is on if the variable is set at all. Even `=0` turns it on.
- **non-empty, not `0`**: the switch is on for any non-empty value except `0`.
- **named**: the switch is on when the variable is set to any non-empty value. This is used to print one-line summaries for default-on transforms. A plain default build stays quiet, while any A/B run that sets the variable explicitly gets the summary.

Almost all backend switches are cached in a function-local `static` and read once per process. They take effect at **lowering time** (MLIR -> LLVM -> object) in every process that lowers:

- `eco-boot-native`
- `ecoc`
- the JIT E2E runner (`test`, through `EcoRunner`)
- the unified `eco` binary (its native driver runs in-process)

They do not affect the produced executable at run time. The E2E binary caches do not track the environment: to A/B a lowering switch you must delete the outputs.

### `eco-boot-native` (AOT native compiler CLI)

Source: `runtime/src/codegen/eco-boot.cpp`, target at `runtime/src/codegen/CMakeLists.txt:1585`. Usage: `eco-boot-native <input.elm|input.mlir|input.o> [options]`. What the input type does:

- `.elm`: runs the Node frontend, then lowers.
- `.mlir`: lowers directly.
- `.o`: re-link only, with no MLIR/LLVM work. It requires `--emit=exe`.

The CLI uses LLVM `cl::opt`, so options accept either `-opt` or `--opt`, and booleans accept `=true/false/0/1`.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `<input>` (positional) | required; `.elm`, `.mlir` or `.o` | File to compile; the extension selects the pipeline entry point | `runtime/src/codegen/eco-boot.cpp:111` |
| `-o <file>` | default depends on `--emit`: `a.out` (exe), `<input>.o` (obj), `<input>.ll` (llvm), stdout (mlir) | Output path. With the default `--emit=exe`, a `-o foo.o` gives object-only output, and a `.so`/`.node` output links a shared library | `runtime/src/codegen/eco-boot.cpp:116`, `:472`, `:767`, `:439` |
| `--emit=` | `exe` (default) \| `obj` \| `llvm` \| `mlir` | Output kind: linked executable, object file, post-RS4GC (+opt) LLVM IR, or MLIR (frontend only, `.elm` input only) | `runtime/src/codegen/eco-boot.cpp:131` |
| `-O <n>` / `-O=<n>` | unsigned, default `2` (values above 3 are clamped to 3) | LLVM optimisation level for the TargetMachine, the opt pipeline and codegen; `0` skips the LLVM opt pipeline | `runtime/src/codegen/eco-boot.cpp:141` |
| `--frontend=<path>` | default empty; required for `.elm` input | Path to the Node frontend runner (`eco-boot-2-runner.js`); invoked as `node <path> make --output=<abs> <abs.elm>` | `runtime/src/codegen/eco-boot.cpp:147`, `:275` |
| `--workdir=<path>` | default: auto (walks up from the input to the nearest `elm.json`) | Elm project root the frontend runs in (cwd) | `runtime/src/codegen/eco-boot.cpp:153` |
| `--verbose` | bool, default `false` | Echo frontend/link subcommands and the emitted object file(s) to stderr | `runtime/src/codegen/eco-boot.cpp:159` |
| `--gc-sections` | bool, default `false` | Link with `--gc-sections` (plus a `.llvm_stackmaps` KEEP script) to strip dead sections; binary size only; Linux executables only | `runtime/src/codegen/eco-boot.cpp:164` |
| `--split-codegen=<N>` | unsigned, default `0` (auto: cores, gated at about 4000 functions); `1` = off | Split the optimised module into N partitions emitted in parallel; executable output only | `runtime/src/codegen/eco-boot.cpp:170` |
| `--parallel-opt=` | `none` (default) \| `dev` \| `cgu` | Parallelise LLVM opt across partitions: `none` = whole-module -O then a codegen-only split; `dev` = cheap IPO + no-inline per-partition pipeline (fastest, lower quality); `cgu` = cheap IPO + full -O2 per partition | `runtime/src/codegen/eco-boot.cpp:177` |
| `--lazy-split` | bool, default `true` | Extract partitions lazily from one shared bitcode (ThinLTO-importer style); `=0` falls back to `llvm::SplitModule` | `runtime/src/codegen/eco-boot.cpp:192` |
| `--dev-emit-cg=<n>` | default `~0u` (follow `-O`); `0` None/FastISel, `1` Less, `2` Default | Overrides the per-partition CodeGen opt level; only takes effect with `--parallel-opt=dev` | `runtime/src/codegen/eco-boot.cpp:200` |
| `--dev-opt-o1` | bool, default `false` | Dev tier only: run the per-partition no-inline pipeline at O1 | `runtime/src/codegen/eco-boot.cpp:207` |
| `--rs4gc-after-opt` | bool, default `false` | EXPERIMENTAL: run RewriteStatepointsForGC after the O2 pipeline instead of before (risks REP_LLVM_001(a)) | `runtime/src/codegen/eco-boot.cpp:214` |
| `--dump-rs4gc-ir=<file>` | default empty | Write the LLVM IR after RS4GC to a file | `runtime/src/codegen/eco-boot.cpp:221` |
| `--dump-pre-rs4gc-ir=<file>` | default empty | Write the LLVM IR before RS4GC to a file | `runtime/src/codegen/eco-boot.cpp:227` |
| `--lowering-stats` | bool, **default `true`** | Print the per-phase/per-pass lowering timing breakdown to stderr at exit; `--lowering-stats=false` silences it | `runtime/src/codegen/eco-boot.cpp:233` |
| Standard MLIR options | see "Inherited LLVM/MLIR options" below | `registerAsmPrinterCLOptions` + `registerMLIRContextCLOptions` + `registerPassManagerCLOptions`; pass-manager options are applied to the lowering PassManager | `runtime/src/codegen/eco-boot.cpp:527-529`, `:362` |

Behaviour notes:

- **Target:** the target is always the native host. There is no `--target`/triple flag.
- **Verifier:** in release builds the per-pass MLIR verifier and the LLVM module verifier are off. Building with `-DECO_LOWERING_VALIDATION` turns them back on and adds extra audit passes.
- **Windows:** the MLIRContext is forced single-threaded (`:636`).

### `ecoc` (Eco dialect compiler / JIT test tool)

Source: `runtime/src/codegen/ecoc.cpp`, target at `runtime/src/codegen/CMakeLists.txt:461`. Usage: `ecoc <input.mlir> [options]`.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `<input.mlir>` (positional) | required | Eco-dialect MLIR input | `runtime/src/codegen/ecoc.cpp:112` |
| `-o <file>` | default `-` | **DEAD**: declared but never read. MLIR dumps go to stderr (`module->dump()`), and LLVM IR and JIT output go to stdout | `runtime/src/codegen/ecoc.cpp:117` |
| `-emit=` | `mlir` \| `mlir-eco` \| `mlir-opt` \| `mlir-llvm` (default) \| `llvm` \| `jit` | Stage to stop at: input MLIR; after the eco-to-eco passes; after the M4 slot (fold-project + CSE, before GC prep); after full LLVM-dialect lowering; LLVM IR after RS4GC (+opt); JIT-compile and run `main` | `runtime/src/codegen/ecoc.cpp:135` |
| `-opt` | bool, default `false` | Enable LLVM optimisation (`CodeGenOptLevel::Aggressive` + O3 transformer) for `llvm`/`jit` | `runtime/src/codegen/ecoc.cpp:148` |
| `-verify-diagnostics` | bool, default `false` | **DEAD**: declared but never read | `runtime/src/codegen/ecoc.cpp:153` |
| `-dump-rs4gc-ir=<file>` | default empty | Write the post-RS4GC LLVM IR to a file (`-emit=llvm` path) | `runtime/src/codegen/ecoc.cpp:158` |
| `-no-verify-parse` | bool, default `false` | Parse without running the verifier, so invalid IR can be dumped (for example with `-emit=mlir`). The module is still verified right after parsing (`:451`), so this helps only if that verify passes | `runtime/src/codegen/ecoc.cpp:168` |
| Standard MLIR options | see below | Same three registrations as `eco-boot-native` | `runtime/src/codegen/ecoc.cpp:414-416` |

### `ecogen` (legacy parse/verify/print tool)

Source: `runtime/src/ecogen.cpp`, target at `runtime/src/codegen/CMakeLists.txt:433` ("legacy, for parsing only"). It registers only the Eco and func dialects and allows unregistered dialects. It does not register the standard MLIR option groups.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `<input .mlir>` (positional) | required | File to parse and verify | `runtime/src/ecogen.cpp:31` |
| `-o <file>` | default `-` (stdout) | Where the re-printed module goes | `runtime/src/ecogen.cpp:36` |
| `-verify-only` | bool, default `false` | Stop after verification (always prints "Verification successful!" to stdout) | `runtime/src/ecogen.cpp:42` |
| `-mlir-print-debuginfo` | bool, default `false` | Print location debug info in the output | `runtime/src/ecogen.cpp:47` |

### `ecor` (standalone GC workload demo / allocator debug tool)

Source: `runtime/src/main.cpp`, target at `CMakeLists.txt:414` (`EXCLUDE_FROM_ALL`, POSIX only, needs RapidCheck). Uses `getopt_long`.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `-d, --duration <time>` | `<n>s\|sec\|m\|min\|h\|hr`; default `0` = run until Ctrl+C | How long to run | `runtime/src/main.cpp:570`, `:109` |
| `-f, --fields <n>` | integer >= 1, default `8` | Number of fields (lists) in the model record | `runtime/src/main.cpp:571`, `:107` |
| `-l, --list-size <n>` | integer >= 1, default `500` | Integers per list | `runtime/src/main.cpp:572`, `:108` |
| `-t, --threshold <frac>` | (0, 1], **default `0.5`** | Old-gen fill fraction that triggers a major GC. The help text says "default: 0.9" and the header example uses `-t 100`, which is rejected: both are wrong | `runtime/src/main.cpp:573`, `:110`, `:520` |
| `-p, --probability <p>` | [0, 1], default `0.5` | Probability of reversing each field's list per step | `runtime/src/main.cpp:574`, `:112` |
| `-n, --threads <n>` | integer >= 1, default `1` | Number of program threads, each with its own heap | `runtime/src/main.cpp:575`, `:113` |
| `--dfs` / `--no-dfs` | default on | Two-pass list-spine copying (hybrid DFS) vs pure Cheney BFS; sets `config.use_hybrid_dfs` | `runtime/src/main.cpp:576-577`, `:695` |
| `-h, --help` | | Print usage | `runtime/src/main.cpp:578` |

### Unified `eco` binary: in-process native driver

The unified `eco` binary (`compiler/CMakeLists.txt:876`, plus `eco-quick` at `:941`) gets its CLI from the Elm compiler, which another section covers. For `--output` to a native target, `Terminal/Make.elm` calls the kernel intrinsic `Eco.NativeDriver.lowerAndLink mlirPath outputPath rootModule` (`eco-kernel-cpp/src/Eco/NativeDriver.elm:46`). That goes through `Eco::Kernel::NativeDriver` (`eco-kernel-cpp/src/eco-kernel/NativeDriver.cpp`) to the C ABI `eco_native_lower_and_link` / `eco_native_lower_and_link_bytes` (`runtime/src/codegen/EcoNativeAPI.h`, `runtime/src/codegen/EcoNativeDriver.cpp:1206`, `:1215`). Both build a **default** `EcoNativeOptions`. None of the options below can be set from the `eco` command line; only `rootModule` is passed through. Binaries linked without `EcoNativeDriverStatic` get weak stubs that return -1 (`runtime/src/codegen/eco_native_stub.cpp`).

`EcoNativeOptions` (`runtime/src/codegen/EcoNativeDriver.h:24`):

| Field | Default (fixed for `eco`) | `eco-boot-native` equivalent | Effect |
|---|---|---|---|
| `optLevel` | `2` | `-O` | LLVM opt level |
| `splitCodegen` | `0` (auto) | `--split-codegen` | Parallel object emission |
| `parallelOpt` | `0` = none (`1` = dev, `2` = cgu) | `--parallel-opt` | Parallel opt tier |
| `lazySplit` | `true` | `--lazy-split` | Lazy partition extraction |
| `devEmitCodeGenLevel` | `~0u` | `--dev-emit-cg` | Dev-tier codegen level |
| `devOptO1` | `false` | `--dev-opt-o1` | Dev-tier O1 |
| `verbose` | `false` | `--verbose` | Echo link command |
| `preRS4GCDumpPath` / `postRS4GCDumpPath` | empty | `--dump-pre-rs4gc-ir` / `--dump-rs4gc-ir` | IR dumps |
| `rootModule` | from caller (empty = omit) | none | Baked in as the `__eco_root_module` symbol, which names the `Elm.<Root>` N-API export |
| `stats` | `nullptr` | `--lowering-stats` | Timing collector (the `eco` path prints nothing) |
| `gcSections` | `false` | `--gc-sections` | `--gc-sections` link |

The native driver has no `rs4gcAfterOpt` field, so that option exists only in `eco-boot-native`. All backend environment variables listed below still apply to `eco`, because lowering runs in the same process.

Linker/runtime lookup environment used by the native driver (`eco-boot-native` and `eco`):

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_RUNTIME_DIR` | path; unset = auto | Where the runtime/kernel static libraries used at link time are found. If set, it is trusted unconditionally (`dir/[subdir/]basename`, even if the file is missing). Otherwise the driver uses `<exe dir>/../lib/eco-runtime` if the file exists there, then falls back to the build-tree path. Also sets the glibc output-profile probe (`$ECO_RUNTIME_DIR/glibc`) that enables `.so`/`.node` outputs | `runtime/src/codegen/EcoBootConfig.cpp:45`, `:75`, `:98` |

### Embedding and Node addon entry points (API, not CLI)

These are not command-line flags, but they are how startup options reach a compiled program:

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `eco_app_start(argc, argv, flags_json)` | `flags_json` may be NULL (no flags) | Host C API. `argv` backs `Eco.Kernel.Env.rawArgs`; `flags_json` is decoded by the program's flags decoder, and a mismatch crashes at startup. One app per process | `runtime/src/embed/eco_embed.h:51`, `runtime/src/embed/eco_embed.cpp:238` |
| Node addon `Elm.<Root>.init({flags})` | `flags` optional; undefined decodes as `null` | `JSON.stringify(opts.flags)` is passed to the embed API; `init` may be called only once per process | `runtime/src/embed/eco_node_addon.cpp:350` |
| Generated program `argv` | none | `main()` in `eco_entry.cpp` stores argc/argv for `Eco.Kernel.Env.rawArgs` (argv[0] is dropped). Compiled executables parse **no runtime flags of their own**. They run `eco_main` on a 64 MiB-stack thread | `runtime/src/codegen/eco_entry.cpp:118`, `:300`, `eco-kernel-cpp/src/eco-kernel/Env.cpp:40` |

### Backend lowering environment variables: MLIR pipeline (eco dialect)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_MLIR_FOLD` | default-on, `0` = off; `census` = on + print running totals | Runs the `EcoFoldProject` pass in the M4 slot (folds projections of constructs) | `runtime/src/codegen/EcoPipeline.cpp:97`, `runtime/src/codegen/Passes/EcoFoldProject.cpp:40`, `:49` |
| `ECO_MLIR_FOLD_BLOCK_LOCAL` | non-empty, not `0`; default off | Restricts fold-project to producers in the same block (bisection aid) | `runtime/src/codegen/Passes/EcoFoldProject.cpp:54` |
| `ECO_MLIR_FOLD_LIST` | non-empty, not `0`; default off | Also folds `eco.list.head`/`tail` of constructed lists (experimental; it has crashed EcoListCursor) | `runtime/src/codegen/EcoOps.cpp:1229` |
| `ECO_MLIR_CSE` | non-empty, not `0`; **default off** | Adds a func-level CSE pass in the M4 slot. It is kept off because merging NaN-containing constructs gives wrong equality results | `runtime/src/codegen/EcoPipeline.cpp:96` |
| `ECO_CMPCASE` | default-on, `0` = off; named = print `[cmpcase]` counts | `EcoCompareCaseRewrite`: `compare` + case-on-Order is lowered to direct comparisons | `runtime/src/codegen/Passes/EcoCompareCaseRewrite.cpp:76`, `:83` |
| `ECO_VALUE_EQ_STRCASE` | default-on, `0` = off | String `case` if-chains are lowered through `eco.value.eq`. It is read in two files that must agree | `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp:720`, `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp:38` |
| `ECO_LIST_MAP_EXPAND` | default-on, `0` = off | `eco.list.map` expands to the forward scratch-stack template; `0` emits the order-preserving collapse instead | `runtime/src/codegen/Passes/EcoListTemplate.cpp:705` |
| `ECO_LIST_TEMPLATE_DEBUG` | presence | Debug trace from EcoListTemplate | `runtime/src/codegen/Passes/EcoListTemplate.cpp:348` |
| `ECO_LIST_CURSOR_DEBUG` | presence | Debug trace from EcoListCursor | `runtime/src/codegen/Passes/EcoListCursor.cpp:118` |
| `ECO_GCLEAF_MARK` | default-on, `0` = off | `EcoMarkGCLeafCalls` stamps `eco.callee_gc_leaf` on calls to `eco.gc_leaf` kernels | `runtime/src/codegen/Passes/EcoMarkGCLeafCalls.cpp:65` |
| `ECO_GCLEAF_MARK_REPORT` | presence | Prints the `[gcleaf-mark]` decl/site counts | `runtime/src/codegen/Passes/EcoMarkGCLeafCalls.cpp:95` |
| `ECO_GCPREPARE_CENSUS` | presence | Prints the `[gcprepare-census]` allocation-group opportunity census (no IR change) | `runtime/src/codegen/Passes/EcoGCPrepare.cpp:132` |
| `ECO_GCPREPARE_SPLIT_INLINE_GROUPS` | default-on, `0` = off | Splits allocation groups whose members all have inline lowerings (`0` restores grouping) | `runtime/src/codegen/Passes/EcoGCPrepare.cpp:150` |
| `ECO_GCPREPARE_LEAF_SAFEPOINT` | default-on, `0` = off | Calls stamped `eco.callee_gc_leaf` are not treated as safepoints (no root operands) | `runtime/src/codegen/Passes/EcoGCLiveness.h:41` |
| `ECO_LAX_CASE_VERIFY` | presence (even `0` enables it) | Turns `eco.case`/`eco.yield` type-mismatch verifier errors into warnings, for dumping invalid IR. Never set it in real builds | `runtime/src/codegen/EcoOps.cpp:273`, `:314` |

### Backend lowering environment variables: Eco -> LLVM dialect

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_ECO2LLVM_PARALLEL` | default-on, `0` = serial | Per-function body conversion in EcoToLLVM runs in parallel; `0` forces serial (determinism bisection) | `runtime/src/codegen/Passes/EcoToLLVM.cpp:469` |
| `ECO_ECO2LLVM_STATS` | presence | Prints wall-time for EcoToLLVM's serial sub-stages | `runtime/src/codegen/Passes/EcoToLLVM.cpp:160` |
| `ECO_INLINE_ALLOC` | default-on, `0` = off | Inline nursery bump allocation (HEAP_034); `0` emits `eco_alloc_*` calls instead (needed for `ECO_CLOSURE_STATS` and GC-stats census) | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:812` |
| `ECO_INLINE_DEREF_EXT` | default-on, `0` = off | Extended inline HPointer deref classes; `0` restores out-of-line `eco_resolve_hptr`/`eco_get_tag` | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:794` |
| `ECO_INLINE_ZERO` | default-off; value starting with `1` = on | Forces payload zeroing on every inline allocation (bisection only; changes code) | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:959` |
| `ECO_KERNEL_GCLEAF` | default-on, `0` = off | Honours the `eco.gc_leaf` attribute on kernel declarations; `0` ignores it everywhere, which also disables `ECO_GCLEAF_MARK` | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:832` |
| `ECO_STRING_LEN_INLINE` | default-on, `0` = off | `eco.string.length` becomes an inline header load; `0` calls `Elm_Kernel_String_length` | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:859` |
| `ECO_CAF_CALLER_FAST` | default-on, `0` = off | Caller-side CAF slot fast path (load/test diamond) | `runtime/src/codegen/Passes/EcoToLLVMInternal.h:1283` |
| `ECO_STRLIT_CACHE` | default-on, `0` = off | String-literal slot cache at call sites; `0` restores the bare alloc call | `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp:780` |
| `ECO_ORDER_FROM_SIGN` | default-on, `0` = off | Order result is built with one gc-leaf call from the sign; `0` restores the three-getter shape | `runtime/src/codegen/Passes/EcoToLLVMArith.cpp:1016` |
| `ECO_SLOT_CAST_BARRIERS` | default-on, `0` = off | Emits `__eco_slot_to_hptr`/`__eco_hptr_to_slot` barriers (REP_LLVM_002). `0` also forces the `$cap` inliner into GC-call-free-only mode | `runtime/src/codegen/Passes/EcoSlotCastBarriers.h:41` |
| `ECO_SAT_FAST` | default-on, `0` = off | Saturated-call fast edge: MLIR-side sat markers/descriptors (Closures) and backend diamond expansion. Both read the same variable | `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1522`, `runtime/src/codegen/EcoBackend.cpp:1657` |
| `ECO_PAP_HISTO` | presence | Prints PAP/dispatch lowering histograms and `[sat-expand]` counts at backend exit (no behaviour change) | `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1537`, `runtime/src/codegen/EcoBackend.cpp:1808` |
| `ECO_LSS_DISPATCH_SITE_COUNTERS` | presence | Emits per-site fast-dispatch counters, which the runtime reports under `ECO_DISPATCH_STATS`. Census builds only; the binary differs | `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1279` |

### Backend lowering environment variables: LLVM IR backend (`EcoBackend.cpp`, RS4GC/opt/emit)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_GCFREE_LEAF` | default-on (stamp); `0` = off; `c` = census only; named = print `[gcfree]` summary | Propagates GC-free functions and stamps `gc-leaf-function`, so RS4GC skips statepoints on calls to them | `runtime/src/codegen/EcoBackend.cpp:114`, `:2642` |
| `ECO_GCFREE_LEAF_DUMP` | path | Writes the names of GC-free functions to a file | `runtime/src/codegen/EcoBackend.cpp:2630` |
| `ECO_FP_LEAF` | default-on, `0` = off; named = print `[gcfree-fp]` line | Adds `frame-pointer=all` only to functions with statepoints or root-stack registration; `0` adds it to every function | `runtime/src/codegen/EcoBackend.cpp:1049`, `:1084` |
| `ECO_ALLOC_HOIST` | default-on; `0` = off; `c` = census; named = print summary | Capacity-check hoisting (needs `ECO_GCFREE_LEAF` in stamp mode) | `runtime/src/codegen/EcoBackend.cpp:138`, `:3373` |
| `ECO_ALLOC_HOIST_MAX_BYTES` | integer, default `512`; clamped to [8, 4096] and rounded down to a multiple of 8 | Per-run byte budget cap for hoisting | `runtime/src/codegen/EcoBackend.cpp:157` |
| `ECO_ALLOC_HOIST_M2` | default-on, `0` = off | M2: folds a root function's own markers into the hoisted run | `runtime/src/codegen/EcoBackend.cpp:174` |
| `ECO_ALLOC_HOIST_DUMP` | path | Writes coverable functions (`name;budget;sites;…`) to a file | `runtime/src/codegen/EcoBackend.cpp:3335` |
| `ECO_CAP_INLINE_MAX_INSTS` | integer, default `64`; `0` disables | Size threshold for the pre-RS4GC `$cap` AlwaysInline prepass | `runtime/src/codegen/EcoBackend.cpp:3379` |
| `ECO_CAP_INLINE_LIST` | path to a file with one symbol per line | Marks exactly the listed `$cap` functions and ignores the threshold (delta-debug) | `runtime/src/codegen/EcoBackend.cpp:3387` |
| `ECO_CAP_INLINE_GCFREE_ONLY` | presence | Restricts `$cap` inlining to GC-call-free bodies (forced automatically when slot-cast barriers are off) | `runtime/src/codegen/EcoBackend.cpp:3412` |
| `ECO_CAP_INLINE_DEBUG` | presence | Prints a `[cap-inline]` line per marked function | `runtime/src/codegen/EcoBackend.cpp:3420` |
| `ECO_CAP_GCLEAF_REPORT` | named | Prints the count of `$cap` clones that ended up gc-leaf | `runtime/src/codegen/EcoBackend.cpp:2668` |
| `ECO_INLINE_BUMP_STATE` | default-on, `0` = off | Replaces `eco_bump_state()` calls with an initial-exec TLS load (AOT only; the JIT keeps the call) | `runtime/src/codegen/EcoBackend.cpp:1239` |
| `ECO_TLS_ROOT_STACK` | default-on, `0` = off | Inlines constant-count root-stack range registration through the TLS root stack pointer | `runtime/src/codegen/EcoBackend.cpp:1507` |
| `ECO_VALUE_EQ_INLINE` | default-on, `0` = off | Expands `__eco_value_eq` markers into a word-equality diamond; `0` makes a bare call | `runtime/src/codegen/EcoBackend.cpp:2149` |
| `ECO_VALUE_EQ_GCLEAF` | default-off; exactly `1` = on | Stamps the value-eq slow call as gc-leaf | `runtime/src/codegen/EcoBackend.cpp:2157` |
| `ECO_CALL_CENSUS` | non-empty, not `0`; `1`/`all` = every bucket, or a comma list of `elm,kernel,cap,helper,runtime,extern,indirect` | Instruments surviving call instructions per bucket. The runtime dumps the counts under `ECO_DISPATCH_STATS`. Census only; changes the binary | `runtime/src/codegen/EcoBackend.cpp:245`, `:257` |
| `ECO_FCA_SCAN` | presence | Scans for aggregate-with-GC-pointer instructions after the pre-RS4GC fold: prints `FCA-SCAN: clean`, or `report_fatal_error` listing the sites | `runtime/src/codegen/Passes/EcoPtrIntVerify.cpp:501` |

### Program-run-time instrumentation environment (runtime, non-GC)

These are read by the runtime (`runtime/src/allocator/RuntimeExports.cpp`) when a compiled program runs, not at lowering time. They are listed here because they pair with the backend census switches above. The GC section may also list them.

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `ECO_DISPATCH_STATS` | non-empty, not `0` | At exit, dumps the per-closure-evaluator sat/gen/fast dispatch table, plus the `ECO_CALL_CENSUS` tables if they were compiled in | `runtime/src/allocator/RuntimeExports.cpp:1043`, `:1141` |
| `ECO_CLOSURE_STATS` | non-empty, not `0` | At exit, dumps per-evaluator closure creates/extends (blind at inline-alloc sites; build with `ECO_INLINE_ALLOC=0`) | `runtime/src/allocator/RuntimeExports.cpp:877` |
| `ECO_CONS_SITES` | presence | Tallies cons allocations per site and dumps them at exit | `runtime/src/allocator/RuntimeExports.cpp:368` |
| `ECO_GC_EXIT_MAJOR` | exactly-`1` prefix (`[0]=='1'`) | Forces one major GC after `eco_main` returns, so the exit stats show the live retained set (GC section cross-reference) | `runtime/src/codegen/eco_entry.cpp:132`, `:200` |

### Kernel C++ environment variables and debug toggles

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `TZ` | IANA name, optional leading `:` | `Time.here`/zone name: used before `/etc/localtime` on Linux, macOS and Windows | `elm-kernel-cpp/src/time/TimeExports.cpp:92`, `:130`, `:151` |
| `CURL_CA_BUNDLE` | path | CA bundle for HTTPS when the request has no explicit `caInfo` (libcurl does not read this itself). The AOT E2E runner sets it to its test server's cert | `runtime/src/platform/HttpService.cpp:229`, `test/aot_e2e_main.cpp:127` |
| `PATH` (Windows also `Path`) | standard | `Eco.File.findExecutable` search path | `eco-kernel-cpp/src/eco-kernel/File.cpp:190` |
| `HOME`; Windows `APPDATA` -> `USERPROFILE` -> `HOME` | standard | `Eco.File.appDataDir` base (`~/.name`, `~/Library/Application Support/name` on macOS, `%APPDATA%/name` on Windows) | `eco-kernel-cpp/src/eco-kernel/File.cpp:350-361` |
| any name (`Eco.Env.lookup`) | arbitrary | Elm programs read any variable through `Eco.Kernel.Env.lookup` (evaluated at task-step time) | `eco-kernel-cpp/src/eco-kernel/Env.cpp:32` |
| `ECO_KERNEL_DEBUG` (compile-time macro / CMake option) | CMake option default **OFF**; the `dev` preset turns it ON | Enables `ECO_KLOG` `[eco-kernel:<tag>]` stderr traces in the ElmKernel_Http, EcoKernel_Http and EcoKernel_File targets. The header comment in `KernelDebug.hpp` says "defaults ON", which is stale | `CMakeLists.txt:247`, `eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp:17`, `elm-kernel-cpp/src/KernelDebug.hpp:15`, `elm-kernel-cpp/CMakeLists.txt:343`, `eco-kernel-cpp/CMakeLists.txt:300` |

### Test runners (`test/`)

`TEST_FILTER` is not read by any C++ code. It is a CMake-target convention: the targets `check`, `run-tests`, `full`, `stress`, `run-mlir-equivalence` and `run-aot-e2e` wrap the runner in `sh -c '<runner> ${TEST_FILTER:+--filter "$TEST_FILTER"}'` (`CMakeLists.txt:1184`, `:1192`, `:1202`, `:1219`, `test/CMakeLists.txt:309`, `:377`). All `--filter` options below match by **substring** of the test name (`test/TestSuite.hpp:289`).

#### `test` (unit + JIT E2E suite): `test/main.cpp`

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `-n, --num-test-loops <N>` (alias `--num-tests`) | > 0, default `5` | RapidCheck `max_success` per property | `test/main.cpp:294`, `:89` |
| `-s, --seed <SEED>` | uint64; default time-based | RapidCheck seed, printed for reproduction | `test/main.cpp:296` |
| `-m, --max-size <N>` | > 0, default `50` | RapidCheck `max_size` | `test/main.cpp:297`, `:90` |
| `--max-discard-ratio <N>` | > 0, default `10` | RapidCheck `max_discard_ratio` | `test/main.cpp:298`, `:91` |
| `-v, --verbose` | off | Verbose output and statistics | `test/main.cpp:299` |
| `--list` | off | List tests without running them | `test/main.cpp:300` |
| `-f, --filter <PAT>` | empty = all | Run only tests whose name contains PAT | `test/main.cpp:301` |
| `-r, --repeat <N>` | > 0, default `1` | Run the suite N times (cannot be combined with `--duration`) | `test/main.cpp:302` |
| `-t, --duration <TIME>` | `<n>s\|m\|h\|d` | Loop the suite until TIME expires, then exit 0 | `test/main.cpp:303` |
| `--timeout <TIME>` | same units | Fail if the run exceeds TIME | `test/main.cpp:304` |
| `--no-shrink` | off | **DEAD**: parsed into `config.no_shrink`, never used | `test/main.cpp:305`, `:375` |
| `--reproduce <STRING>` | empty | **DEAD**: parsed into `config.reproduce`, never used | `test/main.cpp:306`, `:378` |
| `--no-show-seed` | seed shown | Hide the seed banner | `test/main.cpp:307` |
| `-i, --interactive` | off | Interactive test/suite selection loop | `test/main.cpp:308`, `:1172` |
| `-h, --help` | | Help | `test/main.cpp:309` |
| env `RC_PARAMS` (written, not read) | | The runner overwrites RapidCheck's `RC_PARAMS` from the flags above, so a user-set `RC_PARAMS` is ignored | `test/main.cpp:237` |
| env `ECO_TEXT_MLIR` | set and not `0` | JIT E2E: passes `--text-mlir` to the frontend (text MLIR instead of bytecode) | `test/TestSuite.hpp:24`, `test/ElmE2ETestBase.hpp:480` |

The unit tests ignore `ECO_HEAP_CONFIG` for the old generation; see the GC section.

#### `stress-test` (Elm stress programs): `test/stress-elm/main.cpp` (POSIX only)

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `-f, --filter <PAT>` | all | Substring filter | `test/stress-elm/main.cpp:88` |
| `-r, --repeat <N>` | default `1` | Repeat the suite (cannot be combined with `--duration`) | `test/stress-elm/main.cpp:89` |
| `-t, --duration <TIME>` | `s\|m\|h\|d` | Loop until TIME, then exit 0 (cannot be combined with `--timeout`) | `test/stress-elm/main.cpp:90` |
| `--timeout <TIME>` | | Fail when exceeded; also passed to Elm as `StressFlags.timeoutMs` | `test/stress-elm/main.cpp:91` |
| `-n, --num-test-loops <N>` | default `100` | Passed to Elm as `StressFlags.numLoops` | `test/stress-elm/main.cpp:92`, `:25` |
| `-m, --max-size <M>` | default `100` | Passed to Elm as `StressFlags.maxSize` | `test/stress-elm/main.cpp:93`, `:27` |
| `-s, --seed <SEED>` | default `0` (= time-based per help) | Passed to Elm as `StressFlags.seed` | `test/stress-elm/main.cpp:94` |
| `--list` | | List tests | `test/stress-elm/main.cpp:95` |
| `-v, --verbose` | | Verbose; also `StressFlags.verbose` | `test/stress-elm/main.cpp:96` |
| `-h, --help` | | Help | `test/stress-elm/main.cpp:97` |

#### `aot-e2e-runner` (Elm -> MLIR via the Stage 3 JS runner -> `eco-boot-native` -> run ELF): `test/aot_e2e_main.cpp`

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `--filter <pat>` / `--filter=<pat>` | all | Substring filter on the display name | `test/aot_e2e_main.cpp:526` |
| `--jobs <N>` / `--jobs=<N>` | default = hardware cores (fallback 4); clamped to [1, 16] | Concurrent tests | `test/aot_e2e_main.cpp:530`, `:513` |
| `--list`, `-h/--help` | | List / help. An unknown argument prints help | `test/aot_e2e_main.cpp:522-524` |
| env `AOT_E2E_JOBS` | integer > 0 | Overrides `--jobs` (the environment wins over the flag) | `test/aot_e2e_main.cpp:539` |
| env `ECO_AOT_EXTRA_FLAGS` | whitespace-split string | Extra arguments added to every `eco-boot-native` call, for example `--parallel-opt=dev` | `test/aot_e2e_main.cpp:392` |

The runner runs the frontend as `node --stack-size=65536 … make --optimize` with `NODE_OPTIONS=--max-old-space-size=12000` (`test/aot_e2e_main.cpp:364-377`).

#### `mlir-equivalence` (Stage 2 JS vs Stage 6 native compiler byte-identical MLIR): `test/mlir_equivalence_main.cpp`

| Name | Values / default | Effect | Source |
|---|---|---|---|
| `--filter <pat>` / `--filter=<pat>` | all | Substring filter | `test/mlir_equivalence_main.cpp:401` |
| `--jobs <N>` / `--jobs=<N>` | default `4`; clamped to [1, 16] | Concurrency | `test/mlir_equivalence_main.cpp:405`, `:388` |
| `--list`, `-h/--help` | | List / help | `test/mlir_equivalence_main.cpp:397-399` |
| env `MLIR_EQUIV_JOBS` | integer > 0 | Overrides `--jobs` | `test/mlir_equivalence_main.cpp:414` |

### Inherited LLVM/MLIR options (`eco-boot-native`, `ecoc`)

Both tools call `registerAsmPrinterCLOptions()`, `registerMLIRContextCLOptions()` and `registerPassManagerCLOptions()`, and apply them to the lowering PassManager (`applyPassManagerCLOptions`). Every upstream option is therefore accepted. The most useful ones:

- `--mlir-print-ir-before=<pass>` / `--mlir-print-ir-after=<pass>` / `--mlir-print-ir-before-all` / `--mlir-print-ir-after-all` / `--mlir-print-ir-after-change` / `--mlir-print-ir-after-failure` / `--mlir-print-ir-module-scope`
- `--mlir-timing` / `--mlir-timing-display=list|tree` (per-pass timing; `eco-boot-native` also prints its own `--lowering-stats`)
- `--mlir-pass-statistics`, `--mlir-pass-pipeline-crash-reproducer=<file>`
- `--mlir-disable-threading` (also turns off `ECO_ECO2LLVM_PARALLEL`'s parallel path), `--mlir-print-op-on-diagnostic`, `--mlir-print-stacktrace-on-diagnostic`
- `--mlir-print-debuginfo`, `--mlir-print-op-generic`, `--mlir-elide-elementsattrs-if-larger=<n>`
- Every LLVM `cl::opt` linked into the binary is also accepted (for example `--time-passes`, `--print-after-all`, and `-debug-only=` when LLVM is built with assertions).

There is no flag for the target triple or CPU: both tools use `JITTargetMachineBuilder::detectHost()` or `createEcoTargetMachine`.

### Compile-time switches that change tool behaviour

The CMake options themselves are covered in another section.

- `ECO_LOWERING_VALIDATION`: turns on the MLIR per-pass verifier and the LLVM module verifier in `eco-boot-native`/`ecoc`/`eco`. Adds the `CheckEcoClosureCaptures`, `EcoGCLivenessAudit` and `EcoBoxedStoreVerify` passes (`runtime/src/codegen/EcoPipeline.cpp:61`, `:158`, `:176`; `runtime/src/codegen/eco-boot.cpp:365`).
- `ECO_KERNEL_DEBUG`: kernel stderr tracing (table above).
- `ENABLE_GC_STATS` / `ECO_GC_DEBUG` / `P1_CENSUS_COMPILED` / `ECO_HEAP_VALIDATE`: change what `ecor` and generated programs print at exit, and add GC checks (GC section).
- `_WIN32`: `eco-boot-native` runs the MLIRContext single-threaded and exits through `TerminateProcess`.

### Dead or inconsistent items

- **Dead flags:**
  - `ecoc -o` and `ecoc -verify-diagnostics` are declared but never read.
  - `test --no-shrink` and `test --reproduce` are parsed but never used.
  - `ecoc -no-verify-parse` is close to dead: `main()` runs `verify(*module)` right after parsing (`runtime/src/codegen/ecoc.cpp:451`), so invalid IR still fails before `-emit=mlir` can dump it.
- **Wrong `ecor` help text:**
  - It says `--threshold` defaults to 0.9; the code default is 0.5.
  - The header example `-t 100` is rejected, because the value must be ≤ 1.0.
- **Stale comment:** `KernelDebug.hpp` says `ECO_KERNEL_DEBUG` "defaults ON"; the CMake default is OFF.
- **Presence-type variables where `=0` still enables the switch:** `ECO_LAX_CASE_VERIFY`, `ECO_FCA_SCAN`, `ECO_PAP_HISTO`, `ECO_GCPREPARE_CENSUS`, `ECO_GCLEAF_MARK_REPORT`, `ECO_ECO2LLVM_STATS`, `ECO_LIST_TEMPLATE_DEBUG`, `ECO_LIST_CURSOR_DEBUG`, `ECO_LSS_DISPATCH_SITE_COUNTERS`, `ECO_CAP_INLINE_GCFREE_ONLY`, `ECO_CAP_INLINE_DEBUG`, `ECO_CONS_SITES`.
- **Precedence:** `AOT_E2E_JOBS` and `MLIR_EQUIV_JOBS` override an explicit `--jobs`. The environment beats the flag, which is the reverse of the usual convention.
- **Unified `eco`:** backend options (opt level, split/parallel-opt, gc-sections, IR dumps) cannot be reached from `eco`. It always uses `EcoNativeOptions{}` defaults, and only the environment variables above can change its lowering.

## Runtime: heap and GC

All runtime heap/GC tuning lives in one struct, `Elm::HeapConfig` (`runtime/src/allocator/AllocatorCommon.hpp:600`). Each field's default comes from a `constexpr` constant earlier in that file (`AllocatorCommon.hpp:51-382`). The table defaults below are read from that code.

### How configuration is resolved

| Step | What happens | Source |
|---|---|---|
| 1. Struct defaults | `Allocator::initialize(const HeapConfig& = HeapConfig())` starts from the in-class initializers. The generated-program entry calls `initialize()` with no arguments, so it gets pure struct defaults. | `runtime/src/allocator/Allocator.hpp:84`, `runtime/src/codegen/eco_entry.cpp:103` |
| 2. `ECO_HEAP_CONFIG` | If set and non-empty, it must be a **file path** to a JSON object. Inline JSON is not accepted: the value goes to `std::ifstream`. Keys are applied on top of step 1. An **unknown key throws** (`std::invalid_argument`), so the program fails at heap init. | `runtime/src/allocator/HeapConfigJson.cpp:485-489`, `:154-275` |
| 3. `ECO_GC_*` / region env vars | Applied after the JSON file, so **env beats JSON** (see the env table). | `HeapConfigJson.cpp:591-612`, `Allocator.cpp:246` |
| 4. `resolveNurseryRegions()` | `nursery_regions = 2` (auto) becomes 1; an incompatible config throws (see `nursery_regions` below). | `AllocatorCommon.hpp:949-951`, `Allocator.cpp:247` |
| 5. `validate()` | Range and cross-field checks. On failure it throws `std::invalid_argument`. | `AllocatorCommon.hpp:953-1386` |
| First-init-only geometry | The reservation and the nursery/old-gen split (`nursery_offset`) are computed once, on the first `initialize()`. `reset()` re-derives slice geometry but never the region. | `Allocator.cpp:282-286` |

**Byte-size values** can be a JSON integer (raw bytes) or a string with a power-of-two suffix: `K`/`M`/`G`, optionally followed by `B` or `iB`, e.g. `"16M"` or `"512KiB"` (`HeapConfigJson.cpp:33-93`). The same parser also reads several *count* keys: `nursery_block_count`, `nursery_max_block_count`, `mark_work_ratio`, `string_tiny_slice_limit`, `utf8_view_min_len`, `minor_sweep_divisor`, `incremental_mark_min_slice_units` and `heal_parallel_min`. So `"1K"` is accepted there and means 1024.

**Fraction** keys must be JSON numbers in [0, 1]; values outside that are rejected at parse time (`HeapConfigJson.cpp:95-106`). **Double** keys only need to be numbers; `validate()` checks their range. **u32/i32** keys must be JSON integers.

**No compiled-in JSON exists.** `compiler/cmake/bootstrap/build-kernel/heap-config.json` is copied to `build/compiler/build-kernel/heap-config.json` at configure time (`compiler/CMakeLists.txt:193-200`). The runtime never reads it on its own. It takes effect only when a harness sets `ECO_HEAP_CONFIG` to it, e.g. `heap-profile.py:60,1085`.

That file lists all **88** keys at their current struct defaults, and so does `heap-profile.py` `BASELINE_HEAP`. Both are generated from a default-constructed `HeapConfig` and checked to round-trip through `applyHeapConfigJsonFile`, so a harness baseline is exactly the shipped configuration. "Auto" values are written as their sentinels (thread counts `0`, `nursery_regions` `2`, `nursery_region_eden_flip` `-1`). Regenerate both files when a default in `AllocatorCommon.hpp` changes.

**Unit-test caveat (verified).** `TestHelpers::initAllocatorWith` (`test/allocator/TestHelpers.cpp:39-50`) calls `initialize(config)` and then `AllocatorTestAccess::reset(alloc, &config)`. `Allocator::reset` (`Allocator.cpp:1023-1047`) re-applies only `resolveNurseryRegions()` and `validate()`; it never re-reads `ECO_HEAP_CONFIG` or `ECO_GC_*`. As a result:

- Env and JSON affect only the *first* `initialize()` of a test binary.
- Even that config is immediately overwritten by the test's own programmatic config.
- The one lasting effect is the first-init region split and the helper jitter.

The test binaries (`test`, `stress-test`) run every isolated test and every E2E program in a spawned child, `<self> --isolated-child <result> <kind> <args…>` (kinds `case`, `codegen`, `bf-codegen`, `elm`; `test/SpawnedChildren.hpp`, SYS_008). That mode is internal: the harness passes a zero-filled result file the child maps, and captures the child's stdout and stderr in a per-test file. `initAllocator` takes the config as given, so unit tests run the region nursery by default. `initLegacyAllocator` is the only route to the legacy nursery, for the tests whose subject it is (plans/region-nursery-everywhere.md). E2E children re-install the production config at every `EcoRunner::reset()` (`Allocator::environmentConfig()`), and `test/RegionNurseryGuard.hpp` fails any E2E program that is not on the region nursery unless the environment asks for legacy. To change minor threads across the whole suite, use `ECO_TEST_MINOR_THREADS`, which is applied into each test config (`TestHelpers.cpp:17-31`).

**Other programmatic config.** `runtime/src/main.cpp:693-696`, the standalone runtime stress harness, sets `max_heap_size = 2G` and `use_hybrid_dfs` from its CLI.

"Auto" thread counts are resolved in `OldGenSpace.cpp:2922-2968`. `gc::availableCpus()` returns the affinity mask, capped by the cgroup v2 quota (`GCHelperPool.hpp:308-311`). Every "auto" below uses it. On this 24-CPU host the defaults resolve to 16 markers, 8 minor workers and 4 background markers.

### Heap config JSON keys — heap-wide and placement

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `max_heap_size` | bytes | 24 GiB | Virtual reservation for the whole heap; the old-gen cap is this minus the nursery region. Must be > 0 and ≤ 8 TB (the HPointer limit). | `AllocatorCommon.hpp:75,604`; `Allocator.cpp:258` |
| `nursery_region_bytes` | bytes | 0 = policy `min(4 GiB, max_heap_size/2)` → 4 GiB | Address space for the nursery region; the old gen gets the rest (HEAP_043). If nonzero it must be a multiple of `2*alloc_buffer_size`, ≥ `nursery_max_block_count*alloc_buffer_size`, and ≤ `max_heap_size/2`. | `AllocatorCommon.hpp:88,618,840-848,1119-1138` |
| `alloc_buffer_size` | bytes | 512 KiB | Size of one nursery block and one old-gen BBoP page. Must be ≥ the OS page, ≤ the old-gen cap, and must divide `initial_old_gen_size`. | `AllocatorCommon.hpp:91,621` |
| `large_object_threshold` | bytes | 8 KiB | At or above this, an allocation bypasses the nursery (split header for strings/bytes). Must be ≤ `alloc_buffer_size`. For the region nursery it must also be ≤ the largest old-gen size class + 8; otherwise `nursery_regions` auto throws (set 0 for the legacy nursery). | `AllocatorCommon.hpp:94,624,925-935` |
| `large_ptr_nursery_divisor` | u32 | 8 | A large pointer-bearing object goes to the nursery if its size ≤ min(nursery capacity / divisor, max size); otherwise it goes to the young LOS (YLOS). 0 = always YLOS. | `AllocatorCommon.hpp:100,629` |
| `large_ptr_nursery_max_size` | bytes (multiple of 8) | 128 KiB | Fixed upper bound for the placement rule above. 0 = no fixed bound. | `AllocatorCommon.hpp:103,630` |

### Heap config JSON keys — strings / ropes (not GC, but same file)

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `string_flatten_limit` | UTF-16 units (byte-size parser) | **128K** (131072; 32K until 2026-09-29) | Concat results at or below this flatten to a leaf; larger ones build a rope. | `AllocatorCommon.hpp:110,655` |
| `string_tiny_slice_limit` | UTF-16 units | 128 | Slices at or below this are copied instead of allocating a `StringSlice`. | `:111,638` |
| `utf8_view_min_len` | bytes | 32 | Minimum ASCII payload for a zero-copy `StringUtf8View`. | `:116,642` |
| `utf8_strings_enabled` | bool | true | Master switch for UTF-8 string forms. | `:120,645` |
| `rope_max_height` | u32 | 32 | Rebalance heuristic flag only. The rebalance itself is TODO. | `:123`; `StringOps.cpp:267` |
| `rope_leaf_count_limit` | u32 | 64 | Rebalance heuristic (paired with the next key). | `:126`; `StringOps.cpp:268` |
| `rope_min_leaf_size` | u32 | 128 | Rebalance heuristic: average leaf size threshold. | `:129`; `StringOps.cpp:269` |

### Heap config JSON keys — nursery and minor GC

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `nursery_block_count` | count (even, ≥ 2) | 256 (= 64 MiB per side) | Initial nursery size in blocks. Must be ≤ `nursery_max_block_count`, and the initial per-side size must fit one slice. | `AllocatorCommon.hpp:134,659` |
| `nursery_max_block_count` | count (even) | **384** (192 MiB total; 1024 → 512 on 2026-09-22, 512 → 384 on 2026-09-29) | Adaptive growth ceiling; sets minor pause length (p99 8 ms at 128 blocks … 65 ms at 1024). It also sets the region-nursery extent stride: the next power of two ≥ `(nmbc/2)*abuf`, i.e. 128 MiB. Regions per slot = region bytes / (extents × stride). | `:148,682` |
| `nursery_gc_threshold` | fraction (0, 1] | 0.95 | Nursery occupancy that triggers a minor GC. | `:143,665`; `NurserySpace.cpp:126,340` |
| `nursery_growth_threshold` | fraction (0, 1) | 0.20 | Post-minor survivor occupancy above which the nursery grows. Used by both the legacy and region nursery. | `:146,668`; `NurserySpace.cpp:410`, `NurseryRegion.cpp:193` |
| `promotion_age` | u32, 1..3 | **1** (tuned from 2 on 2026-09-22) | Legacy nursery: survivals before promotion. **Region nursery: tenure age k** (TG7b). It also sets geometry: survivor extents = k + 2. The region nursery requires k ∈ 1..3. | `:152,671,884-888` |
| `use_hybrid_dfs` | bool | true | DFS spine copying for Cons lists in minor GC. Honoured by the serial, parallel and region engines. | `:155,674`; `NurserySpace.cpp:1984`, `NurseryParallel.cpp:511`, `NurseryRegion.cpp:608` |
| `gc_minor_threads` | u32, 0..64 | 0 = auto: `min(cap, availableCpus)` | Parallel minor copy workers (TG6, HEAP_067). 1 = serial Cheney reference. Forced to 1 if `old_gen_bitmap_alloc` is off. | `:238,716`; `OldGenSpace.cpp:2946-2953` |
| `gc_minor_threads_cap` | u32, 1..64 | 8 | Cap for auto minor workers. | `:239,717` |
| `minor_lab_bytes` | bytes, multiple of 8, 4 KiB..1 MiB | 8 KiB | Per-worker to-space LAB size. | `:240,718` |
| `minor_parallel_min_bytes` | bytes | 4 MiB | A minor with less from-space object data than this runs serially. Also gates the parallel tenure engine. | `:241,719`; `NurseryParallel.cpp:598`, `NurseryTenure.cpp:535` |
| `minor_prefetch_children` | bool | true | Child prefetch in the parallel minor. | `:242,720` |
| `minor_fifo_order` | bool | false (LIFO, depth-first) | Grey order of the parallel minor. This is a retention input: promotion order changes the old-gen peak. | `:246,721`; `NurseryParallel.cpp:646` |
| `nursery_regions` | u32: 0 / 1 / 2 | **2 = auto** | 0 = legacy semi-space nursery. 1 = region nursery (eden + survivor extents, HEAP_069); throws if incompatible. 2 = region nursery; an incompatible config throws (never a silent fallback to legacy; legacy must be 0, explicitly). Compatible means: `promotion_age` 1..3, `old_gen_bitmap_alloc`, LOT ≤ largest class + 8, and ≥ 1 heap slot. **At defaults this resolves to 1.** | `:263,724,912-951` |
| `nursery_region_eden_flip` | i32: −1 / 0 / 1 | −1 = on only in `ECO_HEAP_VALIDATE` builds | Double-buffered (quarantined) eden in the region nursery. Adds one extent per slot. | `:264,725,880-883` |
| `tenure_mode` | u32: 1 / 2 | **2 = concurrent** | Region-nursery tenure job. 1 = runs in the hand-over pause (exact reference). 2 = runs on the heap's tenure collector during the next epoch (TG7d default). | `:265,726` |
| `tenure_sync_threads` | u32, 0..64 | 1 | Threads for a synchronous tenure job. 1 = exact engine; 0 = the minor's worker count. | `:266,727`; `NurseryTenure.cpp:520` |
| `tenure_help` | u32: 0 / 1 | 1 | A late concurrent job at the next pause: 0 = wait, 1 = stop it and finish it in the pause. | `:267,728`; `NurseryTenure.cpp:587,616` |
| `tenure_help_threads` | u32, 0..64 | 0 = the minor's worker count | Threads used when helping a late job. 1 = exact. | `:268,729` |
| `tenure_priority` | i32, 0..20 | 0 = inherit | Nice value of the tenure collector thread; 20 = SCHED_IDLE. Never lowered by default: that was the 5c trap. | `:269,730` |
| `heal_parallel_min` | count (heal slots) | 65536 | Above this many heal slots, the heal runs on the gang. | `:270,731` |
| `shadow_granule_log2` | u32: 3 or 4 | 4 (16-byte granule) | Granule of the region nursery's shadow map. 4 halves the shadow versus 3 and **requires every survivor ≥ 16 B**: a smaller one aborts in every build. HEAP_071 guarantees it, because an empty String or Bytes is the Empty constant, never a heap object. 3 (8-byte granule) has no limit. | `:286,754`; `NurseryRegion.cpp:134,404` |
| `tenure_collector_threads` | u32, 1..32 | 1 | Tenure collector threads per heap in mode 2. 1 = exact engine; > 1 = concurrent parallel engine. | `:275,733` |
| `tenure_fifo_order` | bool | false (LIFO) | Promotion order of the exact tenure engine. This is a retention input. | `:278,734` |

### Heap config JSON keys — old generation, major-GC triggers, marking

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `initial_old_gen_size` | bytes | 16 MiB | Old-gen commit at startup. Must be > 0, a multiple of `alloc_buffer_size`, and < the old-gen cap. | `AllocatorCommon.hpp:160,679` |
| `major_gc_initiating_occupancy` | fraction (0, 1) | **0.95** (tuned from 0.85 on 2026-09-22) | Occupancy trigger: committed/cap above this schedules a major. Must be > `major_gc_target_utilization`. | `:166,682` |
| `major_gc_global_pressure_fraction` | fraction (0, 1] | 0.85 | GlobalPressure trigger (anti-ballooning backstop) as a fraction of the old-gen cap. | `:177,685` |
| `major_gc_target_utilization` | fraction (0, 1) | 0.50 | Post-major live/committed target that drives cap growth. | `:180,688` |
| `major_gc_garbage_fraction` | fraction [0, 1) | 0.70 | Garbage-fraction trigger: bytes allocated since the last major, as a fraction of committed. 0 disables it. The major trigger is **chaotic** (small gf changes move major count and old-gen peak non-monotonically, see `plans/threaded-gc-07b-tenure-ageing.md` §7): judge it on a sweep, never one point. | `:183,691` |
| `major_gc_live_budget` | double ≥ 0 | 3.0 | LiveBudget trigger: a major fires when bytes allocated since the last major reach k × live_ref. 0 = off. The one deterministic RSS lever (lower k = more majors, lower peak). 3.0 since 2026-09-29, when the validate failures it exposed (HEAP_072, HEAP_051) were fixed; 4.5 before. | `:362,788` |
| `live_growth_bound` | double, 0 or ≥ 1 | 1.5 | live_ref = min(L_i, r × L_{i−1}). 0 = off. | `:339,765` |
| `major_gc_live_budget_paced` | bool | true | Measure LiveBudget at the hand-off instead of t0 (5c Part B). | `:307,745` |
| `major_gc_headroom_margin` | double, 0..8 | 1.5 | Enables the Headroom trigger (> 0). It starts the cycle earlier when near the cap. | `:306,744` |
| `major_gc_garbage_backstop` | fraction; 0 or in (`major_gc_garbage_fraction`, 1) | 0.0 (off) | While LiveBudget is on, raises the garbage-fraction threshold to this value. | `:308,746` |
| `garbage_denom_cap` | double, 0 or ≥ 1 | 0 (uncapped) | Bitmap mode only: garbage-trigger denominator = min(committed, cap × committed at the last major). | `:331,762` |
| `demote_live_fraction` | double [0, 1] | 0.3 | At the end of mark, a uniform block becomes mixed if live ≤ this × block size. 0 = never. | `:325,758` |
| `decommit_on_oldgen_release` | bool | true | `madvise(DONTNEED)` released old-gen blocks. This now goes through the deferred PageWork path. | `:186,695`; `Allocator.cpp:811`, `PageWork.hpp:51` |
| `old_gen_bitmap_alloc` | bool | true | Bitmap allocation for uniform size-class blocks plus gap sweep (HEAP_054). **Required by** incremental and concurrent mark, parallel minor/mark and the region nursery. Turning it off also requires `incremental_mark=false`, otherwise `validate()` throws. | `:214,710` |
| `incremental_mark` | bool | true | Spreads the major mark over the following minors (TG5a, HEAP_063). | `:315,749` |
| `incremental_mark_slices` | u32, ≤ 4096 | 32 | T = slices per cycle. 0 = the whole cycle in the t0 pause. | `:316,750` |
| `incremental_mark_min_slice_units` | count ≥ 1 | 16384 | Minimum mark work per slice (about 0.7 ms). | `:317,751` |
| `incremental_mark_predict_growth` | double, 1..4 | 1.25 | Growth factor in the slice-pacing prediction. | `:318,752`; `OldGenSpace.cpp:4153` |
| `incremental_mark_finish_fraction` | double in (`global_pressure_fraction`, 1] | 0.95 | Cap fraction at which a running cycle is forced to finish. | `:319,753` |
| `gc_mark_threads` | u32, 0..64 | 0 = auto: `min(cap, availableCpus)` | Parallel foreground markers (TG5b, HEAP_064). 1 = serial reference. Forced to 1 without bitmap alloc. | `:222,713`; `OldGenSpace.cpp:2922-2930` |
| `gc_mark_threads_cap` | u32, 1..64 | 16 | Cap for auto markers. | `:223,714` |
| `conc_mark` | u32: 0 / 1 / 2 | **2 = concurrent** | 0 = in-pause slices (05b). 1 = whole mark in the t0 pause (determinism reference). 2 = background markers, with the mutator assisting when late (TG5c, HEAP_065). Mode 2 needs `incremental_mark` and bitmap alloc. | `:290,737`; `OldGenSpace.cpp:2955-2968` |
| `conc_mark_threads` | u32, 0..63 | 0 = auto: `min(cap, CPUs−1)` | Background markers. Clamped to 64 − foreground markers. | `:291,738` |
| `conc_mark_threads_cap` | u32, 1..63 | 4 | Cap for auto background markers. | `:292,739` |
| `conc_mark_priority` | i32, 0..20 | 0 = inherit | Background marker nice value; 20 = SCHED_IDLE. A low priority caused pauses of up to 9.5 s, so keep 0. | `:293,740` |
| `conc_mark_assist_lag` | u32, ≤ 4096 (cycle steps) | 8 | Grace period before the mutator assists a lagging concurrent mark. | `:294,741` |
| `small_class_heap_budget_bytes` | bytes | 1 GiB | Cap on bytes committed to uniform small-class pages before larger free cells are split. 0 disables. | `:342,768` |
| `small_class_cell_max_bytes` | bytes (0 or ≥ 16) | 8 KiB (= `LARGE_OBJECT_THRESHOLD`) | Cell-size cap that defines "small" for the budget above. | `:771` |

### Heap config JSON keys — helper threads, decommit, commit-ahead (TG3)

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `gc_thread_mode` | u32: 0 / 1 / 2 | **2 = concurrent** | GC helper pool. 0 = off (inline, no pool). 1 = jobs run inline at the post point (reference). 2 = jobs run on `GCHelperPool`. | `AllocatorCommon.hpp:192,699`; `Allocator.cpp:1212` |
| `gc_helper_threads` | u32, 1..64 | 1 | Helper pool size. | `:193,700`; `Allocator.cpp:1226` |
| `gc_helper_cpu` | i32 ≥ −1 | −1 = no pinning | Pins the helper thread to a CPU. | `:194,701` |
| `decommit_delay_syncs` | u32 (pause ends) | UINT32_MAX = never | A released extent is discarded after this many unused pause ends. | `:200,702` |
| `decommit_pending_max_bytes` | bytes | 0 = no cap | Cap on released-but-not-yet-decommitted bytes. | `:201,703` |
| `decommit_delay_majors` | u32 (majors) | 1 | A released extent is discarded after this many unused major GCs. 0 = off. | `:205,704` |
| `commit_ahead_bytes` | bytes (multiple of the OS page) | 128 MiB | Commits and populates this much above the old-gen bump. 0 = off. | `:209,705` |

### Heap config JSON keys — old-gen sweep pacing

| Name | Type / units | Default | Effect | Source |
|---|---|---|---|---|
| `sweep_work_budget` | bytes > 0 | 4 KiB | Lazy-sweep work per slow-path slice. | `AllocatorCommon.hpp:347,777` |
| `minor_sweep_divisor` | count | 1 (no throttle) | Divides `sweep_work_budget` for promotion allocations inside a minor. 0 = no sweep during promotion. Added in W7. | `:786` |
| `initial_sweep_budget` | bytes ≥ `sweep_work_budget` | 64 KiB | Synchronous sweep done at the end of `finishMarkAndSweep`. | `:350,789` |
| `mark_work_ratio` | count ≥ 1 | 2 | **No effect** (W0 item 13): its only reader was dead code. Still accepted so old files parse. | `:353,795-796`; `OldGenSpace.cpp:1877` |
| `sweep_bytes_per_alloc_byte` | double > 0 | 2.0 | Base per-allocation sweep budget, as bytes swept per byte requested. | `:356,799`; `OldGenSpace.cpp:2075-2084` |
| `max_sweep_bytes_per_alloc` | bytes ≥ `sweep_work_budget` | 1 MiB | Soft cap applied before pressure scaling. | `:359,802` |
| `max_sweep_bytes_hard` | bytes ≥ soft cap | 4 MiB | Hard cap applied after scaling and the boost. | `:362,805` |
| `sweep_cap_ratio_low` / `_medium` / `_high` | doubles, 0 < low < med < high < 1 | 0.50 / 0.75 / 0.90 | Committed/cap pressure steps. | `:365-367,808-810` |
| `sweep_scale_low` / `_medium` / `_high` / `_crit` | doubles ≥ 1, non-decreasing | 1 / 2 / 4 / 8 | Sweep budget multiplier for each pressure step. | `:370-373,813-816` |
| `sweep_unswept_ratio_boost` | double (0, 1) | 0.50 | Unswept-block fraction that triggers the boost. | `:376,819` |
| `sweep_unswept_scale` | double ≥ 1 | 2.0 | Boost multiplier. | `:379,822` |
| `panic_sweep_slice_bytes` | bytes ≥ `sweep_work_budget` | 1 MiB | Slice size of the panic sweep before OOM. | `:382,825` |

The following are **compile-time only** and cannot be changed from JSON:

- `MARK_CHUNK_ELEMS` 1024, `MINOR_CHUNK_ELEMS` 1024, `MINOR_SPINE_RUN` 512 (`AllocatorCommon.hpp:224,247,248`)
- Size-class layout: `NUM_SMALL_CLASSES` 32, `MAX_SMALL_SIZE` 256, `MEDIUM_CLASS_BASE` 512, `NUM_MEDIUM_CLASSES_MAX` 8 (`:391-403`)
- `OS_PAGE_SIZE` (`:68-70`)

### Runtime environment variables — heap/GC configuration (override JSON)

All of these are read only in `Allocator::initialize()` (`Allocator.cpp:244-246`), so they apply on first init only. An invalid value throws.

| Name | Type / units | Default (unset) | Effect | Source |
|---|---|---|---|---|
| `ECO_HEAP_CONFIG` | file path | unset | JSON heap config file (see above). Must be a path, not inline JSON. | `HeapConfigJson.cpp:486` |
| `ECO_GC_THREAD` | `0` / `1` / `2` | — (keeps `gc_thread_mode` = 2) | Sets `gc_thread_mode`. | `HeapConfigJson.cpp:494-497,592` |
| `ECO_GC_HELPER_JITTER_US` | decimal µs ≤ 100000 | 0 | Injected jitter for the helper pool and mark gang, for determinism and race tests. Not a HeapConfig field. | `HeapConfigJson.cpp:499-514`; `OldGenSpace.cpp:2936` |
| `ECO_GC_MARK_THREADS` | decimal 0..64 | — (auto) | Sets `gc_mark_threads`. | `HeapConfigJson.cpp:518-529` |
| `ECO_GC_MINOR_THREADS` | decimal 0..64 | — (auto) | Sets `gc_minor_threads`. | `HeapConfigJson.cpp:532-543` |
| `ECO_GC_CONC_MARK` | `0` / `1` / `2` | — (2) | Sets `conc_mark`. | `HeapConfigJson.cpp:548-553` |
| `ECO_GC_CONC_MARK_THREADS` | decimal 0..63 | — (auto) | Sets `conc_mark_threads`. | `HeapConfigJson.cpp:554-565` |
| `ECO_NURSERY_REGIONS` | `0` / `1` / `2` | — (2 = auto) | Sets `nursery_regions`. | `HeapConfigJson.cpp:572-576` |
| `ECO_TENURE_MODE` | `1` / `2` | — (2) | Sets `tenure_mode`. | `HeapConfigJson.cpp:577-581` |
| `ECO_NURSERY_EDEN_FLIP` | `-1` / `0` / `1` | — (−1) | Sets `nursery_region_eden_flip`. | `HeapConfigJson.cpp:582-588` |
| `ECO_TENURE_COLLECTORS` | decimal 1..32 | — (1) | Sets `tenure_collector_threads`. | `HeapConfigJson.cpp:600-606` |
| `ECO_TENURE_FIFO` | `0` / `1` | — (0) | Sets `tenure_fifo_order`. | `HeapConfigJson.cpp:607-611` |

There is **no env override** for the other 78 keys (10 keys have one). They can only be changed through `ECO_HEAP_CONFIG`.

### Runtime environment variables — behaviour switches, stats, logs, validation

| Name | Type | Default | Effect | Build requirement | Source |
|---|---|---|---|---|---|
| `ECO_GC_EVENT_LOG` | file path | unset | Per-collection TSV log. | Minor, major, pause and cycle rows need `ECO_GC_PHASE_TIMERS`. Helper-job and stall rows need `ECO_GC_STATS`. | `GCStats.cpp:2611`; `ThreadLocalHeap.cpp:634-682,915`; `Allocator.cpp:1189` |
| `ECO_GC_PHASE_PROFILE` | any value except `0` | off | Prints `[gc-profile]` lines to stderr for majors and cycle hand-offs. | none | `ThreadLocalHeap.cpp:44-51,799,1224` |
| `ECO_GC_EXIT_MAJOR` | `1` | off | Forces one major GC at exit so the exit stats report the live retained set. | none (the report itself needs stats) | `runtime/src/codegen/eco_entry.cpp:132,200` |
| `ECO_HEAP_TRACE` | any value except `0` | off | Prints `[heap-trace]` growth and GC dumps. | `-DECO_HEAP_TRACE=ON` | `Allocator.cpp:78-93` |
| `ECO_OLDGEN_DEBUG` | set / unset | off | Old-gen block and free-list debug prints. | none | `OldGenSpace.cpp:34,4897,5097` |
| `ECO_NURSERY_BULK_CLEAR` | `1` | off | Restores bulk to-space / eden zeroing, which per-site zeroing replaced. This is the bisection switch. | none | `NurserySpace.cpp:2368`; `NurseryRegion.cpp:1042` |
| `ECO_CAF_PERMANENT` | `0` disables | on | Puts CAF values and interned objects in PermanentSpace. `0` reverts to rooted old-gen allocation. | none | `PermanentSpace.cpp:98`; `RuntimeExports.cpp:666` |
| `ECO_P1_CENSUS` | `0` / `1` / `2` | 2 in validate builds, 1 in census builds | P1 survivor-write census: off, count, or abort on the first violation. | `-DECO_P1_CENSUS=ON` or `ECO_HEAP_VALIDATE` | `P1Census.cpp:88-101`; `P1Census.hpp:21-38` |
| `ECO_SURVIVOR_WRITE_CENSUS` | `1` | — | Alias for `ECO_P1_CENSUS=1`. | same as above | `P1Census.cpp:96` |
| `ECO_P1_CENSUS_SAMPLE` | power of two, 1..65536 | 16 | Sampling rate of the old-gen promoted-object table. | same as above | `P1Census.cpp:66,103-110` |
| `ECO_P1_CENSUS_EVERY` | ≥ 1 | 64 | Verify the O table every N minors. | same as above | `P1Census.cpp:68,111-118` |
| `ECO_NURSERY_POISON` | `1` | off | Fills free nursery space with 0xD8 as a zeroing tripwire. | `ECO_HEAP_VALIDATE` | `NurserySpace.cpp:89-94,2371` |
| `ECO_POISON_NONFATAL` | `1` | off | Poison census mode: reports each poison hit and nulls the slot instead of aborting. | `ECO_HEAP_VALIDATE` | `NurserySpace.cpp:1307` |
| `ECO_PERSITE_ZERO` | `1` | off | Zeroes the full object at allocation. | `ECO_HEAP_VALIDATE` | `ThreadLocalHeap.hpp:48-53` |
| `ECO_LARGE_PTR_TRACE` | `1` (stderr) or a file path | off | Traces large-object placement. | `ECO_HEAP_VALIDATE` | `ThreadLocalHeap.cpp:216` |
| `ECO_VALIDATE_FREELIST_DUP_SCAN` | `0` disables | on | O(n) duplicate-cell scan in free-list validation. | `ECO_HEAP_VALIDATE` | `OldGenSpace.cpp:4952` |
| `ECO_TEST_CHECK_AGE_SWEEP` | `1` | on in validate builds, else off | Checks the region age-extent sweep. | none | `NurseryTenure.cpp:332` |
| `ECO_TEST_TENURE_STOP_AFTER` | N | 0 | Test probe: every tenure job stops after N items. | `ECO_GC_STATS` | `NurseryRegion.cpp:172` |
| `ECO_TEST_PROMO_VIA_CTX` / `ECO_TEST_MINOR_ENGINE=P` | flags | off | Test probes: context-based serial promotion, or forcing the parallel minor engine. | `ECO_GC_STATS` | `NurserySpace.cpp:165,170` |
| `ECO_CONS_SITES` / `ECO_CLOSURE_STATS` / `ECO_DISPATCH_STATS` | set / non-`0` | off | Allocation-site and dispatch profiling tables, printed at exit. These are not GC settings. | none | `RuntimeExports.cpp:368,877,1043` |

The following are **test-harness only** and are read by `test/allocator/*`, not by the runtime:

- `ECO_TEST_MINOR_THREADS` (`TestHelpers.cpp:20`)
- `ECO_TEST_MARK_THREADS` (`IncrementalMarkTest.cpp:67`)
- `ECO_TEST_CONC_MARK` (`ParallelMarkTest.cpp:72`, `IncrementalMarkTest.cpp:73`, `ParallelMinorTest.cpp:131`)
- `ECO_CONC_SCALE_BENCH` / `ECO_CONC_SCALE_GB` / `ECO_CONC_SCALE_SLEEP_MS` (`ConcurrentMarkTest.cpp:959-962`)

These are out of scope here, but related: lowering-time env vars in `runtime/src/codegen` that shape allocation code, e.g. `ECO_INLINE_ALLOC`, `ECO_INLINE_ZERO`, `ECO_INLINE_BUMP_STATE`, `ECO_ALLOC_HOIST*`, `ECO_TLS_ROOT_STACK`, `ECO_GCFREE_LEAF`, `ECO_KERNEL_GCLEAF`.

### Compile-time switches affecting the runtime GC (runtime behaviour only)

| Macro (CMake option) | Default | Runtime effect | Env/JSON knobs it enables |
|---|---|---|---|
| `ENABLE_GC_STATS` (`ECO_GC_STATS`) | ON for non-Release builds, OFF for Release (`CMakeLists.txt:119-128`) | GC counters and timers; the exit `=== GC Statistics ===` banner (also printed on fatal signals). | Helper and stall rows of `ECO_GC_EVENT_LOG`; `ECO_TEST_*` probes |
| `ENABLE_GC_PHASE_TIMERS` (`ECO_GC_PHASE_TIMERS`, requires stats) | OFF (`CMakeLists.txt:135-146`) | Minor phase timers, promotion sampling, pause log (percentiles, MMU), event-log rows. Costs about +2.3 % GC time. | Minor, major, pause and cycle rows of `ECO_GC_EVENT_LOG` |
| `ECO_HEAP_VALIDATE` | OFF (`CMakeLists.txt:84-89`) | Stale-pointer hooks, poisoning, bitmap tripwires, post-GC heap walker, BBoP audits. **It also changes defaults:** eden flip on (`AllocatorCommon.hpp:880-883`), P1 census mode 2 (abort), age-sweep check on. This changes the region geometry: one extra extent. | `ECO_NURSERY_POISON`, `ECO_POISON_NONFATAL`, `ECO_PERSITE_ZERO`, `ECO_LARGE_PTR_TRACE`, `ECO_VALIDATE_FREELIST_DUP_SCAN`, `ECO_P1_CENSUS*` |
| `ENABLE_P1_CENSUS` (`ECO_P1_CENSUS`) | OFF (`CMakeLists.txt:95-103`) | Cheap P1 survivor-write census without the validator. Default mode 1 (count). | `ECO_P1_CENSUS`, `_SAMPLE`, `_EVERY`, `ECO_SURVIVOR_WRITE_CENSUS` |
| `ECO_HEAP_TRACE` | OFF (`CMakeLists.txt:109-115`) | Compiles in the `[heap-trace]` dumps. | `ECO_HEAP_TRACE` |
| `ECO_GC_DEBUG` | ON for Debug builds, else OFF (`CMakeLists.txt:56-63`) | Extra GC assertions and nursery stale-pointer checks. Adds a struct member, so every target must agree on it (ODR). | none |
| `ECO_LOWERING_VALIDATION` | OFF | Verifier passes plus runtime copy-loop barriers. | none |


## Build-time configuration

Everything here is fixed when you configure (`cmake --preset …` / `-D…`) or build. Runtime environment variables read by `eco`, `ecor` and the runtime (for example `ECO_GC_*` and `ECO_HEAP_TRACE`) are in [Runtime: heap and GC](#runtime-heap-and-gc) and [C++ backend tools](#c-backend-tools-and-native-driver). Targets are documented in [docs/build-targets.md](build-targets.md). The preset workflow is in [docs/building.md § Presets](building.md#presets), and the test targets are in [docs/testing.md](testing.md).

**Build-type-dependent defaults are evaluated only once.** `ECO_GC_DEBUG`, `ECO_GC_STATS` and `ECO_ASSERTS_ON` choose their default from `CMAKE_BUILD_TYPE` the first time a build tree is configured. After that, the value stays in `CMakeCache.txt`. If you later change `CMAKE_BUILD_TYPE` in the same tree, these options keep their old values. To pick up new defaults, delete the cache or pass the options explicitly.

### CMake options (`option(...)`)

| Name | Default | Effect | Source |
|---|---|---|---|
| `ECO_FRONTEND_ONLY` | OFF (`mac-frontend`, `win-frontend`: ON) | Configure only `compiler/` (bootstrap stages 1–5, pure Node/Elm). Skips LLVM/MLIR, libunwind, runtime, kernels and tests. No define. | `CMakeLists.txt:15` |
| `ECO_GC_DEBUG` | ON if `CMAKE_BUILD_TYPE=Debug`, else OFF | Runtime GC debug checks (nursery stale-pointer detection, extra GC asserts). Adds the global define `ECO_GC_DEBUG=1`. It changes class layout (`in_minor_gc_`), so every target must agree. | `CMakeLists.txt:56-63` (also re-declared at `runtime/src/codegen/CMakeLists.txt:16-20`; per-target copies at `:650,742,785,824`) |
| `ECO_LOWERING_VALIDATION` | OFF | Validation-only MLIR verifier passes (EcoBoxedStoreVerify, EcoPtrIntVerify, GC liveness audit, closure-capture check). Also turns on the after-each-pass module verifier and runtime copy-loop barriers. Slow. Global define `ECO_LOWERING_VALIDATION=1`. | `CMakeLists.txt:70-75` (re-declared at `runtime/src/codegen/CMakeLists.txt:22`; per-target copies at `:425,560,653,895,1624`) |
| `ECO_HEAP_VALIDATE` | OFF | Heap-corruption detectors at every read/write/GC-walk site: stale-HPointer hooks, free-region poisoning, post-GC integrity walker, old-gen/BBoP audits. Also compiles in the P1 census in abort mode. Slow. `ECO_HEAP_VALIDATE=1` | `CMakeLists.txt:84-89` |
| `ECO_P1_CENSUS` | OFF | Compiles in the P1 survivor-write census (threaded-gc-04) without the full heap validator. The runtime mode comes from the environment variable of the same name (`0`/`1`/`2`). Always defines `ENABLE_P1_CENSUS=1` or `=0`. | `CMakeLists.txt:96-103` |
| `ECO_HEAP_TRACE` | OFF | Compiles in the per-GC `[heap-trace]` diagnostics. Output still requires the runtime environment variable `ECO_HEAP_TRACE=1`. `ECO_HEAP_TRACE=1` | `CMakeLists.txt:109-114` |
| `ECO_GC_STATS` | OFF if `CMAKE_BUILD_TYPE=Release`, else ON | GC allocation/timing counters and the exit-time `=== GC Statistics ===` banner. Always defines `ENABLE_GC_STATS=1` or `=0`. | `CMakeLists.txt:121-130` |
| `ECO_GC_PHASE_TIMERS` | OFF | threaded-gc-00 minor-GC phase timers, pause log (percentiles/MMU) and `ECO_GC_EVENT_LOG` TSV. Measured cost is about +2.3 % GC time. Configure fails with FATAL_ERROR unless `ECO_GC_STATS` is ON. Always defines `ENABLE_GC_PHASE_TIMERS=1` or `=0`. | `CMakeLists.txt:137-147` |
| `ECO_ASSERTS_ON` | OFF if `CMAKE_BUILD_TYPE=Release`, else ON | Keeps `assert()` live by adding `-UNDEBUG` per target (`ecor`, runtime static libs, all kernel libs). No define. | `CMakeLists.txt:155-159`; applied at `CMakeLists.txt:440`, `elm-kernel-cpp/CMakeLists.txt:328`, `eco-kernel-cpp/CMakeLists.txt:287`, `runtime/src/codegen/CMakeLists.txt:723,782,821` |
| `ECO_USE_CCACHE` | OFF | Wraps C/C++ compiles with ccache (force-sets `CMAKE_{C,CXX}_COMPILER_LAUNCHER`). | `CMakeLists.txt:164-169` |
| `ECO_FRAME_POINTERS` | OFF | Adds `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` globally, for perf/flamegraphs. | `CMakeLists.txt:171-174` |
| `ECO_STATIC` | OFF (`release`: ON, forced by `ECO_STATIC_MUSL`) | Statically links curl/openssl/libzip/libunwind/libstdc++ into `eco`, prefers `.a` libraries, and vendors libcurl (and zlib on Windows) via FetchContent. Emits `ecoStatic=true` in the generated `EcoBootConfig.h`. | `CMakeLists.txt:182`; `runtime/src/codegen/CMakeLists.txt:1401-1416` |
| `ECO_STATIC_MUSL` | OFF (`release`: ON) | Stage B: fully static musl build (libc++/compiler-rt/LLVM libunwind, `-static` non-PIE). Force-sets `ECO_STATIC=ON` and enables the Stage C bundle install rules and CPack. | `CMakeLists.txt:192-197` |
| `ECO_GLIBC_OUTPUT_RUNTIME` | OFF | Stage D archive-only mode: builds only the glibc-ABI PIC output-runtime archive set, with no compiler, tests or `ecor`. Requires `ECO_STATIC`. Incompatible with `ECO_STATIC_MUSL`. Adds `-stdlib=libc++`. | `CMakeLists.txt:207-228` |
| `ECO_LINK_WITH_BFD` | ON (`release`: OFF) | Links `eco` with `-fuse-ld=bfd`, because lld rejects `.llvm_stackmaps` relocations in PIE builds. | `CMakeLists.txt:237`; used at `compiler/CMakeLists.txt:824` |
| `ECO_KERNEL_DEBUG` | OFF (`dev`: ON) | Stderr tracing (`ECO_KLOG`) in the HTTP/File/zip kernels and the HttpService runtime. Per-target define `ECO_KERNEL_DEBUG` on ElmKernel_Http, EcoKernel_Http, EcoKernel_File and EcoRuntimeStatic. | `CMakeLists.txt:247`; `elm-kernel-cpp/CMakeLists.txt:343`, `eco-kernel-cpp/CMakeLists.txt:300`, `runtime/src/codegen/CMakeLists.txt:748` |
| `ECO_BUNDLE_STRIP` | ON | `strip --strip-debug` on every bundled `.a`/`.o` at install/CPack time. Only takes effect under `ECO_STATIC_MUSL`. | `CMakeLists.txt:529`, `:649` |
| `ECO_ALLOW_NONPORTABLE_LD` | OFF | Musl only: if no static `ld.lld` is found in `/opt/llvm-mlir/libexec/eco-bundle`, bundles the dynamic build-host `ld.lld` instead of failing. The resulting bundle is not portable. | `runtime/src/codegen/CMakeLists.txt:1088` |

### Cache variables (`set(... CACHE ...)`) and `-D` inputs

| Name | Default | Effect | Source |
|---|---|---|---|
| `ECO_FETCH_RETRIES` | `3` | Download attempts for the fetched Elm toolchain (elm, elm-format, elm-test-rs) before configure fails. | `compiler/cmake/toolchain.cmake:39` |
| `ECO_FETCH_TIMEOUT` | `600` | Total timeout per download attempt, in seconds. | `compiler/cmake/toolchain.cmake:40` |
| `ECO_FETCH_INACTIVITY_TIMEOUT` | `60` | No-data timeout per download attempt, in seconds. | `compiler/cmake/toolchain.cmake:41` |
| `ELM_EXECUTABLE` | fetched `build/toolchain/bin/elm` | Path to elm 0.19.1. | `compiler/cmake/toolchain.cmake:197` |
| `ELM_FORMAT_EXECUTABLE` | fetched elm-format 0.8.7 | Path to elm-format. | `compiler/cmake/toolchain.cmake:198` |
| `ELM_TEST_RS_EXECUTABLE` | fetched elm-test-rs 3.0.1 | Path to elm-test-rs (used by `elm-tests`). | `compiler/cmake/toolchain.cmake:199` |
| `ECO_GLIBC_RUNTIME_TREE_OUT` | `${CMAKE_BINARY_DIR}/glibc-runtime-tree` | Staging directory for the Stage D glibc output-runtime tree. Only used with `ECO_GLIBC_OUTPUT_RUNTIME`. | `CMakeLists.txt:828` |
| `ECO_GLIBC_LLVM_RUNTIMES_DIR` | `""` (auto-discover) | Overrides the directory holding glibc-PIC `libc++.a`/`libc++abi.a`/`libunwind.a`/`libclang_rt.builtins-x86_64.a`. Stage D only. | `CMakeLists.txt:845` |
| `ECO_VERSION_OVERRIDE` (plain `-D`, not declared) | unset | Replaces the `version.txt` + `-dev-<git describe>` string in `eco --version` and in the CPack package names. Docker equivalent: `--build-arg ECO_VERSION`. | `compiler/CMakeLists.txt:82`; `CMakeLists.txt:968,1024,1061` |
| `ECO_GLIBC_RUNTIME_TREE` (plain `-D`, not declared) | unset | Musl bundle: merges a Stage D glibc tree into `lib/eco-runtime/glibc`. If unset, the bundle refuses `.so`/`.node` outputs. | `CMakeLists.txt:622` |
| `LLVM_INSTALL_PREFIX` (plain `-D` or env; `release` sets it) | unset | Search prefix for LLVM libunwind. Linux only; macOS and Windows use the system unwinder or none. | `cmake/LLVMLibunwind.cmake:48-53` |
| Tool/path discovery entries (`find_*`, overridable with `-D`) | auto | `CCACHE_EXECUTABLE`, `NODE_EXECUTABLE`, `PNPM_EXECUTABLE`, `PYTHON3_EXECUTABLE`, `GNU_TIME_EXECUTABLE` (GNU `time`, or `gtime` on macOS), `ECO_NODE_API_INCLUDE_DIR` (vendored node-api headers; if absent, no EcoNodeGlue and no `.node` outputs), `ECO_SYSTEM_LD` (AOT linker baked into EcoBootConfig), `ECO_BUILD_LD_LLD` / `ECO_BUNDLED_LD_LLD` (musl), `ECO_DARWIN_LIBSSL_A` / `ECO_DARWIN_LIBCRYPTO_A` (brew openssl@3), `ECO_LIBZ_A` (`ECO_STATIC`). | `CMakeLists.txt:166`; `compiler/CMakeLists.txt:23-39`; `runtime/src/codegen/CMakeLists.txt:801,953,1073,1079,1231,1234,1404` |
| Internal (`CACHE INTERNAL`, not user knobs) | computed | `ECO_ALLOCATOR_PLATFORM_SRCS[_RELATIVE]` (posix vs win32 VM source), `ECO_ELM_KERNEL_MODS`, `ECO_KERNEL_MODS`, crt/libgcc placeholders on Windows, the compiler-rt builtins path, and the re-published Darwin openssl paths. | `CMakeLists.txt:37-48`; `runtime/src/codegen/CMakeLists.txt:920,924,978,992-998,1030,1157,1246-1248` |
| Third-party forced cache (FORCE) | n/a | Vendored curl (static, OpenSSL on POSIX / schannel on Windows, every protocol except HTTP(S) disabled) applies under `ECO_STATIC OR WIN32`. Vendored libzip (no crypto/bzip2/lzma/zstd) applies under `ECO_STATIC OR APPLE OR WIN32`. Both force `BUILD_SHARED_LIBS=OFF` for the whole tree. | `CMakeLists.txt:323-369`; `eco-kernel-cpp/CMakeLists.txt:61-74` |

The standalone TSan harness projects have no options:

- `test/gc-helper-tsan` always builds with `-fsanitize=thread -UNDEBUG`.
- `test/gc-heap-tsan` hard-codes `ECO_HEAP_VALIDATE=1 ENABLE_GC_STATS=1` (`test/gc-heap-tsan/CMakeLists.txt:22`).

Both are configured separately into `build-tsan` / `build-heap-tsan` with `g++`.

### CMake presets

These come from `CMakePresets.json`. Every configure preset uses the Ninja generator, and each has a matching build preset with `jobs: 0`. Options a preset does not set take the defaults listed above.

| Preset | Host | Binary dir | Build type | Compiler / linker | Options set |
|---|---|---|---|---|---|
| `dev` | Linux | `debug/` | Debug | clang/clang++, `-fuse-ld=lld` | `ECO_KERNEL_DEBUG=ON`. Debug also enables `ECO_GC_DEBUG`, `ECO_GC_STATS` and `ECO_ASSERTS_ON` by default. |
| `build` | Linux | `build/` | RelWithDebInfo (`-O2 -g -UNDEBUG`) | clang/clang++, `-fuse-ld=lld` | none. Defaults give asserts ON, GC stats ON, GC debug OFF. |
| `mac-build` | Darwin | `build/` | RelWithDebInfo (`-O2 -g -UNDEBUG`) | AppleClang + ld64 | `CMAKE_PREFIX_PATH=/opt/homebrew/opt/llvm@21` |
| `mac-frontend` | Darwin | `build/` | RelWithDebInfo | default | `ECO_FRONTEND_ONLY=ON` |
| `win-frontend` | Windows | `build/` | RelWithDebInfo | clang-cl | `ECO_FRONTEND_ONLY=ON` |
| `win-build` | Windows | `build/` | RelWithDebInfo (`/O2 /Zi /UNDEBUG`) | clang-cl + lld-link, `/MT` static CRT, `/EHsc`, `/INCREMENTAL:NO` | `CMAKE_PREFIX_PATH=$env{LLVM_DIR}`, `ECO_LLVM_FUNCTION_SECTIONS=ON` (no CMake file reads this variable) |
| `release` | any (no condition) | `build-static/` | Release (`-O2 -DNDEBUG -march=x86-64-v3`) | clang, `-stdlib=libc++`, `-static … -rtlib=compiler-rt -unwindlib=libunwind -fuse-ld=lld` | `ECO_STATIC=ON`, `ECO_STATIC_MUSL=ON`, `ECO_LINK_WITH_BFD=OFF`, `CMAKE_PREFIX_PATH` / `LLVM_INSTALL_PREFIX=/opt/llvm-mlir`. Release also turns GC stats and asserts OFF, and adds `--strip-all` (`compiler/CMakeLists.txt:872`). |

### Environment variables used at configure/build/test time

| Name | Default | Effect | Source |
|---|---|---|---|
| `TEST_FILTER` | unset (run all) | Passed as `--filter` to the test runner by the `check`, `full`, `run-tests`, `stress`, `run-mlir-equivalence` and `run-aot-e2e` targets. | `CMakeLists.txt:1184,1192,1202,1219`; `test/CMakeLists.txt:309,377` |
| `LLVM_INSTALL_PREFIX` | unset | Configure-time search prefix for LLVM libunwind. | `cmake/LLVMLibunwind.cmake:51` |
| `CMAKE_PREFIX_PATH` | unset | Also searched (colon-split) for libunwind. | `cmake/LLVMLibunwind.cmake:64` |
| `LLVM_DIR` | unset (required) | `win-build` expands it into `CMAKE_PREFIX_PATH`. | `CMakePresets.json:96` |
| `DESTDIR` | unset | Honoured by the bundle strip `install(CODE)` step under CPack. | `CMakeLists.txt:651` |
| `PATH` | inherited | `elm-tests` puts `build/toolchain/bin` first so elm-test-rs can find `elm`. elm-test-rs runs with a fixed `--fuzz 1` and reads no env knobs. | `compiler/CMakeLists.txt:179-180` |
| `GUIDA_JS_PATH` (set by the build) | build-tree `guida.js` | Stage 2: tells `bin/index.js` where the Stage 1 compiler is. | `compiler/CMakeLists.txt:294` |
| `NODE_OPTIONS` (set by the build) | `--max-old-space-size=16384` | Set on the Stage 9b `eco → eco-2` command. That command runs a native binary, so the setting has no effect. | `compiler/CMakeLists.txt:984` |
| `ECO_MONO_ENGINE` | compiler default | Not read by CMake. The comment recommends `subst` for the Node-hosted stages on hosts with about 15 GB RAM (runtime compiler env). | `compiler/CMakeLists.txt:423` |
| `ECO_TEXT_MLIR` | unset (bytecode) | When set and not `0`, the E2E harness passes `--text-mlir` to the compiler. | `test/TestSuite.hpp:24` |
| `AOT_E2E_JOBS` | runner default | Parallel job count for `aot-e2e-runner`. | `test/aot_e2e_main.cpp:539` |
| `ECO_AOT_EXTRA_FLAGS` | unset | Extra `eco-boot-native` flags injected into every AOT E2E compile. | `test/aot_e2e_main.cpp:392` |
| `MLIR_EQUIV_JOBS` | runner default | Parallel job count for `mlir-equivalence`. | `test/mlir_equivalence_main.cpp:414` |
| `W0_CAPTURE_GOLDENS` | unset | Makes KernelExportsTest print goldens instead of checking them. | `test/kernel/KernelExportsTest.cpp:338` |
| `ECO_TEST_MINOR_THREADS` | unset (-1) | Overrides the minor-GC thread count in allocator unit-test heaps. | `test/allocator/TestHelpers.cpp:20` |
| `ECO_TEST_MARK_THREADS` | unset (1) | Re-runs the incremental-mark tests with N markers. | `test/allocator/IncrementalMarkTest.cpp:67` |
| `ECO_TEST_CONC_MARK` | unset (0) | Overrides `conc_mark` in the parallel-mark tests. | `test/allocator/ParallelMarkTest.cpp:72` |
| `ECO_TEST_CHILD_STDERR` | unset | Keeps stderr from forked test children (by default it goes to /dev/null). | `test/allocator/ParallelMarkTest.cpp:198` |
| `ECO_CONC_SCALE_BENCH` / `_GB` / `_SLEEP_MS` | unset / 1.0 / — | Opt-in concurrent-mark scale benchmark and its parameters. | `test/allocator/ConcurrentMarkTest.cpp:959-962` |
| `ECO_E1_BENCH` | unset | Opt-in large-array placement benchmark (`=1`). Requires `ENABLE_GC_STATS`. | `test/allocator/LargePtrPlacementTest.cpp:600` |
| `PB_DEBUG` | unset | Debug prints in PromoBufferTest. | `test/allocator/PromoBufferTest.cpp:82` |
| `TMPDIR` | `/tmp` | Scratch directory for the `kernel-license-check` script (an ALL target). | `test/scripts/check-kernel-license-manifest.sh:72` |

The allocator tests also save, clear and restore the runtime variables `ECO_GC_CONC_MARK`, `ECO_GC_CONC_MARK_THREADS` and `ECO_GC_HELPER_JITTER_US` (`test/allocator/ConcurrentMarkTest.cpp:83`, `TriggerPacingTest.cpp:282`). Unit-test heaps apply `ECO_GC_*` only at the first `Allocator::initialize`.

### Preprocessor switches in C++

The only `ECO_*` / `ENABLE_*` feature macros in `runtime/`, `elm-kernel-cpp/` and `eco-kernel-cpp/` are the CMake-driven ones above. Their fallback defaults, used when a file is compiled outside CMake, are:

| Name | Default | Effect | Source |
|---|---|---|---|
| `ECO_GC_DEBUG` | `0` | See the option above (24 conditionals, 8 files). | `runtime/src/allocator/AllocatorCommon.hpp:23` |
| `ECO_HEAP_VALIDATE` | `0` | See the option above (221 conditionals, 43 files). | `runtime/src/allocator/AllocatorCommon.hpp:34`, `P1Census.hpp:33` |
| `ENABLE_GC_STATS` | `0` | See `ECO_GC_STATS` (169 conditionals). The header default is OFF even though the CMake default is ON outside Release. | `runtime/src/allocator/GCStats.hpp:32` |
| `ENABLE_GC_PHASE_TIMERS` | `0` | See `ECO_GC_PHASE_TIMERS`. `#error` if enabled without GC stats. | `runtime/src/allocator/GCStats.hpp:56-60` |
| `ENABLE_P1_CENSUS` | `0` | See `ECO_P1_CENSUS`. | `runtime/src/allocator/P1Census.hpp:30` |
| `P1_CENSUS_COMPILED` | derived | `ENABLE_P1_CENSUS \|\| ECO_HEAP_VALIDATE`. Gates the census code (30 sites). | `runtime/src/allocator/P1Census.hpp:36` |
| `ECO_LOWERING_VALIDATION` | undefined | `#ifndef` ⇒ disables the after-each-pass MLIR verifier; `#if` ⇒ enables the verifier passes. | `runtime/src/codegen/eco-boot.cpp:365`, `EcoNativeDriver.cpp:97`, `Passes/EcoBoxedStoreVerify.cpp:53` |
| `ECO_HEAP_TRACE` | undefined | Compiles `Allocator::heapTraceEnabled()` to read the environment. | `runtime/src/allocator/Allocator.cpp:79` |
| `ECO_KERNEL_DEBUG` | undefined | Defines `ECO_KLOG` as an `fprintf` to stderr (a no-op otherwise). | `eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp:17`, `elm-kernel-cpp/src/KernelDebug.hpp:14`, `runtime/src/platform/HttpService.cpp:9` |
| `NDEBUG` | set by build type / flags | Besides `assert`, root-stack overflow checks run when `!NDEBUG \|\| ECO_HEAP_VALIDATE`. | `runtime/src/allocator/RootSet.hpp:145,166` |
| `RUSAGE_THREAD` | platform (Linux) | Per-thread fault and context-switch counters in the GC phase profile. They read 0 on Darwin. | `runtime/src/allocator/ThreadLocalHeap.cpp:823`, `NurserySpace.cpp:555` |
| `__SANITIZE_THREAD__` | compiler (TSan) | Reserves the heap in TSan's low application range. | `runtime/src/allocator/PlatformVirtualMemory_posix.cpp:39` |
| `MAP_NORESERVE` / `MAP_FIXED_NOREPLACE` / `MADV_POPULATE_WRITE` | platform (fallbacks `0` / skip / `23`) | VM reservation and pre-fault portability shims. | `runtime/src/allocator/PlatformVirtualMemory_posix.cpp:11,32,100` |
| `NOMINMAX`, `WIN32_LEAN_AND_MEAN` | defined on Win32 | Global Windows header hygiene. | `CMakeLists.txt:36` |
| `NAPI_VERSION` | `8` | N-API level for the `.node` addon glue. | `runtime/src/embed/eco_node_addon.cpp:28` |
