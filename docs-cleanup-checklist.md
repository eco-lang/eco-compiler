# Docs to correct: cleanup checklist

Documentation and code comments that disagree with the code, found while writing the program theory (`THEORY.md`, `design_docs/theory/`). In every case the code is right and the text is out of date. Each item names the file, what it says, and what is true instead ("→" separates the two). The theory document that covers the topic is named in brackets.

Source: `icm-agents/workspaces/program-theory-writer/theory/review/source-drift.md`, section 4, which has the evidence. Entries for the deleted files (the old `THEORY.md`, `PLAN.md`, `compiler/THEORY.md` and the old `design_docs/theory/*` documents) are left out.

## Root and top-level

- [x] `Readme.md`: 0.1.0 alpha → `version.txt` 0.2.0; "native x86 binaries" → also apple-m1; "160K LOC" → ~240K; omits Windows and `docs/building-windows.md`. *(theory: eco)*
- [x] `CLAUDE.md`: `build` preset called "RelWithDebInfo"; preset is `-O2 -g -UNDEBUG`, asserts on. *(theory: build-and-workflow)*
- [x] `STYLE.md`: names `GarbageCollector::instance()`, `getNursery()` (now `Allocator::instance()`, `getRootSet()`); "40-bit offsets" → absolute addresses; points to missing `design_docs/gc/`; mandates `#ifndef` guards while 14 allocator headers use `#pragma once`. *(theory: invariants-and-design)*
- [x] `CLAUDE.md`: does not point to `GITSTYLE.md`. Add a pointer so agents follow it, in particular that commits carry no tool or assistant attribution trailers. The few past commits with trailers are mistakes, not exceptions to the rule. *(theory: invariants-and-design)*

## docs/ and guides/

- [x] `docs/getting-started.md`: installs `eco_0.1.0-RC2_amd64.deb` but downloads macOS `v0.2.0-nightly`. *(theory: eco)*
- [x] `docs/bootstrap.md`: Stages 6 and 9 produce "x86-64 Linux ELF"; same chain runs on macOS and Windows (its own Stage 8c). *(theory: eco)*
- [x] `docs/bootstrap.md`, `guides/bootstrap.md`: Stage 1 compiler "from npm" → SHA256-pinned binary via `compiler/cmake/toolchain.cmake`. *(theory: bootstrap)*
- [x] `docs/bootstrap.md`, `guides/bootstrap.md`: `--max-old-space-size=12000` → CMake pins 16384. *(theory: bootstrap, build-and-workflow)*
- [x] `guides/bootstrap.md`: omits that Stages 6-9 also use `--optimize`. *(theory: bootstrap)* — DONE IN PART: only Stages 7a/8a/9b pass `--optimize`; Stage 6 only lowers MLIR, so the text says 'native self-compiles'.
- [x] `guides/bootstrap-fix-loop.md`: "all 8 stages" → nine. *(theory: bootstrap)*
- [x] `docs/building.md`: "Three presets" → seven; Linux-only prerequisites; `version.txt` baseline 0.1.0 → 0.2.0; omits `docker/build-dist.sh` and numbered builds. *(theory: build-system)*
- [x] `docs/build-targets.md`: lists 9 EcoKernel libs, no EcoSystem → 11 EcoKernel (adds Hash, GC) + 12 EcoSystem; omits glibc-runtime, `eco-system-*`, `run-js-e2e`, `kernel-license-check`, `tla-check` targets. *(theory: build-system)*
- [-] `docs/building-windows.md`: target table omits the same targets. *(theory: build-system)* — SKIPPED: claim wrong; `docs/building-windows.md` has no target table.
- [x] `docs/testing.md`: `elm-tests` called "compiler frontend tests"; covers middle end through MLIR generation. *(theory: compiler-tests)*
- [x] `docs/testing.md`: E2E "Elm to MLIR to JIT" only → also AOT; omits `run-aot-e2e`, `run-mlir-equivalence`, `run-js-e2e`, eco-system suite, static scripts run by `check`/`full`, `tla-check*`, `genmc-check`, `register-guards`, conformance scripts, TSan/GenMC tiers. *(theory: verification, program-tests, runtime-tests)*
- [x] `guides/test-coverage-howto.md` (and elm-coverage README): assume `compiler/node_modules/.bin` and `unpacked_bin/elm-instrument`; now pnpm and CMake toolchain. *(theory: compiler-tests)* — DONE IN PART: toolchain paths now `build/toolchain/bin`; the elm-coverage `npm install`/`unpacked_bin/elm-instrument` steps are still right (standalone binwrap package), so they stay.
- [x] `guides/mem-hints.md`: dated baselines from an earlier compiler. *(theory: development-practice)*
- [x] `.github/scripts/eco-version.sh`, `docker/build-dist.sh` headers: `~` version form; `publish-nightly.yml` rewrites `~` in asset names. *(theory: build-system)*
- [x] `CMakeLists.txt` comments: preset `ninja-clang-lld-linux-musl` → `release`. *(theory: build-system)*

