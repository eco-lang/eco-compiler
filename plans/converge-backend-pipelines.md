# Converge Backend Pipelines (ecoc / eco-boot / EcoRunner)

Implementation plan for `design_docs/converge-pipelines.md`.

## Goal

Collapse the three nearly-identical RS4GC + frame-pointer + DataLayout flows
in `ecoc.cpp`, `eco-boot.cpp`, and `EcoRunner.cpp` onto one shared backend
driver. Land each phase behind a green test run so any regression is bisected
to a single change.

## Current state (verified, not from doc)

- `addEcoGCPipeline` is declared in `runtime/src/codegen/Passes/EcoPtrIntVerify.h`.
- `EcoJIT::setupTargetTripleAndDataLayout` lives at
  `runtime/src/jit/EcoJIT.cpp:335`. It is a thin
  `setDataLayout` + `setTargetTriple` pair, equivalent to MLIR's
  `ExecutionEngine::setupTargetTripleAndDataLayout`.
- Per-tool RS4GC / DL ordering today:
  - `ecoc.cpp::dumpLLVMIR` (`ecoc -emit=llvm`):
    translate → RS4GC → optional post-RS4GC dump → init target →
    `ExecutionEngine::setupTargetTripleAndDataLayout` → opt → print.
    **DL set AFTER RS4GC.** No FP attribute.
  - `ecoc.cpp::runJIT`: transformer does RS4GC + FP. DL is set BEFORE
    the transformer by `EcoJIT::create` (`EcoJIT.cpp:280`).
    **DL already early.**
  - `eco-boot.cpp` AOT path: translate → optional pre-RS4GC dump →
    RS4GC → optional post-RS4GC dump → `createTargetMachine` (local
    helper that also sets triple+DL) → opt → FP loop → emit.
    **DL set AFTER RS4GC.** FP loop applied.
  - `EcoRunner.cpp::executeJIT`: transformer does RS4GC + FP. DL set
    BEFORE transformer by `EcoJIT::create`. **DL already early.**
- `eco-boot.cpp::createTargetMachine` is opt-level aware (passes
  `codeGenOpt` to `createTargetMachine`); the host-detect path
  (`JITTargetMachineBuilder::detectHost`) used by ecoc/EcoJIT is not.
  This difference is load-bearing for `-O0/-O1/-O2/-O3` AOT codegen
  and must be preserved.

## Phases

### Phase 1 — Extract `runRS4GCAndMaybeFramePointers` (no behaviour change)

**Files added:**
- `runtime/src/codegen/EcoBackend.h` — public API.
- `runtime/src/codegen/EcoBackend.cpp` — implementation.

**API:**
```cpp
namespace eco {
struct RS4GCOptions {
    std::string preDumpPath;        // optional pre-RS4GC dump (filename)
    std::string postDumpPath;       // optional post-RS4GC dump (filename)
    bool addFramePointerAttr = false;
};
void runRS4GCAndMaybeFramePointers(llvm::Module &m, const RS4GCOptions &opts);
} // namespace eco
```

Behaviour:
1. If `preDumpPath` non-empty, open + write IR (errors → `errs()`, do not abort).
2. Build `PassBuilder` + analysis managers, run `addEcoGCPipeline` over the
   module — identical to today's three call sites.
3. If `postDumpPath` non-empty, dump IR after RS4GC.
4. If `addFramePointerAttr`, walk non-declaration functions and add
   `addFnAttr("frame-pointer", "all")`.

**CMake wiring (3 targets):**
- `ecoc` (`add_llvm_executable`): add `EcoBackend.cpp` to its source list.
- `EcoRunner` (`add_mlir_library`): add `EcoBackend.cpp` to its source list.
- `eco-boot-native` (`add_llvm_executable`): add `EcoBackend.cpp` to its
  source list.

**Call-site replacements (Phase 1 stays semantically identical):**

- `ecoc.cpp::dumpLLVMIR` (lines ~214–243): replace the RS4GC `PassBuilder`
  block and the optional post-dump with one call:
  ```cpp
  eco::RS4GCOptions o;
  o.postDumpPath = dumpRS4GCIR;
  o.addFramePointerAttr = false;
  eco::runRS4GCAndMaybeFramePointers(*llvmModule, o);
  ```
  Order preserved: RS4GC still runs BEFORE the existing DL setup
  (ordering flip is Phase 3, not now).

