Below is a more “engineering‑level” design for the small‑aggregate escape analysis work, with concrete code locations and the main changes you’d need to make. It’s written so you can come back to it when you’re ready to implement.
I’ll assume:
- We **do not** touch Strings or ByteBuffers in this optimisation. They stay `!eco.value`, and their rope/slice machinery remains runtime‑only via `StringOps` and BF dialect【】.
- We **do** reuse existing Eco ops for tuples/records/customs/lists/closures and extend their semantics to allow value‑level (unboxed aggregate) representation.
- We’re okay with relaxing `CGEN_025` (“All construct ops produce !eco.value”) and updating tests accordingly【】.
---
## A. High‑Level Flow (end‑to‑end)

1. Elm frontend + Mono:
   - No major semantic change; still emits `eco.construct.*` and `eco.project.*` for tuples, records, customs, lists, closures【】.
   - Layout metadata (RecordLayout, TupleLayout, CtorLayout, list element layout) is already computed and used for heap bitmaps/invariants【】.
2. Eco/MLIR Stage 1 (Eco → Eco):

   - **New pass** `EcoEscapeAnalysisPass`:
     - Classifies uses of small aggregates as escaping / non‑escaping.
   - **New pass** `EcoUnboxedAggSpecializePass`:
     - Creates unboxed worker variants of functions.
     - Rewrites eligible `eco.construct.*` results and call sites to use **unboxed aggregate types** instead of `!eco.value`.

   - Existing `ConstructLoweringPass`:
     - Only lowers heap‑backed `eco.construct.*` to `eco.allocate_* + stores` now【】.

3. Eco/MLIR Stage 2 & 2.5:

   - `JoinpointNormalization` + `EcoControlFlowToSCF` + `ControlFlowLowering`: see new aggregate types but otherwise unchanged【】.
   - `EcoGCPrepare`: sees fewer `!eco.value` values crossing “GCRootCarrier” ops; attaches roots only for those【】.

4. Eco → LLVM (EcoToLLVM):

   - `EcoTypeConverter` maps:
     - `!eco.value` → `ptr addrspace(1)` (unchanged)【】.
     - New aggregate types → LLVM `struct`s or flattened scalar parameter lists.
   - Heap lowering patterns only handle `eco.allocate_*`/heap‐backed constructs.

5. LLVM optimisation:

   - Inliner, `mem2reg`, SROA, InstCombine, CFG simplification.
   - RS4GC / statepoint conversion runs after scalar optimisations, as it does today【】.
---
## B. Eco dialect: types and ops
### B1. New aggregate SSA types

Add new Eco types in `runtime/src/codegen/Ops.td`:
File: `runtime/src/codegen/Ops.td`【】
Add after `Eco_ValueType`:
```tablegen
def Eco_Tuple2Type : Eco_Type<"Tuple2", "tuple2"> {
  let summary = "Unboxed logical 2-tuple";
  let description = [{
    Logical representation of a 2-tuple at the SSA level.

    This is a value-level aggregate; it may be lowered either to a heap-backed
    Tuple2 object (!eco.value) or to registers/stack-only representation.
    It does not imply a particular heap layout.
  }];
}

def Eco_Tuple3Type : Eco_Type<"Tuple3", "tuple3"> {
  let summary = "Unboxed logical 3-tuple";
}

def Eco_RecordType : Eco_Type<"Record", "record"> {
  let summary = "Unboxed logical record";
  let description = [{
    Logical representation of a record. The concrete field layout is
    determined by a layout-id attribute (e.g. from RecordLayout).
  }];
}

def Eco_CustomType : Eco_Type<"Custom", "custom"> {
  let summary = "Unboxed logical custom ADT value";
}

def Eco_ClosureEnvType : Eco_Type<"ClosureEnv", "closure_env"> {
  let summary = "Unboxed closure environment";
}
```

