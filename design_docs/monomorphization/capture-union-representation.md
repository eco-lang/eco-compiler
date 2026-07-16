# M5 unboxed capture unions — design sketch + go/no-go

**Status: NO-GO (2026-07-16).** The go/no-go criterion from
`plans/hof-elimination-closure-alloc-reduction.md` §H7 — *"post-H6 census
share of allocations attributable to k≥2 sets and to escaping-but-small
closures; if < ~10%, don't build it"* — evaluates to **≈0% in the top 46%
of dynamic creates and no evidence of a qualitatively different tail**
(analysis in §4). This document records the representation design at the
depth needed to (a) justify the verdict and (b) restart quickly if the
revisit conditions (§5) ever hold. No implementation exists or is planned.

## 1. What M5 is

The PLDI'23 lambda-set headline: when the set of lambdas that can flow to
a function-typed position has statically known members `{λ₁..λₖ}` with
`k ≤ K` (eco: `maxSetSize = 8`), the closure value can be represented as a
**stack-allocated tagged union of capture records** instead of a heap
closure — the consumer `match`es on the discriminant and calls the member
directly. H5 (interprocedural capture flattening + call-site loopification,
SHIPPED) already captures the `k = 1` case, which every census to date
shows dominates. M5's residual value is exclusively:

- `k ∈ [2..8]` sets — match-dispatch without closure objects;
- closures that leave their creating function ("escape" in the weak
  sense: returned / passed by value) while staying OUT of heap data, small
  enough to travel as a by-value aggregate.

## 2. Representation sketch

### 2.1 Layout

```
%union = { i8 discriminant, [S x i64] slots }   // S = max over members of
                                                 //     slot count (≤ 6, H5's cut)
```

- One union TYPE per lambda set (per keyed spec, riding AbiCloning's
  per-set fan-out — the M4 keyed machinery).
- `discriminant` indexes the member list in set order (the LSS member
  ordering already stable for keyed specs).
- Each member's capture record occupies `slots[0..cᵢ)` in its OWN kind
  layout; unused tail slots are undefined and must never be scanned.

### 2.2 Kind encoding (sibling invariant sketch: `REP_STACK_CAPTURE_UNION`)

- Per-slot kinds use the SAME 2-bit encoding as heap closures
  (`00`=boxed HPointer, `01`=Int, `10`=Float, `11`=Char) so spill-to-heap
  (boxing) is a memcpy plus header write, never a re-encode.
- Bool stays boxed per `FORBID_CLOSURE_001` (never captured/stored as an
  immediate outside SSA control flow).
- No embedded-constant compression: slots hold full `!eco.value` words per
  `REP_CONSTANT_001/002` (True/False/Empty remain HPointer-embedded
  constants; the union never invents a denser form).

### 2.3 Boxing boundary (escape ⇒ box)

A union value must be BOXED into an ordinary heap closure (of the matched
member) the moment it:

1. is stored into heap data — ctor field, record, array/list element, or
   **another closure's capture slot** (this is the dominant real-world
   path — see §4);
2. crosses the C++ kernel ABI (kernels take `HPtr` closures; there is no
   union kernel ABI and building one is out of scope);
3. flows into generic apply / PAP formation (papCreate/papExtend operate
   on heap closures; arity-mismatch consumption forces the heap form);
4. widens out of its set (`LTop` at any consumption point).

By-value travel (argument/return within compiled Elm code) does NOT box,
subject to the aggregate-lowering cap (`logicalTypes.customMaxFields`,
clamped [1,24] with 24 the heap-ABI hard cap; the plan's earlier
`kMaxDirectFields` name does not exist in-tree). With S ≤ 6 + i8 the union
is well under it.

### 2.4 GC rooting — the hard design problem

