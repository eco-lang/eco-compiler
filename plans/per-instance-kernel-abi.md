# Per-Instance Kernel ABI with Primitive-Preserving Generic Apply

Move from a single MLIR symbol per logical kernel (with policy-driven all-boxed
or Elm-derived ABI) to a **per-instance** kernel ABI: each (home, name,
monomorphic argument types) tuple maps to its own C++ symbol with primitive
ABI types for `Int`/`Float`/`Char`. Then make generic apply
(`eco_apply_closure` / `lowerSegmentationUnknown`) respect REP_ABI_001 by
passing primitives through unboxed.

The end goal is to eliminate the small-int / float / char heap allocations
that today are forced by:

1. `KernelBackendAbiPolicy.AllBoxed` (e.g. `Utils.compare`, `List.cons`,
   `String.fromNumber`, `Json.wrap`, `Basics.add/sub/mul/pow`) — wrappers
   re-box primitives to `!eco.value` before calling the kernel.
2. `lowerGenericApply` and the saturated/over-saturated branch of
   `lowerSegmentationUnknown` — which today route everything through
   `emitRootedBoxedArgsArray`, allocating an `eco_alloc_int` HPointer for
   every primitive newarg.

This plan is staged so each step is independently testable.

---

## 0. Reference points in current code

- `compiler/src/Compiler/Monomorphize/KernelAbi.elm`
  - `KernelAbiMode = UseSubstitution | PreserveVars | NumberBoxed`
  - `deriveKernelAbiMode`, `numberBoxedKernels`, `concreteTypeAwareKernels`
  - `canTypeToMonoType_preserveVars`, `canTypeToMonoType_numberBoxed`
- `compiler/src/Compiler/Monomorphize/Specialize.elm:4483` — `deriveKernelAbiType`
  consumes `KernelAbiMode`; the only consumer of `NumberBoxed`.
- `compiler/src/Compiler/Generate/MLIR/Context.elm`
  - `kernelBackendAbiPolicy` (`AllBoxed | ElmDerived`) at lines 121–190.
  - `kernelDecls : Dict String (List MlirType, MlirType)` at line 239.
  - `registerKernelCall` at line 594.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
  - `generateVarKernel` at line 657 (closure path).
  - Direct kernel call at line 2583 (`Mono.MonoVarKernel _ kernelPrefix home name funcType`).
  - Uses `boxToMatchSignatureTyped` at line 2988 / 3025 to coerce SSA args.
- `compiler/src/Compiler/Generate/MLIR/Functions.elm:1012` — `generateKernelDecl`.
- `compiler/src/Compiler/Generate/MLIR/Backend.elm` — iterates `finalCtx.kernelDecls`
  to emit `func.func private` declarations.
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`
  - `lowerGenericApply` at line 1494 — boxes everything via `emitRootedBoxedArgsArray`.
  - `lowerSegmentationUnknown` at line 1398 — typed args + boxed args dual buffer.
  - `mlirTypeToParamKind` at line 1131 (`PK_Boxed=0, PK_Int=1, PK_Float=2, PK_Char=3`).
- `runtime/src/allocator/RuntimeExports.cpp:1123` — `eco_apply_closure(HPtr, uint64_t*, uint32_t)`.
- `runtime/src/allocator/RuntimeExports.h:277` — declaration.
- `elm-kernel-cpp/src/KernelExports.h` — kernel C signatures (e.g. `Utils.compare` is
  `HPtr(HPtr,HPtr)` today).
- `design_docs/invariants.csv`
  - `REP_ABI_001` (line 9) — already strengthened to forbid boxing primitives at ABI.
  - `CGEN_038` (line 291) — same-symbol same-types.
  - `CGEN_059` (line 333), `CGEN_060` (line 339) — generic apply ABI.
  - `KERN_006` (line 341) — kernelBackendAbiPolicy is the sole arbiter.

---

## 1. Phasing

The plan is split into six phases that can land as separate commits/PRs:

1. **A. Per-instance ABI plumbing in Elm** — introduce `KernelInstanceKey` and
   `KernelInstanceAbi`, switch `kernelDecls` to be keyed by symbol, update
   direct calls and closures (no behaviour change yet — symbol suffix is `""`
   for every kernel, so still one symbol per logical kernel).
2. **B. First polymorphic kernel migrated to per-instance variants**
   (`Utils.compare` → `_Int`, `_Float`, `_Char` plus a generic root). Implements
   suffix selection in `deriveKernelInstanceAbi`, adds C++ variants, removes
   `Utils → AllBoxed` for the primitive cases.
3. **C. Roll out remaining kernels** — `Utils.equal/lt/le/gt/ge/append`,
   `String.fromNumber`, `List.cons`/`take`/`drop`, `JsArray` index ops,
   `Basics.add/sub/mul/pow` (number-boxed). Each kernel: add C++ variants,
   register Elm-side suffix logic, drop from `AllBoxed`.
4. **D. Generic apply primitive preservation** — change
   `lowerGenericApply` and the saturated branch of `lowerSegmentationUnknown`
   to build a tagged `i64*` array (using `EvalParamLayout`/operand types) and
   update `eco_apply_closure` to interpret slots accordingly.
5. **E. Roll out the typed-newargs optimisation** — generate
   `__closure_wrapper_typed_*` variants, set `CLOSURE_FLAG_TYPED_NEWARGS`
   on `papCreate`/`papCreateGroup` closures with a valid layout, migrate
   `eco_closure_call_saturated` and `emitInlineClosureCall` to the typed
   convention in lockstep, then delete the runtime re-boxing branch and
   reduce `eco_apply_closure` to an all-boxed shim. First phase that
   actually reduces allocator traffic on real Elm code.
6. **E.2. `Basics.add/sub/mul/pow` per-instance variants** (added
   2026-05-07; reverses Q5). Add `_Int`/`_Float` C variants and migrate
   to suffix selection so that **indirect** uses (e.g. `List.foldl (+)
   0 xs`) also benefit from the unboxed primitive ABI. Q5 was based on
   the assumption "concrete uses are intrinsic-lowered" — true for
   *direct* application, but indirect uses still go through the boxed
   polymorphic kernel symbol via `papCreate`. After E.2 the polymorphic
   symbol is unreachable; Phase F deletes it along with `NumberBoxed`
   mode. See §6.5 for details.
7. **F. Cleanup after per-instance kernel ABI rollout** (revised
   2026-05-07 after Phase E audit; see §7 for details). Seven steps:
   (1) move `String.fromNumber` from `numberBoxedKernels` to the
   suffix-selecting set; (2) retire `CLOSURE_FLAG_TYPED_NEWARGS` (now
   provably vestigial — set in two places, read nowhere); (3) collapse
   `kernelBackendAbiPolicy` AllBoxed entries with no primitive-capable
   parameters to `ElmDerived`; (4) rename `concreteTypeAwareKernels` →
   `suffixSelectingKernels` to match its actual function; (5) delete
   the four `Basics.add/sub/mul/pow` `kernelBackendAbiPolicy` arms; (6)
   remove `NumberBoxed` mode and friends; (7) decide on (and likely
   delete) the polymorphic `Elm_Kernel_Basics_{add,sub,mul,pow}` C
   symbols. Steps 5–7 are unlocked by Phase E.2.

The `lowerSegmentationUnknown` typed-args path already uses primitives for the
under-saturated case (the `typedArgsArray` populated at line 1419), so phase D
only changes the saturated/over-saturated and `lowerGenericApply` branches.

---

## 2. Phase A — Per-instance ABI plumbing (no observable change)

### 2.1 `Compiler/Monomorphize/KernelAbi.elm`

Both the data types **and** `deriveKernelInstanceAbi` live in `KernelAbi.elm`
(decision Q1). `Context.elm` becomes a pure consumer that wraps the call and
caches results into `kernelDecls`.

```elm
type alias KernelInstanceKey =
    { home : String
    , name : String
    , argTypes : List Mono.MonoType
    , resultType : Mono.MonoType
    }

type alias KernelInstanceAbi =
    { symbolName : String
    , abiArgTypes : List MlirTypes.MlirType
    , abiResultType : MlirTypes.MlirType
    }

deriveKernelInstanceAbi : KernelInstanceKey -> KernelInstanceAbi
```

`KernelAbi.elm` already imports `Mono` and `State`; it can also import
`Compiler.Generate.MLIR.Types` since `KernelAbi.elm` does not transitively
depend on `Context.elm`. (Verify before implementation — if a cycle appears,
move the MLIR-type fields into a shared `Compiler.AST.Mlir` module.)

Phase-A behaviour: `deriveKernelInstanceAbi` returns `symbolName` with **no
suffix** (i.e. exactly today's `Elm_Kernel_<home>_<name>`) and uses
`monoTypeToAbi` for the ABI types, **but only when the policy says
`ElmDerived`**. For kernels that today hit `AllBoxed`, return all
`!eco.value`. This keeps the wire format identical.

Add an `ensurePrimitiveAbi` self-check that crashes when `MInt`/`MFloat`/`MChar`
slots are paired with a non-primitive ABI type or vice versa. This is the Elm
side of REP_ABI_001 / KERN_006.

Also add a **MONO_002 spot-check** (decision Q7): when constructing a
`KernelInstanceKey`, assert that no `argType` or `resultType` contains
`Mono.MVar _ Mono.CNumber` in any reachable position. Encountering one means
specialization failed for a reachable call site, which is a compiler bug.

### 2.2 `Compiler/Generate/MLIR/Context.elm`

Switch `kernelDecls` from

```elm
kernelDecls : Dict String (List MlirType, MlirType)
```

to

```elm
type alias KernelDeclInfo =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    }
kernelDecls : Dict String KernelDeclInfo
```

Add a new entry point:

```elm
registerKernelInstance : KernelInstanceKey -> Context -> ( KernelInstanceAbi, Context )
```

It calls `deriveKernelInstanceAbi`, looks up the symbol in `kernelDecls`, and
either crashes on mismatch (CGEN_038) or inserts/returns the existing entry.

Keep `registerKernelCall` as a thin shim during phase A so we don't have to
update every call site at once. Its body becomes:

```elm
registerKernelCall ctx symbolName argTypes returnType =
    -- legacy path: no MonoType info, treat the MLIR types as authoritative
    Dict.insert symbolName { symbolName = symbolName, abiArgTypes = argTypes, abiResultType = returnType } ctx.kernelDecls
```

`generateKernelDecl` already takes `(funcName, (argTypes, returnType))`; pivot
it to take a `KernelDeclInfo` and update the iteration in `Backend.elm` (3 sites).

### 2.3 `Compiler/Generate/MLIR/Expr.elm`

For now, leave the existing logic mostly untouched — they all funnel through
`registerKernelCall`. The only material change is that the **closure path
(`generateVarKernel`)** and the **direct call path** (line 2583) both now have
access to `KernelInstanceKey`, so we add small helpers that build the key and
delegate to `registerKernelInstance`. Behaviour is unchanged because the
suffix logic is still the trivial identity.

### 2.4 Acceptance for Phase A

- All existing tests pass with no `.mlir` diff (modulo the rename of struct
  fields in any debug printers).
- A new invariant test `KernelDeclInstanceConsistency` checks that every
  `func.func private` named `Elm_Kernel_*` has a matching entry in
  `kernelDecls` and the types agree (CGEN_038).

---

## 3. Phase B — First per-instance kernel: `Utils.compare`

### 3.1 Symbol suffix selection

In `deriveKernelInstanceAbi`, add the first real branch:

```elm
case ( key.home, key.name, key.argTypes ) of
    ( "Utils", "compare", [ Mono.MInt, Mono.MInt ] ) ->
        suffixed "_Int"

    ( "Utils", "compare", [ Mono.MFloat, Mono.MFloat ] ) ->
        suffixed "_Float"

    ( "Utils", "compare", [ Mono.MChar, Mono.MChar ] ) ->
        suffixed "_Char"

    _ ->
        rootBoxedSymbol  -- still all-boxed for non-primitive comparables
```

The non-primitive case keeps `Elm_Kernel_Utils_compare(HPtr, HPtr) -> HPtr`.

Drop `( "Utils", _ )` from `kernelBackendAbiPolicy` — instead, the policy is
now derived per instance: primitive instances are `ElmDerived` (with primitive
ABI types), the root symbol stays all-boxed.

`KernelBackendAbiPolicy` stays for the duration of the rollout (decision Q2):

- It still acts as a coarse "always boxed" switch for modules like `Debug`
  and `Platform` that are not being migrated.
- It is a guardrail: until the C++ side has the new symbol, the policy
  table forces `AllBoxed` so we cannot accidentally emit a typed call into
  a boxed kernel.
- As each kernel migrates, flip its entry from `AllBoxed` to `ElmDerived`
  in the same PR that adds the C++ variants.
- Phase F removes the policy table once everything that mattered has been
  flipped to `ElmDerived`.

### 3.2 C++ variants

In `elm-kernel-cpp/src/KernelExports.h`, add:

```cpp
HPtr     Elm_Kernel_Utils_compare       (HPtr a, HPtr b);          // existing root
HPtr     Elm_Kernel_Utils_compare_Int   (int64_t  a, int64_t  b);
HPtr     Elm_Kernel_Utils_compare_Float (double   a, double   b);
HPtr     Elm_Kernel_Utils_compare_Char  (uint16_t a, uint16_t b);
```

Result type stays `HPtr` because `Order` is an Elm custom type, not a
primitive (REP_ABI_001 only constrains primitive Elm types). Implement in
`elm-kernel-cpp/src/core/UtilsExports.cpp` by reusing the existing
`compare_int` / `compare_float` / `compare_char` helpers.

For `_Char` variants we use the **standard `uint16_t` ABI** (decision Q3),
not the `uint64_t c_raw` widening that exists in `Char_toCode` /
`String_cons`. Reasons:

- REP_ABI_001 already standardizes Char as `i16` at SSA and ABI.
- `kernelBackendAbiPolicy` already treats `Char.toLower` / `Char.toUpper` as
  ElmDerived `i16`, and they work today.
- The `c_raw` widening is a workaround for `gc.statepoint` zero-extension
  edge cases on existing Char kernels; rather than propagate that, we let
  EcoToLLVM handle any necessary `zext`/`trunc` when funnelling values
  through the generic-apply args array (Phase D).

This decision applies to **all new `_Char` variants** introduced in Phases B
and C.

### 3.3 Direct call + closure paths in Expr.elm

`generateVarKernel` (closure path) — when capturing `Utils.compare` as a
function value, build the key from the kernel's monomorphized function type:

```elm
case monoType of
    Mono.MFunction argTypes resultType ->
        let key = { home = "Utils", name = "compare", argTypes = argTypes, resultType = resultType }
        Ctx.registerKernelInstance key ctx