And constraints:
```tablegen
def Eco_Tuple2 : Type<CPred<"llvm::isa<eco::Tuple2Type>($_self)">,
                       "!eco.tuple2", "eco::Tuple2Type">;

def Eco_Tuple3 : Type<CPred<"llvm::isa<eco::Tuple3Type>($_self)">,
                       "!eco.tuple3", "eco::Tuple3Type">;

def Eco_Record : Type<CPred<"llvm::isa<eco::RecordType>($_self)">,
                      "!eco.record", "eco::RecordType">;

def Eco_Custom : Type<CPred<"llvm::isa<eco::CustomType>($_self)">,
                      "!eco.custom", "eco::CustomType">;

def Eco_ClosureEnv : Type<CPred<"llvm::isa<eco::ClosureEnvType>($_self)">,
                          "!eco.closure_env", "eco::ClosureEnvType">;
```

No string/bytes types: strings remain as `!eco.value` and are manipulated via `Eco_StringLiteralOp` / runtime `StringOps`【】【】; byte arrays via BF ops【】.
### B2. Making `eco.construct.*` polymorphic in result type

Currently all construct ops return `Eco_Value` and CGEN_025 asserts that “All construct ops produce !eco.value results”【】. We want:
- to **allow** them to return either `!eco.value` (heap) **or** an aggregate type (value‑only),
- but keep their surface syntax the same.

Example: `Eco_Tuple2ConstructOp` today:
```tablegen
def Eco_Tuple2ConstructOp : Eco_Op<"construct.tuple2", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  ...
  let arguments = (ins
    Eco_AnyValue:$a,
    Eco_AnyValue:$b,
    Variadic<Eco_Value>:$live_roots,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$a `,` $b ... `:` type($a) `,` type($b) `->` type($result)";
}
```

Change:
- `results` remains a single result, but we relax its constraint to allow **either** `!eco.value` **or** an aggregate type; the ODS can’t easily express “one of N types” here, so we:

  - keep `Eco_Value` as the concrete type, but we’ll **change it in the IR** during the unboxing pass, or
  - better: introduce a `AnyAggOrValue` type constraint, but that’s overkill.

Given ODS limitations, the pragmatic path:

- **Leave ODS as‑is** (still `Eco_Value` in the TableGen signature).
- Let the *pass* rewrite the result type to an aggregate MLIR type using C++ IR mutation APIs and update all uses. MLIR’s verifier will still accept it because the underlying C++ op class is templated on `TypeRange`, not the ODS string; but you may need to make the C++ op definition more generic if TableGen generated type checks are too strict.

If you want to avoid fighting ODS, an incremental alternative:

- Add **parallel ops** for unboxed aggregates, e.g.:
  ```tablegen
  def Eco_Tuple2MakeOp : Eco_Op<"make.tuple2", [Pure]> {
    let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b);
    let results   = (outs Eco_Tuple2:$result);
    let assemblyFormat = "$a `,` $b attr-dict `:` type($a) `,` type($b) `->` type($result)";
  }
  ```

  And similarly `make.tuple3`, `make.record`, `make.custom`.  

  For this design, I’ll assume we *do* introduce this `make.*` family, as it keeps invariants and GC passes unchanged and is much easier to stage.
So:
- Keep existing `eco.construct.*` ops **unchanged** (always heap‑backed, `!eco.value`, GCRootCarrier)【】【】.
- Introduce new **value‑level** ops:
  - `eco.make.tuple2`, `eco.make.tuple3`
  - `eco.make.record`
  - `eco.make.custom`
  - `eco.make.cons`
  - `eco.make.closure_env` (optional later)
- These new ops:
  - are **Pure**, *not* GCRootCarrier,
  - return aggregate types (`!eco.tuple2`, etc.),
  - do **not** allocate heap objects.

Example definitions in `Ops.td`:
```tablegen
def Eco_Tuple2MakeOp : Eco_Op<"make.tuple2", [Pure]> {
  let summary = "Create unboxed 2-tuple aggregate";
  let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b);
  let results = (outs Eco_Tuple2:$result);
  let assemblyFormat =
    "$a `,` $b attr-dict `:` type($a) `,` type($b) `->` type($result)";
}
```

Similar for:
- `Eco_Tuple3MakeOp : (!eco.any, !eco.any, !eco.any) -> !eco.tuple3`
- `Eco_RecordMakeOp : (Variadic<Eco_AnyValue>) -> !eco.record`
- `Eco_CustomMakeOp : (Variadic<Eco_AnyValue>) -> !eco.custom`
- `Eco_ConsMakeOp   : (Eco_AnyValue head, Eco_Value tail) -> !eco.cons` (optional, later)
- `Eco_ClosureEnvMakeOp : (Variadic<Eco_AnyValue>) -> !eco.closure_env`
### B3. Heap/value boundary ops

