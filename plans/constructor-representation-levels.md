---
status: partial
updated: 2026-11-21
remaining: "Section 13 R0-R4 done as written, with dated amendments (representation step 8.7 s -> 1.7 s, under the 2 s target; see 13.6). Not built, each by its gate (see section 12): S2 (S2-D failed, 2.0 MiB projected); N2 (re-measured after N1, under 0.2% of allocations reachable; not planned); K2 (K0 re-run with K1 on finds 0 sites). K1 was built before K0-D was measured, against the plan's order; K0-D failed (0 sites), and K1 is default on since 2026-11-21 under a new gate (E2E fixtures, see section 14)."
---

# Constructor representation: four levels of custom-type unboxing

This plan covers how the native backend represents values of custom types, by the shape of the
type:

| Level | Shape | Example | What this plan does |
|---|---|---|---|
| 1 | one constructor, one field | `type Quantity n u = Quantity n` | erase the wrapper everywhere (group E) |
| 2 | one constructor, several fields | `type Pt = Pt Float Float` | return in registers (S1); smaller heap object (S2, gated) |
| 3 | several constructors, at most one field each | `Maybe a`, `Result e a` | `Just x` as bare `x` (group N); option (b) deferred (N2) |
| 4 | several constructors, several fields | `Dict`'s `RBNode_elm_builtin` | local only: fold `case` on a known constructor (group K) |

The JS backend is out of scope: it already erases level 1 (`Opt.Box` → identity,
`GenerateJs/Generate.elm:306`) and its object model makes the other levels moot.

`plans/sum-type-wrapper-unboxing.md` is superseded by this plan (decision D3). Its option (a),
nullary embedding, shipped as `plans/null-cons-hpointer-embedding.md`. Its option (b) is unit N2
here. Its W1 table rests on a wrong premise: one-constructor one-field types *do* allocate
natively (§1.1), so its 1-field pool mixes levels 1 and 3.

## 0. What this plan achieves

At the end of the plan:

- **Wrapper types cost nothing natively** (level 1), as they already cost nothing in JS. A value
  of `type Parser a = Parser (State -> Step a)` *is* the closure, a `Quantity Float` *is* an
  `f64`, a `Set` *is* its `Dict`. No allocation, no projection, no header. In the self-compile
  this is up to 103.4M allocations (8.6 %), and it removes a whole style tax from ordinary Elm,
  where 24–32 % of declared types are such wrappers.
- **`Just x` is `x`** (level 3) whenever `x`'s word can never be the Empty constant: records,
  tuples, functions, Bool, and most custom types. `Just` alone is 299.8M allocations (25 %) in the
  self-compile, mostly from `Dict.get`-style code. `Nothing` stays the Empty constant.
- **A `case` on a constructor built in the same function folds away** (level 4 and the local
  half of level 3), as inlining exposes such sites.
- **One-constructor records-by-position returned from functions travel in registers** (level 2,
  S1), as returned tuples already do. A compact heap layout (S2) is built only if the
  measurement says it pays.
- **A census lands in the repo** (M0). It attributes every compiled-code custom allocation and
  every minor-GC promotion to a constructor and level. Every gate below is measured with it, and
  it stays available for later work.
- **Two analyses land that the compiler lacks today**, and that later representation work can
  reuse:
  - The kernel-visibility set (KV) says which types the C++ kernels build or read, so their
    representation must stay fixed.
  - The representation-meets analysis (V) finds every place where two different `MonoType`s
    describe one runtime value. It closes the gap between what MONO_029 states and what
    `ValidateLayout` checks.

Program output does not change, including `Debug.toString`. The only visible difference is when
a wrapper or `Just` reaches `Debug.toString` through a polymorphic, erased position, which prints
the payload (§6.3, known limitation).

## 1. Where things stand

### 1.1 What the native backend does today

- **Level 1.** `toOpts` (`Canonicalize/LocalEnvironment.elm:693`) marks a type `Can.Unbox` when it
  has exactly one constructor with exactly one argument. Typed optimization turns that into
  `TOpt.Box` (`LocalOpt/Typed/Module.elm:278`). References become `TOpt.VarBox`
  (`LocalOpt/Typed/Names.elm:273`).
  - Both mono engines specialize a `Box` as an ordinary one-field constructor:
    `Monomorphize/Subst/Specialize.elm:1674` (`specializeCtorViaScheme … 0 1`) and
    `Monomorphize/Solver/Monomorphize.elm:3998`.
  - The result is a `MonoCtor home { name, tag = 0, fieldTypes = [payload] } resultType` node.
    The value is a heap `Custom` built by `eco.construct.custom` and read by
    `eco.project.custom`.
  - Matching never tests a tag. Typed optimization emits `TypedPath.Unbox` / `TOpt.Unbox` for
    these types (`LocalOpt/Typed/DecisionTree.elm:269-276`, `Expression.elm:1694-1697`), which
    mono turns into `MonoUnbox` / `DtUnbox` path steps.
- **Existing aggregate passes** (`Compiler/Config.elm`, all on by default):
  - `aggPromote` keeps a let-bound constructor value in SSA (`eco.make.custom`) when every use
    only reads a field (`GenerateMlir/Expr.elm` `promotableCtorCall`, line 6400). A use that
    tests the tag disqualifies it.
  - `ctorInline` builds the value in the caller, still on the heap (`Expr.tryCtorInline`, 3534).
  - `sretResults` covers returned 2- and 3-tuples only (`Backend.elm` `sretInfoOf`, line 409).
  - `psplitParams` splits a parameter that is a 2- or 3-tuple, or a one-constructor custom with
    **2 to 6** fields (`Backend.elm` `psplitOnePass`, 929-946). One-field types never qualify.
- **Nullary constructors.**
  - `Nothing` is the shared Empty constant (word 0x6), which `()`, `{}`, `[]`, `""` and empty
    Bytes also use. `True`/`False` are 0x5/0x4.
  - Every other nullary constructor is a null-cons word `(idx << 43) | 0b111`, where `idx` is its
    declaration index (`runtime/src/allocator/Heap.hpp:14-25, 360-393`). Null-cons words are **not
    unique per type**.
- **`eco.get_tag`** (`RuntimeExports.cpp:4391-4414` and the inline expansion at
  `EcoBackend.cpp:2493+`) returns:
  - the index for a null-cons word, 0xFFFD (`CtorTag.constantTag`) for Empty, and 0 or 1 for
    False or True;
  - the `ctor` field for a `Custom`, 1 for a list cell, and **0 for every other heap object**
    (tuple, record, closure, string).

  `Just` has tag 0. A bare record read as a `Maybe` would therefore silently look like `Just`.
- **`Debug.toString` is typed.** The compiler emits `eco.type_table`
  (`GenerateMlir/TypeTable.elm`), and the call site passes a type id computed from the argument's
  `MonoType` (`Expr.elm:3807-3817`, `Ctx.getOrCreateTypeIdForMonoType`). The printer is
  `print_typed_value` (`runtime/src/allocator/RuntimeExports.cpp:3794`). Type kinds are
  `EcoTypeKind` 0–6 (`runtime/src/allocator/TypeInfo.hpp:47-55`).

A probe (one function per case, `--text-mlir`) confirmed the passes catch only local cases:

| Case | Today |
|---|---|
| let-bound wrapper, only unwrapped | SSA, no allocation |
| `f (Q x)` where `f` gets inlined | SSA, no allocation |
| wrapper returned from a function, or passed to one that is not inlined | heap on both sides |
| `List.map Q xs`, `List.foldl add (Q 0)` | one heap object per element or step |
| `case WorkA x of ...` on a multi-constructor type | heap, even though built and matched locally |

### 1.2 Measurements (2026-11-19)

**Dynamic.** These numbers come from the compiler self-compiling (`eco-compiler-boot make
--optimize`, solver and LSS, cold project cache), measured with scratch instrumentation:

- Every `eco.construct.custom` site was tagged.
- The runtime counted allocations at each site, and promotions in the minor-GC copy paths.
- One-constructor versus multi-constructor was classified from source declarations by
  (constructor name, field count). 215 of 54,934 sites were ambiguous.
- The instrumented compiler's output was byte-identical to an uninstrumented one.
- Kernel-built customs were not counted as allocations. They appear only as unclassified
  promotions (about 7k).

**That instrumentation is lost.** Its worktree no longer exists. Unit M0 (§3) rebuilds it properly,
and its first gate is to reproduce this table to within a few percent.

| Level | Allocated | % | Promoted | % | Main constructors (allocated) |
|---|---|---|---|---|---|
| 1 | 103.4M | 8.6 | 7.4M | 5.4 | `Unify` 37.5M, `Parser` 22.1M, `Pt` 17.9M, `StringTable` 8.3M, `RResult` 6.6M, `Set_elm_builtin` 2.4M, `Decoder` 1.7M |
| 2 | 124.0M | 10.3 | 22.3M | 16.2 | `Array_elm_builtin` (4 fields) 71.2M, `FieldType` (2) 20.7M, `UnifyOk` (2) 20.5M, `OpBuilder` (2) 3.4M |
| 3 | 425.6M | 35.3 | 17.1M | 12.4 | `Just` 299.8M, `Leaf` 30.1M, `Ok` 20.9M, `SubTree` 20.5M, `Structure` 15.1M, `U8` 13.9M |
| 4 | 553.7M | 45.9 | 90.5M | 65.9 | `RBNode_elm_builtin` 394.5M, `TType` 32.6M, `Root` 32.1M, `App1` 10.3M |
| ambiguous | 0.6M | 0.0 | 0.2M | 0.1 | |
| total | 1,207M | | 137.4M | | |

- `Pt` (promoted 7.0M) and `FieldType` (19.3M of 20.7M promoted) are long-lived. `Unify`,
  `Parser` and `UnifyOk` are never promoted: pure allocation churn.
- This is one workload, a compiler built from monadic parsers and unifiers. `Just` and `Dict`
  occur in nearly every Elm program; `Unify`/`Parser` stand for any wrapped-function style.

**Static.** Type definitions by shape, counted from source:

| Corpus | Types | 1 ctor 1 field | 1 ctor 2+ fields | multi, all ≤1 field | multi, some 2+ | enum |
|---|---|---|---|---|---|---|
| `compiler/src` | 632 | 98 | 99 | 113 | 230 | 92 |
| all packages on disk (eco home and `~/.elm`) | 1,543 | 367 | 155 | 402 | 248 | 371 |
| eco test, example and benchmark programs | 504 | 163 | 55 | 139 | 71 | 76 |

## 2. Ground rules for every unit

These apply to every unit below; the units do not repeat them.

1. **Read before touching code.** Read `design_docs/invariants.csv`, at least the rows each unit
   names, and `design_docs/theory/compiler/monomorphization.md` and `mlir-generation.md`.
2. **Tests first** (project rule). Each unit's fixtures land first, passing against today's
   compiler (they pin current output). A fixture that exposes a pre-existing bug lands as XFAIL
   with the bug recorded. Record the expected Elm semantics from `node` when in doubt.
   - E2E fixtures go in `test/elm/src/<Name>Test.elm` with `-- CHECK:` lines. See
     `test/elm/src/CaseMaybePairTest.elm` for the format.
   - Unit tests go in `compiler/tests/<same folder as the source module>/<Module>Test.elm`.
   - Pipeline tests over SourceIR cases go in `compiler/tests/TestLogic/...`, with cases in
     `compiler/tests/SourceIR/<Topic>Cases.elm`, registered in
     `SourceIR/Suite/StandardTestSuites.elm`.
3. **Every behaviour change sits behind a config switch**, default off until its gates pass, then
   flipped on in a separate commit. A new switch is added like `ctorInline`:
   1. the field in the `EcoConfig` alias (`Compiler/Config.elm:101`) and its doc (`:61-72`, which
      counts the switches);
   2. the default in `default` (`:545`);
   3. a `D.apply (D.optionalField "<name>" D.bool default.<name>)` in `decoder` at the **same
      position** as the field in the alias. The decoder is positional, as at `:588`;
   4. a hash token in `hash` (`:1147-1151` pattern), because each switch changes the output;
   5. the env override in `Builder/Eco/Config.elm`: add it to the `applyEnvOverrides` chain
      (`:334-337`) with an `apply<Name>Override` modelled on `:880-901`;
   6. rows in `docs/options.md` (env table near `:196`, JSON table near `:258`).
4. **Gates for any unit that changes generated code:**
   - `cmake --build build --target elm-tests`;
   - `cmake --build build --target full` (Gate A);
   - `cmake --build build --target bootstrap` (fixed point, Stage 8c);
   - the unit's fixtures under `ECO_MONO_VALIDATE=1`.

   Run each once, with output teed to `/tmp/test_output.txt` (CLAUDE.md). Before trusting E2E
   after a compiler change, wipe `build/test/*/eco-stuff` and the `~/.eco/<version>` package
   artifacts: `full` clears neither.
5. **Every pipeline goes through `Compiler/Pipeline/Steps.elm`.** A new mono-level pass is a new
   `Steps` function, called from all four drivers:
   - `Builder/Generate.elm` `monoPipelineFrom` (:941-987);
   - `compiler/tests/TestLogic/TestPipeline.elm` (:629-680);
   - `compiler/tests/Compiler/PackageCompilation.elm` (:630-681);
   - `compiler/tests/TestLogic/MonoOpt/PostPruneGraphClosed.elm`.

   `Steps` never prints. A step returns its report text, and `Generate` writes it to stderr.
6. **New `MonoGraph` fields.** A field added to `MonoGraph` (`IR/Mono.elm:3002-3019`) must be
   initialised everywhere a `MonoGraph` record is built: grep `Mono.MonoGraph {` and
   `MonoGraph {`, including `Prune.rebuild` (`Monomorphize/Prune.elm:~365`) and test helpers.
   Give every new field an empty default so that untouched pipelines behave exactly as before.
7. **Commit messages** follow `GITSTYLE.md`, with no assistant attribution trailers.

## 3. Unit M0: the constructor census

**Goal.** For a compiled program, count allocations and minor-GC promotions per constructor
class, and attribute each class to a level. It must work in both JIT and AOT runs. It must cost
nothing when off.

**Design decisions.**
- Ids are per **constructor class**, not per site. A class is
  `(level, home, type name, ctor name, payload class)`. The table has to fit 15 bits, so that a
  promoted object can carry its id in its header. Per-site detail was not used by any §1.2
  number.
- The compiler owns the id table and writes it to a file. The runtime knows only ids. No string
  tables are compiled into the binary.
- The id lives in the 15-bit `Header.refcount` field (`Heap.hpp:156`), which is used only on
  `Tag_Free` cells (`OldGenSpace.hpp:148-196`). It is copied with the header on promotion.
  Id 0 means unattributed: kernel-built objects and out-of-line allocations.

### M0.1 Compiler side

1. **Switch.** Add `ctorCensus : Maybe String` to `EcoConfig`, holding the output path for the
   table. Follow §2 rule 3, with these differences:
   - env `ECO_CTOR_CENSUS=<path>`;
   - JSON key `ctorCensus` (string);
   - hash token `ctorc=1` when it is set. The MLIR differs, so cached artifacts must not mix.
2. **Classification**, in a new module `Compiler/GenerateMlir/CtorCensus.elm`:
   ```elm
   type alias CensusKey = { level : Int, home : String, typeName : String, ctor : String, payload : String }
   build : Mono.MonoGraph -> { ids : Dict String Int, table : List ( Int, CensusKey ) }
   idFor : Mono.MonoType -> Name -> Ctx -> Maybe Int   -- result type, ctor name
   ```
   - Walk every `MonoCtor home shape resultType` node. `resultType` is `MCustom _ home typeName
     args`. The shapes of `resultType` come from `ctorShapes` (`Mono.layoutMapGet`).
   - The level comes from the shape list:
     - one shape with one field → 1;
     - one shape with ≥2 fields → 2;
     - several shapes, each with ≤1 field → 3;
     - otherwise 4.
   - `payload` is `"-"` except for level-3 constructors with one field. For those it is
     `"adm"` or `"inadm"` under the N1 admissibility rule (§7.2, `NullableMaybe.admissible`).
     Until N1 exists, compute it with a local copy of the rule. After KV lands (§4), add a `"kv"`
     suffix when the type is kernel-visible.
   - The level-1 classes get the same treatment for E: the payload is `"boxed"`, `"unboxed"` or
     `"kv"`.
   - Assign ids from 1 in table order, capped at 32,767. If the cap is hit, map the rest to 0
     and print a warning.
   - Write the table as TSV to the path from `ctorCensus`, one row per id:
     `id level home type ctor payload`. `Builder/Generate.elm` writes it; `Steps` does not.
