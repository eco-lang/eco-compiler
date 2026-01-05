Below is a consolidated design / implementation plan that:

- Rewrites the existing Ecoc optimisation ideas (LLVM, MLIR, Eco‑specific) as a concrete plan.
- Integrates the “missing” ideas and dialects we discussed.
- Adds new sections on optimising contiguous numeric buffers (tuples/records/arrays of floats, and how they interact with `memref` + `affine`).

I’ll clearly distinguish which parts are grounded in your docs and which are extrapolated.

---

# 0. Goals and Global Constraints

### 0.1 Runtime and Representation Constraints

From `Heap.hpp` and related docs:

- Every heap object starts with an 8‑byte `Header` (tag, GC bits, size, etc.)   .
- Logical pointers are `HPointer`:
    - 64‑bit value with `ptr : 40` (heap offset), `constant : 4` (embedded constants), `padding : 20`  .
    - Stored in IR as `i64` or equivalent.
- Many objects have a trailing `Unboxable values[]` array carrying either:
    - A heap pointer (`HPointer`) or
    - An unboxed primitive (`i64`, `f64`, `u16`)  .
- You use a tracing GC with statepoints/stackmaps; no reference counting in the current configuration   .
- Elm is immutable at the language level; GC design assumes “no writes after construction” (no write barriers needed)  .

### 0.2 MLIR / LLVM Dialect Strategy

From `eco-lowering.md`:

- Core dialects: `eco`, `func`, `cf`/`scf`, `arith`, `llvm`  .
- Optional: `memref` as a transient representation for some buffers, *not* for general Eco heap objects; for a moving GC + 40‑bit logical pointers it is “often cleaner to stick to raw pointers and the LLVM dialect”  .
- `!eco.value` is lowered to `ptr addrspace(1)` (logical heap pointer) in the LLVM dialect; Elm primitives map to `i64`, `double`, etc.  .
- `eco.safepoint` is lowered to `gc.statepoint`/`gc.relocate` and drives stackmaps for the GC   .

These constraints shape which optimisations are easy/safe and which require major representation work.

---

# 1. Base Pipeline (Recap) and Placement of Passes

From `llvm-optimization-ideas.md` and `Passes.h`:

```cpp
static int runPipeline(ModuleOp module, bool lowerToLLVM) {
    PassManager pm(module->getName());

    // ========== Stage 1: Eco → Eco ==========
    pm.addPass(eco::createRCEliminationPass());
    // TODO: pm.addPass(eco::createBoxUnboxEliminationPass());
    // TODO: pm.addPass(eco::createClosureDevirtualizationPass());
    // TODO: pm.addPass(eco::createEcoConstantFoldingPass());
    pm.addNestedPass<func::FuncOp>(createCSEPass());
    pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    if (lowerToLLVM) {
        // ========== Stage 2: High-Level Optimizations ==========
        pm.addPass(createInlinerPass());
        pm.addPass(createSCCPPass());
        pm.addNestedPass<func::FuncOp>(createCSEPass());
        pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());
        pm.addPass(createSymbolDCEPass());

        // ========== Stage 3: Eco → LLVM ==========
        pm.addPass(eco::createEcoToLLVMPass());
        pm.addPass(createConvertSCFToControlFlowPass());
        pm.addPass(createConvertFuncToLLVMPass());
        pm.addPass(createConvertControlFlowToLLVMPass());
        pm.addPass(createArithToLLVMConversionPass());

        // ========== Stage 4: LLVM Dialect Cleanup ==========
        pm.addNestedPass<LLVM::LLVMFuncOp>(createCanonicalizerPass());
    }

    if (failed(pm.run(module)))
        return 1;

    return 0;
}
```


We’ll extend this skeleton as we add new passes.

---

# 2. Eco→Eco Optimisations (High-Level IR)

These passes run on the Eco dialect before any lowering to `func`/`cf`/`scf`.

## 2.1 RCElimination (existing)

- **Status:** Implemented. Removes placeholder RC ops (`eco.incref`, `eco.decref`, etc.) that are not used with tracing GC  .
- **Goal:** Assert that no Perceus/RC ops survive into codegen.