```

The resulting symbol name flows into the `papCreate` `function` attribute, and
the existing closure machinery (already type-aware via `_capture_abi` and
`_fast_evaluator`) handles the rest.

Direct call (line 2583) — at the call site, we know each argument's MonoType
via `Mono.typeOf`. Build the key, register, then box/unbox arguments only
where the SSA type doesn't already match `instanceAbi.abiArgTypes`. The
existing `boxToMatchSignatureTyped` does this for ABI-typed signatures, so
just reuse it: pass `instanceAbi.abiArgTypes` as the target.

### 3.4 Acceptance for Phase B

Phase B's deliverable is **per-instance machinery in place, unit-tested, no
regressions**. Runtime exercise of the new `_Int` / `_Float` / `_Char`
variants is **deferred to Phase D**: the existing `eco.{int,float,char}.cmp_order`
intrinsics intercept every `compare` call site at primitive types — including
inside the `Basics.compare` wrapper body — so the new kernel symbols are not
reachable via the current codegen path. They become load-bearing in Phase D
when generic apply stops collapsing through the intrinsic dispatcher.

- Unit tests in `compiler/tests/Compiler/Monomorphize/KernelAbiTest.elm`
  pin down `deriveKernelInstanceAbi` directly:
    - `Utils.compare` with `[MInt, MInt]` → `Elm_Kernel_Utils_compare_Int`
      with `(i64, i64) → !eco.value` ABI; analogous for `MFloat` / `MChar`.
    - `Utils.compare` with `[MString, MString]` and `[MList _, MList _]`
      falls back to the boxed root.
    - Unmigrated AllBoxed kernels (`Utils.equal`, `JsArray.appendN`) keep
      their all-`!eco.value` ABI even on primitive args.
    - User-package prefix (`Eco.Kernel.MVar.put`) produces `Eco_Kernel_*`
      symbol — regression test for the prefix bug.
- C++ implementations of the three variants linked into the kernel binary
  (`elm-kernel-cpp/src/core/UtilsExports.cpp`) and declared in
  `KernelExports.h`. Runtime exercise via Elm E2E happens in Phase D.
- Existing front-end and E2E tests continue to pass; the
  `KernelDeclInstanceConsistency` invariant test stays green.

C++ unit tests under `elm-kernel-cpp/tests/` and the
heap-allocation counter test originally listed as Phase-B acceptance are
**not part of this phase**: the former because the project's kernel testing
happens through Elm E2E, the latter because primitive `compare` already
doesn't allocate (the intrinsic produces an `Order` singleton without a
heap call), so a counter test would measure zero on `main` too.

---

## 4. Phase C — Roll out remaining kernels

The complete set of kernels and their required variants comes from the audit
in **Appendix A** (Kernel Variant Audit). The audit walks every AllBoxed
kernel from `kernelBackendAbiPolicy`, intersects with primitive-capable Elm
types, and produces an exact list of new C symbols.

**19 kernels** need monomorphic variants, totalling **41 new C symbols**.
For each kernel, the audit gives the exact new symbol names, parameter types,
and result types — the table below is a checklist; refer to Appendix A §
"Step 3 + Step 4" for the full signatures.

For each kernel, repeat the Phase B template:

1. Add the C++ variants (see Appendix A for exact signatures) to
   `elm-kernel-cpp/src/KernelExports.h` and the corresponding
   `elm-kernel-cpp/src/<module>/<...>Exports.cpp` implementation file.
2. Add suffix-selection cases in `KernelAbi.deriveKernelInstanceAbi`.
3. Drop or scope down the kernel's `AllBoxed` entry in
   `kernelBackendAbiPolicy` (remove the broad `( "Utils", _ )` and
   `( "List", _ )` and `( "JsArray", _ )` arms; replace with explicit
   per-name entries for the kernels that *stay* AllBoxed — see "Stays
   AllBoxed" below).
4. Add an MLIR-level Elm test under
   `compiler/tests/TestLogic/Generate/CodeGen/` that fixes the new symbol
   selection (one focused test per kernel; share the harness with the
   Phase-B `UtilsCompareInstanceAbi` test).
5. Add a per-variant C++ unit test in `elm-kernel-cpp/tests/`.

### Phase C rollout checklist

Group the migrations into commits/PRs by module to keep churn local. The
recommended order is roughly "fewest dependencies first":

| Order | Kernel | Variants | Implementation file |
| --- | --- | --- | --- |
| 1 | `Utils.compare` | 3 (`_Int`, `_Float`, `_Char`) | `core/UtilsExports.cpp` (Phase B) |
| 2 | `Utils.equal` | 3 | `core/UtilsExports.cpp` |
| 3 | `Utils.notEqual` | 3 | `core/UtilsExports.cpp` |
| 4 | `Utils.lt` | 3 | `core/UtilsExports.cpp` |
| 5 | `Utils.le` | 3 | `core/UtilsExports.cpp` |
| 6 | `Utils.gt` | 3 | `core/UtilsExports.cpp` |
| 7 | `Utils.ge` | 3 | `core/UtilsExports.cpp` |
| 8 | `String.fromNumber` | 2 (`_Int`, `_Float`) | `core/StringExports.cpp` |
| 9 | `List.cons` | 3 | `core/ListExports.cpp` |
| 10 | `Json.wrap` | 3 | `json/JsonExports.cpp` |
| 11 | `JsArray.singleton` | 3 (element axis) | `core/JsArrayExports.cpp` |
| 12 | `JsArray.push` | 3 (element axis) | `core/JsArrayExports.cpp` |
| 13 | `JsArray.unsafeSet` | 3 (element axis; index always `int64_t`) | `core/JsArrayExports.cpp` |
| 14 | `JsArray.unsafeGet` | 1 (`_Int` index; element stays HPtr) | `core/JsArrayExports.cpp` |
| 15 | `JsArray.slice` | 1 (`_Int` indices) | `core/JsArrayExports.cpp` |
| 16 | `JsArray.appendN` | 1 (`_Int`) | `core/JsArrayExports.cpp` |
| 17 | `JsArray.initialize` | 1 (`_Int` size+offset) | `core/JsArrayExports.cpp` |
| 18 | `JsArray.initializeFromList` | 1 (`_Int` max) | `core/JsArrayExports.cpp` |
| 19 | `JsArray.indexedMap` | 1 (`_Int` offset) | `core/JsArrayExports.cpp` |

Each row's exact signature is in **Appendix A § "Step 3 + Step 4"**. The
`elm-kernel-cpp/src/<module>/<...>Exports.cpp` paths are derived from the
existing implementation files for these kernels (see
`elm-kernel-cpp/src/core/UtilsExports.cpp`,
`elm-kernel-cpp/src/core/StringExports.cpp`,
`elm-kernel-cpp/src/core/ListExports.cpp`,
`elm-kernel-cpp/src/core/JsArrayExports.cpp`,
`elm-kernel-cpp/src/json/JsonExports.cpp`).

### Stays AllBoxed (no variants)

Per the audit, the following AllBoxed kernels do **not** need monomorphic
variants and keep their current `HPtr`-only signatures:

- `Utils.append` — `appendable` does not admit `Int`/`Float`/`Char`.
- `List.fromArray`, `List.toArray`, `List.map2`..`map5`, `List.sortBy`,
  `List.sortWith` — no primitive parameter at the kernel ABI; only
  containers and closures.
- `JsArray.empty`, `JsArray.length`, `JsArray.map`, `JsArray.foldl`,
  `JsArray.foldr` — no direct primitive parameter at the kernel ABI.
- `Basics.add/sub/mul/pow` (decision Q5) — concrete uses are intrinsic-lowered;
  the kernel symbol is reached only by genuinely polymorphic uses where
  boxing is correct.
- `Json.wrap` (root symbol) — kept as the polymorphic fallback; Phase C adds
  primitive variants alongside, the root remains.

When dropping the broad `( "Utils", _ )` / `( "List", _ )` / `( "JsArray", _ )`
arms from `kernelBackendAbiPolicy`, replace them with explicit per-name
entries for the kernels listed above so they stay AllBoxed.

### Bool equality and container wrappers

**Bool equality (decision Q8)**: do *not* add `_Bool` variants. A boxed
`(HPtr, HPtr)` symbol with a different name buys nothing over the existing
generic `Utils.equal`. If profiling shows Bool comparisons are hot, the right
fix is an `eco.bool.eq` / `icmp eq i1` intrinsic in
`Compiler/Generate/MLIR/Intrinsics.elm`, mirroring the existing Int/Float/Char
fast paths. Track that as a separate optimization rather than rolling it into
this plan.

**Container kernels (decision Q4)**: keep `concreteTypeAwareKernels` for the
duration of the rollout. After `List.cons` and `JsArray` index ops have
per-instance ABIs landed and tested, retire `concreteTypeAwareKernels` in a
follow-up — by then, element specialization is already happening through the
per-instance ABI machinery and the separate knob is redundant.

Each migration in the table above is one PR. Progress is gated by CI:
existing tests must remain green and the Phase B allocation invariant test
gets extended for each new variant.


---

## 5. Phase D — Generic apply primitive preservation

### 5.1 `lowerGenericApply` (currently boxes everything)

Today it calls `emitRootedBoxedArgsArray`, allocating an HPointer for every
primitive newarg. New design:

1. Build a typed `i64*` array (same as the typed branch of
   `lowerSegmentationUnknown`) by storing each primitive newarg directly:
   - `i64` → store as-is
   - `f64` → bitcast to `i64`, store
   - `i16` → zext to `i64`, store
   - `ptr<1>` → `argsSlotStoreValueToI64`, store
2. Compute an `EvalParamLayout` from the operand types of the new args (the
   captured slots are not relevant here — `eco_apply_closure` reads the
   closure header for those).
3. Call a new variant of the runtime helper:

   ```cpp
   HPtr eco_apply_closure_typed(HPtr closure, int64_t* args, uint32_t num_args,
                                const EvalParamLayout* args_layout);
   ```

   `args_layout` describes only the `args` array (the captured-arg layout
   comes from the closure header). Phase D adds this new entry point;
   `eco_apply_closure` (HPtr-array form) stays as a thin wrapper that
   constructs an all-boxed layout and calls the typed entry point — so
   call sites that genuinely need boxed args (e.g. dynamic dispatch into
   evaluators that haven't been migrated) keep working.

### 5.2 `lowerSegmentationUnknown`

Already builds a typed args array (line 1419). Drop the parallel boxed array
(`emitRootedBoxedArgsArray` at line 1471) once `eco_apply_segmentation_unknown`
no longer needs it. The runtime helper currently dispatches:

- under-saturated → `eco_pap_extend(typed_args, bitmap)` (already typed)
- saturated/over → `eco_apply_closure(boxed_args)` (today)

After migration:

- saturated/over → `eco_apply_closure_typed(typed_args, layout)` where layout
  is built from the bitmap and operand types.

### 5.3 `RuntimeExports.cpp`

`eco_apply_closure_typed` resolves the closure header, reads each closure
slot's `EvalParamLayout` for the captures (already available — that's how the
fast clone is invoked today), and dispatches into the evaluator with the
typed-arg `int64_t*` plus the new `args_layout`. The existing
`eco_apply_closure(HPtr, uint64_t*, uint32_t)` is kept as a compatibility
shim that builds an all-boxed layout (`PK_Boxed` in every slot) and forwards.

### 5.4 Per-evaluator capability bit (decision Q6)

Today's evaluator wrappers expect all-boxed `newargs` — that is the meaning
of `kinds.push_back(0); // PK_Boxed` at `EcoToLLVMClosures.cpp:1604` and the
current text of CGEN_059. Generic apply cannot just start handing primitives
to evaluators that expect HPtrs.

We **avoid a flag-day** and instead introduce a per-evaluator capability bit
(`accepts_typed_newargs`):

- Stored in the evaluator's metadata. Two reasonable homes:
  - As an extra bit on the `EvalParamLayout` global, *or*
  - As a bit in the closure header next to the existing fast/slow flags.

  Recommend `EvalParamLayout` since it's the structure
  `eco_apply_closure_typed` already needs to load.
- Default for legacy / not-yet-migrated evaluators: `0` (all-boxed
  newargs). `eco_apply_closure_typed` re-boxes primitives via
  `eco_alloc_int` / `eco_alloc_float` / `eco_alloc_char` before calling
  these evaluators. This shim path is exactly what `eco_apply_closure`
  does today — we are factoring it behind the layout flag.
- Migrated evaluators: bit set to `1`. The typed `int64_t*` is forwarded
  unchanged.

The MLIR codegen side flips the bit when emitting an evaluator wrapper that
has been built to consume primitives directly. Phase D adds the bit
defaulted to `0`; Phase E flips it for migrated evaluators in lockstep with
removing the boxed shim. Once every evaluator has been migrated, the bit
can be removed.

### 5.5 Invariants

- Update `CGEN_059` from "Generic-mode `eco.papExtend` boxes ALL primitive
  arguments" to "passes primitives unboxed using the new layout".
- Update `CGEN_060` similarly for `segmentation_unknown` saturated path.
- Add a test that scans the generated LLVM IR for `eco_alloc_int` calls
  immediately preceding `eco_apply_closure*` — should be zero.

---

## 5.bis Phase D Part 2 — Completing the deferred work

Phase D Part 1 landed the typed-args entry point (`eco_apply_closure_typed`)
and rewrote `lowerGenericApply` to use it. Two pieces remain before the
phase is fully delivered:

- **The runtime helper still re-boxes every primitive** before forwarding
  to `eco_apply_closure`. This is *structurally* correct (allocations equal
  the previous IR-side scheme) but does not yet reduce allocator traffic.
  The optimisation needs a per-evaluator capability bit so migrated
  evaluators can receive typed args directly.
- **`lowerSegmentationUnknown` still emits the dual-buffer scheme**
  (`emitRootedBoxedArgsArray` + the typed `i64*` buffer) and calls
  `eco_apply_segmentation_unknown(typed, num, bitmap, boxed)`. Symmetry with
  generic apply means dropping the boxed buffer and routing the
  saturated/over branch through `eco_apply_closure_typed`.

Plus: tests covering both static IR shape and the runtime helper itself.

### 5.bis.1 `accepts_typed_newargs` capability bit

The bit lives on `EvalParamLayout` (decision Q6 in §9 — chosen because the
typed-apply path already needs to load the layout). Schema change:

```cpp
// runtime/src/allocator/Heap.hpp
enum EvalLayoutFlags : unsigned char {
    EVAL_LAYOUT_FLAG_ACCEPTS_TYPED_NEWARGS = 1 << 0,
};

struct EvalParamLayout {
    unsigned char num_params;
    unsigned char flags;        // NEW — defaults to 0 in all globals emitted in Phase D Part 2
    unsigned char kinds[];      // length = num_params, byte 2 onward
};
```

**Layout discipline.** `num_params, flags, kinds[]` is a back-compatible
extension only if every consumer that reads `kinds[]` accounts for the
extra prefix byte. There are two consumers today:

1. `eco_closure_call_saturated` reads `layout->kinds[i]` to decide how to
   re-box captured slots (`RuntimeExports.cpp:1036`).
2. `eco_apply_closure_typed` (Phase D Part 1) reads `layout->kinds[i]` for
   each new arg.

Both pick up the extra byte automatically because `kinds[]` is now offset
+2 instead of +1; the change is invisible to readers that use the struct
field name. The emitter (`getOrCreateEvalLayout` in
`EcoToLLVMClosures.cpp`) is updated to insert the extra `i8 0` between
`num_params` and the kinds array, and to fold a flag bit into a uniqueness
suffix so layouts with different flags don't dedupe.

**Flag default.** All callers in Phase D Part 2 pass `flags = 0` — i.e.
"evaluator does not accept typed newargs." That preserves current behaviour
exactly. The point of adding the field now is to give a single, named
location for a future migration of `_fast_evaluator` clones (and Phase B/C
kernel variants accessed through closures) to flip the bit.

**Consumer wiring.** `eco_apply_closure_typed` reads
`args_layout->flags & EVAL_LAYOUT_FLAG_ACCEPTS_TYPED_NEWARGS`. If set, it
forwards `typed_args` directly to a new entry point (call it
`eco_apply_closure_with_typed_newargs`) instead of re-boxing. **Phase D
Part 2 does not implement that fast path** — it adds the gate, with the
fast branch left as a `// TODO: typed-newargs path` returning to the
re-boxing fallback. The actual fast path (selecting an
`evaluator_typed_newargs` slot, or providing a typed-newargs trampoline)
is deferred to a follow-up phase that migrates evaluators.

### 5.bis.2 `lowerSegmentationUnknown` migration

Today the lowering builds *both* a typed `i64*` buffer (for the
under-saturated `eco_pap_extend` path) and a boxed `uint64_t*` buffer (for
the saturated `eco_apply_closure` path). After Phase D Part 2 the boxed
buffer is gone:

```cpp
// new lowering shape (sketch):
typed_args = alloca i64, num_args
populate typed_args from origNewArgTypes (no boxing)
push GC root range over typed_args with hptr-only mask
layout = getOrCreateEvalLayout(kinds derived from origNewArgTypes, flags=0)
result = eco_apply_segmentation_unknown(closure, typed_args, num_args, layout)
restore GC range
```

Runtime side (`eco_apply_segmentation_unknown` in
`runtime/src/allocator/RuntimeExports.cpp`):

- Signature changes from
  `(HPtr, uint64_t* typed_args, uint32_t, uint64_t bitmap, uint64_t* boxed_args)`
  to
  `(HPtr, int64_t* typed_args, uint32_t, const Elm::EvalParamLayout* layout)`.
- Under-saturated branch: derive the 2-bit-per-slot bitmap on the fly from
  `layout->kinds` (a tight loop; bounded by max closure arity), then call
  `eco_pap_extend(typed_args_as_uint64, num_args, bitmap)` exactly as
  today. We do not change `eco_pap_extend`'s signature in this phase —
  only its caller — so the under-saturated shape is unchanged.
- Saturated/over branch: forward to
  `eco_apply_closure_typed(closure, typed_args, num_args, layout)`. The
  re-boxing centralisation already in `eco_apply_closure_typed` provides
  the correct semantics; no separate boxed buffer is needed.

`getOrCreateApplySegmentationUnknown` in `EcoToLLVMRuntime.cpp` updates to
the new function type (drops the `uint64_t bitmap, ptr boxed_args` pair,
adds a single `ptr layout`).

CGEN_060's text is rewritten in lockstep to mirror the new path:
> "EcoToLLVM lowers `_call_kind = segmentation_unknown` with `remaining_arity`
> absent by building a typed `i64*` args buffer (no LLVM-side boxing) plus an
> EvalParamLayout describing each slot kind, and calling
> `eco_apply_segmentation_unknown` which dispatches to either
> `eco_pap_extend` (under-saturated) or `eco_apply_closure_typed`
> (saturated/over) per the closure header."

### 5.bis.3 Static-IR enforcement test for CGEN_059 / CGEN_060

Add a single MLIR-level test fixture (one module containing both a generic
apply and a segmentation_unknown apply at primitive types) and feed it
through the EcoToLLVM pass via the existing codegen-test harness in
`/work/test/codegen/`. Assertion shape (text-grep against the dumped LLVM
IR):

- For each call to `@eco_apply_closure_typed` in the dumped IR, walk the
  preceding instructions in the same basic block and assert there is no
  `call @eco_alloc_int`, `@eco_alloc_float`, or `@eco_alloc_char` between
  the operand definitions and the call site.
- Same check around `@eco_apply_segmentation_unknown`.

Using the basic-block window (rather than a whole-function scan) keeps the
test resistant to unrelated alloc calls earlier in the function. A whole-
function scan would still work today but is more brittle.

If `/work/test/codegen/` lacks an "extract LLVM IR" harness, add the test
in `/work/test/bf-codegen/`-style with a fixture `.mlir` and an assertion
function in C++ that runs the pass pipeline and inspects the resulting
`llvm::Module`. Either home is acceptable; the choice is local to the
codegen test infrastructure.

### 5.bis.4 Runtime correctness test for `eco_apply_closure_typed`

Add a test in `/work/test/allocator/EcoApplyClosureTypedTest.cpp` modelled
on `GenericApplyBoxingTest.cpp`:

1. Build a mock evaluator that asserts `args[i]` are HPointer-encoded and
   point to ElmInt/ElmFloat/ElmChar with expected payloads.
2. Allocate a closure for the evaluator with arity 4, no captures.
3. Construct `typed_args[4]` and a stack-built `EvalParamLayout` with
   `kinds = {PK_Int, PK_Float, PK_Char, PK_Boxed}` and `flags = 0`.
4. Call `eco_apply_closure_typed(closure, typed_args, 4, &layout)` and
   verify (a) the evaluator was invoked, (b) every received arg was a
   valid HPointer with the expected payload, (c) the boxed return value
   round-trips.

Plus a regression case: pass `args_layout = nullptr` (legacy behaviour)
and verify all four slots are treated as PK_Boxed.

### 5.bis.5 Cleanup notes

These are *not* implemented in Phase D Part 2 — listed here for the plan
record:

- **Retire `eco_apply_closure` as a public API** once every direct caller
  is migrated to `eco_apply_closure_typed`. Today the typed entry point
  forwards through it; once the typed-newargs fast path lands the
  forwarding will move into a single internal helper.
- **Update CGEN_059 text** to drop the "centralised re-boxing in the
  runtime" caveat once the runtime no longer re-boxes (i.e. once the
  `accepts_typed_newargs` flag is set on every reachable evaluator).
- **Consider folding `EvalParamLayout` kinds into the closure header**
  (so the layout pointer is no longer a separate runtime argument). This
  is a closure-format change and belongs in Phase F or a successor.

### 5.bis.6 Acceptance for Phase D Part 2

- `EvalParamLayout` schema extended with `flags`; emitter and runtime
  consumers updated; all flag values are `0` in this phase.
- `lowerSegmentationUnknown` no longer emits a parallel boxed buffer;
  `eco_apply_segmentation_unknown` runtime helper updated to the new
  signature; CGEN_060 text updated.
- New runtime correctness test passes; the static-IR test passes.
- Existing E2E and allocator suites green (no regressions); allocation
  count for primitive generic-apply call sites unchanged versus Phase D
  Part 1 (the optimisation lands in a follow-up).

---

## 5.ter Phase D Part 3 — Typed-wrapper migration + tests

Three deliverables, all small in scope but bringing the optimisation
finally within reach:

1. **Static-IR enforcement test** — guard the LLVM-IR-side contract that
   neither `lowerGenericApply` nor `lowerSegmentationUnknown` introduces
   `eco_alloc_*` boxing calls before the runtime apply.
2. **32-arg cap assertion** — make the silent truncation in
   `eco_apply_segmentation_unknown`'s bitmap derivation a hard assert.
3. **Typed-wrapper migration** — generate a parallel typed-wrapper
   variant alongside `__closure_wrapper_*`, advertise the capability via
   a closure-header flag bit, and let `eco_apply_closure_typed` skip
   re-boxing for closures that have it set. Add a runtime test that
   verifies zero `eco_alloc_int` calls when the typed path fires.

Phase D Part 3 *also* corrects a design misplacement from Part 2 — the
`flags` byte was added to `EvalParamLayout` (a call-site property) but
the capability is fundamentally a property of the *closure's evaluator*
(read at runtime by dynamic dispatch). Part 3 moves it.

### 5.ter.1 Static-IR enforcement test (CGEN_059 / CGEN_060)

The codegen test harness in `/work/test/codegen/CodegenIsolatedTest.hpp`
already supports `// CHECK:` directives via `extractCheckPatterns` /
`verifyPatterns` and `ecoc --emit=llvm` for IR dumping. Two small
extensions needed:

- **Extend the harness** with a `// CHECK-NOT:` directive: a pattern
  that must *not* appear anywhere in the dumped output. Implementation
  is symmetric with `verifyPatterns` — one extra parse step in
  `extractCheckPatterns`, one extra check in `verifyPatterns`.

- **Add a fixture** `/work/test/codegen/papextend_no_realloc.mlir` that:
  - Emits a `eco.papExtend` op without `remaining_arity` (generic apply)
    *and* a second one with `_call_kind = segmentation_unknown` at
    primitive-typed newargs.
  - Has a `// RUN: %ecoc -emit=llvm %s | FileCheck %s`-style header.
  - `// CHECK:` lines for `eco_apply_closure_typed` and
    `eco_apply_segmentation_unknown` calls (ensures the test exercises
    the lowering it claims to).
  - `// CHECK-NOT:` lines for `eco_alloc_int`, `eco_alloc_float`,
    `eco_alloc_char` — globally on the function. We use a whole-function
    scan rather than a basic-block window because the `extractCheckPatterns`
    harness is line-oriented and has no notion of CFG; this is acceptable
    because the fixture is small and has no other allocations.

The test fails if a future regression reintroduces LLVM-side boxing in
either lowering.

### 5.ter.2 32-arg cap assertion

`eco_apply_segmentation_unknown` derives a 2-bit-per-slot bitmap from
`args_layout->kinds` for the under-saturated branch. The bitmap is
`uint64_t`, so it caps at 32 slots. Today the loop silently truncates
above 32, which would lose the primitive-ness of slots 32+ for closures
that have more than 32 args under-saturated.

Add `assert(num_args <= 32)` immediately before the bitmap-derivation
loop. The assert is correct because (a) Elm's max function arity is in
practice well below 32, and (b) the under-saturated guard `num_args <
remaining` already implies `num_args < max_values <= 63`, so a 33+ arg
under-saturation is theoretically reachable for very-high-arity closures
but is a real bug if it happens.

If the assert ever fires in practice, the fix is to replace `uint64_t
bitmap` with a heap- or stack-allocated `uint8_t[]` kind array — but
that is out of scope until evidence shows it's needed.

### 5.ter.3 Closure header: narrow `unboxed`, add `flags`

The current `Closure` struct packs `n_values:6 + max_values:6 +
unboxed:52` into 64 bits, fully consumed. To make room for capability
flags without enlarging the closure header, narrow `unboxed:52` to
`unboxed:50` and add `flags:2`. Trade-off: max captures with kind
tracking drops from 26 to 25; verified that no existing closure uses
that slot.

```cpp
typedef struct {
    Header header;
    u64 n_values  : 6;
    u64 max_values: 6;
    u64 unboxed   : 50;   // was 52 — caps captures at 25 instead of 26
    u64 flags     : 2;    // NEW — see CapabilityFlags below
    EvalFunction evaluator;
    Unboxable values[];
} Closure;

enum ClosureFlags : unsigned char {
    CLOSURE_FLAG_TYPED_NEWARGS = 1u << 0,
};
```

Updates required:
- `EcoOps.cpp` verifier: change `52-bit capacity` checks to `50-bit
  capacity` for the `unboxed_bitmap` attribute on `papCreate`/`papExtend`.
- `EcoToLLVMClosures.cpp` (PapCreate lowering): the packed write site
  currently encodes `n_values | (max_values << 6) | (unboxed << 12)`
  into a single i64. The packing remains unchanged (bit positions match
  the struct), but the verifier now rejects bitmaps that would clobber
  the new `flags:2` field at bits 62–63.
- The runtime `eco_alloc_closure*` helpers do not need changes — they
  initialise `unboxed = 0` (which now also zeroes `flags`).

### 5.ter.4 Move the capability flag from layout to closure