## compiler/

- [x] `compiler/README.md`: six phases ending in OPTIMIZE and `src/Compiler/Optimize/` → `LocalOpt/{Erased,Typed}`, `Monomorphize/`, `MonoSolver/`, `GlobalOpt/`. *(theory: compiler)*
- [x] `compiler/README.md`: MLIR backend under `Generate/CodeGen/` → `Generate/MLIR/`. *(theory: compiler)*
- [x] `compiler/README.md`: `guida`/`eco-boot` targets, `~/.guida`, `guida make` → eco names, `eco-stuff` (202f9a35). *(theory: compiler)* — DONE IN PART: `~/.guida`/`guida make` fixed; the `guida` and `eco-boot` CMake targets still exist, so their names stay.
- [x] `Compile.elm`: module and `compile` docs list four phases; `compileTyped` adds root normalization, PostSolve, arrow-root stamping, typed join. *(theory: compiler)*
- [x] `Compile.elm`: `compileTyped` doc and `TypedArtifactsData.objects` say "always `Opt.emptyLocalGraph`"; code stores `Opt.typedPathStub` (has `main`). *(theory: compiler)*
- [x] `Compile.elm`: `phase` doc says `Task.succeed ()` boundaries let GC interleave; they began as trace points (f177f7ac); no measurement found. *(theory: compiler)* UNVERIFIED as to reason.
- [x] `Compiler/Pipeline/Steps.elm`: `toGlobalOpt` "is the whole pipeline"; nothing calls it. *(theory: compiler)*
- [x] `Compiler/Generate/CodeGen.elm`: three backend kinds incl. `TypedCodeGen` → `CodeGen`, `MonoCodeGen`; `Output` "string or binary" → only `TextOutput`. *(theory: compiler, javascript-output)*
- [x] `Compiler/Eco/Config.elm`: module doc "missing key takes its default" contradicted by `monoDecoder`. *(theory: compiler)*
- [x] `MonoSolver/Translate.elm`: module doc describes "M1 arms" returning `Unsupported`. *(theory: monomorphization)*
- [x] `Monomorphize/Monomorphize.elm`: module doc lists `(Global, MonoType, Maybe LambdaId)` work items. *(theory: monomorphization)*
- [x] `MonoSolver/Monomorphize.monomorphize`: `lss.enabled = False` "byte-identical" to subst; `EngineDiff` checks canonical equivalence only. *(theory: monomorphization)*
- [x] `GlobalOpt/InlineSimplify.elm` header: `_pi` suffix freshening and `AssignMVarIds` inside mono → `PreMono.Fresh` (40826d13), `AssignMVarIds` before pre-mono. *(theory: global-optimization)*
- [x] `GlobalOpt/AbiCloning.elm` header: "staging wrappers" blockers (deleted module). *(theory: global-optimization)*
- [x] `Config.BorrowConfig`, `Borrow.elm`: `oracleOpt` facts "for code generation"; `Context.oracleFacts` is read by nothing. *(theory: global-optimization)*
- [x] `Generate/MLIR/Expr.elm`: `generateGenericApply`, `generateUnknownSegmentationCall` docstrings say "boxed"/"always !eco.value"; result is primitive when `_result_kind` ≠ 0; only `i1` is boxed. *(theory: mlir-generation)*
- [-] `Compiler/Generate/Html.elm`: `leadingLines` 2 vs 14 lines (defect 15). *(theory: javascript-output)* — SKIPPED: claim wrong; the doc already says 2 vs 14 lines, and that is accurate.
- [-] `API.Main`: documents `format` as supported; CLI command removed. *(theory: build-driver)* — SKIPPED: claim wrong; `API.Main` still decodes and dispatches `format` to `API.Format` (only the terminal command is gone).
- [x] `TestLogic/TypedPipelineTest.elm`: docstring says subst engine and that later-phase errors pass; code uses solver engine and fails on `Err`. *(theory: compiler-tests)*