## 2.2 Box/Unbox Elimination (planned)

- **Goal:** Remove redundant `eco.box` / `eco.unbox` pairs to:
    - Avoid heap allocation for temporary boxed numbers.
    - Reduce pointer chasing.

- **Pattern examples:**

  ```mlir
  %b = eco.box %x : i64 -> !eco.value
  %y = eco.unbox %b : !eco.value -> i64
  // => reuse %x, delete both ops
  ```

- **Implementation sketch:**

    1. For each `eco.unbox`:
        - Check if its operand is a dominating `eco.box` of the same value and type.
        - Ensure no intervening uses of the boxed value that *require* a heap object.
    2. Replace uses of `%y` by the unboxed source, erase the box and unbox.
    3. Run CSE/Canonicalizer afterwards to clean up.

- **Placement:**

  ```cpp
  pm.addPass(eco::createBoxUnboxEliminationPass());
  pm.addNestedPass<func::FuncOp>(createCSEPass());
  pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());
  ```

## 2.3 Eco Constant Folding (planned)

- **Goal:** Fold simple Eco‑level arithmetic/logical ops before lowering to `arith`/LLVM.

- **Example:**  
  From `llvm-optimization-ideas.md`:

  ```mlir
  %a = arith.constant 10 : i64
  %b = arith.constant 20 : i64
  %sum = eco.int.add %a, %b : i64

  // After:
  %sum = arith.constant 30 : i64
  ```


- **Implementation:**

    - Define pattern rewrites for `eco.int.*`/`eco.float.*` when all operands are constants.
    - Annotate Eco ops with `FoldableOpInterface` if appropriate so the Canonicalizer can fold them automatically.

- **Placement:** Same as box/unbox, in Stage 1.

## 2.4 Construct Fusion + `eco.record_update` (designed)

From `eco-construct-lowering.md`:

- **IR extension:** Introduce `eco.record_update`:

  ```mlir
  %new = eco.record_update %src [3, 4] (%new_name, %new_age)
           { tag = 0, size = 5, unboxed_bitmap = 0 }
         : (!eco.value, !eco.value, !eco.value) -> !eco.value
  ```


- **Semantics:**  
  Always allocate a new record:

    1. Allocate a new `Custom`/`Record` object with the same tag/size.
    2. Copy ctor/unboxed + all fields from `%src` via memcpy.
    3. Overwrite the fields listed in `updated_indices` with `new_values`.
    4. Optionally set a new `unboxed_bitmap`.

  Immutability is preserved because the source record is never mutated  .

- **Fusion pass (`ConstructFusionPass`):**

    - Pattern:

      ```mlir
      %f0 = eco.project %record[0]
      %f1 = eco.project %record[1]
      %f2 = eco.project %record[2]
      %new = eco.construct(%f0, %f1, %new_f2) {tag=0, size=3, ...}
      ```

      →

      ```mlir
      %new = eco.record_update %record [2] (%new_f2) {tag=0, size=3, ...}
      ```

    - Preconditions:

        - All `eco.project`s target the same `%record`.
        - Projections are identity (`project.index == position` in the construct operands)  .
        - Construct tag/size match the record’s layout.
        - Profitability heuristic: `unchanged_fields > changed_fields`.

    - After rewriting, CSE/DCE remove now‑dead projections.

- **Lowering (`RecordUpdateOpLowering`):**

  A single memcpy + K stores:

  ```cpp
  // 1. Allocate new object
  Value newObj = allocateCustom(rewriter, loc, tag, size);

  // 2. Copy ctor/unboxed + fields
  int64_t copySize = 8 + size * 8;
  emitMemcpy(rewriter, loc, newObj, source, /*srcOffset=*/8,
             /*dstOffset=*/8, copySize);

  // 3. Overwrite updated fields
  for (auto [idx, value] : llvm::zip(indices, newValues))
    emitStoreField(rewriter, loc, newObj, idx, value);

  // 4. Set unboxed bitmap if provided
  if (auto ub = op.getUnboxedBitmap())
    emitSetUnboxed(rewriter, loc, newObj, *ub);
  ```


- **Placement:** Stage 1 Eco→Eco, before any lowering to `func`/`cf`/`scf`.

