# Plan: Remove Redundant Cardinality Computations

## Problem Statement

`Dict.size`, `Set.size` and `List.length` all look O(1) and are not. `elm/core`'s
`Dict.size` is `sizeHelp`, a full red-black tree walk; `Set.size` delegates to it;
`List.length` walks the spine. Code that reaches for one of them to answer a
*yes/no* question — "is it empty?", "did this change?", "do these have the same
shape?" — pays an O(n) traversal for one bit of information.

This plan came out of the `CsePurity` `Set Int` → `BitSet` switch
(`Compiler/GlobalOpt/CsePurity.elm`), where the fixpoint's termination test was
written `Set.size next == Set.size safe`. That comparison was a proxy for "did
this sweep remove anything", and replacing it with a changed flag deleted two
complete tree walks per sweep. A scan of the rest of the compiler for the same
shapes found the sites below.

Scan scope: all `.elm` under `compiler/src`. Occurrences — `Dict.size` 37,
`Set.size` 5, `CoreDict.size` 1, `BitSet.size` 0 external, `List.length` 410.
The `List.length` population was triaged by shape (compared-to-constant,
length-vs-length, repeated-on-the-same-value, inside-a-fold), not audited
exhaustively.

### The governing rule

Per `benchmarks/borrow-inf-opt.md` and the perf-tune loop's lesson — *only
remove allocation, never add fixed overhead to a hot path* — a rewrite here only
counts as a win if it removes allocation or removes traversals. Trading one for
the other does not, and two candidates were rejected on exactly that basis (see
"Rejected" below).

## Tier 1 — `Dict.toList` allocation in MonoType equality

`Compiler/AST/Monomorphized.elm:571` (`eqKeyWith`) and `:890` (`eqLayout`):

```elm
( MRecord _ fieldsA, MRecord _ fieldsB ) ->
    (Dict.size fieldsA == Dict.size fieldsB)
        && eqKeyFields annoSensitive (Dict.toList fieldsA) (Dict.toList fieldsB)
```

**The size guard is redundant for correctness** — `eqKeyFields` (`:605`) and
`eqLayoutFields` (`:914`) both end in `_ -> False`, so they already reject a
length mismatch. But deleting the guard alone is NOT a win: it would trade two
tree walks for two list allocations on the mismatch path.

The real waste beside it is the two `Dict.toList` calls, which allocate a cons
cell per field on **every** comparison. Replace the pairwise list walk with a
`Dict.foldl` + `Dict.get` probe, which allocates nothing — and which makes the
size guard load-bearing rather than redundant, since `A ⊆ B` plus equal
cardinality is what gives set equality.

Both sites are hot: `eqKey` is the equality behind the K4 hash-keyed MonoType
maps, and the comment at `:931` records that bucket collisions are "resolved by
a full `eqLayout` confirm".

`eqKeyFields` and `eqLayoutFields` have no other callers and get deleted.

## Tier 2 — wrong shape: allocates and will not short-circuit

**T2-a `Compiler/MonoSolver/Translate.elm:3576, 3582, 3585, 3588`** — four
instances of

```elm
List.length args1 == List.length args2 && List.all identity (List.map2 sameShapeModuloNumeric args1 args2)
```

Three costs: two length walks, an intermediate `List Bool` allocated at full
length, and `List.map2` evaluating the *recursive* predicate for every pair even
after the first mismatch. A short-circuiting `allPairs` helper subsumes all
three — matching `( [], [] )` / `( x :: xt, y :: yt )` / `_ -> False` handles the
length check for free. The length guards cannot simply be deleted, because
`List.map2` truncates silently; the helper is the fix, not a deletion.

`:3588` is the record arm and is worse — `Dict.keys f1 == Dict.keys f2` allocates
two key lists, then `List.map2` over `Dict.values` allocates two more plus the
`Bool` list. Same `Dict.foldl` + `Dict.get` treatment as Tier 1.

**T2-b `Compiler/GlobalOpt/Borrow/Solve.elm:265`** — `fixAlpha` builds
`Set.union cur bs` unconditionally, then asks `Set.size new == Set.size cur` to
find out whether it grew. A union only ever grows, so that is a subset test
written the expensive way: it allocates a tree on every flow edge of every sweep
and then walks two more. Test `bs ⊆ cur` first with an allocation-free
`Set.foldl`, and build the union only when it actually grows. On a default-off
path (`ECO_BORROW`).

**T2-c `Compiler/Generate/MLIR/Expr.elm:5122, 5149, 5157`** — `Set.size scc`
computed three times on an unchanged set inside one function. Bind once.

## Tier 3 — trivial or cold

| id | site | change |
|----|------|--------|
| T3-a | `Builder/Deps/Diff.elm:454,457` | `Dict.size x > 0` → `not (Dict.isEmpty x)` |
| T3-b | `Compiler/Reporting/Error/Pattern.elm:151` | `List.length args > 0` → `not (List.isEmpty args)` |
| T3-c | `Data/HashMap.elm:169` | `List.length kept == List.length bucket` asks "did the filter drop anything"; probe with `List.any` first and skip the filter allocation entirely on a miss |
| T3-d | `Compiler/Canonicalize/Environment/Local.elm:352` | allocates `Dict.intersect boundVars freeVars` purely to `Dict.size` it, then walks two more dicts; the predicate is "identical key sets" |
| T3-e | `Compiler/Type/Unify.elm:891` | `Dict.size sharedFields == Dict.size matchingFields` detects "did any field fail to unify"; `traverseMaybe` (one caller, `:899`) can report that directly |
| T3-f | `Compiler/Generate/MLIR/Backend.elm:568` | `Dict.size next == Dict.size table` is the changed-flag pattern again; the fold's insert is already guarded by `not (Dict.member sid acc)`, so a threaded flag is exact |

