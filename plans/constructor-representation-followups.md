---
status: done
updated: 2026-11-21
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
| F5 | Makes a `JsArray` of boxed primitives impossible by construction (producers derive the kind from the value; the two relabelling paths assert instead), then `Array.get` on an `Array Int`/`Float`/`Char` is an inline load instead of a kernel call that boxes each element, and `JsArray` callbacks get raw elements | every program using primitive arrays; a latent kind/GC hazard closed |
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
   - the stress suite (`build/test/stress-test`, built by name) in the normal tree, once at the
     default heap config and once under GC pressure (`ECO_HEAP_CONFIG` naming a JSON file with
     `{"nursery_regions": 0}` and a small `nursery_block_count`/`nursery_max_block_count`, so that
     the legacy nursery collects often; a region-mode nursery must keep at least one heap slot);
   - the `ECO_HEAP_VALIDATE` tree (`build-validate`: its unit tests, E2E and stress) is run **once,
     after the whole plan is complete** (user direction, 2026-11-20: validate builds take too long per
     unit; the normal-tree E2E and stress runs stay in every gate). F5a's probe and F1.1's
     validate-build asserts are read in that run (memory: never a validate self-compile);
   - the AOT E2E (`cmake --build build --target run-aot-e2e`): new symbols must link;
   - lowering validation, for a unit that adds or changes an LLVM lowering pattern (F2, F1): a tree
     configured with `-DECO_LOWERING_VALIDATION=ON` (EcoPtrIntVerify is compiled only then), running
     `full`;
   - `stress-test` with a small nursery (`ECO_HEAP_CONFIG` naming a 4 MiB nursery): the default
     config runs zero minors in the stress suite.

### 1.3 Measurement

- Self-compile: `benchmarks/fe-loop-run.sh` (three cold runs), against the previous unit's kept
  compiler; noise is about 1 %.
- User programs: `node examples/benchmarks/run.mjs <workloads> --runs 10`.
- Allocations: `scripts/ctor-census-selfcompile.sh <label>` (the constructor census).

---

## 2. F5. Array element kinds: an invariant, then typed reads

### 2.1 Facts

- A `JsArray`'s element kind is `header.unboxed & 3` (0 boxed, 1 Int, 2 Float, 3 Char). Readers and
  the GC trust it; the GC traces array elements only at kind 0 (`NurserySpace.cpp:1700`,
  `NurseryRegion.cpp:739-741`, `NurseryParallel.cpp:574-576`).
- The kind is set dynamically by the first store, so the runtime *permits* a kind-0 array of boxed
  Ints. The compiler avoids building one wherever the element type is known:
  - at a concrete element type the `push`/`singleton`/`unsafeSet` intrinsics unbox the value to the
    static element type (`Compiler/IR/Kernel/Intrinsics.elm:670-685`), and the kernels pick
    `_Int`/`_Float`/`_Char` variants;
  - since ARRAY-NEW-1 (2026-11-04), `initialize`/`map`/`indexedMap`/`initializeFromList` take the
    element kind from the call site's static type;
  - every element-building call in elm/core `Array.elm` is saturated (`:184,203,241,346,436,521-530,
    551,559`), so it is specialized at the concrete element type;
  - JSON `Decode.array` derives the kind from the decoded values' runtime tags
    (`JsonExports.cpp:1335-1342`, `decodedSlot` `:1005-1022`).
- A kind-0 primitive array can come only from a boxed root path, used where the element's static
  type is a type variable while the values are primitives. No Elm program is known to reach one.
  The producers that can (verified, review of 2026-11-20):

  | Producer | Today |
  |---|---|
  | `Elm_Kernel_JsArray_singleton` (`JsArrayExports.cpp:388-393`) | kind 0 (`arrayFromPointers`) |
  | `elm_array_singleton_box` (`:709-720`) | kind 0 |
  | `Elm_Kernel_JsArray_push` onto an empty array (`:427-460`) | kind 0 |
  | `elm_array_push_box` (`:753-772`) | kind 0, **relabelling** a primitive source |
  | `initializeImpl`/`mapImpl` with `kKeepElementKind` (`:225-300`, `:567-583`, `:890-904`) via `pushTypedResult` (`:150-172`) | a result_kind-0 closure's boxed primitives at kind 0 |
  | `JsArray::initializeFromList` with `kKeepElementKind` (`JsArray.cpp:26-35`) | first head binds; later heads of another kind stored **unconverted** |
  | `eco_clone_array` + `eco_array_set_fix_kind` (`RuntimeExports.cpp:4997-5038`, `eco.array.set`) | **relabels** without converting |
  | eco/system `JsArray2` `unsafeInsert` onto empty / `unsafeSet` / `copyArray` (`JsArray2Exports.cpp:37-107`) | kind 0 (reached only by `SeqDict` with `Node` elements) |

  `Elm_Kernel_JsArray_unsafeSet`'s boxed root (`:403-425`) and `slice`/`appendN` (`:463-561`,
  `:774-808`, `:944-997`) store by kind or copy the source; `List.toArray`'s array is always empty
  (`ListExports.cpp:612-638`); JSON's internal arrays hold Customs.
- A boxed Int/Float/Char exists only for a static `Int`/`Float`/`Char` (verified: nullable types
  exclude primitive payloads, MONO_033; erased wrappers become `MInt`; JSON values are wrapped;
  `number` resolves by MONO_028; Bool/Order/unit are constants). This is what makes tag-derived
  kinds sound.