## 2.5 Closure Devirtualization (planned)

- **Goal:** Replace closure applications with direct calls when the function is statically known, eliminating allocations and enabling inlining.

- **Pattern:**

  ```mlir
  %c = eco.papCreate @add(%five) {arity=2, num_captured=1}
  %r = eco.papExtend %c(%ten) {remaining_arity=1}
  ```

  →

  ```mlir
  %r = call @add(%five, %ten) : (i64, i64) -> i64
  ```


- **Implementation:**

    1. Analyze `eco.papCreate` and `eco.papExtend` to see if:
        - `function` attribute is a known `@symbol`.
        - All required arguments are present after PAP extensions.
        - The closure value does not escape (used only by `eco.papExtend`/`eco.call` with that symbol).
    2. Replace the closure construction+application with a direct `func.call`.
    3. Mark the resulting call as a candidate for inlining.

- **Placement:** Stage 1 Eco→Eco, before MLIR inliner.

## 2.6 Escape Analysis (future, advanced)

- **Goal:** Identify Eco values that do not escape a function and:
    - Promote their allocations to stack slots (in conjunction with safepoints and stackmaps).
    - Potentially allow in‑place updates of `eco.record_update` (Phase 3).

- **Design constraints:**

    - Must integrate with statepoint lowering: stack slots containing `!eco.value` must be listed in statepoints/stackmaps so GC can relocate/scan them correctly   .
    - In‑place record updates conflict with the current assumption “no write barriers”; only safe if:
        - The object does not survive a GC cycle, *or*
        - You redesign GC to handle such writes.

- **Implementation idea (extrapolated):**

    - Build a dataflow/alias analysis to classify each allocation op (e.g. `eco.allocate_ctor`, `eco.allocate_array`) as:
        - Local and non‑escaping (stack‑candidate),
        - Escaping (must remain on heap).
    - For non‑escaping objects:
        - Lower allocation to `alloca` (or to MLIR `memref` for numeric buffers; see §6).
        - Rewrite field operations to load/store from that `alloca`.

---

# 3. Eco Control Flow → SCF/CF and SCF Optimisations

From `control-flow-scf-lowering.md` and `eco-lowering.md`:

## 3.1 Joinpoint Normalization + EcoControlFlowToSCF

- **Goal:** Turn suitable `eco.case` + `eco.joinpoint` patterns into structured control flow (`scf.if`, `scf.index_switch`, `scf.while`) so SCF loop optimisations can fire.

- **Components:**

    1. `createJoinpointNormalizationPass()`:
        - Classify joinpoints as:
            - SCF‑candidate: single entry, looping structure, simple continuation.
            - CF‑only: complex, irreducible, or multi‑exit structures.
        - Annotate IR so the SCF lowering pass can decide what to transform.
    2. `createEcoControlFlowToSCFPass()`:
        - Lower pure‑return `eco.case` to `scf.if` / `scf.index_switch`.
        - Lower composite `eco.joinpoint + eco.case` patterns into `scf.while` loops (loop‑carried tuples).

    3. `createControlFlowLoweringPass()`:
        - Fallback: lower remaining Eco control flow ops directly to `cf`.

- **Guarantees:**

    - By the time `EcoToLLVMPass` runs, there are no `eco.case` / `eco.joinpoint` / `eco.jump` left; only `func` / `cf` / `scf` / `arith` and Eco heap/GC ops   .

## 3.2 SCF Loop Optimisations

From `llvm-optimization-ideas.md`:

- **Passes:**

    - `scf::createForLoopCanonicalizationPass()`
    - `scf::createForLoopPeelingPass()`
    - `scf::createForLoopSpecializationPass()`

- **Placement:**

  ```cpp
  pm.addPass(eco::createJoinpointNormalizationPass());
  pm.addPass(eco::createEcoControlFlowToSCFPass());
  pm.addPass(eco::createControlFlowLoweringPass()); // fallback CF
  pm.addNestedPass<func::FuncOp>(scf::createForLoopCanonicalizationPass());
  pm.addNestedPass<func::FuncOp>(scf::createForLoopPeelingPass());
  pm.addNestedPass<func::FuncOp>(scf::createForLoopSpecializationPass());
  ```

