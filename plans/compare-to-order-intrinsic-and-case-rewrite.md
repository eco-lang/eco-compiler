# Plan: `compare` → `Order` intrinsic + `case compare … of` rewrite

Two independent optimizations, sharing a runtime mechanism for cheap `Order`
values:

- **Option 1** — TypedOptimized (or post-monomorphize) rewrite that turns
  `case compare a b of LT/EQ/GT` into a nested `if` chain over `<` / `==`,
  eliminating both the `compare` call and the `Order` allocation in hot
  Dict/Set paths.
- **Option 2** — A `CompareToOrder` MLIR intrinsic for `Utils.compare` on
  unboxed `Int`/`Float`/`Char`. Returns one of three pre-allocated `Order`
  singletons (`LT`, `EQ`, `GT`), so neither the arguments nor the result is
  allocated per call.

Pipeline reminder (compiler):
`TypedCanonical → TypedOptimized → Monomorphized → MLIR`. Intrinsics
dispatch happens during MLIR codegen on `MonoCall` with concrete `MonoType`
operand types.

---

## Phase A — Runtime: pre-allocated `Order` singletons

Lowest-risk piece, independent from both options. After this phase, the
rest of the work has a stable target.

### A.1 Allocation and rooting

Files: `elm-kernel-cpp/src/core/Utils.cpp`, `Utils.hpp`,
`elm-kernel-cpp/src/core/UtilsExports.cpp`.

- Add three file‑static **encoded HPointer** slots in `Utils.cpp`:

  ```cpp
  // Encoded HPointer Elm values; registered as value roots so GC
  // never frees the underlying Custom objects. See Q1.
  static uint64_t ORDER_LT_SINGLETON;
  static uint64_t ORDER_EQ_SINGLETON;
  static uint64_t ORDER_GT_SINGLETON;
  ```

- Add `Utils::initOrderSingletons()` that calls
  `alloc::custom(ORDER_LT, {}, 0)` / `… ORDER_EQ …` / `… ORDER_GT …`
  exactly once and stores the encoded HPointer (`Export::encode(...)`)
  for each in the slots above. Reuse the existing
  `ORDER_LT`/`ORDER_EQ`/`ORDER_GT` ctor‑tag constants in
  `Utils.cpp:19-21`.

- Add `Utils::getOrderSingleton(int kind)` returning the appropriate
  encoded HPointer (or three nullary getters; see A.4).

- Add a kernel‑side root scanner registration:
  `Eco_Kernel_Order_register_gc_roots()` that calls
  `eco_gc_add_value_root(&ORDER_LT_SINGLETON)` for each of the three
  slots. `eco_gc_add_value_root` is the right primitive because the
  slots hold encoded HPointer values (filters out embedded
  constants); see `RuntimeExports.h`.

### A.2 Hook into runtime startup

- Chain `Eco_Kernel_Order_register_gc_roots()` into
  `Eco_Kernel_register_all_gc_roots`, alongside the existing
  MVar/Runtime external root scanners. That aggregator is invoked
  immediately after `Allocator::initThread()` from the AOT/JIT
  entrypoints.
- `Utils::initOrderSingletons()` must run *after*
  `Allocator::initThread()` (the allocator must be up) but *before*
  any user code can call `compare`. Same phase as
  `eco_register_all_effect_managers()`.
- Concretely: call `initOrderSingletons` from the
  `Eco_Kernel_Order_register_gc_roots` registration path so allocation
  and root registration happen as a single unit.

### A.3 Update existing `Utils::compare` to reuse the singletons (optional)

`Utils.cpp:350-356` currently allocates a fresh `Custom` per `compare`
call:
```cpp
return alloc::custom(orderCtor, {}, 0);
```
Change to `return Utils::getOrderSingleton(orderCtor);`. Independent
win for any remaining boxed-key `compare` calls (Strings, lists, tuples,
records, user comparables).

### A.4 Decide on lowering ABI for the singletons

Two options for how `Eco_*CmpOrderOp` references the singletons:

- **(A) LLVM globals**: declare `ORDER_LT_SINGLETON` etc. as external
  LLVM globals; lowering does `load i64, ptr @ORDER_LT_SINGLETON` and
  decodes via the standard HPointer encoding (`addrspacecast` /
  embedded‑constant handling identical to `eco.unbox`/regular value
  loads). Zero runtime calls on the hot path.
