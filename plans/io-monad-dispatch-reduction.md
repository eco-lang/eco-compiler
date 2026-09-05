# Cutting the IO monad's dispatch: state-passing where there is no state

**Status: P0 + P1 DONE 2026-09-05 — dispatch −35.1 %, allocation −15.5 %
(−1.64 e9 objects, −63 GB), wall −11.5 %, all gates green including the JS
self-compile. **P2 was already delivered by P1; P3 done 2026-09-05.**
Cumulative: dispatch **−43.1 %**, allocation **−18.5 %** (−1.96 e9 objects,
−75 GB), wall **−13.2 %**. P4–P7 open; see §9 and §10.**

Successor to the caller-side dispatch census recorded in memory
(`dispatch-source-census-io-monad`). Target: `System.TypeCheck.IO` and its hot
callers, chiefly `Compiler/Type/UnionFind.elm`.

**Note on §1–§8:** written BEFORE the work; they are the plan as proposed. §9
records what actually happened, including where the plan was wrong (P1's premise
that `get`/`equivalent` are pure queries — they are not; see §9.1).

---

## 1. The finding

A caller-side census of a solver+LSS self-compile (`eco-new` compiling
`/work/compiler/src`, 9:00.79 wall, `sat=2,585,353,796` generic dispatches;
98.9 % of dispatches attributed):

| source subsystem | dispatches | % | est. wall |
|---|---:|---:|---:|
| **System.TypeCheck.IO monad** | **1,414,130,404** | **55.3 %** | **67.4 s** |
| Dict/Set folds + maps | 376,022,103 | 14.7 % | 17.9 s |
| other compiled Elm | 354,053,899 | 13.8 % | 16.9 s |
| kernel C++ / runtime | 106,202,007 | 4.2 % | 5.1 s |
| monomorphizer / solver | 96,998,754 | 3.8 % | 4.6 s |
| unresolved return address | 92,670,678 | 3.6 % | 4.4 s |
| typechecker (non-IO) | 87,650,532 | 3.4 % | 4.2 s |
| Bytes encode/decode | 29,378,911 | 1.1 % | 1.4 s |

By combinator: **`andThen` 1,107,232,296 (43.3 %)**, `map` 270,569,386 (10.6 %),
everything else < 1 %. Spread over 425 specializations, but two of them
(`andThen_$_18949` 213 M, `_$_18964` 180 M) are **15.3 % of all dispatch in the
compiler**. Wall model: dispatch machinery = 22.55 % of wall (121.9 s of 540.8 s)
=> **47.7 ns per dispatch**.

The hot specializations are called from `Compiler_Type_UnionFind_{get, fresh,
repr, equivalent, union}`.

## 2. The mechanism — a monad around an array index

```elm
-- Compiler/Type/UnionFind.elm
get ((IO.Pt ref) as point) =
    IORef.readPointCell ref |> IO.andThen (\cell -> case cell of
        IO.Root _ desc -> IO.pure desc
        IO.Chain (IO.Pt ref1) -> IORef.readPointCell ref1 |> IO.andThen (\cell1 -> …))

-- Data/IORef.elm — NOTE: `s` is returned UNCHANGED
readPointCell ref =
    \s -> case Array.get ref s.ioRefsPoint of
            Just cell -> ( s, cell )

-- System/TypeCheck/IO.elm
type alias IO a = State -> ( State, a )
andThen f ma = \s0 -> let ( s1, a ) = ma s0 in f a s1     -- returns a CLOSURE
map fn ma s0 = let ( s1, a ) = ma s0 in ( s1, fn a )      -- already eta-expanded
pure x = \s -> ( s, x )
```

Reading one array element costs: the `\s ->` action, the `andThen` closure, the
`\cell ->` continuation, a `( s, cell )` tuple, an `IO.pure` closure — and two
indirect calls. That is where the 1.1 e9 dispatches come from.

Writes are worse: `writePointCell` is
`\s -> ( { s | ioRefsPoint = Array.set ref cell s.ioRefsPoint }, () )` — a 4-field
State record copy **and** a persistent-array update per write.