3. **Emission.**
   - `Ops.ecoConstructCustom` (`GenerateMlir/Ops.elm:311-332`) gains an optional census id. When
     present, it adds `_census_id = IntAttr id`.
   - Every caller passes `CtorCensus.idFor resultType ctorName ctx` when the switch is on:
     - `Functions.generateCtor` (`Functions.elm:1421`, op at 1536);
     - `Expr.generateCustomCreateHeap` (7232/7245);
     - `Patterns.materializeSplitParam` (`Patterns.elm:362-367`);
     - `BytesFusion/Emit.elm:2031,2041`.
   - Also count SSA constructions that never allocate: `eco.make.custom` (`Expr.elm:7219`) gets
     the same attribute. The backend counts it as "promoted to SSA", which tells E4/N0 what
     `aggPromote` already removes.
   - Put the `CtorCensus` table in `Ctx` (`Context.elm`) next to `ctorShapes`. Build it once in
     `Backend.elm` where `Ctx` is initialised.

### M0.2 Backend and runtime side

1. **Runtime counters** (`runtime/src/allocator/`, new file `CtorCensus.cpp/.hpp`):
   ```cpp
   extern "C" uint64_t eco_ctor_census_alloc[32768];    // compiled-code allocations
   extern "C" uint64_t eco_ctor_census_ssa[32768];      // eco.make.custom executions
   uint64_t eco_ctor_census_promoted[32768];            // under ENABLE_GC_STATS
   ```
   - They are always defined (BSS, untouched unless used), so census-compiled code links on every
     preset.
   - At exit, if `ECO_CTOR_CENSUS_OUT` is set, write `id alloc ssa promoted` for each nonzero id
     to that path. Hook into the same exit path that prints `GCStats` (`GCStats.cpp` `print`).
2. **Allocation increments.**
   - In `CustomConstructOpLowering` (`codegen/Passes/EcoToLLVMHeap.cpp:1078-1185`): if the op has
     `_census_id = n`, emit before the allocation a non-atomic `load / add 1 / store` on
     `&eco_ctor_census_alloc[n]`. Declare the global as an external `llvm.mlir.global`. JIT
     resolves it like any runtime symbol, and HEAP_007 allows only one mutator.
   - Do the same for `eco.make.custom` lowering into `eco_ctor_census_ssa`.
   - Keep `_census_id` through every earlier pass. Check the canonicalizer and
     `EcoPAPSimplify`-style rewrites that rebuild `CustomConstructOp`, and copy discardable
     attributes where an op is rebuilt. Grep `CustomConstructOp::create`.
3. **Header id.**
   - On the inline path (`EcoToLLVMHeap.cpp:1110-1131`), pass `n` as the refcount bits to
     `value_enc::composeHeader` (`EcoToLLVMInternal.h:377`).
   - On the out-of-line `eco_alloc_custom` path (objects over 4096 bytes), leave 0.
   - **Before relying on this**, grep `refcount` across `runtime/src` and confirm no live-object
     code reads or asserts it: the heap validator, the snapshot code and `zeroNewObject`. If
     something does, add an exemption gated on the census.
4. **Promotion counting** (`#if ENABLE_GC_STATS`), at the three promotion paths:
   - `NurserySpace::copyClaimed`, `NurseryParallel.cpp:262` (counted at :282);
   - the serial tenure `copy`, `NurseryTenure.cpp:115` (:126);
   - the parallel tenure engine, `NurseryTenure.cpp:~1104`.

   If `hdr.tag == Tag_Custom`, increment `promoted[hdr.refcount]`. Parallel workers count into a
   worker-local `std::vector<uint64_t>` that is allocated on first use when
   `ECO_CTOR_CENSUS_OUT` is set. Add it to `MinorCopyCounts` (`GCStats.hpp:1289-1338`) and merge
   it in `mergeCopyCounts` (:1340).
5. **Report script** `scripts/ctor-census.py TABLE.tsv COUNTS.txt`. It joins the two files and
   prints:
   - the §1.2 level table (allocated, SSA, promoted, with percentages);
   - the top 10 classes per level;
   - a `--by payload` breakdown, used by the E4, KV0 and N0 gates.

### M0.3 Tests and gate

- **Unit.** `compiler/tests/Compiler/GenerateMlir/CtorCensusTest.elm`: the level classification
  for one type of each shape, and the payload classes for `Maybe Int`, `Maybe {x:Int}` and
  `Maybe String`.
- **Codegen.** `test/codegen/ctor_census_inline.mlir`: a `construct.custom` with `_census_id = 5`
  lowers to an increment of `eco_ctor_census_alloc[5]` and a header whose refcount bits are 5.
- **E2E.**
  - Compile `test/elm/src/CaseMaybePairTest.elm` with the census on and check that the `Just`
    class has the expected count.
  - Check the census-off MLIR of the whole E2E suite is byte-identical to before.
- **Gate M0-G.** Run Stage 7a (the self-compile of `bootstrap.md`) with the census on, using the
  `build` preset, which has `ENABLE_GC_STATS`. The level table matches §1.2 within ±3 % per
  level. The compiler output must be byte-identical to an uncensused run. Record the run's
  command line in `benchmarks/ctor-census.md` as the baseline for every later gate.

## 4. Unit KV: the kernel-visibility set

**Goal.** Compute, per program after monomorphization, the set of type constructors whose
representation must not change, because C++ builds, reads, or receives them in a known shape.

### 4.1 The table: `Compiler/IR/Kernel/Visibility.elm` (new)

```elm
type KernelUse
    = Transparent              -- only moves or generically compares its type-variable values
    | Inspects (List TypeRef)  -- builds or reads exactly these type constructors
type alias TypeRef = { pkg : String, home : String, name : String }

kernelUses : Dict ( String, String ) KernelUse    -- (home, name) of a MonoVarKernel; absent = deny-all
managerUses : Dict String (List TypeRef)          -- effect-manager home -> types its C++ manager reads/builds
byName : List TypeRef                             -- matched by name in compiler or C++ code
opaque : List TypeRef                             -- kernel-produced values behind a dummy declaration
```

Every entry carries a comment citing the C++ that justifies it (file:line).

**Seed contents.** These come from the KV0 groundwork audit. KV0 completes the table.

- `byName`:
  - `Bytes.Decode.Decoder` (BytesFusion `Reify.elm:2067,2132,2199`, `Expr.elm:3691`);
  - `Array.Array` (`Array_elm_builtin`, built in `JsonExports.cpp:722-728`, printed by name in
    `RuntimeExports.cpp:3650`);
  - `Dict.Dict` (`RBNode_elm_builtin`/`RBEmpty_elm_builtin`, reserved tags in `CtorTag.elm`,
    `Utils.cpp:38`, `HttpExports.cpp:242-277`);
  - eco/system `SeqDict`;
  - `Set.Set` (`Set_elm_builtin`, printer `RuntimeExports.cpp:3647-3650`). Remove `Set.Set` in
    E2, once the printer has a Wrapper arm for it.
- `opaque`: the A3 list.
  - **elm/core:** `Platform.Program`/`Task`/`ProcessId`/`Router`, `Platform.Cmd.Cmd`,
    `Platform.Sub.Sub`, `Elm.JsArray.JsArray`.
  - **elm/bytes, elm/json:** `Bytes.Bytes`, `Json.Encode.Value`, `Json.Decode.Decoder`.
  - **elm/http:** `Body`, `Part`, `Expect`, `Resolver`.
  - **Others:** `File.File`, `Regex.Regex`, `Browser.Navigation.Key`, `VirtualDom.Node`,
    `VirtualDom.Attribute`.
  - **eco/system:** `Html.Dom.Tagger`/`Handler`, `FileSystem.Handle` access phantoms, `JsArray2`.
  - **elm-explorations:** the WebGL and linear-algebra types.

  `JsArray a = JsArray a` and `JsArray2` matter most here. They have a placeholder field, so they
  would otherwise classify as level 1.
- `kernelUses = Transparent` candidates (each still read before marking):
  - `List.cons`, `reverse`, `append`, `concat`, `take`, `drop`, `fromArray`, `toArray`,
    `map2`–`map5`, `sortBy`, `sortWith`;
  - all of `JsArray.*`;
  - `Scheduler.succeed`, `fail`, `andThen`, `onError`, `spawn`;
  - `MVar.*`;
  - `Platform.sendToApp`, `sendToSelf`;
  - `Utils.equal`, `notEqual`, `compare`, `lt`, `le`, `gt`, `ge`, `append`;
  - `Basics.*`;
  - `Debug.todo`;
  - `Debug.log` and `Debug.toString`, but only once E2 lands. Until then they are deny-all.
- **Not transparent:**
  - `FNV.hash`: it hashes structure, so its output would change with representation (decision
    D10);
  - every Json, Bytes, VirtualDom, Http, Regex, Time, Url and Browser kernel. Give these
    `Inspects` entries from the audit.
- `managerUses`: one entry per effect-manager home, listing its `MyCmd`/`MySub` types and the
  types its C++ builds:
  - Task: `Task.MyCmd`;
  - Time: `Time.MySub`, `Time.Posix`;
  - Http: its MyCmd and MySub, `Http.Response`, `Http.Progress`;
  - `Browser.Dom.Error` (`BrowserExports.cpp:27`);
  - System, FileSystem, Socket, Udp, Terminal, WebSocket, HttpServer and ChildProcess, from their
    managers.

### 4.2 The analysis: `Compiler/MonoOpt/KernelVisible.elm` (new)

```elm
type alias KvSet = { ctors : Set ( String, String ) }   -- (home, type name)
compute : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> KvSet
isVisible : KvSet -> Mono.MonoType -> Bool              -- head type constructor is in the set
```

**Roots.** Walk every node with `Traverse.foldExpr`.

| Where | Root types | Closure |
|---|---|---|
| `MonoCall _ (MonoVarKernel _ _ home name _) args resTy _` with `kernelUses` = `Transparent` | none | none |
| the same with `Inspects ts` | every `MCustom` in `typeOf arg`/`resTy` whose ctor is in `ts` | **declared** |
| the same, absent from `kernelUses` | every `typeOf arg` and `resTy` | **deny-all** |
| `MonoVarKernel` not in call position (first-class) | its own `MonoType` | deny-all |
| `MonoManagerLeaf home ty` node | every `MCustom` in `ty` whose ctor is in `managerUses home` | declared |
| `MonoPortIncoming`/`MonoPortOutgoing` node | its type | deny-all |
| flags: the parameter type of `main`'s flags decoder (`flagsDecoder` spec) | that type | deny-all |
| every `MCustom` in any `ctorShapes` key whose ctor is in `byName` or `opaque` | that key | the ctor itself only |

Use the argument and result *expression* types, not the `MonoVarKernel`'s own type. A kernel with
a type variable has a boxed root ABI, so its reference type carries `MVar _ CEcoValue` there
(`Monomorphize/KernelAbi.elm:15-25`).

**Closures.** Add each reached type constructor to `ctors`, then recurse:
- **deny-all:** into every type argument of every `MCustom`, including opaque ones, since a
  kernel-built `Task x Posix` produces a `Posix`. Also into every field type of every shape of
  that `MCustom` (from `ctorShapes`), list elements, tuple elements, record fields, and function
  parameters and results. Stop at primitives and `MVar`.
- **declared:** for each listed `MCustom`, recurse into the fields whose *declared* type is not a
  bare type variable. Get the declaration from `Analysis.lookupUnion typeEnv home name`
  (`Monomorphize/Analysis.elm:366`, `Can.Union` alts). Take the instantiated field `MonoType`
  from the same position in `ctorShapes`, and continue with **declared** closure for further
  listed types, otherwise deny-all.
  - So `Result e a` built by a Json kernel marks `Result` but not the user's `a`.
  - `MyCmd = Perform (Task Never msg)` marks `Task`, which is opaque, and not `msg`.
- Track visited `MonoType`s in a `Mono.LayoutMap ()` so that recursive types terminate.

**Why no fixed point with erasure.** The closure already includes every type nested inside a
root. Erasure only removes wrappers that are *not* in `KvSet`, so it cannot add new roots. The
original plan's "iterate to a fixed point" is unnecessary and is dropped.

`Steps.eraseWrappers` and `Steps.nullableMaybe` call `compute`, which is why both take a
`GlobalTypeEnv`. All four drivers already have one, since `Steps.monomorphize` takes it.

### 4.3 KV0: audit and measure

1. **Fill the table.** For each kernel export the groundwork scan flagged (144 of 507 exports
   reach a custom-touching function), read the C++ and write an `Inspects` or `Transparent`
   entry with its citation. Anything not read stays absent, which means deny-all.
   - Re-run the scan to find the list. Grep `alloc::custom`, `alloc::just`, `justKind`,
     `alloc::ok`, `alloc::err`, `nothing(`, `->ctor` and `eco_alloc_with_roots(Tag_Custom` in
     `elm-kernel-cpp/`, `eco-kernel-cpp/`, `system-kernel-cpp/` and `runtime/src`, and walk
     callers up to the `Elm_Kernel_*`/`Eco_Kernel_*` exports.
   - Effect managers are reached through registration (`onEffectsEval`/`subMapEval`/
     `cmdMapEval`), not through exports. Read each manager.
   - `Platform.worker`, `Browser.*` and the other program kernels need explicit `Inspects`
     entries (Cmd, Sub and the tuple only). Under deny-all they would mark the whole user
     `Model`/`Msg` graph. HEAP_045 already makes the model boxed at that boundary.
2. **Unit test.** `compiler/tests/Compiler/MonoOpt/KernelVisibleTest.elm`. Build small graphs and
   check:
   - a wrapper passed to an unlisted kernel is visible;
   - a wrapper passed to `List.cons` is not;
   - `Result Error UserRec` from a Json `Inspects` kernel marks `Result` but not `UserRec`;
   - a wrapper inside `Time.Posix -> msg` under a `MonoManagerLeaf` is visible.
3. **Census.** Add the `kv` suffix (M0.1 step 2).
4. **Gate KV0-D.** Run the census on Stage 7a.
   - If KV excludes more than 25 % of the level-1 pool's allocations, or of the admissible
     `Just` pool, find the kernels responsible (add a `--why` mode to `KernelVisible` that prints
     the root for each visible type) and audit them into `Inspects`/`Transparent`.
   - Repeat until under 25 %, or until every remaining root is genuinely inspecting.
   - Record the final numbers in `benchmarks/ctor-census.md`.

### 4.4 Invariant

Add **MONO_032**:

> A type constructor in the kernel-visibility set (`Compiler.MonoOpt.KernelVisible`) keeps its
> heap representation: `EraseWrappers` and `NullableMaybe` never change it. The set's roots and
> closure rules are those documented in that module.

## 5. Unit V: representation meets, and a representation validator

**Goal.** Find every pair of `MonoType`s that describe the same runtime value, grouped into
components. E1b and N1 use the components to decide; the validator checks the result.

**Why it is needed.** MONO_029 says views agree at every interior position, but
`Monomorphize/ValidateLayout.elm` checks only three things, all for ABI kind:
- tuple and list destructor paths;
- tail-call arguments against loop parameters;
- tuple-creation elements.

Its doc (:29-34) calls a mismatch between an erased type variable and a concrete type in captures
and ordinary call arguments "harmless". That is true today only because both sides are boxed heap
shapes of the same kind. E1b (wrapper → `f64`) and N1 (`Maybe Rec` → bare `Rec`) make it false.

### 5.1 The pair collector: `Compiler/Monomorphize/RepresentationMeets.elm` (new)

```elm
type alias Meet = { a : MonoType, b : MonoType, root : Bool, site : String }
collect : Mono.MonoGraph -> List Meet                  -- every recorded pair, recursively split
components : List Meet -> UnionFind                    -- over MonoType keys (Mono.LayoutMap-based)
componentOf : UnionFind -> MonoType -> List MonoType
```