- `ecoc.cpp::runJIT` transformer (lines ~296–323): replace RS4GC pipeline
  + FP loop with:
  ```cpp
  eco::RS4GCOptions o;
  o.addFramePointerAttr = true;
  eco::runRS4GCAndMaybeFramePointers(*m, o);
  ```
  Note: the helper's `pre/postDumpPath` fields are left empty here. No
  JIT-side CLI flag for RS4GC dump is added — the hook exists in
  `RS4GCOptions` if a future JIT-only RS4GC bug needs it, but the
  user-facing surface stays AOT-only for now.

- `EcoRunner.cpp::executeJIT` transformer (lines ~199–227): same swap as
  `ecoc::runJIT`. EcoRunner has no dump CLI flags; opts left empty except
  `addFramePointerAttr=true`.

- `eco-boot.cpp` (lines ~699–739, 765–770): replace the pre-dump block,
  RS4GC block, post-dump block, AND the FP loop near the bottom of the
  function with one call:
  ```cpp
  eco::RS4GCOptions o;
  o.preDumpPath = dumpPreRS4GCIR;
  o.postDumpPath = dumpRS4GCIR;
  o.addFramePointerAttr = true;
  {
      eco::LoweringStats::Scope scope(stats, "LLVM RS4GC pipeline");
      eco::runRS4GCAndMaybeFramePointers(*llvmModule, o);
  }
  ```
  Important: the FP loop at ~765–770 must be deleted at the same time
  (otherwise FP is applied twice — harmless but a latent
  attribute-already-set source-of-confusion). The `LoweringStats::Scope`
  must continue to wrap the RS4GC call so timing data doesn't disappear.

**Validation:** `cmake --build build --target full`, then
`cd compiler && npx elm-test-rs --fuzz 1`. Any regression here is a
copy-paste error in the helper, not a semantic shift.

### Phase 2 — Add `EcoBackendJob` / `runEcoBackend` thin façade

**EcoBackend.h additions:**
```cpp
enum class BackendKind {
    DumpLLVMText,     // ecoc -emit=llvm / eco-boot -emit=llvm path 1
    EmitObjectFile,   // eco-boot -emit=obj|exe
    JITInvokePacked,  // EcoRunner / ecoc::runJIT — wired in Phase 4
};

struct EcoBackendJob {
    BackendKind kind;
    llvm::TargetMachine *tm = nullptr;
    llvm::CodeGenOptLevel optLevel = llvm::CodeGenOptLevel::None;
    bool needsFramePointerAttr = false;
    std::string preRS4GCDumpPath;
    std::string postRS4GCDumpPath;
    // Phase 3+ fields (objectFilePath, exeFilePath) added when used.
};

llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job);
```

**EcoBackend.cpp Phase 2 body:** call
`runRS4GCAndMaybeFramePointers` with the dump/FP fields from the job,
then switch on `kind` and `return Error::success()` for `DumpLLVMText`
and `EmitObjectFile` (no opt / emit moved in yet).
`JITInvokePacked` returns `llvm_unreachable` for now (not exposed in
public API until Phase 4 — guard via header so callers can't accidentally
construct one).

Phase 2 does NOT migrate any tool to `runEcoBackend` yet — it just adds
the façade. (Earlier rev of this plan had Phase 2 migrate AOT; pulled out
because there's no ordering change yet, so the migration adds risk
without producing the desired DL-early outcome. Tools migrate in Phase 3
together with the ordering flip.)

**Validation:** Build only — no runtime behaviour change.

### Phase 3 — Flip DataLayout ordering: DL set BEFORE RS4GC

The semantic change. Two tools to migrate; do them in separate commits.

#### 3.1 `ecoc.cpp::dumpLLVMIR`

New order: translate → InitializeNativeTarget → detectHost +
`createTargetMachine` → `EcoJIT::setupTargetTripleAndDataLayout(mod, tm)`
→ `runEcoBackend(DumpLLVMText, postRS4GCDumpPath=dumpRS4GCIR, FP=false)`
→ opt → print.

Concretely:
- Move the `InitializeNativeTarget` + `JITTargetMachineBuilder::detectHost`
  + `createTargetMachine` block from ~245–260 up to immediately after
  translation (~213).
- Replace `ExecutionEngine::setupTargetTripleAndDataLayout(mod, tm)`
  with `EcoJIT::setupTargetTripleAndDataLayout(mod, tm)` for consistency
  (semantically identical — both call `setDataLayout` + `setTargetTriple`;
  we prefer the eco-namespaced helper because Phase 4 also uses it).
