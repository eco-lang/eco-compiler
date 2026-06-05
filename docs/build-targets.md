# Build Targets

Every target below is invoked as `cmake --build build --target <name>`. For a
live listing, run `cmake --build build --target help`.

This reference was verified against the project's `CMakeLists.txt` files.

## Convenience targets

| Target | Purpose |
|---|---|
| `rebuild` | `ninja clean` + full rebuild |
| `check` | Build everything + run E2E tests (set `TEST_FILTER=` to filter) |
| `run-tests` | Run E2E tests without rebuilding |
| `stress` | Build + run the stress-elm suite |
| `full` | `clean` + rebuild + run E2E tests |
| `run-aot-e2e` | Build + run the AOT E2E suite (compile Elm → MLIR → native ELF → run) |
| `run-mlir-equivalence` | Build mlir-equivalence + run Stage 2 vs Stage 6 MLIR diff |
| `mlir-timing-report` | Emit an MLIR compile-timing report |
| `elm-tests` | Run the Elm-side compiler frontend tests via `elm-test-rs` |

## Bootstrap chain

The 9-stage self-compilation pipeline. See [bootstrap.md](bootstrap.md) for the
full description of each stage and its gates.

| Target | Stage | Output |
|---|---|---|
| `guida` | 1 | `build/compiler/build-xhr/bin/guida.js` |
| `eco-boot` | 2 | `build/compiler/build-kernel/bin/eco-boot.js` |
| `eco-boot-2` | 3 | `build/compiler/build-kernel/bin/eco-boot-2.js` |
| `eco-boot-3` | 4a | `build/compiler/build-kernel/bin/eco-boot-3.js` |
| `eco-boot-verify` | 4b | JS fixed-point check stamp |
| `eco-compiler-mlir` | 5 | `build/compiler/build-kernel/bin/eco-compiler.mlir` |
| `eco-compiler` | 6 | Native ELF compiler |
| `eco-compiler-boot` | 7 | Native self-compiled compiler |
| `eco` | 9 | Unified single-binary compiler — `build/compiler/build-kernel/bin/eco` |
| `eco-bootstrap` | 9 | Alias of `eco`; gates on the entire bootstrap chain |
| `eco-verify` | 9b | `eco` self-compile sanity-check (produces `eco-2`) |
| `bootstrap` | aggregate | Full chain through the Stage 8 + 9b fixed-point checks |

`eco` and `eco-quick` are `add_executable` targets; the rest of the chain are
custom targets. `eco-2` is the output of `eco-verify`, not a target itself.

### Dev iteration: `eco-quick`

`eco-quick` is the fast-iteration sibling of the Stage 9 unified `eco` binary.
The two share an identical link line (kernel libraries, runtime,
`EcoNativeDriverStatic`, `-fuse-ld=bfd`), but `eco-quick`'s MLIR-lowering
custom-command depends only on `eco-compiler.mlir` and `eco-boot-native`,
deliberately dropping the gate on the full bootstrap chain that the production
`eco` target enforces.

`eco-compiler.mlir` is a Stage-5 product of Elm sources only and is invariant
under C++/kernel edits, so once a prior `--target bootstrap` has populated it,
`--target eco-quick` rebuilds only the changed kernel/runtime libraries and
relinks the unified binary — no Stage 6–8 self-compile cycles. Use `--target
eco` for the production binary that enforces the full bootstrap; use `--target
eco-quick` while iterating on code under `runtime/` or `*-kernel-cpp/`.

| Target | Purpose | Output |
|---|---|---|
| `eco-quick` | Re-link the unified `eco` against current C++ libs; skips the bootstrap gate. Requires a prior successful `--target bootstrap`. | `build/compiler/build-kernel/bin/eco-quick` |

## Test executables

| Target | Purpose |
|---|---|
| `test` | Main test binary (`build/test/test`) — unit + E2E + allocator |
| `stress-test` | Stress-elm runner (`build/test/stress-test`) |
| `mlir-equivalence` | MLIR-diff binary (`build/test/mlir-equivalence`) |
| `aot-e2e-runner` | AOT E2E runner used by `run-aot-e2e` |