**Sources of pairs.** Walk each node's body, keeping an environment from local names to their
binding types.

| Construct | Pairs (`a` = what the value is, `b` = what the consumer expects) |
|---|---|
| `MonoVarGlobal _ s t` | (`t`, type of node `s`); for a `MonoCtor` node, use `MFunction shape.fieldTypes resultType` |
| `MonoVarLocal name t` | (binding type of `name`, `t`) |
| `MonoCall _ f args resTy _` | for each `i`: (`typeOf args[i]`, i-th parameter of `typeOf f`), walking `MFunction` stages in order; and (result of `typeOf f` after `length args` parameters, `resTy`) |
| `MonoTailCall` args | (`typeOf arg`, loop parameter type) |
| `MonoClosure info body t` | for each capture `(n, e, _)`: (`typeOf e`, binding type of `n` inside the body); (`typeOf body`, result of `t`) |
| `MonoLet (MonoDef n e) body t` | records `n : typeOf e` in the environment; (`typeOf body`, `t`) |
| `MonoDestruct (MonoDestructor n path ty) body t` | (type the path yields, `ty`); records `n : ty` |
| `MonoCase`/`MonoIf` branches | (`typeOf branch`, the case/if result type) |
| record, tuple and list construction | (`typeOf element`, the slot type in the container type) |
| `MonoDefine e t`, `MonoTailFunc … body t` | (`typeOf e` or `typeOf body`, `t`) |

All of these are `root = True`.

**Splitting.** `pair a b root` does the following:
- If `a == b` (`Mono.eqKeySpec`-style), stop.
- If either side is `MVar _ CEcoValue`, record `(a, b, root)` and stop.
- If both have the same head (`MList`, `MTuple`, `MRecord` by field name, `MCustom` with the
  same home and name, `MFunction` with the same stage shape), record `(a, b, root)` and recurse
  into the children with `root = False`. Function parameters and results count as interior
  positions.
- If the heads differ (for example `MInt` vs `MCustom`), record the pair and report it. That is
  a type-system bug, so the collector returns `Err` under validate.

**Components.** Union `a` and `b` for every recorded pair. A component is a set of `MonoType`
keys that some runtime value is viewed as.
- E1b uses components built from interior pairs only (`root = False`), because call-boundary
  boxing (CGEN_001/CGEN_007) repairs a root `f64` ↔ `!eco.value` mismatch.
- N1 uses all pairs, because no boxing converts between two `!eco.value` shapes.

### 5.2 The validator: `Compiler/Monomorphize/ValidateRepresentation.elm` (new)

```elm
validate : { nullable : Mono.LayoutMap NullableInfo } -> Mono.MonoGraph -> List String
```

- Over `collect graph`, every interior pair must have equal **slot kind**: `MInt` → Int,
  `MFloat` → Float, `MChar` → Char, everything else → boxed. This is what the mono engines
  promise under MONO_029 and what E1b must preserve.
- Every pair, root or interior, where one side is in `nullable` must have the other side equal
  to it. No erased or other view may meet a nullable `Maybe`.
- Wire it as `Steps.checkRepresentation : Config.EcoConfig -> … -> Result String ()`, active
  under `mono.validate` like `checkLayout` (`Steps.elm:287-305`). Call it after
  `eraseWrappers` and after `nullableMaybe`.

### 5.3 V0: baseline

1. **Unit test.** `compiler/tests/Compiler/Monomorphize/RepresentationMeetsTest.elm`:
   - a `List (Q Float)` argument to a spec whose parameter is `List a` gives one interior pair
     (`Q Float`, `MVar`);
   - a captured `Maybe Rec` read as `Maybe a` gives a root pair.
2. **Run on the unchanged compiler.** Run `checkRepresentation` over all E2E programs
   (`ECO_MONO_VALIDATE=1 cmake --build build --target full`) and Stage 7a.
   - **Expected:** no slot-kind violations.
   - **Any violation is a pre-existing MONO_029 miscompile.** Add a fixture for it (XFAIL) and fix
     it in the mono engine, or the representation work cannot proceed.
3. **Also print the number of interior pairs with an `MVar` side** on the self-compile. This
   is the size of E1b's and N1's exclusion surface. Record it in `benchmarks/ctor-census.md`.

### 5.4 Invariant

Amend **MONO_029**: its enforcement column names `Compiler.Monomorphize.ValidateRepresentation`
as the check of interior slot-kind agreement at every pair source listed in §5.1.

## 6. Level 1: erase one-constructor one-field wrappers (group E)

**Goal.** Represent a value of wrapper type `W args = C payload` as the payload itself, in SSA,
ABI, heap fields and closures. This is Elm's own `Unbox` optimization, which the JS backend
already applies.

Two stages:
- **E1a** erases a wrapper type constructor whose payload is boxed in every reachable
  instantiation. This needs no V: every view goes from one boxed word to another, and no code
  inspects the value as a wrapper after the rewrite.
- **E1b** extends erasure to individual instantiations whose payload is Int, Float or Char, using
  V's components to exclude those that meet an erased view.

### 6.1 E0: fixtures (land first, pinning today's output)

E2E, in `test/elm/src/`, each with `-- CHECK:` lines that print values with `Debug.log`:

| File | Content |
|---|---|
| `EraseWrapperFloatContainersTest.elm` | `type Q = Q Float` inside a `List`, a `Dict` value, a record field, a closure capture, and a `Maybe` |
| `EraseWrapperFunctionTest.elm` | a parser-style wrapper `type P a = P (String -> Maybe (a, String))` with `map`/`andThen`, `List.map P`, partial application of `P` |
| `EraseWrapperPolyTest.elm` | `type Box a = Box a` used at `Int`, `String`, a record, and inside a polymorphic helper that keeps `a` erased (empty-list argument) |
| `EraseWrapperPhantomTest.elm` | `type Quantity number units = Quantity number` at `Float` and `Int` with two phantom units |
| `EraseWrapperRecursiveTest.elm` | `type T = T (List T)`, and mutually recursive wrappers `type A = A (List B)` / `type B = B (Maybe A)` |
| `EraseWrapperEqualityTest.elm` | `==` and `/=` on wrapped values, nested wrappers, wrappers in tuples |
| `EraseWrapperDebugTest.elm` | `Debug.toString` of `Q 1.5`, `Box (Box "x")`, `[Q 1, Q 2]`, `Dict` of wrappers, `Set` (prints `Set.fromList`), a record holding a wrapper |
| `EraseWrapperPortTest.elm` | a wrapper in an outgoing port and in flags (must stay heap: KV) |
| `EraseWrapperSetDictTest.elm` | `Set` operations and `Set` equality |
| `EraseWrapperModelTest.elm` | `Platform.worker` whose model is `type Model = Model Float` |

A BytesFusion program already in the bytes suite must keep passing; `Bytes.Decode.Decoder` is on
`byName`.

The unit tests in `compiler/tests/Compiler/MonoOpt/EraseWrappersTest.elm` are listed in §6.4,
together with E1.

Put a SourceIR case module `compiler/tests/SourceIR/WrapperCases.elm` (the programs above, in
miniature) in `StandardTestSuites`. It then runs through both mono engines and the existing
TestLogic checkers.

### 6.2 E2: printing erased wrappers (lands before E1a is switched on)

**The problem.** After erasure the argument of `Debug.toString` has the payload's `MonoType`, so
the type id no longer names the wrapper.

**Decision D5:** carry the pre-erasure type on the call, and let the type table describe
wrappers.

1. **`CallInfo.printType : Maybe MonoType`.**
   - Add the field to `CallInfo` (`IR/Mono.elm:3896`) with default `Nothing` in
     `defaultCallInfo`. Set it in the four other record literals that build a `CallInfo`
     (grep `evaluatorReturnType =`).
   - Do **not** add it to `Traverse.mapNodeTypes` or `anyNodeType`. It holds the unerased type
     on purpose.
2. **Use it in codegen.** In `Expr.elm`'s `Debug.log` (:3807) and `Debug.toString` (:3866)
   arms, use `Maybe.withDefault (Mono.typeOf valueExpr) callInfo.printType` as `valueMonoType`.
3. **New `MonoGraph` field** (§2 rule 6):
   ```elm
   erasure : { printShapes : LayoutMap (List CtorShape), erasedKeys : LayoutMap () }
   ```
   - `printShapes` is the `ctorShapes` from before erasure.
   - `erasedKeys` holds every unerased `MCustom` key that was erased.
   - Both are empty by default.
4. **Type table (Elm).** In `GenerateMlir/TypeTable.elm`:
   - Add `TKWrapper` → 7 to `TypeKind`/`typeKindToTag` (:66-113).
   - In `processType` (:259), an `MCustom` key found in `erasedKeys` is emitted as kind 7 with
     the same data layout as Custom: `[id, 7, firstCtor, 1]`, with one ctor entry `[tag 0,
     name_index, first_field, 1]` whose field is the payload's type id.
   - Resolve shapes from `printShapes` first, then from `ctorShapes`. Make
     `Ctx.getOrCreateTypeIdForMonoType` (`Context.elm:478-500`) do the same.
5. **Type table (C++).**
   - `EcoTypeKind::Wrapper = 7` (`TypeInfo.hpp:47-55`). Append it; the enum order is fixed. Its
     `data` reuses the custom struct.
   - `case 7` in `EcoToLLVMGlobals.cpp:348-384`, copying the Custom arm.
6. **Printer** (`RuntimeExports.cpp`, `print_typed_value` :3794).
   - A Wrapper arm: print the ctor name, a space, then the payload through `print_ctor_arg`
     (parenthesised as a constructor argument) with the payload type id. The value word *is* the
     payload.
   - `builtin_container_of` (:3639-3651) keeps matching by ctor name. Route `Set_elm_builtin`
     reached through a Wrapper to the Set arm (:3758-3776), in a variant that takes the payload
     `Dict` word directly instead of requiring a heap `Custom`. Then remove `Set.Set` from
     `Visibility.byName`.
   - For E1b (unboxed payloads), every slot-kind site must see through Wrapper to the payload's
     primitive:
     - :3881, :3907 (asserts false otherwise);
     - tuples at :3961/3971/3989/3999/4009;
     - records at :4087, custom fields at :4211;
     - `print_typed_slot` :3617.

     Add a helper `resolveWrapper(typeId)` that follows kind 7 to the payload type id, and call
     it at the top of each site. This is unit **E2b**, landing with E1b.
7. **Known limitation**, recorded in the MONO_031 text: a wrapper reaching the *untyped* printer
   (`Debug.toString` used as a first-class function, or a value under an erased `MVar`) prints
   as its payload.

**Tests.**
- `test/codegen/type_table_wrapper.mlir`: a kind-7 entry lowers.
- `test/allocator/` or `test/kernel/`: the printer prints a Wrapper over Float, a String, a
  record, and `Set_elm_builtin` over an RBNode.
- `EraseWrapperDebugTest.elm` output is unchanged with E1a on.

### 6.3 E1a: the pass `Compiler/MonoOpt/EraseWrappers.elm` (new)

```elm
type alias EraseStats = { erasedCtors : Int, erasedKeys : Int, excludedKv : Int, excludedCycle : Int, excludedUnboxed : Int, ctorCallsRemoved : Int, unboxStepsRemoved : Int }
erase : { allowUnboxed : Bool } -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> ( Mono.MonoGraph, EraseStats )
```

**Pipeline placement.**
- Add `Steps.eraseWrappers : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> (
  Mono.MonoGraph, EraseStats )`, a no-op unless `cfg.eraseWrappers`. Add
  `Steps.checkErased` (MONO_031, under `mono.validate`).
- In `Builder/Generate.elm` `monoPipelineFrom`, call them right after `Steps.checkLayout`
  (:963) and before `runInlineSimplifyPhase` (:972), followed by `Steps.checkRepresentation`.
- Call them at the same point in the three test drivers (§2 rule 5).
- Print `EraseStats` with the inline report (`ECO_INLINE_REPORT`, `pruneAndReportInline`,
  `Generate.elm:1037-1055`).

**Step 1: candidate type constructors.**
- `ctorShapes` lists every constructor of every reachable `MCustom`
  (`Analysis.computeCtorShapesForGraph`). So a type constructor `(home, name)` is a candidate
  when **every** `ctorShapes` key `MCustom _ home name _` has exactly one shape with exactly one
  field. By `toOpts`, that is exactly `Can.Unbox`.
- Remove from the candidates:
  1. **KV:** `KernelVisible.isVisible kv` for any key of the constructor, and `byName`/`opaque`
     members (counted in `excludedKv`).
  2. **Unboxed** (E1a only): any key whose payload, after erasing nested candidates, is `MInt`,
     `MFloat` or `MChar` (`excludedUnboxed`). Compute this after step 3.
  3. **Cycles:**
     - Build a directed graph on candidates with an edge `W → W'` when `W'` occurs anywhere in
       the payload type of any key of `W`.
     - Compute SCCs (Tarjan over a `Dict (String, String) (List …)`) and drop every candidate on
       a cycle: an SCC of size > 1, or a self-loop (`excludedCycle`).
     - One pass is enough: dropping a candidate only removes edges.
     - `type T = T (List T)` is a self-loop; erasing it would make the type infinite.
- Repeat rule 2 after rule 3, since dropping a cyclic wrapper can change what a payload erases
  to. Use a small loop until the set stops shrinking.

**Step 2: the type eraser.**
```elm
eraseType : Erasable -> MonoType -> MonoType
```
- `MCustom _ h n args` with `(h, n)` erasable becomes `eraseType` of the payload. Take the
  payload from `ctorShapes` at that exact key, field 0 of the single shape. If the key is
  missing, `Debug.todo` with the key: it is a MONO_013 violation.
- Every other composite is rebuilt from erased children with the smart constructors (`Mono.mList`
  :510, `mTuple` :519, `mRecord` :540, `mCustom` :564, `mFunction` :595), never by hand, because
  of the packed hash. Template: `resolveNumberTypeRebuild` (:2819-2840).
- Memoise in a `Mono.LayoutMap MonoType` threaded through the fold.
- Keep function stage segmentation exactly. Erasing `P (String -> R)` gives `MFunction [String]
  R`, not a merged arity.

**Step 3: rewrite expressions** with `Traverse.mapExpr` (bottom-up) on each node *before* the
type rewrite, while the original types are still in place.
- Let `ctorSpecs` be the SpecIds whose node is `MonoCtor _ _ (MCustom _ h n _)` with `(h, n)`
  erasable.
- `MonoCall _ (MonoVarGlobal _ s _) [arg] _ _` with `s ∈ ctorSpecs` becomes `arg`
  (`ctorCallsRemoved`). The result type of a constructor is never a function, so the call always
  has exactly one argument.
- `MonoCall (MonoVarKernel _ _ "Debug" ("log" | "toString") _) args …`: set `printType` on the
  `CallInfo` to the original `typeOf` of the printed argument when erasing it would change it.
  `Debug.log`'s argument 2 is the printed one; for `toString` it is argument 1. Do this in the
  same bottom-up pass, before argument rewriting changes the argument's type. Read the type from
  the incoming node, since `mapExpr` is bottom-up.
- Paths: `MonoUnbox ty inner` with `ty` erasable becomes `inner`; `DtUnbox ty inner` becomes
  `inner` (`unboxStepsRemoved`). Apply this inside `MonoDestruct` destructors and inside every
  `Decider` path (`Chain` tests, `FanOut` paths).
- Assert that no `Decider` test has an `IsCtor` whose home and name belong to an erasable type.
  Typed optimization never generates one (§1.1); the assertion guards that fact.

**Step 4: constructor nodes.** Each `MonoCtor home shape t` in `ctorSpecs` becomes an identity
function at the **same SpecId**, so every reference stays valid:
```elm
MonoDefine
    (MonoClosure
        { lambdaId = AnonymousLambda home nextLambdaIndex   -- then bump nextLambdaIndex
        , srcLambda = Nothing, lssMember = Nothing, captures = []
        , params = [ ( "x", p ) ], closureKind = Nothing, captureAbi = Nothing }
        (MonoVarLocal "x" p)
        (Mono.mFunction anno [ p ] p))
    (Mono.mFunction anno [ p ] p)
```
- `p = eraseType payload`.
- `anno` is the `LambdaSetAnno` on the arrow of the constructor's function type, read from any
  `MonoVarGlobal _ s (MFunction _ anno _ _)` that references the spec. That arrow carries the
  constructor's LSS member id. If no reference exists, use `LTop 0` (poison), which is always
  safe. `mFunction`'s signature is `LambdaSetAnno -> List MonoType -> MonoType -> MonoType`
  (`IR/Mono.elm:595`).