T3-f is correctness-neutral cleanup with **no meaningful gain** — the enclosing
fold is O(nodes) and dominates a walk of the much smaller sret table. It is in
scope for consistency, not for speed.

## Rejected (checked, do not re-scan)

- **`Dict.merge` as the Tier 1 / T2-a mechanism.** It reads well but `elm/core`
  implements it as `foldl` over the right dict seeded with `toList leftDict`,
  allocating a list plus a tuple per step. It is a wash against the code it
  would replace. Use `Dict.foldl` + `Dict.get`.
- **`BitSet.size`** — zero external readers; only internal bounds checks. No
  cardinality misuse anywhere.
- **`Intern.size` / `HashMap.size`** (`MonoSolver/Store.elm:914`,
  `MonoSolver/Engine.elm:1321`, `Monomorphized.elm:669/762/790`) — O(1) stored
  counts, documented at `Engine.elm:1316`.
- **`LocalOpt/{Erased,Typed}/DecisionTree.elm` `List.length tests` ×3** — looked
  like repeated computation, is not: mutually exclusive case branches.
- **`joinAnnotations` (`Monomorphized.elm:1014/1024/…`) and the arity guards in
  `Backend`, `TailRec`, `Expr`** — the length check is load-bearing, because
  `List.map2` truncates.
- **`Type/Unify.elm:759,762`** — `Dict.size members2 <= Dict.size members1` is
  formally implied by the subset test that follows it, but the comment there
  caps those sets at 8 members. Immaterial either way; leave it.
- **`KernelFacts.elm:750/754`, `Deps/Diff.elm:329`, `MapTemplate.elm:1400`** —
  genuine cardinality, computed once.

## Verification

Behaviour-preserving throughout, so the gates are identity gates, not just
green-suite gates.

1. `elm make src/Terminal/Main.elm --output=/dev/null` — type-check.
2. `cmake --build build --target elm-tests` — expect the 12 known TYPE_007
   failures and nothing else.
3. E2E `--target full`, three legs, purging `build/test/*/eco-stuff` between
   them (the harness cache is env-blind): default, `ECO_CSE=1`,
   `ECO_LIST_MAP_TEMPLATE=1`. Expect 1,675 / 1,675 each.
4. Self-compile census, `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1
   ECO_LIST_MAP_TEMPLATE=1 ECO_LIST_REPORT=1`. **This is the sharp gate for
   Tier 1**: `MapTemplate.elm:756` calls `Mono.eqLayout`, so a behaviour change
   in the record arm moves the licence counters. Expect the Run V line
   unchanged — `recognized=592 licensed=297 declinedDebug=0
   declinedOpaqueGlobal=0 … declinedSpecUnresolved=0` and
   `unresolved{blocked=0 global=15 missing=0}`.

Note that byte-identity of `eco-compiler.mlir` is NOT available as a gate: the
compiler's own source is the corpus, so changing it changes the artifact.

## Done when

All three tiers landed, all four gates green, and the census line matches Run V
counter for counter.

## LANDED 2026-08-16 — all three tiers

Twelve sites across ten files. `eqKeyFields`, `eqLayoutFields` and
`traverseMaybe` were deleted (folded into `eqFieldsBy` and `traverseAll`);
`allPairs` and `subsetOf` are new.

| gate | result |
|------|--------|
| 1. type-check | exit 0 |
| 2. elm-tests | 13,104 passed / 12 failed — the same 12 known TYPE_007 failures |
| 3. E2E default / `ECO_CSE=1` / `ECO_LIST_MAP_TEMPLATE=1` | 1,675 / 1,675 each |
| 4. self-compile census | exit 0, licence counters unchanged |

Gate 4 is the one that matters, and it is exact:

```
[map-template] mapTemplate{recognized=592 licensed=297 declinedDebug=0
declinedOpaqueGlobal=0 declinedCalleeLocalLSet=0 declinedCalleeLocalLTop=13
declinedCalleeOther=0 declinedArgTaint=5 declinedWidened=257
declinedUnresolvedMember=15 declinedSpecUnresolved=0 declinedGenericUnboxed=1
declinedEngine=0 declinedChunksOff=0 declinedShape=0 declinedNoStamp=4}
[map-template] argTaint{ltop=2 opaqueGlobal=0 memberPoison=3 closurePoison=0}
[map-template] unresolved{blocked=0 global=15 missing=0}
```

Every counter matches Run V. `MapTemplate.elm:756` calls `Mono.eqLayout`, so
the rewritten record arm is exercised across hundreds of licence decisions and
none of them moved.

`cse-census` reports `specs=32586 safeSpecs=40729`, each exactly 12 below the
pre-change run (`32598` / `40741`). That is the corpus shrinking by the deleted
helpers, not a behaviour change — the compiler's own source IS the workload, and
both counters moving by the same amount is the expected signature.

**Not measured, by construction.** No benchmark accompanies this. Every rewrite
is behaviour-preserving and most of the wins are allocation removed from
predicates, which this protocol cannot resolve below its ~2.8% noise band
(`benchmarks/kernel-opt.md`). T2-b is on a default-off path (`ECO_BORROW`) and
T3-f was known-negligible before it was written. Judge this change on the
identity gate, not on a wall figure.