Add explicit conversion ops for when we must box/unbox aggregates:
- `eco.to_heap`:
  - Converts a value aggregate (`!eco.tuple2`, `!eco.record`, …) to `!eco.value` by doing heap allocation and stores.
  - Pure from the IR perspective? No, it allocates: should implement `Eco_GCRootCarrier` and be treated like other allocs.

- `eco.from_heap`:
  - Converts `!eco.value` with known layout to an aggregate `!eco.tuple2`/`!eco.record` when we know it doesn’t escape further as a heap object.  
  - For simplicity, we may skip `from_heap` in the first implementation and just rely on `make.*` at expression creation sites; `from_heap` is only needed for crossing opaque boundaries (e.g. worker/wrapper entry).

ODS sketch:
```tablegen
def Eco_ToHeapOp : Eco_Op<"to_heap",
    [DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>]> {
  let arguments = (ins Eco_AnyValue:$value); // actually Eco_Tuple2/Eco_Record/etc.
  let results   = (outs Eco_Value:$result);
  let assemblyFormat = "$value (`(` $live_roots^ `:` type($live_roots) `)`)? "
                       "attr-dict `:` type($value) `->` type($result)";
}
```

Implementation in C++ will delegate to `eco.allocate_*` patterns.
---
## C. Elm/MLIR generation changes

File: `compiler/src/Compiler/Generate/MLIR/Types.elm`【】
- Extend `MonoType -> MlirType` mapping so it **can** map tuple/record/custom types to new aggregate types (`!eco.tuple2`, `!eco.record`, etc.) when representation policy says “unboxed aggregate”.
- For initial implementation, keep policy simple:
  - Codegen continues to target heap constructs (`eco.construct.*` returning `!eco.value`) for **all** aggregates.
  - The Eco passes will later rewrite some uses to `eco.make.*` and aggregate types.

So initial Elm codegen changes can be minimal: just ensure the compiler **knows** how to print/parse the new types (for tests/debug), but you don’t have to emit them yet.

File: `compiler/src/Compiler/Generate/MLIR/Expr.elm` and `Functions.elm`【】

- No changes required in the first phase; all construction goes via existing `eco.construct.*` ops, which simplifies the first rollout.
---
## D. EcoEscapeAnalysisPass (new pass)
### D1. Declaration / registration

File: `runtime/src/codegen/Passes/Passes.h`【】
Add:
```c++
/// Escape analysis for small aggregates (tuples, records, customs, cons, closure envs).
/// Marks non-escaping values and records representation decisions for a later pass.
std::unique_ptr<mlir::Pass> createEcoEscapeAnalysisPass();

/// Specialization pass that rewrites eligible constructs/calls to use unboxed aggregate
/// types and eco.make.* ops based on EcoEscapeAnalysis results.
std::unique_ptr<mlir::Pass> createEcoUnboxedAggSpecializePass();
```

File: `runtime/src/codegen/EcoPipeline.cpp` (not shown, but referenced in EcoPipeline.h【】)
- In `buildEcoToEcoPipeline`, insert:
  ```c++
  void buildEcoToEcoPipeline(mlir::PassManager &pm) {
      using namespace eco;

      // Existing
      pm.addPass(createRCEliminationPass());
      pm.addPass(createUndefinedFunctionPass());
      pm.addPass(createCheckEcoClosureCapturesPass());
      pm.addPass(createEcoPAPSimplifyPass());

      // NEW: aggregate escape analysis and specialisation
      pm.addPass(createEcoEscapeAnalysisPass());
      pm.addPass(createEcoUnboxedAggSpecializePass());

      // Existing: construct lowering, etc.
      pm.addPass(createConstructLoweringPass());
      // ...
  }
  ```

Ensure these run **before** `ConstructLowering` and `EcoGCPrepare`【】.
### D2. Implementation

Create: `runtime/src/codegen/Passes/EcoEscapeAnalysis.cpp`
High‑level structure:
```c++
struct EcoEscapeAnalysisPass
    : public mlir::PassWrapper<EcoEscapeAnalysisPass, mlir::OperationPass<mlir::ModuleOp>> {
  void runOnOperation() override;
};
```