- An empty array may carry a primitive kind (`slice` to length 0 keeps the source's kind), so "no kind
  yet" means *length 0*, whatever the header says.
- `Array.get` (elm/core `Array.elm:269`, `getHelp`'s `Leaf` arm `:285`) calls the global alias
  `Elm.JsArray.unsafeGet` (`Elm/JsArray.elm:105-107`). AliasForward keeps the call (`abiFixed` false),
  so it reaches the shared specialization and `Elm_Kernel_JsArray_unsafeGet_Int`
  (`JsArrayExports.cpp:842`), which boxes a primitive element for the caller to unbox. The compiler
  itself does this (`LocalOpt/Typed/Case.elm:213-228`, `arrayGetOr` on an `Array Int`).
- Calls to elm/core globals already try intrinsics: `Expr.elm:3685-3699` (`maybeCoreInfo`) passes the
  global's module name to `admittedIntrinsic` (`:1401-1404`) → `KernelIntrinsics.kernelIntrinsicOn`
  (`Intrinsics.elm:149-175`), which dispatches on the kernel home. The module `Elm.JsArray` does not
  match the home `"JsArray"`, so no `JsArray` intrinsic fires for the alias calls. A call whose result
  is a function goes to `generateClosureApplication` first (`Expr.elm:1655-1660`) and never reaches
  the intrinsic check.
- `mapImpl` (`:283-287`) and `foldImpl` (`:619-625`) box each primitive element before each callback
  call, through `callUnaryMapClosureTyped` (`:209`), `callBinaryIndexMapClosureTyped` (`:177`) and
  `callBinaryFoldClosureTyped` (`:194`), whose layouts give the element kind 0.
- License pins (`compiler/src/Compiler/Monomorphize/Solver/kernel-license-files.csv`): the 14
  `Elm.JsArray.*` kernels have 21 rows over `JsArrayExports.cpp`, `JsArray.cpp` and `JsArray.hpp`
  (`JsArray.hpp` for initialize, indexedMap, initializeFromList, map, push, unsafeSet). `JsArray2`,
  `HeapHelpers.hpp` and `RuntimeExports.cpp` are not license-pinned; none of the F5 files holds a TLA
  region (`RuntimeExports.cpp` and `NurserySpace.cpp` carry census pins, which hash concurrency lines
  only).

### 2.2 F5a. A primitive `JsArray` is always of its primitive kind

**Invariant** (HEAP_046, extended): a non-empty `JsArray` holding `Int`, `Float` or `Char` values is
of that primitive kind; a non-empty kind-0 array holds no boxed `Int`/`Float`/`Char`. Producers bind
an array's kind from its first element (by the element's runtime tag when it arrives boxed) and
convert every later element to that kind; nothing relabels a non-empty array. A length-0 array has no
kind, whatever its header says.

1. **Shared helpers**, `runtime/src/allocator/HeapHelpers.hpp`, beside `boxElement` (`:1927`), in
   namespace `alloc` (the file already uses `Allocator::resolve`, `resolveOrNull`, `ElmInt`,
   `ElmFloat`, `ElmChar`):

   ```cpp
   // The slot kind a JsArray stores `v` in when it arrives with kind `srcKind` (0 boxed word, 1-3 raw):
   // `srcKind` itself for a raw value, and for a boxed word 1, 2 or 3 if it names a boxed Int, Float or
   // Char, else 0 (HEAP_046). Does not allocate.
   inline u8 arrayKindOf(Unboxable v, u8 srcKind);

   // `v` (of kind `srcKind`) as a slot of kind `dstKind`: unchanged when the kinds agree; a boxed
   // Int/Float/Char unboxed when `dstKind` is 1-3. A raw value never goes into a boxed (kind 0) slot,
   // and a non-primitive word never into a primitive one: both assert (plain `assert`). Does not
   // allocate.
   inline Unboxable convertToKind(Unboxable v, u8 srcKind, u8 dstKind);

   // Under ECO_HEAP_VALIDATE: asserts that the array object `arr` keeps HEAP_046 (a non-empty kind-0
   // array holds no boxed Int, Float or Char), checking every element. A no-op otherwise.
   inline void validateArrayKind(const void* arr, const char* where);
   ```

   `JsArray::unboxByKind` (`elm-kernel-cpp/src/core/JsArray.hpp:30-48`) becomes a call of
   `convertToKind(boxed(p), 0, kind)`, keeping its asserts' messages.
2. **Producers** (each: `existing = number of elements already in the destination`;
   `k = existing == 0 ? alloc::arrayKindOf(v, srcKind) : (dst->header.unboxed & 3)`;
   `dst->elements[i] = alloc::convertToKind(v, srcKind, k)`; `dst->header.unboxed = k`):
   - `Elm_Kernel_JsArray_singleton` and `elm_array_singleton_box`: allocate one slot (root the value
     across `allocArray`, as `elm_array_singleton_box` does), store with the rule;
   - `Elm_Kernel_JsArray_push` and `elm_array_push_box`: after `copyAndExtendForPush`, store with the
     rule (`existing = len`); `push_box` keeps a primitive source's kind instead of relabelling;
   - `pushTypedResult` (`JsArrayExports.cpp:150-172`): replace the per-kind `arrayPush`/`arrayPushKind`
     calls by the rule with `srcKind = result_kind` (`existing = arr->length`), then `length++`;
   - `JsArray::initializeFromList` (`JsArray.cpp:26-35`), the `kKeepElementKind` branch: the rule per
     head with `srcKind` the cell's head kind;
   - delete `pushUnboxedResult` (`JsArrayExports.cpp:119-146`; its comment says nothing calls it);
   - `JsArray2Exports.cpp`: `unsafeInsert`, `unsafeSet` (and the `slotFor` helper, `:16-29`) store with
     the rule.
   `elm_array_push_int/float/char` and the `_Int`/`_Float`/`_Char` kernel variants keep
   `bindPrimitiveKind` (`:363-378`); its kind-0 branch stays as a defensive conversion and its comment
   changes ("a boxed source cannot hold primitives under HEAP_046; converted defensively").
3. **No relabel in `Array.set`.** `eco_array_set_fix_kind` becomes `eco_array_check_kind(array, kind)`:
   `assert(len == 0 || (unboxed & 3) == kind)` plus `validateArrayKind`; it never writes. The lowering
   (`ArraySetOpLowering`, `EcoToLLVMHeap.cpp:1442-1515`) emits the call only when the codegen is built
   with `ECO_HEAP_VALIDATE` (`#if ECO_HEAP_VALIDATE` around the call emission), so ordinary builds pay
   no call per `Array.set`. Rename at all five sites: `RuntimeExports.cpp:4997` (definition),
   `RuntimeExports.h:926`, `runtime/src/codegen/RuntimeSymbols.cpp:589-591` (JIT symbol map),
   `EcoToLLVMInternal.h:1170-1171` (declaration helper; mark gc-leaf, it never allocates),
   `EcoToLLVMRuntime.cpp:1261` (pre-declaration list); update the lowering's doc comment
   (`EcoToLLVMHeap.cpp:1436-1441`).
4. **Read-side validation** (the probe; independent of GC mode, touches no TLA region): call
   `alloc::validateArrayKind` on the array argument at the entry points that already resolve every
   array Elm hands the kernels: `copyAndExtendForPush` (`:302`), `copyForUnsafeSet` (`:336`),
   `Elm_Kernel_JsArray_slice` and `elm_array_slice`, `appendN` and `elm_array_append_n` (both
   operands), `mapImpl`, `foldImpl`, `Elm_Kernel_JsArray_unsafeGet_Int`, `eco_clone_array`
   (`RuntimeExports.cpp:5007`), and `JsArray2`'s `copyArray`. Not in the GC: synthetic GC tests
   (`MinorWorkload.hpp:83,135-139`, `ParallelMinorTest`, `ConcurrentTenureTest`, `HeapHelpersTest`,
   `gc-heap-tsan/heap_driver.cpp`) build kind-0 arrays of boxed Ints on purpose and never pass
   through these entry points.
5. **Tests.**
   - `test/kernel/JsArrayKernelTest.cpp`: for each producer of step 2, boxed Ints, Floats and Chars
     build an array of the primitive kind (header checked) whose elements read back; `push_box` onto a
     kind-1 array keeps kind 1 and every element; a minor GC (`eco_minor_gc`) in between leaves all
     elements intact. Update ARRAY-05 (`:253-254`), whose fixture builds a kind-0 array with
     `elm_array_push_box(boxedInt(..))`: build the fixture by hand (`allocArray` + `alloc::arrayPush(...,
     true)`) to keep testing `bindPrimitiveKind`'s defensive branch; update the file header (`:2-4`).
   - `test/codegen/array_kind_set.mlir` (FileCheck, `// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s`,
     after `test/codegen/caf_memo_gc.mlir:14-31`): `eco.array.push` of `!eco.value` Int operands (which
     lowers to `elm_array_push_box`), `eco.array.set : i64`, `eco_minor_gc`, then `eco.array.get : i64`
     of every element: the values (the kind is checked indirectly, by correct reads after a GC).
   - Existing tests keep passing: `test/elm-conformance/src/ArrayMapDebugLogKindTest.elm`,
     `test/elm-core/src/ArrayUnsafeGet{Char,Float}ElementTest.elm`, `HeapHelpersTest` (it tests the
     low-level `arrayPush`, which is unchanged).
6. **Comments** that describe the old behaviour: `bindPrimitiveKind` (`JsArrayExports.cpp:358-378`),
   `Utils.cpp:707-708`, `JsArray.hpp:53-57` (kKeep "unchecked"), `HeapHelpers.hpp:1753-1756`
   (`arrayPush`/`arrayPushKind` "later pushes must agree, unchecked": now "callers keep HEAP_046").
7. **Invariant**: amend HEAP_046's JsArray paragraph (the invariant above, the helpers, the read-side
   validation, the length-0 rule).