- Replace the inline RS4GC call (added in Phase 1) with `runEcoBackend`
  carrying `kind = DumpLLVMText`, `tm = tm.get()`, `optLevel = …`,
  `postRS4GCDumpPath = dumpRS4GCIR`.
- Keep `enableOpt` opt and `llvm::outs() << *llvmModule` in `dumpLLVMIR`
  — `runEcoBackend(DumpLLVMText)` is RS4GC-only in this phase.

#### 3.2 `eco-boot.cpp`

New order: translate → call existing `createTargetMachine` helper (which
already sets triple+DL on the module) → `runEcoBackend(EmitObjectFile,
preRS4GCDumpPath, postRS4GCDumpPath, FP=true, optLevel)` → opt → emit.

Concretely:
- Move the Step-5 `createTargetMachine` block from ~745–752 up to
  immediately after translation (~691) — KEEP the local `createTargetMachine`
  helper because it is opt-level aware (preserves AOT `-O0..-O3` codegen).
- Replace the Phase-1 `runRS4GCAndMaybeFramePointers` call with a
  `runEcoBackend(EmitObjectFile, ...)` call carrying the pre/post dump
  paths, FP=true, and `optLevel`.
- Keep Steps 6 (opt), 7 (emit object), and 8 (link exe) where they are
  for Phase 3. Migration into `runEcoBackend` is Phase 3.5 (optional)
  or deferred.

**Validation per sub-step:**
`cmake --build build --target full` after 3.1, then again after 3.2.
Bisecting any DL-related miscompile to one or the other tool is the
whole point of splitting the commits.

#### 3.3 — Move opt + object emit + exe-link into `runEcoBackend` (separate follow-up commit)

Land this AFTER 3.1 + 3.2 are green, as its own commit. Keeping
the DL-ordering flip (3.1/3.2) and the opt/emit/link move (3.3) in
separate commits makes bisection trivial: a DL-related regression
points at 3.1/3.2; an emission-related regression points at 3.3.

Expand `runEcoBackend(EmitObjectFile)` to also:
- run `makeOptimizingTransformer(job.optLevel, 0, job.tm)`,
- call eco-boot's existing `emitObjectFile` helper with
  `job.objectFilePath`,
- optionally link an exe via eco-boot's existing linker driver if
  `job.exeFilePath` is non-empty.

Add `objectFilePath` and `exeFilePath` fields to `EcoBackendJob` at
this point (not earlier — keep the struct minimal until used).
`eco-boot.cpp` fills in the new job fields and the body shrinks to
"parse → translate → DL early → `runEcoBackend` → write stats → done."

### Phase 4 — Bring JIT (EcoRunner + ecoc::runJIT) onto `runEcoBackend`

By Phase 4, all three tools share `runEcoBackend` for RS4GC + FP. Phase 4
adds `JITInvokePacked` dispatch and migrates JIT transformers.

**EcoBackend changes:**
- Add `BackendKind::JITInvokePacked` to public `runEcoBackend` switch.
- For `JITInvokePacked`, after RS4GC+FP, call
  `makeOptimizingTransformer(job.optLevel, 0, job.tm)` against the module
  (replicating the `baseTransformer` step today inside the JIT lambdas).
- `packFunctionArguments` (`EcoJIT.cpp:281`) stays where it is — it is
  JIT-specific scaffolding tied to LLJIT's calling convention, not
  part of the generic RS4GC/backend pipeline. The doc's
  `needsPackedInvokeWrappers` flag is dropped from the plan; do not
  add it to `EcoBackendJob`.

**`EcoRunner.cpp::executeJIT` transformer:** replace the
Phase-1 `runRS4GCAndMaybeFramePointers + baseTransformer` body with
one `runEcoBackend(JITInvokePacked, ...)` call. The `baseTransformer`
binding can be deleted.

**`ecoc.cpp::runJIT` transformer:** same swap.

Note: both JIT paths already have DL set early by `EcoJIT::create`
(at `EcoJIT.cpp:280`). Phase 4 doesn't change ordering — it just
unifies the transformer body.

**Validation:** Full E2E plus stress tests. JIT covers most regressions
because every Elm E2E test runs through it.

### Phase 5 — AOT canary in E2E (beachhead, not a full refactor)

For this unit of work, ship a small handful of canary E2E tests
(start with one) that exercise the AOT path: write MLIR to a temp
file, shell out to `eco-boot-native` with `--emit=exe`, run the
produced binary, and compare stdout to existing `-- CHECK:` patterns.
This is enough to catch most JIT/AOT drift in the converged backend
without a structural change to the harness.