- Check the exact closure conventions against a `MonoDefine` the engines produce for
  `id x = x`, and copy that shape exactly.
- Update `lssMemberOrigins`: an `OriginCtor home name` of an erased ctor becomes
  `OriginGlobal home name`. Its four consumers are:
  - `AbiCloning.elm:2502`;
  - `MapTemplate.elm:649`, `:1322`;
  - `Borrow/LssFacts.elm:376`.

  `OriginGlobal` is the correct description of an ordinary function. The cost is that
  `LssFacts` classifies it `PoisonUnresolved` instead of `Clean`. Accept that; first-class uses
  of a constructor are rare, and inlining removes most of them.

**Step 5: rewrite types and graph fields.**
- `Traverse.mapNodeTypes (eraseType e)` over every node (:1081).
- `ctorShapes`: rebuild with `layoutMapFoldl`.
  - Drop erased keys.
  - Re-key the others by `eraseType key`, with field types erased.
  - Two keys can collide after erasure (`Foo (Q String)` and `Foo String`). Keep one, and
    assert under validate that the shapes are equal.
- `erasure.printShapes` ← the original `ctorShapes`; `erasure.erasedKeys` ← every erased key.
- `registry.reverseMapping`: erase the types, keep the globals. `registry.mapping` is already
  empty after `Prune` (`Prune.elm:365-369`). Assert that, because collisions in `mapping` are
  then impossible and no merging is needed. Duplicate `(global, type)` pairs in `reverseMapping`
  are harmless, because MLIR function names carry the SpecId (`Functions.elm:625-632`).
- `callEdges`: recompute with `Traverse.collectSpecEdges` (:1630). `InlineSimplify` builds its
  call graph from it (:937).
- `nextLambdaIndex`: advanced by step 4.
- `ports`, `flagsSchema`, `flagsDecoder`: unchanged. KV keeps their types out of erasure.

**Config.** Switch `eraseWrappers` (§2 rule 3), env `ECO_ERASE_WRAPPERS`, JSON `eraseWrappers`,
hash token `ew=1`. It is a mono pass, so update the doc in `Compiler/Config.elm:61-72` that says
the switches gate codegen rewrites.

### 6.4 E3: invariants, checks and gates for E1a

**Invariants.**
- **MONO_031** (new). After `EraseWrappers`:
  - no reachable node, expression or path type contains an `MCustom` whose key is in
    `erasure.erasedKeys`;
  - no `MonoUnbox`/`DtUnbox` targets one;
  - no `Decider` tests one;
  - `CallInfo.printType` is exempt.

  Include the known limitation from §6.2.
- **MONO_026**: amend. Its `Unbox` segments are those left after erasure. Fix its stale names:
  there is no `MonoGraph.ctorLayouts`, and the layout comes from `ctorShapes` via
  `Types.computeCtorLayout`.
- **TOPT_006**: unchanged.

**`Steps.checkErased`** implements MONO_031 with `Traverse.anyNodeType` plus a path and decider
walk.

**Unit tests** in `compiler/tests/Compiler/MonoOpt/EraseWrappersTest.elm`:
1. candidate selection on hand-built shape lists (one shape with one field; one shape with two
   fields; two shapes);
2. a self-loop and a two-wrapper cycle are excluded;
3. a wrapper of an unboxed payload is excluded under `allowUnboxed = False`;
4. `eraseType` on nested wrappers, inside `List`, `MFunction` and records, keeps the stage
   shape;
5. a saturated ctor call is replaced, a first-class ctor becomes an identity `MonoDefine` at the
   same SpecId, and `MonoUnbox`/`DtUnbox` are removed;
6. `Debug.toString (Q x)` gets `printType = Just (Q …)`;
7. `ctorShapes` collision handling.

**Gates** (§2 rule 4), with `ECO_ERASE_WRAPPERS=1`:
- all E0 fixtures, including identical `Debug.toString` output;
- `checkErased` and `checkRepresentation` green under `ECO_MONO_VALIDATE=1` on all E2E programs;
- `checkClosureStaging` green. Exposing wrapped functions changes staging and LSS, so run the
  E0 function-wrapper fixtures under **both** mono engines (the subst engine via the TestLogic
  suite, which runs both).

Then flip the default on in its own commit and rerun all the gates.

### 6.5 E4: measure E1a

Re-run the census and the Stage 7a wall time and RSS (N=3 medians, as in
`benchmarks/ctor-census.md`) against the same-source baseline with `ECO_ERASE_WRAPPERS=0`.

Report:
- the share of the level-1 row now gone;
- the remainder by reason: KV, cycle, unboxed (waiting for E1b), or not erasable;
- wall time and minor-GC time.

The level-1 row of §1.2 is the upper bound: 103.4M allocations, 7.4M promotions.

### 6.6 E1b: unboxable payloads

**Decision D4: extend the post-mono pass, using V's components.** The alternative was to erase
inside both mono engines at type translation. That gets MONO_029 by construction, but it is two
engine changes, and KV would have to be computed before mono. It is rejected unless E1b's V0
surface (§5.3 step 3) is so large that the exclusions defeat the purpose.

1. Run `erase { allowUnboxed = True }`.
   - Every key of a candidate wrapper whose erased payload is primitive is a **tentative**
     erasure, decided per key (instantiation), not per type constructor.
   - Boxed keys of the same wrapper are erased as in E1a, since they are boxed in all views.
   - For a wrapper with both boxed and unboxed keys: E1a's per-constructor rule excluded the
     whole wrapper, but E1b decides per key.
2. Compute `RepresentationMeets.components` over interior pairs on the **pre-erasure** graph. For
   each component, compute the slot kind of every member *as it would be after the tentative
   erasure*:
   - a tentatively erased key → its payload's kind;
   - an `MVar` → boxed;
   - anything else → its own kind.

   If the kinds disagree, un-erase every tentative key in the component. Repeat until nothing
   changes. It terminates, because each round only removes erasures.
   - Example: `List (Q Float)` flowing into `List a` puts `Q Float` and `MVar` in one component
     (f64 vs boxed), so `Q Float` stays a heap `Custom` there and everywhere else.
3. Continue with steps 3–5 of E1a on the final key set. The `eraseType` lookup is per key
   (`erasedKeys`) instead of per constructor.
4. **E2b** (§6.2 step 6) lands in the same change.
5. **Codegen check.** An erased `Quantity Float` is an `MFloat` everywhere, so all existing Float
   paths apply:
   - heap slots get kind 10 through `slot_kinds`;
   - closures get unboxed captures (CGEN_003);
   - lists get unboxed heads (CGEN_027).

   `Platform.worker` with `type Model = Model Float` relies on HEAP_045's boxing of the model.
   `EraseWrapperModelTest.elm` covers it.
6. **Gates:** as for E1a, plus `checkRepresentation` (slot kinds) green on all E2E programs and
   on Stage 7a. Then measure as in E4, reporting E1b's share separately.

## 7. Level 3: several constructors, at most one field each (group N)

### 7.1 N0: measure what `Just` holds

The M0 census already splits `Just` by payload class (`adm`, `inadm`, `kv`). After V0, also
count how many admissible `Just` allocations are in components that N1 would exclude: run
`NullableMaybe` in a dry-run mode that only reports.

**Gate N0-D.** Build N1 only if admissible, non-KV, non-excluded `Just` allocations are at least
5 % of all custom allocations in Stage 7a. They are 25 % before exclusions.

### 7.2 N1a: nullable `Maybe`

**Representation** of an *admissible* instantiation `Maybe T`:
- `Nothing` stays the Empty constant;
- `Just x` is `x` itself, the boxed word of `x`. For `T = Bool` that is the 0x4/0x5 constant.

**Admissibility of `T`**, judged after erasure and written once as `NullableMaybe.admissible :
CtorShapes -> KvSet -> MonoType -> Bool`, because the census uses it too. `T` must be boxed and
its word must never be Empty.

| `T` (after erasure) | Admissible |
|---|---|
| `MInt`, `MFloat`, `MChar` | no (unboxed) |
| `MUnit`, `MList _ _`, `MString`, `MRecord` with zero fields | no (can be Empty) |
| `MCustom` of `Maybe` | no (its `Nothing` is Empty) |
| `MCustom` in `opaque` (this includes `Bytes.Bytes`, whose empty value is Empty), or kernel-visible | no (the kernel chooses the word) |
| `MVar _ _` | no (unknown) |
| `MBool` | yes |
| `MRecord` with ≥1 field, `MTuple`, `MFunction` | yes |
| any other `MCustom` with at least one constructor that has fields | yes (null-cons words are not Empty) |
| an enum `MCustom` (only nullary constructors) | yes (null-cons words are not Empty) |

`MonoType` has exactly these constructors (`IR/Mono.elm:166-178`): `MInt`, `MFloat`, `MBool`,
`MChar`, `MString`, `MUnit`, `MList`, `MTuple`, `MRecord`, `MCustom`, `MFunction`, `MVar`. Write
`admissible` as a `case` over all of them with no wildcard, so that a new constructor forces a
decision.

**Pass placement.** `Compiler/MonoOpt/NullableMaybe.elm` (new), run as `Steps.nullableMaybe`
right after `Steps.eraseWrappers`, then `checkRepresentation`.

```elm
type alias NullableInfo = { nullCtor : Name, valueCtor : Name, test : NullTest }
type NullTest = TestEmpty | TestConstantBit       -- TestConstantBit is N1b
run : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> ( Mono.MonoGraph, NullStats )
```

1. **Candidates:** every `ctorShapes` key `MCustom _ Maybe "Maybe" [t]` with `admissible t` and not
   `KernelVisible.isVisible kv`.
2. **Exclusion by V:**
   - Take the components over **all** pairs (root and interior). A candidate survives only if
     every member of its component is the candidate key itself.
   - Any other `Maybe` instantiation (for example `Maybe (MVar)`) or an `MVar` in the component
     excludes it.
   - Example: an erased spec of `Maybe.withDefault` receiving a `Maybe Rec`. Today's `get_tag`
     returns 0 for a bare record, which equals `Just`'s tag, so the miscompile would be silent.
3. **Record the result** in a new `MonoGraph` field `nullable : LayoutMap NullableInfo` (§2
   rule 6), keyed by the `Maybe T` type.
4. **Rewrite decision trees** over a nullable value. For each `Decider` path whose type
   (`Mono.dtPathType`, `IR/Mono.elm:3517`) is a nullable key:
   - `Chain` tests are ANDed. Split a chain so that a test on a nullable path stands alone:
     `Chain (t1 :: (p, IsCtor …"Just"…) :: rest) s f` becomes
     `Chain [t1] (Chain [(p, IsCtor …"Nothing"…)] f (Chain rest s f)) f`.
     When a `Just` test is the only one, it becomes the `Nothing` test with success and failure
     swapped.
     - `Leaf (Inline e)` branches can be duplicated by this. Accept that for now; most deciders
       use `Jump`. Count the duplicated inline leaves in `NullStats`.
   - `FanOut p [(FCtor Nothing, dN), (FCtor Just, dJ)] fallback`, in either order, possibly
     with one edge missing (it is then `fallback`), becomes `Chain [(p, IsCtor …"Nothing"…)] dN
     dJ`.
   - Build the `IsCtor` test for `Nothing` with the same arguments the engines use (home
     `Maybe`, index 0, numAlts 2, the `Can.CtorOpts` already on the original test).
   - Codegen then needs **no new test code**. `Patterns.generateMonoTest`'s `IsCtor Nothing`
     already compares `eco.get_tag` with `CtorTag.constantTag` (0xFFFD) (`Patterns.elm:165-184`,
     `ctorTagInt` :975-981). `get_tag` returns 0xFFFD only for Empty. For every admissible
     payload it returns something else: 0/1 for Bool, a decl index ≤1023 for null-cons, a ctor
     tag for a Custom (the reserved 0xFFFF/0xFFFB are not 0xFFFD), and 0 for other heap objects.
5. **Codegen changes** (`GenerateMlir`; give `Ctx` the `nullable` map next to `ctorShapes`):
   1. **Construction.** A saturated `Just` call whose result type is nullable becomes its
      argument, boxed to `!eco.value` (Bool: `i1` → constant word through the existing Bool
      boxing). Do this check first in `Expr.tryCtorInline` (3534), in `promotableCtorCall`
      (6400; return `Nothing`, never `make.custom`) and in the generic call path. Also in
      `Functions.generateCtor` (1421): the `Just` ctor function of a nullable instantiation
      returns its parameter.
   2. **Projection.** In `Patterns.generateMonoIndexOnHeap` (478), a `MonoIndex 0
      (CustomContainer "Just") ty inner` whose container type is nullable yields the container
      value itself. It is then coerced to `ty`'s MLIR type; only `MBool` needs a conversion, the
      existing `!eco.value` → `i1` unbox. `dtPathToMonoPath` (111-121) feeds decider paths
      through the same function.
   3. **Guard.** `Patterns.generateMonoTest` and the fan-out in `Expr.elm:5941` /
      `TailRec.elm:1224,1381` crash with `"N1: unrewritten Just test"` if they meet an
      `IsCtor`/`FCtor` on `Just` for a nullable type. Step 4 must have removed all of them.
   4. **Unchanged:**
      - `Nothing` emission (`Functions.elm:1449-1463`, `Expr.elm:813-817`,
        `Backend.elm:1309-1347`);
      - `psplit` (one-field types never qualify);
      - BytesFusion. `Bytes.decode`'s result type is kernel-visible, so its `Maybe` is never
        nullable; add an assertion at `Emit.elm:2031,2041` that the result type is not in
        `nullable`. The bf runtime's `elm_maybe_just` (`ElmBytesRuntime.cpp:294`) stays as it is.
6. **Type table.**
   - `EcoTypeKind::Nullable = 8`, with data `{ payload_type_id : u32, null_name : u32,
     value_name : u32 }` (12 bytes, within the union; `static_assert` at `TypeInfo.hpp:168`).
   - Emit it from `TypeTable.elm` for a nullable key, and add `case 8` to `EcoToLLVMGlobals.cpp`.
   - The printer arm: an Empty word prints `Nothing`; anything else prints `Just ` followed by
     the payload through `print_ctor_arg`.
7. **Equality and hashing.**
   - `Utils.equal` on two nullable values compares payloads or Empty, which is correct.
     `Nothing == Just x` is Empty against a non-Empty word, so false.
   - `compare` does not apply to `Maybe`.
   - `FNV.hash` is deny-all, so nothing it hashes is nullable.

**Switch:** `nullableMaybe`, env `ECO_NULLABLE_MAYBE`, hash token `nm=1`.

**Invariants.**
- **REP_CONSTANT_003** (new): "A `Maybe T` in `MonoGraph.nullable` is represented by Empty for
  `Nothing` and by the boxed word of the payload for `Just x`. Its `case` tests compare
  `get_tag` with the constant tag; no `Custom` with ctor `Just` exists for that type."
- **MONO_033** (new): the admissibility table above, the KV exclusion, and "no other view meets
  a nullable key" (checked by `checkRepresentation`).

**Fixtures** (E2E, `test/elm/src/NullableMaybe*Test.elm`, landing first):
- `Maybe` of each admissible and inadmissible payload: record, tuple, function, `Bool` (both
  values), enum, a multi-constructor custom with fields, `Int`, `String`, `List`, `()`.
- `Maybe Rec` passed to a polymorphic helper whose spec keeps `MVar` (excluded by V).
- Nested `Maybe (Maybe Rec)`: the outer one is inadmissible, the inner one nullable.
- `Maybe` through a port, and `Maybe` in a `Dict` value.
- `Dict.get` results.
- `Just a == Just b`, `Nothing == Just x`.
- `Debug.toString` of each.
- A `case` with three arms over `(Maybe Rec, Maybe Bool)` to exercise chain splitting.