### 2.1 Two things already settled — do not redo them

- **The trampoline is GONE.** `IO.elm:90`: "`type Step`/`loop` (the trampoline)
  REMOVED — all `IO.loop` call sites were [converted to] direct
  self-tail-recursion which TCO's to while-loops (still stack-safe) while
  dropping the per-iteration `Step`/loop-state-tuple/closure allocations."
  `foldrM`, `foldM`, `traverseList`, `mapM_`, `forM_` are plain tail recursion.
  **Stack safety is not what costs us; the per-step `andThen` plumbing is.**
- **Direct state-passing is already an in-tree, proven pattern**, it just stopped
  short of the union-find core: `Store.freshVarS`, `structS`, `monoTypeToVarC`,
  `monoListToVarC`, `recordFieldPointsC`, `mintVarSlots`, `qSigClasses`,
  `qSigGo`, `qEagerAt`, `qEagerGo`, plus `Solve.solveGo`,
  `Expression.letSpineGo`, `Pattern.consSpineGo`, `Module.constrainDeclsGo`.

### 2.2 Scale of the surface

Static uses: `andThen` 279, `pure` 147, `map` 125, `apply` 33, `traverseList` 26,
`foldM` 15, `foldrM` 8, `mapM_`/`forM_` 5 each, `traverseMapWithKey` 4. Only
**15 modules** use the combinators (the 86 that import the module mostly want the
`State`/`Point` types): `Type/Solve` 180, `Type/Constrain/Typed/Expression` 160,
`Type/Type` 86, `Constrain/Typed/Pattern` 35, `Constrain/Typed/Module` 32,
`Type/UnionFind` 27, `Type/Unify` 23, `Type/Occurs` 15, `Type/Instantiate` 15,
then single digits. `UnionFind.elm` is **238 lines**.

## 3. Constraints

**C1 — JS stack safety is still a hard requirement.** The original overflow was
`Maximum call stack size exceeded` in `eco-boot-2.js`
(`plans/typecheck-io-stack-safety.md`): the *JavaScript* bootstrap, which Stages 2
and 5 still run. The native binary has TCO and a real stack, so "it works
natively" is NOT evidence a change is safe. Every phase below must be validated
through the JS path (`--target eco-boot` + a JS self-compile), not only
`--target full`.

**C2 — NO compiler special-casing of the compiler's own internals.** (User
directive, 2026-09-05.) Editing `UnionFind.elm`/`IO.elm` is just writing better
Elm and is fine. But a compiler PASS must never recognise
`System.TypeCheck.IO.andThen` by name, or any other eco-internal symbol. Eco is a
general-purpose Elm compiler; effort spent teaching it about its own libraries is
wasted and does nothing for user code. Any rewrite in §6 must be expressible as a
**general code shape** that fires on any `andThen`/`map`-like function over any
type — and, ideally, on non-monadic code too. If a proposed optimisation cannot
be stated without naming a module, it is out of scope.

**C3 — the artifact must not move except where intended.** These are internal
refactors; the emitted `.mlir` for a fixed corpus should stay byte-identical
except where a change legitimately alters lambda numbering, in which case the
bootstrap fixed point is the gate.

## 4. Phases (source side — the compiler's own Elm)

### P0. Probe: eta-expand `andThen` (1 line)

`andThen f ma = \s0 -> …` allocates a closure per node; `map fn ma s0 = …` does
not, and `map` costs 4× less per use. Write `andThen f ma s0 = let ( s1, a ) = ma
s0 in f a s1`.

**Honest caveat:** `x |> IO.andThen f` is a partial application, so an arity-3
`andThen` may just move the allocation into a PAP. Whether mono/LSS saturates it
is exactly what this probe measures. Cheap to try, cheap to revert; it also
calibrates the measurement loop before the real work.

### P1. Queries stop being IO — the main event

`readPointCell` returns `s` unchanged. So `get`, the read half of `repr`,
`equivalent`, and descriptor inspection are **queries, not state transformers**.
Give them `State -> a` (or plain extra-parameter) signatures:

```elm
get : State -> Point -> Descriptor      -- no tuple, no threading, no andThen
```

Zero closures, zero dispatch, zero tuple for what is an array index. Scope: the
read primitives in `UnionFind.elm` + `Data/IORef.readPointCell`, and their direct
callers in `Unify`, `Occurs`, `Type`, `Solve`.

### P2. Fast-path the primitives

`get`'s common case is `Root` on the first cell — a direct array read that
returns immediately; only `Chain` falls back to the general path. Same for `set`.
Today even the fast path pays full monadic plumbing.

### P3. Writers move to direct state-passing

`fresh`, `set`, `union`, `modify` -> `… -> State -> ( X, State )`, following the
`Store.freshVarS` precedent. Saturated calls become direct calls, and Eco gives a
`( X, State )` result a `$sret` twin (verified in this session on
`Translate.travExpr`), so the tuple is two SSA values, not a heap object.

**Decide the convention first:** `IO` returns `( State, a )`, the existing
direct-style helpers return `( a, State )`. Pick one and use it everywhere; a
silent mismatch here is a correctness trap, not a style nit.

### P4. Stop threading the whole `State` record

Every write copies a 4-field record for one array update. The union-find core
needs only `ioRefsPoint`: pass `Array PointCell` through it and rebuild `State`
at the phase boundary.

### P5. Remove the leaf wrappers

- `IO.pure` (147 uses) — each allocates `\s -> ( s, x )`; in direct style it is
  just the value.
- `IO.apply` (33 uses) — `andThen (\f -> andThen (f >> pure) ma) mf` is three
  closures plus a composition per use; hand-write the hot ones.
- Batch the hot pairs: unification does `get a; get b; compare; set`; a
  `getPair : State -> Point -> Point -> ( Descriptor, Descriptor )` halves the
  plumbing on the hottest path.

### P6. A real mutable store (deepest, optional)

`Data.Vector.Mutable` is a misnomer — it is `Array.set` on a **persistent** array
inside an IORef. A genuinely linear/mutable array removes the path-copying as
well as the threading, attacking allocation as well as dispatch. Large change;
only after P1–P5 have been measured.

### P7. Usage-discipline audit

The remaining stack risk is *non-tail* recursion (e.g. `repr` recurses then
writes), not the combinators. Enumerate the genuinely deep recursions; use direct
style everywhere else, validated against the JS stage per C1. Candidates for
lifting out of the monad wholesale: `Type.variableToCanType` (itself a hot
`andThen` caller), `Occurs`, zonking.

## 5. What NOT to do

Do not restructure the typechecker around a new DSL. `plans/state-monad-stack-safety.md`
already added one (`Constrain.Program`) for a real reason (JS stack), and the
census says the cost is in the union-find leaves, not the constraint walk. This
plan is about not paying monadic overhead for array indexing — nothing more.

## 6. Compiler-side (general shapes ONLY — see C2)

The monad's cost is: **a closure is created and then immediately applied.** That
is a general shape, and every rewrite below is stated without reference to any
module. Each must be justified on general Elm, with a general test, and must fire
on user code with the same shape.

- **G1 — inline small saturated higher-order functions.** `andThen` is tiny;
  inlined at the site, `ma s0` and `f a s1` become direct calls whenever the
  operands are literal lambdas — the common case in any do-block, in any
  monad, in any program. Find why `MonoInlineSimplify` declines it (size? arity?
  the returned closure?).
- **G2 — beta-reduce create-then-apply.** A lambda allocated and applied on a
  path where it does not escape should never be built. General closure/escape
  optimisation; `plans/escape-analysis-implementation.md` is the existing home.
- **G3 — fold projection of a known construction.** `let ( s1, a ) = ( s0, x ) in
  body` -> substitute. Standard SROA; the codegen test `fold_project_of_construct.mlir`
  shows the MLIR-level fold already exists — the question is whether it fires
  after G1/G2 expose the pattern.
