---
status: not-started
updated: 2026-11-19
---

# Constructor representation: four levels of custom-type unboxing

This plan covers how the native backend represents values of custom types, by the shape of the
type:

| Level | Shape | Example | What this plan does |
|---|---|---|---|
| 1 | one constructor, one field | `type Quantity n u = Quantity n` | erase the wrapper everywhere (unit group E) |
| 2 | one constructor, several fields | `type Pt = Pt Float Float` | return in registers, smaller heap object (group S) |
| 3 | several constructors, at most one field each | `Maybe a`, `Result e a` | `Just x` as bare `x` (group N); the old option (b) deferred |
| 4 | several constructors, several fields | `Dict`'s `RBNode_elm_builtin` | local only: fold `case` on a known constructor (group K) |

The JS backend is out of scope: it already erases level 1 (`Opt.Box` → identity,
`GenerateJs/Generate.elm:306`) and its object model makes the other levels moot.

Relationship to `plans/sum-type-wrapper-unboxing.md`: that plan's option (a), nullary embedding, has
shipped (`plans/null-cons-hpointer-embedding.md`). Its remaining option (b), unboxing
multi-constructor one-field unions by their payload's runtime tag, becomes unit N2 here. Its W1
table also rests on a wrong premise: it says one-constructor one-field types "are already
`Can.Unbox` and never allocate a `Custom`". They do allocate natively (§1), so its 1-field pool
mixes levels 1 and 3.

## 1. Where things stand

### 1.1 What the native backend does today

- **Level 1.** `toOpts` (`Canonicalize/LocalEnvironment.elm:690`) marks a type `Can.Unbox` when it
  has exactly one constructor with exactly one argument. Typed optimization turns that into
  `TOpt.Box` (`LocalOpt/Typed/Module.elm:278`). Both mono engines then specialize a `Box` as an
  ordinary one-field constructor (`Subst/Specialize.elm:1674`; `Solver/Monomorphize.elm:3998` and
  `:4129`). The value is a heap `Custom` with tag 0, built by
  `eco.construct.custom` and read back by `eco.project.custom` (`MonoUnbox` path segments).
- **Existing aggregate passes** (`Compiler/Config.elm`, all on by default):
  - `aggPromote` keeps a let-bound constructor value in SSA (`eco.make.custom`) when every use
    only reads a field. A use that tests the tag disqualifies it
    (`GenerateMlir/Expr.elm`, `promotableCtorCall`, around line 6400).
  - `ctorInline` builds the value in the caller, still on the heap.
  - `sretResults` covers returned 2- and 3-tuples only (`Backend.elm` `sretInfoOf`, line 409).
  - `psplitParams` splits a parameter that is a 2- or 3-tuple, or a one-constructor custom with
    **2 to 6** fields (`Backend.elm` around line 854). One-field types never qualify.
- **Nullary constructors.** `Nothing` is the shared Empty constant (0x6), which `()`, `{}`, `[]`, `""`
  and empty Bytes also use. `True`/`False` are 0x5/0x4. Every other nullary constructor is a
  null-cons word `(idx << 43) | 0b111`, where `idx` is its declaration index. Null-cons words are
  **not unique per type** (`runtime/src/allocator/Heap.hpp:14-25`, `IR/Runtime/CtorTag.elm`).
- **`Debug.toString` is typed.** The compiler emits `eco.type_table`, and the printer takes a type
  id (`Elm_Kernel_Debug_toString_typed`, `elm-kernel-cpp/src/core/DebugExports.cpp:63`;
  `runtime/src/allocator/TypeInfo.hpp`). A representation change can therefore keep the output
  identical by adding a type kind the printer understands.

A probe (one function per case, `--text-mlir`) confirmed the passes catch only local cases:

| Case | Today |
|---|---|
| let-bound wrapper, only unwrapped | SSA, no allocation |
| `f (Q x)` where `f` gets inlined | SSA, no allocation |
| wrapper returned from a function, or passed to one that is not inlined | heap on both sides |
| `List.map Q xs`, `List.foldl add (Q 0)` | one heap object per element or step |
| `case WorkA x of ...` on a multi-constructor type | heap, even though built and matched locally |

### 1.2 Measurements (2026-11-19)