8. **License manifest**: one re-audit line for every row of the 14 `Elm.JsArray.*` kernels (21 rows,
   three files) in `compiler/src/Compiler/Monomorphize/Solver/kernel-license-audit.csv`, stamped
   `date -u +%Y-%m-%dT%H:%M:%S`, then `test/scripts/check-kernel-license-manifest.sh /work --update`.
9. **Probe and gates.** Configure and build the validate tree (`cmake -S /work -B /work/build-validate
   -DECO_HEAP_VALIDATE=ON` if it has no cache; `cmake --build build-validate --target test
   stress-test` by name, they are not in `all`), run its unit tests, `check` E2E and the stress suite
   under a 4 MiB nursery. Record in §9 whether `validateArrayKind` or a `convertToKind` assert fired,
   and where. Then §1.2 items 1–3, 6 and 7. Identity oracle: no MLIR change (the codegen change in step
   3 is under `ECO_HEAP_VALIDATE` only).

### 2.3 F5b. `Array.get` as an inline read

With F5a, a primitive `JsArray` holds raw slots, so `eco.array.get` (already a plain load for
`!eco.value`, `i64`, `f64` and `i32`, `EcoToLLVMHeap.cpp:1382-1425`) is correct for every static
element type: a primitive static element means a primitive-kind array, a non-primitive one a kind-0
array.

*(Found while implementing, 2026-11-20.)* In an optimized build the post-mono inliner already inlines
the `Elm.JsArray.unsafeGet` alias into a direct kernel call, which reaches the intrinsic: the
`repr-KV2` self-compile has 120 inline `eco.array.get`s and no `unsafeGet` kernel call. Those
existing inline reads were relying on the invariant F5a now enforces. F5b therefore only changes
alias calls the inliner leaves in place (inlining off, or over budget); its test compiles with the
post-mono inliner off (`Compiler.GenerateMlir.ArrayGetIntrinsicTest`), and the E2E MLIR test is a
regression lock (it passes with either compiler, the inliner being on in E2E).

1. **Tests first.**
   - `test/elm-core/src/ArrayGetPrimitiveTest.elm`: `Array.get` and `Array.length` on `Array Int`,
     `Float`, `Char`, `String` and `(Int -> Int)` (call the result), built by `fromList`,
     `initialize`, `push`, `set`, `append` and `slice`, at indices below 32 and at 35+ (`getHelp`'s
     leaf arm), and out of range. Output recorded from Elm. Passes before and after.
   - `compiler/tests/Compiler/GenerateMlir/ArrayGetIntrinsicTest.elm`: `JsArray.unsafeGet 1
     (JsArray.push 5 (JsArray.push 4 JsArray.empty))` compiled with `inline.postMono = False` emits
     `eco.array.get` and no `Elm_Kernel_JsArray_unsafeGet_Int`. Fails before. (The test interface
     `compiler/tests/Compiler/Elm/Interface/JsArray.elm` gains `unsafeGet`.)
   - `test/eco-mlir/src/ArrayGetIntInlineTest.elm`: for `Array.get` on an `Array Int`,
     `-- CHECK-MLIR: eco.array.get` and `-- CHECK-MLIR-NOT: Elm_Kernel_JsArray_unsafeGet_Int` (a
     regression lock).
2. **Map the module.** `compiler/src/Compiler/GenerateMlir/Expr.elm:3685-3699`, `maybeCoreInfo`: return
   `( coreIntrinsicHome moduleName, name )` with

   ```elm
   {-| The kernel home whose intrinsics a call of an elm/core global of module `moduleName` may use:
   `Elm.JsArray`'s definitions are aliases of the `JsArray` kernel (`Elm.JsArray.unsafeGet =
   Elm.Kernel.JsArray.unsafeGet`), so a call of one is matched as a call of the kernel, with the
   call's own argument and result types. Every other module is its own home.
   -}
   coreIntrinsicHome : String -> String
   coreIntrinsicHome moduleName =
       if moduleName == "Elm.JsArray" then
           "JsArray"

       else
           moduleName
   ```

   Every `jsArrayIntrinsic` (`singleton`, `push`, `slice`, `appendN`, `length`, `unsafeGet`,
   `unsafeSet`) is the operation the forwarded kernel calls already use; each declines when the
   array's element type is a type variable (`Intrinsics.elm:714-719` for `unsafeGet`), so shared
   specializations keep their kernel calls. No change to `suffixSelectingKernels`, AliasForward or
   either mono engine: a call whose result is a function keeps today's path (`Expr.elm:1655-1660`).
3. **Invariant**: amend HEAP_046 (compiled code reads `JsArray` elements directly, relying on the
   invariant) and the CGEN row that describes the JsArray intrinsics if one exists (`grep -n
   "eco.array.get" design_docs/invariants.csv`).
