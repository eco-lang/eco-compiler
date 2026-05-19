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

### Phase 5 — AOT E2E test runner (independent target, isolated outputs)

Build out a new test runner that exercises the AOT path end-to-end on
the same `*.elm` sources the JIT E2E suite uses today. The runner
lives in its own binary with its own CMake target so the existing
`cmake --build build --target full` JIT suite is not affected by AOT
runtime cost or AOT-only failures. Phase 5 lands incrementally:

1. **Step A** — stand up the new runner + target with a small starter
   set of tests (5–10 representative `.elm` sources covering basic
   arithmetic, recursion, closures, simple list/string ops, and one
   effect-driven program). Land + green.
2. **Step B** — expand to the full set of `test/<pkg>/src/*Test.elm`
   sources. Land + green. Any tests that surface JIT/AOT divergence
   get filed as separate bugs; the runner is not the place to fix
   them.

Phase 5 also updates `guides/bootstrap.md` to wire the new target
into the bootstrap chain at the earliest valid point (see "Bootstrap
gates" below) — including a parallel insertion of the existing JIT
E2E suite as a Stage 1 gate, for the same early-failure rationale.

#### Shape

- **New binary:** `test/aot_e2e_main.cpp`, modelled on
  `test/mlir_equivalence_main.cpp`. For each Elm test source it
  drives:
  1. Compile `.elm → .mlir` by shelling out to
     `node --stack-size=65536 build/compiler/build-kernel/bin/eco-boot-2-runner.js make <test.elm> --output=<test.mlir>`
     — the Stage 3 kernel-IO JS compiler (same compiler Stage 5
     uses to produce `eco-compiler.mlir`).
  2. Lower `.mlir → ELF` by shelling out to
     `build/runtime/src/codegen/eco-boot-native <mlir> -o <exe>`.
  3. Execute the ELF, capture stdout/stderr, compare against the
     test source's `-- CHECK:` / `-- CHECK-NOT:` patterns via the
     existing `test/CheckPatterns.hpp` machinery.
- **New CMake target:** `aot-e2e` (the binary) and `run-aot-e2e`
  (build + run + report), modelled on `mlir-equivalence` /
  `run-mlir-equivalence`. `DEPENDS` on `eco-boot-native` AND on the
  `eco-boot-2` target — which transitively pulls in Stages 1, 2, and
  3 of the bootstrap chain so a clean checkout's
  `cmake --build build --target run-aot-e2e` works end-to-end.
  Supports `TEST_FILTER` from day one (mirroring the existing
  pattern) so partial runs are easy.
- **Concurrency:** capped via `AOT_E2E_JOBS=<N>` env, default 4,
  matching `MLIR_EQUIV_JOBS`. Per-test AOT compile + run takes
  ~seconds; parallelism keeps wall-clock reasonable.
- **Frontend choice (Stage 3 eco-boot-2.js, not Stage 1 guida.js):**
  the JIT E2E suite today uses Stage 1's `guida.js` (the XHR-based
  variant). The AOT runner uses Stage 3's `eco-boot-2.js` — the
  kernel-IO self-compiled JS compiler — for two reasons:
  1. **Matches Stage 5's compiler choice.** Stage 5 produces
     `eco-compiler.mlir` via `eco-boot-2.js`; using the same
     compiler for AOT-test MLIR means any cross-mode MLIR diffs
     reflect *only* the test source, not a compiler-stage mismatch.
  2. **Exercises the kernel-IO path under test.** Stage 1's XHR
     compiler is a bootstrap artefact; Stage 3 is the "production"
     JS compiler with kernel IO. Running E2E tests through it
     gives the kernel-IO path its own coverage.

  The cost: `run-aot-e2e` requires Stages 1+2+3 to be built first
  (~minutes for a clean tree, sub-second when already built).
  CMake target dependency handles that automatically; the user
  doesn't need to run any extra commands.

  No `--kernel-package` / `--local-package` flags should be passed
  for ordinary test sources — those are specific to compiling
  Eco's own source against the kernel package. Confirm during
  implementation by trying a representative test first.

  A "Stage 6 frontend" variant (using the *native* `eco-compiler`)
  is a clean future enhancement once the basic runner ships.

#### Output isolation

AOT outputs must not collide with the JIT suite's outputs. The JIT
suite writes per-package state at `${CMAKE_BINARY_DIR}/test/<pkg>/`
(elm.json + src symlink + eco-stuff/ + elm-stuff/), and MLIR lands at
`${CMAKE_BINARY_DIR}/test/<pkg>/eco-stuff/mlir/<Test>.mlir`.

The AOT runner gets a **parallel shadow tree** at
`${CMAKE_BINARY_DIR}/test/aot-e2e/<pkg>/` with the same shape:
- `elm.json` (copy of the source `test/<pkg>/elm.json`).
- `src` (symlink to `test/<pkg>/src`, exactly like the JIT shadow).
- Per-test outputs land at:
  - MLIR: `${CMAKE_BINARY_DIR}/test/aot-e2e/<pkg>/eco-stuff/mlir/<Test>.mlir`
  - ELF: `${CMAKE_BINARY_DIR}/test/aot-e2e/<pkg>/aot-bin/<Test>`
  - Test stdout/stderr captures: `${CMAKE_BINARY_DIR}/test/aot-e2e/<pkg>/run-out/<Test>.{out,err}`

`test/CMakeLists.txt` materialises this tree at configure time using
the same `file(COPY …)` + `file(CREATE_LINK … SYMBOLIC)` pattern as
the JIT shadow. Set
`ADDITIONAL_CLEAN_FILES "${CMAKE_BINARY_DIR}/test/aot-e2e"` so
`ninja clean` drops the whole AOT output tree.