**Dynamic.** The compiler self-compiling (`eco-compiler-boot make --optimize`, solver and LSS, cold
project cache) was measured with scratch instrumentation in `/work/worktrees/ctorcensus`, which is
not in the repo:
- Every `eco.construct.custom` site in the self-compile MLIR was tagged with a per-constructor id.
- The runtime counted allocations at the site and promotions in all three minor-GC copy paths.
- One-constructor versus multi-constructor was classified from the source declarations by
  (constructor name, field count). 215 of 54,934 sites were ambiguous and are listed separately.
- The instrumented compiler's output was byte-identical to an uninstrumented one built from the
  same sources.
- Kernel-built customs (from C++) are not counted as allocations. They appear only as
  unclassified promotions (about 7k).

All of these allocations happen with today's passes on:

| Level | Allocated | % | Promoted | % | Main constructors (allocated) |
|---|---|---|---|---|---|
| 1 | 103.4M | 8.6 | 7.4M | 5.4 | `Unify` 37.5M, `Parser` 22.1M, `Pt` 17.9M, `StringTable` 8.3M, `RResult` 6.6M, `Set_elm_builtin` 2.4M, `Decoder` 1.7M |
| 2 | 124.0M | 10.3 | 22.3M | 16.2 | `Array_elm_builtin` (4 fields) 71.2M, `FieldType` (2) 20.7M, `UnifyOk` (2) 20.5M, `OpBuilder` (2) 3.4M |
| 3 | 425.6M | 35.3 | 17.1M | 12.4 | `Just` 299.8M, `Leaf` 30.1M, `Ok` 20.9M, `SubTree` 20.5M, `Structure` 15.1M, `U8` 13.9M |
| 4 | 553.7M | 45.9 | 90.5M | 65.9 | `RBNode_elm_builtin` 394.5M, `TType` 32.6M, `Root` 32.1M, `App1` 10.3M |
| ambiguous | 0.6M | 0.0 | 0.2M | 0.1 | |
| total | 1,207M | | 137.4M | | |

Notes on the table:
- `Pt` (promoted 7.0M) and `FieldType` (promoted 19.3M of its 20.7M) are the long-lived ones.
  `Unify`, `Parser` and `UnifyOk` are never promoted: they are pure allocation churn.
- This is one workload: a compiler built from monadic parsers and unifiers. `Just` and `Dict` occur
  in nearly every Elm program; `Unify`/`Parser` stand for any wrapped-function style.

**Static.** Type definitions by shape, counted from source (`/tmp/ctorcensus/elmtypes.py`):

| Corpus | Types | 1 ctor 1 field | 1 ctor 2+ fields | multi, all ≤1 field | multi, some 2+ | enum |
|---|---|---|---|---|---|---|
| `compiler/src` | 632 | 98 | 99 | 113 | 230 | 92 |
| all packages on disk (eco home and `~/.elm`) | 1,543 | 367 | 155 | 402 | 248 | 371 |
| eco test, example and benchmark programs | 504 | 163 | 55 | 139 | 71 | 76 |

Ordinary packages and programs define proportionally more one-field wrappers (24–32% of types) than
the compiler (16%).

## 2. Shared component: which types may change representation

Levels 1, 2 and 3 all change how some `MonoType` is laid out. The change is safe only if every
piece of code that sees a value of that type agrees. That code comes in three kinds.

**Compiled Elm code.** Every view of a value must agree on its representation. MONO_029's text
says that views agree at each interior position: either all are concretely equal or all are
erased. **That is not what is enforced.**
- `Compiler.Monomorphize.ValidateLayout` checks only the ABI kind. It explicitly does not check
  constructor fields, captured closure values, or ordinary call arguments. Its doc calls a
  mismatch between an erased type variable and a concrete type there "harmless".
- It is harmless today only because both sides are boxed heap shapes of the same kind.
- A specialization that keeps `MVar _ CEcoValue` (MONO_021) can therefore receive a concrete
  value through a call argument. For example, an erased spec of `Maybe.withDefault` receiving a
  `Maybe Rec`.

Three representation changes have different exposure to this:

- **Decided per type constructor, independent of its arguments** (S2, and E1a below). An erased
  view and a concrete view of the same type constructor get the same representation. Today's
  mismatches stay harmless.
- **Changed from boxed to boxed** (E1a: wrapper → boxed payload). The erased side holds an
  opaque `!eco.value` it never inspects as a wrapper, because erasure removes every wrapper
  inspection. Safe.