Algorithm (per `func.func`):
- Build a worklist of candidate values:
  - results of:
    - `eco.construct.tuple2`, `eco.construct.tuple3`【】
    - `eco.construct.record`【】
    - `eco.construct.custom`【】
    - `eco.construct.list`
    - `eco.allocate_closure` (to later target closure envs)【】
  - For now, exclude strings and arrays (`eco.allocate_string`, `eco.array.*`)【】.

For each candidate `v`:

- Traverse its SSA use‑def chain:
  - Flag as **escaping** if:
    - Used as operand to:
      - any `eco.construct.*` that itself returns `!eco.value` (heap),
      - any `eco.allocate_*` / heap op as field/root,
      - any `eco.global` / `eco.store_global`,
      - any `eco.call` whose callee is:
        - a kernel symbol with `AllBoxed` ABI,
        - or an unknown symbol (no `func.func` body in current module),
      - `eco.box` (explicit boxing),
    - Captured in `eco.papCreate` / `eco.papExtend` whose resulting closure is stored/returned/used in a way we can’t see through yet.
  - Allowed, non‑escaping uses:
    - `eco.project.*` (tuple/record/custom/list projection)【】
    - `eco.case` scrutinee/result when the entire case tree is local and the result is also a candidate for unboxing.
    - Direct `eco.call` to a **known** `func.func` we can specialise (see next pass).
    - Being the **return value** of the current function, provided:
      - the caller will also be specialised to handle unboxed, or
      - we’ll insert a boxing wrapper later.

Store escape classification on the value, e.g. via a side map:
```c++
llvm::DenseMap<mlir::Value, EscapeKind> escapeMap;
enum class EscapeKind { NonEscaping, EscapesToHeap, EscapesToUnknown };
```

You don’t need to attach attributes to the IR yet; just keep the map for the next pass.
Conservatively treat “unknown use” as escaping.
---
## E. EcoUnboxedAggSpecializePass (new pass)

Create: `runtime/src/codegen/Passes/EcoUnboxedAggSpecialize.cpp`
### E1. Responsibilities

- For each `func.func`:

  - If it has parameters or results whose *logical* types are small aggregates (tuple/record/custom/list/closure env), and all uses are classified as **NonEscaping**, create:
    - an **unboxed worker** with adjusted signature,
    - a **boxed wrapper** that matches existing ABI and calls the worker.
- Rewrite:

  - Eligible `eco.construct.*` → `eco.make.*` returning aggregate types, instead of `!eco.value`.
  - Eligible `eco.project.*` → operate over aggregate types (pure field extraction) as well as over `!eco.value`.
  - Call sites → call workers where both sides are unboxed‑aware.
### E2. Worker/wrapper construction

For each `func.func @f`:
1. Inspect its type:
   - Use `func.getFunctionType()` to see parameter/result types.
   - For each parameter/result, ask the front‑end type table (via attributes) or the MonoType metadata what its *logical* Elm type is.

2. Determine if a **worker** is worthwhile:
   - At least one parameter or result is:
     - a small tuple/record/custom/list/closure env,
     - and the escape analysis marks its value as `NonEscaping` within `f`.

3. Create the worker:

   - Clone `f` as `@f$unboxed`:
     - Add a function attribute like `@f$unboxed { eco.unboxed_worker = true }`.
   - Change its function type:
     - For aggregate parameters:
       - Either replace a single `!eco.value` param with:
         - a single aggregate param (`!eco.tuple2`, `!eco.record`, etc.), or
         - multiple primitive/`!eco.value` params matching fields.
       - For initial implementation, prefer the **aggregate type** form; it’s simpler and you can flatten further in EcoToLLVM.
     - For aggregate results:
       - Change result type from `!eco.value` to the appropriate aggregate type.

   - Rewrite the body:
     - Replace uses of the old parameter with field projections from the aggregate param via new `eco.project.*` variants or direct SSA destructuring.
     - Inside `f$unboxed`, keep:
       - `eco.make.*` for new aggregates (tuples/records/customs) that are non‑escaping,
       - `eco.construct.*` only where the result must be heap‑backed (escapes to heap/unknown).