These passes make loops more regular and easier for the later LLVM loop optimisers and (optionally) for affine/vector passes on numeric buffers (§6).

---

# 4. MLIR‑Level Generic Passes

These run on `func`/`cf`/`scf`/`arith` (and maybe Eco) before you lower to LLVM.

- **CSE** to merge duplicate computations (especially `eco.project`)  .
- **Canonicalizer** for algebraic and CFG simplifications  .
- **SCCP** to propagate constants through branches (very powerful after monomorphization)  .
- **SymbolDCE** to remove now‑unused functions and globals  .
- **ControlFlowSink** to move expensive computations into only the branches that use them  .

These are essentially “add to pass pipeline and tune if needed”; no Eco‑specific design change required.

---

# 5. LLVM‑Level Optimisations

You already rely on LLVM’s `-O3` pipeline invoked via `makeOptimizingTransformer(3, 0, nullptr)`  . On top of that, `llvm-optimization-ideas.md` suggests emphasising:

- Tail Call Elimination (TCE), backed by Eco’s `musttail` attribute on `eco.call` and joinpoints  .
- ADCE and DSE for cleaning up pattern‑matching scaffolding and redundant field stores   .
- Loop unrolling and vectorisation where loops over arrays/numeric buffers exist  .

These are standard LLVM passes; the interesting work is making your IR amenable to them (via SCF, unboxing, and contiguous numeric buffers).

---

# 6. Additional Eco‑Level Ideas (New Section)

These were missing or only hinted at previously.

## 6.1 Systematic Unboxing / Representation Selection (new plan)

- **Goal:** Expand the use of unboxed fields beyond just `Cons`/`Tuple2`/`Tuple3` by:

    - Using the `unboxed_bitmap` attribute on `eco.construct` and `eco.record_update` to mark which fields are stored unboxed.
    - Changing layouts of `Custom`/`Record` objects based on static type information.

- **Implementation sketch (extrapolated but consistent with `Heap.hpp` + Eco docs):**

    1. **Front‑end:**
        - For each constructor/record:
            - Derive which fields have primitive types (`Int`, `Float`, `Char`, `Bool`) and are safe to unbox.
            - Emit `eco.construct` with `unboxed_bitmap` reflecting this choice   .
    2. **Eco Unboxing Pass (Eco→Eco):**
        - Inspect uses of fields; where a field is *always* consumed as an unboxed type, mark it unboxed and adjust types of projections.
        - For fields sometimes used as boxes (e.g. passed to polymorphic code), keep them boxed.
    3. **Lowering:**
        - Use the `unboxed_bitmap` to decide whether each `values[i]` slot is treated as a primitive or as an `HPointer` when implementing `eco.project` and `eco.construct` lowering   .

- **Benefit:** Enables more values to stay in registers and supports contiguous unboxed `f64` slots for numeric kernels (see §7).

## 6.2 Closure Elimination via Escape Analysis (new)

- **Goal:** Beyond closure *devirtualization*, completely remove closures that never escape their defining scope.

- **Pattern (extrapolated):**

  ```mlir
  %c = eco.papCreate @f(%capt1, %capt2) ...
  ...
  %r = eco.call %c(%x) // only use, no storage or passing
  ```

  → rewrite IR so `@f` is called directly with `%capt1`, `%capt2`, `%x` as arguments; erase the closure.

- **Requirements:**

    - A simple escape analysis that tracks closure values:
        - If a closure is only:
            - Passed to known call sites,
            - Never stored, returned, or passed to unknown code,
        - Then it can be eliminated via parameter lifting.

- **Implementation outline:**

    1. Build a call graph and track closure values per function.
    2. For closures with no escaping uses:
        - Introduce new versions of target functions with additional parameters for captures.
        - Rewrite call sites and erase closure operations.

- **Placement:** Stage 1–2, after inlining and SCCP have simplified control flow.

## 6.3 Eco/SCF LICM (new)

- **Goal:** Hoist Eco‑specific invariant computations out of loops *before* LLVM LICM, exploiting Eco semantics more directly.