- **Decided per instantiation, or boxed → unboxed** (E1b: wrapper → `f64`; N1: `Maybe Rec` → bare
  `Rec`). A concrete view and an erased view of the same value can then disagree. Example:
  `List (Q Float)` erasing to `List Float`, which has unboxed heads, flowing into a `List a`
  parameter. Another: a bare `Rec` flowing into an erased `Maybe a` whose `case` reads a `Custom`
  tag. **This miscompiles unless excluded.** Units V and E1b/N1 below deal with it.

At top level, call-boundary boxing (CGEN_001, CGEN_007) converts `f64`/`i64` to `!eco.value`. It
does not convert between two `!eco.value` representations, so it cannot rebuild a `Just` around a
bare value.

**Kernel C++.** The kernel builds and reads `Custom`s by hand:
- about 38 `alloc::just`/`justKind` call sites and 65 `nothing(` uses across `runtime/src` and the
  kernel trees;
- `Result`, `Order`, Json, Http and VirtualDom code;
- the typed printer, which recognises `Set_elm_builtin` by name (`RuntimeExports.cpp:3649`).

A type the kernel builds, inspects, or receives in a known shape must keep its heap
representation. Kernel-opaque types need special care. They are declared in Elm with a dummy
nullary constructor, but their runtime word is whatever the kernel produces, and it can be Empty:
- `type Bytes = Bytes`, whose empty value is Empty;
- `Task`, `ProcessId` and `Program` in `Platform`;
- `Json.Encode.Value`, `Regex`, `File`, `Html`, and the eco/system handles.

**Compiler code that recognises types by name.** BytesFusion matches `Bytes.Decode.Decoder`
(`BytesFusion/Reify.elm:2067,2132,2199`) and builds `Just` directly (`BytesFusion/Emit.elm:2031,2041`).
`Backend.elm:1309-1347` and `Functions.elm:1462` special-case `Nothing`.

### 2.1 Unit KV: the kernel-visibility set

Compute, once per program after monomorphization, the set of types whose representation must not
change. It is kept per **type constructor** (home module and name) wherever the change is decided
per type constructor (E1a, S2), so that every instantiation agrees. A type T is in the set when:

1. T occurs within the type of an argument or the result of a `MonoCall` to a `MonoVarKernel`
   that is not on the **transparent list**. Use the argument and result *expression* types: a
   kernel with a type variable has a boxed root ABI, so the `MonoVarKernel` reference's own type
   carries `MVar _ CEcoValue` there, not T (`Monomorphize/KernelAbi.elm:15-25`). A kernel used as
   a first-class value (not called directly) counts as non-transparent for every type in its
   context type.
   - A transparent kernel only moves its type-variable values, or compares them with the generic
     equality. Equality is word-based for constants (`UtilsExports.cpp:97-109`), and both sides
     share one representation, so it is representation-agnostic.
2. T occurs in a port or flags type (`MonoPortIncoming`/`MonoPortOutgoing`, `flagsSchema`). Their
   decoders and encoders build and read values in the kernel.
3. T's home type is on the **by-name list**: types matched by name in compiler or kernel code.
   Initially `Bytes.Decode.Decoder`, `Set_elm_builtin` (until E2 gives the printer a Wrapper arm
   for it), `Maybe` for the BytesFusion sites until they are rewritten, and any type KV0 finds.
4. T is **kernel-opaque**, meaning its values are produced by a kernel (§2 list). Opaque types are
   denied by default until KV0 has audited each one.

Conditions 1 and 2 are judged on the type *after* any erasure from level 1, so the analysis runs
inside the same pass, iterated to a fixed point (§3).

### 2.2 Unit V: a representation validator

Strengthen `ValidateLayout`, or add a sibling check under `ECO_MONO_VALIDATE=1`, for every type
whose representation this plan changes. It checks that every pair of views meeting at the
following points has the same *representation*, not just the same ABI kind:
- call arguments and results;
- closure captures;
- constructor fields;
- tail-call arguments;
- kernel call arguments.

Run it after `EraseWrappers` and after N1. Note that `checkLayout` runs before E1's insertion
point (`Builder/Generate.elm:961`), so without V the erased graph is never validated. V is a
prerequisite of E1b and N1, and a gate for E1a and S2.

