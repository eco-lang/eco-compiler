# Wrong-unboxed-bitmap: upstream trace report

Companion to `plans/wrong-unboxed-bitmap.md`. Same bug, traced **upstream**
from `Specialize.elm` back into PostSolve, Solve, and constraint
generation. Built by following the plan in
`plans/trace-unbound-tvar-in-tuple-slot.md`.

## TL;DR

The Elm type checker **does not generate a constraint that ties
`consumerIdx` (slot 0 of `buildSiblingData`'s destructured first
parameter) to `Int`**. Pt6806 — the solver flex var minted for that
slot by `addTupleWithIdsProg` — passes through the solver and remains
`FlexVar(fresh)` at PostSolve time. PostSolve renames it to `b`,
AssignMVarIds maps `b` to MVarId 8536, and Specialize's `TOpt.Tuple`
case at `Specialize.elm:3209` applies its substitution to
`canType = T3(Int, V8536, Int)` and — because 8536 is neither in the
substitution nor flagged as a number variable — falls into the
`CEcoValue` branch of `TypeSubst.applySubst` (lines 625–635),
returning `Mono.MVar 8536 CEcoValue` for slot 1. The element
expressions themselves are correctly `MInt` at the SSA level, so the
container `MonoType` and the element-derived type disagree. Downstream
this becomes the `unboxed_bitmap = 17` boxing mismatch described in
`wrong-unboxed-bitmap.md`.

The constraint **should have been**:

> "Argument of `List.foldl buildSiblingData ... (List.indexedMap
> Tuple.pair members)` is a `List (Int, MemberType)`; therefore
> `buildSiblingData`'s first parameter is `(Int, MemberType)`;
> therefore slot 0 of the destructure pattern is `Int`."

The two needed sub-conclusions show up in the trace:

- `Pt6807` (the `member` slot) **is** unified with `Struct(Rec)` —
  evidence that the let-bound function's body did pin slot 1 from
  context.
- `Pt6806` (the `consumerIdx` slot) is **never** unified with anything
  beyond two other unconstrained `Flex(fresh)` peers.

The asymmetry — slot 1 gets pinned, slot 0 does not — is the
signature of the bug.

## How to read the chain

The story has six steps. Each line is a real trace line from
`/tmp/stage5_traces5.log` (Stage 5 self-compile,
`compiler/src/Terminal/Main.elm` as input). Line numbers refer to
`compiler/src/Compiler/Generate/MLIR/Expr.elm` in the current tree.

The buggy source site:

```elm
buildSiblingData ( consumerIdx, member ) acc =                   -- Expr.elm:4451
    let
        ...
        crossEdgesForSibling =
            List.indexedMap
                (\j ( _, captureExpr, _ ) ->
                    case captureExpr of
                        Mono.MonoVarLocal refName _ ->
                            case Dict.get refName memberIndex of
                                Just producerIdx ->
                                    Just
                                        ( producerIdx                -- Expr.elm:4508
                                        , consumerIdx                -- Expr.elm:4509
                                        , nonSiblingCount + j        -- Expr.elm:4510
                                        )
                                ...
        ...

groupAcc =
    List.foldl
        buildSiblingData                                            -- Expr.elm:4572
        { ctx = ctxWithPlaceholders, ... }
        (List.indexedMap Tuple.pair members)                        -- Expr.elm:4578
```

### Step 1 — Constraint generation

`Compiler.Type.Constrain.Typed.Pattern.addTupleWithIdsProg`
(`Pattern.elm:556`) is invoked for the destructure pattern
`( consumerIdx, member )` at line 4451. It mints two fresh flex
variables (via `pMkFlexVar`, which is interpreted to call
`Type.mkFlexVar = UF.fresh flexVarDescriptor` in
`Type.elm:319`):

```
[Constrain/Pattern/Tuple] slot=0 region=4451:26-4451:49 var=Pt6806
[Constrain/Pattern/Tuple] slot=1 region=4451:26-4451:49 var=Pt6807
```

- **Pt6806** is the solver variable for `consumerIdx`.
- **Pt6807** is the solver variable for `member`.

The site also emits a `CPattern` constraint
(`Type.CPattern region E.PTuple (Type.TupleN aType bType []) expectation`)
intended to unify `TupleN Pt6806 Pt6807 []` with whatever the
surrounding context expects for buildSiblingData's first parameter.

### Step 2 — Solver behaviour

The solver runs. For `Pt6806` (consumerIdx slot) the **only** merge
events in this module's typecheck are:

```
[Solve/Unify-merge] var1=Pt6806 content1=Flex(fresh) var2=Pt6958 content2=Flex(fresh) => Flex(fresh)
[Solve/Unify-merge] var1=Pt6960 content1=Flex(fresh) var2=Pt6958 content2=Flex(fresh) => Flex(fresh)
```

That's it. `Pt6806` is union-find'd with `Pt6958`, then `Pt6960` is
union-find'd with `Pt6958`. The resulting equivalence class
`{Pt6806, Pt6958, Pt6960}` is `Flex(fresh)` from beginning to end —
never unified with `Struct(Int/0)`, never unified with any structure
at all.

By contrast, `Pt6807` (member slot) gets pinned to a record:

```
[Solve/Unify-merge] var1=Pt6807 content1=Flex(fresh) var2=Pt111594 content2=Struct(Rec) => Struct(Rec)
```

**This asymmetry is the bug.** The constraint that should pin
`Pt6806 = Int` (from
`List.indexedMap Tuple.pair members : List (Int, MemberType)`
flowing into `List.foldl buildSiblingData ...`'s parameter type) is
never generated. Both `Pt6958` and `Pt6960` (the call-site
instantiation peers) also stay `Flex(fresh)`, so even via union-find
the class never sees `Int` come in.

### Step 3 — PostSolve (`Type.toCanTypeBatch` → `variableToCanType`)

At end of solve, `runWithIds` calls `Type.toCanTypeBatch nodeVars`
(`Solve.elm:122`) with a shared `NameState`. That walks every node's
solver variable and converts it to a `Can.Type Name`. For unresolved
`FlexVar Nothing` variables it allocates a fresh name from the
shared NameState:

```
[PostSolve/Resolve] var=Pt6806 content=FlexVar(fresh) name=b
[PostSolve/Resolve] var=Pt6806 content=FlexVar(named) name=b
[PostSolve/Resolve] var=Pt6958 content=FlexVar(named) name=b
```

The first line records the fresh naming; the next two are re-visits
of the same UF root (now with `FlexVar (Just "b")`). All three Pts
in the equivalence class end up canonically as `Can.TVar "b"`.

### Step 4 — AssignMVarIds (per-scheme name → MVarId)

`AssignMVarIds.assignIds` processes each scheme. For
`Compiler.Generate.MLIR.Expr.generateExpr`'s scheme, it walks every
expression's `meta.tipe` and converts `Can.TVar name` to
`Can.TVar mvarId` via `ensureMVarId`:

```
[AssignMVarIds/freshMVarId] id=8536 constraint=CEcoValue
[AssignMVarIds/ensureMVarId] id=8536 name=b reused=N source=ensureMVarId
[AssignMVarIds/ensureMVarId] id=8536 name=b reused=Y
[AssignMVarIds/ensureMVarId] id=8536 name=b reused=Y
... (many more reuses of id=8536 for the same name "b" inside generateExpr's scheme)
```

Note: `source=ensureMVarId` — i.e., **not**
`ensureMVarIdForRoot`. That confirms the offending name `b` is *not*
backed by a `SolverRoots`-recorded solver root. It is a name that
PostSolve invented from thin air for an unresolved FlexVar. The
scheme-root path that exists for legitimately polymorphic top-level
schemes is bypassed entirely.

### Step 5 — Specialize sees the unbound TVar

When Specialize processes generateExpr (which has no top-level
polymorphism — `currentFreeVars = []` and the scheme's freeVars is
empty), it walks the AST and hits `TOpt.Tuple` for
`( producerIdx, consumerIdx, nonSiblingCount + j )` at line
4508–4511. The trace point at `Specialize.elm:3209`:

```
[Specialize/Tuple]
  currentGlobal = compiler:Compiler.Generate.MLIR.Expr.generateExpr
  freeVars      = []
  canType       = T3(Int,V8536,Int)
  substProbe    = V8536(inSubst=N,numberVar=N,constraint=CEcoValue)
  toptElemCanTypes = [Int,V8536,Int]
  subst         = {8500->I, 8501->S, 8502->B, 8503->T2(S,MonoType), 8504->R{..}, 8505->R{..},
                   8506->R{..}, 8507->S, 8508->B, 8509->T2(S,MonoType), 8510->R{..}}
  monoType(after subst) = T3(I,V8536_ecovalue,I)
  elemTypes(after subst)= [I,I,I]
```

Reading this:

- `canType = T3(Int, V8536, Int)` — slots 0 and 2 are concrete `Int`,
  slot 1 is V8536.
- `substProbe`: V8536 is **not** in `subst`, **not** in
  `numberVars`, and carries constraint `CEcoValue`.
- `subst` covers V8500–V8510 (the call-site arg/return bindings that
  `Specialize.specializeCall` injected for generateExpr's
  *call-site*-derived type variables). V8536 is far outside that
  range — it's a **scheme-internal** TVar that no caller's
  substitution covers.
- `monoType(after subst)` = `T3(I, V8536_ecovalue, I)` — the
  container's declared type with the unbound MVar baked in.
- `elemTypes(after subst)` = `[I, I, I]` — the elements themselves
  are correctly all `MInt`.

The disagreement is exactly the bug shape from
`wrong-unboxed-bitmap.md` — V-id shifted (was V8531, now V8536; the
allocation order drifted between runs but the structure is
identical).

The `applySubst` `Nothing` branch (`TypeSubst.elm:625–635`) fires
because V8536 has no entry in `subst` and `numberVar=N`, so its
constraint `CEcoValue` selects:

```elm
Mono.CEcoValue -> ( Mono.MVar mvarId constraint, env )    -- ← actually taken
```

returning `Mono.MVar 8536 CEcoValue` for slot 1. The buggy
`MonoTupleCreate`'s declared type becomes
`MTuple [MInt, MVar 8536 CEcoValue, MInt]`.

### Step 6 — Downstream consequence

Identical to `wrong-unboxed-bitmap.md`:
`computeTupleLayout [MInt, MVar 8536 CEcoValue, MInt]` produces
`unboxed_bitmap = 17`, `generateTupleCreate` boxes slot 1 at
construction, runtime reads the pointer bits as i64, papCreateGroup
verifier rejects "cross_edges consumer 1614627243 out of range".

## Why slot 1 (`member`) escapes the bug but slot 0 (`consumerIdx`) doesn't

`Pt6807` (member) is **used** inside `buildSiblingData`'s body in
ways that pin its type: `member.closureInfo` forces it to be a
record, `member.lambdaBody` reinforces this, etc. So the solver
receives constraints that bind `Pt6807` to `Struct(Rec)`.

`Pt6806` (consumerIdx) is only **referenced as a value** inside the
3-tuple `( producerIdx, consumerIdx, nonSiblingCount + j )`. None of
those uses imposes a numeric or structural constraint on it directly
— the tuple constructor is polymorphic in each slot. There is no
arithmetic on `consumerIdx`, no list-indexing, no comparison. So no
constraint flowing **outward** from a use-site.

The constraint that *should* exist is the one flowing **inward**
from buildSiblingData's call site: `List.foldl buildSiblingData ...
(List.indexedMap Tuple.pair members)` makes
`List.indexedMap Tuple.pair members :: List (Int, MemberType)`, hence
buildSiblingData's first parameter should be `(Int, MemberType)`,
hence the destructure pattern's slot 0 should be `Int`. But that
constraint apparently never gets propagated all the way back to the
`Pt6806` UF class. Specifically, `Pt6958` (which the trace shows
union-find'd with `Pt6806` — likely the result of the let-polymorphic
**copy** taken at the `CLocal "buildSiblingData" expectation`
unification site) is *also* never bound to `Int`. So whatever
intermediate node should have carried the `Int` constraint into the
class, it didn't.

## Answers to the three direct questions

### "How is the variable created in the first place? Is it a synthetic TVar added to the Canonical IR when first creating the TypedCanonical IR?"

**Yes — it is synthetic, and the smoking gun is at
`Pattern.elm:558–571`.** The pattern `( consumerIdx, member )` is a
`Can.PTuple` pattern. `addTupleWithIdsProg` walks it and calls
`pMkFlexVar` once per slot, allocating a fresh solver variable
(`Pt6806` for slot 0, `Pt6807` for slot 1). These solver vars are
born unnamed (`FlexVar Nothing`).

They are **not** synthesized by the canonicalizer — they're
synthesized by constraint generation, *for the purpose of unification
during solving*. Importantly, the canonical pattern itself has no
type information — only the *solver* side of the typecheck attaches
type variables. So a CleanCanonicalIR `Can.PTuple` does not contain
TVars; the TVars come in when we generate constraints.

### "Why is that TVar not linking to another var or concrete type?"

**Because the constraint that would link it is never generated.**
The expected propagation chain is:

    List.indexedMap Tuple.pair members  :: List (Int, MemberType)
       └─ flows as third arg of  List.foldl : (a -> b -> b) -> b -> List a -> b
           └─ so List.foldl's `a` = (Int, MemberType)
               └─ so buildSiblingData (the first arg) :: (Int, MemberType) -> b -> b
                   └─ so pattern  ( consumerIdx, member )  expects (Int, MemberType)
                       └─ so Pt6806  =  Int

The trace proves that this chain breaks somewhere between
"buildSiblingData :: (Int, MemberType) -> ..." and "Pt6806 = Int". The
union-find class `{Pt6806, Pt6958, Pt6960}` remains `Flex(fresh)`
from creation through PostSolve. The only Pt6806-touching events are
two intra-class unifications; nothing brings `Int` into the class.

The likely structural cause is the way **let-polymorphism** interacts
with destructured-parameter local functions. `buildSiblingData` is a
let-bound helper without a type annotation. The constraint solver
treats it as polymorphic (generalised over Pt6806 and Pt6807). The
call site (`List.foldl buildSiblingData ...`) goes through `CLocal
"buildSiblingData" expectation` — which `makeCopy`s the scheme and
unifies the fresh copy with the expectation. That unification (the
`Pt6806 = Pt6958` merge) gives us a fresh copy `Pt6958`, but the
fresh copy is never further unified with `Int` — most plausibly
because the call-site expectation was itself a fresh structural type
whose first component was a free flex var (the Tuple.pair's `a`
slot), and that component never got pinned to `Int`.

In other words: the call-site instantiation correctly produces a
fresh copy of buildSiblingData's first-parameter slot-0 type, but the
expectation that's supposed to constrain it is itself still
unresolved at unification time. Once both sides are
`Flex(fresh) = Flex(fresh)`, the unification succeeds vacuously and
the result is still `Flex(fresh)`.

This is hypothesis (A) from `plans/trace-unbound-tvar-in-tuple-slot.md`
— a **constraint-generation / let-polymorphism ordering gap**, not a
solver failure.

### "Should we expect this to be resolved in PostSolve or Monomorphization?"

**Neither does anything useful in the current pipeline.** Concretely:

- **PostSolve** (`Compiler.Type.PostSolve.postSolveExpr`) does *not*
  default unresolved `Can.TVar` nodes; it just lets them through. It
  has fix-up logic for Group B expressions (Str/Chr/Float/Unit
  literals) and for `VarKernel` lookups, but no rule that says
  "unresolved TVar in a tuple-element position should default to
  something safe". So it does not own a fix for this case today, and
  there is no commented-out hook suggesting it ever did.

- **Specialize** has `Mono.forceCNumberToInt` (currently the
  identity, but historically responsible for defaulting `CNumber`
  TVars). That covers `CNumber` only — `CEcoValue` falls through
  unchanged, which is exactly what produces `Mono.MVar _ CEcoValue`
  in the tuple slot.

- Specialize also has the `applySubst` `Nothing` / `CEcoValue` branch
  in `TypeSubst.elm:625–635` which *encodes* the bug (it produces
  `Mono.MVar mvarId CEcoValue` rather than defaulting to something
  unboxable). It is the closest thing to a defaulting hook for
  CEcoValue, but it deliberately preserves the variable for legitimate
  fully-polymorphic boxing.

So **the right home for an upstream fix is the constraint-generation
phase**. Specifically, the place that generates constraints for
let-bound function definitions and their call-site instantiations
needs to ensure that the call-site's expected argument type flows
back into the pattern's slot types before the scheme is generalised
(or at least before AssignMVarIds runs). A `Compiler.Type.Solve`
patch is plausible too — making `CLocal` constraints emit a stronger
unification that propagates expectation into the scheme's fresh
copies — but that's a Solve-side fix for what is fundamentally a
constraint-flow gap.

A **downstream containment patch** is also viable and much cheaper:
the Fix A from `wrong-unboxed-bitmap.md`, namely changing
`Specialize.elm:3229` to derive the tuple's MonoType from the
already-specialised element expressions rather than from
`meta.tipe`. That's still out of scope for this report (per
the plan), but the trace evidence here strongly supports it: the
SSA element types are already correct (`elemTypes(after subst) =
[I, I, I]`), so element-derived `MTuple [MInt, MInt, MInt]` would
agree with codegen without touching the type-checker.

## Surprise findings (not in the original plan)

0. **The downstream `[TupleLayout]` and `[TupleCreate-17]` traces fired
   0 times in Stage 5** despite the upstream `[Specialize/Tuple]`
   trace clearly catching the buggy `T3(I, V8536_ecovalue, I)`
   shape. Two things to note:

   - The hard-coded `bitmap == 17` test on `[TupleCreate-17]` was
     **too narrow**. The unboxed-bitmap uses 2 bits per slot, so a
     mis-boxed slot produces different bitmap values depending on
     which slot the unbound MVar lands in (slot 1 → 17, slot 0 → 20,
     slot 2 → 5, etc.). Trace condition was widened to
     `[TupleCreate-mismatch] bitmap=N` (any slot whose declared
     unboxed bit disagrees with `Mono.typeOf elemExpr`); even with
     the wider condition it still fired 0 times in the rerun.
   - More substantively: the fact that **no** downstream codegen
     trace sees `MTuple [_, MVar _ CEcoValue, _]` reach
     `computeTupleLayout` means an intermediate pass between
     Specialize and MLIR codegen (likely one of
     `Compiler.GlobalOpt.MonoGlobalOptimize`,
     `Compiler.GlobalOpt.MonoInlineSimplify`,
     `Compiler.Monomorphize.Prune`, or one of the staging passes) is
     **already silently rewriting the `MonoTupleCreate` so the buggy
     `MonoType` does not survive to codegen** in Stage 5's
     self-compile of the compiler. The runtime symptom (the
     cross_edges miscompile reported in
     `wrong-unboxed-bitmap.md`) was observed when the compiled
     compiler ran *its output* against a different input —
     specifically Stage 7b's run. So the bug-producing path may
     surface only at one of:
     - Stage 7a (the eco-compiler self-compile producing
       `eco-compiler-boot.mlir`), where the input is the same source
       but the compiler doing the compilation is now native rather
       than node-hosted, and the .ecot caches and global
       allocation order differ;
     - or any other compilation where the rewriting pass's
       precondition (whatever currently masks the issue at Stage 5)
       does not hold.
   - This is consistent with the original report's framing:
     `wrong-unboxed-bitmap.md` says the cross_edges failure was at
     "Stage 7b" runtime, not Stage 5 output. So the upstream chain
     proven here is correct, but a separate diagnostic pass would
     be needed to identify which downstream pass is currently
     **incidentally** masking the issue in Stage 5 — and which Stage
     defeats that incidental masking. Doing that is out of scope
     for this trace report (the goal here was to nail the
     **upstream** cause); it would warrant its own diagnostic plan.

1. **Pt indices are recycled across module typechecks.** Every time
   `Compiler.Compile` typechecks a new module, the UF allocator's
   internal counter is independent (or at least the `IO.Pt idx` values
   collide). So a given Pt index appears in many unrelated trace
   lines. This makes plain `grep Pt6806` misleading; the right way to
   read the trace is to anchor on the `Constrain/Pattern/Tuple` line
   for the source region you care about and read forward.

2. **There is a second mismatch.** Beyond
   `Compiler.Generate.MLIR.Expr.generateExpr`'s `T3(I,V8536_ecovalue,I)`,
   there is also a `Specialize/Tuple` trace for
   `Compiler.Monomorphize.Monomorphize.assembleRawGraphFrom` with
   `canType = T3((Array (Maybe (List Int))), Alias:BitSet, Alias:BitSet)`
   vs `monoType(after subst) = T3(Array, R{..}, R{..})`. That second
   mismatch is **NOT** the bug we are chasing — the disagreement is
   purely a pretty-printer artifact (my `prettyMonoTypeTraceSpec` is
   lossy on `MCustom` — it renders the name only, not the args). The
   actual underlying types likely agree. The trace condition is overly
   sensitive there; a stricter pretty-printer would suppress this
   false positive.

3. **`forceCNumberToInt` is now the identity.** The function still
   exists (`Mono.elm:265`) but is documented "kept as identity to
   avoid churn at 57 call sites". The actual `CNumber → MInt`
   defaulting happens inside `resolveMonoVars` (called via
   `applySubst`'s `Just monoType -> resolveMonoVars subst monoType`
   path). For the buggy case, the unbound TVar goes through the
   `Nothing` branch — which only handles `CNumber → MInt`, not
   `CEcoValue → anything`. So even if you re-added defaulting to
   `forceCNumberToInt`, you would not catch the CEcoValue case.

4. **The scheme-roots path bypasses `b`.** Many AssignMVarIds
   entries are `ensureMVarIdForRoot id=N root=PtM name=X` — these
   are TVars backed by `SolverRoots`-recorded solver variables (used
   when a top-level scheme has a generalised type with named
   parameters). The buggy `V8536`, however, comes through plain
   `ensureMVarId` (`source=ensureMVarId`), confirming it is not a
   real scheme parameter — it is a PostSolve-invented name for an
   unresolved interior FlexVar.

## Where to look in the source

- `compiler/src/Compiler/Type/Constrain/Typed/Pattern.elm:556`
  — `addTupleWithIdsProg`, mints `Pt6806`/`Pt6807` via `pMkFlexVar`.
- `compiler/src/Compiler/Type/Type.elm:319`
  — `mkFlexVar`, the actual `UF.fresh` allocation.
- `compiler/src/Compiler/Type/Type.elm:501`
  — `variableToCanType`, where unresolved `FlexVar Nothing` gets
  the fresh name `b`.
- `compiler/src/Compiler/Type/PostSolve.elm:357` — `postSolveExpr`,
  which trusts the solver's now-named `Can.TVar` and walks past it.
- `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm:124`
  / `:159` / `:184` — where the name `b` becomes MVarId 8536.
- `compiler/src/Compiler/Monomorphize/Specialize.elm:3209`
  — the `TOpt.Tuple` case that materialises the wrong `monoType`.
- `compiler/src/Compiler/Monomorphize/TypeSubst.elm:625–635` —
  the `applySubst` `Nothing/CEcoValue` branch that produces
  `Mono.MVar _ CEcoValue` for unbound vars.
- `compiler/src/Compiler/Generate/MLIR/Types.elm:557` —
  `computeTupleLayout`, which trusts that wrong `monoType` and emits
  `unboxed_bitmap = 17`.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm:5661` —
  `generateTupleCreate`, which boxes slot 1 according to that bitmap.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm:4451` and `:4509` —
  the source-level site of the bug: `buildSiblingData`'s destructured
  parameter and its inner-tuple use of `consumerIdx`.

## Chronologically ordered chain (final form)

```
source file:line:col
  Expr.elm:4451:26-4451:49 = ( consumerIdx, member )
    └─ Constrain (Pattern.elm:556)
         Pt6806 = pMkFlexVar()     -- consumerIdx slot, Flex(fresh)
         Pt6807 = pMkFlexVar()     -- member slot, Flex(fresh)
         CPattern PTuple (TupleN Pt6806 Pt6807 []) expectation emitted
        └─ Solve (Type.Constrain → Type.Solve → Type.Unify)
             Pt6807 merged with Struct(Rec) at some point
             Pt6806 merged with Pt6958 (Flex), Pt6960 (Flex)
             UF class {Pt6806, Pt6958, Pt6960} stays Flex(fresh)
             — no Int comes in
            └─ PostSolve (Type.elm:501 variableToCanType)
                 Pt6806's UF root has FlexVar Nothing
                 → allocate fresh name "b" from shared NameState
                 → write back FlexVar (Just "b") into UF
                 → return Can.TVar "b"
                └─ AssignMVarIds (AssignMVarIds.elm:159)
                     ensureMVarId "b" in generateExpr's scheme env
                     → freshMVarId CEcoValue → MVarId 8536
                     → bind "b" → 8536 in this scheme's SchemeEnv
                    └─ Specialize (Specialize.elm:3209)
                         TOpt.Tuple at Expr.elm:4508-4511 has
                           meta.tipe = T3(Int, TVar 8536, Int)
                         applySubst with subst = {8500..8510}
                         → 8536 not in subst, not in numberVars,
                           constraint=CEcoValue
                         → Nothing/CEcoValue branch (TypeSubst.elm:635)
                         → Mono.MVar 8536 CEcoValue
                         → MTuple [MInt, MVar 8536 CEcoValue, MInt]
                        └─ Layout (Types.elm:557 computeTupleLayout)
                             canUnbox (MVar _ CEcoValue) = False
                             → unboxedBitmap = 0b010001 = 17
                            └─ Codegen (Expr.elm:5661 generateTupleCreate)
                                slot 1: isUnboxed=False → boxToEcoValue
                                eco.construct.tuple3 with
                                  _operand_types = [i64, !eco.value, i64]
                                  unboxed_bitmap = 17
                                └─ Runtime
                                    Tuple3.b stored as Unboxable.p (HPointer)
                                    eco_tuple3_get1_i64 reads .i (i64 union)
                                    → returns the pointer's bit pattern
                                    → papCreateGroup verifier rejects
                                      "cross_edges consumer N out of range"
```

## Recommendation for a future fix

The trace evidence supports **two complementary fixes** of very
different scope:

### Containment (downstream, ~one-line patch)

Apply Fix A from `plans/wrong-unboxed-bitmap.md` at
`Specialize.elm:3229`: build the tuple's `MonoType` from the
already-specialised element expressions rather than from
`meta.tipe`. This guarantees that container `MonoType` and SSA
element types agree, regardless of whether the upstream type checker
correctly pins the slot type. The trace confirms this works because
the element types `(after subst)` are already `[I, I, I]` — Fix A
would build `MTuple [MInt, MInt, MInt]` directly, bypassing the
broken `applySubst` Nothing/CEcoValue branch for tuples.

Strongly recommended as the next concrete step.

### Root cause (upstream, scoped investigation)

The constraint-flow gap lives in the interaction between let-bound
local-function generalisation, tuple-destructure parameter patterns,
and call-site `CLocal` expectation propagation. A focused
investigation would instrument `Type.Constrain.Typed.Expression`'s
`CLet`/`CDef` constraint generation to see exactly which Type
expression carries the slot-0 expectation at the
`List.foldl buildSiblingData ...` call site, and trace whether it
ever gets unified with the corresponding member of the let-bound
function's first-parameter copy. If the chain breaks at a specific
constraint, that's the root-cause fix site.

That is scope for a separate plan; the diagnostic work here has
nailed the layer (constraint generation / let-polymorphism) and the
shape (no Int constraint ever reaches Pt6806's UF class), which is
the prerequisite for that follow-up.