## Runtime executables

| Target | Purpose |
|---|---|
| `ecor` | Allocator + RapidCheck test exe (`build/ecor`) |
| `eco-boot-native` | Native MLIR-lowering tool used by Stages 6–9 |
| `ecoc` | Standalone Eco compiler driver |
| `ecogen` | Code-generation driver |

## Runtime libraries

| Target | Purpose |
|---|---|
| `EcoRunner` | JIT runner library |
| `EcoPasses` | MLIR passes |
| `EcoDialect` | Eco MLIR dialect |
| `BFDialect` | Bytes-fusion MLIR dialect |
| `EcoEntryStatic` | Entry-point glue |
| `EcoRuntimeStatic` | Runtime archive |
| `EcoNativeDriverStatic` | In-process MLIR → ELF lowering bridge (linked only into the unified `eco`) |

## Elm kernel libraries

| Target | Purpose |
|---|---|
| `ElmKernel_Basics` | `Basics` kernel |
| `ElmKernel_Bitwise` | `Bitwise` kernel |
| `ElmKernel_Browser` | `Browser` kernel |
| `ElmKernel_Bytes` | `Bytes` kernel |
| `ElmKernel_Char` | `Char` kernel |
| `ElmKernel_Debug` | `Debug` kernel |
| `ElmKernel_EffectRegistry` | Effect manager registry |
| `ElmKernel_File` | `File` kernel |
| `ElmKernel_Http` | `Http` kernel |
| `ElmKernel_JsArray` | `JsArray` kernel |
| `ElmKernel_Json` | `Json` kernel |
| `ElmKernel_List` | `List` kernel |
| `ElmKernel_Parser` | `Parser` kernel |
| `ElmKernel_Platform` | `Platform` kernel |
| `ElmKernel_Process` | `Process` kernel |
| `ElmKernel_Regex` | `Regex` kernel |
| `ElmKernel_Scheduler` | `Scheduler` kernel |
| `ElmKernel_String` | `String` kernel |
| `ElmKernel_Time` | `Time` kernel |
| `ElmKernel_Url` | `Url` kernel |
| `ElmKernel_Utils` | `Utils` kernel |
| `ElmKernel_VirtualDom` | `VirtualDom` kernel |

(`ElmKernel` is an `INTERFACE` umbrella aggregating the above.)

## Eco kernel libraries

| Target | Purpose |
|---|---|
| `EcoKernel_Console` | `Eco.Console` IO |
| `EcoKernel_Crash` | `Eco.Crash` (Stage 2+ replacement for `Debug.todo`) |
| `EcoKernel_Env` | `Eco.Env` environment variables |
| `EcoKernel_File` | `Eco.File` IO |
| `EcoKernel_Http` | `Eco.Http` IO |
| `EcoKernel_MVar` | `Eco.MVar` synchronization |
| `EcoKernel_NativeDriver` | In-process MLIR → ELF lowering intrinsic for the unified `eco` |
| `EcoKernel_Process` | `Eco.Process` IO |
| `EcoKernel_Runtime` | `Eco.Runtime` glue |

(`EcoKernel` is an `INTERFACE` umbrella aggregating the above.)

## Tablegen / generated headers

| Target | Purpose |
|---|---|
| `EcoOpsIncGen` | Generate Eco dialect Op `.inc` files |
| `BFOpsIncGen` | Generate BF dialect Op `.inc` files |

> LLVM/MLIR pull in additional transitive tablegen targets (`acc_gen`,
> `omp_gen`, `target_parser_gen`, `vt_gen`, …) during configuration. These are
> not declared by this project and are not intended to be built directly.

## CMake built-ins

| Target | Purpose |
|---|---|
| `clean` | Remove ninja-tracked outputs |
| `help` | List all available targets |
| `install` | Install built artifacts |
| `edit_cache` | Open CMake cache for editing |
| `rebuild_cache` | Reconfigure CMake cache |
| `list_install_components` | List installable components |