## design_docs/

- [x] `design_docs/compatability.md`: "x86-64 only (no ARM64)"; `EcoBackend.h` pins apple-m1. *(theory: eco)*
- [x] `design_docs/distribution.md`: preset `ninja-clang-lld-linux-musl` → `release`; 9 `libEcoKernel_*.a` → 11 + 12 `EcoSystem_*` + `share/eco/system/`. *(theory: build-system)*
- [x] `design_docs/parallel-gc.md`: §8.2 "HEAP_018 makes RC complete" false for closures; "runs entirely on the mutator thread" → helper pool and concurrent marking. *(theory: garbage-collector, design-notes)*
- [x] `design_docs/lld-in-eco.md`: system linker only; bundle ships static linker, non-bundle uses `ld.bfd`. *(theory: design-notes)*
- [x] `design_docs/escape-analysis.md`, `escape-analysis-status.md`: describe deleted passes. *(theory: design-notes, backend)*
- [x] `design_docs/incremental-builds/README.md`: links missing `plans/partitioned-mlir-handoff.md`. *(theory: design-notes)*
- [x] `design_docs/monomorphization/multiset-defunctionalization-design.md`: cites deleted `mono-uncurry.md`, `mono-still-curried.md`. *(theory: design-notes)*
- [x] `error-handling.md`: `Scheduler.cpp` line numbers moved; behavior unchanged. *(theory: design-notes)*
- [x] `design_docs/all-e2e-test-cases.md`: "231 test files" → 679 (~640 `*Test.elm`); covers one directory. *(theory: program-tests)*
- [-] `design_docs/elm_kernel_functions.csv`: a JS-surface inventory incl. packages with no C++, not the implementation list. *(theory: elm-kernel)* — SKIPPED: the claim is true, but the CSV has no prose that says otherwise and no comment syntax; `theory/kernels/elm-kernel.md` already describes it.
- [x] `design_docs/kernel-boundary-reduction.md`: self-declared snapshot; figures and anchors stale. *(theory: elm-kernel)*
- [x] `design_docs/invariant-test-logic.md`: 44 `tests:` paths use old `compiler/tests/Compiler/...`; 5 name deleted checkers; GOPT_002 entry for removed `returnedClosureParamCounts`. *(theory: invariants)*
- [x] `design_docs/invariant-test-logic.md`: names absent modules `CaseStagingTest`, `ClosureStageArityTest`, `LambdaIdUniquenessTest`, `LocalTailRecSimpleTest`, `TailRecWithLocalTailDefTest`, `TypeConsistencyTest`, `UnboxCtorLayoutConsistencyTest`, `UnboxPathGroundTypeTest`. *(theory: compiler-tests)* — DONE IN PART: only 5 are gone; `CaseStagingTest`, `LocalTailRecSimpleTest`, `TailRecWithLocalTailDefTest` still exist as E2E tests in `test/elm/src/`.
- [x] `design_docs/monomorphization/design-recovery.md`: Axiom 2 keeps `MVar _ CNumber` id → keyed `MInt` since 9d4c39bc; `Specialize.elm` live and "stable"; module table has `Maybe LambdaId`. *(theory: monomorphization)*
- [x] `design_docs/monomorphization/solver-reuse-evaluation.md`: default at zonk, delete TypeSubst → defaults at Prune, both engines remain. *(theory: monomorphization)*
- [x] `design_docs/monomorphization/lambda-set-specialization-design.md`: `enabled` False → True; `keyed` flag → unconditional; `maxSetSize` 8 → 0; `maxSpecsPerGlobal` 64 → 0; `LambdaSet1 Bool Dict` → `LsTop | LsMembers | LsFrom`. *(theory: monomorphization)*
- [x] `design_docs/globalopt/borrow-inference-design.md` §3.2: Borrow runs last; CSE, dedupe, hoist follow. *(theory: global-optimization)*
- [x] `design_docs/invariants.csv` HEAP_018: says Elm values are always acyclic because Elm has "no recursive let bindings" → Elm has recursive local functions, and their closures form cycles (a self-capturing closure stores its own address; a mutually recursive group is allocated together and cross-wired). Value data (lists, records, custom types) stays acyclic. *(theory: garbage-collector, runtime)*

