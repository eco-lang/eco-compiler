# Chunked List Representation (Alm-style unrolled lists)

*(Plan created Aug 2, 2026. Prior art: Alm's `_List_*` kernel —
`/work/Alm/crates/compiler/src/generate/runtime.js:60-127` — and its WasmGC
twin (`wasmgc.rs` `T_BACK`/`T_LIST`, `CONS_CHUNK_CAP = 8192`). In-repo context:
`design_docs/theory/`, memory notes "eco cons-reduction investigation"
(Cons = 10.4% of the true 6.52B-object alloc profile ≈ 678M objects) and
"borrow-inf perf-tune loop" (lesson: only REMOVE allocation; never add fixed
overhead to a hot path).)*

**Status: PROPOSED — measurement phase L0 must run before any commitment.**

---

## 1. The Alm scheme, restated precisely

Alm replaces cons cells with an *unrolled linked list*: a spine of **chunks**,
each a dense array of up to `_List_LIMIT = 8192` elements.

Two object kinds:

- **View node** (the `'::'` value): `{ d: backing, o: firstLiveIndex, b: tail }`.
  Immutable once observable. A list's elements are `d[o .. d.length)` ++ `b`.
- **Backing array** `d`: element slots, plus a mutable watermark `d.hd` =
  frontmost slot ever claimed on this backing.

Operations:

- **cons** (`_List_Cons`): if the tail view owns the frontmost slot
  (`o > 0 && d.hd === o`), write `d[o-1] = hd`, decrement `d.hd`, return a new
  view `{d, o-1, b}` — **one small view alloc, amortized zero backing alloc**.
  Otherwise allocate a fresh chunk (geometric: `cap = prev < 4 ? 8 : prev*2`,
  capped at 8192) with the element at the back and `b = old list`. Never an
  O(n) copy.
- **tail**: `o+1 < d.length ? {d, o+1, b} : b` — allocates a view unless the
  chunk is exhausted.
- **head**: `d[o]` — one extra indirection vs a cons cell.
- **Bulk builders** (`fromArray`, and Alm's kernelized `map`/`filter`/`range`/
  `foldr`-output/etc.): ONE dense chunk over the whole result (`o=0`, no `hd`
  claim, unbounded size), adopting the scratch array without copying.
- **Aliasing safety** is the `d.hd === o` guard: exactly one live view can own
  the slack in front of any position; every other cons (second cons onto the
  same list, cons onto a tail view) degrades to a fresh chunk. A view's `o`
  never decreases and `d.hd` only decreases, so a slot below `hd` has provably
  never been written and is unreachable from every live view.
- **Chunk boundaries are NOT part of list identity**: equality, ordering,
  pattern matching, `toString` compare the logical element sequence.