**Unit tests:** `compiler/tests/Compiler/MonoOpt/NullableMaybeTest.elm` covers admissibility
(every row), chain and fan-out rewriting, and V exclusion.

**Gates:** §2 rule 4 with `ECO_NULLABLE_MAYBE=1 ECO_ERASE_WRAPPERS=1`. Then measure the census as
in E4.

### 7.3 N1b: Maybe-shaped user types

A user type with one nullary constructor `N` and one constructor `S` with one field (for example
`type Opt = None | Some Rec`). `N` is a null-cons word, which is neither unique nor distinguishable
from a payload by `get_tag`. If `None` is declared first, its index 0 equals a record's tag 0.

**Decision D2 (kept):** admit only payloads with **no embedded-constant values at all**, after
erasure. That means records with ≥1 field, tuples, functions, and customs with no nullary
constructors, recursively through wrappers that erase to them. It excludes Bool, enums, lists,
strings and the rest. Then a word is a constant exactly when it is `N`.

1. **New op** `eco.is_constant : !eco.value -> i1` (`Pure`) in `codegen/Ops.td` near `get_tag`
   (:555). It lowers to `(word & 4) != 0` (the `ptr_ind` bit, as FORBID_HEAP_001 requires). Add
   the lowering next to `GetTagOpLowering` (`EcoToLLVMControlFlow.cpp:140-169`) and a folder
   (an `eco.constant` operand folds to true). Record it as invariant **CGEN_087**.
2. `NullableMaybe` also accepts these types, with `NullableInfo.test = TestConstantBit` and the
   ctor names from the shapes.
3. **Decider rewrite:** as in N1a, with `N` in place of `Nothing`.
4. **Codegen:** `generateMonoTest` on `IsCtor N` of a `TestConstantBit` type emits
   `eco.is_constant` instead of the tag compare. Construction and projection of `S` are as for
   `Just`. `N` stays its null-cons word (unchanged emission).
5. **Type table:** `Nullable` already carries both ctor names.
6. **Fixtures:**
   - `None` declared first and second;
   - a payload that is a record, and one that is a custom with a nullary ctor (must be excluded);
   - nesting inside `Maybe`.

### 7.4 N2: the old option (b), deferred

Represent a multi-constructor one-field union as its bare payload when every constructor's payload
has a distinct runtime tag (constraints in `plans/sum-type-wrapper-unboxing.md` §2(b)). The
candidates in §1.2 are `Leaf` 30.1M, `Ok` 20.9M, `SubTree` 20.5M, `Structure` 15.1M and `U8`
13.9M. `Result`'s `Err`/`Ok` payloads often share a tag. Re-measure with the census after N1, and
decide then whether to plan N2 in detail.

## 8. Level 4, and the local half of level 3 (group K)

A multi-field multi-constructor value that escapes stays on the heap; nothing here changes that.
`RBNode_elm_builtin` (394.5M allocations) dominates level 4. The lever for escaping values is
in-place reuse of a uniquely referenced cell (Perceus or Lean-style), a separate and larger
project that is not planned here.

### 8.1 K0: census

Add `Compiler/MonoOpt/KnownCtorCensus.elm`:
```elm
census : Mono.MonoGraph -> { sites : Int, trivialArgs : Int, rootOnly : Int }
```
After inlining, it counts every `MonoCase _ x …` where `x` is bound in an enclosing let chain to
a saturated constructor call or a `MonoEnum` reference:
- `trivialArgs`: every argument is a `MonoVarLocal`, `MonoVarGlobal` or literal;
- `rootOnly`: every decider test reached from the root is on `DtRoot`.

Print it with the inline report (`Generate.elm:1037-1055`, `ECO_INLINE_REPORT`).

**Gate K0-D:** build K1 only if `sites ≥ 100` on Stage 7a. Record the numbers.

### 8.2 K1: case of known constructor

**Where.** `Compiler/MonoOpt/InlineSimplify.elm`, inside the per-node fixpoint (`iterate`, :2884),
as part of the let-chain rewrite (`rewriteLetChain` :3852, next to `forwardInChain` :3961). There
the chain's earlier bindings are visible. Nothing like it exists today; the only branch folding
is `if True/False` (:3083-3090).

**Context.** `RewriteCtx` (~:1500) has no SpecId → node table. Add
`knownCtors : Dict Int KnownCtor`, built in `initRewriteCtx` (:2555) from the nodes:

```elm
type KnownCtor = KCtor Name Int Int   -- ctor name, tag, field count  (from MonoCtor)
               | KEnum Name Int       -- from MonoEnum
```

**Rule.** Within a let chain, take a binding `x = MonoCall _ (MonoVarGlobal _ s _) args _ _`
with `s` a `KCtor` and `List.length args` = its field count, or `x = MonoVarGlobal _ s _` with
`s` a `KEnum`. A later `MonoCase lbl x decider jumps t` in the chain (or as its body) is rewritten
when all of the following hold:
1. every `args[k]` is trivial (`MonoVarLocal`, `MonoVarGlobal`, literal). This avoids
   re-evaluating work;
2. no binding between the definition and the case rebinds `x` or any name occurring in `args`.
   Check with a free-name set; `InlineSimplify` already has `countUsages` (:5895) and the
   substitution helpers (:3570, :3728);
3. walking `decider` from the root, every test met is either on `DtRoot x _`, and so decidable
   from the constructor, or on a path the walk never reaches. Evaluate `IsCtor _ name _ _ _` as
   `name == ctorName` and `FanOut` by picking the matching `FCtor` edge, else the fallback;
4. the walk ends in a `Leaf`.

The result:
- **Branch.** `Leaf (Inline e)` gives `e`; `Leaf (Jump i)` gives the `i`-th entry of `jumps`.
- **Destructors.** In the chosen branch, a `MonoDestruct (MonoDestructor n path ty) body` whose
  path is `MonoIndex k (CustomContainer _) _ (MonoRoot x _)` becomes `MonoLet (MonoDef n
  args[k]) body`. A deeper path whose innermost step is that index is re-rooted on `args[k]`,
  which is trivial, so a `MonoVarLocal` can root it.
  - If `args[k]` is a literal or a global, first bind it to a fresh name with the inliner's
    fresh-name helper.
- Leave `x`'s binding in place. `simplifyLets` (:5429) deletes it if it is now unused.
- Count `knownCtorFolds` in `Metrics` (:902) and print it in the inline report.

**Tests.** In `compiler/tests/Compiler/MonoOpt/InlineSimplifyTest.elm`:
- fold on a 2-ctor type with a field read;
- no fold when an argument is a call;
- no fold when a test is on a field path (nested pattern);
- `Jump` and `Inline` leaves;
- enum scrutinee.

Add an E2E fixture `test/elm/src/KnownCtorCaseTest.elm` covering probe case 6
(`case WorkA x of …` after inlining).

**Switch** `knownCtorCase`, env `ECO_KNOWN_CTOR_CASE`, hash `kcc=1`. **Gates** are §2 rule 4.

### 8.3 K2: multi-constructor values in SSA (optional)

After K1, what remains is a value built in different branches and matched later (`let m = if c
then A x else B y in case m of …`). Supporting it needs an SSA tagged-union aggregate. Decide
after K0 is re-run with K1 on.

## 9. Level 2: one constructor, several fields (group S)

### 9.1 S1: sret for one-constructor customs with 2–3 fields

**Today.** `sretInfoOf` (`Backend.elm:409-420`) handles `MTuple` only. The `$sret` worker returns
the fields as separate results (CGEN_064, CGEN_067). Callers that only take the value apart bind
the fields directly (`Expr.trySretLetBinding` 6657).

**Candidate.** `UnifyOk` (20.5M allocations, never promoted).

**Changes, in order:**
1. **`Context.elm`:**
   - `SretInfo` (161-164) becomes `{ layout : SretLayout, slotTypes : … }` with
     `type SretLayout = SretTuple Types.TupleLayout | SretCtor Types.CtorLayout Mono.CtorShape`.
   - `sretTailLayout` (303) becomes `Maybe SretLayout`.
   - Fix every reader of `.layout.elements`/`.unboxedBitmap` (compile errors will list them).
2. **`Backend.elm`:**
   - `sretInfoOf` takes `ctorShapes`. It adds the `MCustom` case: exactly one shape with 2 or 3
     fields, the type not kernel-visible, and its layout from `Types.computeCtorLayout`.
   - `buildSretPromoted` (448) and its call site (:122) gain `ctorShapes` and `ctorBySpec` (from
     `buildCtorBySpec`).
   - `sretLeafMatches` (791), `sretTailOk` (802), `sretTailFuncOk` (736) and `sretFreshTailOk`
     (657) accept a saturated call of a `ctorBySpec` spec whose shape equals the info's.
3. **`Functions.elm`:**
   - `generateSretWorkerAndShim` (1006-1110): use `aggCustomType` and
     `Ops.ecoProjectCustomAgg` (`Ops.elm:533`) for `SretCtor`.
   - The shim rebuilds with `Ops.ecoConstructCustom` (tag, ctor name, `slot_kinds`, census id).
   - `generateTailFunc` (1381-1384) gets the same treatment.
4. **`TailRec.compileBaseReturnStep`** (1003-1040): the same.
5. **`Expr.elm`:**
   - the spine filter (425-447) and the `MonoCall` arm (487-493): a constructor call on the
     spine is built with `generateCustomCreateValue` (7206, `make.custom`);
   - `spineResultMlirType` (5988), `emitSpineYield` (6450), `finishSpineCase` (6521),
     `trySretFreshLeaf` (6582) and the `generateIf` spine (4234) all get `SretCtor` arms;
   - `trySretLetBinding`/`emitSretLetBinding`: `CustomContainer` and `SplitCtor`. The latter is
     already supported by `Patterns.materializeSplitParam`/`splitSlotRead`.
6. **psplit interplay:** `Backend.elm:1075`, `psplitSiteHit` (1221) and `Expr.psplitArg` (3342)
   handle `SplitTuple` only. Extend them to `SplitCtor` where an sret-bound custom flows into a
   split parameter.

No C++ change is needed. Multi-result lowering is generic, and `make.custom`/`project.custom` on
`!eco.custom` already lower.

**Switch** `sretCtors` (hash `sretc=1`).

**Fixtures:**
- a function returning `UnifyOk`-style `Ok2 a b`, consumed by `case` and by a let destructure;
- a tail-recursive one;
- a 3-field Float custom (unboxed slots);
- an escaping result (the shim rebuilds the value).

**Gate:** the census shows the targeted classes' allocations gone, plus §2 rule 4. Invariants:
amend CGEN_064 and REP_AGG_001's PRODUCERS text to include one-constructor customs.

### 9.2 S2: compact heap layout (measure first)

A `Custom` has an extra word (`ctor:16 | unboxed:48`) that `Tuple2`/`Tuple3` do not
(`Heap.hpp:555-569` vs `620-625`). Storing a one-constructor 2- or 3-field custom in the tuple
layout saves 8 bytes per object: 32 → 24 bytes, 40 → 32.

**Gate S2-D.** Build S2 only if the projected saving is at least 2 % of the bytes promoted in
Stage 7a. The projection is the census's promoted count for eligible classes (one constructor,
2–3 fields, not kernel-visible) times 8 bytes. Total promoted bytes come from `GCStats`, using
the `build` preset, which has GC stats. `FieldType` alone projects 19.3M × 8 B ≈ 147 MiB of copy
volume over the run.

**If built:**
- **Decision.** Per type constructor (so all views agree, §5): `compact : CtorShapes -> KvSet ->
  MonoType -> Bool`, stored as a `MonoGraph` field `compactCtors : Set (String, String)` and
  computed in `NullableMaybe`'s step or its own `Steps` function.
- **Codegen:**
  - construction emits `eco.construct.tuple2/3` (`Ops.td:756/786`, `unboxed_bitmap` from the
    field kinds) instead of `construct.custom`;
  - projection emits `eco.project.tuple2/3` (`:816/840`);
  - case on a one-constructor type has no tag test (`Unbox`-free, but `IsCtor` with `numAlts =
    1` must not read `get_tag`; check `Patterns.generateMonoTest` and skip the test);
  - `aggPromote` uses `make.tuple2/3`, and psplit uses `SplitTuple` for these types.
- **Type table:** a flag bit in the Custom descriptor (`compact`). The printer reads the fields
  from a `Tuple2`/`Tuple3` object.
- **Invariants:** amend HEAP_015 (a compact one-constructor custom is a `Tuple2`/`Tuple3`) and
  XPHASE_001.
- **Equality:** `Utils.eqHelp` compares tuples field-wise, which is correct. FNV is deny-all.

The `Array_elm_builtin` record (4 fields, 71.2M) is out of reach of S1 and S2. It is also on
`byName`. Finding where those allocations come from is a separate investigation.

## 10. Order, dependencies and decisions

| Step | Unit | Depends on | Gate to pass before the next step |
|---|---|---|---|
| 1 | M0 census | — | M0-G: §1.2 reproduced ±3 %, output byte-identical |
| 2 | KV table + analysis, KV0 audit | M0 | KV0-D: exclusion < 25 % of the level-1 and admissible-`Just` pools, or every root justified |
| 3 | V collector + validator, V0 baseline | — | no slot-kind violations on E2E + Stage 7a (fix any found first) |
| 4 | E0 fixtures, E2 printing | — | fixtures green on today's compiler |
| 5 | E1a + E3 | 2, 4 | §6.4 gates; then default on |
| 6 | E4 measure | 5 | numbers recorded |
| 7 | E1b + E2b | 3, 5 | §6.6 gates |
| 8 | N0 | 2, 3 | N0-D: ≥ 5 % of custom allocations |
| 9 | N1a, then N1b | 8 | §7.2 gates |
| 10 | K0, then K1 | — | K0-D: ≥ 100 sites |
| 11 | S1 | M0 | census shows the targets gone |
| 12 | S2-D, then S2 | M0, 2 | S2-D: ≥ 2 % of promoted bytes |
| 13 | N2, K2 | 9, 10 | decide after re-measuring |

K and S are independent of E and N, and can proceed in parallel with them.

**Decisions.**
- **D1** (2026-11-19): M0 lands the census in the repo, so every gate is reproducible.
- **D2** (2026-11-19): Maybe-shaped user types in N1 are restricted to payloads with no embedded
  constants. Re-encoding `N` as Empty is not part of N1.
- **D3** (2026-11-19): `plans/sum-type-wrapper-unboxing.md` is superseded by this plan.
- **D4** (2026-11-19): E1b is a post-mono extension of `EraseWrappers` using V's components, not
  an erasure inside both mono engines (§6.6).
- **D5** (2026-11-19): `Debug` printing of erased wrappers works through
  `CallInfo.printType` plus `MonoGraph.erasure.printShapes` and a Wrapper type kind (§6.2).
- **D6** (2026-11-19): an erased constructor's node becomes an identity `MonoDefine` at the same
  SpecId, and its LSS origin becomes `OriginGlobal` (§6.3 step 4).
- **D7** (2026-11-19): census ids are per constructor class, not per site, and live in the
  header's `refcount` bits, so that promotions can be attributed (§3).
- **D8** (2026-11-19): N1 removes `Just` tests at the `Decider` level (mono), so codegen reuses
  the existing `Nothing` tag test (§7.2 step 4).
- **D9** (2026-11-19): K1 folds only when the constructor's arguments are trivial and every test
  reached is on the root.
- **D10** (2026-11-19): `FNV.hash` stays deny-all. Its hash values must not change with
  representation. Revisit only if KV0-D says it matters.
- **D11** (2026-11-19): KV is a closure over types computed once, not a fixed point with erasure
  (§4.2).

## 11. Corrections to the previous text of this plan

Recorded so that nobody re-derives them:

- **Wrong path or line references:**
  - `Solver/Monomorphize.elm:4129` is annotation-id collection, not specialization.
  - `MonoTraverse` is `Compiler.IR.Mono.Traverse`.
  - The pipeline steps live in `Compiler.Pipeline.Steps`. `checkLayout` is called at
    `Generate.elm:963`.
- **The `mapping` key collision cannot happen.** `Prune` empties `registry.mapping` before E1
  runs, so no specialization merging is needed (§6.3 step 5).
- **There is no constructor expression.** A constructor reference is `MonoVarGlobal` to a
  `MonoCtor` node. `MonoCase` carries no destructors; field bindings are `MonoDestruct`s in the
  branches.