- **G4 — LSS devirtualisation of the continuation.** `andThen` is already
  specialized 425 ways, so `ma`/`f` should often be singleton sets; find out why
  AbiCloning does not stamp them. Entirely general (it is about lambda sets), and
  this is the **named hot consumer** the LSS arc repeatedly said it lacked
  (memory: `lss-destr-anno-shipped`, "precision work needs a NAMED HOT CONSUMER").

**Note the pleasing consequence:** G1+G2+G3 compose to *derive* the monad laws
(`andThen f (pure x)` -> `f x` and friends) without the compiler knowing what a
monad is. That is the correct way to get them. Do not add a monad-law pass.

## 7. Measurement protocol

Instruments all exist (memory: `dispatch-source-census-io-monad`):

1. **Count** — `ECO_DISPATCH_STATS=1` for the callee census; the caller census
   via bpftrace uprobes on `eco_apply_closure_eval` /
   `eco_closure_call_saturated{,_eval}` / `eco_apply_segmentation_unknown` reading
   `*(uint64*)reg("sp")` (the return address, works without frame pointers).
   Set `BPFTRACE_MAP_KEYS_MAX=1000000` — it truncates silently at 4096.
   Cost 0.49 µs/probe (self-compile 9:00 -> 30:16).
2. **Wall** — bpftrace `profile:hz:997` on an UNPROBED run; symbolise offline via
   the `eco_alloc_closure` anchor slide + `nm`. Never run a second process on the
   same binary while a probe is attached: uprobes attach per **inode**.
3. **Allocation** — lower the same `.mlir` a second time with
   `ECO_INLINE_ALLOC=0` and read `Objects allocated` / `Bytes allocated`.
   The monad's closures/tuples/record-copies are invisible otherwise.
4. **Minor GC count** is deterministic per (binary × tree) — an n=1 A/B is valid.

Gates per phase: `--target full` E2E 1718/1718; the unit suite (12 known
pre-existing typechecker failures — compare the SET, not the count); **a JS
self-compile per C1**; and the bootstrap fixed point where output legitimately
moves.

## 8. Expected ceiling, stated honestly

Dispatch machinery attributable to the monad is **67.4 s of a 540.8 s**
self-compile (12.5 %). That is the ceiling on the dispatch half alone. The
allocation half — one closure per `andThen`, one per `pure`, a tuple per step, a
State record copy per write — is not in that number and is plausibly larger; the
solver's sibling `Step` monad is already known to dominate allocation
(`lss-cost-is-step-monad-allocation`). Neither number is a promise: P0 may be
flat, and P1 is the phase that has to carry the result.

A refuting outcome to watch for: if P1 lands and dispatch drops but wall does
not, the cost was never the dispatch but the allocation behind it — in which case
P4/P6 become the plan and P2/P3/P5 are hygiene.

## 9. Results — P0 + P1 DONE 2026-09-05

**All gates green.** Unit suite 13,422 pass / 12 fail — byte-compared as the SAME
12 pre-existing typechecker failures; `--target full` **1,718 / 1,718**; two small
corpora **byte-identical**; and the C1 gate — **a full JS self-compile passed**
(`rc=0`, 15:14.31, no `RangeError`/stack message), which is the one that matters
because P1 converts monadic recursion into real stack recursion.

Corpus: the frozen 223,536-line compiler source (`scratchpad/corpus-src`), both
arms, DEFAULT flags (solver + LSS), `ECO_DISPATCH_STATS=1`.