Boxed (`00`) slots inside a LIVE stack union must be GC roots, and — this
is the crux — **which slots are boxed depends on the runtime
discriminant** (member i's kind map). Options considered:

- **(a) Exploded SSA**: keep the union as separate SSA values per slot +
  discriminant; RS4GC tracks the `ptr addrspace(1)` slots natively. Cost:
  per-member phi webs at every merge point; code-size blowup measured in
  the H5 work already at k=1.
- **(b) Stack slot + dynamic mask**: alloca the union and register a
  stack-range root whose mask is selected by discriminant at runtime
  (`eco_gc_push_stack_range` with a per-member mask table). Cost: a NEW
  GC scan contract (mask lookup during scan — today masks are static),
  touching `NurserySpace::scanObject`-adjacent code and the exact
  stack-root machinery two use-after-free bugs shipped from this quarter.
- **(c) Conservative over-mask**: union of all members' boxed slots
  scanned as potential pointers — UNSOUND with a moving GC (a non-pointer
  slot interpreted as HPointer would be "relocated"): ruled out; eco's GC
  is precise by invariant.

(a) is sound but pays in code size; (b) is the honest design and carries
first-class GC-invariant risk (new HEAP_* sibling, new scan mode). Either
way M5's implementation cost is dominated by GC plumbing, not by the union
layout itself.

## 3. Where M5 could win, precisely

Combining §1 and §2.3: the win class is closures that are
**(i) members of a k≥2 set, (ii) never stored into heap data (including
closure captures), (iii) never passed to kernels, (iv) consumed at
set-known sites** — plus the weak-escape single-member case not already
taken by H5.

## 4. Go/no-go evaluation (fresh post-P6 census, 2026-07-16)

Workload: native Stage-7a self-compile, flag-off, P6 in the backend
(`/tmp/sweep-off-c1.log`; creates = 543,335,453, extends = 1.1M).
Concentration: top-20 = 41.0%, top-50 = 62.3%, top-200 = 86.9%.

Classification of the top-25 creators (≈46% of ALL creates):

| block | ≈creates | class | M5 win? |
|---|---|---|---|
| `Terminal_Main_lambda_8xxx$cap` ×16 (8274 33.9M … 8247 5.0M) | 175.5M | TypeCheck.IO monadic-bind continuations, CAPTURED into the returned IO value / next chain closure (H6.0a classification) | **No — heap-capture ⇒ box (§2.3.1)** |
| k=1 HOF-arg pairs: `lambda_28456`+`applySubstPure` (both 11,402,436), `TType`+`IO_map` (both 6,539,65x), `typeEncoderS`, `Maybe_map`, `traverseList`, `List_cons` | 65.6M | one lambda per consumer spec — the identical creator/consumer counts are k=1 signatures | **No — k=1 is H5's class, not M5 residual** |

Zero rows in the top 46% belong to the §3 win class. Corroborating
evidence that the tail is not different:

- Every LSS census to date found singletons dominate (the H5/M3.5 record;
  M4's keyed fan-out exists precisely because multi-member sets are rare
  enough to budget at `maxSpecsPerGlobal = 64`).
- The static residual taxonomy (same compile):
  `arg-to-ctor = 1204` + `stored-data = 50` (semantic heap escape),
  `arg-to-kernel = 787` (kernel boundary), `let-bound = 6763` /
  `arg-to-global = 3346` (dominated by the k=1 pairs above),
  `fnres-returned = 700` of 1212 fn-result specs (returned IO values that
  are then BOUND — i.e. stored — by the next bind).
- Post-P6, a "create" is a bump-pointer alloc + store — the cheapest event
  in the system. M5's per-avoided-alloc win is at its historical minimum
  while its cost (a new value representation + REP_/HEAP_ siblings + the
  §2.4 GC contract) is unchanged.

**Verdict: NO-GO.** The measured share of the win class is ≈0% where the
mass is, the tail would need to be qualitatively unlike everything
measured to reach the 10% bar, and the implementation cost lands on the
exact GC machinery with the worst recent defect history.

## 5. Revisit conditions

Reopen only if one of these materially changes:

1. A workload where k≥2 sets carry ≥10% of dynamic creates (requires a
   set-size-keyed census: instrument keyed-LSS specs to tag their
   members' papCreates — does not exist today and is only worth building
   against a concrete suspect workload).
2. The typechecker's IO chain is restructured so continuations stop being
   heap-captured (e.g. a defunctionalized step loop) — that removes the
   boxing boundary from the dominant block, and §3's calculus changes.
3. Wall-clock profiling attributes a material cost to create traffic
   itself (post-P6 this is doubtful: the U2b sweep showed a 13.5% event
   REDUCTION costing +55% wall — allocation counts do not govern this
   compiler's wall-clock).