- **(B) Runtime helpers**: expose three `extern "C"` functions
  `Eco_Runtime_getOrderLT/EQ/GT` returning encoded HPointer (`uint64_t`).
  Lowering emits a call. Simpler to wire (no need to coordinate global
  symbol names between C++ and the lowering pass), at the cost of a
  function call.

Recommendation: **(B) initially** for simplicity, with a TODO to switch
to (A) once everything else is stable. The hot Dict path will be
covered by Option 1 (no `Order` produced at all), so this call cost is
on the cold path only.

---

## Phase B — Option 2: `CompareToOrder` intrinsic

### B.1 New Eco dialect ops

File: `runtime/src/codegen/Ops.td` (alongside `Eco_IntLtOp` at line
2069, etc.):

```tablegen
def Eco_IntCmpOrderOp   : Eco_Op<"int.cmp_order", [Pure]> {
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results   = (outs Eco_Value:$result);
  ...
}
def Eco_FloatCmpOrderOp : Eco_Op<"float.cmp_order", [Pure]> {
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results   = (outs Eco_Value:$result);
  ...
}
def Eco_CharCmpOrderOp  : Eco_Op<"char.cmp_order", [Pure]> {
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results   = (outs Eco_Value:$result);
  ...
}
```

Each is `Pure` (no side effects, deterministic). They take unboxed
primitives and return a heap pointer (`!eco.value`).

### B.2 Lowering to LLVM

File: `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` (next to
`IntLtOpLowering` at line 538, etc.).

For each op:

1. Emit `icmp slt` / `icmp sgt` on Int (signed),
   `fcmp olt` / `fcmp ogt` on Float (ordered — both predicates are
   false on any NaN, which routes NaN to `EQ` exactly matching Elm's
   `Basics.compare` semantics; see Q2),
   `icmp ult` / `icmp ugt` on Char (unsigned, mirrors existing
   `eco.char.lt`).
2. Use two `select` ops (or a small `cond_br`/phi chain) to pick the
   right singleton:
   - `if isLt then ORDER_LT else if isGt then ORDER_GT else ORDER_EQ`.
3. The result is an encoded HPointer (`!eco.value` after type
   conversion).

If we go with ABI (B): emit three `LLVM::CallOp`s and `select` between
their results. Or, more efficient: branch first, only call one. The
branch version is also slightly nicer because each helper call is then
on a cold edge.

### B.3 Compiler-side intrinsic plumbing

File: `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`.

Concrete edits, all small and local to existing patterns:

- **Type extension** (around line 27):
  ```elm
  type Intrinsic
      = ...
      | CompareToOrder { kind : CompareKind }

  type CompareKind = CompareIntKind | CompareFloatKind | CompareCharKind
  ```

- **`intrinsicResultMlirType`** (line 61): new branch returning
  `Types.ecoValue` for `CompareToOrder _`.

- **`intrinsicOperandTypes`** (line 142): per-kind operand types
  (`[I64,I64]` / `[F64,F64]` / `[ecoChar,ecoChar]`). This drives the
  existing `unboxArgsForIntrinsic` to insert `eco.unbox` for boxed
  `MInt`/`MFloat`/`MChar` arrivals — which is the mechanism that
  removes the boxing on the hot path.

- **`utilsIntrinsic`** (line 534): three new pattern arms above the
  `_ -> Nothing` default:
  ```elm
  ( "compare", [ Mono.MInt,   Mono.MInt   ] ) -> Just (CompareToOrder { kind = CompareIntKind })
  ( "compare", [ Mono.MFloat, Mono.MFloat ] ) -> Just (CompareToOrder { kind = CompareFloatKind })
  ( "compare", [ Mono.MChar,  Mono.MChar  ] ) -> Just (CompareToOrder { kind = CompareCharKind })
  ```
  Strings, lists, tuples, etc. continue to fall through to kernel
  `Elm_Kernel_Utils_compare` (AllBoxed ABI).

- **`generateIntrinsicOp`**: new branch emitting one of
  `eco.int.cmp_order` / `eco.float.cmp_order` / `eco.char.cmp_order`
  via existing `Ops.ecoBinaryOp` helper, returning `Types.ecoValue`.

No changes needed in the call-site machinery
(`Expr.generateSaturatedCall` etc.) — it already routes via
`kernelIntrinsic` → `unboxArgsForIntrinsic` → `generateIntrinsicOp`.

### B.4 Test coverage for Phase B

- Existing e2e suites `CompareInt`, `CompareFloat`, `CompareChar`,
  `CompareString` (per memory) — must still pass with identical output.