| | BASELINE | P0+P1 | delta |
|---|---:|---:|---:|
| **wall** | 8:44.24 | **7:44.03** | **−60.2 s (−11.5 %)** |
| **generic dispatch `sat`** | 2,579,244,404 | **1,674,732,909** | **−904,511,495 (−35.1 %)** |
| ├ `gen` | 2,539,824,084 | 1,635,312,589 | −904,511,495 |
| └ `typed` | 39,420,320 | 39,420,320 | **0** |
| **objects allocated** (`ECO_INLINE_ALLOC=0`) | 10,567,526,344 | **8,925,551,529** | **−1,641,974,815 (−15.5 %)** |
| **bytes allocated** | 437,602.8 MB | 374,578.3 MB | **−63.0 GB (−14.4 %)** |
| minor GC cycles | 2,116 | 1,849 | −12.6 % |
| peak RSS | 10,372 MB | 10,221 MB | −1.5 % |
| wall (noinline arm) | 10:01.76 | 8:47.15 | −74.6 s |
| the compiler's own `.mlir` | 15,510,386 B | 15,420,982 B | −89 KB |

The whole reduction is in the generic funnel — **`typed` is unchanged to the
digit**, exactly as predicted for a change that deletes monadic plumbing rather
than altering statically-known calls.

### 9.1 What was actually done

- **P0**: `andThen f ma s0 = …` (was `andThen f ma = \s0 -> …`), matching `map`.
- **P1**: `UnionFind.elm`'s bodies rewritten in direct state-passing style —
  `freshS`/`reprS`/`getS`/`setS`/`modifyS`/`unionS`/`equivalentS` taking `State`
  as an ordinary parameter, plus `redundantQ : State -> Point -> Bool`, the one
  genuinely pure query. `Data.IORef` gained `readPointCellS` / `writePointCellS`
  / `newPointCellS`, and its `IO` forms are now defined in terms of them.
- **Zero caller churn**: the `IO`-shaped exports were kept as thin wrappers, so
  `Unify`, `Occurs`, `Type`, `Solve` and `Instantiate` were not touched. The
  direct forms are exported too, for callers to migrate onto later.
- Behaviour is preserved exactly, **path compression included** — same reads and
  writes in the same order, with the monad removed.

### 9.2 Honesty about attribution

- **The baseline binary predates two unrelated changes** (the `Nothing`-constant
  fold and the `stampGuardCounts` gating), so the −60.2 s wall includes them.
  The **dispatch** delta cannot: the `Nothing` fold removes *direct* calls, which
  `sat` never counted, and the census gating removes at most ~1 M dispatches
  against 904 M. The **allocation** delta likewise: the census array is a few
  million objects against 1.64 **billion**. So the dispatch and allocation
  numbers are P0+P1; a few seconds of the wall may not be.
- **P0 and P1 were measured together.** Splitting them needs another build+measure
  arm (~35 min). Given P1 removes ~6 monadic operations per union-find call and
  P0 removes one closure per `andThen` node, the split is worth knowing but was
  not bought.

### 9.3 What this says about §8's prediction

§8 predicted a ceiling of 67.4 s from the dispatch half and warned the allocation
half was probably larger and not in that number. That is what happened: the wall
moved 60 s while allocation fell by 1.64 billion objects and 63 GB. The refuting
outcome §8 named (dispatch falls, wall does not) did **not** occur.

Remaining: `sat` is still 1.67e9. P2–P7 are untouched, and a fresh caller-side
census would now be needed to re-rank what is left.


## 10. P2 + P3 — 2026-09-05

### 10.1 P2 was already done by P1 (verified, no code written)

P2 asked to fast-path the primitives because "even the fast path pays full
monadic plumbing". P1 removed the plumbing outright, so the fast path is already
a bare array read: `getS` matches `IO.Root` on the first cell and returns
`( desc, s )`. Confirmed in the emitted MLIR — `getS$sret` is 56 lines of
`get_tag`/`case`/`project.custom` with **no closure and no allocation**, and
`getS`/`equivalentS`/`freshS` all received `$sret` twins so their `( a, State )`
results are two SSA values rather than heap tuples. Nothing left to do.

### 10.2 A fresh caller census re-ranked the field

Run on `eco-p1` (21:29 probed vs 7:44 unprobed), attributing 1.60 e9 of 1.67 e9:

| subsystem | after P0+P1 | (was, before P0+P1) |
|---|---:|---:|
| IO monad combinators | 669,011,287 (41.7 %) | 1,414,130,404 |
| Dict/Set folds | 375,214,240 (23.4 %) | 376,022,103 |
| other compiled Elm | 345,303,802 (21.5 %) | 354,053,899 |
| kernel C++ / runtime | 105,262,104 (6.6 %) | 106,202,007 |
| `Unify`'s own StateT+Except monad | 79,365,774 (5.0 %) | — |
| monomorphizer / solver | 22,176,190 (1.4 %) | 96,998,754 |
| `Solve` | 6,860,280 (0.4 %) | — |
| **`UnionFind` as a dispatch source** | **137** | 48,434,891 |

`UnionFind` went from 48 M to **137**. But the callee side showed the IO wrappers
still being dispatched **141,393,843** times (`UF.get` 80.8 M, `equivalent` 21.1 M,
`union` 20.7 M, …): callers PARTIALLY APPLY them (`UF.get var` is arity-2 given
one argument), so each built a PAP that `andThen` then dispatched through. That
is what P3 had left to do.

### 10.3 What P3 changed

Two conversions in `Compiler/Type/Unify.elm`, both eta-expansions that thread the
state instead of building actions — `Unify` wraps `List Variable -> IO a` and
`IO a = State -> ( State, a )`, so taking `s0` is type-preserving:

- **`guardedUnify`** — unification's hot path. Was `UF.equivalent left right`
  then two `UF.get`s, each partially applied and each consumed by an `andThen`:
  three PAPs, three binds. Now three saturated `equivalentS`/`getS` calls with
  the state threaded through `s0 -> s1 -> s2 -> s3`.
- **`merge`** — `UF.union … |> IO.map (Ok << UnifyOk vars)` became a direct
  `UF.unionS … s0` and a literal result pair.

`gatherFields` was started and **reverted**: closing its tail correctly needs the
whole recursion restructured, and a blind edit there risks correctness for a
non-hot path. It stays monadic.

### 10.4 Results

| | BASELINE | P0+P1 | **+P3** |
|---|---:|---:|---:|
| wall | 8:44.24 | 7:44.03 | **7:34.87** |
| dispatch `sat` | 2,579,244,404 | 1,674,732,909 | **1,466,892,725** |
| objects allocated | 10,567,526,344 | 8,925,551,529 | **8,611,014,205** |
| bytes allocated | 437,602.8 MB | 374,578.3 MB | **362,355.0 MB** |
| minor GC cycles | 2,116 | 1,849 | **1,804** |

P3 alone: dispatch **−207,840,184 (−12.4 %)**, objects −314,537,324 (−3.5 %),
−12.2 GB, wall −9.2 s. That exceeds the 141 M the wrappers themselves accounted
for, because deleting the binds removed their internal dispatches too.

**Cumulative vs baseline: dispatch −43.1 % (−1,112,351,679), allocation −18.5 %
(−1,956,512,139 objects, −75.2 GB), wall −13.2 % (−69.4 s), minor GC −14.7 %.**

**Gates:** P3's emitted `.mlir` is **byte-identical to P1's**; two small corpora
byte-identical; units 13,422 / 12 (same 12 pre-existing, byte-compared);
`--target full` **1,718 / 1,718**; **JS self-compile passed** (rc=0, 14:43.73,
zero stack errors).

### 10.5 Where the next win is — it is no longer this monad

`Dict`/`Set` folds are now the largest single coherent source at **375,214,240
(23.4 %)**, and `Dict_foldl` is rank 1 overall (79.5 M). They were never touched
and are structurally the same problem: `Dict.foldl f acc dict` calls `f`
indirectly per element.

The IO monad's remaining 669 M is now spread thin across many `andThen`
specializations at 30–60 M each, and — importantly — those dispatches are the
`ma s0` and `f a s1` calls made from INSIDE `andThen`. No source edit removes
them; only inlining `andThen` at the site (G1) or devirtualising the continuation
(G4) can, both of which are general compiler work under C2. Further source-side
churn in `Solve`/`Unify`/`Constrain` would buy diffuse single-digit millions per
site for a large, risky refactor.
