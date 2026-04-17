# Represent `!eco.value` as `ptr addrspace(1)` in LLVM IR

## Goal

Change the MLIR → LLVM lowering so that `!eco.value` is represented as
`ptr addrspace(1)` (GC‑managed pointer) in the MLIR LLVM dialect and in the
final LLVM IR, **without** touching:

- The 64‑bit tagged `HPointer` runtime layout (40‑bit offset, 4‑bit
  `constant` field, reserved bits).
- Any C++ runtime signatures — `eco_alloc_*`, `eco_cons`, etc. continue to
  take and return `uint64_t`.
- The stackmap / GC‑scan code, which is type‑agnostic and reads 8‑byte
  words from recorded locations.

At the IR level, every transition between compiled code and the runtime
(or between compiled code and heap‑memory `i64` slots) becomes an
explicit `ptrtoint` / `inttoptr`.

Motivation: make every GC root visible to LLVM by type (so
`RewriteStatepointsForGC` and related passes can see them), and remove
the current "i64 is opaque to LLVM" impediment.

## Non‑Goals

- Do **not** change the `HPointer` on‑heap encoding (including embedded
  constants).
- Do **not** adopt RS4GC in this plan; it only prepares for it.
- Do **not** change C++ kernel ABI or kernel declaration types (kernel
  `func.func` still lowers to LLVM funcs with `i64` where `!eco.value`
  appears, so C linkage is preserved).
- Do **not** dereference `ptr addrspace(1)` in generated code — heap
  reads/writes remain centralized in runtime helpers.

## Invariants (new / affected)

1. In the LLVM dialect and LLVM IR, every MLIR value whose source type
   was `!eco.value` has the LLVM type `!llvm.ptr<i8, 1>`
   (= `ptr addrspace(1)`).
2. External kernel / runtime C functions keep their current signatures
   (`uint64_t` for HPointers). Calls cross the boundary via explicit
   `ptrtoint` / `inttoptr`.
3. Heap storage (`eco.global`, closure capture slots, heap object
   fields) continues to use `i64` slots. All loads/stores of an
   `!eco.value` cross this boundary via `ptrtoint` / `inttoptr`.
4. Generated code never dereferences an `!eco.value`; it only hands it
   to runtime helpers or stores its bits into heap/stack slots.

Existing invariants (HEAP_008, HEAP_010, HEAP_014, HEAP_016, CGEN_012,
REP_*, XPHASE_002) remain valid but are clarified to describe the
**runtime** representation, not the LLVM IR type.

---

## Implementation Plan

### Phase A — Type converter switch (single anchor change)

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:28-56`

- Change `EcoTypeConverter::EcoTypeConverter`:
  - Replace `addConversion(eco::ValueType -> i64)` with
    `addConversion(eco::ValueType -> LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1))`.
  - Keep the `UnrealizedConversionCastOp`‑based source/target
    materializations (they already work for arbitrary types).

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h:30-31`

- Update the doc comment on `EcoTypeConverter` to reflect the new
  mapping.

After Phase A, the pass will fail verification because all existing
lowering patterns still emit `i64` where `!eco.value` is expected. The
rest of the plan fixes each pattern.

### Phase B — Pattern‑by‑pattern casts at ABI boundaries

For every lowering pattern that previously received `i64` operands for
`!eco.value` and returned `i64`, we now receive `ptr addrspace(1)` and
must return `ptr addrspace(1)`. The pattern‑internal IR (calls to
runtime C functions, memory stores, etc.) continues to use `i64`, so we
add `ptrtoint` on the way in and `inttoptr` on the way out.

#### B.0 — Audit `isIntegerTy(64)` / `i64`‑as‑HPointer usages (pre‑flip)

Repo‑wide grep and manual classification of every site outside
`StatepointConversion.cpp` that treats `i64` as "this is an HPointer".
Targets include:

- `runtime/src/jit/EcoJIT.cpp` and any JIT IR printers.
- Anything under `debug/` that pretty‑prints LLVM IR / stackmaps.
- Stackmap tooling that formats roots by type.
- Any MLIR‑level usage of `arg.getType().isInteger(64)` as a proxy for
  `!eco.value` — e.g. `EcoToLLVMErrorDebug.cpp:160` (already flagged
  in B.6), plus any similar asserts in other lowering files.