- Add an MLIR-level assertion (or grep in a regression test) that
  monomorphic `Utils.compare` on `[Int,Int]` no longer emits `eco.box`
  + `eco.call @Elm_Kernel_Utils_compare` and instead emits
  `eco.int.cmp_order`.
- GC stress: many `compare` calls on primitives that trigger GC. Heap
  inspection should show exactly three `Order` objects retained.

---

## Phase C — Option 1: Rewrite `case compare a b of LT/EQ/GT`

### C.1 Where the rewrite lives

**Placement: C-pre-mono with unconditional rewrite** (Q3 resolved).

The TypedOptimized AST (`compiler/src/Compiler/AST/TypedOptimized.elm`)
already lowers `case` to a decision tree
(`TOpt.Case Name Name (Decider _) (List (Int, Expr)) Meta`). The only
point where the case is still in `(Pattern, Expr)` form is during
`Compiler.LocalOpt.Typed.Expression.optimizeExpr`'s handling of
`Can.Case`, *before* `Compiler.LocalOpt.Typed.Case.optimize` is called
(see the `Can.Case` arm and `Case.optimize` invocation around lines
240, 645). That is the injection point.

Per Q3: rewriting is type‑safe even when the scrutinee's `compare` has
polymorphic type `comparable -> comparable -> Order`, because
`(<)`/`(==)` are polymorphic in the same `comparable` constraint. The
rewritten expression is well‑typed before monomorphization, and per‑use
monomorphic copies of e.g. `Dict.insertHelp` lower the substituted
`<`/`==` calls to primitive intrinsics for `Int`/`Float`/`Char` and to
kernel calls for Strings/lists/records/user comparables (still a win:
removes the `Order` allocation; cost is at most one extra comparison
on the equal branch).

Alternatives rejected:

- **C-post-mono** (walk `MonoCase` decision trees in
  `MonoInlineSimplify`): more complex — the case is already a
  `Decider` over ctor tags. Not needed once Q3 is resolved.
- **C-mlir** (pattern match in `Expr.generateCase`): lowest leverage,
  late‑pass, fragile.

### C.2 Pattern detection

Inside the `Can.Case scrutinee branches ->` arm of `optimizeExpr`
(`compiler/src/Compiler/LocalOpt/Typed/Expression.elm`):

1. Inspect `scrutinee` (a `Can.Expr`). Per Q4, accept **both** of:
   - `Can.Call (Can.VarTopLevel ModuleName.basics "compare") [a, b]`
   - `Can.Call (Can.VarKernel Name.utils "compare") [a, b]`
   (kernel form can occur because canonicalization/optimization may
   route `Basics.compare` references through the kernel; treat the
   two faces identically.)
2. Inspect `branches : List Can.CaseBranch`:
   - Exactly three branches, each a `Can.PCtor { home = ModuleName.basics, type_ = "Order", name ∈ {"LT","EQ","GT"}, args = [] }`.
     (Q5/Q8: confirmed zero‑arg ctors with home Basics, type Order.)
   - Permutation OK.
   - Reject if any branch uses `PAnything`, `PVar`, or `PAlias` that
     would collapse multiple ctors into one expression — too fragile
     to reorder without changing semantics.
   - Reject if the union of branches doesn't cover {LT, EQ, GT}.

If both checks pass, replace the entire `Can.Case` with:

```elm
Can.If
    [ ( Can.Binop "<" Basics "lt" forall a b, eLT )
    , ( Can.Binop "==" Basics "eq" forall a b, eEQ )
    ]
    eGT
```

…and recurse into the result via the normal `optimize` path (so any
nested optimizations apply). This piggybacks on the **existing** binop
lowering at lines 444-466 that turns `&&` / `||` into `TOpt.If`, and
on the existing intrinsic dispatch for `<` / `==`.

(Alternative: build the `TOpt.If` directly with two branches in the
`If` arity-2 form supported by `TOpt.If : List (Expr,Expr) -> Expr -> Meta -> Expr`.
Either is fine; rewriting at `Can` level keeps the recursion uniform.)

### C.3 Edge cases

- `case` scrutinee is a let-bound `Order` value: `let o = compare a b in case o of …`.
  The current rewrite only fires when the scrutinee is a *direct* call.
  Letting it through would require a small inliner; punt to a follow-up.
- `case compare a b of LT -> e1 ; _ -> e2`: wildcard collapses `EQ`+`GT`.
  Simple to handle if we want — emit
  `if a < b then e1 else e2` — but **leave for follow-up** unless it
  shows up in real hot paths.