- **Examples:**

    - Hoist `eco.get_tag %value` out of a loop when `%value` is loop‑invariant.
    - Hoist `eco.project %record[i]` if `%record` and `i` are loop‑invariant.

- **Pass design (extrapolated):**

    - A loop‑aware pass over `scf.while` and normalized joinpoints, using a simple dominance and alias analysis to hoist:

        - Any `eco.get_tag`, `eco.project`, `eco.box`/`eco.unbox` whose operands are invariant and whose results are only used inside the loop.

- **Placement:** After `EcoControlFlowToSCF`, before SCF loop optimizations.

## 6.4 Pattern‑Matching / ADT Specialisation (new)

- **Goal:** For certain ADTs (`Maybe Int`, `Result Int a`, etc.), generate specialised code paths with simpler representations.

- **Status:** Fully extrapolated; not covered directly in current docs.

- **Possible steps:**

    1. Detect frequently used monomorphic ADTs of primitive types.
    2. For hot functions, clone them with specialised representations (e.g. `Maybe Int` as a tagged `i64` rather than a heap object).
    3. Rewrite calls to use specialised versions where type information allows.

This is a substantial project and likely a later phase once the basic pipeline is stable.

---

# 7. Additional Dialects and Numerical Kernels (New Sections)

This is where `memref`/`affine`/`vector` become interesting.

## 7.1 Dialect Roles

- **`vector` dialect:**  
  N‑D vectors with well‑defined lowering to 1‑D LLVM vectors + aggregates  . Ideal for expressing small fixed‑size float vectors and SIMD kernels.
- **`affine` dialect:**  
  Structured loop nests and affine index expressions; great for tiling, fusion, and polyhedral optimisation of dense numeric kernels  .
- **`memref` dialect:**  
  Describes dense memory buffers (base pointer + sizes + strides); the natural buffer type for `affine` and `linalg` to work on  .
- **`bufferization` dialect (optional, future):**  
  Bridges tensor IR to `memref` buffers; useful if you ever go through `tensor` + `linalg` for numeric code  .

## 7.2 Policy for Eco

Grounded in your existing docs and the HPointer design:

- **Do not** attempt to model general Eco heap (`!eco.value` / HPointer) as `memref`. It is awkward and adds little: GC and statepoints operate on logical `i64` handles, and `memref` expects real pointers as bases   .
- **Do** use `memref`/`affine`/`vector` for **numeric buffers** that:

    - Have contiguous memory layout (e.g. `f64[]`),
    - Are not directly tracked as `!eco.value` pointers in GC roots, but rather as physical addresses derived from an HPointer during a kernel.

---

# 8. Optimising Contiguous Numeric Buffers (New Major Section)

This is the new design space you asked for.

## 8.1 Unboxed Float Tuples and Records

### 8.1.1 Representation (grounded + extrapolated)

From `Heap.hpp`:

- `Custom` and `Record` objects are:

  ```c
  typedef struct {
      Header header;
      u64 ctor;       // for Custom
      u64 unboxed;    // bitmap
      Unboxable values[]; // elements (8 bytes each)
  } CustomOrRecord;
  ```


Where `Unboxable` can hold either an `HPointer` or an unboxed primitive (`i64`, `f64`, `u16`)  .

If `unboxed_bitmap` indicates “all fields are unboxed floats”, then `values[0..N-1]` is a contiguous array of 8‑byte float slots.

### 8.1.2 MLIR‑level view (extrapolated)

Define a small Eco→std/affine helper pass:

- **Pass:** `EcoNumericTupleToMemrefPass` (conceptual)

- **Pattern:**

    - Detect functions of the form:

      ```mlir
      func.func @foo(%t: !eco.value) -> ... {
        %x = eco.project %t[0] : !eco.value -> f64
        %y = eco.project %t[1] : !eco.value -> f64
        ...
      }
      ```

      where `%t`:
        - Has static type “tuple/record of N floats” from mono.
        - Carries `unboxed_bitmap` = all ones for its fields.