V also produces the exclusion data for E1b and N1: the set of types that meet an erased view
somewhere.

**KV0 (audit, before any code).**
- List the kernel functions that construct or inspect values of a type-variable or named
  custom type. Start from `alloc::custom`/`alloc::just`/`alloc::ok`/`ctor` uses in
  `elm-kernel-cpp/`, `eco-kernel-cpp/`, `system-kernel-cpp/` and `runtime/`.
- Mark everything else transparent only after reading it. The default is **not** transparent,
  which is safe but excludes more.
- Measure how much of the §1.2 level-1 and level-3 pools the conservative set excludes, by
  re-running the census with exclusions marked. If exclusion removes most of the pool, refine the
  transparent list before building E1 or N1.

## 3. Level 1: erase one-constructor one-field wrappers (group E)

**Goal.** Represent a value of wrapper type `W args = C payload` as the payload itself: an `f64` for
a Float payload, a closure for a function payload, and so on, in SSA, ABI, heap fields and
closures. This is Elm's own `Unbox` optimization, which the JS backend already applies.

**Two stages, because of §2.**

- **E1a, boxed payloads.** Decide per wrapper type constructor W. W is erasable when all of these
  hold:
  - W comes from a `Can.Unbox` union.
  - No reachable instantiation of W has an Int, Float or Char payload, so the payload is
    `!eco.value` in every instantiation.
  - W is not in the KV set.
  - W is not on a type cycle through its own payload (`type T = T (List T)`), including cycles
    through other wrappers. Erasing every member of a cycle would make the type infinite.
    Rule: build the erasure graph on wrapper type constructors and drop every wrapper that can
    reach itself.

  Every view of a W value goes from one boxed word to another boxed word, and no code inspects
  it as a wrapper after the rewrite, so the erased-view mismatches of §2 stay harmless.
  - Covers `Unify`, `Parser`, `StringTable`, `RResult` and `Decoder` (subject to KV), whose
    payloads are functions or records.
  - Does **not** cover `type Quantity number units = Quantity number` at Float: that is E1b.

- **E1b, unboxable payloads.** Here a wrapper becomes `i64`/`f64`/`i32`. It is per instantiation,
  so it needs unit V and an extra exclusion: drop any instantiation that V finds meeting an
  erased view at an interior position.
  - Alternative to weigh in E1b's design: erase these wrappers inside monomorphization, by
    translating the wrapper `MonoType` to its payload when a type is first translated. The mono
    engines then establish layout connectivity themselves (MONO_029, as for any Float) instead
    of a later pass having to prove it. This is the more principled option and the larger change
    (both engines). E1b starts by choosing between the two.

### Units

**E0.** Done when KV0 is done. Add the test fixtures first:
- a Float wrapper inside `List`, a `Dict` value, a record field and a closure capture;
- a wrapper around a function (the `Parser`/`Unify` style);
- a polymorphic wrapper instantiated at an erased type (`MVar CEcoValue`);
- a phantom-type wrapper (`Quantity number units`);
- a recursive wrapper, and two mutually recursive wrappers;
- equality on wrapped values;
- `Debug.toString` of wrapped values, nested and inside containers;
- a wrapper passed through a port;
- a `Bytes.Decode.Decoder` program exercising BytesFusion.

These go in `test/elm/` E2E (with expected output) and in elm-test where a unit check fits.

**E1, the pass `Compiler.MonoOpt.EraseWrappers`.** It runs after `checkLayout` and before `inline`
(`Builder/Generate.elm` `monoPipelineFrom`, around line 940), so inlining, GlobalOpt, CSE and the
backend all see the erased graph.
- Compute the erasable set (admissibility above, with KV) to a fixed point.
- Rewrite every `MonoType` in the graph, replacing an erasable `MCustom` by its rewritten payload
  type: node types, expression types, `MonoPath` types, the registry's keys and reverse mapping,
  and the graph's ctor shapes and layouts. Reuse `MonoTraverse.mapNodeTypes`.
- Rewrite expressions:
  - A saturated call to an erasable constructor's `MonoCtor` becomes its argument.
  - A `MonoCtor` node of an erasable type becomes the identity function. First-class uses like
    `List.map Q` then call the identity, and inlining removes it.
  - A `MonoUnbox` path segment on an erasable type disappears.
  - A `MonoCase` on an erasable type has a single constructor and no tag test. Its destructors
    are paths, so the path rewrite covers it. Assert that no tag test on an erasable type remains.