4. **Gates**: §1.2 in full; two fixed-point rounds (the compiler's own `Array.get` calls inline).
   Identity oracle: programs that call `Array.get`/`Array.length` change.

### 2.4 F5c. Raw elements to `JsArray` callbacks (C++ only)

1. **Test**: `test/elm-core/src/ArrayCallbackKindsTest.elm` (recorded from Elm): `map`,
   `indexedMap`, `foldl`, `foldr` over 40-element `Int`, `Float` and `Char` arrays with closures
   typed at the element, with `(::)` and with a function value polymorphic in the element (the last
   two take the element boxed). Behaviour is unchanged by F5c, so this is a correctness lock rather
   than a failing-first test; the change is measured by the benchmarks of §2.5.
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

**Positions where the context fixes the type later** — a let-bound `f = Debug.toString` used later,
a record field, a list element, an `if` branch — were expected to leave the binder a residual type
variable. *(Found while implementing, 2026-11-20: they do not; monomorphization resolves the
parameter in all four, and `DebugValueContextTest` passes without `XFAIL-NATIVE`.)* A `Debug` value
whose argument type is genuinely a type variable still prints untyped.

*(Implementation note, 2026-11-20.)* The pass matches a direct kernel reference
(`Elm.Kernel.Debug.toString`/`log`, `TOpt.VarKernel`) as well as `TOpt.VarDebug`, except a node whose
whole body is such a reference (a kernel alias). The compiler's unit-test environment has no `Debug`
module and refers to the kernels directly (as `SourceIR.DebugKernelCases` does), so the unit test
exercises that form and the E2E tests the `VarDebug` form.

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
   a point-free `Debug.log`, which F3 types; update its docstring (after F5a no producer builds a
   kind-0 primitive array; F5a's kernel tests cover the producers).
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
*(Implementation notes, 2026-11-20.)* `nodeTypeOf` in `collect` returns the `Via` with the node type
(one lookup, instead of a separate `nodeOf`); the `global->` arm tags every meet `splitAt` builds for
it, and `splitAt` itself builds `ViaOther`. The stat is `EraseStats.skippedMoveOnly` (rendered "move-only
meets skipped N"). The census is `Steps.meetsVarCensus`, written with the erase report. The pipeline
test with `repr.validate` passes with `movesOnly` off too (that program has no type-variable meet in
the unit-test environment); the E2E `EraseWrapperMoveOnlyTest` shows the effect (`P` and `Q` built
before F4, not after). Found while testing: `Array.slice` keeps an element wrapper boxed through
elm/core `sliceLeft`'s let-bound `helper` (`other:callArg`, a MONO_021 residual), outside F4's rule;
the test slices a separate wrapper `R`.

*(Found by the F4 gate, 2026-11-20.)* `SeqSetTest`, `SeqDictEqualityTest` and `SeqDictRandomizedTest`
crashed (SIGSEGV in `Utils.equal` → `seqDictEq`). F4 let `SeqDict`'s `Array (Maybe ( Int, k, v ))`
elements become nullable (they meet type variables only through `JsArray` aliases), and
`elm-kernel-cpp/src/core/SeqDict.hpp`, shared by `==` and `FNV.hash`, read each element as a `Just`
Custom. Kernel visibility never covered them: `Utils.equal` declares `SeqDict` inspected, but the
declared closure stops at `JsArray`'s type-variable element field. Fix: the walker reads both forms
by heap tag (a `Tag_Tuple3` element is the nullable `Just`'s payload). MONO_032 amended. **F1 must
exclude** `elm/core:Array`'s `Node` (and audit any other type C++ reads behind an opaque container):
`SeqDict.hpp` and the Array kernels read it as a Custom by constructor index.

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
*(Implementation notes, 2026-11-20 — deviations from the steps above, each for a reason found while
building.)*
- **Null word by the payload's words, not by "can be a constant".** A null word only has to differ
  from every word a payload value can be, since the test is exact. `NullableMaybe.assignNullWords`
  computes, bottom-up over nullable payloads, whether a payload can be Empty or a null-cons word:
  `Maybe` keeps Empty unless the payload can be Empty, a user type keeps its null-cons word unless
  the payload can be a null-cons word, otherwise the spare word one level above the payload's
  highest. So `Maybe Bool`, `Maybe Color` and `Opt String` are unchanged in encoding, and
  `Maybe (Opt String)` gets a spare word: §5.2's "custom payload ⇒ never Empty" is false once
  `Opt String` is nullable (`Some ""` is Empty).
- **Recursive candidates are dropped** (`type L = N | C L`: `C N` would be `N`'s word under any
  encoding; the old "no constants in the payload" rule excluded them by accident). Counted as
  `recursive` in the `nullable-maybe` report.
- **Levels run to 1023** (all of `null_cons_idx`), not 127.
- **`eco.is_word %v [constant, index]`**, not `{word : i64}`: null-cons words reach ~9e15, above the
  2^52 the JavaScript-hosted compiler's bytecode writer encodes exactly.
- **`null_name` packing**: bits 0-19 name index (checked), bit 20 null-cons flag, bits 21-30 index;
  the printer decodes it with `Heap.hpp`'s `nullableNullWord` and compares the exact word.
- `Mono.NullableInfo.constantBitTest` is replaced by `nullWord : Mono.NullWord`; `Ops.ecoIsConstant`
  (no longer emitted) is removed; references to a nullable type's nullary constructor go through a
  new `Context.nullWordBySpec`, consulted before the null-cons and well-known-constant maps.
- Census class `spare` (via `NullableMaybe.censusClass`).

*(Found by the first F2 gate run, 2026-11-20; both fixed, re-gated as `repr-F2b`.)*
- **Kernel visibility did not see through kernel aliases.** `Socket.Tls.info` calls
  `kInfo = Eco.Kernel.Tls.info`, whose shared alias node has type variables where the kernel's types
  are, so `Tls.info`'s declared `Maybe` was never found at `Maybe String`; with `Maybe String` now
  nullable, the kernel's `Nothing` (Empty) read as `Just ""` (`SocketTls*Test`, 4 tests). Latent
  since kernel aliases existed (deny-all kernels behind an alias were exposed the same way, and F4's
  move-only rule removed the type-variable meet that had hidden it). Fix: `KernelVisible` takes a
  reference to a kernel-alias global as a reference to the kernel at the use site's type
  (MONO_032 amended; two `KernelVisibleTest` cases, failing before the fix).
- **The type table decided nullability on the print type.** A type registered for printing keeps
  its erased wrappers (`Maybe (Box String)`), while `repr.nullable` is keyed after erasure
  (`Maybe String`), so the entry was a `Custom` and the printer showed `<internals>`
  (`EraseWrapperDebugTest`, `EraseWrapperSetDictTest`). Fix: `Context.nullableOfPrintType` erases
  the print type first (an `Erasable` built from `repr.erasedKeys`/`printShapes`).
- Expected updates: `CtorCensusTest` (`Maybe String` is `spare`) and
  `test/codegen/type_table_wrapper_nullable_print.mlir` (the new null-word packing).

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
- **D2** (2026-11-20, revised twice the same day): a `JsArray` holding primitives is always of
  that primitive kind (HEAP_046), enforced at the producers (kind from the stored value's runtime tag)
  and checked, under `ECO_HEAP_VALIDATE`, at the kernel entry points that read arrays. `eco.array.get`
  stays a plain load. `Array.get` reaches it by matching calls of the `Elm.JsArray` aliases against
  the `JsArray` intrinsics (`maybeCoreInfo`), not by forwarding `unsafeGet` through
  `suffixSelectingKernels`: forwarding gave a kernel call whose concrete type, at a function element,
  flattens to three parameters and miscompiles (review finding F5-B1), and needed new kernel symbols.
  Rejected: a kind-aware `eco.array.get` with an `scf.if` slow path, defending every reader against
  a state no Elm program is known to produce.
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
| 6 | major | `eco.array.set` relabels a kind-0 copy's kind without converting; `elm_array_push_box` the reverse | F5a: no Elm program is known to reach either (user review); boxed primitive arrays made impossible at the producers, relabels assert, a validate-build probe records whether any construction reaches them |
| 7 | major | the kind branch cannot be new blocks inside a lowering (`scf` regions) | moot: F5b has no kind branch (D2 revised) |
| 8 | major | F5's planned kind-0 E2E construction no longer builds kind 0 (and F3 would type it) | producers tested by kernel unit tests and hand-written MLIR; the F5a probe looks for any real construction |
| 9 | major | F3 outside argument position stays untyped | documented limitation with `XFAIL-NATIVE` tests |
| 10 | major | F1 and F2 can produce the same word | covered by #5's exclusion |
| 11 | major | F2 missed the producers of `Nothing` | enumerated, plus a codegen assertion |
| 12 | major | gates never ran EcoPtrIntVerify, heap-validate, AOT E2E; `~/.eco` caches not wiped | §1.2 extended |
| 13 | major | runtime tolerance turns missed sites into silent wrong answers | validate-build asserts in the out-of-line entry points |
| 14 | major | four construct sites and sret/psplit/aggPromote not covered | enumerated; tagged types excluded from the splitting paths |
| 15 | minor | `eco.array.get` is `[Pure]`, so its slow path could be speculated | moot: no slow path (D2 revised) |
| 16 | minor | the F5c C++ named the wrong helpers | named the three `call…Typed` helpers |
| 17 | minor | F4's second "pure forward" shape has no producer; `via` must thread through `splitAt`; node side must be the `MVar` | §4.3 step 2 |
| 18 | minor | baselines stale after F5 | re-take before F4 |
| 19 | minor | F2's hashing/equality claims; 7-bit level field; type-table packing pass; EcoPtrIntVerify constants | §5.1–5.3 |
| 20 | minor | `TenureHeapEnv::word` contract also in the tsan harness and GenMC drivers | §6.3 step 3 |
| 21 | minor | equality tag compare must happen where the word is in hand | §6.3 step 6 |
| 22 | minor | GC-exercising tests need a mechanism and a check | `-- ENV:` nursery config and a GC-stats CHECK |
| 23 | minor | `bench.sh` is not in the repo; small line-number drifts; Facts cite stale; AliasForward comment | §1.3 names the repo scripts; fixed in place |
| 24 | blocker | (F5 re-review) forwarding `unsafeGet` with its concrete type gives, at a function element, a kernel type whose flattened arity is 3: the call becomes a partial application of the unsuffixed root with a raw index | F5b matches the `Elm.JsArray` alias calls against the existing intrinsics instead (`coreIntrinsicHome`); no forwarding, no new symbols |
| 25 | major | (F5 re-review) the validator check was placed in dead code on a GC path region mode never takes | read-side `validateArrayKind` at the kernel entry points |
| 26 | major | (F5 re-review) GC unit tests and ARRAY-05 build kind-0 arrays of boxed Ints on purpose | the check stays out of the GC; ARRAY-05's fixture rebuilt by hand |
| 27 | major | (F5 re-review) JsArray2 producers and the boxed `unsafeSet` root missing; store asserts blind to first stores and copies | producer table in §2.1; read-side checks see every array |
| 28 | major | (F5 re-review) `initializeFromList` already mixes kinds; a helper taking `HPointer` cannot convert raw inputs | `arrayKindOf` / `convertToKind` over `(Unboxable, srcKind)` |
| 29 | major | (F5 re-review) the `fix_kind` rename misses three sites; every `Array.set` pays a no-op call | all five sites named; the call is emitted only in validate builds |
| 30 | minor | (F5 re-review) license pins are 21 rows over three files; empty arrays may carry a kind; stale comments; FileCheck cannot see the header | §2.1, §2.2 steps 5–8 |

Claims the reviewers confirmed: the F5 forwarding chain (as a chain; it is no longer used, row 24); the HPointer layout and that nothing
produces `0x6 | (k << 43)` today; F2 needs no GC change; F5c's raw callback elements are sound; the
stack-map scanner treats every slot as an independent root; the GC write-back inventory and the TLA
pins; F4's kernel-visibility reasoning and its need for the `Debug` exclusion.

## 9. Results

(Filled in as units land: each unit's gates, identity-oracle differences, measurements, and gate
decisions F1-D, F1-G, F1-C, F1-W.)

### F5 (snapshot `repr-F5b`, 2026-11-20)

- **Gates**: `full` 3,125/3,125; elm-tests 22,012/0; bootstrap rc 0 through Stage 8c and 9b; AOT E2E
  1,506/1,506; TLA canary clean; fixed point holds in **one** round (the compiler's own MLIR is
  unchanged: see F5b). Identity oracle: no existing program's MLIR changed; the only differences are
  the new tests (`ArrayGetIntInlineTest`, `ArrayGetPrimitiveTest`, `ArrayCallbackKindsTest`,
  `ListMapNFunctionResultTest`) and `NullableChainClosureTest` (new since the base corpus).
- **Self-compile**: 71.0 s (base 70.05 s; within noise), minor GCs 1,403, promoted 7,167 MiB.
  `ECO_REPR_VALIDATE=1` self-compile: clean, output identical.
- **Stress** (normal tree): 114/114 at the default config; 114/114 under GC pressure
  (`{"nursery_regions": 0, "nursery_block_count": 2, "nursery_max_block_count": 2}`, 48,269 minor
  GCs in the first test's stats).
- **Live bug confirmed**: before F5a, `test/codegen/array_kind_set.mlir` read `[eco.dbg] 1120986464800`
  (pointer bits) for the untouched elements after `eco.array.push` of boxed Ints and an
  `eco.array.set : i64`; after, `10, 99, 30`.
- **F5b finding**: optimized builds already inline `Array.get` into `eco.array.get` (120 in the
  self-compile, no boxing kernel call), so F5b changes no existing MLIR; it covers alias calls the
  inliner leaves (tested with the inliner off). The existing inline reads relied on F5a's invariant.
- **Existing bug found and fixed** (by `ArrayGetPrimitiveTest`): `Array.initialize`/`map`/`indexedMap`/
  `foldl`/`foldr` and `List.map2`..`map5`, on the path that keeps the closure's own result kind, asked
  an under-saturated call (a merged lambda such as `\i -> \x -> x + i` applied to fewer arguments than
  its stage takes) for the closure's saturated primitive result kind, and `eco_apply_closure_eval`
  aborted. `readClosureResultKind`/`callResultKind` (`JsArrayExports.cpp`) and `kernelListMapN`
  (`ListExports.cpp`) now ask for a boxed result unless the call saturates the closure. Pinned by
  `test/elm-core/src/ListMapNFunctionResultTest.elm` (crashed before, passes after).
- **Deferred to the final `ECO_HEAP_VALIDATE` run** (user direction): F5a's probe. A first validate-tree run
  showed (a) its `full` failing to link `elm-kernel-time-test` (undefined
  `PlatformRuntime::decodeFlags` from `libEcoRuntimeStatic.a`), to be checked against the base tree,
  and (b) that the stress suite's small-nursery config must keep a region at least one heap slot
  (`{"nursery_region_bytes":"4M"}` is refused in region mode; use `nursery_regions: 0` or a larger
  region). The validate tree's unit tests passed (3,126/3,126).
- **Not measured yet**: the user-program benchmarks of §2.5 (to run with the final measurements).

### F3 (snapshot `repr-F3`, 2026-11-20)

- **Gates**: `full` 3,127/3,127; elm-tests 22,020/0 (8 new in `TypedDebugValuesTest`); bootstrap rc 0
  through Stage 8c and 9b; AOT E2E 1,508/1,508; stress 114/114 at the default config and under GC
  pressure; TLA canary clean; fixed point in one round; `ECO_REPR_VALIDATE=1` self-compile clean,
  output identical.
- **Self-compile**: 70.9 s, minor GCs 1,407, promoted 7,185 MiB (F5: 71.0 s, 1,403, 7,167 MiB).
  `pre-debug-values` report line added.
- **Identity oracle**: 13 existing programs' MLIR changed, each of which uses `Debug.toString` or
  `Debug.log` as a function value (`show = Debug.toString`, `D.map Debug.toString`, `List.map
  (Debug.log "x")`, a `Debug.log "g"` argument); all still pass. No other program changed.
- **Tests expose the gap**: with the pass bypassed in `Steps.preMono`, the two MLIR tests of
  `TypedDebugValuesTest` (solver and substitution engines) fail; with it, they pass.
- **Finding**: the let-bound, record-field, list and `if`-branch positions print typed too
  (`DebugValueContextTest` passes without `XFAIL-NATIVE`), contrary to §3's expected limitation.

### F4 (snapshot `repr-F4b`, 2026-11-20)

- **First gate run (`repr-F4`) failed**: `full` 3,125/3,128 and AOT 1,506/1,509, the three `SeqDict`
  tests crashing in `Utils.equal` (see §4.3's finding). Fixed in `core/SeqDict.hpp`; the rest of that
  run (elm-tests 22,027/0, bootstrap 8c/9b, stress 114/114 both configs, canary) was already green.
- **Gates (`repr-F4b`)**: `full` 3,128/3,128; elm-tests 22,027/0; bootstrap rc 0 through Stage 8c and
  9b; AOT E2E 1,509/1,509; stress 114/114 at the default config and under GC pressure; TLA canary
  clean; fixed point holds on the second round (eco-optF4 → eco-optF4b); `ECO_REPR_VALIDATE=1`
  self-compile clean, output identical.
- **Self-compile**: 72.2 s, minor GCs 1,426, promoted 7,412 MiB (F3: 70.9 s, 1,407, 7,185 MiB);
  representation phase 1.7 → 2.6 s. Within run-to-run noise on wall; the extra promotion is the
  representation passes' larger meet lists.
- **Identity oracle**: 206 programs' MLIR changed against F3 (more wrappers erased and more `Maybe`s
  nullable where the only type-variable meets were kernel-alias moves), all passing.
- **Fixture**: before F4, `EraseWrapperMoveOnlyTest`'s `P` and `Q` were built as heap constructors;
  after, neither is. `repr-meets-var` on it: every kernel-alias meet move-only; one `other:callArg`
  (elm/core `sliceLeft`'s `helper`) remains.

### F2 (snapshot `repr-F2b`, 2026-11-20)

- **First gate run (`repr-F2`) failed**: `full` 3,123/3,130, AOT 1,504/1,510, elm-tests 22,033/1 — two
  latent bugs F2 exposed (kernel visibility through kernel aliases, nullability of print types) and
  two expected test updates; see §5.3's findings. Bootstrap, stress (both configs) and the canary
  were already green.
- **Gates (`repr-F2b`)**: `full` 3,130/3,130; elm-tests 22,036/0; bootstrap rc 0 through Stage 8c
  and 9b; AOT E2E 1,510/1,510; stress 114/114 at the default config and under GC pressure; TLA
  canary clean; `ECO_REPR_VALIDATE=1` self-compile clean, output identical. **Fixed point**: needed a
  third round (eco-optF2 had the kernel-visibility bug, so eco-optF2 → eco-optF2b differs);
  eco-optF2b → eco-optF2c is a fixed point.
- **Self-compile**: 72.6 s, minor GCs 1,438, promoted 7,577 MiB (F4b: 72.2 s, 1,426, 7,412 MiB).
- **Identity oracle**: 360 programs' MLIR changed against F4b (every nullable test is now
  `eco.is_word`; newly nullable `Maybe String`/`Maybe (List a)`/nested types), all passing.
- **New tests**: `test/codegen/spare_word.mlir` (ops, exactness, `select`, survival across a minor
  GC), `test/elm/src/NullableSpareWordTest.elm` (Elm-recorded, uses `eco.constant.spare` and
  `eco.is_word`), `NullableMaybeTest` rewritten (null words, levels, recursion), two
  `KernelVisibleTest` alias cases.

### F1.0 — census and gate F1-D (2026-11-20)

- **Built**: `Compiler.MonoOpt.TaggedUnions` (`choose`, `censusLabels`; report-only, run by
  `Steps.representation`'s census hook only when `ECO_CTOR_CENSUS` is set, so no output changes
  otherwise), `Mono.ReprInfo.tagCensus`, the census's `tagged` column, `scripts/ctor-census.py --by
  tagged` (several counts files summed, the F1-D line), `benchmarks/ctor-census-bench.sh`. Unit tests
  `TaggedUnionsTest` (7) and `CtorCensusTest` pass.
- **Gate F1-D — PASSES (narrowly), on the benchmark aggregate**:

  | workload | bare allocations | of attributed custom allocations | share |
  |---|---|---|---|
  | self-compile (Stage 7a, census compiler from eco-optF1a) | 25.45M | 975.56M | **2.6 %** |
  | benchmarks (74 workloads, default sizes, one run each) | 13.85M | 272.85M | **5.1 %** |

  The benchmark bare share is `Bytes.Decode.Step.Loop` 1.53 %, `Parser.Problem.ExpectingSymbol`
  1.43 %, `Parser.Step.Loop`/`Done` 1.21 %, `ExpectingKeyword` 0.32 %, `Result.Ok` 0.26 %, then user
  types. What blocks the rest: self-compile — kernel-owned 44.4 % (`Dict`), **nullable-payload
  18.5 %** (types F2 made the payload of a nullable `Maybe`; F1 and F2 compete for these), no `bare`
  constructor 10.8 %, kernel-visible 6.1 %; benchmarks — kernel-owned 32.6 %, no-bare 32.4 %,
  kernel-visible 20.5 %. `elm/core:Array.Node` is excluded (meets, no-bare), as F4 requires.

### F1.1 — runtime tolerance (2026-11-20, in progress)

- **Tests first**: `test/allocator/TaggedWordGcTest.cpp` (7 tests: serial, parallel and region minors, region
  minors through tenuring, a major, CAF promotion, `==`/`FNV.hash`). Each tagged payload is also held by an
  untagged root and the tagged word must name the same (moved) object, so a word a collector skipped fails
  too. Before the change all six collection tests failed (every write-back dropped the tag; the region
  minor through tenuring also left a tagged JIT root naming the stale copy); after, all seven pass.
- **Write-back**: `Heap.hpp` `WORD_TAG_MASK`, `wordTag`, `retarget(old, newAddr)`; every forwarding/copy
  write-back in `NurserySpace.cpp` (evacuate, list spine), `NurseryParallel.cpp` (evacuateP, spineRunP),
  `NurseryRegion.cpp` (evacuateR incl. the Retire arm, spineRunR), `NurseryTenure.cpp` (TenureParEnv
  childOfCopy/spineRun, the YLOS slot rewrite, both heal loops), `TenureWork.hpp` (`Env::word(old, obj)`),
  `OldGenSpace::fixHPointer`, `PermanentSpace.cpp` (`eco_caf_promote`: fields and the returned root word).
- **Raw roots**: `evacuateJitPtr`, `evacuateRawP`, the region JIT-root loop, `markJitRootRaw` (a tagged JIT
  root would otherwise go unmarked and be freed), `traceOldReachableForValidation`, `Export::toPtr`.
- **Equality and hashing**: `resolveAndCompare` and `equalRespectingConstants` compare tags first; FNV
  mixes a non-zero tag and hashes the untagged word (marker `kTag` appended); the inline `eco.value.eq` fast
  path sends a tagged Empty against a heap word to the kernel.
- **Validate asserts**: `eco_get_tag`, `eco_custom_get_{i64,f64,char}`, `eco_resolve_hptr`,
  `eco_follow_forward` abort on a tagged heap word under `ECO_HEAP_VALIDATE`.
- **TLA canary**: 11 pins fired (M1, M2, M3, M5, M7, W5, w_running_chain); audited — each store is the same
  owner-only whole-word store, merged with the slot's own previous bits — **no model change needed**;
  entries in each AUDIT.md, manifest updated. Kernel license re-audits for the `ExportHelpers.hpp`/`Utils`
  changes. HEAP_086 added.
- **Re-wrap audit** (step 6, read-only, 2026-11-20): no kernel in `elm-kernel-cpp`, `system-kernel-cpp`,
  `HeapHelpers.hpp`, ListOps or StringOps turns a generic element back into a word through an address;
  every store of an element copies the word (`Export::decode`/`encode`, `Unboxable` assignment,
  `convertToKind` at kind 0, root-guard memcpy). The 54 re-wraps found are of objects the kernel just
  allocated (42), List spines (8, never tagged), Strings (3) and `++` operands (1). `Export::fromPtr` has no
  callers. The address-identity shortcut in `Utils.cpp` `eqHelp` (`a == b`) is reached only after the tag
  comparison (`equalRespectingConstants`, `resolveAndCompare`); a new caller of `Utils::equal` must compare
  tags first. Untyped `Debug.toString` of a bare tagged value would print the field: F1.5's typed `Tagged`
  arm covers it.
- **First F1-G run (`repr-F1a`)**: `full` 3,136/3,137 — `VirtualDomKernel V5 raw literal arguments`
  failed: `Export::toPtr` masked every non-constant word to 43 bits, which corrupts a raw C++ static's
  address above 2^43. Fixed: the whole word is tested against the heap first, and only then the masked
  address (a tagged heap word). Everything else in that run passed (self-compile fixed point, repr
  validate, elm-tests 22,043/0, bootstrap 8c/9b, AOT 1,510/1,510, stress both configs, canary).

- **Gate F1-G — PASSES (`repr-F1b`)**: `full` 3,137/3,137; elm-tests 22,043/0; bootstrap rc 0 through
  Stage 8c and 9b; AOT 1,510/1,510; stress 114/114 at the default config and under GC pressure; TLA
  canary clean; fixed point in one round; `ECO_REPR_VALIDATE=1` self-compile clean, output identical.
  Self-compile GC time 3.25 s (F2: 3.14-3.39 s across runs); wall 73.75 s against 72.64 s for F2 (+1.5 %,
  at the edge of the recorded 1.31 % noise; accepted by the user, 2026-11-20).

### F1.2 — codegen spike and gate F1-C (2026-11-20)

- **Ops**: `eco.word_tag %v -> i64` (`(ptrtoint v >> 43) & 1023`; an `i64` so that it is an `int` case's
  scrutinee as it is, not the plan's `i16`), `eco.tag_word %v [idx]` (`getelementptr i8, ptr addrspace(1) v, i64 (idx << 43)`, not
  `inbounds`; index 0 is `v`), `eco.untag %v` (`llvm.ptrmask(v, ~(1023 << 43))`). Verifier on `tag_word`'s
  index.
- **Spike** `test/codegen/tagged_words.mlir`: a bare word over a record (tag 5), a boxed Custom (tag 3) and
  tag 0, live across two minor collections, read back with `word_tag` and `untag` + projection: 5, 41, 3,
  7, 0. RS4GC relocates the untagged bases and rematerializes the tagging GEPs after the statepoint
  (`%.remat = getelementptr … %base.relocated, i64 idx<<43`), so the stack maps hold only untagged
  bases; `EcoPtrIntVerify` needs no new blessed pattern (`word_tag`'s `ptrtoint` feeds `lshr`/`and`/
  `trunc` in its block; the GEP and `ptrmask` make no integer round trip).
- **Gate F1-C — PASSES**: the spike passes in the default tree and in `build-lowval`
  (`-DECO_LOWERING_VALIDATION=ON`). That tree did not compile before: `EcoPtrIntVerify.h` still used
  `llvm::PassInfoMixin`, which this LLVM moved to `detail` (the file's other passes already used
  `Required/OptionalPassInfoMixin`); fixed to `RequiredPassInfoMixin`.

### F1.3-F1.6 — build (2026-11-20)

- **F1.3 choice**: `TaggedUnions.choose` now applies (`repr.taggedUnions`, default on, `ECO_TAGGED_UNIONS`,
  token `tu=1`): `Steps.representation` records `repr.tagged : LayoutMap (List ( Name, Mono.TagForm ))`
  and writes `tagged-unions: N types, M bare constructors; excluded …`. No node changes. One-constructor
  types are never tagged, so `sret`, psplit and the tail split (all `Just [ shape ]`) never see one;
  `promotableCtorCall` excludes tagged types as it does nullable ones.
- **F1.4 codegen**: constructor tests (`Patterns.generateWordTagTest`: `word_tag == index`); fan-outs in
  `Expr` and `TailRec` (`generateWordTagScrutinee`: an `int` case on the declaration indices); field
  projection (`generateMonoIndexOnHeap`: `eco.untag` the container, a `Bare` field is the untagged word,
  a `Boxed` one projected from it; `generateMonoUnboxOnHeap` crashes on a tagged type); construction in
  the constructor node (`Functions.generateCtor`) and inline (`Expr.generateTaggedCreate`).
  `Context.tagFormOf`/`isTagged`.
- **F1.5 printing**: type-table kind 9 `Tagged` (`TypeTable.addTaggedType`, bit 31 of a bare
  constructor's field count; `EcoToLLVMGlobals` packs it as `Custom`); the runtime's `Tagged` arm reads the
  index with `wordTag` and prints a nullary name, a bare name + untagged field, or a boxed untagged Custom
  (`print_custom_heap`, factored out of the `Custom` arm).
- **Bugs found while building** (each fixed):
  1. `Export::toPtr` returned a tagged word whose address is in **PermanentSpace** (a tagged interned
     literal, `Named "a"`) as a raw address — `==` segfaulted. It now also accepts a masked PermanentSpace
     address.
  2. **LLVM `-O0` assertion** (`StatepointLoweringState::clear`, "cleared before statepoint sequence
     completed"): RS4GC rematerialized tagged GEPs after a statepoint that nothing used, leaving dead
     `gc.relocate`s that `-O0` instruction selection skips (the JIT's level; `-O2` cleaned them up).
     `addEcoGCPipeline` now runs `DCEPass` after RS4GC.
  3. My print-helper extraction turned a loop `break` into `return` (every Custom printed empty).
  4. `BasicsExports.cpp`'s `inline` helpers in `extern "C"` became out-of-line unmangled symbols once
     `toPtr` grew (`check-kernel-c-symbols`); now `static inline`.
- **Tests**: `test/elm/src/TaggedUnionTest.elm` (Elm-recorded; `Shape`, `Expr`, `Result String Rec`
  tagged — 3 types, 4 bare constructors; `case`, `==` across constructors over one String, `Debug.toString`,
  records, lists, arrays, `Dict`, closures, a CAF, constructors as functions; 3,000,000-element churn with
  12 minor collections, then the values read again) and `TaggedUnionDerefExtTest.elm` (the same with
  `ECO_INLINE_DEREF_EXT=0`). Native `-O2` and `-O0` and the JIT all give Elm's output. A `Maybe Shape`
  made `Shape` a nullable payload in the first version of the test, so it was not tagged (the census's
  `nullable-payload` competition, now visible per program).
- **F1.6 invariants**: MONO_035, CGEN_091-093 added; HEAP_086 gains its codegen paragraph; HEAP_044,
  FORBID_HEAP_001/002, REP_LLVM_001, REP_CONSTANT_001/002 amended.

- **First F1-W run (`repr-F1c`)**: `full` 3,115/3,140 and AOT 1,487/1,512 (25 HTTP and WebSocket tests),
  stress 112/114 (two `EcoSystemHttpServer*`); bootstrap, elm-tests 22,043/0, the fixed point and the
  canary were green. Cause: `Http.Response` was tagged (`BadUrl_` bare) although the HTTP kernel builds
  it: `Http.toTask` calls the closure `Http.expect` stored with a `Response` it makes, `Response` appears
  in no type of `toTask`'s own, and `expect` declared only `Expect` and `Resolver`. **Fix**: `Http.expect`
  declares `Response` too (Visibility table and `design_docs/elm_kernel_functions.csv`). This is the
  general shape of the gap: a kernel that stores a closure another kernel later calls must declare the
  closure's parameter types. After the fix: the HTTP family 95/95, WebSocket 33/33, the stress programs
  3/3.
- **Closure-argument audit** (read-only, 2026-11-21): every C++ call of an Elm closure (`callClosure1-4`,
  `eco_apply_closure*`) across `elm-kernel-cpp`, `system-kernel-cpp` and `runtime/src/platform` hands it a
  primitive, tuple, record, list or String, a type variable, a kernel-owned type, or a type declared for
  its entry point (the declared closure follows a declared type's closure fields' parameter types). No
  other gap of the `expect`/`toTask` shape. The `Response` gap existed only because `Http.Expect` is
  opaque (no field leads from it to the stored closure); weak spots, not gaps today: FileSystem's and
  ChildProcess's `Maybe` are covered because their `MySub`/`MyCmd` keep the tagger as a visible field,
  and `managerUses` only reaches types visible through the manager's own type.
- **Gate F1-W gates (`repr-F1d`)**: `full` 3,140/3,140; elm-tests 22,043/0; bootstrap rc 0 through Stage 8c
  and 9b; AOT 1,512/1,512; stress 114/114 at the default config and under GC pressure; TLA canary clean;
  fixed point in one round; `ECO_REPR_VALIDATE=1` self-compile clean, output identical. Identity oracle:
  522 programs' MLIR differ from the base (tagged unions in programs with multi-constructor types).
  Self-compile 75.7 s, minor GCs 1,464, promoted 7,709 MiB (F2: 72.6 s, 1,438, 7,577 MiB): **wall +4.2 %**,
  near the 5 % the user asked to be flagged; to be examined in the end-of-plan wall pass.
- **Gate F1-W allocations — MET** (census, eco-optF1d, the program compiled with `ECO_TAGGED_UNIONS=1`
  vs `=0`): benchmarks 272.85M → 259.05M custom allocations (−13.80M, −5.1 %; census prediction 13.85M,
  0.04M bare left); self-compile 992.66M → 966.98M (−25.68M, −2.6 %; prediction 25.45M). Promotions
  161.04M → 159.99M (self), 2.16M → 2.09M (bench).
- **Gate F1-W wall — NOT MET yet**: the instrumented census self-compile took 90.2 s with tagging vs
  82.4 s without (single runs); the gate's plain self-compile 75.7 s vs F2's 72.6 s (+4.2 %). Being
  measured A/B (two compilers differing only in `ECO_TAGGED_UNIONS`), see below.
- **Gate F1-W wall — MET** (2026-11-21, quiet machine, A/B of two compilers built from the same source that
  differ only in `ECO_TAGGED_UNIONS`, alternating, three runs each): tagging off 76.42 / 75.18 / 74.99 s
  (median 75.18 s), tagging on 74.74 / 74.26 / 75.66 s (median 74.74 s, −0.6 %, within noise); GC time
  3.32-3.47 s for both. The earlier +4.2 % against F2 compared runs hours apart (drift), not tagging.
  **F1 ships default-on.**

### End of plan (2026-11-21)

- **`ECO_HEAP_VALIDATE` run** (the one validate run, user direction): `build-validate` main suite (unit +
  E2E) 3,141/3,141; validate stress 114/114 at the default config. Under GC pressure (2-block legacy
  nursery) 110/114: `EcoSystemHttpServerKeepAlive`, `EcoSystemSocket`, `EcoSystemTransformChain` and
  `EcoSystemWebSocket` exceeded the 60 s limit with no validation abort (100 % CPU, heap validation at every
  collection). **Rerun, all four passing** (one at a time, same pressure.json, the child watchdog raised
  with `ECO_TEST_TIMEOUT_SECONDS=5400`): `WebSocket` 131 s, `HttpServerKeepAlive` 142 s, `TransformChain`
  377 s, `Socket` 505 s; no validation abort. (An earlier rerun used `--timeout`, which also sets
  `StressFlags.timeoutMs` and turns each program into a soak until the deadline, so its timeouts and its
  `WebSocket` failure are not results. Soaking `WebSocket` exposed a pre-existing issue, see open items.)
  Fixed for the run:
  `elm-kernel-time-test`'s link order (`ElmKernel_Json` listed after `EcoRuntimeStatic`), which had kept the
  validate tree's `full` from linking.
- **Benchmarks** (Bench.elm compiled by the base compiler `eco-optKV2` and the final `eco-optF1d`, `-O 2`,
  each workload in its own process, warmup 3, 10 runs, median): array-build 0.0 %, dijkstra +0.8 %,
  floyd-warshall −2.5 %, life +2.1 % (rerun +1.5 %), flood-fill +1.8 %, kernel-callbacks +1.6 %,
  dict-char-pairs 0.0 %, json-decoders −0.7 %, csv-parser +4.0 % (rerun ≈ +1 %), lexer −3.4 %,
  **word-freq +7.5 % (rerun +5 to +6 %)**, json-parser −2.6 %, expr-parser −1.0 %, sexpr −2.7 %,
  bytes-dynamic −2.3 %, binary-format +3.5 % (rerun ≈ +1 %). The `word-freq` regression was bisected with
  each unit's gate compiler: KV2 123, F5b 121, F3 122, **F4b 126-132**, F2c 127-130, F1d 126 ms (and the
  final compiler with tagging off, 124-127 ms): it enters with **F4** (one more wrapper type erased in the
  benchmark program, 3 instantiations, 12 constructor calls removed). `perf` shows the same profile shape
  (String compare, `resolve`, Dict) with a small shift to GC work; no new hot path. Recorded for the
  end-of-arc wall pass (user: small regressions acceptable, flag ~5 %).
- **Self-compile** across the plan (gate runs, one machine, different hours): KV2 70.1 s, F5 71.0, F3 70.9,
  F4 72.2, F2 72.6, F1 75.7 s; the quiet-machine A/B of F1 (above) shows tagging itself −0.6 %, so the
  drift between gate runs is not a per-unit cost. **Same-session A/B (2026-11-21, quiet machine,
  alternating, 3 runs each):** base `eco-optKV2` 74.14 / 74.05 / 73.91 s (median 74.05), final
  `eco-optF1d` 75.69 / 75.20 / 74.13 s (median 75.20): **+1.6 %** (mean +1.3 %), GC/alloc time equal
  (3.35 vs 3.35 s median), out.mlir −0.7 %. Below the 5 % flag; most of the 70 → 75.7 s gate-run drift
  was the machine (the base compiler itself now takes 74 s).
- **`word-freq` resolved (2026-11-21)**: comparing every function of the benchmark program's MLIR
  between the F3 and F4b compilers, ignoring SSA names, spec ids and generated helper numbers, the
  functions that changed are the `Set` ones (F4 erased `Set_elm_builtin`: `Set_empty`, its CAF, the
  `List.foldl` instances over sets), Sudoku (`Sudoku_cands` builds three more heap `Just`s: one `Maybe`
  lost its nullable form through the erasure), and a few lambdas. **None of `word-freq`'s path changed**:
  its own functions and every `Dict` function are identical. With identical code and the same profile
  shape, its ±5 % is code placement in the one binary that holds all 74 workloads (functions move when
  other code changes; the alignment effect this project has met before), not a cost of F4.
- **Open items** (for a follow-up, none blocking): the +1.6 % self-compile wall (above); F1 and F2
  compete for the same types (`nullable-payload` was 18.5 % of the self-compile's custom allocations in
  the F1.0 census: a type that is a nullable `Maybe`'s payload cannot be tagged); pre-existing, not from
  this plan (it reproduces with tagging off): `EcoSystemWebSocket` peaks at 3.6 GB RSS in its normal
  20-wave run, almost all off-heap (live heap ≈ 11 MB), and under `--timeout` soak grows ≈ 1 GB/s to the
  machine's 15 GB: native per-connection WebSocket state (deflate streams, write buffers) is released
  late or not at all.