- **Lowering idea:**

    - Introduce a local `memref<Nxf64>` view:

      ```mlir
      // pseudo-IR
      %base = eco.to_physical_ptr %t : !eco.value -> !llvm.ptr<f64>
      %buf = memref.reinterpret_cast %base to memref<Nxf64>
      ```

      (This requires a helper op or direct pattern rewriting into LLVM dialect; details are extrapolated.)

    - Rewrite projections to `memref.load`:

      ```mlir
      %x = memref.load %buf[%c0] : memref<Nxf64>
      %y = memref.load %buf[%c1] : memref<Nxf64>
      ```

    - If a loop over such records exists (e.g., mapping over an array of them), represent the loop body in `affine.for` + `affine.load` for these numeric fields.

- **Safety:**  
  These are *local views* used inside kernels; the global representation remains a normal Eco object with HPointer; GC still sees only the logical pointer.

## 8.2 Specialised `Array Float` Representation (extrapolated)

### 8.2.1 Runtime type

Define a specialised array object for `Array Float`:

```c
typedef struct {
    Header header;      // tag = Tag_ArrayFloat or Tag_Array with a subtype
    u32 length;
    u32 capacity;
    double values[];    // contiguous f64 buffer
} ElmArrayFloat;
```

(This type is extrapolated but consistent with your Tag design where `Tag_Array` already exists  .)

### 8.2.2 Front‑end criteria

The Elm→Eco front‑end chooses this representation only when all three hold:

1. **Element type:** monomorphized type is `Float`.
2. **API usage:** only operations that can be implemented on a `double[]` buffer are applied (no polymorphic array functions expecting generic `!eco.value`).
3. **Aliasing/ownership (optional, future):** if you intend to do in‑place updates, you must know when the array is unique (Perceus RC=1 or escape analysis).

Initially, you can skip (3) and always implement logical “copy+update” by allocating a new `ElmArrayFloat` and copying the buffer.

### 8.2.3 Eco IR and Lowering

- **New Eco ops (extrapolated):**

    - `eco.array_float_new` (len: i64) → `!eco.value` (HPointer to `ElmArrayFloat`).
    - `eco.array_float_get` (arr, idx) → `f64`.
    - `eco.array_float_set` (arr, idx, val) → `!eco.value` (returns new array).

- **Lowering to LLVM/affine/memref:**

    1. Eco→LLVM:
        - `eco.array_float_new` → call runtime `eco_alloc_array_float(length)` returning `ptr addrspace(1)` / HPointer.
        - `eco.array_float_get`/`set`:
            - Convert `!eco.value` to physical pointer: runtime helper or known layout mapping from HPointer`s 40‑bit offset.
            - Compute pointer to `values[0]` via `llvm.getelementptr`.
    2. Eco→affine/memref for kernels:
        - Recognise sequences of `array_float_get`/`set` in loops.
        - Introduce a `memref<?xf64>` view over the `values[]` buffer.
        - Rewrite the loop to `affine.for` with `affine.load`/`affine.store`.

This gives you a clean path to `affine` + `vector` for numeric arrays of floats.

## 8.3 ByteBuffer as Numeric Buffer (grounded + extrapolated)

From `BytesOps.hpp`:

- `ByteBuffer` is a contiguous array of `u8 bytes[]` with `header.size` length and `Tag_ByteBuffer`   .
- You already encode/decode floats into/from this buffer for `Bytes` operations.

**Option:** reuse `ByteBuffer` as a backing store for some float buffers (e.g., `Array (Array Float)` for matrix operations) by:

- Interpreting `bytes` as a packed sequence of `f32`/`f64`.
- Creating MLIR `memref` views (`memref<?xf32>` / `memref<?xf64>`) over `ByteBuffer.bytes` for numerical kernels.
- Maintaining API discipline so only numeric functions treat a given `ByteBuffer` as floats (no mixed views).

This is a smaller step than introducing a brand‑new `ElmArrayFloat`, but more fragile because of aliasing/typing. Probably best as a second step.

## 8.4 `List Float` → Float Buffer (highly extrapolated / future)

As discussed, turning `List Float` into a contiguous buffer is representation specialisation:

- **Conditions:**

    1. The list is known monomorphically as `List Float`.
    2. It is constructed and consumed within a region where:
        - It does not escape,
        - It is not pattern‑matched as `(::)`/`[]` outside the region.

- **Strategy:**

    - Within a numeric kernel, transform:

      ```elm
      sum : List Float -> Float
      sum list = case list of
          [] -> 0
          x :: xs -> x + sum xs
      ```

      into something that:

        1. Builds a temporary float buffer:
            - Either via a single traversal (compute length, then allocate buffer and fill).
        2. Runs a vectorised/affine kernel over that buffer.

    - Outside the kernel, keep the logical representation as `List Float` (Cons cells).

This requires non‑trivial whole‑program analysis and is best treated as a *future* specialised optimisation after the base pipeline and `Array Float` path are solid.

---

# 9. Pipeline Integration Summary

Putting it all together, a more complete pipeline (leaving some steps as future TODOs) could look like:

```cpp
pm.addPass(eco::createRCEliminationPass());