- The scrutinee may have side effects (Debug.log, Tasks). `compare` is
  pure, so the rewrite is sound here.

### C.4 Tests for Phase C

- All existing `case`-on-`compare` test cases remain green
  (`all-elm-test-cases.md` per memory references "case on compare
  result (Order pattern match)").
- New regression: an Elm test that exercises the rewrite on `Int`,
  `Float`, `Char`, and `String` keys; verify outputs match unrewritten
  semantics.
- MLIR golden (or grep) for `Dict.insertHelp` after monomorphization:
  the `Int`-keyed copy should contain `eco.int.lt` / `eco.int.eq` and
  no `eco.call @Elm_Kernel_Utils_compare`, no `eco.box` of the keys.
- Microbenchmark: `Dict.insertHelp` allocation rate drops; bpftrace
  `eco_alloc_int` share for the Dict workload should fall.

---

## Phase ordering and dependencies

A → B → C is the safest order:

1. **Phase A** lands singletons + rooting; verifiable on its own by
   making `Utils::compare` reuse them (A.3).
2. **Phase B** adds the intrinsic; primitive `compare` calls stop
   boxing and stop allocating per call. Verifiable independently of C.
3. **Phase C** removes the `compare` call and `Order` value entirely
   on the hot Dict/Set path, riding on existing `<` / `==` lowering.

A and B together already deliver most of the user-visible win for code
that holds onto `Order` values; C is purely a Dict/Set hot-path
optimization.

---

## Files to edit (summary)

| Phase | File | Change |
| --- | --- | --- |
| A | `elm-kernel-cpp/src/core/Utils.{hpp,cpp}` | Singletons, init, getter |
| A | `elm-kernel-cpp/src/core/UtilsExports.cpp` | C-linkage getters (if (B) chosen) |
| A | runtime startup (TBD: `EffectManagerRegistry.cpp` neighbor or `__eco_init_globals`) | Call `initOrderSingletons` |
| A | (optional) `Utils.cpp:350-356` | `compare` reuses singletons |
| B | `runtime/src/codegen/Ops.td` | Three new ops |
| B | `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` | Three new lowerings |
| B | `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | `Intrinsic`, `CompareKind`, four tables, three new `utilsIntrinsic` arms |
| C | `compiler/src/Compiler/LocalOpt/Typed/Expression.elm` | New `rewriteCaseCompare` helper, hook in `Can.Case` arm |

---

## Resolved questions (was: open questions)

All eight questions raised in earlier drafts of this plan have been
answered in‑repo. The resolutions below are the design we're committing
to.

**Q1. Runtime startup and the canonical "permanent root" API. → Resolved.**

- Two startup hooks exist:
  - `__eco_init_globals` (compiler‑emitted) iterates compiler `eco.global`s
    and calls `eco_gc_add_root` on each (see
    `EcoToLLVMGlobals.cpp:546`).
  - Kernel‑side: `Allocator::initThread()` is called from the AOT/JIT
    entrypoints, immediately followed by
    `Eco_Kernel_register_all_gc_roots`, which aggregates all kernel
    "external root scanners" (MVar, Runtime, etc.). Effect managers are
    registered via `eco_register_all_effect_managers()` in the same
    early phase.
- Two root APIs in `RuntimeExports.h`:
  - `eco_gc_add_root(uint64_t* root_ptr)` — slot holds a **raw 64‑bit
    heap pointer** (used for JIT compiler globals).
  - `eco_gc_add_value_root(uint64_t* value_ptr)` — slot holds an
    **encoded HPointer Elm value** (filters out embedded constants).
- **Decision:** store `Order` singletons as static `uint64_t` slots
  holding encoded HPointers, and register them with
  `eco_gc_add_value_root(&ORDER_LT_SINGLETON)` etc. from a small new
  kernel init function `Eco_Kernel_Order_register_gc_roots()` chained
  into `Eco_Kernel_register_all_gc_roots`. This sits in the same phase
  as effect manager registration and runs after `Allocator::initThread`,
  so the allocator is up before we allocate the singletons. Also
  supersedes the earlier suggestion to use `__eco_init_globals` for
  this.

**Q2. Float NaN semantics in `Eco_FloatCmpOrderOp`. → Resolved.**

- Elm's `Basics.compare` on `Float` is defined via `<` and `>`. JS `<`
  and `>` are both false on any NaN, so `compare` falls through to `EQ`
  for any NaN involvement (NaN‑vs‑NaN, NaN‑vs‑number, both directions).
- Eco's `eco.float.lt` lowers to `llvm.fcmp olt` (and `gt` to `ogt`),
  which are also both false on NaN.
- **Decision:** lower as `lt = fcmp olt; gt = fcmp ogt; if lt then LT
  else if gt then GT else EQ`. Any NaN goes to `EQ`, matching current
  Elm semantics. No special NaN handling needed.

**Q3. Does Option 1 fire on `Dict.insertHelp`? → Resolved.**

- The rewrite is type‑safe at TypedOptimized even with polymorphic
  `comparable`: both `compare` and `(<)`/`(==)` have the same
  `comparable -> comparable -> _` shape, so substituting one for the
  other introduces no new constraints.
- Per‑use monomorphic copies of `Dict.insertHelp` are generated for
  each concrete key type. Inside the `Int` instance, the rewritten
  `<`/`==` get monomorphized to `Utils.lt[Int,Int]` /
  `Utils.equal[Int,Int]`, which already have intrinsics. Same for
  `Float`/`Char`.
- **Decision:** placement is **C‑pre‑mono** (in
  `Compiler.LocalOpt.Typed.Expression.optimizeExpr`'s `Can.Case` arm),
  rewriting **unconditionally on shape** (no element‑type gate).
  Strings/lists/etc. still benefit by losing the `Order` allocation,
  even though they retain kernel `<`/`==` calls.

**Q4. `Basics.compare` reaches the optimizer as `VarTopLevel` or
`VarKernel`? → Resolved: both can occur.**

- The JS backend already routes `Basics.lt`/`gt`/etc. through
  `JsName.fromKernel Name.utils "cmp"` for the dynamic case, so kernel
  rewrites do happen during canonicalization/optimization.
- The MLIR path tracks kernel references via `VarKernel` /
  `Names.registerKernel`.
- **Decision:** the matcher accepts both shapes:
  - `Can.Call (Can.VarTopLevel ModuleName.basics "compare") [a,b]`,
  - `Can.Call (Can.VarKernel Name.utils "compare") [a,b]`,
  and their TypedOptimized equivalents post‑optimize. Treat them
  identically.

**Q5. `LT`/`EQ`/`GT` pattern canonicalization. → Resolved.**

- `type Order = LT | EQ | GT` is declared in core `Basics`; no payloads.
- The runtime reserves only `0xFFFF`/`0xFFFE` for Dict ctors; `Order`
  uses normal zero‑based ctor tags (0=LT, 1=EQ, 2=GT, matching the
  existing `ORDER_LT`/`ORDER_EQ`/`ORDER_GT` constants in `Utils.cpp:19-21`).
- **Decision:** match `Can.PCtor { home = ModuleName.basics, type_ =
  "Order", name ∈ {"LT","EQ","GT"}, args = [] }`. No further
  canonicalization concerns.

**Q6. Is there already a DCE that kills the `Order` allocation? →
Resolved: no.**

- Existing optimizations inline Elm into Elm and can drop dead Elm
  allocations when escape analysis succeeds, but cannot see inside C++
  kernels.
- `Utils.compare` is a kernel function with AllBoxed ABI. The MLIR
  shape on the hot path is `eco.box(%a); eco.box(%b);
  eco.call @Elm_Kernel_Utils_compare`, and the allocator activity in
  the bpftrace output is entirely inside those `eco.box` calls. No
  pass today can see that the result is an `Order`.
- **Decision:** Option 1 is required to remove the source shape;
  Option 2 is required for any remaining primitive `compare` whose
  result escapes. Both phases are justified; do not skip C.

**Q7. Singletons vs equality invariants. → Resolved.**

- `Utils::eqHelp` and `Utils::cmp` over `Custom` are structural: they
  consult the ctor tag and the `header.unboxed` bitmap. They do not
  rely on non‑sharing.
- Singletons strengthen the property to "equal ⇒ pointer‑equal" for
  `Order`, which is already how embedded constants (`Nil`, `True`,
  `False`, `Nothing`, `EmptyString`, `EmptyRec`) behave.
- **Decision:** safe. No additional kernel changes needed for
  equality.

**Q8. Are LT/EQ/GT zero‑arg ctors? → Resolved: yes.**

- `type Order = LT | EQ | GT` carries no payloads; `Custom` for `Order`
  has `size = 0`, `unboxed_bitmap = 0`.
- `alloc::custom(orderCtor, {}, 0)` already produces these correctly
  (existing kernel `Utils::compare` uses exactly that call). The
  singletons just call this once per ctor at startup.
- **Decision:** no special handling.
