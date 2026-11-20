---
status: not-started
updated: 2026-11-20
---

# Constructor representation: follow-ups

Follow-up units to `plans/constructor-representation-levels.md` (status partial: R0–R4 done; S2, N2,
K2 remaining). The base for every measurement is snapshot `repr-KV2`: R4j plus the complete kernel
visibility table (`Compiler.IR.Kernel.Visibility.kernelUse`, 441 entries, each reviewed against its
C++; `design_docs/elm_kernel_functions.csv` records every verdict). On the self-compile that base
erases 70 wrapper types, makes 391 `Maybe` instantiations nullable, has 22 kernel-visible type
constructors, and takes 70.05 s.

This plan was written as a proposal, reviewed adversarially by two independent reviewers against the
code (compiler units; runtime and encodings), corrected, and then lowered. §8 records what the review
found and what changed.

## 0. What the plan achieves

| Unit | What it does | Who gains |
|---|---|---|
| F5 | Fixes two live array-kind bugs (`Array.set` and the boxed push relabel an array's element kind without converting its elements); then `Array.get` on an `Array Int`/`Float`/`Char` reads the raw slot instead of boxing and unboxing each element, and `JsArray` callbacks get raw elements | every program using primitive arrays; a latent use-after-free closed |
| F3 | `Debug.toString` / `Debug.log` used as function values print like direct calls (today `Ctor0 "x"`, `{ f0 = 1 }`) | `Debug` output matches Elm |
| F4 | Wrappers and `Maybe`s that are only *moved* through a type variable (shared kernel-alias specializations) can be erased or made nullable | the wrapper types and `Maybe`s excluded today for "a type-variable view", e.g. `TypeVars.Point` |
| F2 | Nullable types whose payload can itself be a constant (`Maybe String`, `Maybe (List a)`, `Maybe ()`, `Maybe (Maybe Rec)`, user `Opt Bool`) get a reserved "empty" word, so `Just x` is `x` there too; no GC change. Every nullable test becomes an exact word compare | the `Just` allocations N1 cannot reach |
| F1 | Every word of a multi-constructor union carries its constructor index in bits 43–52; one-field constructors with a boxed field become bare (no allocation). Gated by a census and two feasibility gates | `Result`, AST/parser unions, user unions |

**Order**: F5 → F3 → F4 → F2 → F1. F5 and F3 are independent. F4 does not need F3 for soundness
(user `Debug` values never pass through a kernel-alias meet), but its measurement is taken after F5
and F3. F2 builds on N1 and F4. F1 is measured after F2 and gated three times (F1-D census, F1-G
runtime cost, F1-C codegen spike).

## 1. Conventions for every unit

### 1.1 Rules

- **Expose first** (project rule): every behaviour change starts with a failing test. Where Elm
  defines the answer, record it from Elm: `node test/scripts/run-elm-e2e.js --project <name>
  --record <TestName>`. A case eco cannot yet match is marked `-- XFAIL-NATIVE: <reason>`.
- **Invariants**: read `design_docs/invariants.csv` before codegen or runtime edits; add or amend
  rows in the change that changes the rule. Next free ids today: HEAP_085, MONO_034, CGEN_089 (allocated below: F3 MONO_034; F2 HEAP_085, CGEN_089–090; F1 HEAP_086, MONO_035, CGEN_091–093).
- **Snapshots**: `benchmarks/lss-loop-snap.sh snap <name> "<note>"` before each unit and before each
  gate run; never edit the tree while a gate runs (`verify` before reading results).
- **No commits** from the container (git does not run here); the snapshots are the history.

### 1.2 Gates (run each once, output teed to a file under /tmp)

1. `cmake --build build --target elm-tests`.
2. `cmake --build build --target full`, after wiping stale caches: `build/test/*/eco-stuff`, and
   moving aside `~/.eco/0.2.0/packages/*/*/*/artifacts.dat` and the copied `eco/kernel` (memory:
   `full` clears neither).
3. MLIR identity oracle: `python3 test/scripts/dc-corpus.py mlir <dir>`, then
   `python3 test/scripts/dc-corpus.py diff <base corpus> <dir>`. Every difference is listed and
   explained in the unit's record.
4. Fixed point: `benchmarks/fe-loop-build.sh <N>` builds the candidate with the last kept compiler
   (`eco-opt-prev`). **A unit that changes the compiler's own MLIR needs a second round**: copy the
   candidate to `eco-opt-prev`, build again, and compare that build's output with the candidate's
   own self-compile (`benchmarks/fe-loop-run.sh`, which also times three cold runs).
5. `ECO_REPR_VALIDATE=1` self-compile with the final candidate: clean, output identical.
6. `cmake --build build --target bootstrap`: through Stage 8c and 9b.
7. Runtime-touching units also:
   - the TLA canary (`test/scripts/check-tla-manifest.sh /work`): a firing names models to audit
     against their MAPPING, record the verdict in their `AUDIT.md`, then `--update`; never just
     repin;
   - the heap-validate gate (memory: never a validate self-compile): the `build-validate` tree's
     unit tests, E2E, and the GC-pressure stress suite;
   - the AOT E2E (`cmake --build build --target run-aot-e2e`): new symbols must link;
   - lowering validation: a tree configured with `-DECO_LOWERING_VALIDATION=ON` (EcoPtrIntVerify is
     compiled only then), running `full`;
   - `stress-test` with a small nursery (`ECO_HEAP_CONFIG` naming a 4 MiB nursery): the default
     config runs zero minors in the stress suite.

### 1.3 Measurement

- Self-compile: `benchmarks/fe-loop-run.sh` (three cold runs), against the previous unit's kept
  compiler; noise is about 1 %.
- User programs: `node examples/benchmarks/run.mjs <workloads> --runs 10`.
- Allocations: `scripts/ctor-census-selfcompile.sh <label>` (the constructor census).

---

## 2. F5. Array element kinds: two fixes, then typed reads

### 2.1 Facts

- A `JsArray`'s element kind is `header.unboxed & 3` (0 boxed, 1 Int, 2 Float, 3 Char). The GC
  traces elements only when the kind is 0.
- **Live bug 1**: `Array.set` on an `Array Int` is forwarded (`unsafeSet` is suffix-selecting) and
  becomes the inline `eco.array.set`. `ArraySetOpLowering` (`EcoToLLVMHeap.cpp:1442-1515`) clones the
  array and calls `eco_array_set_fix_kind(copy, kind)` (`RuntimeExports.cpp:4997-5005`), which sets
  `header.unboxed = kind` without converting the existing elements. On a non-empty kind-0 copy, the
  other elements become pointer bits read as Ints, and their boxes are no longer traced
  (use-after-free).
- **Live bug 2**: `elm_array_push_box` (`JsArrayExports.cpp:753-772`) sets kind 0 over a primitive-kind
  source without boxing its elements: raw Ints traced as pointers.
- The kernel paths are correct: `bindPrimitiveKind` (`JsArrayExports.cpp:363-378`) unboxes a kind-0
  source in place; `unsafeSet` stores by kind (`:421`).
- `Array.get` (elm/core `Array.elm:269`, and `getHelp`'s `Leaf` arm `:285`) calls the alias
  `Elm.JsArray.unsafeGet = Elm.Kernel.JsArray.unsafeGet`. AliasForward keeps it (`abiFixed` false),
  so the call reaches the shared specialization and `Elm_Kernel_JsArray_unsafeGet_Int`
  (`JsArrayExports.cpp:842`, `_Int` = the index), which boxes a primitive element (`boxElement`) for
  the caller to unbox. The compiler itself does this (`LocalOpt/Typed/Case.elm:213-228`,
  `arrayGetOr` on an `Array Int`).
- `mapImpl` (`:283-287`) and `foldImpl` (`:619-625`) box each primitive element before each callback
  call, through `callUnaryMapClosureTyped` (`:209`), `callBinaryIndexMapClosureTyped` (`:177`) and
  `callBinaryFoldClosureTyped` (`:194`), whose layouts give the element kind 0.
- `eco.array.get` is declared `[Pure]` (`Ops.td:1011`), i.e. also `AlwaysSpeculatable`.
- Lowering patterns may run inside `scf` regions, which must stay single-block
  (`EcoToLLVMGlobals.cpp:28-29`): a branch inside a lowering is an `scf.if`.

### 2.2 F5a. Fix the two kind bugs (first)

1. **Tests first.**
   - `test/codegen/array_kind_set.mlir` (FileCheck, `// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s`):
     build a kind-0 `JsArray` of boxed Ints with `eco.array.push` of `!eco.value` operands (this
     lowers to `elm_array_push_box`), `eco.array.set : i64` one element, force a minor GC
     (`eco_gc_minor` or the runtime test hook used by existing codegen GC tests), then
     `eco.array.get : i64` every element and print. Expected: the values, not pointer bits.
   - The mirror case: a kind-1 array (push of `i64`), then `eco.array.push` of `!eco.value` (the
     boxed push), then read all elements boxed after a GC.
   - `test/kernel/JsArrayKernelTest.cpp`: `elm_array_push_box` onto a kind-1 array keeps every
     element readable.
2. **Fix `eco_array_set_fix_kind`** (`RuntimeExports.cpp:4997`): rename to
   `eco_array_set_bind_kind`. If the copy's kind equals the intended kind, or the copy is empty,
   set the kind as today. If the copy is kind 0 and the intended kind is primitive, unbox every
   element in place (the loop of `bindPrimitiveKind`; the copy is fresh and unshared). The function
   must not allocate (it runs between the clone and the store). Update its declaration in
   `EcoToLLVMRuntime.cpp` and the call in `ArraySetOpLowering`, and the lowering's doc comment.
   Because `runtime/src/allocator` cannot include `elm-kernel-cpp/src/core/JsArray.hpp`, add a
   runtime-side `unboxElementInPlace(Unboxable&, kind)` in `HeapHelpers.hpp` next to `boxElement`
   (`:1927`), and make `JsArray::unboxByKind` call it.
3. **Fix `elm_array_push_box`** (`JsArrayExports.cpp:753-772`): when the source kind is primitive,
   box the pushed value into the source's kind instead (unbox it: the value is a boxed primitive of
   that kind by MONO_028) and keep the kind; only an empty or kind-0 source stays kind 0. This
   mirrors `elm_array_push_*` for primitives.
4. **Invariant**: amend HEAP_046's JsArray paragraph: an array's element kind is set by its first
   store; every later store converts the value to that kind, and a kind change converts every
   element (never relabels).
5. **License manifest**: the 14 `Elm.JsArray.*` rows pin `JsArrayExports.cpp`. Add one re-audit line
   per kernel to `compiler/src/Compiler/Monomorphize/Solver/kernel-license-audit.csv`, stamped with
   `date -u +%Y-%m-%dT%H:%M:%S`, then `test/scripts/check-kernel-license-manifest.sh /work --update`.
6. **Gates**: §1.2 items 1–3, 6 and 7 (runtime change). Identity oracle: no MLIR change expected.

### 2.3 F5b. Typed `Array.get`

1. **Tests first.**
   - `test/codegen/array_get_kind.mlir`: `eco.array.get : i64` / `f64` / `i32` on a kind-0 array (built
     by the boxed push) returns the unboxed values; on a kind-1/2/3 array, the raw values.
   - `test/elm-core/src/ArrayGetPrimitiveTest.elm`: `Array.get` on `Array Int`, `Float`, `Char` built
     by `fromList`, `initialize`, `push`, `set`, `append` and `slice`, at indices below 32 and at 35+
     (`getHelp`'s leaf arm), and on an `Array (Int -> Int)` (call the result). Output recorded from
     Elm. Passes before and after.
   - `test/eco-mlir/src/ArrayGetIntInlineTest.elm`: `-- CHECK-MLIR: eco.array.get` and
     `-- CHECK-MLIR-NOT: Elm_Kernel_JsArray_unsafeGet_Int(` for `Array.get` on an `Array Int`. Fails
     before.
   - `compiler/tests/Compiler/GenerateMlir/KernelAbiTest.elm` (copy the `initialize_Int_Float` case,
     `:544-553`): `jsArrayKey "unsafeGet" [ Mono.MInt, jsArrayOf X ] X` gives
     `Elm_Kernel_JsArray_unsafeGet_Int_Int` / `_Int_Float` / `_Int_Char` with `abiResultType`
     `ecoInt` / `ecoFloat` / `ecoChar`; `X = Mono.MString` gives `Elm_Kernel_JsArray_unsafeGet_Int`;
     `X = MVar CEcoValue` gives `…_unsafeGet_Int`; `X = MVar CNumber` gives `…_unsafeGet_Int_Int`.
   - `compiler/tests/Compiler/PreMono/AliasForwardTest.elm`: copy `kernelConsModule` (`:930-945`)
     with a `qualVarExpr "Elm.Kernel.JsArray" "unsafeGet"` body: the call is forwarded.
   - `test/kernel/JsArrayKernelTest.cpp`: each `unsafeGet_Int_X` on kind 0 and on its own kind.
2. **Forward the call.** `compiler/src/Compiler/IR/Kernel/Abi.elm`: add `( "JsArray", "unsafeGet" )`
   to `suffixSelectingKernels` (`:62-87`); **not** to `boxedAbiKernels`. Update the docstring
   (`:42-61`). Effects: `AliasForward.abiFixedBy` (`:240-245`) becomes true; the subst engine keeps
   the concrete type when `isFullyMonomorphicType` holds (`Specialize.deriveKernelAbiType`
   `:5366-5395`), the solver keeps the read-back type (`Translate.deriveKernelAbiTypeKeeping`
   `:3997-4039`); a residual `JsArray a` stays boxed and the intrinsic declines on `MVar`
   (`Intrinsics.elm:716-720`). Update AliasForward's comments `:34-35` and `:548-549` ("an `abiFixed`
   kernel does not return a function" is no longer true: `unsafeGet` can return a function).
3. **Symbol choice.** `compiler/src/Compiler/GenerateMlir/KernelAbi.elm`, `kernelInstanceSymbol`
   (`:296-297`): replace `( "JsArray", "unsafeGet", [ Mono.MInt, _ ] ) -> suffixed "_Int"` by
   `suffixed ("_Int" ++ abiElementSuffix key.resultType)`, with

   ```elm
   abiElementSuffix : Mono.MonoType -> String
   abiElementSuffix t =
       case Types.monoTypeToAbi t of
           Mlir.I64 -> "_Int"
           Mlir.F64 -> "_Float"
           Mlir.I32 -> "_Char"
           _ -> ""
   ```

   (matching the ABI covers an open `number` variable, whose ABI is `i64`). Update the module and
   function docstrings (`:19-39`, `:139-146`).
4. **Kernel variants** (`elm-kernel-cpp/src/core/JsArrayExports.cpp`, beside `unsafeGet_Int` `:842`),
   reached by value references and partial applications of the alias:

   ```cpp
   int64_t Elm_Kernel_JsArray_unsafeGet_Int_Int(int64_t idx, HPtr array) {
       ElmArray* arr = static_cast<ElmArray*>(Export::toPtr(array.toBits()));
       assert(inRange(idx, arr->length) && "JsArray.unsafeGet: index out of range");
       uint32_t kind = arr->header.unboxed & 0x3;
       if (kind == 1) return arr->elements[idx].i;
       assert(kind == 0 && "unsafeGet_Int_Int: array of another primitive kind");
       return JsArray::unboxByKind(arr->elements[idx].p, 1).i;
   }
   ```

   `_Int_Float` (kind 2, `.f`, `double`) and `_Int_Char` (kind 3, `static_cast<uint32_t>(.c)`,
   `uint32_t`) likewise. None allocates. Declare them in `elm-kernel-cpp/src/KernelExports.h`
   (beside `:422`) and add `KERNEL_SYM(...)` lines in `runtime/src/codegen/RuntimeSymbols.cpp`
   (beside `:929`). `unsafeGet_Int` is unchanged (eco/system's JsArray2 forwards to it).
5. **Kind-aware inline read.** `ArrayGetOpLowering` (`EcoToLLVMHeap.cpp:1382-1425`), for an `i64`,
   `f64` or Char (`i32`) result only:
   - compute the resolved base as today (`emitResolvedBase`); load the header's first `i32`;
     `kind = (hdr >> layout::HeaderUnboxedShift) & 3` (`EcoToLLVMInternal.h:366`);
   - `scf.if (kind == expected)` → load the slot as today; `else` → `llvm.call` of
     `Elm_Kernel_JsArray_unsafeGet_Int_X(index, array)` (one kind-aware reader; declare it in the
     lowering's runtime-declaration table with the `gc-leaf-function` attribute, as it never
     allocates);
   - a `!eco.value` result keeps the plain load (an array of a non-primitive static element type is
     always kind 0).
6. **Not speculatable.** `runtime/src/codegen/Ops.td:1011`: replace `[Pure]` on `Eco_ArrayGetOp` by
   `[NoMemoryEffect]` (no `AlwaysSpeculatable`), so MLIR cannot hoist it above `Array.get`'s bounds
   check now that it may call into the kernel. Run the CSE codegen tests
   (`test/codegen/cse_pure_dedup.mlir`): CSE needs only no side effects.
7. **Policy and manifests.**
   - `compiler/tests/TestLogic/Generate/CodeGen/KernelDeclAbiPolicy.elm`: add
     `"_JsArray_unsafeGet_Int"` to `elementSelected` (`:177-187`) and update its docstring
     (`:25-30`); without it `_Int_Float`/`_Int_Char` are reported.
   - License manifest re-audit as in F5a step 5 (if F5a's re-audit is older than this edit).
8. **Facts row.** `compiler/src/Compiler/IR/Kernel/Facts.elm:909-916` (`Elm.JsArray.unsafeGet`): fix
   the stale evidence cite (`:210-223` → `:401`, `:842`). The row is keyed without suffix, so the
   `_Int_X` variants cannot be gc-leaf through it; the value-reference path keeps a statepoint
   (acceptable: it is not the hot path).

### 2.4 F5c. Raw elements to `JsArray` callbacks (C++ only)

1. **Test first**: `test/kernel/JsArrayKernelTest.cpp`: `foldl`/`map` over a kind-1 array with a
   closure compiled for `Int` and with a boxed closure (a shared-spec closure taking `!eco.value`):
   both give the right result; a count of `boxElement` calls (the allocation census or a test hook)
   is 0 for the typed closure.
2. Add an element-kind parameter to `callUnaryMapClosureTyped`, `callBinaryIndexMapClosureTyped` and
   `callBinaryFoldClosureTyped` and put it in their `EvalParamLayout` (`{elemKind}`,
   `{1, elemKind}`, `{elemKind, accKind}`). In `mapImpl` and `foldImpl`, pass `src->elements[i].bits`
   raw with `srcKind` instead of `boxElement` + kind 0. `eco_apply_closure_eval` converts an argument
   to the kind the closure's slot expects (REP_CLOSURE_002); kind-0 arguments are rooted when a
   layout is given. Re-read `src` after every call (the loops already `resolve(srcHP)`).
3. License re-audit for `foldl`, `foldr`, `map`, `indexedMap` if not already covered.

### 2.5 F5 gates and measurement

All of §1.2 (runtime change; the compiler's own MLIR changes through `arrayGetOr`, so two fixed-point
rounds). Measure `node examples/benchmarks/run.mjs ArrayBuild Dijkstra FloydWarshall Life FloodFill
KernelCallbacks DictCharPairs --runs 10` against `repr-KV2`, and the self-compile.

---

## 3. F3. Typed printing for `Debug` used as a function value

### 3.1 Facts

- A user's `Debug.toString` / `Debug.log` is `TOpt.VarDebug region name home maybeUnusedName meta`
  (`Compiler/IR/Typed/Optimized.elm:233`; built at `LocalOpt/Typed/Expression.elm:446-448`), whose
  meta type is the annotation's generic type (`a -> String`, `String -> a -> a`), with the
  annotation's variable names. `AssignMVarIds` resolves those names per node scope, so they can be
  the enclosing definition's variables (the reason `Specialize.freshenDebugAbi`, `:5320-5329`,
  exists).
- Both mono engines turn `VarDebug` into `MonoVarKernel "Elm" "Debug" name` with a boxed ABI type
  (`Translate.elm:611-614`, `Specialize.elm:2828-2835`). A saturated call prints through the type
  table (`Expr.elm:3881-3990`); a value becomes a closure over the untyped symbol
  (`generateVarKernel` → `instanceClosureResult`).
- Probe on the current compiler (identical with the passes on or off):

  | Code | Prints | Elm prints |
  |---|---|---|
  | `List.map Debug.toString [ Box "x" ]` | `["Ctor0 \"x\""]` | `["Box \"x\""]` |
  | `List.map Debug.toString [ { n = 1 } ]` | `["{ f0 = 1 }"]` | `["{ n = 1 }"]` |
  | `List.map Debug.toString [ Just (A 3) ]` | `["Ctor0 (Ctor0 3)"]` | `["Just (A 3)"]` |
  | `List.map2 Debug.log [ "l" ] [ A 2 ]` | `l: 2` | `l: A 2` |
  | `List.map show [ Box "x" ]`, `show : a -> String`, `show = Debug.toString` | `["Box \"x\""]` | same |

  The last row is a top-level definition: mono specializes `show` at `Box String`, and its generated
  function has a concretely typed parameter.

### 3.2 Design

A new pre-mono pass `Compiler.PreMono.TypedDebugValues`, always on (a correctness fix), run in
`Steps.preMono` after η-expansion and before the pre-mono inliner. In every expression of every node
(`Define`, `TrackedDefine`, `Cycle` bodies, ports), bottom-up:

| Shape (where `D tag` is `TOpt.VarDebug r tag home u m`) | Rewritten to |
|---|---|
| `Call r (Call r2 (D "log") [ l ] _) [ x ] m` | `Call r (D "log") [ l, x ] m` (flatten; no lambda) |
| `D "toString"`, not the function of a `Call` | `\_dbgN -> Debug.toString _dbgN` |
| `D "log"`, not the function of a `Call` | `\_dbgN _dbgM -> Debug.log _dbgN _dbgM` |
| `Call r (D "log") [ l ] m` (one argument) | `\_dbgN -> Debug.log l _dbgN` if `l` is trivial (a literal, local or global); else `let _dbgL = l in \_dbgN -> Debug.log _dbgL _dbgN` (evaluated once: `l` may itself call `Debug.log`) |

Not rewritten: saturated calls; `Debug.todo` (prints only its message).

Construction (copy `EtaExpand`'s helpers, `EtaExpand.elm:486-532`, `:1871`, `:1978-1996`):
1. **Freshen** the reference's type variables first: `Fresh.freshenType` with an empty substitution
   on `m.tipe` (as `Specialize.freshenDebugAbi` does for the kernel type). Without this, the
   lambda's binder shares the enclosing definition's `a`/`number` and is specialized at the wrong
   type.
2. Binder types are the freshened `TLambda` spine's parameters, `clearArrows`ed; the wrapper's meta
   is `{ tipe = clearArrows freshened, tvar = Nothing }`; the inner `VarDebug` gets the freshened
   type as its meta; argument references are `TOpt.VarLocal name { tipe = paramType, tvar = Nothing }`.
3. Binder names come from a counter in the pass's state, `_dbg<n>`, unique per run (the
   `PreMonoBinderHygiene` test runs `preMono` twice and checks hygiene and determinism).
4. The new `Function` (and `Let`, `Def`) is passed through `Fresh.mintNewNode` (fresh `SrcLambdaId`,
   arrow ids).

Mono then specializes each lambda at the type its context gives: in argument position the engines
resolve a pending lambda against the callee's parameter type, so the body is a saturated call at a
concrete type and prints typed.

**Limitation (kept, tested, documented).** Where the context does not fix the type — a let-bound
`f = Debug.toString` used later, a record field, a list element, an `if` branch — the binder may stay
a residual type variable (MONO_021) and the body prints untyped, as today. These cases get
`-- XFAIL-NATIVE:` tests so the gap is visible.

### 3.3 Steps

1. **Tests first.**
   - Extend `test/elm/src/DebugToStringAsValueTest.elm` with the four failing probe rows, a partial
     `List.map (Debug.log "x") [ A 1 ]`, `(Debug.log "y") (A 2)`, `A 3 |> Debug.log "p"`, and a
     `Debug.toString` value inside a function with its own `a` and `number` variables instantiated at
     another type. Record from Elm.
   - `test/elm/src/DebugValueContextTest.elm`: let-bound, record-field, list-element and `if`-branch
     uses, recorded from Elm, `-- XFAIL-NATIVE: F3 limitation` where eco still prints untyped.
   - `compiler/tests/Compiler/PreMono/TypedDebugValuesTest.elm`: real source through `runToTypedOpt`
     (so the input has genuine `VarDebug`s): each rule's output shape; the flattened double call;
     the let-bound label; the freshened variables differ from the enclosing definition's; minted ids
     pass `Fresh.assertMinted`; run the pipeline under `productionConfig` (solver) and `stage5Config`
     (subst).
   - `test/eco-mlir/src/DebugValueTypedTest.elm`: `-- CHECK-MLIR-NOT: @Elm_Kernel_Debug_toString(`
     for a value use in argument position.
2. **The pass**, `compiler/src/Compiler/PreMono/TypedDebugValues.elm`:
   `run : AssignMVarIds.GlobalMVarState -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )`,
   `type alias Metrics = { rewritten : Int, flattened : Int }`. The walk mirrors EtaExpand's node
   walk (every node kind that holds an expression, Cycle bodies included).
3. **Wiring**: `compiler/src/Compiler/Pipeline/Steps.elm`, `preMono` (`:180-220`): call it after the
   η-expansion step, unconditionally; add `debugValues : TypedDebugValues.Metrics` to `PreMono`.
   `compiler/src/Builder/Generate.elm`, `runMonoOptPipeline`: write
   `pre-debug-values: rewritten=… flattened=…` under `inline.report`. The `*NoPreMono` test runners
   (`TestPipeline.elm:578-583`) skip `preMono` and so skip F3; say so in their docstring.
4. **Collateral**: `test/elm-conformance/src/ArrayMapDebugLogKindTest.elm` builds its kind-0 array with
   a point-free `Debug.log`, which F3 types; update its docstring (it no longer builds kind 0, F5a's
   MLIR tests cover kind 0).
5. **Invariant**: a `documented` row MONO_034: a
   `Debug.toString`/`Debug.log` value whose type the context fixes reaches codegen as a saturated
   typed call.
6. **Gates**: §1.2 items 1–3, 5–6. Identity oracle: only programs with `Debug` values differ. The
   compiler has no `Debug` (built with `--optimize`): one fixed-point round.

---

## 4. F4. Type-variable views that only move values

### 4.1 Facts

- Three checks keep a representation for any meet of a value with a type variable:
  `EraseWrappers.choose`'s `meetsVar` (`EraseWrappers.elm:713-731`), `consistentWith`'s `kindClash`
  (`:448-452`), `NullableMaybe.choose`'s `excluded` (`NullableMaybe.elm:350-372`). And
  `RepresentationMeets.validate` (run by `Steps.representation` under `mono.validate` or
  `repr.validate`, `Steps.elm:528-542`) reports any interior meet with different slot kinds
  (MONO_029) and any nullable type meeting another view (MONO_033).
- On `repr-KV2`, `TypeVars.Point` has 418 type-variable meets: 417 `global->N` meets where node N is
  `MonoDefine (MonoVarKernel …)`, the shared specialization of a kernel alias (`Elm.JsArray.*`,
  `Basics.append`); one `callArg` in `Compiler.PreMono.EtaExpand.apply`. Both engines build kernel
  aliases as `MonoDefine (MonoVarKernel …)` (`Solver/Monomorphize.elm:4152-4158`; subst
  `specializeExpr`).
- Every meet is built by `splitAt` (and `split`), including those `translate` rebuilds.
- `KernelVisible`'s roots are kernel call and kernel-value types; it never follows a `global->N` meet
  back to the use site. So a type reaching an *unlisted* kernel through a shared alias is not
  kernel-visible: the type-variable rule is its only protection.
- User `Debug` values are direct `MonoVarKernel` references, never `global->N` meets, so F4 cannot
  expose them; `Debug` is listed `Transparent`, so the rule must still exclude `Debug` explicitly.

### 4.2 Why a move-only view is safe

Take a meet whose node-side type is an `MVar`, at a `global->N` site where N is
`MonoDefine (MonoVarKernel _ _ home name _)`, K = `(home, name)` is in `Visibility.kernelUse`, and
`home /= "Debug"`:
- **Contents**: a listed kernel never looks inside a value of a type variable (the review's
  definition); generic walkers (`Utils.equal`, `compare`, `FNV.hash`) give the same answer erased or
  not, because every view of a value shares one representation (MONO_029).
- **Slot kinds**: a single value crosses into `a` boxed (REP_ABI_001); containers carry slot kinds
  that these kernels read and convert at run time (HEAP_046, and F5a for arrays). `List Float` and
  `Array Int` already take this path, and an erased `Int` wrapper is an `MInt` before any symbol
  choice or codegen.

### 4.3 Steps

1. **Tests first.**
   - `test/elm/src/EraseWrapperMoveOnlyTest.elm`: `type P = P Int`, `type Q = Q Float`,
     `type Box = Box { n : Int }`; stored in `Array`s (`get`, `set`, `push`, `foldl`, `map`, `slice`,
     `append`) and in lists joined with `++`; compared with `==`; printed with `Debug.toString`.
     Output recorded from Elm. Plus `-- CHECK-MLIR-NOT:` of `P`'s construction (a
     `eco.construct.custom` carrying `P`'s census id, or `@TestMod_P` constructor node; choose the
     pattern the existing `EraseWrapperFloatTest` MLIR shows).
   - `compiler/tests/Compiler/MonoOpt/EraseWrappersTest.elm`: a wrapper met only through a move-only
     `global->` meet of a `Transparent` alias is erased; through an alias of an unlisted kernel
     (build one with `kernelCall` of a name absent from the table) it is not; through a `local` or
     `callArg` meet with an `MVar` it is not.
   - `compiler/tests/Compiler/MonoOpt/NullableMaybeRunTest.elm`: a `List (Maybe Rec)` met as `List a`
     through a move-only alias becomes nullable; a `Maybe Rec` met as `Maybe a` does not.
   - An elm-test running the pipeline with `repr.validate` on the move-only fixture: no violation.
2. **`RepresentationMeets`** (`compiler/src/Compiler/Monomorphize/RepresentationMeets.elm`):
   - `type Via = ViaKernelAlias String String | ViaOther`; `Meet` gains `via : Via`.
   - `splitAt` and `split` take `via` and copy it to every meet they produce. In `exprMeets`, the
     `MonoVarGlobal _ specId t` arm looks the node up (a second lookup beside `nodeTypeOf`: add
     `nodeOf : Int -> Maybe Mono.MonoNode` to `collect`) and passes
     `ViaKernelAlias home name` when the node is `MonoDefine (MonoVarKernel _ _ home name _) _`, else
     `ViaOther`. Every other arm passes `ViaOther`. `translate` passes `m.via` through.
   - `movesOnly : Meet -> Bool`: `via = ViaKernelAlias home name`, `home /= "Debug"`,
     `Dict.member ( home, name ) Visibility.kernelUse`, and the meet's **node side** (`m.b` for a
     `global->` meet, which `splitAt` builds as `splitAt site useType nodeType`) is an `MVar`.
   - `validate`: skip a meet for which `movesOnly` holds, in both the MONO_029 and MONO_033 branches.
   - Update `RepresentationMeetsTest` (meets now carry `via`).
3. **`EraseWrappers`**: in `choose`, the `meetsVar` fold skips `movesOnly` meets; in `consistentWith`,
   `drops m` returns `[]` when `movesOnly m`. Add `excludedMeetsVarMoveOnly` (meets skipped) to
   `EraseStats` and `renderStats`.
4. **`NullableMaybe`**: in `choose`, the `excluded` fold skips `movesOnly` meets.
5. **Census line**: `Steps.representation`, under `inline.report`, writes
   `repr-meets-var: <kernel or other>=<count> …` for the type-variable meets (whether skipped or
   not), so the remaining blockers (such as `Point`'s `callArg`) are visible.
6. **Invariants**: amend MONO_029 and MONO_033 (the move-only exemption, its exact conditions, and
   that `RepresentationMeets.validate` applies it) and MONO_032 (kernel visibility does not follow
   alias meets; the move-only rule's exclusion of unlisted kernels covers that case).
7. **Gates and measurement**: all of §1.2 (two fixed-point rounds). Re-take the baseline counts on
   the post-F5/F3 tree first (F5 makes `unsafeGet` calls concrete, which removes some of the 417
   meets). Report wrapper types erased, `Maybe`s made nullable, the census, wall. `Point` stays
   excluded while its `callArg` meet is `ViaOther`; the census line shows what it is, for a possible
   follow-up rule.

---

## 5. F2. A reserved "empty" word, and exact nullable tests

### 5.1 Facts

- N1a's `Maybe T` admits `T` by shape (`NullableMaybe.admissible`, `:54-90`): any non-`Maybe`,
  non-kernel-owned custom passes. Its null test is `eco.get_tag == CONSTANT_TAG`
  (`Patterns.elm:186`), and `get_tag` reports CONSTANT_TAG for any word whose constant field is 2;
  the printer's Nullable arm uses `isEmptyBits && !isNullConsBits` (`RuntimeExports.cpp:4326`).
- N1b's test is `eco.is_constant` (`Patterns.elm:172-181`); D2 restricts its payload to types
  without constants (`admissibleNoConstants`).
- Bits 43–52 are 0 in every word except null-cons words (constant field 3), whose only producers are
  `nullConsWordFor` and `value_enc::encodeNullCons`. The GC, the validators and `Export::toPtr` skip
  or null-map any `ptr_ind` word.
- `Nothing` and nullary user constructors are produced at: `Functions.elm:1473-1490` (a constructor
  node's body: `ecoConstantNothing` / `ecoConstantNullCons`), `Expr.elm:806-830` (the
  `nullConsBySpec` and `constCtorBySpec` reference caches, also used by const-thunk alias chains,
  `ConstThunks.elm:20-24`), and `BytesFusion/Emit.elm` (`ecoConstantNothing`, safe only while
  `Bytes.decode`'s `Maybe` is kernel-visible).
- Equality compares constants by whole word (`UtilsExports.cpp:105`, `Utils.cpp:81`) except an
  Empty-vs-zero-length-String rule that uses `isEmptyBits` (`UtilsExports.cpp:107-108`,
  `Utils.cpp:84-89`, `compareUnboxableSlot`). FNV hashes anything `isEmptyBits` as Empty
  (`FNVExports.cpp:103`). `eco.value.eq`'s fast path tests exactly `0x6` (`EcoBackend.cpp:2356-2361`).
- EcoPtrIntVerify's `isEmbeddedConstant` (`EcoPtrIntVerify.cpp:48-56`) accepts only 0x4–0x6 as
  `inttoptr` constants that end up as instructions.
- `TKNullable`'s descriptor is packed by `EcoToLLVMGlobals.cpp:386-392`
  (`null_name | (constantBitTest ? 0x80000000 : 0)`).

### 5.2 Design

- **Null word of a nullable type**: `Empty` (N1a, payload never a constant), the null-cons word (N1b,
  payload never a constant), or the **spare word of level k**: `0x6 | (k << 43)`, k in 1–127.
- **Levels**: `k = 1 + level(payload)`, where `level(T)` is T's own k if T is a spare-word nullable
  type, and 0 otherwise. A payload type that is nullable with Empty or null-cons null words counts
  as "can be a constant" (its null word is a constant), so `Maybe (Opt Bool)` and `Maybe (Maybe Rec)`
  get spare words. `Maybe (Maybe String)`: inner level 1, outer level 2.
- **Admissibility** (core `Maybe` and user types alike): any payload except `Int`/`Float`/`Char`,
  `MVar`, kernel-owned and kernel-visible instantiations, payloads at level 127, and candidates
  meeting another view (F4's move-only meets excepted). A payload that can be a constant (String,
  List, `()`, `{}`, Bool, an enum or a custom with nullary constructors, a nullable type) gets a
  spare word; otherwise today's encoding.
- **Exact tests for every nullable type**: the null test is `eco.is_word v W` with W the type's null
  word, for N1a, N1b and spare words alike (this replaces the `get_tag` and `is_constant` tests, which
  misread a spare word as Empty or as a constant). The printer's Nullable arm compares the exact
  word.
- **Exact Empty in equality**: the Empty-vs-zero-length-String rule tests the exact Empty word
  (`isExactEmptyBits(b) = b == 0x6`), in `UtilsExports.cpp:107-108`, `Utils.cpp:84-89` and
  `compareUnboxableSlot`. FNV's `isEmptyBits` hashing is left as is (a collision between `Nothing`
  and `Just ""`, resolved by equality).

### 5.3 Steps

1. **Tests first.**
   - `test/elm/src/NullableSpareWordTest.elm`: `Maybe String` (with `Just ""`), `Maybe (List Int)`
     (with `Just []`), `Maybe ()`, `Maybe {}`, `Maybe (Maybe (Maybe String))` at all three levels,
     user `type Opt a = None | Some a` at `Opt Bool`, `Opt Color` (an enum) and `Opt String`, and
     `Maybe (Opt Bool)`, `Maybe (Opt String)`. Each through `case`, `Maybe.map`, `withDefault`,
     `==`, as `Dict` values, `Debug.toString`; produced as a top-level `x = Nothing`, returned from a
     function, and through `List.map (always Nothing)`. Output recorded from Elm.
   - `test/codegen/spare_word.mlir`: `eco.constant.spare` and `eco.is_word` lower and run, including
     a `select` of two such constants (EcoPtrIntVerify path).
   - `compiler/tests/Compiler/MonoOpt/NullableMaybeTest.elm`: admissibility of each new payload; the
     levels; `Maybe (Opt Bool)` is level 2.
2. **Ops** (`runtime/src/codegen/Ops.td`, `compiler/src/Compiler/GenerateMlir/Ops.elm`):
   - `eco.constant.spare {level : i32} -> !eco.value` (`Pure`; verifier: level in 1–127), lowered in
     `EcoToLLVMTypes.cpp` beside `ConstantNullConsOpLowering` (`:75-100`) as `inttoptr` of
     `0x6 | (level << 43)` (add `value_enc::encodeSpare(level)` in `EcoToLLVMInternal.h`);
   - `eco.is_word (!eco.value) {word : i64} -> i1` (`Pure`), lowered in `EcoToLLVMControlFlow.cpp`
     beside `IsConstantOpLowering` (`:176-194`) as `icmp eq ptr addrspace(1) %v, inttoptr(word)`.
   - `Passes/EcoPtrIntVerify.cpp:48-56`: `isEmbeddedConstant` also accepts null-cons and spare
     patterns (constant field 3; constant field 2 with bits 43–49 in 1–127 and no other bits).
   - New rows CGEN_089 (`eco.constant.spare`) and CGEN_090 (`eco.is_word`).
3. **Choice** (`compiler/src/Compiler/MonoOpt/NullableMaybe.elm`):
   - `admissible` and `admissibleNoConstants` merge into one `admissible : ... -> MonoType -> Maybe
     Encoding` with `type Encoding = EmptyWord | NullConsWord | SpareWord` (SpareWord when the
     payload can be a constant);
   - after the candidate set is fixed (exclusions applied), compute levels bottom-up over nesting;
     `Info` and `Mono.NullableInfo` (`Mono.elm:3125`) gain `nullWord : Int` (the exact word) and keep
     `constantBitTest` only as long as the printer reads it (remove it in this unit).
4. **Codegen** (`compiler/src/Compiler/GenerateMlir`):
   - `Patterns.elm:167-185`: the null-constructor test becomes `eco.is_word valVar info.nullWord`
     for every nullable type;
   - the null value: in `Functions.elm:1473-1490` (constructor nodes), `Expr.elm:806-830` (the
     `nullConsBySpec`/`constCtorBySpec` caches and their const-thunk uses) and the nullable
     construction paths (`Expr.elm:3572` `nullableValueCall`, `:6495`), emit `eco.constant.spare`
     when `nullWord` is a spare word;
   - a codegen assertion (crash with a message): a nullable type whose `nullWord` is a spare word
     never receives `eco.constant` Empty or `eco.constant.null_cons` as its nullary value.
5. **Type table and printer**: `TypeTable.elm:70`, `:527-560` (`TKNullable` gains the null word's
   level, 0 for Empty/null-cons); `EcoToLLVMGlobals.cpp:386-392` packs it into bits 24–30 of
   `null_name` (assert the string index is below 2^24); `TypeInfo.hpp` documents it;
   `RuntimeExports.cpp:4320-4340` computes `isNull` as `value == nullWord` (Empty, the null-cons word
   for `null_name`'s constructor, or `spareWordFor(level)`).
6. **Runtime**: `Heap.hpp`: `spareWordFor(k)`, `isSpareWord(b)`, `isExactEmptyBits(b)`, and the
   encoding's documentation; the equality changes of §5.2 in `elm-kernel-cpp/src/core/UtilsExports.cpp`
   and `Utils.cpp` (license re-audit for the pinned rows).
7. **Census**: `CtorCensus.payloadClass` gains `spare` for a one-field constructor of a spare-word
   type.
8. **Invariants**: new HEAP_085 (spare words: encoding, levels 1–127, only compiled code of a
   spare-word nullable type produces them, every runtime classifier treats them as constants);
   amend HEAP_044 (`null_cons_idx` is non-zero in null-cons words and in spare words),
   REP_CONSTANT_003 and MONO_033 (exact-word tests, the new admissibility), CGEN_087 (`is_constant`
   no longer used for nullable tests).
9. **Gates and measurement**: all of §1.2 (two rounds; every nullable program's MLIR changes, from
   `get_tag`/`is_constant` tests to `is_word`: list them as such in the identity-oracle record).
   Census: `Just` allocations still allocated, by payload class; `node examples/benchmarks/run.mjs
   JsonDecoders CsvParser Lexer WordFreq --runs 10`.

---

## 6. F1. Tagged words for multi-constructor unions

### 6.1 Design

Every word of a tagged type T carries its constructor's declaration index in bits 43–52:

| Constructor form | Word |
|---|---|
| `Nullary` | the null-cons word (HEAP_044: its index is already in bits 43–52) |
| `Bare` (one field, see below) | the field's word with the index ORed into bits 43–52 |
| `Boxed` (anything else) | a `Custom` on the heap; its pointer with the index ORed in (index 0 leaves it unchanged) |

So `index = (word >> 43) & 1023` for every value of T. A field is bare-eligible when its type is a
boxed type whose words always have bits 43–52 zero: not `Int`/`Float`/`Char`, not a type with
nullary constructors (null-cons words), not a nullable type (spare and null-cons words), not a type
F1 tags. Constants (String, List, Bool, `()`) are allowed: a bare `A ""` is `0x6 | (idx << 43)`,
distinct within T from every other constructor.

**T is not tagged when** (MONO_035): it is kernel-owned or kernel-visible; it has more than 1,023
constructors; it is nullable; it is **the payload of any nullable type** (N1a, N1b, F2: their tests
and their `Just x = x` read T's words in their own encoding — a bare `A ""` at index 0 is exactly
0x6, and `Maybe T`'s tests would read T's tags as their own); it meets another view other than
move-only (F4); it is passed through sret, psplit or aggPromote (they pass a value as loose fields,
with no word to tag — excluded the way nullable types are, `Expr.elm:6495`); or a fixpoint step makes
one of its would-be-bare fields tagged.

### 6.2 F1.0 Census and gate F1-D (first)

1. `compiler/src/Compiler/MonoOpt/TaggedUnions.elm` (new) with `choose : ... -> TagChoice`, run in
   report-only mode (no graph change) by `Steps.representation` when `ECO_CTOR_CENSUS` is set.
2. `compiler/src/Compiler/GenerateMlir/CtorCensus.elm`: a new column `tagged` for every constructor
   of a type with two or more constructors: `nullary`, `bare`, `alloc-unboxed`, `alloc-constant-type`,
   `alloc-nested`, `alloc-fields`, `excluded-<reason>` (the MONO_035 reason), from `TagChoice`.
   The TSV header and `render` gain the column.
3. `scripts/ctor-census.py`: `--by tagged`, and several counts files summed.
4. `benchmarks/ctor-census-bench.sh` (new): compile `examples/benchmarks/src/Bench.elm` with
   `ECO_CTOR_CENSUS=<dir>/table.tsv` (native `eco make src/Bench.elm --output=<bin>` in
   `examples/benchmarks`), list workloads with `<bin> --list --json`, run each with
   `ECO_CTOR_CENSUS_OUT=<dir>/counts-<name>.tsv <bin> --json --warmup 0 --runs 1 <name>=<size>`, and
   print `ctor-census.py --by tagged` over all counts.
5. **Gate F1-D**: build F1 only if `bare` (not excluded) allocations are at least 5 % of all custom
   allocations in the self-compile or in the benchmark aggregate, measured after F2. Record the
   result in §9 either way.

### 6.3 F1.1 Runtime tolerance and gate F1-G

No compiler change; the runtime accepts tagged heap words everywhere one can sit.

1. **Tests first** (`test/allocator`): build objects whose fields, closure captures, list heads,
   kind-0 array elements, stack-range roots, long-lived roots, JIT/CAF roots and stack-map roots hold
   `addr | (idx << 43)` words; run a serial minor, a parallel minor, a region minor, a tenuring minor,
   a major, and CAF promotion; check every word still names the right (moved) object **with its
   tag**. They fail today (tags dropped; JIT roots skipped).
2. `runtime/src/allocator/Heap.hpp`: `TAG_SHIFT = 43`, `TAG_MASK = 0x3FFULL << 43`, `wordTag(bits)`,
   `retarget(HPointer old, void* newAddr)` (= `toPointerRaw(newAddr)` with `old`'s bits 43–52).
3. Every write-back uses `retarget` (the old word is in hand at each):
   - serial minor: `NurserySpace.cpp:1220`, `:1334`, `:1353-1355`, list spine `:1814-1822`,
     `:1906`, `:1910`;
   - parallel minor: `NurseryParallel.cpp:350`, `:357`, `:368-370`, `:429`, `:444`;
   - region minor: `NurseryRegion.cpp:551`, `:558`, `:585`, `:661`, `:675`, `:949-951`, and the Hand
     slots healed at merge (`:570-571`);
   - tenure: `TenureWork.hpp:538` (`TenureHeapEnv::word(obj)` becomes `word(oldWord, obj)`, the
     contract at `:257`), `NurseryTenure.cpp:91-96`, `:1131`, `:1159`, `:1163`, `:803-807`, `:845`,
     `:867`; also `test/gc-helper-tsan/tenure_harness.cpp:249` and the GenMC drivers
     `test/genmc/w5_forwarding.cpp`, `w_running_chain.cpp`, which implement the `Env` contract;
   - CAF promotion: `PermanentSpace.cpp:186`, `:202`;
   - test-only compaction: `OldGenSpace.cpp:6786-6795` (`fixHPointer`).
4. Raw root paths decode through `hpToAddr` before the heap-range test and write back with
   `retarget`: `evacuateJitPtr` (`NurserySpace.cpp:1338-1356`), `evacuateRawP`
   (`NurseryParallel.cpp:362-371`), the region JIT-root loop (`NurseryRegion.cpp:944-951`),
   `markJitRootRaw` (`OldGenSpace.cpp:2876-2884`), `traceOldReachableForValidation`
   (`ThreadLocalHeap.cpp:1373-1377`).
5. `Export::toPtr` (`elm-kernel-cpp/src/ExportHelpers.hpp:50-64`): mask with `hpToAddr` before
   `isInHeap`.
6. **Equality and hashing compare tags** where a word is still in hand (an address-level `eqHelp`
   cannot see them): `equalRespectingConstants` (`UtilsExports.cpp:99-111`), `resolveAndCompare`,
   `eqUnboxableSlot`, `dictEq` and the list-cursor head comparisons (`Utils.cpp`), `FNVExports.cpp`
   `boxed()` (mix the tag in), and `eco.value.eq`'s fast path (`EcoBackend.cpp:2296-2400`): a word
   with bits 43–52 set and `ptr_ind` clear goes to the kernel arm. Audit the ~50
   `Allocator::wrap`/`Export::fromPtr` sites in `elm-kernel-cpp` and `system-kernel-cpp` for re-wraps
   of an existing element (which would drop a tag); record the audit.
7. **Validate-build asserts**: in `eco_get_tag`, `eco_resolve_hptr`, `eco_follow_forward` and
   `eco_custom_get_*` (the out-of-line compiled-code entry points, `ECO_INLINE_DEREF_EXT=0`), under
   `ECO_HEAP_VALIDATE`, assert that a heap word has bits 43–52 clear (F1 never routes a tagged word
   there; a missed site must fail loudly, not read the field's object).
8. **TLA canary**: it fires for regions NP.evacuateP, NP.spineRunP, NP.minorGCParallel,
   NR.evacuateR, NR.spineRunR, NR.minorGCRegion, NT.TenureHeapEnv, NT.TenureParEnv, NT.mergeJob and
   the file pin `TenureWork.hpp` (models M1–M5, GenMC W5, w_running_chain). Audit each against its
   MAPPING (M3's A2: "slots are whole words, owner-only"; a tag-preserving store is the same abstract
   action), record the verdict and hash prefix in each `AUDIT.md`, then `--update`.
9. **Invariant**: HEAP_086 (tagged words: encoding; producers; every GC write-back keeps bits 43–52;
   kernels other than the generic walkers never receive them).
10. **Gate F1-G**: all runtime gates of §1.2 item 7, and the self-compile's GC time and wall within
    noise of the base (no tagged words exist yet: this is the cost of tolerance).

### 6.4 F1.2 Codegen spike and gate F1-C

Three ops, emitted only for tagged types (`runtime/src/codegen/Ops.td`):
- `eco.word_tag (!eco.value) -> i16`: `(ptrtoint v >> 43) & 1023`, a same-block `ptrtoint` (allowed,
  REP_LLVM_001(d));
- `eco.tag_word (!eco.value) {index : i16} -> !eco.value`: `getelementptr i8, ptr addrspace(1) %v,
  i64 (index << 43)` (a derived pointer; the stack-map scanner treats each slot as an independent
  root and, after F1.1, keeps its tag);
- `eco.untag (!eco.value) -> !eco.value`: `llvm.ptrmask.p1.i64(%v, ~TAG_MASK)`.

The spike, in a tree configured with `-DECO_LOWERING_VALIDATION=ON`:
1. `test/codegen/tagged_words.mlir`: tagged values (bare over a record, boxed over a `Custom`,
   index 0 and 5) live across calls that collect (a tiny nursery via `-- ENV:`-style
   `ECO_HEAP_CONFIG` in the RUN line), then `eco.word_tag` and `eco.untag` + projection; output
   checked.
2. RS4GC accepts both patterns; EcoPtrIntVerify accepts them once a blessed pattern is added for
   `llvm.ptrmask` and the tagging GEP (amend REP_LLVM_001 and FORBID_HEAP_002 accordingly).
3. **Gate F1-C**: the test passes in both the default and the validation tree; otherwise F1 stops
   (record why in §9).

### 6.5 F1.3–F1.6 Build

1. **Tests first** (recorded from Elm):
   - `test/elm/src/TaggedUnionTest.elm`: a type with nullary, bare, unboxed-field and multi-field
     constructors; `Result String Rec`; a recursive type; values in records, lists, arrays, `Dict`
     values, closures, CAFs (a top-level value), constructors used as functions
     (`List.map A xs`); `case`, `==` (`A s == B s` is `False` for one payload), `Debug.toString`;
     `-- ENV:` lines for a 4 MiB nursery and `ECO_GC_STATS`-style output checked for at least one
     minor and one major (`-- CHECK:` on the stats line).
   - The same test run once with `-- ENV: ECO_INLINE_DEREF_EXT=0`.
   - `Maybe T` with a tagged-candidate `T`: T must not be tagged (census reason `nullable-payload`).
2. **F1.3 choice** (`TaggedUnions.choose`, now applied): `repr.tagged : LayoutMap TagInfo`,
   `TagInfo = { forms : List CtorForm }`, `CtorForm = Nullary | Bare | Boxed`, decided after erasure
   and after the nullable choice, iterating to a fixpoint (a field type chosen as tagged makes its
   holder's constructor `Boxed`; a type that loses all `Bare` constructors is dropped). Exclude
   tagged types from sret (`Backend.sretInfoOf`), psplit (`Backend.psplitOnePass`), aggPromote
   (`Expr.promotableCtorCall`) and ctorInline (`Expr.tryCtorInline`), as nullable types are.
3. **F1.4 codegen**: every construction site emits the tagged form — `Functions.elm:1576`
   (`generateCtor`, constructor values), `Functions.elm:1138` (`sretShimConstruct`; excluded types
   never reach it, assert), `Patterns.elm:411` (`materializeSplitParam`; same), `Expr.elm:7399`, and
   the general construct path in `Expr.elm`: `Bare` → `eco.tag_word field idx`; `Boxed` →
   `eco.construct.custom` then `eco.tag_word` when idx > 0; `Nullary` → the null-cons word. Tests
   and `case` on a tagged type use `eco.word_tag` (`Patterns.generateCtorTagTest` and
   `eco.case` scrutinee lowering: emit the tag as an `i16` scrutinee, as for null-cons); projection:
   `Bare` → `eco.untag`; `Boxed` → `eco.untag` then `eco.project.custom`. KnownCtorCase (default off)
   and BytesFusion (kernel-visible types only) need no change; assert they never see a tagged type.
4. **F1.5 printing**: type-table kind 9 `Tagged` (`TypeInfo.hpp` `EcoTypeKind`, appended; the
   compiler's `TypeTable` mirrors it), sharing `custom`'s `{first_ctor, ctor_count}` payload, with a
   per-constructor bare flag in the high bit of `EcoCtorInfo.field_count`;
   `EcoToLLVMGlobals.cpp` packs it. `print_typed_value` (`RuntimeExports.cpp:3897`) gains a `Tagged`
   arm: read the index from the word, find the constructor, print its name and the untagged field
   (`Bare`), the name (`Nullary`), or the untagged `Custom` (`Boxed`).
5. **F1.6 invariants**: MONO_035 (the choice rules of §6.1), CGEN_091–093 (the three ops and their
   blessed patterns), amend HEAP_044, HEAP_086, FORBID_HEAP_001/002, REP_LLVM_001,
   REP_CONSTANT_001/002.
6. **Gate F1-W**: all of §1.2; on the self-compile and the benchmarks, allocations fall by at least
   the census's prediction for `bare` constructors, and wall does not regress.

---

## 7. Decisions

- **D1** (2026-11-20): F3 rewrites `Debug` values into lambdas before mono, with freshened type
  variables. Alternatives: kernel variants taking a type id first (codegen builds a partial
  application that captures the id; kept as the fallback if the rewrite cannot reach some uses); an
  optional type id on the existing symbols (rejected: every kernel-closure path would need a
  `Debug` special case, against the separate-symbol decision in `DebugExports.cpp`).
- **D2** (2026-11-20): F5 makes the inline `eco.array.get` kind-aware (with an `scf.if` slow path into
  the kernel variant) rather than declining the intrinsic for primitive elements, so the hot path
  stays a load; the two live kind bugs are fixed first (F5a).
- **D3** (2026-11-20): F2 precedes F1: it needs no GC change, and F1's census then counts only what
  F2 cannot reach. Every nullable test becomes an exact word compare (needed once spare words exist).
- **D4** (2026-11-20): F1 masks with explicit ops at the sites the compiler emits for tagged types,
  not in `expandInlineDerefs`. This holds only together with MONO_035's exclusions (no tagged type
  is a nullable payload, or reaches sret/psplit/aggPromote/ctorInline); validate-build asserts in the
  out-of-line entry points catch a missed site.

## 8. Adversarial review record (2026-11-20)

Two reviewers read the proposal against the code. Findings and how the plan changed:

| # | Severity | Finding | Change |
|---|---|---|---|
| 1 | blocker | F3 matched `VarKernel "Debug"`; user code holds `TOpt.VarDebug` | §3 restated over `VarDebug`; the alias exclusion dropped |
| 2 | blocker | F3's binder types would capture the enclosing definition's type variables | freshen with `Fresh.freshenType` first; tests under both engines |
| 3 | blocker | `RepresentationMeets.validate` would reject every meet F4 skips | `validate` applies `movesOnly`; elm-test with `repr.validate` |
| 4 | blocker | under core `Maybe`, a spare word reads as `Nothing` (`get_tag`/`isEmptyBits`) | every nullable test becomes an exact word compare; nullable payloads count as "can be a constant" |
| 5 | blocker | D4 refuted: `Maybe T` with a tagged T dereferences T's word unmasked, and `A ""` at index 0 equals `Nothing` | MONO_035: a nullable payload is never tagged |
| 6 | major | `eco.array.set` relabels a kind-0 copy's kind without converting (live); `elm_array_push_box` the reverse | new F5a fixes both first, with tests |
| 7 | major | the kind branch cannot be new blocks inside a lowering (`scf` regions) | `scf.if` |
| 8 | major | F5's planned kind-0 E2E construction no longer builds kind 0 (and F3 would type it) | kind 0 tested by hand-written MLIR and kernel unit tests; collateral docstring fix |
| 9 | major | F3 outside argument position stays untyped | documented limitation with `XFAIL-NATIVE` tests |
| 10 | major | F1 and F2 can produce the same word | covered by #5's exclusion |
| 11 | major | F2 missed the producers of `Nothing` | enumerated, plus a codegen assertion |
| 12 | major | gates never ran EcoPtrIntVerify, heap-validate, AOT E2E; `~/.eco` caches not wiped | §1.2 extended |
| 13 | major | runtime tolerance turns missed sites into silent wrong answers | validate-build asserts in the out-of-line entry points |
| 14 | major | four construct sites and sret/psplit/aggPromote not covered | enumerated; tagged types excluded from the splitting paths |
| 15 | minor | `eco.array.get` is `[Pure]`, so its slow path could be speculated | `[NoMemoryEffect]` |
| 16 | minor | the F5c C++ named the wrong helpers | named the three `call…Typed` helpers |
| 17 | minor | F4's second "pure forward" shape has no producer; `via` must thread through `splitAt`; node side must be the `MVar` | §4.3 step 2 |
| 18 | minor | baselines stale after F5 | re-take before F4 |
| 19 | minor | F2's hashing/equality claims; 7-bit level field; type-table packing pass; EcoPtrIntVerify constants | §5.1–5.3 |
| 20 | minor | `TenureHeapEnv::word` contract also in the tsan harness and GenMC drivers | §6.3 step 3 |
| 21 | minor | equality tag compare must happen where the word is in hand | §6.3 step 6 |
| 22 | minor | GC-exercising tests need a mechanism and a check | `-- ENV:` nursery config and a GC-stats CHECK |
| 23 | minor | `bench.sh` is not in the repo; small line-number drifts; Facts cite stale; AliasForward comment | §1.3 names the repo scripts; fixed in place |

Claims the reviewers confirmed: the F5 forwarding chain; the HPointer layout and that nothing
produces `0x6 | (k << 43)` today; F2 needs no GC change; F5c's raw callback elements are sound; the
stack-map scanner treats every slot as an independent root; the GC write-back inventory and the TLA
pins; F4's kernel-visibility reasoning and its need for the `Debug` exclusion.

## 9. Results

(Filled in as units land: each unit's gates, identity-oracle differences, measurements, and gate
decisions F1-D, F1-G, F1-C, F1-W.)