## runtime/ and kernels

- [x] `runtime/src/codegen/Ops.td` dialect description: Int/Float/Char/Bool unboxed as i64/f64/i32/i1 → Char `i16`, Bool never unboxed in heap; `!eco.value` header "refcount" (tracing GC); `eco.box` says `i32`. *(theory: eco-dialect)*
- [x] `Ops.td:3293`: cites CGEN_028 → CGEN_061. `Ops.td:3213`: cites CGEN_029 → CGEN_062. *(theory: eco-dialect, invariants)*
- [x] `runtime/src/codegen/EcoOps.cpp`: `CallOp::verify`/`PapExtendOp::verify` say signature checks deferred to `CheckEcoClosureCapturesPass`; it does not check them. *(theory: eco-dialect)*
- [x] `EcoOps.cpp`: `CallOp::verify` says module verifier runs after every pass (catches `eco.cse_safe`) → only in `ecoc` and validation builds; elsewhere `EcoGCLivenessAudit`. *(theory: eco-dialect)*
- [x] `EcoOps.cpp`: `foldConstructedField` comment says kind-0 slot accepts i1; `verifySlotKinds` rejects i1 (`:440-442`). *(theory: eco-dialect)*
- [x] `EcoOps.cpp:1338,1343,1377` and `plans/wide-object-tail-kind-words-phase-3.md:1295`: cite CGEN_029 → CGEN_062. *(theory: eco-dialect)*
- [x] `runtime/src/codegen/Passes.h`: `createEcoToLLVMTypeConverter` `eco.value -> i64` → `ptr addrspace(1)`. *(theory: lowering-passes)*
- [x] `Passes.h`: `createEcoFoldProjectPass` "Func-nested" → module pass; `createEcoTailConversionsPass` "anchored on LLVMFuncOp" → module-anchored, chunked. *(theory: lowering-passes)*
- [x] `Passes.h`: `createEcoGCLivenessAuditPass` gated on `ECO_GC_DEBUG` → `ECO_LOWERING_VALIDATION`. *(theory: lowering-passes)*
- [x] `Passes.h`: "Stage 2: Eco -> func/cf/arith" → stage 2 yields `scf`; `cf` only in `EcoTailConversions`. *(theory: lowering-passes)*
- [x] `Passes.h`, `Passes/EcoControlFlowToSCF.cpp`: leftover ops go to `createControlFlowLoweringPass` → `EcoToLLVMControlFlow.cpp`. *(theory: lowering-passes)*
- [x] `Passes.h`, `EcoGCPrepare.cpp` header: GCPrepare computes GC roots → roots discarded at lowering; RS4GC computes roots (CGEN_077(b)). *(theory: lowering-passes)*
- [x] `EcoPipeline.h`: `buildEcoToEcoPipeline` "Undefined function stub generation"; `EcoPipeline.cpp`: stage 2.5 "safepoint rewrite", fold slot "two func-nested passes". All stale. *(theory: lowering-passes)*
- [x] `EcoBackend.h`: `BackendKind`/`EcoBackendJob` comments ("Phase 3.3 expands", "`llvm_unreachable` before Phase 4", "thin facade"); implemented in `runEcoBackend`. *(theory: backend)*
- [x] `EcoNativeDriver.h`, `eco-boot.cpp`: link "via clang++ driver" → direct linker on Linux, clang driver only on macOS/Windows; "MLIR-to-ELF" → also Mach-O, COFF. *(theory: backend, native-drivers)*
- [x] `eco_entry.cpp`, `eco-boot.cpp` headers: "x86-64 Linux" ELF → Darwin and Windows paths exist. *(theory: native-drivers)* — `eco_entry.cpp` needed no change (already says ELF and Mach-O); `eco-boot.cpp` fixed.
- [x] `runtime/src/codegen/EcoNativeAPI.h`: `eco_native_lower_and_link_bytes` presented as the hand-off; `eco make` writes a temp bytecode file and calls `lowerAndLink` (`Terminal/Make.elm` `handleElfOutput`). *(theory: eco)*
- [x] `runtime/src/allocator/AllocatorCommon.hpp`: `NURSERY_REGIONS` comment says auto falls back → throws; `MARK_WORK_RATIO` comment describes allocation-paced marking → unread. *(theory: garbage-collector)*
- [x] `NurserySpace.cpp`: "children are always at least as old as the object" misses same-age cycles. *(theory: garbage-collector)*
- [x] `Heap.hpp`: comment mentions nonexistent `Const_EmptyString`. *(theory: invariants-and-design)*
- [x] `Scheduler.cpp:681-684`: `runEventLoop` comment cites embedder "lifetime baseline"; check is `pendingAsync_ - hostHolds_`. *(theory: scheduler-and-services)*
- [x] `HttpService.hpp`: "worker pool", "SAME worker pool" → one worker. *(theory: scheduler-and-services)*
- [x] `PlatformRuntime` `setupEffects`: returns empty record "no ports for now"; ports are managers. *(theory: scheduler-and-services)*
- [x] `elm-kernel-cpp/LIBRARY_DEPENDENCIES.md`: RapidJSON, PCRE2, Boost.Beast, std::jthread, WebAssembly → nlohmann/json, SRELL, libcurl+OpenSSL, runtime services. *(theory: elm-kernel, kernels)*
- [x] `elm-kernel-cpp/src/regex/Regex.cpp`: "stub needing PCRE2" comments; exports use SRELL. *(theory: kernels)*
- [x] elm-kernel `KernelExports.h`: Bytes and Regex labelled "STUBS"; both implemented. *(theory: elm-kernel)*
- [x] `system-kernel-cpp/README.md`, `IoReactor.hpp`: macOS untested, Windows unsupported; CI builds both. *(theory: system-libraries)*
- [x] `runtime/src/allocator/HeapHelpers.hpp` (`listBackingMaxElems` comment): says an over-threshold list backing would land in pinned old generation and hold unrecorded old-to-young edges. Large objects that may hold pointers are never placed in the old generation (`ThreadLocalHeap.cpp`), so the stated reason for the cap is stale. *(theory: runtime-data-structures)* VERIFIED (amendment review).