- **`ValidateLayout`'s "harmless"** concerns captures and call arguments. It skips constructor
  fields for a different reason.
- **`Utils.equal` is not word-based for heap values.** It walks structure (`Utils.cpp:656-678`),
  with special cases for RBNode and SeqDict. It is representation-agnostic only while both sides
  share a representation.
- **KV needed fixes:**
  - a rule for `MonoManagerLeaf` (effect managers read `MyCmd`/`MySub` directly);
  - `Array_elm_builtin`, `Dict` and `SeqDict` on `byName`;
  - `JsArray` and `JsArray2` as opaque types with a placeholder field;
  - `Debug.log`/`toString` and `FNV.hash` as non-transparent kernels.
- **Missed C++ construction sites:**
  - kernels also build customs through raw `eco_alloc_with_roots(Tag_Custom, …)` (Bytes, Json);
  - BytesFusion also builds `Just` in the bf runtime (`ElmBytesRuntime.cpp:294`);
  - `Expr.elm:3691` projects a Bytes `Decoder`'s field.
- **`get_tag` returns 0 for `False`** as well as for any non-Custom heap object, so N1 must
  replace `Just` tests, not add to them.
- **The census instrumentation is lost.** M0 rebuilds it.

## 12. Implementation record (2026-11-19)

Implemented in one session, in the plan's order. Every behaviour is behind a
`repr` switch in `Compiler.Config.ReprConfig` (env overrides in
`Builder.Eco.Config`, rows in `docs/options.md`). After the gates below, every
representation pass is on by default; the census and the validation are off.

| Unit | Where | Switch |
|---|---|---|
| M0 census | `Compiler.GenerateMlir.CtorCensus`; `_census_id` on `eco.construct.custom`/`eco.make.custom`; `eco_ctor_census_count`/`eco_ctor_census_mark`; id in `Header.refcount`; promotions counted in the minor-GC copy paths (`ctorCensusPromoted`); `scripts/ctor-census.py`, `scripts/ctor-census-selfcompile.sh` | `ECO_CTOR_CENSUS=<path>`, runtime `ECO_CTOR_CENSUS_OUT=<path>` |
| KV | `Compiler.IR.Kernel.Visibility` (table), `Compiler.MonoOpt.KernelVisible` (closure, per type constructor and per instantiation), `scripts/check-kernel-opaque.py` | — |
| V | `Compiler.Monomorphize.RepresentationMeets` (`collect`, `validate`) | `ECO_REPR_VALIDATE` |
| E1a, E1b | `Compiler.MonoOpt.EraseWrappers` | `ECO_ERASE_WRAPPERS`, `ECO_ERASE_UNBOXED` |
| E2, E2b | `CallInfo.printType`, `MonoGraph.repr` (`printShapes`, `erasedKeys`), type kind 7 `Wrapper`, printer `print_wrapper` | — |
| N1a, N1b | `Compiler.MonoOpt.NullableMaybe`, type kind 8 `Nullable`, `eco.is_constant` (CGEN_087) | `ECO_NULLABLE_MAYBE`, `ECO_NULLABLE_USER` |
| K0, K1 | `Compiler.MonoOpt.KnownCtorCase`, `Steps.knownCtorCase` (a pass after `inline` rather than inside it; its census line prints under `ECO_INLINE_REPORT`) | `ECO_KNOWN_CTOR_CASE` |
| S1 | `SretInfo.ctor`; `Backend.sretInfoOf`/`sretCtorLeafOk`; `Expr.trySretCtorLeaf`; `Functions.sretShimConstruct` (CGEN_088) | `ECO_SRET_CTORS` |

Invariants added: MONO_031, MONO_032, MONO_033, REP_CONSTANT_003, CGEN_087,
CGEN_088; MONO_026 and MONO_029 amended.

**Deviations from the text above, found while implementing:**

- `ECO_MONO_VALIDATE=1` fails on every program before this plan's passes run
  (the pre-mono identity validator reports "ArrowId … occurs twice"), so the
  representation checks have their own switch, `ECO_REPR_VALIDATE`.