Phase D Part 2 added `EVAL_LAYOUT_FLAG_ACCEPTS_TYPED_NEWARGS` to
`EvalParamLayout::flags`. That was a misplacement — the capability is a
property of the *closure's evaluator* (discoverable at runtime by
`eco_apply_closure_typed`), not a property of the call site's args
layout. The caller cannot know what evaluator a dynamically-dispatched
closure has; only the closure itself knows.

Part 3 corrects this:
- **Remove** `EvalParamLayout::flags` and the `flags` parameter on
  `getOrCreateEvalLayout`. Revert the layout struct to
  `{ num_params, kinds[] }`.
- **Add** `CLOSURE_FLAG_TYPED_NEWARGS` to `Closure::flags` (per §5.ter.3).
- **Read** `closure->flags & CLOSURE_FLAG_TYPED_NEWARGS` inside
  `eco_apply_closure_typed`, not the layout flag.

`EvalParamLayout` retains its purpose: per-call-site description of
*which* slots are which primitive kind. The capability gate lives on
the closure where it belongs.

### 5.ter.5 Typed-wrapper variant

Today `getOrCreateWrapper` generates `__closure_wrapper_<funcName>`
with signature `ptr(ptr)` — takes a `void**` args array of HPointer-encoded
slots, internally calls `eco_resolve_hptr` + offset-load to unbox each
arg to its primitive type, then calls the target.

Part 3 adds `getOrCreateTypedWrapper` generating
`__closure_wrapper_typed_<funcName>` with the same signature `ptr(ptr)`
but a different convention: each slot in the args array holds the *raw
primitive value* per the target's parameter types (i64 → store as-is;
f64 → bitcast to i64 stored; i16 → zext to i64 stored; eco.value →
HPointer i64 as today). The wrapper then loads each slot at the
correct width and calls the target without resolve+offset-load
sequences.

Compiler-side scope (this phase): **the typed wrapper is generated but
no closure has its `CLOSURE_FLAG_TYPED_NEWARGS` set yet** — i.e.
`papCreate` always stores the legacy wrapper. The runtime infrastructure
exists and is exercised by a manual closure-construction test (§5.ter.7).
The compiler-side decision of "which closures qualify for the typed
wrapper" is deferred to a follow-up phase that needs to prove no
boxed-args caller can reach the closure (e.g. proving the closure is
not stored in any HPtr-typed location reachable from `eco_apply_closure`'s
non-typed callers).

### 5.ter.6 Runtime dispatch update

`eco_apply_closure_typed` becomes:

```cpp
HPtr eco_apply_closure_typed(HPtr closure_hptr, int64_t* typed_args,
                             uint32_t num_args,
                             const EvalParamLayout* args_layout) {
    if (num_args == 0) return eco_apply_closure(closure_hptr, nullptr, 0);

    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits));
    if (closure->flags & CLOSURE_FLAG_TYPED_NEWARGS) {
        // Typed-newargs evaluator: forward the typed buffer directly.
        // No re-boxing, no eco_alloc_* calls.
        return reinterpret_cast<HPtr(*)(int64_t*)>(closure->evaluator)(typed_args);
        // (Modulo the ptr-vs-i64 ABI shim, which is identical to today's path.)
    }

    // Legacy: re-box per args_layout->kinds, then forward to eco_apply_closure.
    // ... (existing Phase D Part 1 code unchanged)
}
```

The fast branch is `O(1)` modulo the closure resolution — no per-slot
work, no allocs.

### 5.ter.7 Runtime alloc-count test

Add a test in `/work/test/allocator/EcoApplyClosureTypedTest.cpp` that:

1. Defines a `mock_typed_evaluator` that takes raw `int64_t*` (cast from
   `void**`) and reads each slot as a primitive at the expected kind —
   the same convention `getOrCreateTypedWrapper` produces.
2. Allocates a closure manually via `eco_alloc_closure` for the typed
   evaluator.
3. Sets `closure->flags |= CLOSURE_FLAG_TYPED_NEWARGS` directly.
4. Snapshots the heap allocation counter, calls `eco_apply_closure_typed`
   with primitive typed args, snapshots again, and asserts the counter
   delta equals zero — i.e. no `eco_alloc_int/_float/_char` calls
   happened on the apply path.
5. As a sanity check, runs the *same* call without setting the flag and
   verifies the counter delta is non-zero (re-boxing happened).

This is the first end-to-end runtime evidence that the optimisation
works, even though no compiler path emits flag-set closures yet.

### 5.ter.8 Acceptance for Phase D Part 3

- `// CHECK-NOT:` works in the codegen harness; new fixture passes; if
  someone re-introduces `eco_alloc_int` near `eco_apply_closure_typed`
  the fixture fails.
- `eco_apply_segmentation_unknown` asserts on >32-arg under-saturation.
- `Closure::unboxed` narrowed to 50 bits + `flags:2` field; `EcoOps`
  verifier updated; existing closure tests still pass (verified no real
  closure uses 26 captures).
- `EvalParamLayout::flags` removed; capability moved to
  `Closure::flags` with `CLOSURE_FLAG_TYPED_NEWARGS` defined.
- `__closure_wrapper_typed_<funcName>` generator exists; new runtime
  test demonstrates it works end-to-end (zero re-boxing alloc count).
- All existing E2E and allocator tests green.

---

## 6. Phase E — Roll out the typed-newargs optimisation

Phase D Part 3 shipped the runtime infrastructure for typed-newargs
dispatch (`CLOSURE_FLAG_TYPED_NEWARGS`, the closure-side capability
gate, the runtime fast path) but no compiler path actually sets the
flag — every closure today still goes through the legacy re-boxing path
inside `eco_apply_closure_typed`. **Phase E delivers the actual
allocator-traffic reduction.**

### 6.0 Current state we're building on

- `Closure` header packs `n_values:6 | max_values:6 | unboxed:50 | flags:2`,
  with `CLOSURE_FLAG_TYPED_NEWARGS = 1u << 0` already defined in `Heap.hpp`
  (Phase D Part 3).
- `EvalParamLayout = { num_params: u8, kinds[]: u8[] }` describes per-slot
  `ParamKind` (`PK_Boxed/PK_Int/PK_Float/PK_Char`).
- `eco.papCreate` / `eco.papExtend` enforce the 25-slot bitmap cap with
  bits 62–63 reserved for `Closure::flags` (verifier in `EcoOps.cpp`).
- `eco_apply_closure_typed` exists and takes typed `int64_t*` args plus an
  `EvalParamLayout*`, but still re-boxes any non-`PK_Boxed` slot via
  `eco_alloc_int/_float/_char` and forwards to `eco_apply_closure`.
- `eco_apply_segmentation_unknown` takes the same typed buffer and layout;
  under-saturated dispatches to `eco_pap_extend`, saturated/over to
  `eco_apply_closure_typed` (Phase D Part 2).
- EcoToLLVM has helpers `wrapperLoadArgSlotToValue` and
  `wrapperReturnValueToPtr0` used by the existing `getOrCreateWrapper` to
  build evaluator wrappers over the `EvalFunction = void *(*)(void *[])`
  ABI.
- Typed closure calling (fast/generic clones) already exists per
  `typed_closure_calling_theory.md`; Phase E piggy-backs on that
  infrastructure to build the typed wrappers.

### 6.1 Goals and non-goals

**Goals for the end of Phase E:**

- For generic apply (`CallGenericApply` / `_call_kind=segmentation_unknown`),
  every Elm-visible closure created at `papCreate` / `papCreateGroup` sites
  with a valid `EvalParamLayout` (i.e. that participates in typed closure
  calling):
  - uses a wrapper that understands a typed `int64_t*` args buffer, and
  - has `closure->flags & CLOSURE_FLAG_TYPED_NEWARGS != 0`.
- `eco_apply_closure_typed`:
  - is the only "real" generic-apply entry point, and
  - does **not** allocate boxing objects for primitive args on typed-flag
    closures.
- Existing typed-mode call paths (`eco.papExtend` with `remaining_arity`)
  reach the wrapper through `eco_closure_call_saturated` and
  `emitInlineClosureCall`; both are migrated in lockstep so the wrapper
  has a single calling convention (typed) for the closures it serves.

**Non-goals (deferred to Phase F or beyond):**

- No whole-program closure-kind analysis. We work at the lowering boundary.
- No result-side typed convention. Wrappers continue to box primitive
  results via `eco_alloc_int/_float/_char` and return an HPtr. Result-side
  optimisation requires a richer evaluator ABI (multi-kind return) and is
  reasonable to defer until arg-side wins are stable.
- Closures **not** created via `papCreate`/`papCreateGroup` (e.g. those
  built by runtime helpers, hand-written kernels, test fixtures) stay
  **legacy** — no flag, no typed wrapper. They reach the runtime via the
  all-boxed shim (§6.5) and continue to work without optimisation. A grep
  for direct `eco_alloc_closure*` callers should enumerate them; either
  document the exception or migrate explicitly in a later phase.

### 6.2 Compiler — `getOrCreateTypedWrapper`

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

Add `getOrCreateTypedWrapper` parallel to `getOrCreateWrapper`. Sketch:

```cpp
mlir::LLVM::LLVMFuncOp getOrCreateTypedWrapper(EcoRuntime &rt,
                                               mlir::LLVM::LLVMFuncOp target,
                                               /* no layout — kinds are
                                                  derived from target's
                                                  function type */);
```

The wrapper derives kinds purely from `target.getFunctionType()` — its
parameter types already encode `i64 / f64 / i16 / !eco.value`. Passing a
separate `EvalParamLayout` would couple the layers unnecessarily; the
layout is a runtime apply concern, not a wrapper concern.

Body:

1. Symbol name: `__closure_wrapper_typed_<targetName>`. Register via
   `EcoRuntime::cacheSymbol` like the legacy wrapper.
2. LLVM signature: `ptr(ptr)` — same as legacy.
3. Entry block takes `%args: !llvm.ptr` (opaque pointer to `void*[]`).
4. For each parameter slot `i` of the target:
   - GEP into `%args` to load the i-th slot as `i64`.
   - Use `wrapperLoadArgSlotToValue` to coerce the `i64` into the target
     param type (HPointer / `i64` / `double` / `i16`). Crucially, **no**
     `eco_resolve_hptr` + offset-8 load — that's the legacy wrapper's
     job, replaced here by direct primitive interpretation.
5. Call the target function with the typed values.
6. If the result is a primitive, box via `eco_alloc_int/_float/_char`
   (result-side convention is unchanged — see Non-goals). If the result
   is an HPtr (`!eco.value`), use `wrapperReturnValueToPtr0` to convert
   to the `ptr` ABI.
7. Return `ptr` (LLVM) / `void*` (C).

The wrapper is typed-newargs aware: each arg slot is already a raw
primitive or HPointer, so no `eco_alloc_*` calls appear on the args side.

### 6.3 Compiler — `papCreate` / `papCreateGroup` migration

**File:** same as above.

`papCreate` and `papCreateGroup` currently:

- Allocate the closure via `eco_alloc_closure[_fast/_slow]` with a
  function pointer at the legacy wrapper.
- Pack `n_values | (max_values << 6) | (unboxed_bitmap << 12)` into the
  closure's 64-bit packed word at offset 8.