For each hit, decide: (i) irrelevant — leave alone, (ii) rewrite to
`isa<LLVM::LLVMPointerType>(t) && t.getAddressSpace() == 1`, or
(iii) introduce a single shared helper (`isEcoValueLLVMType(Type)` in
`EcoToLLVMInternal.h`) and replace. The output of this phase is a
short checklist that guides the edits in B.1 – B.7 and D.

A single helper pair will be introduced in `EcoToLLVMInternal.h`:

```cpp
// Turn an SSA !eco.value (now ptr<1>) into an i64 for passing to
// runtime helpers / storing into heap slots.
Value valueToI64(OpBuilder&, Location, Value v);

// Turn an i64 runtime result / heap load into an SSA !eco.value (ptr<1>).
Value i64ToValue(OpBuilder&, Location, Value i);
```

Both helpers are no‑ops if the input already has the expected type
(idempotent).

#### B.1 — Heap allocation / construct / project

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`
(~27 call sites to `eco_alloc_*` family, `eco_set_unboxed`, record /
custom / tuple / list store + project, etc.)

For each allocating op lowering:
- Wrap every `adaptor.get*()` operand whose source type is
  `!eco.value` with `valueToI64` before feeding it to the runtime call.
- Wrap each `LLVM::CallOp` result that represents an HPointer with
  `i64ToValue` before using it as the replacement for an
  `!eco.value` SSA result.

For project / load‑field patterns:
- Loads from i64 heap slots return `i64`; convert to `ptr<1>` with
  `i64ToValue` when the op result is `!eco.value`.

Special cases to verify inside this file:
- `emitAllocWithSafepoint` (used widely) — ensure the safepoint marker
  argument list is built from the already‑converted ptr<1> adaptor
  values (see Phase C).
- Box / Unbox ops that straddle primitive ↔ `!eco.value`: unbox now
  yields a primitive from a `ptr<1>`; box takes a primitive and yields
  `ptr<1>`. Implementation: call the runtime as today (on `i64`), add
  the `inttoptr`/`ptrtoint` wrappers.

#### B.2 — Closures

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (~1465 lines)

The bulk of cast insertions lives here because of:
- `papCreate` / `papExtend` (capture arrays).
- Direct / indirect / kernel calls.
- Argument boxing for args‑array calling convention.

**Sanity check (Decision 3):** walk every closure / environment struct
literal and every site that produces or consumes a "code pointer"
(evaluator function, kernel function). Verify the pointer type is
plain `!llvm.ptr` (AS0) and is *not* inadvertently routed through
`EcoTypeConverter::convertType`. Function pointers are not
`!eco.value`; they must remain in AS0.

Concrete edits:
- `emitRootedBoxedArgsArray` (lines 91‑151): each arg stored into the
  `i64*` alloca must be an `i64`. For `!eco.value` args, convert with
  `valueToI64` before the `LLVM::StoreOp`. Existing logic that does
  `PtrToIntOp` when it sees an `LLVMPointerType` input already covers
  this once inputs become ptr<1> — verify behaviour and extend to the
  default branch.
- `ProjectClosureOp` (from line ~157): `LLVM::LoadOp` returns `i64`;
  when the op result type is `!eco.value`, produce `ptr<1>` via
  `i64ToValue`. `IntToPtrOp` already exists for pointer results — make
  sure it matches the type‑converter output for `!eco.value`.
- `AllocateClosureOp` / `papCreate` / `papExtend` results: call
  `eco_alloc_closure` / `eco_apply_closure` as today; wrap the `i64`
  return with `i64ToValue`.
- Store of captured `!eco.value` into closure values array: wrap with
  `valueToI64` before `LLVM::StoreOp`.
- Direct Elm‑to‑Elm calls: operands and results are now `ptr<1>`
  naturally — no casts needed. Verify no stray `i64` is assumed by the
  pattern (e.g., cached type constants).
- Kernel calls (C‑linked): kernel `llvm.func` still has `i64`
  signatures (see Phase D). Cast each `!eco.value` argument with
  `valueToI64`; wrap each `i64` result with `i64ToValue`.

#### B.3 — Globals

**File:** `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp:20-100`

- `GlobalOpLowering`: keep the LLVM global type as `i64` (heap slot
  invariant).
- `LoadGlobalOpLowering`: current load returns `i64`; wrap with
  `i64ToValue` when the source op result was `!eco.value`.
- `StoreGlobalOpLowering`: `adaptor.getValue()` is now `ptr<1>` for
  `!eco.value`; wrap with `valueToI64` before `LLVM::StoreOp`.
- `createGlobalRootInitFunction` (line 544+): unchanged — it walks
  `internal i64` globals and registers their addresses; the **addresses**
  are regular `ptr` not `ptr<1>`, which matches `eco_gc_add_root`.
- `TypeTableOpLowering`: no eco.value participation; no change.

#### B.4 — Control flow, case, joinpoint, return

**File:** `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`

- Block arguments and joinpoint phis with `!eco.value` type are handled
  via the type converter automatically (`populateBranchOpInterfaceTypeConversionPattern`
  is already installed — verify it still works with pointer types).
- `CaseOp` scrutinee: boolean case uses `i1` (unchanged). String / ctor
  cases receive an `!eco.value` scrutinee; internal comparisons against
  embedded‑constant i64 values need `valueToI64` on the scrutinee
  before the `llvm.icmp` with the constant literal. Same for int / chr
  literal case arms.
- Any pattern that synthesizes an `i64` constant (`eco.constant`) to
  compare against an `!eco.value` scrutinee now must either wrap the
  scrutinee with `valueToI64` or wrap the constant with `i64ToValue`.

#### B.5 — Arith, string case, utility

**File:** `runtime/src/codegen/Passes/EcoToLLVMArith.cpp`

- Most arith ops produce / consume primitives; unaffected.
- `BoolOp` patterns that embed True/False as HPointer constants need to
  produce `ptr<1>` for `!eco.value` results. The simplest path:
  produce the `i64` constant as today (via `encodeConstant`), then wrap
  with `i64ToValue`.
- Search for other `i64`‑constant productions that represent
  `!eco.value` (e.g., embedded `Unit`, `Nil`, `EmptyString`) in
  `ConstantOpLowering` in `EcoToLLVMTypes.cpp:22-42` — same treatment.

**File:** `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp:22-42`

- `ConstantOpLowering`: currently produces `llvm.mlir.constant i64 ...`.
  Convert to `ptr<1>` with a trailing `inttoptr` when the source type
  is `!eco.value`.
- `StringLiteralOpLowering` (empty‑string path returns `i64` encoded
  EmptyString; non‑empty path returns `eco_alloc_string_literal()`
  result `i64`): both need `i64ToValue` wrapping.

#### B.6 — Error / debug / expect

**File:** `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp`

- `CrashOpLowering`: `eco_crash` takes `uint64_t`; wrap message with
  `valueToI64`.
- `ExpectOpLowering`: the pass‑through value retains `ptr<1>`; message
  wrapped with `valueToI64`.
- `DbgOpLowering` line 160: the `assert(arg.getType().isInteger(64))`
  must be relaxed — `eco.dbg` operands are now `ptr<1>` (when source
  is `!eco.value`). Wrap each arg with `valueToI64` before storing into
  the i64 values array.

#### B.7 — BF (BytesFusion) dialect

**File:** `runtime/src/codegen/Passes/BFToLLVM.cpp`

- One use of `IntToPtrOp` already exists. Audit every interaction with
  eco.value; insert casts where needed. BFOPS_031 already requires
  boundary crossing via `!eco.value`, so this is mainly mechanical.

### Phase C — Safepoints

**File:** `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:54-112`

- `SafepointOpLowering` currently receives `i64` live roots and does
  `IntToPtrOp(i64 -> ptr<1>)` before the `__eco_safepoint_marker` call.
  After Phase A, `adaptor.getLiveRoots()` returns `ptr<1>` already, so
  the loop at lines 76‑80 becomes a no‑op copy.

- Ensure `__eco_safepoint_marker` is declared (when newly declared in
  Phase C) with vararg `ptr addrspace(1)` semantics — currently it is
  declared as a plain vararg (`{}, isVarArg=true`), so typed vararg is
  not an issue.

**Supporting sites** — every allocation and call lowering currently
calls a helper `emitSafepointMarker(op, rewriter, runtime, liveRoots)`
(see `EcoToLLVMHeap.cpp`, `EcoToLLVMClosures.cpp`). Ensure that
`liveRoots` is passed through unchanged — it is already a
`ValueRange` of adapted operands, i.e., `ptr<1>` after Phase A. The
helper itself (defined where?) will need its own `IntToPtrOp` removed.

### Phase D — StatepointConversion (post‑LLVM pass)

**File:** `runtime/src/codegen/Passes/StatepointConversion.cpp`

This runs over LLVM IR after MLIR translation. Today it assumes each
`__eco_safepoint_marker` operand is `inttoptr(i64 -> ptr<1>)` and uses
`stripIntToPtr` to recover the original `i64` value.

After migration, the marker operands are already `ptr<1>` — there is
no `inttoptr` to strip. We must update the pass:

- `stripIntToPtr` (line 49‑56) becomes identity: the "original root" is
  the operand itself (a `ptr<1>` value produced by phis / calls / etc.).
- `isGCManagedType` (line 79‑81) must accept `ptr addrspace(1)` instead
  of / in addition to `i64`. Recommendation: accept `ptr addrspace(1)`
  only, since by construction there are no `i64` GC roots anymore.
- The `SafepointInfo` fields `LiveRoots` / `GCLivePtrArgs` now refer to
  the same pointer‑typed values; simplify.
- `rewriteGCRootsWithAllocas` (line 241+):
  - Alloca element type per root becomes `ptr addrspace(1)` (line 246
    `i64Ty` → `PointerType::get(ctx, 1)`).
  - Store of the initial value (line 300) becomes a `ptr<1>` store.
  - After `gc.relocate`, the `builder.CreatePtrToInt(relocate, i64Ty)`
    (line 327) becomes a plain store of the relocated `ptr<1>` —
    no ptrtoint.
  - Use‑rewriting: the `isGCLiveUse` branch (line 370‑385) previously
    inserted `inttoptr` for gc‑live bundle operands. That case becomes
    the trivial path (load already returns `ptr<1>`); the non‑gc‑live
    branch (plain use) also becomes trivial. All the
    inttoptr/ptrtoint glue disappears.
- `removeDeadGCRelocates` (line 420+): the peephole that strips
  `relocate + ptrtoint` pairs becomes a peephole that strips bare
  `relocate` calls with no uses — simplify accordingly.
- `PromoteMemToReg` works for pointer‑typed allocas just as well as
  integer‑typed ones; no change needed.

Stackmap / relocation / scanner code in `runtime/src/allocator/` is
unaffected (types at machine level are unchanged).

### Phase E — Kernel declarations kept at `i64`

**File:** `runtime/src/codegen/Passes/EcoToLLVMFunc.cpp:26-89`

- `KernelFuncOpLowering` currently hard‑codes `!eco.value -> i64` in
  kernel signatures (lines 50‑65). **Keep this behaviour** — do not
  route it through the updated type converter. This is what preserves
  C ABI compatibility with the C++ kernel implementations (which take
  `uint64_t`).
- Add an explanatory comment referencing the new plan.

Every call site to a kernel now needs explicit casts on the Elm side
(Phase B.2); the kernel’s internal implementation is untouched.

### Phase F — Documentation

1. `design_docs/theory/pass_eco_to_llvm_theory.md`:
   - Line 39: replace "convert `!eco.value` → `i64`" with "convert
     `!eco.value` → `ptr addrspace(1)`".
   - Line 91 (type mapping table): update `!eco.value` row.
   - Line 519: remove/edit the `inttoptr each operand` phrasing — it is
     now a no‑op.
   - Line 561 (post‑conditions): `!eco.value` types are converted to
     `ptr addrspace(1)`.
   - Add a short section "ABI boundary casts" describing the
     `valueToI64` / `i64ToValue` convention and where it applies.

2. `design_docs/invariants.csv`:
   - **Clarify** HEAP_008, HEAP_010, HEAP_014, HEAP_016 comments to
     note they describe the **runtime** representation (in memory /
     registers), not the LLVM IR type.
   - **Update** CGEN_012 description — the MLIR‑level type mapping is
     unchanged (`MInt→i64`, …, `others→eco.value`), but add a
     cross‑reference to the new LLVM‑lowering invariant below.
   - **Add** a new invariant (tentative `CGEN_060` / `REP_LLVM_001`):
     "At the LLVM dialect and LLVM IR level, every SSA value whose
     MLIR type is `!eco.value` has the LLVM type `ptr addrspace(1)`;
     all crossings into/out of `i64` (runtime calls, heap slots,
     closure/capture slots, globals) go through explicit `ptrtoint` /
     `inttoptr`."

3. `design_docs/theory/heap_representation_theory.md`: audit and amend
   language that equates `!eco.value` with `i64` at the IR level.

4. `design_docs/rewrite-statepoints-for-gc/eco-comparison.md`: note
   that GC pointers are now pointer‑typed in IR — this unblocks RS4GC
   adoption (but RS4GC itself is out of scope for this plan).

### Phase G — Tests

1. **Structural IR tests** (add to `test/codegen/`):
   - Compile a minimal Elm function that takes and returns a single
     `!eco.value` (e.g., identity on a list). Assert the generated
     `llvm.func` signature uses `!llvm.ptr<1>` for arguments and return.
   - Compile a function that calls a kernel (e.g., `eco_alloc_int`).
     Assert the kernel’s `llvm.func` declaration has `i64` signature
     and that the call site has `ptrtoint` / `inttoptr` casts.
   - Compile a function with a safepoint (allocation in a loop). Assert
     `__eco_safepoint_marker` call operands are `ptr addrspace(1)` and
     that no stray `inttoptr` is generated at the marker.

2. **LLVM lit test — vararg marker sanity (Decision 1):**
   Standalone `.ll` lit test with

   ```llvm
   declare void @__eco_safepoint_marker(ptr addrspace(1), ...)
   ```

   called with several `ptr addrspace(1)` arguments. Run through the
   full LLVM → object‑code pipeline and confirm clean lowering on the
   target LLVM version. Guards against an unexpected ABI / verifier
   regression on vararg calls with non‑0 address‑space pointers.

3. **Post‑LLVM statepoint tests**:
   - After `StatepointConversion`, assert `gc-live` bundle entries are
     `ptr addrspace(1)` and that reload allocas are of type
     `ptr addrspace(1)`.

4. **End‑to‑end regression**:
   - `cmake --build build --target full` must pass with no behaviour
     change. The physical `HPointer` bits stored in memory / registers
     are unchanged; all GC / heap tests should pass untouched.
   - Exercise focused areas: closure‑heavy tests, long‑lived mutable
     globals, programs that force multiple GC cycles mid‑call.

5. **Stackmap dump sanity check** (manual, one‑shot):
   - Parse the generated stackmap for a program with many live roots.
     Verify root counts and offsets match pre‑migration output byte
     for byte.

---

## Rollout Order (suggested commits)

Per Decision 9, land the core migration atomically. The sequence below
describes the **logical** stages; they may be composed into a single
squashed commit, or a few commits that are each independently
buildable.

1. **Pre‑flight (Phase B.0):** run the `isIntegerTy(64)` audit and
   produce the checklist. May land as a standalone prep commit
   (doc / notes only) before the migration series begins.
2. **Helper introduction:** add `valueToI64` / `i64ToValue` in
   `EcoToLLVMInternal.h` (no behaviour change on their own — type
   converter still emits `i64`, so they are unused).
3. **Core migration squash (A + all of B + C + E):** flip the type
   converter, fix every lowering pattern, update safepoint lowering,
   keep kernel decls at `i64`. Buildable on completion; intermediate
   states inside the squash may be broken and are not exposed on the
   main branch.
4. **Phase D (StatepointConversion):** adjust the post‑LLVM pass so
   roots are pointer‑typed throughout. Small, self‑contained commit.
5. **Phase F (docs):** theory docs + invariants.csv.
6. **Phase G (tests):** structural IR tests, vararg lit test, post‑LLVM
   tests, stackmap byte comparison. Can land in parallel with D/F if
   reviewer prefers.

---

## Resolved Decisions

All eleven open questions from the first draft have been resolved. The
decisions below are now part of the plan.

### 1. Vararg `__eco_safepoint_marker` with `ptr<1>` operands — OK

LLVM IR allows varargs with non‑0 addrspace pointers; the addrspace is
part of the IR type and does not alter the calling convention. **Action
item (added to Phase G):** add a minimal LLVM lit test that declares

```llvm
declare void @__eco_safepoint_marker(ptr addrspace(1), ...)
```

and calls it with several `ptr addrspace(1)` arguments, then runs the
module through the full LLVM → object code pipeline, confirming clean
lowering on our LLVM version.

### 2. `useBarePtrCallConv = true` — orthogonal

Bare‑ptr calling convention in MLIR's LLVM conversion is specific to
*memref lowering*; it does not special‑case arbitrary `ptr` or
`ptr addrspace(1)` arguments. Since we do not lower memref arguments
on these functions, switching `!eco.value` to `ptr<1>` is independent
of this option. No change required.

### 3. Function pointers stay in addrspace 0 — sanity‑check in Phase B.2

Only `!eco.value` operand types flow through the updated
`EcoTypeConverter`. Code‑pointer members (closure evaluator pointer,
kernel function pointers) must remain `ptr` in AS0. **Action item
(added to Phase B.2):** explicit sanity pass over
`EcoToLLVMClosures.cpp` and the closure/env struct literals — verify
every "code pointer" member is typed as plain `ptr` (AS0) and not
routed through `EcoTypeConverter::convertType`.

### 4. Bool scrutinee normalization — out of scope

By the time `EcoToLLVM` runs, boolean scrutinees for `eco.case` are
already `i1` (per `REP_SSA_001` / `CGEN_037`). The normalization
lives in the Stage‑2 control‑flow passes (`EcoControlFlowToSCF` and
case‑lowering), which do not touch the `!eco.value` type mapping.
Changing `!eco.value` to `ptr<1>` has no effect here as long as
`eco.bool` continues to map to `i1` (which it does — it is not
`!eco.value`).

### 5. Globals stay as `i64` — confirmed

`__eco_init_globals` registers each internal `i64` global with the
runtime via `eco_gc_add_root`, so globals are visible as GC roots
without being pointer‑typed in IR. Keep globals `i64`; bridge with
`ptrtoint`/`inttoptr` at load/store sites (already in Phase B.3).
Consistent with the "heap slot" model for captures and record
fields.

### 6. Heap slots stay as `i64` — confirmed

Closure captures and record / custom fields remain `i64` in memory.
Wrap every store of an `!eco.value` into such a slot with
`ptrtoint`, and every load with `inttoptr` (Phases B.1 and B.2).

### 7. `eco.constant` shape — literal `i64` then `inttoptr`

Standardize on: emit the exact `i64` HPointer constant via
`llvm.mlir.constant`, then `inttoptr` → `ptr addrspace(1)`. Do **not**
use `llvm.mlir.zero : ptr<1>` for `Nil` / `Unit`, to avoid
overloading null‑pointer semantics that RS4GC or other consumers may
treat specially. Keeps the tagged representation explicit in IR and
matches the invariants docs. (`EcoToLLVMTypes.cpp` and anywhere Bool
/ Nil / Unit / EmptyString constants are produced.)

### 8. `origFuncTypes` pre‑scan — unchanged

`EcoToLLVM.cpp:250‑252` walks all `func.func` **before** conversion and
stores pre‑conversion `FunctionType`s into `runtime.origFuncTypes`.
The ordering must be preserved (already is). No edits needed.

### 9. Atomic squash commit — confirmed

Land Phases A + (all of) B + C + E as one buildable squash. Internal
pattern‑level sub‑commits are acceptable **only** if each is
independently buildable; otherwise keep everything merged atomically.
This avoids half‑converted states where the verifier fails.
Documentation (F) and tests (G) can follow in separate commits.

### 10. RS4GC adoption — out of scope

This migration only changes `!eco.value`'s IR representation and the
ABI bridges. Enabling RS4GC, wiring a `GCStrategy`, and potentially
replacing `StatepointConversion` are follow‑up work, gated on this
change landing and stabilizing.

### 11. `isIntegerTy(64)` audit — required sweep (Phase B.0)

Any code outside `StatepointConversion.cpp` that uses `i64` (at LLVM
IR level) or `IntegerType::get(ctx, 64)` (at MLIR level) as a proxy
for "this is an HPointer / `!eco.value`" will become wrong.

**Action item (new Phase B.0, runs before flipping the type
converter):** repo‑wide grep and manual audit:

- `runtime/src/jit/EcoJIT.cpp` and any JIT IR printers.
- Anything under `debug/` that pretty‑prints LLVM IR or stackmaps.
- Stackmap tooling that picks formatting based on root type.
- Any lowering pattern outside `EcoToLLVM*` that asserts "root is
  `i64`".
- MLIR‑level usages of `arg.getType().isInteger(64)` as a proxy for
  `!eco.value` (there is at least one at
  `EcoToLLVMErrorDebug.cpp:160` that will need to relax — already
  called out in Phase B.6).

Produce a small checklist of each hit and decide per site: (i) irrelevant
— leave alone, (ii) needs to become `isa<LLVM::LLVMPointerType>(t) &&
t.getAddressSpace() == 1`, or (iii) replace with a helper like
`isEcoValueType(t)` in `EcoToLLVMInternal.h`.