// Eco→Eco high-level normalisation
pm.addPass(eco::createConstructLoweringPass());          // eco.construct → eco.allocate_ctor + field stores
pm.addPass(eco::createBoxUnboxEliminationPass());        // NEW
pm.addPass(eco::createEcoConstantFoldingPass());         // NEW
pm.addPass(eco::createConstructFusionPass());            // record_update
pm.addPass(eco::createClosureDevirtualizationPass());    // direct calls
// TODO: eco::createUnboxingSpecializationPass();        // representation selection
// TODO: eco::createClosureEliminationPass();            // escape-based closure removal

pm.addNestedPass<func::FuncOp>(createCSEPass());
pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

if (lowerToLLVM) {
  // Eco→SCF/CF
  pm.addPass(eco::createJoinpointNormalizationPass());
  pm.addPass(eco::createEcoControlFlowToSCFPass());
  pm.addPass(eco::createControlFlowLoweringPass());
  pm.addNestedPass<func::FuncOp>(scf::createForLoopCanonicalizationPass());
  pm.addNestedPass<func::FuncOp>(scf::createForLoopPeelingPass());
  pm.addNestedPass<func::FuncOp>(scf::createForLoopSpecializationPass());
  // TODO: pm.addNestedPass<func::FuncOp>(eco::createEcoScfLicmPass());

  // High-level generic
  pm.addPass(createInlinerPass());
  pm.addPass(createSCCPPass());
  pm.addNestedPass<func::FuncOp>(createCSEPass());
  pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());
  pm.addPass(createSymbolDCEPass());

  // Optional numeric-kernel path:
  // - pattern: detect Array Float / ElmArrayFloat / ByteBuffer kernels
  // - create memref/affine/vector views and run affine passes

  // Eco→LLVM heap & calls
  pm.addPass(eco::createEcoToLLVMPass());
  pm.addPass(createConvertSCFToControlFlowPass());
  pm.addPass(createConvertFuncToLLVMPass());
  pm.addPass(createConvertControlFlowToLLVMPass());
  pm.addPass(createArithToLLVMConversionPass());

  // LLVM dialect cleanups
  pm.addNestedPass<LLVM::LLVMFuncOp>(createCanonicalizerPass());
}
```

---

## 10. Viability for Elm → Eco

- All Eco‑specific passes described above (box/unbox elimination, construct fusion, closure devirtualization, Eco constant folding, SCF lowering) are fully compatible with Elm’s semantics and your current tracing‑GC + HPointer design.
- Use of `memref`/`affine`/`vector` is **viable** and **valuable** when restricted to:
    - Unboxed numeric payloads (tuples/records of floats),
    - Specialised numeric arrays (`Array Float` / float buffers),
    - Possibly `ByteBuffer` numeric views.
- Avoid representing general Elm heaps (`!eco.value` / HPointer) as `memref`; it’s awkward and low‑yield given your GC and pointer model.
- Representation specialisation for `List Float` and in‑place updates (Perceus) are larger, future projects that would likely require a different GC or a hybrid mode.

If you’d like, the next step could be to expand just one of these new ideas (e.g. `Array Float` + `affine` path) into a detailed, file‑level design like `eco-construct-lowering.md`, with concrete op definitions and C++ skeleton code.