Phase-E changes (apply uniformly to **both** `papCreate` and
`papCreateGroup` — share a small helper that does "allocate closure, set
header fields, choose wrapper" so they stay in sync):

1. **Select the typed wrapper:**

   ```cpp
   auto eval = getOrCreateTypedWrapper(runtime, fastCloneOrKernelFunc);
   ```

   Apply this only when the closure has a valid layout / `_capture_abi`
   (i.e. it participates in typed closure calling). Layout-less closures
   stay on the legacy wrapper and reach the runtime via the all-boxed
   shim — they remain correct, they just don't get optimised.

2. **Set the typed-newargs flag in the packed word.** Define a named
   mask in the C++ side (mirroring the bit position of `flags:0` in the
   bitfield):

   ```cpp
   // In EcoToLLVMInternal.h or a new closure-layout header:
   constexpr uint64_t ClosureFlagTypedNewargsMask = 1ULL << 62;
   // Sanity: bit 62 corresponds to flags bit 0 under our LSB-first
   // bitfield ABI. Verified by static_assert in Heap.hpp (§6.7).
   ```

   In the lowering, OR it into `packed` before storing:

   ```cpp
   auto flagBit = builder.create<LLVM::ConstantOp>(
       loc, i64Ty, builder.getI64IntegerAttr(ClosureFlagTypedNewargsMask));
   auto packedWithFlag = builder.create<LLVM::OrOp>(loc, packed, flagBit);
   store packedWithFlag at [closure + ClosurePackedOffset];
   ```

3. **Scope of rollout — which closures?**

   Set the flag for every `papCreate` / `papCreateGroup` closure that has
   a valid `EvalParamLayout`. There is no need to subdivide further:

   - Closures reachable via generic apply use the runtime's typed fast
     path (§6.4).
   - Closures reachable via typed-mode saturated apply reach the same
     wrapper through `eco_closure_call_saturated` /
     `emitInlineClosureCall`, which we migrate in lockstep (§6.5) so
     they pass typed args.
   - Closures only ever called via direct fast-clone paths
     (`emitFastClosureCall`) bypass the wrapper entirely; the flag is
     harmless on them.

   Layout-less closures stay unflagged. So do non-`papCreate*` closures
   built directly via `eco_alloc_closure*`.

### 6.4 Runtime — `eco_apply_closure_typed` honours the flag

**File:** `runtime/src/allocator/RuntimeExports.cpp`.

Two-step migration so each landing is independently testable.

**Step 1 (behaviour-preserving):** add a fast branch keyed on
`closure->flags & CLOSURE_FLAG_TYPED_NEWARGS`, but keep the legacy
re-boxing path for unflagged closures. This step lands *before* §6.3
flips any closures, so behaviour is unchanged at this point.

```cpp
HPtr eco_apply_closure_typed(HPtr closureBits, int64_t* typed_args,
                             uint32_t num_args,
                             const Elm::EvalParamLayout* args_layout) {
    if (num_args == 0)
        return eco_apply_closure(closureBits, nullptr, 0);

    Closure* closure = (Closure*)hpointerToPtr(closureBits.toBits());
    if (closure && (closure->flags & CLOSURE_FLAG_TYPED_NEWARGS)) {
        EvalFunction eval = closure->evaluator;
        void** asVoidPtrArray = reinterpret_cast<void**>(typed_args);
        void* resultPtr = eval(asVoidPtrArray);
        return ptr0ToHPtr(resultPtr);
    }

    // Legacy re-boxing path — unchanged for now (refactored into a
    // helper `applyClosureTyped_legacyBoxed` for readability).
}
```

Add a small inline helper (centralises the convention; one line, but
better than ad-hoc casts at every call site):

```cpp
// In RuntimeExports.h or a small Pointer.hpp:
inline HPtr ptr0ToHPtr(void* p) {
    return HPtr::fromBits(reinterpret_cast<uint64_t>(p));
}
```

**Step 2 (after §6.3 lands and the test suite is green):** delete the
legacy re-boxing branch.

```cpp
HPtr eco_apply_closure_typed(HPtr closureBits, int64_t* typed_args,
                             uint32_t num_args,
                             const Elm::EvalParamLayout* /*unused*/) {
    if (num_args == 0)
        return eco_apply_closure(closureBits, nullptr, 0);
    Closure* closure = (Closure*)hpointerToPtr(closureBits.toBits());
    debug_assert(closure->flags & CLOSURE_FLAG_TYPED_NEWARGS);
    EvalFunction eval = closure->evaluator;
    void* resultPtr = eval(reinterpret_cast<void**>(typed_args));
    return ptr0ToHPtr(resultPtr);
}
```

The `args_layout` parameter is kept for ABI stability (callers in JIT'd
IR pass a layout pointer; removing the parameter is a Phase F cleanup).

### 6.5 Migrate other wrapper consumers

The wrapper isn't only reached through `eco_apply_closure_typed`. The
typed-mode saturated path goes through `eco_closure_call_saturated` and
`emitInlineClosureCall`. Both currently feed HPtr-encoded args to the
wrapper. Once the wrapper is typed-convention, they would mis-feed.

Generating two wrappers per closure (legacy + typed) and threading
"which one to call" is heavier and complicates eventual cleanup. Instead,
migrate both paths in lockstep with §6.3:

- **`eco_closure_call_saturated`** (`RuntimeExports.cpp`): stop boxing
  new args before storing into the call buffer. The wrapper now expects
  raw primitives at primitive slots and HPtr passthrough at `!eco.value`
  slots.
- **`emitInlineClosureCall`** (`EcoToLLVMClosures.cpp`): stop boxing new
  args inline — store the SSA value directly into the `i64*` buffer
  (with the existing `i16` zext / `f64` bitcast for ABI uniformity).

Both updates are mechanical: remove the `eco_alloc_int/_float/_char`
calls in the new-arg-population loops; keep capture-decode logic
unchanged (captures are re-boxed as needed by the wrapper itself).

### 6.6 Runtime — `eco_apply_closure` becomes an all-boxed shim

**File:** `RuntimeExports.cpp`.

After §6.4 step 2, re-implement `eco_apply_closure` as a thin shim:

```cpp
HPtr eco_apply_closure(HPtr closureBits, uint64_t* boxed_args,
                       uint32_t num_args) {
    const Elm::EvalParamLayout* layout = kAllBoxedLayouts[num_args];
    int64_t* typed = reinterpret_cast<int64_t*>(boxed_args);
    return eco_apply_closure_typed(closureBits, typed, num_args, layout);
}
```

Static cache: `kAllBoxedLayouts[0..63]` — one tiny layout per arity, all
slots `PK_Boxed`. 64 layouts total (`max_values:6 = 63`), negligible
size, O(1) lookup. Initialise at startup or as `constexpr` data.

```cpp
constexpr int kMaxClosureArity = 63;
extern const Elm::EvalParamLayout* const kAllBoxedLayouts[kMaxClosureArity + 1];
```

Behaviour: the caller passes pre-boxed `uint64_t* args` (legacy
convention). All slots are HPtrs, so an all-`PK_Boxed` layout describes
them correctly. `eco_apply_closure_typed` then dispatches them through
the closure's wrapper — if the closure is typed-flag, the typed wrapper
treats `PK_Boxed` slots as HPtr passthrough (matching the legacy
behaviour). If the closure is unflagged, we're in step-1 transition
state (legacy re-boxing path) — also correct.

This keeps test fixtures and hand-written kernel callers working without
changes. They migrate at their own pace.

### 6.7 Compile-time sanity check on bit position

Currently the lowering encodes `packed = ... | (unboxed_bitmap << 12)`.
Phase E adds `| (1ULL << 62)` for typed closures. This relies on the
LSB-first bitfield ABI of clang/gcc on x86-64. Make the assumption
explicit:

```cpp
// In Heap.hpp, alongside the Closure struct:
namespace detail {
    constexpr uint64_t computeFlagMaskFor(unsigned char flagBit) {
        Closure c{};
        std::memset(&c, 0, sizeof(c));
        c.flags = flagBit;
        uint64_t packed;
        std::memcpy(&packed, reinterpret_cast<char*>(&c) + sizeof(Header),
                    sizeof(uint64_t));
        return packed;
    }
}
static_assert(detail::computeFlagMaskFor(CLOSURE_FLAG_TYPED_NEWARGS)
              == (1ULL << 62),
              "CLOSURE_FLAG_TYPED_NEWARGS expected to occupy bit 62 of the "
              "Closure packed word; bitfield layout has changed");
```

If a future compiler or packing change breaks the assumption, the build
fails loudly. Define `ClosureFlagTypedNewargsMask = 1ULL << 62` next to
the `static_assert` so the LLVM emitter and the runtime share one named
constant.

### 6.8 Over-saturated chaining

`eco_apply_closure`'s over-saturated branch saturates the current stage
then recursively applies the remaining args to the result closure.
Because §6.6 reduces `eco_apply_closure` to an all-boxed shim that
forwards to `eco_apply_closure_typed`, the recursive apply also goes
through the typed path with an all-boxed layout. Slots are genuinely
HPtr values; the layout marks them `PK_Boxed`; the typed dispatch
treats them as HPtr passthrough. **No special chaining logic is
needed.** This is purely a consequence of the shim design.

### 6.9 Tests and invariants

**Static-IR tests.** Extend the existing CGEN_059/060 fixtures:

- `/work/test/codegen/papextend_no_realloc.mlir` already asserts no
  `eco_alloc_*` in JIT'd IR for generic apply. Add a parallel fixture
  for `_call_kind=segmentation_unknown` if not already covered.
- After §6.4 step 2, both fixtures should pass without any
  `eco_alloc_*` calls anywhere in the LLVM output around the apply
  call sites.

**Runtime tests.** Extend `/work/test/allocator/EcoApplyClosureTypedTest.cpp`:

1. Build a typed-flag closure manually:
   - `eco_alloc_closure` to allocate.
   - Point `closure->evaluator` at a small C evaluator that interprets
     `void*[]` slots as raw primitives per a known kind sequence.
   - Set `closure->flags |= CLOSURE_FLAG_TYPED_NEWARGS`.
2. Snapshot `Allocator::getCombinedStats().objects_allocated`, call
   `eco_apply_closure_typed` with primitive args and a matching
   `EvalParamLayout`, snapshot again. **Assert delta == 0.**
3. Negative control: same closure setup *without* the flag, OR call via
   `eco_apply_closure` (boxed entry). **Assert delta > 0** (re-boxing
   happened) — proves the test isn't trivially passing.

The Phase D Part 3 tests already cover most of this; extend coverage to
include over-saturation chaining (verify it still works through the shim).

**E2E allocation-count benchmarks** (new). Under `/work/test/elm/` (or a
dedicated `/work/test/perf/`):

| Benchmark | Expected drop |
| --- | --- |
| `Utils.compare_Int` in a tight loop | N → 0 allocs per iter |
| `List.map (\x -> x + 1) intList` | N → small constant per element |
| `JsArray.indexedMap` over primitive elements | proportional → proportional - N |

Each snapshots `Allocator::getCombinedStats().objects_allocated` across
the workload and asserts the drop versus a captured baseline. **First
measurements proving Phase E delivers savings on real Elm code.**

**Invariant updates:**

- **CGEN_059** — drop "the runtime helper interprets the buffer per the
  layout and is the single locus where any required re-boxing occurs".
  Replace with: "the runtime forwards the typed buffer to the closure's
  evaluator without re-boxing; no `eco_alloc_*` calls happen on the
  apply path at all".
- **CGEN_060** — same edit for the segmentation_unknown saturated branch.

### 6.10 Concrete edits checklist

**Runtime:**

- `Heap.hpp`
  - Confirm `Closure::flags` and `CLOSURE_FLAG_TYPED_NEWARGS` are present
    (already so from Part 3).
  - Add the `ClosureFlagTypedNewargsMask` constant + `static_assert`
    on bit position (§6.7).
- `RuntimeExports.h`
  - Add inline `ptr0ToHPtr(void*)` helper (§6.4).
  - No signature changes for `eco_apply_closure_typed` or
    `eco_apply_segmentation_unknown`.
- `RuntimeExports.cpp`
  - **Step 1:** Add fast branch in `eco_apply_closure_typed` keyed on
    `closure->flags`. Refactor legacy boxing into a helper.
  - **Step 2 (after compiler migration):** Delete the legacy branch.
  - Re-implement `eco_apply_closure` as the all-boxed shim (§6.6).
  - Add `kAllBoxedLayouts[64]` static cache.
  - Update `eco_closure_call_saturated` to stop boxing new args (§6.5).

**Compiler (LLVM lowering):**

- `EcoToLLVMClosures.cpp`
  - Add `getOrCreateTypedWrapper` (§6.2). Wrapper derives kinds from
    `target.getFunctionType()`; **no** layout argument.
  - In the shared `papCreate` / `papCreateGroup` allocation helper:
    - Replace `getOrCreateWrapper` with `getOrCreateTypedWrapper` for
      closures with a valid layout.
    - OR `ClosureFlagTypedNewargsMask` into the `packed` word before
      storing.
  - Update `emitInlineClosureCall` to stop boxing new args (§6.5).

**Tests:**

- `papextend_no_realloc.mlir` — extend to cover segmentation_unknown if
  not already.
- `EcoApplyClosureTypedTest.cpp` — extend with over-saturation chain
  test, layout-less closure (legacy fallback) test.
- New benchmark suite under `/work/test/elm/` or `/work/test/perf/`.

### 6.11 Acceptance for Phase E

- `getOrCreateTypedWrapper` exists and is used at every `papCreate` /
  `papCreateGroup` site that produces a closure with a valid
  `EvalParamLayout`.
- Those closures carry `CLOSURE_FLAG_TYPED_NEWARGS = 1` in their header.
- `eco_closure_call_saturated` and `emitInlineClosureCall` pass typed
  args (no inline `eco_alloc_*`).
- `eco_apply_closure_typed`'s legacy re-boxing branch is removed.
- `eco_apply_closure` is reduced to an all-boxed shim.
- New E2E benchmarks demonstrate measurable allocation drops on
  representative Elm programs.
- `static_assert` on bit-62 layout passes.
- CGEN_059 / CGEN_060 updated.
- All existing test suites green.

The flag is universal *for closures with a layout* at end of Phase E;
layout-less and non-`papCreate*` closures stay legacy until a future
phase decides whether to migrate them. Phase F retires the flag.

---

## 6.5 Phase E.2 — `Basics.{add,sub,mul,pow}` per-instance variants

**Added 2026-05-07.** This phase reverses decision Q5 ("no primitive
variants for `Basics.add/sub/mul/pow`") after the Phase E audit
revealed that the original Q5 reasoning was incomplete.

### Why Q5 needs reversing

The Q5 decision rested on the claim:

> Concrete uses are already intrinsic-lowered; the kernel symbol only
> handles polymorphic fallbacks where boxing is correct.

This is true for **direct** application (`1 + 2`): MLIR codegen sees
concrete `[MInt, MInt]` operands and emits `eco.int.add` rather than
calling the kernel. No `Elm_Kernel_Basics_add` invocation occurs.

It is **false** for **indirect** application:

```elm
List.foldl (+) 0 xs
```

Here `(+)` becomes a `MonoVarKernel` that is captured into a PAP via
`papCreate`. The PAP needs an addressable function pointer. Today there
is only one `Elm_Kernel_Basics_add(HPtr, HPtr) -> HPtr` symbol — the
polymorphic boxed one — because:

- `kernelBackendAbiPolicy` returns `AllBoxed` for `Basics.add` (and
  `sub`/`mul`/`pow`).
- There are no `_Int`/`_Float` suffix branches in `kernelInstanceSymbol`.

So the closure wraps the boxed polymorphic kernel; args are boxed at
apply time even though the call-site type is concretely `Int -> Int -> Int`.

The fix is to add primitive variants and route concrete indirect uses
to them. Once landed, the polymorphic symbol becomes unreachable.

### Why this is implementation, not cleanup

Phase F deletes vestigial code paths. Phase E.2 adds new C symbols and
new suffix-selection rules — it changes the wire format for indirect
arithmetic uses from boxed to unboxed. That's an ABI change, not
cleanup. It belongs in the implementation phases.

### Step-by-step

**1. Add C variants in `elm-kernel-cpp/src/core/BasicsExports.cpp`**

Eight new symbols total:

```cpp
EXPORT int64_t Elm_Kernel_Basics_add_Int(int64_t a, int64_t b);
EXPORT double  Elm_Kernel_Basics_add_Float(double a, double b);
EXPORT int64_t Elm_Kernel_Basics_sub_Int(int64_t a, int64_t b);
EXPORT double  Elm_Kernel_Basics_sub_Float(double a, double b);
EXPORT int64_t Elm_Kernel_Basics_mul_Int(int64_t a, int64_t b);
EXPORT double  Elm_Kernel_Basics_mul_Float(double a, double b);
EXPORT int64_t Elm_Kernel_Basics_pow_Int(int64_t a, int64_t b);
EXPORT double  Elm_Kernel_Basics_pow_Float(double a, double b);
```

Implementation: each variant performs the unboxed arithmetic directly
(matching the intrinsic semantics — `i64` two's-complement wrap for Int
add/sub/mul; `pow` uses `std::pow` for Float and an integer-`pow` loop
for Int matching what the existing polymorphic kernel does).

Declarations in `elm-kernel-cpp/src/core/KernelExports.h` (or wherever
the per-instance variant declarations are organised — mirror the
existing `_Int` / `_Float` Phase C declarations).

**2. Add suffix branches in `kernelInstanceSymbol`** (`KernelAbi.elm`)

```elm
( "Basics", "add", [ Mono.MInt, Mono.MInt ] ) ->
    suffixed "_Int"

( "Basics", "add", [ Mono.MFloat, Mono.MFloat ] ) ->
    suffixed "_Float"

-- ... similar for sub, mul, pow
```

Eight new arms total. The argument shape for each is `[N, N]` (binary
operator).

**3. Move `Basics.{add,sub,mul,pow}` from `numberBoxedKernels` →
`concreteTypeAwareKernels`** (the set being renamed to
`suffixSelectingKernels` in Phase F step 4).

Without this move, `deriveKernelAbiType` enters the `NumberBoxed` arm,
which (with `forceCNumberToInt` now identity per "Fix 9") still produces
the fully-monomorphic type — but the path is muddled. Move now to make
the implementation match the design.

After this move `numberBoxedKernels` is empty and `NumberBoxed` mode
is unreachable for any kernel. (Removal of the mode itself is Phase F
step 6.)

**4. Delete the `Basics.{add,sub,mul,pow}` `kernelBackendAbiPolicy` arms.**

Originally listed as Phase F step 5; moved to Phase E.2 because the
suffix selector and the policy table must agree on the wire format.
With `kernelInstanceSymbol` selecting `Elm_Kernel_Basics_add_Int` but
`kernelBackendAbiPolicy` still returning `AllBoxed`, the call site
emits `(HPtr, HPtr) -> HPtr` ABI against a C symbol declared
`(int64_t, int64_t) -> int64_t` — an immediate ABI mismatch.

Delete the four explicit arms:

```elm
( "Basics", "add" ) -> AllBoxed   -- DELETE
( "Basics", "sub" ) -> AllBoxed   -- DELETE
( "Basics", "mul" ) -> AllBoxed   -- DELETE
( "Basics", "pow" ) -> AllBoxed   -- DELETE
```

Fall through to `ElmDerived`. With concrete `[MInt, MInt]` argTypes,
`monoTypeToAbi` produces `[ecoInt, ecoInt] -> ecoInt`, matching the
new C symbol's signature.

### What does NOT change in Phase E.2

- The polymorphic `Elm_Kernel_Basics_add(HPtr, HPtr)` C symbol still
  exists and still works. After Phase E.2 it is unreachable in
  practice; Phase F step 7 decides whether to delete it.
- `NumberBoxed` mode and `numberBoxedKernels` (now empty) are still
  defined. They become dead code; Phase F step 6 removes them.

### Tests

- `KernelAbiTest`: add cases for `Basics.add_Int`, `add_Float`, `sub_*`,
  `mul_*`, `pow_*`. Mirror the existing `String.fromNumber_Int/Float`
  tests.
- E2E: existing arithmetic-heavy tests should continue to pass; new
  variants are exercised by indirect uses (`List.foldl (+) 0`, etc.).
  No new fixtures needed — corpus coverage is high.
- Stress: no expected change.

Risk: low. Direct uses are unchanged (intrinsic-lowered as before).
Indirect uses gain a faster code path; the boxed kernel remains as
backup until Phase F.

---

## 7. Phase F — Cleanup after per-instance kernel ABI rollout

The Phase E audit (`plans/phase-f-readiness-report.md`, 2026-05-07)
revised the original Phase F plan. The four bullets below replace the
earlier sketch; they reflect what the code actually requires now that
Phases B–E have landed.

The ordering is by risk: each step is independently verifiable and
revertible, and later steps assume earlier ones have stuck.

### Decisions that did NOT survive the audit

The following items from earlier drafts of Phase F are dropped:

- **"Drop `NumberBoxed` mode entirely."** The mode is doing two distinct
  jobs: (a) deferred `PendingKernel` resolution for kernels passed as
  arguments, and (b) the boxed-fallback erasure for genuinely
  number-polymorphic call sites (e.g. `List.foldl (+) 0`). After moving
  `String.fromNumber` out (step 1 below), `NumberBoxed` narrows to
  `Basics.add/sub/mul/pow` only, where both behaviours are still needed.
  Renaming the mode to `BoxedNumericFallback` is optional polish.
- **"Drop `concreteTypeAwareKernels` once migrations land."** The
  retirement story in earlier Q4 doesn't match the code: removing the
  set causes `canTypeToMonoType_preserveVars` to erase primitive type
  variables to `CEcoValue` *before* `kernelInstanceSymbol` sees them,
  which silently breaks suffix selection on type-variable axes
  (`List.cons`, `MVar.put`, `Utils.compare`, `JsArray.singleton`/`push`/
  `unsafeSet`, `Json.wrap`). The set IS the registration mechanism.
  Step 4 below renames it; deletion would require flipping the default
  in `deriveKernelAbiType` to "preserve when monomorphic" and is left
  for a separate cleanup if ever desired.
- **"Inline / remove `kernelBackendAbiPolicy` entirely."** After step 3
  the table shrinks to four entries (`Basics.add/sub/mul/pow`). At
  that size keeping it as a small lookup is fine; full removal would
  require inlining the AllBoxed override into `deriveKernelInstanceAbi`
  and is not worth the churn.

### Step 1 — Move `String.fromNumber` to `suffixSelectingKernels`

`String.fromNumber` already has both halves of the per-instance ABI:

- C symbols `Elm_Kernel_String_fromNumber_Int(int64_t)` and
  `Elm_Kernel_String_fromNumber_Float(double)` exist in
  `elm-kernel-cpp/src/core/StringExports.cpp`.
- Suffix branches `("String","fromNumber",[MInt|MFloat])` exist in
  `KernelAbi.elm:kernelInstanceSymbol`.

It is, however, still in `numberBoxedKernels` rather than the
suffix-selecting set. Move it:

1. Remove `( "String", "fromNumber" )` from `numberBoxedKernels`.
2. Add `( "String", "fromNumber" )` to `suffixSelectingKernels` (the
   set being renamed in step 4).
3. Verify `KernelAbiTest` still green; existing test cases for
   `String.fromNumber Int` / `Float` cover the suffix-selection path.
4. Verify E2E + stress no regressions.

After this step, `numberBoxedKernels` contains only the four
`Basics.add/sub/mul/pow` polymorphic-fallback kernels — which is the
correct steady-state shape and makes `NumberBoxed` mode's narrowed
purpose obvious.

### Step 2 — Retire `CLOSURE_FLAG_TYPED_NEWARGS`

The Phase E audit confirmed the flag bit is **completely vestigial**:

- Defined in `runtime/src/allocator/Heap.hpp:372` plus the
  `ClosureFlagTypedNewargsMask` packed-word constant.
- Set in exactly two places:
  - `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:606` (`papCreate`
    lowering OR's it into the packed word).
  - `runtime/src/allocator/RuntimeExports.cpp:738`
    (`eco_alloc_closure_group_packed`).
- **Read for runtime branching: zero places.** Dispatch in
  `eco_closure_call_saturated` and `eco_apply_closure_typed` is driven
  from `closure->unboxed[i]` (the 2-bit PrimitiveKind bitmap), not
  from any flag.

The four binding-evaluator bugs fixed during the Phase E audit
(`MVar.read/take/put_*` decoding `rawArgs[0]` as HPointer when the
captured `mvarId` was PK_Int; `Process.sleep` doing the same for a
PK_Float `millis`) are exactly the audit Option A would have caught.
With those four fixed, the full set of capture-primitive
`eco_alloc_closure*` callers is correctly written. There are no other
holdouts: every other direct `eco_alloc_closure*` caller in the runtime
and kernel sources captures via `boxed(...)` only.

Take Option A. Mechanical steps:

1. Delete `CLOSURE_FLAG_TYPED_NEWARGS` from the `ClosureFlag` enum in
   `Heap.hpp`.
2. Delete `ClosureFlagTypedNewargsMask` and the self-consistency
   `static_assert` it carries.
3. Delete the `flagMask` write at `EcoToLLVMClosures.cpp:606` (the
   `OR` term in `packedValue`).
4. Delete `closure->flags = CLOSURE_FLAG_TYPED_NEWARGS;` at
   `RuntimeExports.cpp:738`.
5. Widen `Closure::unboxed` from 50 → 52 bits (and the per-closure
   capture limit from 25 → 26) by reclaiming the two flag bits.
6. Either delete `Closure::flags` outright or repurpose it for a
   future flag. Recommended: delete; it can be re-added as a single
   bit later if needed.

Verification: re-run E2E + stress. If both still pass at the post-fix
counts (1263/1263 E2E, 99/99 stress), the bit was provably dead.

Risk: low. The bit is consulted for no decision; removal cannot change
runtime behaviour. The 50→52 widening is a strict capacity gain that
restores the documented per-closure capture limit.

### Step 3 — Collapse `kernelBackendAbiPolicy` AllBoxed entries

Several entries in `kernelBackendAbiPolicy` are `AllBoxed` even though
their parameters are uniformly `!eco.value` (closures, lists, JsArrays,
Strings) — for these, `AllBoxed` and `ElmDerived` produce identical
wire formats because `monoTypeToAbi` of every parameter resolves to
`!eco.value` regardless. The explicit override is redundant and can be
removed by falling through to `ElmDerived`.

Move the following to `ElmDerived` (i.e. delete their explicit arms):

- `List.fromArray`, `List.toArray`
- `List.map2`, `List.map3`, `List.map4`, `List.map5`
- `List.sortBy`, `List.sortWith`
- `Utils.append`
- `JsArray.empty`, `JsArray.length`, `JsArray.map`, `JsArray.foldl`,
  `JsArray.foldr`

Keep as `AllBoxed`:

- `Basics.add`, `Basics.sub`, `Basics.mul`, `Basics.pow` —
  the polymorphic-fallback path. Concrete `[MInt,MInt]` /
  `[MFloat,MFloat]` cases are intrinsic-lowered before the kernel
  symbol is reached; the kernel symbol only handles genuinely
  polymorphic uses where boxing is correct.

Per `alwaysPolymorphicModules`, `Debug.*` is handled separately and
does not appear in `kernelBackendAbiPolicy`.

After this step `kernelBackendAbiPolicy` is a four-entry table for
`Basics.{add,sub,mul,pow}`. Update or remove `KERN_006`'s reference to
the table only if the residual four entries no longer carry useful
signal; otherwise leave the invariant in place.

Risk: zero semantic change for the migrated entries (wire format is
bit-identical). Verify with E2E + stress that there is no regression
from the policy-table simplification.

Optional follow-on: corpus-scan `Basics.add/sub/mul/pow` for genuinely
polymorphic call sites. If empty, the C++ implementations can be
deleted; if non-empty (likely — `List.foldl (+) 0` is a common idiom
that erases the operand type), keep them. This is a binary-size
optimization; not on the critical path.

### Step 4 — Rename `concreteTypeAwareKernels` → `suffixSelectingKernels`

The set's actual function is **registering kernels for suffix
selection**: it tells `deriveKernelAbiType` to preserve the concrete
monomorphic type so that `kernelInstanceSymbol` can pattern-match on
primitive `MonoType`s and pick the `_Int` / `_Float` / `_Char` C symbol
variant. The original name, "concrete type aware kernels", described
how the table works; the new name describes what it's for.

Mechanical:

1. Rename the binding `concreteTypeAwareKernels` → `suffixSelectingKernels`
   in `compiler/src/Compiler/Monomorphize/KernelAbi.elm`.
2. Update the doc comment to reflect the new name and emphasise that
   membership is the registration mechanism for suffix-selecting
   kernels — the table is **load-bearing** and not a transitional
   shim.
3. Update all references:
   - `Compiler.Monomorphize.Specialize.deriveKernelAbiType` (the
     `EverySet.member ... concreteTypeAwareKernels` check in the
     `PreserveVars` arm).
   - `compiler/tests/Compiler/Monomorphize/KernelAbiTest.elm` (any
     direct references in test names / docs).
   - Comments and doc strings throughout.
4. Verify frontend tests + E2E pass.

Risk: zero functional change; pure rename + doc update.

After step 4, the suffix-selecting set is complete and named
correctly. `numberBoxedKernels` is empty (Phase E.2 emptied it by
moving `Basics.{add,sub,mul,pow}` to the suffix-selecting set).

### Step 5 — (removed — moved to Phase E.2)

The flip from `AllBoxed` → `ElmDerived` for the four `Basics`
arithmetic kernels was originally listed here as cleanup, but it is
load-bearing for Phase E.2 (without it, the suffix selector and the
policy table disagree on the wire format and the call site emits
`(HPtr, HPtr) -> HPtr` ABI against a `(int64_t, int64_t) -> int64_t` C
symbol). It is now done as part of Phase E.2.

### Step 6 — Remove `NumberBoxed` mode

After Phase E.2 and step 1 above, `numberBoxedKernels` is empty. The
`NumberBoxed` arm in `deriveKernelAbiMode` is unreachable (the
`EverySet.member ... numberBoxedKernels` check always returns False),
and the `NumberBoxed` arms in `processCallArg` and `deriveKernelAbiType`
are dead.

Delete:

1. `KernelAbiMode = NumberBoxed` constructor (`KernelAbi.elm:92`).
2. `numberBoxedKernels` definition (`KernelAbi.elm:153`).
3. `canTypeToMonoType_numberBoxed` definition (`KernelAbi.elm:396`).
4. The `NumberBoxed` branch in `deriveKernelAbiMode`
   (`KernelAbi.elm:131-133`).
5. The `NumberBoxed` arm in `Specialize.processCallArg`
   (`Specialize.elm:3249-3258`) — `VarKernel` falls through to the
   eager `specializeExpr` path used by `PreserveVars`.
6. The `NumberBoxed` arm in `Specialize.deriveKernelAbiType`
   (`Specialize.elm:4501-4514`).
7. The `PendingKernel` constructor in `processCallArg`'s deferred
   args is also unused after this — remove it from the
   `PendingArg` enumeration too.

Verify: frontend tests + E2E + stress.

Risk: low. The dead-code analysis is mechanical: `numberBoxedKernels`
is empty, so every `NumberBoxed` case is statically unreachable.

### Step 7 — Decide on the polymorphic `Elm_Kernel_Basics_*` C symbols

After step 5, the polymorphic boxed C symbols
(`Elm_Kernel_Basics_add(HPtr, HPtr) -> HPtr` etc.) are unreachable
from generated MLIR. Two options:

**Option A — leave them as dead C symbols.** Lowest-risk: the
declarations and definitions remain in `BasicsExports.cpp` but are
never linked. The linker likely strips them. Binary size cost is
small; correctness is unaffected.

**Option B — delete them.** Remove the four `EXPORT HPtr
Elm_Kernel_Basics_{add,sub,mul,pow}(HPtr, HPtr)` definitions and
their `KernelExports.h` declarations. Slightly cleaner; small risk
that some out-of-tree caller relied on them (unlikely — kernel
symbols are only reached via generated MLIR).

Recommended: **Option B.** The polymorphic boxed kernel was always a
fallback for the (now non-existent) genuinely number-polymorphic
indirect use case. Delete it to make the codebase reflect the new
invariant: `Basics.add` is always concrete at the C boundary.

Risk: low. The removal is purely subtractive; if any code path
secretly reaches it, the linker error is loud and immediate.

### Phase F summary

| Step | Action | Risk | Dependencies |
| ---- | ------ | ---- | ------------ |
| 1 | Move `String.fromNumber` to suffix-selecting set | Low | — |
| 2 | Retire `CLOSURE_FLAG_TYPED_NEWARGS` | Low | — |
| 3 | Collapse AllBoxed entries with no primitive-capable params | Zero | — |
| 4 | Rename `concreteTypeAwareKernels` → `suffixSelectingKernels` | Zero | Steps 1, 5 (so the new name lands with full membership) |
| 5 | (Moved to Phase E.2) | — | — |
| 6 | Remove `NumberBoxed` mode | Low | Phase E.2, step 1 |
| 7 | Delete polymorphic `Elm_Kernel_Basics_*` C symbols | Low | Phase E.2 |

Steps 1–4 are independent of E.2 and can land first. Steps 6–7 unlock
once Phase E.2 has been verified in production. Each step can land as
a separate PR.

---

## 7. New tests

Place these alongside the existing CodeGen invariant tests in
`compiler/tests/TestLogic/Generate/CodeGen/`:

| Test | What it asserts |
| --- | --- |
| `KernelInstanceAbi.elm` | For each `eco.call` with callee `Elm_Kernel_*`, the operand MLIR types match `monoTypeToAbi` of the corresponding monomorphic argument type — no `!eco.value` slot has primitive MonoType. |
| `KernelInstanceConsistency.elm` | Every `Elm_Kernel_*_<suffix>` symbol used in the module has a matching `func.func private` decl with identical types (CGEN_038, scoped per symbol). |
| `ClosurePrimitiveAbi.elm` | Every `_fast_evaluator` symbol used by closures over kernels has primitive parameters where `_capture_abi` says primitive. |
| `GenericApplyPrimitive.elm` | Generic-mode `eco.papExtend` (no `remaining_arity`) emits no boxing op (`eco.box`, `eco.alloc_int`, etc.) for arguments whose `_operand_types` says primitive. |

The Elm tests can use the existing MLIR-text harness in
`compiler/tests/TestLogic/Generate/CodeGen/CallAbiConsistency.elm` as a
template.

C++ tests:

- Per-variant unit tests in `elm-kernel-cpp/tests/UtilsExportsTest.cpp` etc.
- A runtime test that calls `eco_apply_closure_typed` directly with a known
  closure + primitive args and checks both the result and the heap allocator
  counters (no `eco_alloc_int` calls in the steady state).

---

## 8. Risks and rollback

- **Symbol explosion**: every primitive monomorphic call site now produces
  a distinct `Elm_Kernel_*_<suffix>` decl. Mitigation: `kernelDecls` is
  already a `Dict`, dedup is automatic; the C++ binary grows by the number
  of variants (3–4 per affected kernel), which is small.
- **CGEN_038 violations during rollout**: if someone introduces a kernel use
  with mismatched ABI types under the new keying. Mitigation: the
  `registerKernelInstance` mismatch crash and the new
  `KernelInstanceConsistency` test catch this.
- **`Char` zero-extension hazard**: the SysV/statepoint issue documented in
  `KernelExports.h:75–79` exists for the *legacy* Char kernels.
  Per decision Q3, new `_Char` variants use the standard `uint16_t` ABI
  and rely on EcoToLLVM to insert `zext`/`trunc` when funnelling values
  through generic-apply args arrays. Verify with a runtime test that
  `Utils.compare_Char` round-trips across `gc.statepoint` correctly; if
  the hazard reappears, the fix is to apply the `c_raw` widening only at
  the offending callsite, not as a kernel-wide ABI change.
- **Incremental rollout**: each phase is independently revertable. If Phase D
  destabilises generic apply, we can roll back D alone — phases A–C give us
  per-instance ABI for direct calls without touching the runtime helpers.

---

## 9. Resolved decisions and remaining checks

The eight original open questions have been resolved:

| # | Question | Decision |
| --- | --- | --- |
| 1 | Where does `deriveKernelInstanceAbi` live? | Both data types and function in `KernelAbi.elm`. `Context` is a pure consumer. |
| 2 | Keep `KernelBackendAbiPolicy` during rollout? | Keep. Use as a coarse "always boxed" guardrail; flip entries kernel-by-kernel. Phase F collapses entries with no primitive-capable params to `ElmDerived`; the residual table (the four `Basics` arithmetic kernels) is the steady-state shape. |
| 3 | `_Char` parameter ABI? | Standard `uint16_t`, **not** `uint64_t c_raw`. EcoToLLVM handles any `zext`/`trunc` for generic apply. |
| 4 | `concreteTypeAwareKernels` wrappers? | **Permanent.** The set is the registration mechanism for suffix-selecting kernels — without it, `canTypeToMonoType_preserveVars` erases primitive type variables before `kernelInstanceSymbol` sees them. Phase F renames it to `suffixSelectingKernels` to match its actual function (revised 2026-05-07 from earlier "retire in Phase F" plan after Phase E audit). |
| 5 | Primitive variants for `Basics.add/sub/mul/pow`? | **Yes** (revised 2026-05-07; original answer "No" was reversed by Phase E.2). Direct uses are intrinsic-lowered, but indirect uses — `(+)` passed as a closure to e.g. `List.foldl` — go through `papCreate` and need an addressable per-instance C symbol. Phase E.2 adds `_Int`/`_Float` variants; Phase F deletes the polymorphic root. |
| 6 | Per-evaluator "accepts typed newargs" capability bit? | **Yes.** Add to `EvalParamLayout`, default `0`. `eco_apply_closure_typed` re-boxes for evaluators that don't accept primitives. Flip on per-evaluator as they migrate. |
| 7 | MONO_002 holds at `generateVarKernel`? | Yes per the invariant. Add a defensive assertion in `KernelInstanceKey` construction. |
| 8 | `_Bool` kernel variants? | **No.** Bool stays `!eco.value` at ABI; a `_Bool` symbol with `(HPtr, HPtr)` adds nothing. Bool fast paths belong in `Intrinsics.elm`, not in kernel symbol space. |

Remaining sanity checks to perform during Phase A (before any Phase B work):

- Confirm `KernelAbi.elm → Generate.MLIR.Types` has no import cycle when we
  add the MLIR-typed fields. If a cycle appears, hoist `MlirType` into a
  shared module before adding the new types.
- Confirm there is no Elm test today that exercises
  `Basics.add/sub/mul/pow` and reaches the kernel symbol with fully concrete
  arguments. If one exists, treat it as evidence that intrinsic coverage
  has a gap and add an intrinsic — do not add a primitive kernel variant.
- Spot-check that every `MonoVarKernel` reaching `generateVarKernel` has
  argument types free of `MVar _ CNumber` (MONO_002 spot-check).

---

## Appendix A — Kernel Variant Audit Report

**Sources of truth used**

- `elm-kernel-cpp/src/KernelExports.h` — current C ABI signatures.
- `compiler/src/Compiler/Generate/MLIR/Context.elm` (`kernelBackendAbiPolicy`,
  lines 121–190) and `design_docs/theory/kernel_abi_theory.md` (mirror of the
  policy table).
- Elm signatures from
  `~/.eco/1.0.0/packages/elm/core/1.0.5/src/{Basics,Bitwise,Char,String,List,Elm/JsArray,Debug,Process}.elm`
  and `~/.eco/1.0.0/packages/elm/json/1.1.4/src/Json/Encode.elm`.

**Primitive ABI mapping** (per `Compiler.Generate.MLIR.Types.monoTypeToAbi`):

- `Int → int64_t`, `Float → double`, `Char → uint16_t`. All other Elm types
  → `uint64_t` (HPtr) at the C ABI.

**Note on `appendable`**: in Elm's type system `appendable` resolves only to
`String` or `List a`. It does **not** include `Int`, `Float`, or `Char`.
Therefore `Utils.append` is *not* a primitive-capable kernel under the rules
of this audit and is excluded.

**Note on `comparable`**: in Elm 0.19, `comparable` resolves to `Int`,
`Float`, `Char`, `String`, or tuples / lists of `comparable`. So `comparable`
admits `Int`, `Float`, and `Char`.

**Note on `number`**: resolves to `Int` or `Float`.

### Step 1 + Step 2 — Kernels that are AllBoxed *and* primitive-capable

A kernel is "primitive-capable" if any parameter, after admissible Elm type
instantiation, can be `Int`, `Float`, or `Char`. A kernel is "AllBoxed" if
`kernelBackendAbiPolicy` returns `AllBoxed` and its `KernelExports.h`
signature is uniformly `HPtr`/`uint64_t` for all parameters and the return
value.

Walking the five `AllBoxed` groups in `kernelBackendAbiPolicy`:

#### `("List", _) → AllBoxed`

C signatures (from `KernelExports.h` lines 129–138):

| Kernel | Elm type | C ABI today | Has primitive-capable parameter? |
| --- | --- | --- | --- |
| `List.cons` | `a -> List a -> List a` | `HPtr(HPtr,HPtr)` | Yes — `a` admits `Int`/`Float`/`Char`. |
| `List.fromArray` | `JsArray a -> List a` | `HPtr(HPtr)` | No — `JsArray a` is a container; carries primitives only indirectly. |
| `List.toArray` | `List a -> JsArray a` | `HPtr(HPtr)` | No — same reason. |
| `List.map2` | `(a -> b -> r) -> List a -> List b -> List r` | `HPtr(HPtr,HPtr,HPtr)` | No — only closures and Lists. |
| `List.map3` | analogous | `HPtr(HPtr,HPtr,HPtr,HPtr)` | No. |
| `List.map4` | analogous | `HPtr(HPtr,HPtr,HPtr,HPtr,HPtr)` | No. |
| `List.map5` | analogous | `HPtr(HPtr,HPtr,HPtr,HPtr,HPtr,HPtr)` | No. |
| `List.sortBy` | `(a -> comparable) -> List a -> List a` | `HPtr(HPtr,HPtr)` | No — closure and list. |
| `List.sortWith` | `(a -> a -> Order) -> List a -> List a` | `HPtr(HPtr,HPtr)` | No. |

Per the audit rule "indirect via container ≠ primitive at this kernel's own
ABI": **only `List.cons` qualifies.**

#### `("Utils", _) → AllBoxed`

C signatures (lines 144–151):

| Kernel | Elm type | C ABI today | Primitive-capable? |
| --- | --- | --- | --- |
| `Utils.compare` | `comparable -> comparable -> Order` | `HPtr(HPtr,HPtr)` | Yes — `Int`/`Float`/`Char`/`String`. |
| `Utils.equal` | `a -> a -> Bool` | `HPtr(HPtr,HPtr)` | Yes — `a` admits any primitive. |
| `Utils.notEqual` | `a -> a -> Bool` | `HPtr(HPtr,HPtr)` | Yes. |
| `Utils.lt` | `comparable -> comparable -> Bool` | `HPtr(HPtr,HPtr)` | Yes. |
| `Utils.le` | `comparable -> comparable -> Bool` | `HPtr(HPtr,HPtr)` | Yes. |
| `Utils.gt` | `comparable -> comparable -> Bool` | `HPtr(HPtr,HPtr)` | Yes. |
| `Utils.ge` | `comparable -> comparable -> Bool` | `HPtr(HPtr,HPtr)` | Yes. |
| `Utils.append` | `appendable -> appendable -> appendable` | `HPtr(HPtr,HPtr)` | No — `appendable` ⊂ `{String, List _}`. |

**All Utils except `append` qualify.**

#### `("String", "fromNumber") → AllBoxed`

| Kernel | Elm type | C ABI today | Primitive-capable? |
| --- | --- | --- | --- |
| `String.fromNumber` | `number -> String` | `HPtr(HPtr)` (line 112) | Yes — `number` ⇒ `Int` or `Float`. |

#### `("JsArray", _) → AllBoxed`

C signatures (lines 173–202). All `Elm_Kernel_JsArray_*` symbols use uniformly
`HPtr` parameters and return today, including the index-typed ones (`length`,
`unsafeGet/Set`, `slice`, `appendN`, `initialize`, `indexedMap`).

> **Important**: `KernelExports.h` lines 184–194 also declare `elm_array_*`
> typed trampolines (`elm_array_singleton_int`, `elm_array_push_float`, etc.).
> Those are **not** AllBoxed kernel functions in the meaning of
> `kernelBackendAbiPolicy`; they are intrinsic trampolines invoked from
> `eco.array.*` lowering and already take primitives. They are out of scope
> for this audit.

| Kernel | Elm type | C ABI today | Primitive-capable? |
| --- | --- | --- | --- |
| `JsArray.empty` | `JsArray a` (zero-arg) | `HPtr()` | No (no parameters). |
| `JsArray.singleton` | `a -> JsArray a` | `HPtr(HPtr)` | Yes — `a`. |
| `JsArray.length` | `JsArray a -> Int` | `HPtr(HPtr)` | No (param is a container). |
| `JsArray.unsafeGet` | `Int -> JsArray a -> a` | `HPtr(HPtr,HPtr)` | Yes — `Int` index. |
| `JsArray.unsafeSet` | `Int -> a -> JsArray a -> JsArray a` | `HPtr(HPtr,HPtr,HPtr)` | Yes — `Int` index *and* element `a`. |
| `JsArray.push` | `a -> JsArray a -> JsArray a` | `HPtr(HPtr,HPtr)` | Yes — `a`. |
| `JsArray.slice` | `Int -> Int -> JsArray a -> JsArray a` | `HPtr(HPtr,HPtr,HPtr)` | Yes — two `Int` indices. |
| `JsArray.appendN` | `Int -> JsArray a -> JsArray a -> JsArray a` | `HPtr(HPtr,HPtr,HPtr)` | Yes — `Int`. |
| `JsArray.initialize` | `Int -> Int -> (Int -> a) -> JsArray a` | `HPtr(HPtr,HPtr,HPtr)` | Yes — two `Int` parameters (size, offset). |
| `JsArray.initializeFromList` | `Int -> List a -> (JsArray a, List a)` | `HPtr(HPtr,HPtr)` | Yes — `Int`. |
| `JsArray.map` | `(a -> b) -> JsArray a -> JsArray b` | `HPtr(HPtr,HPtr)` | No. |
| `JsArray.indexedMap` | `(Int -> a -> b) -> Int -> JsArray a -> JsArray b` | `HPtr(HPtr,HPtr,HPtr)` | Yes — `Int` offset. |
| `JsArray.foldl` | `(a -> b -> b) -> b -> JsArray a -> b` | `HPtr(HPtr,HPtr,HPtr)` | No (the `b` accumulator is fully polymorphic at the kernel ABI; treated under the same "indirect via container" exclusion as `List.fromArray`). |
| `JsArray.foldr` | analogous | analogous | No (same as foldl). |

> The `b` accumulator argument of `JsArray.foldl` / `foldr` is unconstrained
> `b`, so by the strict reading in Step 1 it could be primitive. However,
> this is the same direct-but-polymorphic-at-the-ABI position as
> `List.cons`'s element. Excluded out of caution because the accumulator is
> shared with the user closure, which today is an evaluator that expects
> boxed args (cf. `kinds.push_back(0); // PK_Boxed` in
> `EcoToLLVMClosures.cpp:1604`). Flag for revisit if the rule should apply
> uniformly.

#### `("Json", "wrap") → AllBoxed`

| Kernel | Elm type | C ABI today | Primitive-capable? |
| --- | --- | --- | --- |
| `Json.wrap` | `a -> Value` (used at `Int -> Value`, `Float -> Value`, `String -> Value`, `Bool -> Value` per `Json/Encode.elm`) | `HPtr(HPtr)` (line 339) | Yes — `Int`/`Float`/`Char` are reachable instantiations. |

#### Summary of intersection

The set of kernels that are **both** primitive-capable **and** currently
AllBoxed with a uniform `uint64_t` C ABI:

```
List.cons
Utils.compare
Utils.equal
Utils.notEqual
Utils.lt
Utils.le
Utils.gt
Utils.ge
String.fromNumber
JsArray.singleton
JsArray.unsafeGet
JsArray.unsafeSet
JsArray.push
JsArray.slice
JsArray.appendN
JsArray.initialize
JsArray.initializeFromList
JsArray.indexedMap
Json.wrap
```

That is **19 kernel functions** that need monomorphic C++ variants under the
new rule.

### Step 3 + Step 4 — Required variants and signatures

For each surviving kernel, the **current** signature from `KernelExports.h`
followed by the **new monomorphic variants**, with primitives mapped per the
standard ABI (`Int → int64_t`, `Float → double`, `Char → uint16_t`).

Naming convention: `<existing base>_<Primitive>` for parameters whose type is
a single specializable primitive position. For kernels with two or more
independently specializable primitive positions (`JsArray.unsafeSet`), the
suffix encodes only the **element-type axis** that the spec instantiates;
numeric index parameters always become `int64_t` regardless of the element
axis.

#### List

```c
HPtr Elm_Kernel_List_cons(HPtr head, HPtr tail);                             // current
```
Variants needed (specializing `a`):
```c
HPtr Elm_Kernel_List_cons_Int  (int64_t  head, HPtr tail);
HPtr Elm_Kernel_List_cons_Float(double   head, HPtr tail);
HPtr Elm_Kernel_List_cons_Char (uint16_t head, HPtr tail);
```

#### Utils

```c
HPtr Elm_Kernel_Utils_compare (HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_equal   (HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_notEqual(HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_lt      (HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_le      (HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_gt      (HPtr a, HPtr b);                              // current
HPtr Elm_Kernel_Utils_ge      (HPtr a, HPtr b);                              // current
```

`Utils.compare` (`comparable, comparable → Order`) — `Order` is a custom
type, so the result stays `HPtr`:

```c
HPtr Elm_Kernel_Utils_compare_Int  (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_compare_Float(double   a, double   b);
HPtr Elm_Kernel_Utils_compare_Char (uint16_t a, uint16_t b);
```

`Utils.equal`, `Utils.notEqual` (`a, a → Bool`) — `Bool` is boxed at ABI, so
the result stays `HPtr`:

```c
HPtr Elm_Kernel_Utils_equal_Int      (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_equal_Float    (double   a, double   b);
HPtr Elm_Kernel_Utils_equal_Char     (uint16_t a, uint16_t b);

HPtr Elm_Kernel_Utils_notEqual_Int   (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_notEqual_Float (double   a, double   b);
HPtr Elm_Kernel_Utils_notEqual_Char  (uint16_t a, uint16_t b);
```

`Utils.lt/le/gt/ge` (`comparable, comparable → Bool`):

```c
HPtr Elm_Kernel_Utils_lt_Int  (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_lt_Float(double   a, double   b);
HPtr Elm_Kernel_Utils_lt_Char (uint16_t a, uint16_t b);

HPtr Elm_Kernel_Utils_le_Int  (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_le_Float(double   a, double   b);
HPtr Elm_Kernel_Utils_le_Char (uint16_t a, uint16_t b);

HPtr Elm_Kernel_Utils_gt_Int  (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_gt_Float(double   a, double   b);
HPtr Elm_Kernel_Utils_gt_Char (uint16_t a, uint16_t b);

HPtr Elm_Kernel_Utils_ge_Int  (int64_t  a, int64_t  b);
HPtr Elm_Kernel_Utils_ge_Float(double   a, double   b);
HPtr Elm_Kernel_Utils_ge_Char (uint16_t a, uint16_t b);
```

#### String

```c
HPtr Elm_Kernel_String_fromNumber(HPtr n);                                   // current
```
`String.fromNumber : number → String` admits `Int` and `Float`:
```c
HPtr Elm_Kernel_String_fromNumber_Int  (int64_t n);
HPtr Elm_Kernel_String_fromNumber_Float(double  n);
```

#### JsArray

```c
HPtr Elm_Kernel_JsArray_singleton          (HPtr value);                                          // current
HPtr Elm_Kernel_JsArray_unsafeGet          (HPtr index, HPtr array);                              // current
HPtr Elm_Kernel_JsArray_unsafeSet          (HPtr index, HPtr value, HPtr array);                  // current
HPtr Elm_Kernel_JsArray_push               (HPtr value, HPtr array);                              // current
HPtr Elm_Kernel_JsArray_slice              (HPtr start, HPtr end, HPtr array);                    // current
HPtr Elm_Kernel_JsArray_appendN            (HPtr n, HPtr dest, HPtr source);                      // current
HPtr Elm_Kernel_JsArray_initialize         (HPtr size, HPtr offset, HPtr closure);                // current
HPtr Elm_Kernel_JsArray_initializeFromList (HPtr max, HPtr list);                                 // current
HPtr Elm_Kernel_JsArray_indexedMap         (HPtr closure, HPtr offset, HPtr array);               // current
```

`JsArray.singleton : a → JsArray a` — specializing `a`:

```c
HPtr Elm_Kernel_JsArray_singleton_Int  (int64_t  v);
HPtr Elm_Kernel_JsArray_singleton_Float(double   v);
HPtr Elm_Kernel_JsArray_singleton_Char (uint16_t v);
```

`JsArray.unsafeGet : Int → JsArray a → a` — only the index is
primitive-capable; the result is `a`, but result type is not specialized at
the C boundary (it is `HPtr` and the caller unboxes if needed):

```c
HPtr Elm_Kernel_JsArray_unsafeGet_Int(int64_t index, HPtr array);
```

> The element type position (`a`) is not a parameter, so it does not generate
> parameter-side variants. Returning a primitive directly would require
> result-side specialization, which the current scheme (per the agreed plan)
> does not encode in the kernel symbol. Result stays `HPtr`.

`JsArray.unsafeSet : Int → a → JsArray a → JsArray a` — `Int` index always
unboxes; `a` element specializes:

```c
HPtr Elm_Kernel_JsArray_unsafeSet_Int  (int64_t index, int64_t  value, HPtr array);
HPtr Elm_Kernel_JsArray_unsafeSet_Float(int64_t index, double   value, HPtr array);
HPtr Elm_Kernel_JsArray_unsafeSet_Char (int64_t index, uint16_t value, HPtr array);
```

`JsArray.push : a → JsArray a → JsArray a` — specializing `a`:

```c
HPtr Elm_Kernel_JsArray_push_Int  (int64_t  v, HPtr array);
HPtr Elm_Kernel_JsArray_push_Float(double   v, HPtr array);
HPtr Elm_Kernel_JsArray_push_Char (uint16_t v, HPtr array);
```

`JsArray.slice : Int → Int → JsArray a → JsArray a` — both indices unbox; no
element axis to specialize:

```c
HPtr Elm_Kernel_JsArray_slice_Int(int64_t start, int64_t end, HPtr array);
```

`JsArray.appendN : Int → JsArray a → JsArray a → JsArray a` — `n` unboxes; no
element axis:

```c
HPtr Elm_Kernel_JsArray_appendN_Int(int64_t n, HPtr dest, HPtr source);
```

`JsArray.initialize : Int → Int → (Int → a) → JsArray a` — both `Int`
parameters unbox; closure stays `HPtr`:

```c
HPtr Elm_Kernel_JsArray_initialize_Int(int64_t size, int64_t offset, HPtr closure);
```

`JsArray.initializeFromList : Int → List a → (JsArray a, List a)` — `Int`
`max` unboxes:

```c
HPtr Elm_Kernel_JsArray_initializeFromList_Int(int64_t max, HPtr list);
```

`JsArray.indexedMap : (Int → a → b) → Int → JsArray a → JsArray b` — `Int`
offset unboxes:

```c
HPtr Elm_Kernel_JsArray_indexedMap_Int(HPtr closure, int64_t offset, HPtr array);
```

#### Json

```c
HPtr Elm_Kernel_Json_wrap(HPtr value);                                       // current
```
`Json.wrap : a → Value` admits `Int`, `Float`, `Char` instantiations:

```c
HPtr Elm_Kernel_Json_wrap_Int  (int64_t  value);
HPtr Elm_Kernel_Json_wrap_Float(double   value);
HPtr Elm_Kernel_Json_wrap_Char (uint16_t value);
```

### Variant counts

| Kernel | New variants | Primitive axes |
| --- | --- | --- |
| `List.cons` | 3 | Int, Float, Char (head) |
| `Utils.compare` | 3 | Int, Float, Char |
| `Utils.equal` | 3 | Int, Float, Char |
| `Utils.notEqual` | 3 | Int, Float, Char |
| `Utils.lt` | 3 | Int, Float, Char |
| `Utils.le` | 3 | Int, Float, Char |
| `Utils.gt` | 3 | Int, Float, Char |
| `Utils.ge` | 3 | Int, Float, Char |
| `String.fromNumber` | 2 | Int, Float |
| `JsArray.singleton` | 3 | Int, Float, Char (element) |
| `JsArray.unsafeGet` | 1 | Int (index only) |
| `JsArray.unsafeSet` | 3 | Int, Float, Char (element); index always Int |
| `JsArray.push` | 3 | Int, Float, Char (element) |
| `JsArray.slice` | 1 | Int (indices only) |
| `JsArray.appendN` | 1 | Int |
| `JsArray.initialize` | 1 | Int |
| `JsArray.initializeFromList` | 1 | Int |
| `JsArray.indexedMap` | 1 | Int (offset) |
| `Json.wrap` | 3 | Int, Float, Char |

**Total: 41 new C symbols** (excluding the unchanged AllBoxed root symbols,
which remain for genuinely polymorphic call sites).

### Out of scope — explicitly NOT requiring variants

The following AllBoxed kernels do *not* need variants, with the reason from
the audit:

- `List.fromArray`, `List.toArray`, `List.map2..map5`, `List.sortBy`,
  `List.sortWith` — no primitive parameter at the kernel's own ABI; only
  containers and closures.
- `Utils.append` — `appendable` does not include `Int`/`Float`/`Char`.
- `JsArray.empty`, `JsArray.length`, `JsArray.map`, `JsArray.foldl`,
  `JsArray.foldr` — no direct primitive parameter (length returns `Int` but
  takes `JsArray a`; the rule keys off parameter positions).

The remaining `Basics.add/sub/mul/pow` are listed in `KernelBackendAbiPolicy`
as `AllBoxed` for closure/PAP soundness, not under the five module-level
`AllBoxed` arms. They are number-polymorphic and primitive-capable, but
`kernel_abi_theory.md:385` explicitly notes that concrete `Int`/`Float` uses
are intrinsic-lowered and never reach the kernel symbol; therefore by the
audit's "currently routed through the AllBoxed C ABI" criterion they are in
a borderline state. They are listed as a follow-up note rather than required
variants (decision Q5).