The full `BackendMode`-style refactor (every Elm E2E test runs under
both `BackendMode::JIT` and `BackendMode::AOT`) is the right long-term
shape but is tracked as a separate follow-up plan — not bundled here.

### Phase 6 — Bake JIT + AOT E2E gates into bootstrap.md

The convergence story isn't complete until the bootstrap chain itself
exercises both faces of the shared backend. Today
`guides/bootstrap.md` walks Stages 1–8 with no test gating; the
existing `cmake --build build --target full` E2E suite is invoked
separately and only covers Stage 1's `guida.js` + EcoRunner JIT — it
never touches Stages 2–8 or the AOT path.

This phase rewrites `guides/bootstrap.md` to insert two E2E gates:

#### 6.1 JIT E2E gate after Stage 1

Right after `./scripts/build.sh bin` (the step that produces
`build/compiler/build-xhr/bin/guida.js`), insert:

```bash
cmake --build build --target full
```

Rationale: this is the existing JIT E2E suite. It needs Stage 1's
`guida.js` (which the default `GUIDA_JS_PATH` in
`compiler/bin/index.js` resolves to) plus the EcoRunner library. It
validates the Stage-1 frontend + the entire MLIR-codegen + runtime
+ JIT stack BEFORE we burn cycles on Stages 2–5's self-compiles.
Failures here are localised to Stage 1 or the runtime, not a
self-compile interaction.

No code changes required for 6.1 — it's a doc-only insertion that
documents the existing test target as a bootstrap gate.

#### 6.2 AOT E2E gate after Stage 6

Right after Stage 6 (eco-compiler ELF produced), insert a new
target invocation:

```bash
cmake --build build --target run-aot-e2e
```

This new CMake target drives a new `aot-e2e` binary (or extends the
existing `mlir-equivalence` pattern) that, for each Elm E2E test
source under `test/<pkg>/src/*Test.elm`:

1. Compiles `.elm → .mlir` using **`build/compiler/build-kernel/bin/eco-compiler`**
   (Stage 6's native ELF), into an isolated per-test `--builddir`.
2. Lowers `.mlir → ELF` using
   **`build/runtime/src/codegen/eco-boot-native`** with `--emit=exe`.
3. Runs the produced ELF, captures stdout, and verifies against the
   test source's `-- CHECK:` / `-- CHECK-NOT:` patterns
   (reusing `test/CheckPatterns.hpp`).

Concurrency capped (e.g. `AOT_E2E_JOBS=4` env, mirroring
`MLIR_EQUIV_JOBS`). Failures report the failing test name + the
divergence (mismatched CHECK pattern, non-zero exit, timeout).

**New code:**
- `test/aot_e2e_main.cpp` — a binary modelled on
  `test/mlir_equivalence_main.cpp` but running compiled ELFs and
  comparing stdout to CHECK patterns instead of comparing
  byte-equality of two MLIRs.
- `test/CMakeLists.txt`: `add_executable(aot-e2e …)` +
  `add_custom_target(run-aot-e2e …)` paralleling the
  `mlir-equivalence` / `run-mlir-equivalence` pair, with
  `DEPENDS` on `eco-compiler` + `eco-boot-native` so a missing
  bootstrap stage produces a clear "Stage 6 not built" diagnostic.

**Choice of compiler for step 1 — Stage 6 vs Stage 7:**
Stage 6's `eco-compiler` is preferred. Earlier failure isolates
faster: a regression caught at the post-Stage-6 gate implicates
Stage 5's MLIR + `eco-boot-native`; the same regression caught
after Stage 7 also implicates Stage 6→7's self-compile, widening
the search. Stage 7 is also expensive (~15 min self-compile of
the whole compiler today); we want Stage 6 to be the cheapest gate.

**Optional 6.3 — Re-run AOT E2E after Stage 7:** once the
`run-aot-e2e` target exists, re-invoking it after Stage 7 with
`ECO_COMPILER=…/eco-compiler-boot` (env override) is cheap and
provides a belt-and-braces check that Stage 7's MLIR-gen behaves
the same as Stage 6's. Recommended but not load-bearing; can be a
follow-up commit.

#### Sequence in the rewritten `guides/bootstrap.md`

```
Stage 1   build.sh bin          → guida.js
GATE 6.1  cmake … --target full → existing JIT E2E suite     [NEW]
Stage 2   build-self.sh         → eco-boot.js
Stages 3+4 build-verify.sh      → JS fixed-point check
Stage 5   eco-boot-2.js make    → eco-compiler.mlir
Stage 6   eco-boot-native …     → eco-compiler (native ELF)
GATE 6.2  cmake … --target run-aot-e2e                       [NEW]
Stage 7   eco-compiler make …   → eco-compiler-boot.mlir, .ELF
[Optional GATE 6.3 re-run AOT E2E against eco-compiler-boot] [NEW]
Stage 8   eco-compiler-boot make + cmp                        (fixed-point ELF)
```

The "All stages in sequence" block at the bottom of `bootstrap.md`
gets the two new `cmake` invocations inserted at the matching
positions.

#### Risks / watch items

- **Stage 6 doesn't exercise --kernel-package / --local-package
  paths in the same way Stage 7 does.** When using Stage 6's
  `eco-compiler` to compile test sources, the test packages live
  under `build/test/<pkg>/` and don't carry the kernel-package
  flags Stage 5/7 use. The `aot-e2e` binary needs to pass any
  flags the existing JIT E2E suite passes today (see
  `ElmE2ETestBase::compileElmToMlir` — `extraFlags`,
  `--builddir`, text/bytecode flag).
- **eco-boot-native's emit mode.** Need to confirm
  `eco-boot-native …mlir -o exe` produces a runnable exe (not just
  an object file) today, or whether `--emit=exe` is the right flag.
  This matters for the 6.2 wire-up but is straightforward to
  resolve by reading `eco-boot.cpp`'s `EmitAction` handling.
- **Test isolation.** Each AOT compile produces a real ELF in an
  isolated scratch dir; `ADDITIONAL_CLEAN_FILES` should drop those
  on `ninja clean`, mirroring `mlir-equivalence-out`.
- **CI time.** A full E2E suite running through `eco-boot-native`
  + ELF execution per test is much slower than the JIT path. The
  bootstrap chain is already long; budget for this and keep the
  AOT E2E gate parallelised. Consider a `TEST_FILTER`-equivalent
  for the AOT runner from day one.

## Risks / what to watch

- **Phase 3 DL-flip is the only behaviour change.** A DataLayout set on
  the module BEFORE RS4GC can change RS4GC's choices because RS4GC
  reads pointer sizes / address-space layout from the DL. The whole
  point of the convergence is that all three tools should agree on
  this ordering — but the practical worry is that one of the tools
  was secretly relying on RS4GC seeing the default (no-DL) module.
  Mitigation: split 3.1 and 3.2 commits, run full E2E after each.
- **Phase 1 FP-loop duplication.** When swapping in
  `runRS4GCAndMaybeFramePointers` in `eco-boot.cpp`, the explicit FP loop
  at the bottom of the function MUST be deleted in the same commit.
  Easy to miss because it lives ~70 lines below the RS4GC block.
- **LoweringStats scopes.** eco-boot wraps RS4GC in a stats scope. The
  helper itself should not own the scope — keep the scope at the call
  site so other tools (ecoc, EcoRunner) that don't use LoweringStats
  aren't forced to depend on it.
- **Header location.** `addEcoGCPipeline` declaration is in
  `Passes/EcoPtrIntVerify.h` (not great naming, but is what the doc
  says). `EcoBackend.cpp` includes it; this is the only new
  cross-directory include.

## Resolved decisions

1. **No JIT-side `--dump-rs4gc-ir` flag.** The hook stays in
   `RS4GCOptions` for future use; no user-facing CLI surface is added
   to `ecoc::runJIT` or EcoRunner. If a JIT-only RS4GC bug shows up,
   add a flag or env-var at that time.
2. **Phase 3.3 lands as a separate follow-up commit** after 3.1/3.2 —
   never bundled. DL-flip and opt/emit/link move are kept in separate
   commits so bisection of any regression points at exactly one
   change.
3. **`packFunctionArguments` stays in `EcoJIT::create`.** It is
   LLJIT-calling-convention scaffolding, not part of the generic
   RS4GC/backend pipeline. The `needsPackedInvokeWrappers` knob from
   the design doc is dropped.
4. **`createTargetMachine` paths stay divergent.** eco-boot's
   opt-level-aware helper is load-bearing for AOT `-O0..-O3`; ecoc/JIT
   use `JITTargetMachineBuilder::detectHost()` with Aggressive/None,
   which is a fine simplification. Revisit only if JIT tuning needs
   finer-grained codegen-opt control.
5. **Phase 5 = single AOT canary** (or small handful), not a
   `BackendMode` harness refactor. Full both-modes coverage is the
   right long-term shape and is tracked as a separate follow-up plan.