- The representation validator reports only violations the passes introduce:
  some meets of differing slot kinds exist before any pass (MONO_021: a spec
  that keeps a type variable is reached by a concrete view whose elements it
  never reads, e.g. `describeList [1]` sharing `describeList []`'s spec).
- A kernel call is not a meet. A kernel's parameters are type variables by
  its boxed ABI, and what it does with a value is KV's question.
- Every key of the new passes is a layout key (`Mono.toComparableLayoutType`,
  new), which ignores lambda sets and type-variable ids; erasing an
  instantiation substitutes its own type arguments into the listed field type.
- A wrapper any of whose instantiations meets a type variable anywhere is not
  erased. An erased view reads a value untyped, and `show = Debug.toString` (a
  function value) would print the bare field. This keeps `Debug.toString`
  output identical, which the plan had listed as a known limitation; it also
  keeps elm/core's `Set` printing as `Set.fromList` through the untyped printer.
- A destructuring path can be a bare root after erasure. The code generator
  now boxes a primitive or `Bool` root read as `!eco.value`.
- KV enters kernel-owned types through their non-variable fields. An effect
  manager's command type is kernel-owned and its fields are what the kernel
  reads; the scan alone missed `Maybe ( Int, Int, Int )` built by the C++
  child-process manager. A manager's command type is not in `ctorShapes`, so
  `Analysis.ctorShapesOf` computes it from the declaration.
- The census promotion count uses a relaxed atomic add in the copy paths (the
  plan proposed worker-local vectors). E2E test children end through their own
  exit path, so the census is read from native binaries (`eco_entry`'s exit).
- Under the substitution engine, MLIR generation crashes on two `SourceIR`
  catalogue programs with or without these passes ("cannot coerce i64 to
  f64": Mono refine coverage, Number through a compound field). This is
  pre-existing; `TestLogic.MonoOpt.ReprPassesTest` runs the subst engine to
  global optimization only.

**Gates:**

- E2E with every switch on (`ECO_REPR_VALIDATE=1`): 3110/3111, the one failure
  being the KV hole above, fixed and re-run green.
- elm-tests with the passes on by default: 21,871 passed, 0 failed. Among them
  `TestLogic.MonoOpt.ReprPassesTest` compiles the whole `SourceIR` catalogue
  with every pass on and validated, under both engines. Six older tests (in three files) that
  examine exactly what the passes remove (unbox steps, a wrapper's shape, a
  locally cased constructor) run with `TestPipeline.withoutReprPasses`.
- Gate A (`cmake --build build --target full`, passes on by default):
  3,113/3,113. Bootstrap (`--target bootstrap`) with the passes on, the
  compiler compiling itself with them: green, Stage 8c fixed point included.
  After the KV refinements below, all three were re-run green (elm-tests
  21,871/0).

**KV refinements made from the census (KV0):** the eco/kernel `MVar` kernels
(which hold the compiler's whole state), `System.Crash.crash` (`String -> a`,
which marked the type of every expression that can crash) and
`Bytes.decodeFailure` (which throws) were deny-all and are now `Transparent`.

**Census of the self-compile** (`scripts/ctor-census-selfcompile.sh`; the
workload, the compiler compiling itself with the passes off, is the same for
both binaries; `build` preset):

| | passes off (binary) | passes on (binary) | change |
|---|---|---|---|
| level 1 | 107.5M | 25.5M | −76 % |
| level 2 | 133.3M | 133.3M | 0 |
| level 3 | 407.2M | 200.3M | −51 % (admissible `Just` 223.1M → 16.2M) |
| level 4 | 635.4M | 635.4M | 0 |
| total custom allocations | 1,283.3M | 994.3M | −22.5 % |
| promotions | 150.1M | 147.7M | −1.6 % |
| workload wall (census binaries) | 71.9 s | 71.3 s | flat |

- **M0-G:** the passes-off census reproduces §1.2 for level 1 (107.5M against
  103.4M) and level 3 (407.2M against 425.6M); levels 2 and 4 and the total
  (1,283M against 1,207M) are higher by up to 15 %, the compiler having grown
  since the §1.2 run (it now includes this plan's passes). Nothing is
  unattributed.
- **KV0-D:** kernel-visible level-1 allocations are 21 % of the level-1 pool
  (22.5M, almost all `TypeVars.Point`, an `Int` wrapper), under the 25 % bound.
- **N0-D:** admissible, non-kernel-visible `Just` allocations were 17 % of all
  custom allocations (bound 5 %): N1 is kept, default on.
- **K0-D:** `KnownCtorCase` finds 0 sites in the self-compile after inlining
  (bound 100): K1 stays built but default off (`ECO_KNOWN_CTOR_CASE`).
- **S1:** on, but `UnifyOk` (21.5M) still allocates: its producers did not
  qualify for a `$sret` worker (why was not investigated). The E2E fixture
  `SretCtorTest` shows the mechanism working.
- **S2-D:** eligible one-constructor 2–3-field classes are promoted 0.27M
  times, 2.0 MiB of copy volume: far under 2 % of promoted bytes. S2 is not
  built.
- **E4 / wall:** allocation volume drops by 22.5 %, but with the generational
  GC copying survivors only, the self-compile's wall time is flat. The passes
  themselves cost compile time: the self-compile with them on takes 77.5 s
  against 68.6 s with them off (two runs each), the representation-meets
  collection and the kernel-visibility closure each running twice. That is
  the first thing to optimize before relying on the passes for speed.

**Units decided by their gates, and the deferred decisions (2026-11-19, after
re-measuring with the census):**

- **S2** is not built: S2-D failed (2.0 MiB projected).
- **K1** was built before K0 could be measured on the self-compile (the
  measurement needs the bootstrap's native compiler, which needed K1 in the
  sources). K0-D then failed (0 sites), so K1 stays in the tree, tested, and
  default off. This departs from the plan's order (measure, then build).
  Since 2026-11-21 it is default on under a different gate (section 14).
- **N2** is decided against. After N1, the level-3 classes still allocating are
  `Array.Node`'s `Leaf` and `SubTree` (55M together; both hold a JsArray, so
  their payloads share one runtime tag, which N2 requires to be distinct; and
  `Array` is on the by-name list), `Result`'s `Ok` (21.9M, kernel-visible), the
  kernel-visible or inadmissible `Just`s, and classes of under 1M each. N2
  could reach under 2M allocations (0.2 %).
- **K2** is decided against, by the step §8.3 prescribes ("decide after K0 is
  re-run with K1 on"): K0 re-run on the self-compile (`eco-compiler-boot make
  --optimize --no-cache` of `Terminal/Main.elm`, `ECO_INLINE_REPORT=1`) reports
  `sites=0 trivialArgs=0 rootOnly=0 folded=0` with `ECO_KNOWN_CTOR_CASE=1`, and
  the same with it off. There are no local constructor-then-case sites left for
  an SSA tagged-union aggregate to serve.
- **N2** follows §7.4's step ("re-measure with the census after N1, and decide
  then whether to plan N2 in detail"): the re-measurement is the passes-on
  census above, and the decision is not to plan it.

**Unit tests** (all in `compiler/tests`, green):
`Compiler/GenerateMlir/CtorCensusTest` (M0), `Compiler/MonoOpt/KernelVisibleTest`
(KV: unlisted kernel, transparent kernel, kernel as a value, per-instantiation
`Maybe`, never-returning kernel), `Compiler/Monomorphize/RepresentationMeetsTest`
(V), `Compiler/MonoOpt/EraseWrappersTest` (E1a, E1b), `Compiler/MonoOpt/NullableMaybeTest`
(admissibility) and `NullableMaybeRunTest` (the decision-tree rewrite, N1b's
constant-bit types, the exclusion by a meet), `Compiler/MonoOpt/KnownCtorCaseTest`
(K0 census, K1 fold, the sites left alone), and `TestLogic/MonoOpt/ReprPassesTest`
(the whole `SourceIR` catalogue with every pass on, both engines). The
manager-leaf KV rule is tested end to end by `ProcessSpawnExternalTest`. Codegen:
`test/codegen/ctor_census_construct_llvm.mlir`, `test/codegen/is_constant.mlir`.
E2E: `test/elm/src/EraseWrapper*Test`, `Nullable*Test`, `KnownCtorCaseTest`,
`SretCtorTest`.

**Tests added in the last pass over the plan's test lists** (the items found
missing on review):

- E0/N1 E2E fixtures: `EraseWrapperSetDictTest` (`Set` operations, equality and
  printing; a `Dict` of wrappers; `Set` and `Tag` are erased),
  `EraseWrapperModelTest` (a `Platform.worker` with `type Model = Model Float`;
  the model is left boxed because `Platform.worker` views it through a type
  variable), `NullableMaybePortTest` (`Maybe { n : Int }` through a port; left
  on the heap as kernel-visible). The flags fixture is `FlagsRecordTest`, which
  already existed.
- E2 codegen: `test/codegen/type_table_wrapper_nullable_llvm.mlir` (kind-7 and
  kind-8 entries lowered byte by byte) and
  `test/codegen/type_table_wrapper_nullable_print.mlir` (the printer on a
  wrapper, a boxed and an unboxed list head, and a nullable).
- MONO_031: a direct test of `EraseWrappers.check` in `EraseWrappersTest`
  (empty after `erase`; one violation reported for a node put back with an
  erased type).
- `compiler/tests/SourceIR/WrapperCases.elm`: wrapper, Maybe and known-ctor
  programs in the standard suites, so every pipeline check runs on them.

Compiler changes made with them, found by the worker fixture: `Platform.batch`
and `Platform.map` are now `Inspects platformTypes` in the kernel table
(PlatformExports.cpp only builds bag nodes); a listed kernel used as a value is
treated by its table entry, as a call of it is; the erase-wrappers report
counts the wrappers excluded by a type-variable meet apart from the
kernel-visible ones.

**TLA+ canary.** The census promotion hooks (three regions in `NurseryParallel.cpp`
and `NurseryTenure.cpp`, the `GCStats.hpp` census, and the `F.atexit` grep) fired the
canary from the day they were added; it is warn-only, and the earlier gate runs
did not report it. Audited 2026-11-19 in M2, M3, M5, M6, M7 and `test/genmc/AUDIT.md`:
a relaxed RMW on a statistics-only array no model holds, and a lock-free exit
dump. No model change was needed, and the manifest was repinned.

**Gates after these last changes (2026-11-19):** elm-tests 22,003 passed / 0
failed; `full` 3,118 / 3,118 (the five new E2E and codegen tests among them);
`bootstrap` rc 0 through Stage 8c (native fixed point) and 9b; the canary passes.

**Follow-ups:** the passes' compile-time cost (+8.4 s on the self-compile) is
now §13 of this plan; not part of it: `TypeVars.Point` (19M) still kernel-visible; `UnifyOk`
(21.5M) not getting a `$sret` worker.

## 13. The passes' compile-time cost (units R0–R4)

### 13.1 The problem, measured

`benchmarks/fe-opt-loop.md` row `ctorrep` (2026-11-19, one run each, same binary `eco-optCTOR`, the
passes switched by `ECO_ERASE_WRAPPERS`, `ECO_ERASE_UNBOXED`, `ECO_NULLABLE_MAYBE`,
`ECO_NULLABLE_USER`, `ECO_SRET_CTORS`):

| | passes on | passes off | Δ |
|---|---|---|---|
| wall | 77.78 s | 69.37 s | **+8.41 s** |
| monomorphization phase | 35.4 s | 27.0 s | **+8.4 s** |
| parse/check/build, inline, global opt, MLIR codegen | 27.6 / 0.8 / 1.1 / 9.0 s | 27.3 / 0.9 / 1.0 / 9.4 s | flat |
| minor GCs / promoted | 1565 / 7230 MiB | 1375 / 7075 MiB | +190 / +155 MiB |

All of the cost is `Steps.representation` (`compiler/src/Compiler/Pipeline/Steps.elm`), which runs
inside the monomorphization phase (`Builder/Generate.elm` `monoPipelineFrom`, after
`Steps.checkLayout`). With every switch off it returns before computing anything, so the off row
pays nothing for it. (The off row is still 5 s over p08: the compiler's own source grew; not this
section's business.) The census self-compile showed the passes' runtime payoff on this workload is
flat (71.9 → 71.3 s), so every second here is pure cost.

**Target:** the representation step under 2 s on the self-compile, with byte-identical output.

### 13.2 What the step does today (the inventory R0 measures)

With the defaults (`validate` off), in this order:

| # | call | walks | allocation per walk | string keys |
|---|---|---|---|---|
| 1 | `KernelVisible.compute typeEnv graph` | every expression of every node (`nodeRoots`/`exprRoots`), then the closure of each root type (`denyAll`, `declared`, `fieldClosure`) | the root list; `seenDeny`/`seenField`/`instances` sets | `toComparableLayoutType` of every custom type visited, **including already-seen ones** (the key is built to test `seen`) — `KernelVisible.elm:301`, `:384` |
| 2 | `RepresentationMeets.collect graph` | every expression; `splitAt` recursion over every pair of differing types | one `Meet` record per differing pair at every level; a `site` string per meet: `"spec " ++ String.fromInt i ++ " " ++ m.site` (`RepresentationMeets.elm` `collect`), used only by `validate`'s messages | none in `collect`; `components` keys by string (`:482`–`:524`) |
| 3 | `EraseWrappers.erase` | `choose` (over `ctorShapes` and **all meets**: `meetsVar`, `consistentWith`); then per node `Traverse.mapExpr setPrintType`, `Traverse.traverseExpr rewriteExpr`, `Traverse.mapNodeTypes (eraseType e)`; then `Traverse.collectSpecEdges` over all nodes | `mapNodeTypes` **rebuilds every expression of every node** whether or not a type changed (`Traverse.elm:1081`, `mapExprTypes`); the node array; the call-edge array | `Erasable = Dict String …`: `mentions` builds the key of **every custom type at every depth** (`EraseWrappers.elm:133`), and `eraseType` calls `mentions` again at every level it descends (`eraseTypeNow` → `eraseType` per child), so a nested type's keys are built O(depth) times each |
| 4 | `KernelVisible.compute typeEnv erased` | as 1, on the erased graph | as 1 | as 1 |
| 5 | `RepresentationMeets.collect erased` | as 2 | as 2 | — |
| 6 | `NullableMaybe.run` | per node `Traverse.traverseExpr rewriteCase` | the node array rebuilt by `Array.push` | candidate and exclusion sets by string (`NullableMaybe.elm:276`–`:311`) |

`toComparableLayoutType` (`IR/Mono.elm:3711`) concatenates fragments of the whole type into one
`String`: its cost is the type's size, and it allocates. Every composite `MonoType` already carries
its layout hash (`Mono.layoutHashOf`, O(1), `IR/Mono.elm:388`), and `Mono.LayoutMap` is a hash map
on it with `eqKeyLayout` for collisions. That is the "interned id" the fixes use: no new interning
table is needed.

### 13.3 Units

The order below is the expected payoff. **R0 decides the real order**: a unit whose target R0
measures at under 0.3 s is skipped and recorded as such.

#### R0 — measure (no behaviour change except the new timer line)

1. **Own phase timer.** Add `PhaseRepresentation` to `FEStats.PhaseName`
   (`Builder/Eco/FEStats.elm:76`), labelled `"representation"` in `phaseLabel`, placed after
   `PhaseMono` in every list the module keeps of the phases (grep `PhaseMono` in the file). In
   `Builder/Generate.elm` `monoPipelineFrom`, move the `Steps.representation` `Task.andThen` out of
   the `FEStats.withPhaseLazy stats FEStats.PhaseMono` closure into its own
   `FEStats.withPhaseLazy stats FEStats.PhaseRepresentation (\() -> …)` step, chained after the
   mono phase and before `runInlineSimplifyPhase`, as `runInlineSimplifyPhase` is chained. With the
   passes off the line reads about 0 ms and `monomorphization` returns to ~27 s.
2. **Sub-step split, by switches** (no code): three self-compiles with the R0 binary under the
   fe-opt-loop protocol (`benchmarks/fe-opt-loop.md` §2, one run each), reading the
   `representation` line: all on; `ECO_NULLABLE_MAYBE=0 ECO_NULLABLE_USER=0` (steps 1–3); and
   `ECO_ERASE_WRAPPERS=0 ECO_ERASE_UNBOXED=0` (steps 4–6 on the unerased graph). The differences
   give erase vs nullable.
3. **Per-function split, by perf**: one passes-on self-compile under
   `sudo -n perf record -F 499 -g -o /tmp/claude-…/repr.data` (perf needs sudo here), then
   `perf report --no-children --sort symbol` and sum the samples by symbol prefix:
   `Compiler_MonoOpt_KernelVisible_`, `Compiler_Monomorphize_RepresentationMeets_`,
   `Compiler_MonoOpt_EraseWrappers_`, `Compiler_MonoOpt_NullableMaybe_`,
   `Compiler_IR_Mono_toComparable` (the key builder, shared), `Compiler_IR_Mono_Traverse_`, and the
   GC (`eco::` / `Nursery` symbols). Symbols carry their Elm names (e.g.
   `Compiler_MonoOpt_EraseWrappers_mentions_$_31563`). With `--children`, attribute
   `toComparable*` to its callers.
4. **Sizes**: add to `EraseWrappers.renderStats`'s caller in `Steps.representation` the meet count
   (`List.length meets`) and the KV root count (expose `KernelVisible.rootCount` or return it with
   the set), printed under `ECO_INLINE_REPORT=1`.

**R0 result (2026-11-19, binary `eco-optR0`, one self-compile each):**

| run | `representation` | wall |
|---|---|---|
| all on | 8.7 s | 77.03 s |
| erase only (`ECO_NULLABLE_MAYBE=0 ECO_NULLABLE_USER=0`) | 8.2 s | 76.88 s |
| nullable only (`ECO_ERASE_WRAPPERS=0 ECO_ERASE_UNBOXED=0`; one KV + one meets collect) | 0.52 s | 68.97 s |

Sizes (`ECO_INLINE_REPORT=1`): 5,865 KV root types, 93 kernel-visible type constructors, 74,805
meets; erased 66 type constructors (930 instantiations), 3,250 ctor calls and 4,069 unbox steps
removed; 376 of 416 admissible types made nullable, 1,336 tests rewritten.

perf (`-F 499 -g`), the 8.87 s window in which pass frames appear, main thread (4,426 samples):
`StringOps::join` 17.3 %, `ListCursor::advanceSpine` 10.2 % (the fragment lists `String.concat`
walks), `Dict_balance`/`insertHelp`/`get`/`foldl` 15 %, `toComparableFragments(Rev)` 6.9 %,
`StringOps::compare` + `eco_string_cmp3` 10.1 %, `Allocator::resolve` 6.3 %. Where the call chain
survives, the innermost pass frame is `EraseWrappers.mentions` (14.0 %, under
`Traverse.mapNodeTypes`) or `EraseWrappers.choose` (13.1 %, its `meetsVar` set union over every
meet); `RepresentationMeets` 5.5 %; 62.7 % of the samples lose the chain inside the string and
`Dict` kernels. **Reading:** the cost is building and comparing layout-key strings, nearly all of
it in `EraseWrappers`; the analyses (KV, meets) cost about 0.5 s together. So R1 comes first and
carries most of the gain; R2 (KV and meets once) can save at most about 0.25 s, under the 0.3 s
skip bar, but is kept because R3 needs its translations; R4's `eraseTypeMaybe` removes the
repeated `mentions` descent.

Record the four results in a table under this unit (the `representation` time, the split, the top
15 symbols, the sizes). **Gate R0-D:** none; R0 only orders R1–R4.

#### R1 — layout-hash keys instead of built strings

Replace every `Dict String` / `Set String` keyed by `Mono.toComparableLayoutType` in the four
modules with `Mono.LayoutMap` / a new `Mono.LayoutSet`. Strings stay only where a message is
printed (`RepresentationMeets.validate`, `EraseWrappers.check`).

1. **`IR/Mono.elm`:** add, next to the `layoutMap*` functions (`:799`–`:844`) and in the same style
   (they wrap `Data.HashMap` with `layoutHashOf` and `eqKeyLayout`):
   `type alias LayoutSet = LayoutMap ()`, `layoutSetEmpty`, `layoutSetInsert`, `layoutSetMember`,
   `layoutSetFromList`, `layoutSetUnion` (a fold of inserts), `layoutSetSize`, plus
   `layoutMapIsEmpty` and `layoutMapSize` (`Data.HashMap` exposes `isEmpty` and `size`). Expose them.
2. **`MonoOpt/KernelVisible.elm`:** `KvSet`'s instance set (`:59`) and `Acc`'s `instances`,
   `seenDeny`, `seenField` (`:117`–`:119`) become `Mono.LayoutSet`; `denyAll` (`:301`) and
   `fieldClosure` (`:384`) test `layoutSetMember t` instead of building `key`; `addCtor` takes the
   type instead of the key; `isVisibleInstance` (`:107`) uses `layoutSetMember`. The ctor set
   `Set ( String, String )` stays (its keys are names, not built from types).
3. **`Monomorphize/RepresentationMeets.elm`:** `components` (`:482`–`:560`): give each distinct
   type in the meets a dense `Int` id through one `LayoutMap Int` built in a single fold over the
   meets; `rep` becomes `Dict Int Int` (or an `Array Int`), `members` `Dict Int (List MonoType)`,
   `adjacency` `Dict Int (List Int)`, `flood` works on `Set Int`; `componentOf` (`:561`) looks the
   type up in the id map. The type at `:85` likewise.
   **Meet sites:** `Meet` gains a `spec : Int` field beside `site`, which keeps the constant
   literal the call site passes; `collect` stops concatenating; `validate` formats
   `"spec " ++ String.fromInt spec ++ " " ++ site` when it prints. *(Amended 2026-11-20: a field
   beside `site` rather than a `{ spec, what }` record in its place; same content.)*
4. **`MonoOpt/EraseWrappers.elm`:** `Erasable` (`:110`) becomes
   `Mono.LayoutMap ( Mono.MonoType, Mono.MonoType )`; every `Dict.member`/`Dict.get` on
   `toComparableLayoutType` (`:133`, `:167`, `:368`, `:665`, `:712`, `:776`, `:798`, `:1021`,
   `:1158`) becomes `layoutMapMember`/`layoutMapGet`; `insts` (`:498`), `succ` (`:536`, the cycle
   graph: key it by the same dense ids as in 3, or by `LayoutMap`), `toErasable` (`:576`),
   `meetsVar` (`:597`–`:624`, a `LayoutSet`); `Dict.isEmpty e` → `layoutMapIsEmpty e`.
   **No name pre-filter.** *(Amended 2026-11-20, by the 13.5 re-profile.)* This step first kept a
   `Set String` of the erased type constructors' names and tested it before the layout lookup. The
   re-profile after R4b put 30 % of the phase in that set's string compares, while the lookup it
   guarded compares `Int`s (the layout hash is read off the type, not computed), so `isErasable`
   and `erasableGet` call `layoutMapMember`/`layoutMapGet` directly (−0.2 s, R4f).
5. **`MonoOpt/NullableMaybe.elm`:** `candKeys` and `excluded` (`:276`–`:311`) become `LayoutSet`s.

**Order traps.** `Dict String` iterates in key order, `LayoutMap` in insertion order. Check each
fold whose result is a list or numbering: the identity nodes' lambda indices come from a fold over
the node array (unchanged); `Erasable`'s order is never emitted; `components`' representative
choice changes but only membership is read. If any output changes, the identity gate (13.4) says
so.

#### R2 — kernel visibility and meets once, translated through the erasure

Steps 4 and 5 recompute on the erased graph what steps 1 and 2 already know.

1. **`EraseWrappers.translateKv : Erasable -> KernelVisible.KvSet -> KernelVisible.KvSet`** (or in
   `KernelVisible`, taking the type map as a function): the ctor set unchanged; each instance type
   `t` replaced by `eraseType e t` (re-inserted in a fresh `LayoutSet`). *(Built as named:
   `EraseWrappers.translateKv e kv = KernelVisible.mapInstances (eraseType e) kv`; R2.4's subset
   check holds on the whole `SourceIR` catalogue and the self-compile.)* **Why this is safe:**
   `choose` never erases a type in the set, and an erased `W` is never inside the closure (reaching
   `W` from a root would have marked it), so the closure of the erased roots is the erased closure
   of the roots. The one difference: `declared` searches the type arguments of every custom type
   on its path, and a phantom argument of `W` that its payload drops is still found by the
   translation and no longer by a recompute. So translation ⊇ recompute: a type may stay
   kernel-visible that would not be, which only forgoes an optimization, never breaks one.
2. **`RepresentationMeets.translate : (MonoType -> MonoType) -> List Meet -> List Meet`**: for each
   meet, `splitAt` again on `( f m.a, f m.b )` with its `root` flag and `site` (so a pair that
   erasure makes layout-equal is dropped, and any interior pair the erased types newly expose is
   recorded). The meets made by a removed constructor call (`W`'s parameter vs. the argument) map
   to layout-equal pairs and drop out, as they do on recompute. *(Amended 2026-11-20: duplicates are
   kept. Every reader takes the meet list as a set (the nullable exclusion, `consistentWith`, the
   R2.4 comparison, which compares sets), so a duplicate changes no decision, and removing them
   would be work spent for nothing.)*
3. **`Steps.representation`:** steps 4 and 5 become `translateKv e kv` and
   `RepresentationMeets.translate (eraseType e) meets`. `EraseWrappers.erase` returns its
   `Erasable` (add it to the result, or expose a `plan` step; see R3), so the caller can translate.
   When `erase` erased nothing, pass `kv` and `meets` through unchanged.
4. **Checker:** under `checks` (`ECO_REPR_VALIDATE` / `ECO_MONO_VALIDATE`), also compute both
   recomputes and compare: the recomputed instance set must be a subset of the translated one, and
   the meet sets must be equal as sets of `( layout key a, layout key b, root )` (strings are fine
   here). A difference is reported as a violation with the first five differing entries.
5. **Gate R2-D (exactness):** with R2 in, `NullableMaybe`'s report line (`ECO_INLINE_REPORT=1`) on
   the self-compile and on every E2E program in the corpus run is **identical** to the line before
   R2: the same candidates, exclusions and rewritten tests. If the superset in 1 ever excludes a
   type the recompute would not, the line differs and R2 must narrow `translateKv` (recompute only
   for the instances whose types contain an erased constructor) before it lands.

#### R3 — one rewrite pass for erase and nullable

After R2 the nullable choice no longer needs the rewritten graph, only `ctorShapes1`, the
translated KV set and the translated meets. So both decisions can be made first, and the nodes
rewritten once.

1. **Split `EraseWrappers.erase`** into
   `plan : Options -> KvSet -> MonoGraph -> Plan` — `choose`, `ctorSpecs`, `ctorShapes1`,
   `erasedKeys`, `erasedCtorNames`, the stats so far; no node is touched — and
   `rewriteStep : Plan -> Counts -> MonoExpr -> ( Maybe MonoExpr, Counts )` (today's
   `setPrintType` then `rewriteExpr`, composed: apply `setPrintType`; on its result, or on the
   original if `Nothing`, apply `rewriteExpr`; `Just` if either changed), plus
   `finish : Plan -> Array (Maybe MonoNode) -> MonoGraph -> ( MonoGraph, EraseStats )` (the identity
   nodes, the registry's `reverseMapping`, `lssMemberOrigins`, `repr`; everything after the node
   loop in today's `erase`). *(Amended 2026-11-20. The composed step is built as specified, inside
   `EraseWrappers.rewriteNodeExprs`, run by `rewriteNodes : Plan -> touches -> extra -> ctx ->
   MonoGraph -> Rewritten ctx` (the node loop, which also replaces the constructor nodes and
   erases types, so `finish` takes its `Rewritten` record). One fact this text left out: the
   traversal is bottom-up, so when it reaches a `Debug` call an argument that was an erased
   constructor call is already its field and its type is gone from the expression. `Counts`
   therefore carries `lastRemoved` (what the last removal produced and the call's type), set by a
   removal and cleared at every other node; a call's arguments are the last children visited
   before the call, so `setPrintType` at a `Debug` call reads the printed argument's original type
   from it. Reading it from the `Debug` kernel's own type instead (R4e) fails, since that type is
   generic.)*
2. **Split `NullableMaybe.run`** into `choose : {userTypes} -> KvSet -> List Meet -> LayoutMap
   (List CtorShape) -> Choice` (a record of the chosen `LayoutMap Info` and the `NullStats`),
   `recordNullable : Choice -> MonoGraph -> MonoGraph` (writes the choice into `repr.nullable`),
   and the existing `rewriteCase` exposed as `rewriteStep norm nullable`: `rewriteCase` looking
   each tested type up through `norm`, so that it can run in the fused traversal before the types
   are erased (R3.3 passes `eraseType e`).
3. **New module `Compiler.MonoOpt.Representation`** (`compiler/src/Compiler/MonoOpt/`; tests in
   `compiler/tests/Compiler/MonoOpt/RepresentationTest.elm`, per the test-layout rule) owning the
   loop that `Steps.representation` now spreads over two passes: for each node, one
   `Traverse.traverseExpr` whose step is `EraseWrappers.rewriteStep` followed by
   `NullableMaybe.rewriteCase` on its result (bottom-up, so a case's decider is erased before the
   nullable rewrite sees it, as today), then `mapNodeTypes (eraseType e)` (R4 limits it), counters
   threaded in one record. `Steps.representation` keeps its signature, report lines and checks; it
   calls `EraseWrappers.plan`, the translations (R2), `NullableMaybe.choose`, the new loop, then
   `EraseWrappers.finish`, and sets `repr.nullable` as `run` does today.
4. The old `erase` and `run` stay as thin wrappers over the pieces, so their unit tests
   (`EraseWrappersTest`, `NullableMaybeRunTest`) keep testing the same behaviour.

#### R4 — leave unaffected nodes alone

1. **Which nodes.** A node needs work only if one of its types mentions an erased or nullable type:
   ctor calls, destructs, cases and `Debug` calls on those types all carry them. Two read-only
   scans (`Traverse.anyNodeType`, `Traverse.elm:1304`, which reaches the same positions as
   `mapNodeTypes`) decide, in order:
   - `anyNodeType (mentions e) node`: the node mentions an erased type and gets the full rewrite
     (the composed erasure step and the nullable step in one traversal, then the type rewrite);
   - otherwise `anyNodeType (NullableMaybe.touches nullable) node`: the node holds a custom type
     named like a nullable type and gets the traversal with the nullable step alone, no type
     rewrite. `touches` matches by name: before erasure a type can name a nullable type only
     directly or through an erased one, and the first scan catches the second case.
   Any other node is kept as the same value: no traversal, no rebuild. (A single combined predicate
   sends `Maybe`-only nodes through the type rewrite too; measured at +0.4 s on the phase, R4's
   first try in 13.6.)
2. **Types without the copy.** For affected nodes, `mapNodeTypes` still rebuilds the node's whole
   tree. Add `Traverse.mapNodeTypesMaybe : (MonoType -> Maybe MonoType) -> MonoNode -> Maybe
   MonoNode` sharing unchanged subtrees (the `travExpr` pattern: `Nothing` = unchanged), and
   `EraseWrappers.eraseTypeMaybe : Erasable -> MonoType -> Maybe MonoType`, one descent that
   rebuilds only the spine above an erased type and returns `Nothing` when nothing changed; then
   `eraseType e t = Maybe.withDefault t (eraseTypeMaybe e t)` and `mentions` is no longer called
   from it (the O(depth²) key building goes).
3. **Call edges.** Erasure changes calls only in rewritten nodes (it removes calls to erased ctor
   specs), and nullable changes none. Replace `Traverse.collectSpecEdges nodes3` with an update of
   `g.callEdges` at the indices of rewritten nodes and of the new identity nodes; expose
   `Traverse.specEdgesOfNode` for it.
4. **Arrays.** The node loop returns the same `Maybe MonoNode` for unaffected indices. *(Amended
   2026-11-20: it stays an `Array.foldl` that pushes each node, since it threads the lambda counter
   of the identity nodes, the counts and the visited set, which `Array.indexedMap` cannot;
   `NullableMaybe.run`'s own loop is no longer on the path, `Representation.run` replaces it.)*

### 13.4 Gates (every unit)

1. **Identity:** the passes' output must not change. Before the first unit, record a baseline with
   `test/scripts/dc-corpus.py mlir /tmp/claude-…/repr-base` after a `full` run (it copies
   `build/test/*/eco-stuff/mlir/*.mlir`); after each unit, `full`, `dc-corpus.py mlir …/repr-RN`
   and `dc-corpus.py diff`: **no differing file** (R0 too: its timer must not change output).
   Wipe the E2E caches first (`build/test/*/eco-stuff`, and the `~/.eco/<ver>` package artifacts),
   since `full` clears neither.
2. **Self-compile:** the fe-opt-loop single run (§2 of that file, the `ctorrep` row's protocol) of
   the unit's candidate, fixed point checked, reading the new `representation` line; record the
   row in `benchmarks/fe-opt-loop.md` (judged against the previous unit's row, the first against
   `ctorrep`).
3. **Keep rule:** keep a unit if the `representation` line drops by at least 0.3 s, or if it deletes
   work with a flat line (the fe-opt-loop's "flat deletions ship" rule). Otherwise revert
   (`benchmarks/lss-loop-snap.sh` snapshot before each unit).
4. **Tests:** `elm-tests` once per unit (the plan's unit tests plus `ReprPassesTest` and
   `SourceIR.WrapperCases` cover every pass under both engines); R2 adds a unit test of
   `translateKv`/`translate` against the recompute on the `EraseWrappersTest` program; R3 adds
   `RepresentationTest` (one program with a wrapper inside a `Maybe`: the fused loop gives the same
   graph as `erase` then `run`, compared with `Mono.toComparableMonoType` of every node type and
   the rewrite counters); R4 adds a test that an unaffected node is returned as the same value
   (count rewritten nodes on a program with one affected and one unaffected function).
5. **End of section:** `full`, `bootstrap` (Stage 8c) and the TLA+ canary once, after the last kept
   unit.

### 13.5 Stop rule

After R4, if the `representation` line is still over 2 s, re-run R0.3 (perf) and record what is
left before deciding anything else. If it is under 2 s, close this section: record the final row
and update the front matter's `remaining`.

### 13.6 Implementation record (2026-11-19)

All five units are built and gated: per unit, `full` 3,118/3,118, the E2E MLIR corpus (1,544
files, `test/scripts/dc-corpus.py`) byte-identical to the pre-R0 baseline, and one fe-opt-loop
self-compile at its fixed point (rows R0–R4b in `benchmarks/fe-opt-loop.md`).

| unit | `representation` | wall | kept? |
|---|---|---|---|
| R0 | 8.7 s | 77.03 s | measurement (results under R0 above) |
| R1 | 2.5 s | 72.28 s | WIN |
| R2 | 2.1 s | 72.15 s | kept (−0.4 s) |
| R3 | 2.1 s | 70.63 s | FLAT, kept: deletes the nullable pass's own node loop |
| R4 first try | 2.5 s | 70.51 s | LOSS on the phase, revised |
| R4b | 2.2 s | 70.83 s | FLAT, kept: deletes work (unaffected nodes not walked or rebuilt; promoted −51 MiB) |
| R4d (R4.2 as written) | 2.0 s | 71.14 s | kept: −0.2 s |
| R4e (+ composed `setPrintType`) | 1.8 s | 70.73 s | **FAILED its gate** (7 E2E tests, see below), not kept |
| R4f | 1.8 s | 71.52 s | WIN on the phase (−0.4 s vs R4b); `full` 3,119/3,119, corpus identical but the new fixture |
| R4g (R3.1 composed, exactly) | 1.7 s | 70.85 s | `full` 3,119/3,119, corpus identical but the new fixture (fixed point not valid: the source was edited during the run) |
| R4h (+ R2.4 checks as written) | 1.8 s | 70.35 s | `full` 3,119/3,119, corpus identical but the new fixture, fixed point, validation self-compile clean |
| R4i (`eraseType` = one `eraseTypeMaybe` descent, as R4.2 writes) | 1.7 s | 69.72 s | `full` 3,119/3,119, corpus identical but the new fixture, fixed point, validation self-compile clean |
| R4j (final: `EraseWrappers.translateKv` as R2.1 names it; no behaviour change) | 1.8 s | 70.88 s | `full` 3,119/3,119, corpus identical but the new fixture, fixed point, validation self-compile clean |

**Deviations from the text above:**
- R1.3: a meet's site is a separate `spec : Int` field next to the literal `site`, not a record.
- R2.4 is built as written (R4h): under `checks`, the recollected instance set must be within the
  carried-over one and the carried-over and recollected meets must be the same set by
  `( layout key a, layout key b, root )`; the nullable decision is compared too. They hold on the
  whole `SourceIR` catalogue (`ReprPassesTest`, every pass on, `repr.validate`) and on an
  `ECO_REPR_VALIDATE=1` self-compile, which reports no violation and produces the unchanged MLIR
  (`nullable-maybe: 386 of 426 ... 1,422 tests`). R2-D held at every R unit: the corpus is
  byte-identical and the self-compile at its fixed point. The meet list is not deduplicated:
  duplicates are harmless to its readers.
- R3: the nullable step looks tested types up through `eraseType` (`NullableMaybe.rewriteStep`),
  since in the fused traversal types are erased after it. `EraseWrappers.erase`/`eraseKeeping` and
  `NullableMaybe.run` remain, built from the pieces.
- R4: the first try (a `Traverse.mapNodeTypesMaybe` that shared only per node, after a second
  read-only scan, with `eraseTypeMaybe` allocating at every list) cost 0.4 s on the phase. R4b
  scans a node for erased types (`mentions`, no allocation) and, failing that, for nullable names
  (`NullableMaybe.touches`): a node with erased types gets the full rewrite, one with only nullable
  names the fused walk alone, any other node nothing. R4d then built R4.2 as written:
  `Traverse.mapNodeTypesMaybe` shares every unchanged subtree (expression, path, decision tree,
  closure and call record, type list; the positions of `mapNodeTypes`), and `eraseTypeMaybe`
  allocates nothing when nothing changes. Call edges are recomputed only for visited nodes. The
  node loop stays an `Array.foldl` (it threads the lambda counter); unvisited nodes are pushed as
  the same value.
- R1.4's name pre-filter is gone (R4f): the 2.2 s re-profile put 30 % of the phase in its
  `Set String` compares, while the layout-hash lookup it guarded compares `Int`s (the hash is read
  off the type). `isErasable` and `erasableGet` look the layout hash up directly: −0.2 s.
- R3.1 (`setPrintType` then `rewriteExpr`, composed) is built as written (R4g). One fact the plan
  did not state: the traversal is bottom-up, so when it reaches a `Debug` call an argument that was
  an erased constructor call is already its field, and its original type is gone from the
  expression. The step therefore records each removal (`Counts.lastRemoved`: what it produced and
  the call's type) and every other node clears it; a call's arguments are the last children visited
  before the call, so at a `Debug` call the record is the printed argument's, when it has one. A
  first composition (R4e) read the printed type from the `Debug` kernel's own type instead, which is
  generic, and failed 7 E2E tests (`EraseWrapperDebugTest`, `...FloatTest`, `...PolyTest`,
  `...RecursiveTest`, `...SetDictTest`, `HoleyAliasTwoParamsTest`, `RecordNarrow08NoDestructureTest`:
  `q: 1.5` printed for `q: Quantity 1.5`); R4f went back to a pre-walk, R4g composed it as above.

**A bug in N1 found on the way (fixed, R4d):** the R4d source crashed every compiler with the
nullable pass on, back to `eco-optCTOR`: `MONO_019 violation: two different lambdas are both named
'Terminal_Main_lambda_30645' (in Basics_composeL_$_45091)`. `NullableMaybe.rewriteDecider` splits a
chain of several tests (one on a nullable value) into nested one-test chains, each with the chain's
failure branch: an `Inline` leaf of that branch holding a closure put its lambda in the graph once
per test under one lambda id, and later passes transformed the copies apart. Exposed first by
`NullableMaybeRunTest` "splitting a chain of tests duplicates no lambda (MONO_019)" (failed:
lambda 1 twice), then fixed: `NullableMaybe.prepareChains` moves each such leaf into a new jump of
the `case`, so the copies share it; leaves without a closure stay inline, and no existing E2E
program's MLIR changed. E2E fixture: `NullableChainClosureTest`.

**Tests added:** `EraseWrappersTest` (carried-over KV and meets lead to a recollection's nullable
decision), `RepresentationTest` (one loop equals erase then nullable; an unaffected node is not
visited and comes back the same), `NullableMaybeRunTest` (no duplicated lambda), E2E
`NullableChainClosureTest`.

**Stop rule (13.5):** after R4b, 2.2 s was over the 2 s target, so R0.3 was re-run on `eco-optR4b`: the
phase's window is 2.26 s, 1,120 main-thread samples. Innermost pass frame `isErasable` 18.2 %,
`mentions` 17.4 % (their time is the `Set String` name pre-filter: `Dict_get` 9.6 %,
`StringOps::compare` 10.7 %, `eco_string_cmp3` 10.1 %; and `mentions`' `Dict.values` on records,
`Dict_foldr` 5.2 %, `List_any` 7.4 %), `RepresentationMeets.splitAt` + `exprMeets` 10.5 %,
`erasableGet` 3.5 %. Acting on it: `mentions` folds record fields without `Dict.values` (R4d), and
the name `Set String` was dropped for the layout-hash lookup (R4f, above). Final: **1.8 s**, under
the target; this section is closed.

**End gates (final tree, R4j):** `full` 3,119/3,119; elm-tests 22,007/0; `bootstrap` rc 0 through Stage 8c (native fixed point) and 9b; an `ECO_REPR_VALIDATE=1` self-compile clean with unchanged output; canary passing.


## 14. K1 default on (2026-11-21)

The gate for K1 is now the E2E fixtures instead of K0-D's self-compile site count (user
direction): `test/eco-mlir/src/KnownCtorCaseFoldTest.elm` (new) and
`test/elm/src/KnownCtorCaseTest.elm`, which until now only ever ran with the pass off.

- **New fixture.** Seven scenarios checked against Elm's output (node): a direct `let`, a builder
  and a matcher both inlined, a literal and a top-level argument, a 1,000,000-iteration
  tail-recursive loop, a nullary constructor, a value still used after the `case`, a `String`
  field. Its CHECK-MLIR-NOT lines assert that no `eco.construct.custom` names the folded
  constructors (`KcPair`, `KcRect`, `KcLit`, `KcStep`), and a CHECK-MLIR line that `KcKeep`, used
  after its `case`, is still built. With the pass off the fixture fails on those lines.
- **Exposed and fixed.** Inlining a function that builds the value (`helper`) gave no site:
  `InlineSimplify` binds each parameter to a fresh name, so the value's binding is
  `x = (let p = a in ... C p ...)`, and `knownOf` only recognised a bare constructor call.
  `KnownCtorCase.floatOut` floats such a chain above the binding (pure and strict, so evaluation
  order is unchanged; only when no floated name is used by the body). Unit test `wrapped` in
  `Compiler/MonoOpt/KnownCtorCaseTest` (red before the fix: 4 sites, not 5). With it the fixture's
  census is `sites=7 folded=7 bindingsDropped=6`.
- **Gates** (unit `K`, snapshot `repr-K`, full chain against `eco-optF1d`): full 3,141/3,141
  (both fixtures pass), elm-tests 22,043/0, bootstrap 8c/9b, AOT 1,513/1,513, stress 114/114 in both
  configs, TLA canary, fixed point, `ECO_REPR_VALIDATE` self-compile identical.
- **Self-compile** (quiet machine, alternating, 3 runs each): `eco-optF1d` 77.55 / 76.33 / 75.71 s
  (median 76.33), `eco-optK` 77.18 / 77.42 / 76.12 s (median 77.18): +1.1 % median, +0.5 % mean,
  inside the 1.3 % noise; output byte-identical. The self-compile still has 0 sites with the
  floating (`ECO_INLINE_REPORT=1`): its matching functions exceed the post-mono inline budget
  (`postMonoThreshold` 10), so they are not inlined where their argument is built. The pass pays in
  programs whose small matchers do inline.