What it buys (Alm's measurements): `List.map` 1M `102 → 12.4 ms` (JS) /
`1.9 ms` (wasm), `filter` `70 → 16.7 / 2.6`, float-sum `178 → 28 / 3.1`;
plus short spines (GC + cache) and structural sharing preserved.

**Load-bearing fact about where the win comes from:** Alm gets the bulk-builder
numbers because its **entire `List` module is kernel code**
(`runtime.js:349-470`: `$List$map/filter/foldl/foldr/range/repeat/reverse/
sortBy/...` are array loops over chunks). It does *not* compile elm/core's
recursive `List.elm`. Per-`::` cost in Alm is still one view-node allocation —
comparable to a cons cell. The representation alone does not make `map` fast;
the kernelized builders do. This drives the phasing below (§6).

---

## 2. Mapping onto eco's heap

### 2.1 Current representation

```c
// Heap.hpp:467-471
typedef struct {
    Header header;   // Header.unboxed bits 1:0 = head kind (00 boxed/01 i64/10 f64/11 char)
    Unboxable head;
    HPointer tail;
} Cons;              // 24 bytes/element
```

Nil is the merged `Empty` embedded constant `0x6` (REP_CONSTANT_001/HEAP_010) —
**unchanged by this plan**.

### 2.2 Proposed layout

Keep `Tag_Cons` as the tag of the **view node** so every "is it Nil or a heap
Cons" dispatch (eco.case lowering, `eco_get_tag`, kernel `isCons`) is
untouched. Add **one** new tag for the backing (tag budget: 25 of 32 used
after the UTF-8 tags; verified room).

```c
typedef struct {
    Header header;   // tag = Tag_Cons. Header.unboxed bits 1:0 = ELEMENT kind
    HPointer backing;// -> Tag_ListBacking
    u32 offset;      // first live index (o).  u32 pad free in the word.
    HPointer next;   // next view in spine, or Nil
} Cons;              // 32 bytes (was 24)

typedef struct {
    Header header;   // tag = Tag_ListBacking. header.size = capacity (elem count)
                     // Header.unboxed bits 1:0 = uniform element kind
    u32 hd;          // frontmost claimed slot (mutable, monotonically decreasing)
    u32 _pad;
    Unboxable elems[];
} ListBacking;
```

- **Unboxed elements survive intact.** Today `Cons.head` holds unboxed
  Int/Float/Char selected per-cell by the 2-bit bitmap (HEAP_019,
  REP_BOUNDARY_002/003). The backing carries one *uniform* 2-bit element kind —
  the same move as `Tag_Array`'s uniform kind, and the exact analogue of Alm's
  `T_LISTI/T_LISTF/T_LISTC` unboxed twins, except eco gets it from one
  parameterized layout instead of three monomorphized types. A well-typed list
  is kind-homogeneous, and every construct site knows the SSA operand type
  (REP_BOUNDARY_002), so the kind is available at every cons/bulk site.
- Alm's SoA twin for `List (flat product of scalars)` (`T_LIST_SOA`) is
  **explicitly out of scope** for v1.
- Bulk chunks: cap bulk-chunk size at `HeapConfig::large_object_threshold`
  bytes and chain chunks beyond it (deviation from Alm, which is unbounded) —
  keeps backings out of the large-object / split-header machinery (HEAP_026)
  in v1. A future `Tag_LargeListBacking` split-header form can lift this.

  **The cap is a HARD SAFETY requirement, not just a tuning choice
  (learned the hard way, Aug 2 2026):** an over-LOT backing is allocated
  directly into pinned old gen, and filling it with fresh (nursery) element
  pointers creates exactly the unrecorded old→young edges of §2.3(a) —
  minor GC never rescans it and the slots go stale. Bisected on the flag-on
  bytecode self-compile: the 76,728-element `List.reverse encodedOps` chunk
  (614 KB) in the bytecode writer, whose element slots later resolved to
  unrelated Records. Backings must be NURSERY-BORN; the promotion path is
  then safe (promoted backings ride the same promoted-objects machinery as
  every promoted Cons/Custom).

  **As-built v1:** `alloc::listFromUnboxables` enforces the cap and falls
  back to CELLS for over-cap batches (correct, loses the chunk win on
  giant lists). **Chunk CHAINING for over-cap batches is the planned
  refinement — a concrete L2 work item (§6):** split an n-element batch
  into ⌈n/maxElems⌉ nursery-sized backings linked through `next`, each
  view's `len` covering its suffix per the consistency invariant. O(1)
  extra views, all nursery-born, no GC surface change. The measured
  motivation is real: the bytecode writer's op list alone is ~77K elements
  per self-compile, and every over-cap batch currently pays n cells.

### 2.3 The three hazards eco has that Alm's JS host absorbed

*(§6-restructure note: under hybrid spines, hazard (a) applies only if L3
ever builds slack fill — deferred with §10; hazard (b) applies only to
chunk-context tails (measured 19.4M residual, §11.b); hazard (c) reduces to
fixed-extent scanning since v1 chunks are immutable with `hd ≡ 0`.)*

These are the design-critical deltas; each gets an invariant in §7.

**(a) No write barrier exists.** eco's minor GC assumes *no old→young pointers
ever exist* ("Elm's immutability means no old->young pointers exist, so no
write barrier or remembered set is needed" — `NurserySpace.cpp:25-26`;
reaffirmed at `ThreadLocalHeap.cpp:236-238`). The in-place slack fill writes a
possibly-young element into an existing backing. **Rule: the in-place cons fast
path additionally requires the backing to be nursery-resident** (one address
range check). A promoted or permanent backing fails the guard and the cons
opens a fresh (nursery) chunk — graceful degradation, zero new barrier
machinery. `PermanentSpace.cpp:124` (CAF deep-copy of `Tag_Cons`) must copy
backings with the slack **trimmed and `hd` frozen at `o`** so a permanent
backing can never accept an in-place fill (it fails the nursery check anyway;
trimming also stops permanent space retaining dead slack).

**(b) `eco.project.list_tail` stops being a pure load.** Today it is `Pure` and
lowers to one inline load at `ConsTailOffset` (`Ops.td:670`,
`EcoToLLVMHeap.cpp:581`, offsets at `EcoToLLVMInternal.h:333-334`). Under
chunks, tail = *allocate a view* unless the chunk is exhausted. That makes
every compiled `x :: rest` match an allocation site: statepoint placement
(allocation-based statepoints), GC root liveness, and the HEAP_034 inline-bump
diamond all now apply to tail projection. This is the single most invasive
codegen consequence and the reason for the out-of-line-first phasing (§6 L1).
`eco.project.list_head` stays pure but becomes two loads (view→backing→elem).

**(c) GC must never trace slack.** Live slots of a backing are `[hd, cap)`;
`[0, hd)` is uninitialized garbage. Every tracer — nursery scan/evacuation,
old-gen mark (`OldGenSpace.cpp:1639,3898`), permanent-space copy, and
`ECO_HEAP_VALIDATE` walkers — scans from `hd`. Since `hd ≤ o` for every live
view, scanning `[hd, cap)` covers all reachable elements. `evacuateListSpine`
/`evacuateListHeads` (`NurserySpace.cpp:1434-1659`), the spine-locality
special case built for cons chains, is **retired/rewritten**: the spine is now
one object per ≤8192 elements, so plain BFS suffices — a meaningful
simplification and a GC win in its own right (spine copy per minor GC drops
~chunk-factor).

Known retention tradeoff (same as Alm, document in theory notes): a live tail
view retains its whole backing, including elements ahead of `o` reachable from
no live list.

---

## 3. Operation semantics in eco terms

| op | today | chunked |
|---|---|---|
| `cons h t` | 24B inline bump alloc, 3 stores | guard `t` is Tag_Cons ∧ `o>0` ∧ `backing.hd==o` ∧ backing in nursery ∧ kind matches → store elem, `hd--`, alloc 32B view. Else alloc fresh chunk (geometric 8→2×, ≤8192) + view |
| `head l` | 1 load (+kind-typed result, REP_BOUNDARY_003) | 2 loads: `backing.elems[o]`, kind-typed as today |
| `tail l` | 1 load | `o+1 < cap ? alloc view(o+1) : load next` — **allocates** |
| `[a,b,c]` literal | 3 cons ops | 1 backing + 1 view (new bulk path, §5.3) |
| eq / compare / toString | walk cells | logical-sequence walk, chunk-boundary-blind (Alm invariant) |
| case Nil/Cons | Empty-constant vs heap tag test | unchanged |

Number-kind note: a backing's uniform kind must agree with what projection
sites expect (REP_BOUNDARY_003). Cross-kind cons (e.g. boxed onto unboxed —
which today is representable per-cell) must refuse the fast path and open a
fresh chunk of the operand's kind only if the whole-list kind matches;
otherwise fall back to kind `00` (boxed) chunks. The monomorphizer's guarantees
(MONO_028 number healing; the deep-branch-solver Cons-taint fix in
`Translate.elm deriveKernelAbiTypeWith`) make mixed-kind lists a should-not-
happen; the runtime guard makes it safe anyway.

---

## 4. What the code touches — full inventory

### 4.1 Runtime heap + GC (`runtime/src/allocator/`)

| file | change |
|---|---|
| `Heap.hpp` | `Cons` struct → view layout; new `ListBacking` + `Tag_ListBacking` (before `Tag_Free`); comment blocks on `unboxed` bitfield (Cons slot count) |
| `HeapHelpers.hpp` | `alloc::cons` (line ~609-630) reimplemented — **this is the chokepoint API** (`(Unboxable, HPointer, bool)` signature kept so most kernel call sites survive untouched); `listHead`/`listTail`/`isCons` helpers; `getObjectSize` arms for both new shapes |
| `NurserySpace.cpp` | scanObject `Tag_Cons` arm (trace backing+next); new `Tag_ListBacking` arm (trace `elems[hd..cap)` per uniform kind); **delete/rewrite `evacuateListSpine`/`evacuateListHeads`** (1434-1659) and the `use_hybrid_dfs` config knob; evacuation copies backing whole (slack included, garbage bytes); HEAP_BUILDER_002 interplay if builder bit is used (not planned for v1) |
| `OldGenSpace.cpp` | mark/size arms 1639, 3898 |
| `PermanentSpace.cpp` | list deep-copy arm 124: trim slack, freeze `hd = o` |
| `ListOps.cpp/.hpp` | full rewrite to chunk-native builders: `range`/`repeat` emit dense chunks directly; `sort*` already round-trips a vector — retarget to bulk build; `append`/`concat`/`intersperse`/`take`/`drop`/`partition`/`unzip`/`reverse` become array loops |
| `RuntimeExports.cpp` | every `Tag_Cons` site (~23): cons alloc exports (265, 374, 1064-1091, 1486 — incl. the list-literal / fromArray runtime paths), `eco_get_tag`, `Debug.toString` walker (1601, 1649, 2862-2891, 3119, 3356-3361, 3911), any `->head/->tail` direct field access |
| `Allocator.cpp`, `GCStats.cpp` | size/census arms; census tag names (`heap-profile.py` too) |
| validation | `ECO_HEAP_VALIDATE` walkers: slack-skip rule, `hd ≤ o < cap` on every view, kind-match view↔backing |

### 4.2 Kernels (`elm-kernel-cpp/src/`, `eco-kernel-cpp/src/`)

| file | change |
|---|---|
| `core/ListExports.cpp` | `cons`/`cons_Int`/`cons_Float`/`cons_Char` (259-271) → chunk cons; `fromArray`/`toArray` (277, 326) → adopt/emit dense chunks (near-free win); `map2..5` shared driver (388-600) → chunk cursors — **re-audit against the `kernelListMapN` stale-cursor GC bug** (memory: cursors must be re-read from rooted values after any alloc; chunk cursors are (backing, index) pairs and backings MOVE at minor GC — cursor = rooted view + index, never a raw `Unboxable*`); `sortBy`/`sortWith` |
| `core/Utils.cpp` | structural eq (319), compare (514, 615, 744): logical-sequence walkers over chunks, memcmp-style fast path within same-kind unboxed chunks is a free bonus |
| `json/JsonExports.cpp` | encode walk; decode `list` builder → bulk chunk (decode-heavy code is a first-class beneficiary) |
| `core/JsArrayExports.cpp` | `Array.fromList` walk (Utils.cpp:135 comment) |
| `core/UtilsExports.cpp`, `Scheduler.cpp` (platform), `virtual-dom`, `parser`, `bytes`, `http` | audit every `isCons`/head/tail/direct-field use; helper-API users survive, direct `Cons*` field pokes are rewritten |
| eco-kernel-cpp | same audit (File/Console/Env list results) |

### 4.3 MLIR codegen — C++ (`runtime/src/codegen/`)

| file | change |
|---|---|
| `Ops.td` | `eco.construct.list` (614): same IR surface, new lowering contract; `eco.project.list_head` (648): stays Pure, two-load; **`eco.project.list_tail` (670): loses Pure / gains allocation semantics** — new traits, GC-visible; doc examples 297/391/880; `eco.make.cons` (2924) + `!eco.cons`: **keep for SSA-only non-escaping cons pairs** (escape analysis / T1 stack promotion unaffected), but `eco.from_heap : !eco.value -> !eco.cons` (CGEN_063) can no longer synthesize a (head, tail) pair without allocating a tail view → **drop `!eco.cons` from from_heap's legal results**; `eco.to_heap` of `!eco.cons` materializes a 1-chunk list |
| `EcoToLLVMInternal.h` | `ConsHeadOffset`/`ConsTailOffset` (333-334) → view/backing offset set |
| `EcoToLLVMHeap.cpp` | `ListConstructOpLowering` (~451): L1 = call `eco_list_cons` runtime export; L2 = inline fast path (guard chain + bump diamond); `ListHeadOpLowering` (500-548): two-load; `ListTailOpLowering` (581): alloc-or-load diamond with statepoint |
| `EcoToLLVMValueAgg.cpp` | `ConsMakeOpLowering` (160), from_heap/to_heap Cons arms (586, 751) per the Ops.td decision |
| `EcoToLLVMControlFlow.cpp` | case-on-list arms (6 hits) — expected no-op if `Tag_Cons` retained; verify |
| `EcoToLLVMGlobals.cpp` | static/global list constants (5 hits): emit compile-time backing + view globals (nice win: literal lists become 2 static objects) |
| `EcoGCPrepare` / statepoint machinery | list_tail is now an alloc site: liveness, root ranges, `EcoGCLivenessAudit` coverage |
| `EcoBackend.cpp`, `EcoToLLVMTypes.cpp` | struct defs, type converter |

### 4.4 Compiler — Elm (`compiler/src/Compiler/`)

| file | change |
|---|---|
| `Generate/MLIR/Expr.elm` (~885) | list-literal emission: today Nil + per-element `eco.construct.list`; add a bulk form (either a new `eco.construct.list_bulk` op or a recognized cons-chain the C++ lowering collapses — recommend the explicit op) |
| `Generate/MLIR/Ops.elm` (190-385) | op builders for the above |
| `Generate/MLIR/Patterns.elm`, `TailRec.elm` | decision-tree Head/Tail steps semantically unchanged, but tail-projection inside self-tail loops is now allocating — TailRec's loop-carried values must treat the tail view as a fresh GC-visible value each iteration (shadow-roots interplay, `plans/tco-shadow-roots.md`) |
| `Generate/MLIR/LogicalTypes.elm` (36, 237) | `"cons:Kh:Kt"` encoding: tail kind is still `v`; head kind unchanged — audit only |
| `Generate/MLIR/BytesFusion/Reify.elm` (479) | cons-call recognition — audit |
| `GlobalOpt/Borrow/KernelSigs.elm` | param modes for the rewritten list kernels; census counters distinguish view vs backing allocs |
| `Translate.elm` (`deriveKernelAbiTypeWith`) | `cons_Int/Float/Char` suffix-kernel ABI unchanged in signature; verify against the ConsNumberTaintTest gate |
| escape analysis / `EcoUnboxedAggSpecialize` | non-escaping `eco.make.cons` unchanged; escaping to_heap now materializes chunk form |

### 4.5 Invariants + docs (`design_docs/`)

- Update: CGEN_016 (construct.list contract), CGEN_021 (projection ops),
  CGEN_063 (from_heap loses `!eco.cons`), CGEN_065/066 (Q4 cons notes),
  HEAP_015 (Cons layout), HEAP_019 (backing uniform kind).
- New: **HEAP_037** (backing live range `[hd, cap)`; `hd` monotone decreasing;
  `hd ≤ o` for every live view; slots below `hd` never traced),
  **HEAP_038** (in-place fill only into nursery-resident backings — the
  no-write-barrier guarantee), **HEAP_039** (chunk boundaries are not list
  identity: eq/compare/toString/pattern-match observe the logical sequence),
  **CGEN_070** (list_tail is an allocation site; statepoint rules).
- New theory note: `design_docs/theory/chunked_list_representation_theory.md`
  (aliasing proof of the `hd==o` guard, retention model, generation rules).

---

## 5. Why this may NOT be a win in eco as-is — and what makes it one

Being honest before spending the effort:

1. **eco compiles `List.elm` from source.** `List.map` *is* `foldr`
   (memory: cons-reduction investigation). eco's kernel surface for List is
   only what elm/core routes through `Elm.Kernel.List`: `cons`, `fromArray`,
   `toArray`, `map2..5`, `sortBy`, `sortWith` (`ListExports.cpp`). Alm's
   headline numbers come from its fully kernelized List module. Without §5.3,
   eco gets: shorter spines (GC evacuation, cache), static literals, JSON
   decode, sort, mapN — but NOT the map/filter/fold collapse.
2. **Per-cons allocation does not drop.** View node (32B) replaces cons cell
   (24B): the fast path is *bigger* per `::` plus the guard chain, minus the
   element store amortization. Today's cons is already a 3-store inline bump
   alloc (HEAP_034).
3. **Traversal gains an alloc.** Every compiled `x :: rest` case match
   allocates a tail view where today it is a pure load — and the eco compiler
   (the workload that matters: Stage 7a self-compile) is case-traversal-heavy.

So the payoff order is inverted relative to Alm: **GC/spine effects and bulk
builders carry the win; the representation change alone is likely a
regression** on self-compile (perf-tune lesson: it *adds* allocation to the
traversal path). Which is why:

### 5.1 L0 measurement gate (mandatory, cheap) — **RUN Aug 2 2026, see §11**

Extend the existing census (`ECO_INLINE_ALLOC=0` + census infra,
`design_docs/borrow-inf-census.md` methodology) with op-rate counters:
`cons` executed, `list_tail` executed on non-exhausted chunks (i.e. would-
alloc), `list_head`, bulk-buildable constructions (literals, decode, toArray
round-trips). One self-compile run answers: **would chunked lists add or
remove net allocations on Stage 7a?** Decision rule: if
`would-alloc-tails > cons-saved + bulk-saved` by weight, STOP (record verdict
in this file, as A4/H7 did) or reduce scope to §5.4.

As-built: counters live in `eco_list_census[12]` (RuntimeExports.cpp, atexit
reporter, silent when zero); `alloc::cons` (HeapHelpers.hpp) counts kernel
cons split by tail==Nil; `Elm_Kernel_List_cons(+_Int/_Float/_Char)`
(ListExports.cpp) separates `::`-as-function-value HOF cons from
kernel-owned building loops; head/tail projection sites emit gc-leaf counter
calls when `ECO_LIST_CENSUS=1` is set at lowering time
(EcoToLLVMHeap/Runtime/Internal). Reproduce:

```
cmake --build build --target ElmKernel_List eco-boot-native
cd build/compiler/build-kernel
ECO_LIST_CENSUS=1 ECO_INLINE_ALLOC=0 \
  ../../../build/runtime/src/codegen/eco-boot-native bin/bench-clean.mlir -o /tmp/eco-census
/tmp/eco-census make --optimize --kernel-package eco/compiler \
  --local-package eco/kernel=/work/eco-kernel-cpp \
  --output=/tmp/census-boot.mlir /work/compiler/src/Terminal/Main.elm
```

### 5.2 Chunk-cursor traversal (the mitigation Alm never needed)

TailRec already rewrites self-tail list loops (`case xs of x :: rest -> go rest`)
into `while` loops. Inside such a loop the tail view is consumed immediately
and never escapes: represent the cursor as SSA `(backing, index, next)` and
never materialize the view — the escape-analysis machinery (make.cons /
T1 stack promotion) is exactly shaped for this. This removes the traversal
alloc for the dominant loop shape; non-loop tails still allocate.

### 5.3 Kernelize the bulk builders (the payoff phase — superseded in scope by §9)

Two mechanism options, decide at L3:
- **(a) Kernel shunt**: teach the build to substitute kernel implementations
  for selected `List.*` globals (`map`/`filter`/`foldl`/`foldr`/`range`/
  `repeat`/`reverse`/`append`/`concat`/`indexedMap`/`filterMap`/`take`/`drop`)
  the way Alm's runtime.js shadows `$List$*`. New mechanism; interacts with
  KernelSigs/borrow modes and the unboxed-element ABI (`cons_Int`-style
  suffixing per element kind).
- **(b) MLIR combinator recognition**: BytesFusion-style whole-combinator
  rewrite of the known elm/core definitions to chunk loops (memory note
  already concluded fusion "is the lever" and that this "needs
  whole-combinator recognition").
Option (a) is less clever and matches "exact same scheme as Alm" — recommend
(a), with the borrow-oracle KernelSigs entries extended for each new kernel.

### 5.4 Minimal-scope fallback

If L0 says the full scheme loses: bulk chunks **only where a kernel already
owns both ends** — JSON `Decode.list`, `List.sort*`, `String.split/toList`,
`fromArray`/`toArray`, mapN, literals — with cons/tail staying cell-based and
a chunk being just another spine node the walkers understand (views degrade to
cells on cons). That is strictly additive on the hot paths and captures most
locality wins without touching tail-projection semantics.

---

## 6. Phasing — RESTRUCTURED Aug 2, 2026 after the L0 census (§11)

**Tier B is the L1 deliverable.** The original ordering (representation
first, combinators as a later payoff) is superseded: §11 measured that the
representation alone is +7.6% objects, cursors bring it only to +1.8%, and
the entire win lives in the combinator pools. The census also justifies a
cheaper architecture than wholesale Cons conversion:

**Hybrid spines.** Keep `::` a 24-byte cell forever; add chunk view/backing
as *additional* spine node forms that only recognized combinators (and later
Tier-A kernels) produce. A spine may mix cells and chunks; walkers,
projections, eq/compare/toString, and GC understand both. Consequences,
priced with run-3/4 numbers:

- The HOF pool (498.0M conses / 64.9M lists) and kernel-owned pool (17.4M /
  5.4M) become chunk builds: 515.4M cells removed, 140.6M view+backing
  objects added. Compiled `::` (19.6M) is untouched — the +75M
  backing-conversion term from §11.b's full-conversion model **disappears**.
- Net: **−355.3M objects (−7.24%)** — equal-or-better than full conversion.
- Chunks are built whole (builder-bit rooted during construction, HEAP_BUILDER
  machinery already shipped) and **immutable after** — no front-slack, no
  `hd` watermark mutation, no old→young hazard. **All of §10 (and invariants
  HEAP_038/040/041) is deferred out of v1.** `::` onto a chunk view just
  makes a cell whose tail is the view.
- `list_tail` on a cell stays a pure load; only chunk-context tails allocate
  views — measured residual 19.4M (0.4% of objects), shrinking further as
  Tier B's cursors consume chunks directly.

Phases:

- **L0 — census. DONE** (§11, §11.a, §11.b). Verdict: GO conditional on
  Tier B; target ≈ −355M objects.
- **L1 — Tier B combinator loop templates + the hybrid chunk representation
  (the deliverable; first default-on candidate).** Three internal stages:
  - **L1.1 — recognition + template infrastructure on today's cells.**
    Recognize the forward-loop combinators (`foldl`, `any`, `all`, `member`,
    `length`, `sum`/`product`, `foldl`-shaped locals) at GlobalOpt/MLIR-gen
    (BytesFusion precedent) and emit cursor loops with LSS-inlined bodies —
    over the *existing* cons-cell representation (cursor = pointer walk).
    Alloc-neutral by construction; proves recognition, inlining, and gate
    plumbing with zero heap risk. Gates: full E2E, elm-tests, Stage 7a
    self-host fixed point.
  - **L1.2 — hybrid chunk representation, flag-off.** `Tag_ListBacking` +
    chunk-view `Tag_Cons` variant (§2.2 layout with `len`, §9.3; `hd ≡ 0`,
    immutable), GC arms (nursery/oldgen/permanent), mixed-spine walkers
    (eq/compare/toString/JSON/ports/Debug), `ChunkCursor` C++ helper,
    bulk-alloc runtime exports, `ECO_HEAP_VALIDATE` coverage. No codegen
    changes yet beyond chunk-aware `list_head`/`list_tail` lowering
    (tail-on-chunk = out-of-line allocating call in this phase).
  - **L1.3 — templates target chunks.** List-producing templates (`map`,
    `filter`, `filterMap`, `indexedMap`, `concatMap`, `partition`,
    `unzip`, `intersperse`) emit dense chunks (exact-size preallocation via
    `len`); the foldr family (`foldrHelper` 815 specs, `takeFast`) becomes
    backward-cursor chunk walks; `scf.while` cursor handling reads mixed
    spines. Priority order is data-ranked from §11.a: foldl (1,939 specs)
    first, foldr family second, then map/filter and the take/drop/any tier.

    **AS-BUILT (Aug 2 2026), slice 1 — closure-free combinator SHUNTS,
    SHIPPED + MEASURED.** `reverse`/`append`/`concat`/`take` spec bodies
    (elm/core List origin, capture-free MonoClosure, exact arity) are
    rewritten at MLIR-gen to `Elm_Kernel_List_*` calls
    (Functions.elm `listChunksShunt`); kernels build chunks COUNT-FIRST
    (probe shape → exact backing → view → direct fill; no vectors, no
    per-element rooting; probes are chunks-gated so flag-off `++` keeps a
    single pass). REQUIRED FIX: `MonoInlineSimplify` threshold-inlines the
    tiny delegate bodies at every call site before generation, so shunting
    dead definitions did nothing — the inliner blacklist was upgraded to
    full non-candidacy and Generate blacklists the five names when
    `list.chunks` is on. Measured (true census, flag-on binary
    self-compile vs pre-list-opt.md): **6.407B objects = −67.0M (−1.03%);
    Cons 611.1M vs 737.5M (−17.1%); +18.8M ConsChunk, +5.05M ListBacking;
    same-day interleaved walls ≈ +1%, GC +8 s (12 vs 11 majors), RSS
    +2.5%; flag-on fixed point byte-identical; full E2E 1642/1642.**

    **Slice 2 infrastructure (built, capture pending): scratch-stack
    templates.** Runtime `eco_scratch_mark/push_boxed/push_scalar/finish`
    (RuntimeExports.cpp) — a GC-root-registered growable stack (external
    root scanner, evacuated in minor-GC phase 1d; old-gen compaction has
    no production caller today — if ever wired up, root fixup must be
    added before `freeEvacuatedBuffers`). `finish` builds
    entry[top-1]::…::entry[mark]::next as one chunk (cells when small /
    over-cap / off) and pops to the mark; nesting balances by mark/finish
    discipline. This makes accumulation templates safe WITHOUT §10 builder
    pinning: the growing state lives outside the heap. Backend pass
    `EcoListTemplate` (post-EcoControlFlowToSCF, gated on the
    `eco.list_chunks` attr) rewrites scf.while cons-accumulators
    (conditional chains through scf.if/index_switch/eco.case supported).

    **MEASURED NEGATIVE + architecture correction: the pass captures ZERO
    loops on the full compiler** (4,626 whiles, 15,673 value-typed iter
    args — none accumulate via inline cons). Reason: eco lowers TCO as
    `musttail` self-calls at the MLIR level, NOT scf.while — accumulator
    recursion (foldl specs, `_tail_mono_inline_*`) never materializes as
    a while; acc updates cross `eco.call`(1,611 sites)/`eco.papExtend`
    (1,690) boundaries where the cons lives inside the callee. The
    capture point for templates must therefore be the FUNCTION level
    (self-musttail functions with an accumulator parameter; rewrite
    non-recursive call sites to mark/…/finish; bail when the function is
    papCreate-referenced) or mono-level template generation in
    Functions.elm per the original BytesFusion-precedent design.

    **AS-BUILT slice 3 (Aug 3 2026) — unwind-cons recursion, measured
    NEUTRAL.** EcoListTemplate phase 2 captures functions whose return
    value is a cons chain around a self-call result (the foldr/encoder
    family): pushes are inserted BEFORE the op leading toward the
    recursion on each path (self-call or region op), so pushes run in
    descent order and `eco_scratch_finish_fwd` rebuilds forward
    (entry[mark]::…::rest) at every non-self call site (mark/call/finish
    wrapping; bails on papCreate references, musttail external sites,
    escaping self-call results, and non-dominating heads). 29 of 55
    candidate functions captured, all gates green (byte-identical
    self-compile) — but Cons moved only −149K: recursive encoders yield
    1–3 elements per call, below the ≥4 chunk threshold, so finish takes
    the cells path. Kept (correct, attr-gated, and captures long-chain
    `x :: recurse rest` patterns that other workloads will hit); the
    remaining foldr-family pool is closure-mediated (λ≈7.7 papExtend
    traffic) and stays uncapturable without defunctionalization — the
    U2b/H7 NO-GO precedents apply.

    **AS-BUILT slice 4 (Aug 3 2026) — mixed-spine cursors for compiled
    walks, SHIPPED.** `EcoListCursor` (pipeline slot after EcoToLLVM,
    before the SCF tail conversions — post-GCPrepare, so the per-step ops
    acquire no statepoints or rooting; gated on the module declaring
    `__eco_list_tail_inline`, i.e. chunk-compiled only) rewrites
    list-walking `scf.while` loops to carry (node, idx): head projections
    become `__eco_list_cur*_inline(node, idx)`, the yielded tail becomes
    `__eco_list_step_{node,idx}_inline` pairs, and conditional stepping is
    handled by STEP TREES — `scf.if`/`index_switch` interior nodes on the
    yield chain are rebuilt with one extra i64 result carrying the per-arm
    index (identity arms yield the current index). Emptiness tests stay
    plain get_tag on the node (positions are normalized: idx > 0 only
    inside a chunk with idx < run). Escaping loop results materialize ONE
    view via the new `eco_list_pos_view` runtime export — per exit, not
    per element. All markers expand to pure-load cell-fast/chunk diamonds
    in EcoBackend (`expandListCursorMarkers`), so the cell edge keeps
    today's inline loads exactly. **Captures 3,191 of 4,626 whiles**
    (the rest: non-list value args and non-projection escapes). Measured:
    walk-view churn ConsChunk 41.9M → 26.9M (−15.1M allocations +
    as many statepointed calls removed); total −277.0M objects (−4.28%)
    vs baseline; RSS flag-on now BELOW flag-off (5.38 vs 5.48 GB) for the
    first time; walls remain parity-bound in a ±4% noise window (best
    observed 4:44.13, interleaved means ~+2% — the default-off flip
    criterion is still not met; re-measure in a quiet window). Gates:
    differential identical, ECO_HEAP_VALIDATE clean, flag-on self-compile
    output byte-identical, unit + full E2E green.**

    **AS-BUILT slice 5 (Aug 3 2026) — backward-cursor foldr walks.**
    Kernel side SHIPPED: `alloc::ListBackwardCursor` (HeapHelpers)
    collects spine NODES front-to-back — one entry per cell or chunk
    view, so chunk runs collapse ~1,019× versus per-element copies —
    roots them as contiguous ≤64-entry ranges, and yields elements in
    reverse with per-read re-resolution (fold callbacks may allocate and
    GC freely). Kernel `ListOps::foldr` converted from
    toVector-plus-per-element-roots to this cursor; unit test covers a
    mixed over-cap spine with an ALLOCATING folder (`foldr (::) [] ==
    id`). Compiled side CLOSED NO-GO BY MEASUREMENT: the post-slice-4
    cons-site tally attributes **zero** residual cons to any
    foldr-family symbol (223.4M tallied total — all in the work-stack /
    closure-lambda / encoder pools) — the shunts took `foldr cons`,
    chaining made the >500 `reverse` fallback cheap, and the cursor pass
    de-allocated the `foldl` walk, leaving nothing for a compiled
    foldrHelper rewrite to collect.**

    **Residual-Cons composition (ECO_CONS_SITES return-address tally on
    the flag-on census run; 409M of 611M symbolized):
    `toComparableMonoTypeHelper` 164.6M (40%! — one work-stack loop
    building `List String` comparable type keys; also drives a matching
    Custom pool via WorkItem wrappers); kernel `reverse` small-list
    (n<4) cells fallback ≈61M (LTO-inlined into `List_reverse_$_*`
    specs; irreducible under the ≥4 chunk threshold); long tail of
    lambda/tail-inline sites ≈150M; kernel `append` cells 5.8M,
    `String.split` 5.5M, `map2` 4.8M (L2 Tier-A pool).** Data-ranked
    next targets: (1) function-level accumulator templates (captures
    toComparable's 164.6M + the tail-inline pool), (2) L2 Tier A.
  - **L1 exit gates:** full E2E + elm-tests + Stage 7a fixed point +
    `ECO_HEAP_VALIDATE` clean + census re-run hitting ≈ −350M objects ±
    justification + wall/GC-counts vs master (majors recorded, LSS lesson).
    Default-on only on a clean wall win; else flag-off and record.

    **EXIT GATES RUN + DECISION RECORDED (Aug 2 2026): full E2E
    1642/1642; differential + `ECO_HEAP_VALIDATE` clean; flag-on Stage 7a
    fixed point byte-identical (text AND bytecode legs); census −349.6M
    Cons / −261.9M objects (−4.05%) — the ≈ −350M target met on the Cons
    side, with the object-count shortfall being the added chunk/backing
    objects, exactly as §11.b priced. elm-tests: 13,037/13,049 pass; the
    12 failures are ALL in the typechecker constraint-generator gates
    (golden fingerprints + POST_010 groundedness) belonging to the
    separate typechecker-simplification workstream — their test modules
    reference nothing this plan touched, and the byte-identical self-host
    fixed point independently pins front-end behavior.
    **DECISION: list.chunks stays DEFAULT-OFF.** Walls are at parity
    (interleaved: flag-on ≈ +1–2%, one extra major), not a win — the
    plan's own flip criterion. Revisit after Tier C fusion (§6 L5), the
    first phase expected to move wall time by deleting whole traversals;
    flip requires a replicated, interleaved wall improvement. Invariants
    HEAP_037–040 + CGEN_070/071 recorded in invariants.csv.

    **WALL MEASUREMENT CLOSED (Aug 3 2026, post-cursor, post-foldr):
    sole-job ×3 interleaved under this box's irreducible ambient load —
    off 5:07.3/5:12.7/5:06.3 vs on 5:15.7/5:11.3/5:15.3, i.e. flag-on
    ≈ +1.7%, replicated across all 8 interleaved pairs measured. The gap
    is the extra major GC (12 vs 11 in every single pair — a
    backing-promotion occupancy effect, tunable only at the GC-trigger
    level, out of plan scope); RSS flag-on is LOWER in every pair. Final
    trade at flag-on: −4.28% objects, −47.5% Cons, lower footprint, for
    ~+1.7% wall on the self-compile workload. Default-off stands
    conclusively; re-open only with a different workload class (retention-
    or decode-heavy) or after tuning the major-GC trigger.**
- **L2 — Tier A + owned producers.** Kernel-owned loops (`map2..5`,
  `sortBy`/`sortWith`, `fromArray`), JSON `Decode.list`, `String.split`
  family, list literals ≥ 2 elements, static list globals
  (EcoToLLVMGlobals). Small (measured pool: 17.4M + literals), but each item
  is locality + exact-size wins on hot decode paths. **Plus: chunk chaining
  for over-cap batches in `listFromUnboxables`** (§2.2 as-built note) —
  split ⌈n/maxElems⌉ nursery-sized backings linked via `next`, replacing
  the v1 cell fallback; measured beneficiary: the bytecode writer's ~77K-
  element op lists.

  **TIER-A AS-BUILT (Aug 3 2026):** most of the tier came free — `map2..5`,
  `sortBy`/`sortWith`, `map`/`filter`/`partition`/`unzip`/`intersperse`
  already build through the (now chunk-chain-native) `listFromUnboxables`.
  Newly converted: JSON `DEC_LIST` accumulates on the scratch stack —
  keeping the REVERSE decode order for failure semantics (the reversing
  `eco_scratch_finish` restores logical order; new `eco_scratch_abandon`
  rebalances on a failing element decoder), gated on `eco_g_list_chunks`;
  `listFromPointers` (the `String.split` parts path and every other
  pointer-list builder) and `listFromInts` gained chunk-chain fast paths.
  **List literals and static globals: SKIPPED BY DATA** — the census
  measured `alloc_cons_nil = 0` (no literal-started spines at runtime),
  so there is no pool; recorded rather than built.

  **CHAINING AS-BUILT (Aug 2 2026) — shipped ahead of the rest of Tier A,
  and it landed far bigger than the 77K-list estimate:**
  `alloc::listChunkChain` builds ⌈n/`listBackingMaxElems()`⌉ nursery-born
  backings chained tail-first (remainder in the tail link; every link
  stays strictly under the large-object threshold, preserving the §2.2
  invariant; lens telescope per the len-consistency invariant), with
  `ListChainWriter`/`ListChainReverseWriter` doing allocation-free fills
  after construction. All four producers converted: `listFromUnboxables`,
  kernel `reverse`/`append`/`concat` (the LOT term dropped from
  `chunkEligible`), and `eco_scratch_finish`. With LOT = 8 KB
  (maxElems ≈ 1019), over-cap batches turned out to be COMMON — template
  `finish` accumulations and big module lists, not just the bytecode
  writer. Measured (true census, flag-on self-compile vs baseline):
  **6.212B objects = −261.9M (−4.05%); Cons 387.9M = −349.6M (−47.4%);
  ConsChunk 41.5M; ListBacking 10.6M (avg 277 B); wall 4:49.24 (parity
  band); differential + ECO_HEAP_VALIDATE clean; BYTECODE self-compile —
  the original `fromPointerRaw` over-cap crash scenario — byte-identical;
  two over-cap chain unit tests in ChunkedListTest.** Cumulative Tier-B +
  chaining ≈ the full §11.b −355M Cons-side target.
- **L3 — cons amortization (§10 ladder), census-gated.** Front-slack
  in-place fill + builder-epoch pinning + HEAP_038/040/041 only if the
  post-L1 census shows remaining cell-chain volume worth it (measured
  ceiling today: 19.6M compiled + residual HOF conses — likely NOT worth
  it; record the decision either way, as A4/H7 did).

  **DECISION (Aug 2 2026): NO-GO — closed.** The post-chaining cons-site
  tally decomposes the residual 388M Cons into: `toComparable`'s work
  stack (LIFO push/pop churn — front-slack fill cannot amortize a stack),
  sub-4-element lists (below any chunk threshold by design), and a thin
  lambda tail spread across hundreds of sites. None of these pools wants
  builder-epoch pinning or mutation-under-GC machinery; the scratch stack
  (HEAP_040) already covers incremental building without any §10 heap
  mutation. The §10 ladder and its HEAP_038/040/041 draft rows (as
  originally drafted for slack fill) are retired; the shipped HEAP_038/040
  ids were reused for the as-built nursery-born-backing and scratch-stack
  invariants instead.

- **L4 — full-conversion decision.** Retire cells entirely only if mixed
  spines prove costlier than the census predicts (extra tag dispatch in
  walkers vs +75M backing conversions). Default expectation: **keep hybrid
  permanently**; the census favors it.

  **DECISION (Aug 2 2026): NO-GO for full conversion — hybrid is
  permanent.** Measured basis: `::` as a cell keeps the hot single-prepend
  path a 3-store inline bump alloc (HEAP_034) with a pure-load tail; the
  cells-fast/chunk-escape form of eq/compare costs nothing measurable
  (walls at parity across every gate run); sub-4-element traffic — the
  bulk of list COUNT — would regress under mandatory backings (backing +
  view ≥ cells for n ≤ 3); and full conversion would resurrect the §5.2
  tail-view-per-step problem that hybrid confines to chunk spines only.
  Nothing in the L1/L2 data contradicts the §11.b prediction that favored
  hybrid.
- **L5 — Tier C fusion** (§9.2): adjacent-combinator fusion over the L1
  loop templates, eliminating intermediate lists outright. Census-ranked
  by observed `map∘map` / `foldl∘filter` adjacency; strictly beyond Alm.

  **ADJACENCY CENSUS RUN + DECISION (Aug 3 2026): NO-GO on this
  workload — closed by the phase's own census gate.** Per-function-scoped
  scan of the Stage 7a compiler MLIR (an earlier global-scope scan was
  invalidated by SSA-name collisions across functions — 6,638 apparent
  pairs collapsed to 1,162 real ones): `foldl ∘ reverse` 815 (70% — this
  is `foldrHelper`'s internal >500-element fallback, one site per spec,
  dynamically rare and already chunk-chain-cheap), `append ∘ append` 120,
  `map ∘ map` 44, everything else ≤ 40. There is no high-value fusible
  pool: the textbook lambda-composition engine (mono-level closure
  composition + re-specialization) would target ~44–120 mostly-cold
  sites, while the measured wall profile is dominated by Custom/Closure
  churn and non-list work. A speculative `reverse ∘ reverse → id`
  peephole was implemented, measured against the corrected census (0
  real occurrences), and removed. Revisit only with a workload whose
  adjacency census shows a hot `map∘map`/`fold∘map` pool; the capture
  point then is mono-level composition in GlobalOpt over ListCombinators
  recognition, not MLIR (lambdas are opaque papExtends by then).

Invariants updates (§4.5) land with whichever phase first ships default-on;
the §10-derived rows (HEAP_038/040/041) move to L3.

---

## 7. Risks

| risk | mitigation |
|---|---|
| Old→young edge via in-place fill | HEAP_038 nursery-residency guard; ECO_HEAP_VALIDATE assert on every fill |
| GC traces slack garbage | HEAP_037 `[hd, cap)` rule in every tracer + validator |
| Traversal alloc regression on self-compile | L0 gate before any build; §5.2 cursors; §5.4 fallback scope |
| Allocating `list_tail` breaks statepoint/root assumptions | L1 out-of-line calls first (statepoints come free at call sites); L2 only after liveness audit |
| mapN-style stale cursor bugs (GC moves backings mid-loop) | cursors are (rooted view, index), never raw element pointers; re-derive after every alloc — regression test alongside the existing `kernelListMapN` one |
| Retention via slack/backing sharing | documented; permanent-space trim; future evacuation-trim if census shows it matters |
| Mixed-kind cons (number taint) | runtime kind guard falls back to fresh/boxed chunk; MONO_028 gates already pin the compile-time side |
| Bundle of ~40 touched files destabilizes master | flag-gated (`chunked_lists_enabled=false` ships until L4), same rollback shape as HEAP_032 UTF-8 strings |

## 8. Open questions

1. `eco.construct.list_bulk` op vs C++-side cons-chain collapse for literals
   (lean: explicit op — simpler lowering, visible to census).
2. Keep `!eco.cons` SSA aggregate (non-escaping) or retire it now that
   from_heap can't produce it? (Lean: keep; stack promotion T1.3 wants it.)
3. `CONS_CHUNK_CAP`: Alm uses 8192; eco's nursery sizing and the
   large-object threshold may want smaller — L0 decides.
4. Should `hd` claims survive minor-GC evacuation (copy `hd` verbatim) or be
   frozen on promotion only? (Plan says: verbatim in nursery copies; frozen on
   promotion/permanent — the nursery guard makes promoted `hd` inert anyway.
   §10 revisits this: options B/C make promoted `hd` live again.)

---

## 9. T2 — interning the whole List module (own the representation end-to-end)

Nothing outside the tree constrains this. Once eco owns every producer and
consumer of the type, the *only* binding contracts on a list representation
are:

1. **The `case` cost model** — user code pattern-matches `x :: rest`
   everywhere, so head/tail/isNil must stay cheap. This is what forces a
   view-over-chunks shape (Alm JS) or vector-with-front-slack (Alm wasm
   `T_LIST {len, bk}`) rather than a plain vector.
2. **GC invariants** (§2.3, §10) — the representation must be traceable and
   generation-sound.
3. **Observable Elm semantics** — immutability, structural sharing cost,
   `(==)`/`compare`/`Debug.toString` behavior. All runtime-owned; no user
   code can see chunk boundaries.

Ports/JSON/`toString`/equality are all in-tree kernels; docs and interfaces
are type-level and unchanged. So "replace the module wholesale" is purely an
internal engineering decision.

### 9.1 Mechanism: bundled `List.elm` override

eco already the pattern in every piece: elm/core compiles from a cache the
build controls, `Elm.Kernel.*` references resolve to C++ exports
(`ListExports.cpp`), kernel signatures live in the synced signature files
(memory gotcha: **3 synced places + stale-stage-cache purge**,
`~/.eco/.../eco/kernel`). The move is:

- Ship a bundled override of elm/core's `List.elm` whose exports keep their
  published types but whose bodies route to `Elm.Kernel.List.*` — exactly what
  Alm's `runtime.js:349-470` does with `$List$*`. Type checker, docs, and
  interfaces see the identical module.
- Extend `ListExports.cpp` with the full surface and add
  KernelSigs (borrow modes) + KernelAbi entries per function. Unboxed element
  kinds via the existing suffix-kernel mechanism (`cons_Int/Float/Char`
  precedent, `deriveKernelAbiTypeWith`) — but per-**chunk** dispatch on the
  backing's 2-bit kind hoisted outside the loop is simpler than N suffix
  copies and costs one branch per chunk, not per element. Decide per function.

### 9.2 The tension full kernelization must not ignore: LSS

Alm can kernelize `map`/`filter`/`foldl` freely because its JS closures are
cheap indirect calls either way. **eco cannot**: LSS + $cap-inlining + HOF
elimination (all shipped, −14.5% wall / −99.2% HOF events) mean today's
compiled `List.map f xs` is a *specialized copy with `f` inlined as a direct
call*. A C++ kernel `map` forfeits that: one indirect closure call per
element, un-inlinable forever. For closure-taking combinators, naïve
kernelization trades eco's biggest shipped optimization for loop overhead —
likely a net loss on self-compile.

Hence three tiers, not one:

- **Tier A — C++ chunk kernels for closure-free ops** (no LSS interaction):
  `range`, `repeat`, `reverse`, `append`, `concat`, `intersperse`, `length`,
  `take`, `drop`, `sort`, `unzip`, `member`, `maximum/minimum/sum/product`,
  `fromArray`/`toArray`, plus the already-kernel `map2..5`/`sortBy`/`sortWith`
  rewritten chunk-native. Pure win: array loops, memcpy where kinds allow,
  exact-size preallocation.
- **Tier B — compiler-intrinsic loop templates for the HOF producers**:
  `map`, `filter`, `filterMap`, `indexedMap`, `concatMap`, `foldl`/`foldr`
  when their result feeds a list build, `partition`, `any/all`. Recognized at
  GlobalOpt/MLIR-gen time (BytesFusion is the in-repo precedent for
  call-shape recognition → fused loop emission, `BytesFusion/Reify.elm`), and
  lowered to an `scf.while` over a **chunk cursor** `(backing, index, next)`
  with the per-element body inlined via the existing LSS specialization — so
  the direct-call/inlining win is *kept* and the output is written into a
  preallocated dense chunk. The output backing is GC-rooted during the loop
  via the **builder bit** (`BuilderGuard`, `HeapHelpers.hpp:1098-1176` —
  built for exactly this: JsArray incremental construction) since the inlined
  body may allocate.
  This tier is precisely the "whole-combinator recognition" the
  cons-reduction investigation concluded was the lever.
- **Tier C — fusion laws over Tier B loops**: once `map`/`filter` are loop
  templates, adjacent combinators fuse (`map f (map g xs)`, `foldl` over
  `filter`, `concatMap` chains) and intermediate lists vanish entirely —
  strictly beyond Alm, which fuses nothing. The borrow perf-tune wins
  (hand-fused `++`/`concatMap`/`allRes` walks, −5.1% objects) are the
  measured preview of what automatic fusion buys on the compiler itself.

`foldl` whose result is *not* a list stays compiled Elm (Tier B only when
recognition is free); there is nothing chunked about an accumulator.

### 9.3 Representation upgrades an interned module unlocks

With every producer in-tree, the view can carry more than Alm's does. The
32-byte view of §2.2 has a spare u32 next to `offset` — spend it on
**logical length**:

```c
typedef struct {
    Header header;   // Tag_Cons; unboxed bits 1:0 = element kind
    HPointer backing;
    u32 offset;      // o
    u32 len;         // total logical length of this list value
    HPointer next;
} Cons;              // still 32 bytes
```

Walkers treat `len` as authoritative (consume `min(cap−o, remaining)` per
chunk, stop at 0). That buys:

- **`List.length` O(1)** (today O(n), and the compiler calls it).
- **`(==)` early-exit** on length mismatch before any element compare.
- **`take n` O(1)**: same backing/offset/next, `len = n`. **`drop n`
  O(chunk-hops)**: view arithmetic. `splitAt` — both. (Today all O(n) with
  O(n) allocation for `take`.)
- **Exact-size preallocation** for `map`/`append`/`reverse`/`toArray` — one
  dense chunk, no geometric slack waste.
- `append xs ys` of same-kind unboxed chunks = memcpy of `xs` + shared tail.
- `cons` computes `len = tail.len + 1` — one extra load on the fast path.

New invariant: `len ≤ (cap − o) + next.len` — checked under
`ECO_HEAP_VALIDATE`.

A shared C++ `ChunkCursor` helper (rooted view + index, GC-safe re-derivation
after every alloc — the `kernelListMapN` stale-cursor lesson baked into the
type) becomes the iteration protocol for every *other* kernel that walks
lists: `Dict.fromList/toList`, `String.join/split/fromList`, JSON
encode/decode, virtual-dom.

### 9.4 Phasing amendment — superseded

*(Historical: this section originally slotted Tier A at L3 and Tier B at
L5. The L0 census (§11) inverted that — Tier B carries the entire win —
and §6 was restructured Aug 2 2026: Tier B **is** L1, Tier A is L2, Tier C
is L5. See §6 for the current phasing; each tier keeps the flag-off
rollback and the same gates.)*

---

## 10. Backing-generation policy — lifting the nursery-residency limit

**Status: deferred out of v1 (moved to phase L3, census-gated) by the §6
restructure.** Under hybrid spines (§6), chunks are built whole and
immutable — no in-place slack fill exists, so nothing in this section is a
v1 prerequisite. It becomes relevant only if L3's census says cons-chain
amortization is worth building. Retained in full as the design for that
decision.

§2.3(a)'s nursery-only fill guard is correct but pessimistic. Failure mode
analysis first: a **fast fill** (list built in a tight loop) completes within
a GC cycle or two and never notices the guard. The loser is the **slow
accumulator** — a list consed a few elements per minor GC across many cycles
(fold over a long computation that allocates in between). Its backing gets
promoted at age 3, after which (v1 rules) every cons opens a fresh chunk, and
worse, geometric sizing means each abandoned chunk promotes with huge
uninitialized slack → old-gen bloat that today's cons cells don't have.

Options, in increasing order of GC-doctrine change:

### 10.A Builder-bit pinning with epoch eviction (the "survive longer" option)

The mechanism already exists: `Header.builder == 1` ⇒ evacuated but never
aged, never promoted (HEAP_BUILDER_002, `Heap.hpp:135-152`). Mark a backing
`builder=1` while it has unclaimed slack (`hd > 0`). The missing piece is
**eviction** — a list nobody conses again would squat in the nursery forever.
Use the spare `_pad` u32 in the backing as `lastFillEpoch` (minor-GC counter,
already tracked by GCStats): the cons fast path stamps it; minor-GC
evacuation clears `builder` on any backing whose `lastFillEpoch <
currentEpoch` (not filled since the last GC ⇒ start aging normally). One
store per fill on the same cache line as `hd`; zero cost to everything else.

Two companions:

- **Small-cap degradation**: when the fast path fails because the tail's
  backing is non-nursery, open a cap-8 chunk instead of geometric — the
  geometric credit belongs to actively-filling lists. A degraded slow
  accumulator then costs ≈ today's cons cells, never worse.
- **Nursery-pressure accounting**: builder-pinned bytes count toward the
  occupancy/grow heuristic (NurserySpace step 4) so pinned chunks can't
  starve the nursery; optionally cap builder treatment at a max chunk size.

Verdict: cheap, uses shipped machinery, captures every actively-built list
regardless of how many GCs the build spans. **Recommended for v1.**

### 10.B Separate space / pinned bodies — total freedom for unboxed kinds

A dedicated arena for backings only works barrier-free if the GC never needs
to find young pointers through it. That is exactly true for **pointer-free
backings** — element kind 01/10/11 (Int/Float/Char). eco already has the
pattern shipped: the split-header large-body form (`Tag_LargeByteHeader`,
HEAP_026 — header in nursery, pointer-free body in old gen, **never copied**).
Apply it verbatim: `Tag_LargeListBacking` = nursery header
`{hd, kind, cap, body*}` over an old-gen scalar body. Consequences:

- In-place fill into the body is safe in **any** generation — the body is
  untraced and contains no pointers, precisely like string/byte bodies.
  The nursery-residency guard *disappears* for `List Int/Float/Char`.
- Backing bodies are never memcpy'd by minor GC again (today's §2.3
  evacuation copies the whole chunk incl. slack).
- The census memory note that `resultAliases` went `List Int` is the hint
  that compiler-hot scalar lists exist; L0 measures how much weight this
  carve-out carries.

For **boxed** element kinds a separate space buys nothing by itself — young
pointers stored into it still need discovery, which means a remembered set,
which is option C. So "separate heap space" resolves to: *split-header pinned
bodies for scalar kinds* (do it), *not* a general arena.

### 10.C Scoped single-site remembered set (boxed backings, full generality)

The doctrine "no write barrier needed" (`NurserySpace.cpp:26`) survives
because eco's heap is immutable *except* at enumerable kernel-owned sites
(MVar state, manager arrays — already handled as explicit GC roots). The
chunk fill is **one more enumerable site**: the only code that ever stores a
pointer into an existing backing is the cons fast path. That admits a
remembered set without a general barrier:

- Backing gains `hdAtLastGC` (u32, shares the pad word budget with 10.A's
  epoch — 10.C subsumes it). On a fill where the backing is non-nursery and
  `hd == hdAtLastGC` (first fill this cycle), push the backing onto a
  per-thread dirty-backings vector in the RootSet.
- Minor GC scans, for each dirty backing, exactly `[hd, hdAtLastGC)` — the
  slots filled since the last GC — as roots, then resets `hdAtLastGC = hd`
  and clears the vector. Precise, bounded by mutation volume, zero cost when
  no old backing is filled.

This is a real (if surgical) amendment to the no-write-barrier invariant —
NurserySpace.cpp:26's comment, HEAP_038, and the theory note all get
rewritten to "no *untracked* old→young pointers". Highest power: full
in-place amortization for boxed lists across any lifetime. Also the only
option that makes promoted `hd` live again (§8 Q4).

### 10.D Promotion-trim (orthogonal; kills slack bloat)

When promoting a backing with `hd > 0`, copy only `[hd, cap)` and record the
rebase delta alongside the forwarding pointer (backing headers have room:
forward word + delta); views evacuated in the same cycle adjust `o -= delta`
when they chase the forward. Cheney order doesn't matter since the delta is
retrievable from the forwarded header for the whole cycle. Old gen then never
holds uninitialized slack. Pairs naturally with 10.A's small-cap rule; not
needed at all under 10.B (scalar bodies) since those are allocated
exact-or-slacked out of the copying path entirely — apply it to boxed
promotions only.

### 10.5 Recommendation ladder

1. **v1 = 10.A + small-cap degradation** — no GC-doctrine change, never worse
   than today, covers all actively-built lists.
2. **v1.5 = 10.B for kinds 01/10/11** — shipped pattern reuse; scalar lists
   escape the constraint entirely.
3. **v2 = 10.C** if L0/L4 census shows boxed slow-accumulator weight
   (dirty-backing count and would-have-degraded rate are one counter each in
   the census build).
4. **10.D** rides along with whichever of 10.A/10.C ships, boxed kinds only.

Invariant work: new **HEAP_040** (builder-epoch eviction rule), **HEAP_041**
(dirty-backing remembered set: single producer site, scan window
`[hd, hdAtLastGC)`, reset discipline), amend **HEAP_038** per the ladder
stage, amend HEAP_026 notes for `Tag_LargeListBacking`.

---

## 11. L0 census — RESULTS AND VERDICT (measured Aug 2, 2026)

Workload: Stage 7a self-compile (`Terminal/Main.elm --optimize`,
solver/all-keyed, warm `~/.eco`), instrumented candidate lowered from
`bench-clean.mlir` with `ECO_LIST_CENSUS=1 ECO_INLINE_ALLOC=0` (§5.1
as-built). Two runs: run 1 cold-ish (deps re-verified; 5.92B objects), run 3
warm (4.91B objects — the standing-baseline shape; 3:57 wall / 6.6 GB RSS
under census overhead). Verdict numbers use run 3. Cross-check: total cons
682.8M (run 1) matches the standing true-alloc profile (~678M = 10.4% of
6.52B) — the counters are consistent with the census of record.

### Measured (run 3, warm)

| counter | value | meaning |
|---|---:|---|
| `head` | 446,279,600 | compiled list_head projections |
| `tail` | 412,241,247 | compiled list_tail projections |
| `tail_nonnil` | 305,337,405 | tails returning non-Nil = **would-alloc upper bound** |
| `kernel_cons` | 515,387,975 | alloc::cons from C++ (all callers) |
| `hof_cons` | **497,999,680** | subset: `Elm_Kernel_List_cons(+_Int/…)` — `::` as a function value from Elm-driven HOF loops |
| kernel-owned loop cons | **17,388,295** | `kernel_cons − hof_cons` — the ONLY Tier-A bulk-savable pool |
| `alloc_cons` (compiled `::`) | 19,607,048 | accumulator prepends; `alloc_cons_nil=0` |
| list starts (`kernel_cons_nil`/`hof_cons_nil`) | 70.3M / 64.9M | avg chain length λ: 7.3 overall, **7.7 HOF**, 3.2 kernel-owned |
| total cons | 535.0M | **10.9%** of 4.91B objects |

### The decisive fact

**96.6% of "kernel" cons volume is not kernel-owned.** eco's own HOF
machinery (LSS, HOF-elimination) drives `foldl cons`-shaped loops from
compiled code and calls the `::` kernel per element. Only 17.4M conses
(3.4%) come from loops a C++ kernel owns end-to-end — so §5.4's
"bulk chunks where kernels own both ends" carve-out addresses almost
nothing, and Alm's headline mechanism (kernelized bulk builders) has no
existing pool to collapse in eco.

### First-order arithmetic (per §5.1 decision rule)

v1 = Alm-exact representation, no Tier B, no cursors (views 1:1 with cells,
+8B each; cons-grown backings ≈ 1/chain at λ≈7.3 with cap-8 first chunks;
tail views at the measured upper bound):

    Δobjects ≈ +75M backings + 305M tail views − 6.6M Tier-A savings
             ≈ **+373M objects (+7.6%)**
    Δbytes   ≈ +17.1GB views + 9.8GB tail views + 5.5GB backings − 12.8GB cells
             ≈ **+19.6GB (+10.7% churn)**

**v1 verdict: NO-GO.** The exact Alm scheme, bolted onto eco's
compiled-from-source List module, is an unambiguous allocation regression.

With **Tier B** (§9.2 combinator loop templates) collapsing the HOF pool
(498M conses → 64.9M lists × ~2 objects) plus compiled/kernel-owned pools:

    Δobjects ≈ (1−f)·305M − 375M      (f = cursor coverage of tail views, §5.2)
             ≈ −70M (−1.4%) at f=0 … −161M (−3.3%) at f=0.7

**Conditional GO.** Chunks and Tier B are complementary, not separable:
Tier B on cons cells saves closure-call overhead but no allocation (a bulk
build needs a chunk to build into); chunks without Tier B regress. Together
they remove ~370M allocations plus the unquantified-here locality, spine-GC,
and O(1)-length wins.

### Consequences for phasing (now enacted — §6 was restructured accordingly)

1. **The representation must not ship standalone** — the phase gates would
   correctly reject it (+7.6% alone, +1.8% even with cursors).
2. **Tier B (§9.2) is the L1 deliverable** (§6): the first default-on
   candidate is hybrid chunks + Tier-B loop templates for the `foldl cons`
   family (reverse/append shapes — 93% of cons volume at λ=7.7).
3. §5.2 cursor coverage `f` — **measured, static §11.a and dynamic §11.b**:
   44.0% of list_tail sites are inside `scf.while`, but those sites carry
   **93.6% of would-alloc tail executions** (f_dyn = 0.936). The tail-view
   risk that drove the v1 NO-GO is a measured 19.4M residual (0.4% of
   objects). Final band: **−7.2% of all allocations** with Tier B (§11.b);
   **−7.24%** under §6's hybrid spines, with `::` untouched.
4. §10 options A–D gate cons-chain fill amortization only; under hybrid
   spines that is optional follow-up work — deferred to L3, census-gated.

Instrumentation left in-tree, all inert without `ECO_LIST_CENSUS=1` at
lowering time except five unconditional counter increments on already-
out-of-line paths: `RuntimeExports.cpp` (`eco_list_census[12]` + reporter +
cons-export bumps), `HeapHelpers.hpp` (`alloc::cons`),
`ListExports.cpp` (HOF-cons split), `EcoToLLVMHeap.cpp` /
`EcoToLLVMRuntime.cpp` / `EcoToLLVMInternal.h` (census call emission).
Logs: `/tmp/list-census-run{,3}.log`.

### 11.a Static cursor coverage `f` (measured Aug 2, 2026)

Tool: `benchmarks/list-tail-coverage.py` over the generic-form text MLIR of
the self-host module (`eco make --optimize --text-mlir …` — bytecode `.mlir`
must be regenerated as text first). Region tracking is brace-depth based;
`scf.while` survives into the backend input, so "inside a while" is exactly
the TailRec loop shape §5.2 cursors address. Module: 69,018 functions,
4,620 `scf.while` ops, 8,019 `list_tail` sites (head sites mirror at 44.0%).

| pool | sites | share | §5.2 cursor | Tier B |
|---|---:|---:|:--:|:--:|
| inside `scf.while` (TailRec loops) | 3,531 | **44.0%** | ✓ | (✓) |
| foldr family (`foldrHelper` 3,260 = 815 specs × 4-way unroll; `takeFast` 255) | 3,515 | 43.8% | ✗ | ✓ backward cursor over dense chunk |
| remainder (bounded fixed-shape destructure probes: KernelAbi/Intrinsics/BytesFusion big cases, misc) | 973 | 12.1% | ✗ | ✗ |

Structural findings:

- **The outside-while pool is essentially foldr.** elm/core's non-TCO
  4-way-unrolled `foldrHelper` is 72.6% of it. A dense chunk makes foldr a
  *backward* cursor walk (no views, no recursion depth games), so Tier B
  covers it naturally — foldr is already on the Tier-B producer list.
- **`List_foldl` alone is 1,939 specializations, each one `scf.while` with
  exactly one tail site** — 55% of the cursorable pool. Fold combinators are
  2,754 of 8,019 sites (34%) by themselves; adding `any`/`take`/`drop`/
  `takeReverse`/`member`-shaped elm/core loops, the List module's
  combinators own the large majority of all traversal sites — independent
  confirmation of §9's premise that interning ~a dozen combinators covers
  almost all list traversal in the compiler.
- The unaddressed 12.1% is dominated by bounded per-probe destructuring
  (`case args of [a, b, c] -> …` in codegen-phase functions), not
  per-element walks.

Site-shares were initially used as a proxy for dynamic `f`; **superseded by
the direct dynamic measurement in §11.b** (site-share badly *understated*
loop coverage: 44% of sites carry 94% of would-alloc executions).

### 11.b Dynamic cursor coverage `f` (measured Aug 2, 2026 — run 4)

Mechanism: at EcoToLLVM entry — before any conversion, while the
front-end's `scf.while` structure is intact — every `eco.project.list_tail`
inside a while gets an `eco.census_loop` UnitAttr (`EcoToLLVM.cpp`, gated on
`ECO_LIST_CENSUS`); `ListTailOpLowering` routes tagged sites to
`eco_census_list_tail_loop` (counters [12]/[13]). Same workload as run 3.

**Determinism check:** run 4 reproduced run 3 exactly — 4,905,774,191
objects and every cons counter identical; the two tail halves sum to run 3's
totals to the last digit (48,726,567 + 363,514,680 = 412,241,247 executions;
19,414,205 + 285,923,200 = 305,337,405 non-Nil).

| tail pool | executions | share | non-Nil (would-alloc) |
|---|---:|---:|---:|
| `scf.while`-context sites (3,531 static) | 363,514,680 | 88.2% | 285,923,200 |
| non-loop sites (4,488 static) | 48,726,567 | 11.8% | 19,414,205 |

**f_dyn = 285.9M / 305.3M = 93.6%.** Dynamic weighting inverts §11.a's
static picture: the loop sites (`List.foldl`'s 1,939 one-tail whiles above
all) dominate execution, while the static-majority non-loop pool
(foldr-family + destructure probes) executes only 48.7M tails — with a 60%
Nil rate (short-list probes), leaving 19.4M residual would-alloc views,
**0.4% of all objects**. The §11 worst case largely evaporates even before
Tier B; Tier B's backward-cursor foldr absorbs part of the residual too.

### Updated arithmetic (measured f_dyn, run-3/4 workload = 4.91B objects)

    cursors only, NO Tier B:
      Δobjects ≈ +75M backings + 19.4M tail views − 6.6M Tier-A
               ≈ +88M (+1.8%) — still NO-GO alone (backing adds dominate)

    chunks + cursors + Tier B:
      new objects ≈ 129.8M (HOF pool: 64.9M lists × view+backing)
                  + 22.1M (compiled views + amortized backings)
                  + 10.8M (kernel-owned bulk) + 19.4M (residual tail views)
                  = 182.1M   vs   535.0M cells removed
      Δobjects ≈ **−353M (−7.2% of all allocations)**
      Δbytes   ≈ 8.9GB added vs 12.8GB cells removed ≈ **−3.9GB (−2.1%)**

### Consolidated verdict (all L0 measurements)

| configuration | Δobjects | verdict |
|---|---:|---|
| v1: Alm-exact scheme alone | **+373M (+7.6%)** | NO-GO |
| v1 + §5.2 cursors (f_dyn=0.936) | +88M (+1.8%) | NO-GO alone |
| chunks + cursors + Tier B | **−353M (−7.2%)**, bytes −2.1% | **GO** |

The census chain is internally consistent three ways: total cons 682.8M
(run 1, cold) matches the standing 6.52B profile's ~678M; run 3 vs run 4
replicate byte-identically; and the static site census (§11.a) partitions
exactly into the dynamic execution split (§11.b). The GO is conditional on
Tier B exactly as §11 concluded — now with the tail-view risk quantified
at 0.4% and the payoff at ≈ −7% of all allocations, plus the unquantified
locality, spine-GC, and O(1)-length wins.
