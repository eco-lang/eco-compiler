# GC Liveness Audit Pass

## Goal

Add a debug-only verification pass `EcoGCLivenessAudit` that recomputes SSA
liveness of `!eco.value` values inside each function and, for every op
implementing `eco::GCRootCarrier`, diagnoses any value that is semantically
live across the op but missing from the op's attached GC root set.

Positioned in the pipeline immediately after `EcoGCPrepare`, before
`EcoToLLVM`. Acts as a backstop verifying that EcoGCPrepare's root sets
correctly reflect SSA liveness.

## Context (what already exists)

- `EcoGCPrepare` (`runtime/src/codegen/Passes/EcoGCPrepare.cpp`) is a
  module-level pass that already attaches GC roots to all GCRootCarrier ops
  via the `eco::GCRootCarrier` interface, using MLIR's `mlir::Liveness`
  analysis (`computeLiveRoots`, lines 49–80).
- The interface class name in C++ is `eco::GCRootCarrier` (TableGen def is
  `Eco_GCRootCarrierOpInterface`, used by the dialect at 14 op definitions).
  Methods: `getGCRoots()` and `setGCRoots(ValueRange)`.
- An ad-hoc self-check already lives inside `EcoGCPrepare.cpp` under
  `#if ECO_GC_DEBUG_VERBOSE` (lines 151–190). It writes diagnostics to
  `llvm::errs()` but does **not** fail the pipeline. The new pass should
  supersede this block (and the block can be removed once the new pass is
  wired in and proven equivalent).
- `ECO_GC_DEBUG` is already defined for `obj.EcoPasses`, `ecoc`, and
  `obj.EcoRunner` via CMake when the option is on (defaulted ON for Debug
  builds). No new build flag needed.
- `registerEcoPasses()` is implemented in `Passes/EcoToLLVM.cpp` (not
  `Passes.cpp`); it currently registers only `EcoToLLVMPass`.
- The pipeline is built in `EcoPipeline.cpp::buildEcoToLLVMPipeline`
  (lines 67–86). `EcoGCPrepare` runs at line 77.

## Plan

### Step 1 — Declare the pass

Edit `runtime/src/codegen/Passes.h`:

- Add a new declaration in the "Stage 2.5: GC Preparation" block:

  ```cpp
  // Audits GC root sets attached by EcoGCPrepare against SSA liveness of
  // !eco.value values. Emits diagnostics and fails the pipeline if any
  // GCRootCarrier op is missing a root that is semantically live across it.
  // No-op in non-debug builds (gated on ECO_GC_DEBUG).
  std::unique_ptr<mlir::Pass> createEcoGCLivenessAuditPass();
  ```

### Step 2 — Implement the pass

Create `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp`:

- A `PassWrapper<…, OperationPass<func::FuncOp>>` that uses
  `MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID`.
- `getArgument()` returns `"eco-gc-liveness-audit"`,
  `getDescription()` describes the audit.
- **Reuse `mlir::Liveness`**, do **not** hand-roll a liveness fixpoint.
  The user's draft uses a custom dataflow loop, but `EcoGCPrepare` already
  uses `mlir::Liveness` and `isDeadAfter(v, op)`. We must match its notion
  of liveness exactly, otherwise the audit will diverge from what
  EcoGCPrepare attaches and produce noise.
- Body sketch:
  ```cpp
  void runOnOperation() override {
  #ifndef ECO_GC_DEBUG
      return;
  #else
      auto func = getOperation();
      if (func.isExternal()) return;
      mlir::Liveness liveness(func);

      bool hadError = false;
      func.walk([&](Operation *op) {
          auto carrier = dyn_cast<eco::GCRootCarrier>(op);
          if (!carrier) return;

          // Recompute what should be live at this op (mirrors
          // EcoGCPrepare::computeLiveRoots).
          auto shouldBeLive = computeLiveRoots(liveness, op);

          // Union with op's own !eco.value operands — required for ops
          // whose lowering expands into alloc + separate field stores
          // (construct.record/custom). EcoGCPrepare does this same union
          // for alloc group leaders; we must do it here for parity.
          for (Value v : op->getOperands())
              if (isEcoValue(v)) shouldBeLive.push_back(v);

          // Compare against attached roots.
          ValueRange roots = carrier.getGCRoots();
          llvm::DenseSet<Value> rootSet(roots.begin(), roots.end());

          for (Value v : shouldBeLive) {
              if (rootSet.count(v)) continue;
              auto diag = op->emitError("[gc-liveness-audit] value live "
                                        "across this GC root carrier but "
                                        "missing from its GC root set");
              diag.attachNote(v.getLoc()) << "missing value: " << v;
              hadError = true;
          }
      });

      if (hadError) signalPassFailure();
  #endif
  }
  ```
- `isEcoValue` and `computeLiveRoots` should be **factored out** of
  `EcoGCPrepare.cpp` into a shared internal header (e.g.
  `Passes/EcoGCLiveness.h`) so the audit pass and EcoGCPrepare share one
  authoritative definition. Otherwise the audit can only ever be as right
  as a stale copy of the analysis.

### Step 3 — Refactor liveness helpers into a shared header

Create `runtime/src/codegen/Passes/EcoGCLiveness.h`:

- Move the `isEcoValue` and `computeLiveRoots` helpers from
  `EcoGCPrepare.cpp` (lines 39–80) into the header (or a `.cpp` if you
  prefer non-inline).
- Update `EcoGCPrepare.cpp` to include this header and remove the local
  copies.
- The audit pass includes the header.

### Step 4 — Register the pass

Edit `Passes/EcoToLLVM.cpp::registerEcoPasses()` (line ~374):

```cpp
void eco::registerEcoPasses() {
    PassRegistration<EcoToLLVMPass>();
    PassRegistration<EcoGCLivenessAuditPass>(
        []{ return createEcoGCLivenessAuditPass(); });
}
```

(Or follow whatever pattern other passes converge on — currently only
`EcoToLLVMPass` is registered, so this is mostly forward-looking.)

### Step 5 — Wire into the pipeline

Edit `EcoPipeline.cpp::buildEcoToLLVMPipeline` after the `EcoGCPrepare`
call (line 77):

```cpp
pm.addPass(eco::createEcoGCPreparePass());
#ifdef ECO_GC_DEBUG
pm.addNestedPass<func::FuncOp>(eco::createEcoGCLivenessAuditPass());
#endif
```

Note: it has to be `addNestedPass<func::FuncOp>` because the audit is a
`func::FuncOp` pass, while `EcoGCPrepare` is a `ModuleOp` pass.

### Step 6 — Add the source file to CMake

Edit `runtime/src/codegen/CMakeLists.txt` line ~204 (the `EcoPasses`
library source list):

```cmake
Passes/EcoGCPrepare.cpp
Passes/EcoGCLivenessAudit.cpp   # NEW
```

The existing `target_compile_definitions(obj.EcoPasses PRIVATE
ECO_GC_DEBUG=1)` (lines 254–256) already gates the new file.

### Step 7 — Remove the inline self-check from EcoGCPrepare

Once Step 5 is verified working, delete the
`#if ECO_GC_DEBUG_VERBOSE` block in `EcoGCPrepare.cpp` (lines 151–190).
The new pass replaces it and is a strict improvement (fails the build
instead of just printing to stderr).

### Step 8 — Build and run

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

If the audit fires, treat each diagnostic as a real bug in EcoGCPrepare
or earlier MLIR generation and investigate before silencing.

## Resolved design decisions

1. **Use `mlir::Liveness`, not a hand-rolled fixpoint.** The audit asks
   the same question `EcoGCPrepare` answered, so it uses the same
   analysis. No divergence risk; analysis cost is fine for a debug-only
   pass.

2. **Skip nested regions in v1.** Only audit `GCRootCarrier` ops sitting
   in the top-level region of the `func.func`. EcoGCPrepare's
   per-block `Liveness` is blind to cross-iteration uses of values
   captured into nested regions (its own comment, lines 284–292), and it
   works around this by unioning the front-end's operand list — a
   workaround the audit cannot replicate. Avoid false positives by
   skipping `scf.while` / `scf.if` bodies and leave a clear TODO in the
   pass for future region-aware coverage.

3. **Hard fail.** `signalPassFailure()` on any violation. A missed root
   is a correctness bug. If noise becomes a problem we can later add a
   `--eco-gc-liveness-soft` pass option or demote specific patterns to
   remarks.

4. **Interface name.** Use `eco::GCRootCarrier` (matches existing
   EcoGCPrepare usage at lines 159, 267). The TableGen def
   `Eco_GCRootCarrierOpInterface` generates this shorter C++ name.

5. **Diagnostic shape.** One `op.emitError("[gc-liveness-audit] ...")`
   per carrier op, including the count of missing values. Each missing
   value gets an `attachNote` (or `emitRemark` on its defining op /
   block argument owner) localizing the origin. Keeps log volume bounded
   per safepoint while still pointing to every missing value.

6. **`computeLiveRoots` parity.** The shared helper (Step 3) preserves
   EcoGCPrepare's exact set: live-in ∪ block-arguments ∪ ops-before-target,
   filtered by `!liveness.isDeadAfter(v, op)`, plus the union of the
   op's own `!eco.value` operands. Anything else would diverge from
   what EcoGCPrepare attaches and produce false positives.

7. **Pass registration scope.** Only register the new
   `EcoGCLivenessAudit` pass. Do not touch `EcoGCPrepare`'s registration
   (it's already wired via the pipeline call in `EcoPipeline.cpp`).

## Files touched

- `runtime/src/codegen/Passes.h` — declaration (≈5 lines)
- `runtime/src/codegen/Passes/EcoGCLivenessAudit.cpp` — new (~120 lines)
- `runtime/src/codegen/Passes/EcoGCLiveness.h` — new shared header (~40 lines)
- `runtime/src/codegen/Passes/EcoGCPrepare.cpp` — extract helpers, remove
  `#if ECO_GC_DEBUG_VERBOSE` self-check (~50 lines net delta)
- `runtime/src/codegen/Passes/EcoToLLVM.cpp` — register the new pass
  (~3 lines)
- `runtime/src/codegen/EcoPipeline.cpp` — add to pipeline under
  `#ifdef ECO_GC_DEBUG` (~3 lines)
- `runtime/src/codegen/CMakeLists.txt` — add source file to `EcoPasses`
  (~1 line)

No invariant changes. No test changes (audit is a verifier — its presence
in CI under `ECO_GC_DEBUG=1` *is* the test).