4. Turn original `@f` into a **wrapper**:

   - Keep its original signature (boxed ABI) for compatibility with existing code and kernel call conventions【】.
   - In the body:
     - Unbox/convert incoming `!eco.value` aggregates to unboxed aggregate values:
       - By calling `eco.from_heap` (if you introduce it), or
       - For stage 1, just call `@f$unboxed` with `!eco.value` and have `f$unboxed` itself do `eco.project.*` from heap. You can defer full aggregate entry conversion.
     - Call `@f$unboxed`.
     - Box/allocate its aggregate results via `eco.to_heap` if the wrapper must return `!eco.value`.

5. Rewrite call sites:

   - For each `eco.call @f`:
     - If the caller is also in the **unboxed world**, adjust it to call `@f$unboxed` with aggregate params.
     - Otherwise keep it calling `@f` (wrapper).

This is almost identical to how you already handle primitive unboxing/boxing across closure boundaries, with `_capture_abi` and `EmitRootedBoxedArgsArray` in EcoToLLVM【】—just lifted to aggregates.
---
## F. ConstructLowering changes

File: `runtime/src/codegen/Passes/ConstructLowering.cpp` (implied by `createConstructLoweringPass()`【】)
Today this pass:
- Visits `eco.construct.*` ops (`tuple2`, `tuple3`, `record`, `custom`, `list`【】【】).
- Replaces each with:
  - an `eco.allocate*` op (`eco.allocate`, `eco.allocate_ctor`, `eco.allocate_closure`【】),
  - plus explicit field stores (probably via `eco.project.*` / `eco.heap.store` lowering patterns in EcoToLLVM).

New rule:

- **Only run on heap‑backed constructs**:
  - `eco.construct.*` whose result type is `!eco.value`.
- Leave all `eco.make.*` ops alone: they are value‑level and do **not** lower to `eco.allocate_*`.

Implementation:

- In the pattern that matches, add:
  ```c++
  if (!op.getResult().getType().isa<eco::ValueType>()) {
      // Not heap-backed; skip.
      return mlir::failure();
  }
  ```

No change to GC root handling: only `eco.construct.*` + `eco.allocate_*` with `!eco.value` results participate in `Eco_GCRootCarrier` and EcoGCPrepare【】.
---
## G. EcoToLLVM changes

File: `runtime/src/codegen/Passes/EcoToLLVMInternal.h` / `EcoToLLVMTypes.cpp`【】
### G1. Type converter

Extend `EcoTypeConverter`:
- Today it handles:
  - `!eco.value` → `ptr addrspace(1)` (GC pointer),
  - primitives → `i64`/`f64`/`i16`/`i1`【】.

Add conversions:

- `!eco.tuple2<T0,T1>`:
  - Map to LLVM struct type: `{ T0', T1' }`, where `T0'/T1'` are the converted LLVM types for T0/T1 (either scalar or `ptr<1>`).
- `!eco.record<layout-id>`:
  - Either a struct of its fields, or just lower as a flat struct of `N` `ptr/primitive` fields matching its logical shape.
- `!eco.custom`, `!eco.closure_env`:
  - Similarly, struct types representing the logical fields captured in the unboxed representation.

You do **not** need to mirror the **exact** heap layout in LLVM: this is a **value representation**, independent of the heap representation model (consistent with your REP_* invariants that keep SSA/heap separate【】).
### G2. Heap patterns vs value patterns

In `EcoToLLVMHeap.cpp`【】:
- Heap construction patterns (`eco.construct.*` lowering to `eco_alloc_*`) remain unchanged, but they only ever see heap‐backed construct ops (`!eco.value`).

In the core patterns (which lower arbitrary Eco ops to LLVM):

- Add lowering patterns for:
  - `eco.make.tuple2` / `tuple3`: create LLVM `insertvalue` chains to build the struct or, if you choose multi‑arg lowering, just pass scalars through.
  - `eco.to_heap`: expand to `eco_alloc_*` runtime calls + stores, mirroring what ConstructLowering does.

Projection:

- Extend `eco.project.*` lowering so that:
  - When the operand is `!eco.value`, you emit the existing heap field loads (via header/offset helpers).
  - When the operand is an aggregate struct, you emit LLVM `extractvalue` to pull out the relevant field.

Because the SSA type tells you whether the operand is heap‑backed or not, you can dispatch on `value.getType().isa<eco::ValueType>()` vs aggregate type.
---
## H. LLVM optimisation pipeline wiring