With this layout, the JIT and AOT MLIRs for the same test source
co-exist at known paths and can be diffed directly — a future
`mlir-equivalence`-style cross-mode check is a small follow-up.

#### Bootstrap gates (updates to `guides/bootstrap.md`)

Today `bootstrap.md` walks Stages 1–8 with no test gating. Phase 5
inserts two gates at the earliest valid points in the chain so a
regression in either backend face fails fast, before downstream
stages burn cycles.

**Gate A — JIT E2E after Stage 1.** Right after `./scripts/build.sh
bin` produces `guida.js`, insert:

```bash
cmake --build build --target full
```

The existing JIT E2E suite needs only Stage 1's `guida.js` plus the
EcoRunner library. Failing here pins the regression to Stage 1's
frontend or to the runtime/JIT path — well before Stages 2–5's
self-compiles.

No code changes for Gate A; it's a doc-only insertion that documents
the existing target as a bootstrap gate.

**Gate B — AOT E2E after Stages 3+4.** Right after
`./scripts/build-verify.sh` (which produces and fixed-point-verifies
`eco-boot-2.js`), insert:

```bash
cmake --build build --target run-aot-e2e
```

The new AOT runner needs `eco-boot-2.js` (just produced) and
`eco-boot-native` (CMake handles the dep). This is the **earliest
valid point** for the AOT gate: gating later (after Stage 5 or
Stage 6) wouldn't surface AOT regressions any earlier, and the
original Phase-6-style "after Stage 6" gate was only delayed
because that plan used Stage 6's native `eco-compiler` as the
frontend. With `eco-boot-2.js` as the frontend, the gate moves up.

#### Rewritten sequence in `guides/bootstrap.md`

```
Stage 1   build.sh bin            → guida.js
GATE A    cmake … --target full   → JIT E2E suite             [NEW]
Stage 2   build-self.sh           → eco-boot.js
Stages 3+4 build-verify.sh        → eco-boot-2.js, fixed point
GATE B    cmake … --target run-aot-e2e → AOT E2E suite        [NEW]
Stage 5   eco-boot-2.js make      → eco-compiler.mlir
Stage 6   eco-boot-native …       → eco-compiler (native ELF)
Stage 7   eco-compiler make …     → eco-compiler-boot.mlir,.ELF
Stage 8   eco-compiler-boot make + cmp → native fixed point
```

The "All stages in sequence" block at the bottom of `bootstrap.md`
gets the two new `cmake` invocations inserted at the matching
positions. Document the cost briefly in each gate's prose: Gate A
adds the existing JIT-suite wall clock; Gate B adds the AOT
runner's wall clock (sized to its Step A/B scope).

#### Risks / watch items

- **eco-boot-native CLI surface.** Confirm the exact flag for
  emitting a runnable exe when the input is a `.mlir` file (the
  existing path is `eco-boot-native <input.mlir> -o <output>` which
  defaults to exe; verify against `eco-boot.cpp`'s `EmitAction`).
- **Frontend caches.** `eco-boot-2.js` writes `.ecot` and
  `elm-stuff/` caches under its cwd. Running the AOT shadow with
  its own per-package cwd means those caches land in the AOT tree,
  not the JIT tree — no cache invalidation cross-talk.
- **JS-bootstrap prereq for `run-aot-e2e`.** The target depends on
  the `eco-boot-2` CMake target, which runs Stages 1+2+3 of the JS
  bootstrap on a clean tree (build-xhr `guida.js` → kernel-IO
  `eco-boot.js` → fixed-point-verified `eco-boot-2.js`). First
  invocation after `rm -rf build` takes minutes; subsequent
  invocations are cache hits. CI runs that already do bootstrap
  pay zero additional cost here.
- **Stale `.ecot` caches between AOT runs.** The bootstrap doc
  flags that Stage 5 needs `find … -name '*.ecot' -delete` before
  running because Stages 2–4 don't invalidate MLIR-output caches.
  The AOT shadow tree's `.ecot` caches will face the same issue if
  the runner is re-invoked after the JS compiler changes. Mitigation:
  either drop the AOT shadow's `eco-stuff/` on every `run-aot-e2e`
  invocation, or document the manual sweep. Pick one during
  implementation.
- **CI time.** Per-test AOT compile is much slower than JIT (each
  invocation is a fresh `eco-boot-native` process running the full
  LLVM pipeline + linking). Keep `run-aot-e2e` opt-in and
  parallelised; do not bundle into `target full`. Step A starts
  small to keep total wall-clock manageable.
- **Test sources with no main / pure typecheck tests.** Some Elm E2E
  sources are typecheck-only (no `main`, can't be executed). The
  runner must skip these the same way the existing JIT runner does
  (see `ElmE2ETestBase`'s skip logic).
- **Divergence triage.** When Step B turns on the full set, expect
  some tests to fail AOT-only — those are bugs to file, not
  blockers for Phase 5. The runner's job is to *report* divergence,
  not to prove parity.

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
5. **Phase 5 = independent AOT E2E runner with its own target and
   isolated output tree**, plus the bootstrap-doc updates folded
   back in. Starts with a small set of tests (Step A) and expands to
   the full E2E corpus (Step B). The bootstrap.md edits insert two
   gates: JIT E2E after Stage 1 and AOT E2E after Stages 3+4 (the
   earliest valid points; the AOT gate moves up from the original
   "after Stage 6" because the runner uses `eco-boot-2.js` as the
   frontend, not Stage 6's native compiler). The `BackendMode`-style
   harness refactor (every test runs under both JIT and AOT in one
   binary) remains a separate long-term option.