## test/

- [x] `test/codegen/run_tests.sh` header: cites missing `jit-test-tidy.md`. *(theory: codegen-tests)*
- [x] `test/codegen/run_llvm_statepoint_probes.sh`: cites deleted `EcoUnboxedAggCrossSpec.cpp` as capping field count. *(theory: codegen-tests)*
- [x] `test/codegen/arithmetic_int.mlir` and similar: `// RUN:` `%ecoc`/`%FileCheck` headers are decorative. *(theory: verification)*
- [x] `test/ChildStdin.hpp`, `test/stress-elm/main.cpp`, `test/platform/PlatformServicesTest.hpp`, `test/main.cpp`: describe forked children; harness spawns (`SpawnedChildren.hpp`, `IsolatedTestRunner.hpp`, SYS_008). *(theory: program-tests, runtime-tests)*
- [x] `test/gc-heap-tsan/README.md`: M4 `promo` "expected to fail" until CR-002/001/016; fixed (`ef550a60`). *(theory: runtime-tests)*
- [x] `test/gc-heap-tsan/README.md`: `ylos-sweep`/`det-cr019` described as live; `fork_arms.txt` marks `det-cr019:*` retired (HEAP_080). *(theory: runtime-tests)*
- [x] `test/genmc/AUDIT.md`: "49 rows" → ~62; "canary is not built yet" (also `test/tla/M1-snapshot-mark/AUDIT.md`). *(theory: runtime-tests, concurrency-models)*
- [x] `test/genmc/CMakeLists.txt`, AUDIT.md: budget called run-locally; drivers are canary-pinned. *(theory: runtime-tests)*
- [x] `test/tla/README.md`: "224 pins" is historical. *(theory: concurrency-models)*
- [x] `test/CMakeLists.txt`: canary comment says pin change fails the build (warns by default). *(theory: concurrency-models)* — the stale comment was in the root `CMakeLists.txt`, not `test/CMakeLists.txt`; fixed there.
- [x] `CheckPatterns.hpp`: `CHECK-DAG` is an alias for `CHECK`, unlike FileCheck. *(theory: verification)*
- [x] `benchmarks/backend-bench.sh`: documents itself as `scripts/backend-bench.sh`. *(theory: development-practice)*