You already depend on LLVM’s `RewriteStatepointsForGC` and have analysed its behaviour【】. The key is to ensure:
- **Inlining**, `mem2reg`, and **SROA** run *before* RS4GC.

Where to wire:

- If you’re using MLIR’s `ExecutionEngine` with a custom `llvm::PassManager`, adjust the construction to:
  ```c++
  llvm::PassBuilder PB;
  llvm::LoopAnalysisManager LAM;
  llvm::FunctionAnalysisManager FAM;
  llvm::CGSCCAnalysisManager CGAM;
  llvm::ModuleAnalysisManager MAM;

  PB.registerModuleAnalyses(MAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  // Build -O2-style pipeline up to but not including RS4GC
  auto MPM = PB.buildPerModuleDefaultPipeline(llvm::OptimizationLevel::O2);

  // Then RS4GC
  MPM.addPass(llvm::RewriteStatepointsForGC(/*strategy=*/...));

  // Run on the module produced by MLIR → LLVM translation.
  ```

If you’re relying on MLIR’s default `createCanonicalizerPass` + `createCSEPass` etc., you may need a custom hook in `ecoc.cpp` or wherever you configure the LLVM side to ensure SROA runs.
This isn’t specific to the small aggregates work, but once you start emitting small aggregate structs, SROA becomes important to avoid unnecessary stack traffic.
---
## I. Invariants and tests

You will need to update invariants and tests that assume everything is boxed.
### I1. CGEN_* invariants

File: `design_docs/invariant-test-logic.md`【】
- `CGEN_025 - All construct ops produce !eco.value`:
  - Update to something like:
    > “All **heap‑construct** ops (`eco.construct.*`) produce `!eco.value` results. Value‑only aggregate construction must use `eco.make.*` ops and non‑`!eco.value` result types.”
- Add a new invariant for `eco.make.*` ops:
  - That their result types are one of the aggregate types and that they never participate in GC root sets.

- Keep `CGEN_026`/`027` (unboxed bitmaps) unchanged; they already rely on SSA operand types, not result types【】.
### I2. MLIR tests

Directory: `test/codegen/*.mlir`【】
- Add new tests:
  - `unboxed_tuple2.mlir`, `unboxed_record.mlir`, etc., exercising `eco.make.*` and verifying LLVM lowering produces small structs / scalar args.
  - Tests that ensure `eco.construct.*` still lower to `eco.allocate_*` and that `eco.make.*` do *not*.

- Existing tests:
  - Update `ConstructResultTypeTest` to allow:
    - `eco.construct.*` → `!eco.value`,
    - `eco.make.*` → aggregate types.
---
## J. Scope and staging (practical plan)

1. **Phase 0 (plumbing)**:
   - Add Eco aggregate types and `eco.make.*` ops.
   - Extend EcoToLLVM type converter and projection lowering to understand aggregate types.
   - No escape analysis yet; no Elm codegen changes yet.
2. **Phase 1 (manual usage for tests)**:
   - Hand‑write a couple of `.mlir` tests that use `eco.make.*` directly.
   - Verify:
     - they don’t allocate,
     - they lower to small LLVM structs,
     - LLVM SROA keeps them in registers.

3. **Phase 2 (EcoEscapeAnalysis + EcoUnboxedAggSpecialize on a small subset)**:
   - Implement passes, but initially restrict to:
     - `eco.construct.tuple2`/`tuple3`,
     - local non‑escaping values inside a single function,
     - no cross‑function worker/wrapper yet.
   - Rewrite those constructs to `eco.make.*` automatically under a `-enable-unboxed-agg` flag.

4. **Phase 3 (worker/wrapper & cross‑function unboxing)**:
   - Extend EcoUnboxedAggSpecialize to generate workers and wrappers for functions that pass small aggregates around.
   - Gradually broaden patterns (small records/customs, etc.), measuring allocation drop.

Throughout:

- **Strings & bytes stay opaque**:
  - No new Eco types for slices/ropes or byte‑array headers.
  - All string/bytes layout work continues to live in `Heap.hpp` + `StringOps` + BF dialect【】【】.

This gives you a reasonably concrete blueprint: specific ops, passes, files to touch, and a staging path that doesn’t require flipping the world at once.