- Rewriting keys can make two specializations collide in the registry's `mapping : SpecKeyMap
  SpecId` (`IR/Mono.elm:2955`). For example, `(f, Q -> Float)` and `(f, Float -> Float)` become
  one key, and one entry would be silently lost.
  - Policy: on a collision, keep the lower spec id, redirect every `MonoVarGlobal` that names the
    other id to it, and drop the other node.
  - Both nodes compute the same thing on the same representation, so merging is sound. A test
    covers it.
- Behind a config switch `eraseWrappers`, on by default once E3 passes. It joins `Config.hash` the
  way the other aggregate switches do.
- The test pipelines repeat the step order, so add the pass there too:
  `tests/TestLogic/TestPipeline.elm:633,680` and `tests/Compiler/PackageCompilation.elm:630-681`.

**E2, typed printing.** Add `EcoTypeKind::Wrapper`, appended as value 7 because the enum order is
fixed. It carries the constructor name and the payload type id, so `Debug.toString (Q 1.5)` still
prints `Q 1.5`. Places to change:
- the emitter, `GenerateMlir/TypeTable.elm`;
- the MLIR → LLVM type-table lowering, which switches on the kind: add a `case 7` in
  `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp` around line 348;
- the printer;
- the printer's by-name container detection. `RuntimeExports.cpp:3649` recognises
  `Set_elm_builtin` and prints `Set.fromList`. Once Set is erased to its `Dict`, the Wrapper entry
  must route to that arm. Otherwise Set prints as `Dict.fromList`. Until that arm exists, Set is
  on the by-name list (§2.1).

Known limitation: a wrapper reaching the untyped printer through an erased (`Polymorphic`)
position prints as its payload. This affects only `Debug` output; record it in the invariant
text.

**E3, invariants and gates.**
- New invariant MONO_031: after `EraseWrappers`, no reachable `MonoType` contains an `MCustom` of
  an erasable wrapper, and no `MonoUnbox` segment targets one.
- Amend MONO_026 to say its `Unbox` segments are those left after erasure.
- Check MONO_031 and unit V under `ECO_MONO_VALIDATE=1`, and run the E0 fixtures with it on.
- Gates:
  - elm-tests;
  - `cmake --build build --target full`, run once;
  - the bootstrap fixed point (Stage 8c);
  - the E0 fixtures, including `Debug.toString` output unchanged.

**E4, measure.** Re-run the census and Stage 7a wall time and promotion against the same-source
baseline. The level-1 row of §1.2 is the upper bound: 103.4M allocations, 7.4M promotions.
Report E1a and E1b separately: how much of the row each covers, and how much KV and V exclude.

### Risks
- **Staging.** Exposing functions that were wrapped (`Parser`, `Unify`) changes what
  `checkClosureStaging` and LSS see. That is the point, but it is the most likely place for
  failures, so E0's function-wrapper fixtures must run under both mono engines.
- **Kernel visibility is the correctness boundary.** If the KV set misses a type the kernel builds
  or reads by hand, the kernel and compiled code disagree on that type's layout. Hence KV0's
  conservative default.

## 4. Level 2: one constructor, several fields (group S)

The values have to live somewhere, so a value that escapes still allocates. Parameters are already
split by `psplitParams`. Two improvements are open.

**S1, sret for one-constructor customs.** Extend `sretInfoOf` (`Backend.elm:409`) and the sret
machinery to a returned one-constructor custom with 2 or 3 fields, reusing the tuple path:
- the `$sret` worker returns the fields as separate results;
- the caller rebuilds the value only if it escapes.

Candidates in §1.2: `UnifyOk` (20.5M allocations, never promoted, so built in order to be returned
and taken apart). Gate: the census shows the S1-covered allocations gone, and the full gates pass.

**S2, compact heap layout (measure before building).** A `Custom` has an 8-byte word holding the
constructor tag and 48 bits of field kinds, which `Tuple2`/`Tuple3` do not (`Heap.hpp:552-570`,
`:619-624`). A one-constructor type does not need the tag. Storing a 2- or 3-field one with the
`Tuple2`/`Tuple3` layout saves 8 bytes per object: 32 → 24 bytes for 2 fields, 40 → 32 for 3.
- What it changes: construction and projection emit the tuple ops; the type table gets a kind (or
  flag) so the printer still prints the constructor; KV excludes kernel-visible types.
- Equality is unaffected: all views share the layout (§2).
- Expected size: `FieldType` alone accounts for 19.3M promotions over the run, which is about
  147 MiB less copied into the old generation at 8 bytes each. That is copy volume over the run,
  not live heap. The whole 2- and 3-field one-constructor pool is 52.7M allocations and 22.2M
  promotions.
- S2 is decided per type constructor, so an erased view and a concrete view of the same type get
  the same layout (§2). V is still a gate.
- Gate S2-D: build S2 only if the projected saving, promoted objects × 8 bytes, is at least 2% of
  the bytes promoted in a release-preset Stage 7a run with the census, or a heap snapshot shows a
  2% reduction in peak live heap.

**Not covered.** `Array_elm_builtin` (4 fields, 71.2M allocations) is elm/core's own array record.
Neither S1 (3 fields at most) nor S2 (3 fields at most) reaches it. Finding where those
allocations come from is a separate investigation.

## 5. Level 3: several constructors, at most one field each (group N)

### N0: measure what `Just` holds

`Just` is 299.8M allocations, a quarter of all custom allocations in the self-compile. N1 applies
only when the payload type is admissible (below).
- Extend the census to tag each `Just` construction site with whether its payload `MonoType` is
  admissible, and with its KV status.
- Do the same for Maybe-shaped user types.
- Gate N0-D: proceed to N1 only if admissible, non-KV `Just` allocations are at least 5% of all
  custom allocations.

### N1: nullable-pointer representation

Represent `Maybe T` as follows:
- `Nothing` stays the Empty constant (as now).
- `Just x` is `x` itself.
- `case m of Nothing -> ...; Just x -> ...` becomes a test of whether the word is Empty, with
  `x = m` on the `Just` branch.

**Admissible T.** Every test applies to T *after* level-1 erasure. T's runtime word can never be
Empty, and T is boxed:
- *Not admissible:*
  - `Int`, `Float`, `Char` (unboxed);
  - `()`, `{}`, `List`, `String`, `Bytes`, `Maybe` (each can be Empty);
  - every kernel-opaque type (§2: its word is chosen by the kernel);
  - an erased `MVar` (unknown);
  - any T that erases to one of these.
- *Admissible:* records with at least one field, tuples, functions, `Bool` (False/True are not
  Empty), and customs declared in Elm with at least one constructor that has fields. Null-cons
  words are not Empty, so ordinary nullary constructors are fine.

**Maybe-shaped user types** (one nullary constructor N and one constructor with one field):
- N is a null-cons word, not Empty, and null-cons words are not unique per type. So admit T only
  when T, after erasure, has no embedded-constant values at all: records, tuples, functions,
  customs with no nullary constructors.
- Example of why "after erasure" matters: `type W = W Color` passes "no nullary constructors" but
  erases to `Color`'s null-cons words.
- Re-encoding N as Empty when T can never be Empty would admit more types. Decision D2 rejects
  it for N1; it is deferred.

**Consistency.** N1 is decided per instantiation and changes `Maybe T` from a boxed `Custom` to a
different boxed shape. It is therefore in §2's dangerous class:
- An erased `Maybe a` view (a `withDefault` spec that kept `MVar CEcoValue`) receiving a bare
  `Rec` would read it as a `Custom`. Today's `get_tag` returns 0 for a non-Custom heap object, and
  `Just` is tag 0 (`EcoBackend.cpp:2474-2480`), so the error is silent.
- So N1 requires unit V and excludes every `Maybe T` that V finds meeting an erased view, at any
  position, interior or top level.
- KV excludes kernel-visible `Maybe T`: for example `String.toInt` (already inadmissible as
  `Maybe Int`) and kernel functions that build `Just` in C++.
- `Json.Decode.maybe` is Elm code (`oneOf [ map Just d, succeed Nothing ]`), so it is compiled with
  the new representation and needs no exclusion.
- N0 must measure how much of the `Just` pool survives these exclusions before N1 is built.

**Code to change:**
- construction of `Just`, which becomes a coercion to `!eco.value`;
- `case` lowering on `Maybe` (`Patterns.elm`, the constant-tag tests);
- projection of `Just`'s field, which becomes the identity;
- BytesFusion's two `Just` sites;
- the type table: a `Nullable` kind so the printer still prints `Just ...`.

**Invariants.**
- Add a REP_CONSTANT entry stating the nullable representation.
- Add a MONO entry stating admissibility.

**Gates:** as for E3, plus fixtures for the following:
- `Maybe` of each admissible and inadmissible payload, including `Maybe Bool` and `Maybe` of a
  multi-constructor custom. A missed tag test there would silently take the `Just` branch;
- `Maybe Rec` passed to a polymorphic function whose spec keeps `MVar CEcoValue` (must be
  excluded by V);
- nested `Maybe`;
- `Maybe` through a port;
- `Maybe` in a `Dict` value;
- equality `Just a == Just b` and `Nothing == Just x`;
- `Debug.toString`.

### N2: the old option (b), deferred

Represent a multi-constructor one-field union as its bare payload when every constructor's payload
has a distinct runtime tag. Constraints are as written in `plans/sum-type-wrapper-unboxing.md` §2(b).
Candidates in §1.2: `Leaf` 30.1M, `Ok` 20.9M, `SubTree` 20.5M, `Structure` 15.1M, `U8` 13.9M.
`Ok` is part of `Result`, whose `Err`/`Ok` payloads often share a tag, so that one is unlikely to
qualify. Re-measure after N1, and decide then whether to plan N2 in detail.

## 6. Level 4, and the local half of level 3 (group K)

A multi-field multi-constructor value that escapes stays on the heap; nothing in this plan changes
that.
- `RBNode_elm_builtin` (394.5M allocations, 28.7M promoted) dominates this level.
- The lever for escaping values is in-place reuse of a uniquely referenced cell (Perceus or
  Lean-style). That is a separate, larger project and is not planned here.

**K1, case-of-known-constructor.** In `Compiler.MonoOpt.InlineSimplify`, rewrite a `MonoCase` whose
scrutinee is known to be a saturated constructor call. `MonoCase` takes a variable name, not an
expression, so K1 looks through `let x = C a b` (or an enclosing binding the inliner produced) to
find the constructor. The result is the
matching branch, with the destructors bound to the arguments. Inlining creates many such sites, so
run it inside the inline fixpoint. It covers probe case 6 and the same pattern at every level.
- Measure first: count `MonoCase` scrutinees that are known constructor calls after inlining, with
  a static census over the self-compile graph. Building it is cheap, so the gate is only that the
  count is non-trivial (≥ 100 sites).

**K2, multi-constructor values in SSA (optional, after K1).** Today `aggPromote` refuses any value
whose tag is tested.
- What remains after K1: a value built in different branches and matched later
  (`let m = if c then A x else B y in case m of ...`).
- Supporting it needs an SSA tagged-union aggregate: a tag plus the widest field set.
- Decide after K1's census shows how many such sites remain.

## 7. Order and decisions

Order:
1. KV0 (audit plus exclusion measurement), and M0 (below).
2. E0, E1a, E2, E3, E4 for E1a. This is level 1 for boxed payloads, which needs no V.
3. V (representation validator).
4. E1b (level 1 for unboxable payloads, including Martin's `Quantity Float`).
5. N0, then N1 if N0-D passes.
6. K1.
7. S1.
8. S2 only if S2-D passes.
9. N2 and K2: decide after re-measuring.

Each unit lands on its own with the full gates. The census instrumentation is scratch today, and
every gate above needs it. M0 lands it properly:
- The compiler emits a per-site census id under a config switch. The compiler knows the type, so
  no name ambiguity remains.
- The runtime keeps counters under `ENABLE_GC_STATS`.

Decisions (taken 2026-11-19):
- **D1 — land the census:** yes. M0 lands the census in the repo, so every gate is reproducible.
- **D2 — Maybe-shaped user types in N1:** restrict to payloads with no embedded constants.
  Re-encoding N as Empty (the wider rule) is not part of N1; reconsider it only after N1 lands and
  N0's numbers show the excluded user types matter.
- **D3 — `plans/sum-type-wrapper-unboxing.md`:** marked `superseded` by this plan. Its remaining
  work is N2 here.
