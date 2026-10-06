# Intern hash table and integer global ids

Date: 2026-09-30. Status: **planned, nothing implemented.** Line numbers are from the tree of this
date. Functions are named as well, because lines drift.

Three tracks, each split into steps that are measured one at a time:

- **Track H: an `Array`-backed hash table used only by `Compiler.AST.Intern`.** H0 fixes a leak in
  Intern's widen memo. H1 adds `Data.HashTable` and moves both Intern tables onto it.
  `Data.HashMap` and every other caller are left alone.
- **Track G: stop hashing and string-rendering `TOpt.Global` keys on the solver's hot paths.** G0
  removes a string build that runs on every signature lookup. G1 gives every global a dense integer
  id with precomputed facts. G2 re-keys the signature and scheme memos by id and threads the id
  down the call-translation path. G3 re-keys the per-item node resolution and the spec tallies.
- **Track C: `Data.HashMap` reimplemented as a pure-Elm CHAMP** (Compressed Hash-Array Mapped
  Prefix-tree; Steindorfer & Vinju, OOPSLA 2015). Its API and contracts, including
  insertion-ordered iteration, are unchanged, so no caller changes.
  - C0 adds host-independent 32-bit bit helpers (`Data.Bits32`), pinned on both JS and native.
  - C1 swaps `Data.HashMap`'s internals: a linear small-map form for up to 8 entries, then a CHAMP
    trie.
  - C2 puts Intern on the CHAMP `HashMap` and compares it against H1, to decide whether
    `Data.HashTable` should stay.
  - C3 keeps the trie logic in Elm and moves only its hot primitives out of pure Elm, **using
    kernel calls and existing `eco.array.*` ops only. Nothing is added to the eco dialect**
    (decided 2026-09-30). It has four sub-steps:
    - C3.0 makes `Eco.Hash`'s kernels gc-leaf, as its doc already claims.
    - C3a turns popcount into a gc-leaf kernel call.
    - C3b adds `Eco.NodeArray`, a node array with no `Array` wrapper whose read allocates no
      `Just`. It is built on elm/core's `JsArray` kernel.
    - C3c turns insert-at and remove-at into single-allocation kernel calls.

The measurement loop is the one in `benchmarks/lss-compile-opt-loop.md` §1. Results are recorded
there as entries `H0`, `H1`, `G0`–`G3`, `C1`–`C2` and `C3.0`, `C3a`–`C3c` (§13 below; C0 is not
timed).

Contents: §0 prior results this plan builds on · §1 findings that shape the design · §2 the steps ·
§3 H0 · §4 H1 · §5 G0 · §6 G1 · §7 G2 · §8 G3 · §9 C0 · §10 C1 · §11 C2 · §12 C3 · §13 measurement and
gates · §14 deliberately not done · §15 documentation to update.

---

## 0. Prior results this plan builds on

| What | Where | Outcome and lesson |
|---|---|---|
| Step 17: every `Data.HashMap` onto an `Array` of buckets | `benchmarks/lss-compile-opt-loop.md:861` | **LOSS**, +1.01 s, +25 minor GCs. Most HashMaps are small, short-lived per-item tables. For those, a 64-slot `Array.repeat` at construction plus a 32-wide node copy per `Array.set` outweighed the saving on the one big table (Intern). The Intern-only effect was never isolated. That is Track H. |
| Step 2: O(arity) hash-cons equality | loop `:359` | **WIN**, −10.71 s. Intern's equality check fell from about 20 % inclusive to 0.5 %. What remains in `Intern.probe` is the bucket lookup and the probe count. |
| Step 11b: widen memo in Intern | loop `:598` | **WIN**, −11.07 s. It introduced the second Intern table and the `entries` write-back guard. |
| Step 12 (surgical): key `lssSignatures` by `Global` | loop `:748` | **LOSS** while `globalHash` was an Elm `String.foldl`. |
| 12s: the same with native `Eco.Hash` | loop `:1433` | **WIN**, −2.51 s. |
| Entry 27, 24(iii)+(iv) | loop `:777`, `:1012` | **LOSS**. "Every hashing step that HAS won hashes something carrying a precomputed integer." |
| 21a: `BitSet` twin | loop `:1048` | **LOSS**. `BitSet.member` does not beat a small `Dict Int` descent. |
| Old step 12 spec (dense `GlobalId`) | `plans/lss-compile-time-optimizations.md:5715-6086` | Never built. The loop's summary (`:1791`, `:1824`) lists "12 and 13 in full" as the strongest unbuilt idea. Track G replaces that spec (§15). |
| "Dict→HAMT" closed avenue | `design_docs/kernel-boundary-reduction.md:347` | Replacing core `Dict` with a HAMT was rejected: `Dict` must iterate in key order, a codegen-order incident showed that order leaks into output, and the comparison ceiling was ≤ 1.94 %. Track C does not touch `Dict`. It replaces `Data.HashMap`, whose contract is insertion order, and C1 keeps that contract exactly. |
| K4 codegen-order bug | `plans/mono-comparable-key-optimization.md` §11 | Hash-ordered iteration of a `HashMap` broke an emission path. That is why `Data.HashMap` iterates in insertion order (sequence numbers plus a sort on fold). C1 keeps it. |

All these numbers predate the threaded-GC series (2026-09-25 onward). §13 therefore starts with a
new series baseline.

## 1. Findings that shape the design

### 1.1 Intern's tables (`compiler/src/Compiler/AST/Intern.elm`)

- **Two tables.** Both are `HashMap`s in each of the `Intern` and `ReadOnly` constructors
  (`Intern.elm:72-75`):
  - **m**, `HashMap Canon MonoType`, the node table. It is probed with
    `getBy Mono.specHashOf eqExactAgainst` (`probe` 232-239, `probeRO` 249-256) and inserted into
    with `insert canonHash canonEq` on a miss (239).
  - **w**, `HashMap MonoType MonoType`, the widen memo. It uses `get`/`insert` with
    `Mono.specHashOf` and `widenEq` (`widenSets` 448-471, `putWiden` 484-491).
- **Insert-only, never iterated.** No `remove`, `foldl`, `toList` or `values` is ever called.
  - `size` has no caller in `compiler/src`; only tests use it.
  - `entries` (404-414) returns `size m + size w`. Its only users are the write-back guards
    `Engine.withIntern` (`Engine.elm:2846`) and `Store.consC` (`Store.elm:2396`). They rely on
    "both tables only ever grow, so equal counts imply the same value".
  - **Table order therefore cannot reach the output.** The one visible choice is which object is
    canonical: the first one inserted wins. Any insert-only table keeps that.
- **A persistent structure is required.** The default path uses the table linearly, but three
  places reuse an older version after a newer one exists:
  - `Store.rezonkSettled` (`Store.elm:2586-2660`, report mode only) forks from `s.intern` at 2627
    and deliberately drops the grown copy (comment at 2646). LSS_035 relies on this read-only
    discipline.
  - The subst engine discards a fork at `Specialize.elm:3524` and recomputes at 3561.
  - The unit tests reuse table values freely (`ComparableKeyEncodingTest.elm` 161-257).
  - A `Data.HashTable` built on `Array` is persistent by construction, since `Array.set` copies the
    path. Nothing here needs a mutable kernel table, and HEAP_005 would make one expensive
    (off-heap storage plus an external root scanner, as with `Eco.CellStore`).
- **One lineage per run.** The solver creates the table once, in `Monomorphize.initState`
  (`MonoSolver/Monomorphize.elm:3927`); the subst engine does so in `State.elm:363`. It is not
  created per item or per module. Step 17's failure mode, many small short-lived tables, does not
  apply.
- **Sizes and traffic** (censuses from 2026-08-05, before steps 4a/4b; treat as orders of
  magnitude):
  - The solver made about 18.4 M composite constructions for about 163 K distinct types
    (`plans/mono-comparable-key-optimization.md` §15, 814-826).
  - `hashCons` was called 13.7 M times with a 98.98 % hit rate (§16, 1001-1010). That implies
    roughly 140 K rows in m.
  - Those distinct counts were measured by the spec key. Intern uses exact `==`, which separates
    MVar ids and `LTop` kinds, so m may be larger.
  - The size of w has never been measured. It has about 141 K top-level calls per run.

### 1.2 The widen memo memoises leaves, against its own comment

The comment at `Intern.elm:453` says "Leaves and `MVar` are the identity and never enter the
memo". The code does not filter:
- `widenSets` probes w for every node it is handed, including every leaf child reached through
  `widenList` and the record fold.
- On a miss, `widenSetsGo` returns the leaf unchanged (the `_ ->` arm at 544), and `putWiden`
  inserts it.
- Every `MVar _ CEcoValue` hashes to 7 and every `MVar _ CNumber` to 1, the same as `MInt`
  (`Monomorphized.elm` `leafKeyTag` 375-405).
- `widenEq` is `==`, so each distinct MVar id is its own key.

As a result, one `Dict` bucket collects every distinct `MVar` seen, and each leaf probe scans that
list with `==`. Its length has never been measured. H0 removes it. The plan's original design did
filter leaves (`plans/lss-compile-time-optimizations.md:5415-5423`); the version that shipped does
not.

### 1.3 Hash properties (`Compiler/AST/Monomorphized.elm`)

- **Range.** `specHashOf` (351-369) is in `[0, 2^26)` for composites and is 1–7 for leaves. It is
  never negative.
- **Mixing.** `mixHash h x = modBy hashBase (h * 33 + modBy hashBase x + 7)` (319-321), with
  `hashBase = 2^26`. This is a polynomial with multiplier 33:
  - The low k bits depend only on the low k bits of the inputs.
  - Because 33 ≡ 1 (mod 32), bits 0–4 are an order-insensitive sum.
  - `mCustom` hashes name LENGTHS only, so `Maybe.Maybe` and `Array.Array` collide in full. The
    equality check resolves that.
- **Simulation (synthetic).** A simulation of this construction over 163 K invented types put
  linear-probing cost within 2 % of a random-oracle hash when indexing with a plain mask. The
  script is session scratch: `/tmp/hashtable-plan/intern/sim.py`.
- **Consequence for the design:**
  - Index with `Bitwise.and mask h`. On both hosts (JS 32-bit, native `and_` on int64,
    `elm-kernel-cpp/src/core/Bitwise.cpp`) that gives identical slots for `h < 2^31`.
  - Keep a one-line `spread` hook for a finaliser, chosen by the H1 census (§4.5).
  - Store the full hash in each entry, so entries that merely share a slot are rejected by an
    `Int` compare.

### 1.4 What `Array` costs in this runtime

- `Array` is elm/core's persistent 32-way tree with a tail
  (`~/.eco/0.1.1/packages/elm/core/1.0.5/src/Array.elm`).
- Its element operations `JsArray.unsafeGet`/`unsafeSet` are intrinsics lowered to
  `eco.array.get`/`eco.array.set` (`Generate/MLIR/Intrinsics.elm` 238-243 and 946;
  `runtime/src/codegen/Ops.td:1042,1066`). They are not kernel calls.
- For 2^18 slots, `Array.get` is a bounds check, a tail test and 4 levels of inline loads, and it
  allocates the `Just` it returns.
- `Array.set` copies about 4 nodes of at most 32 slots each. That is roughly as many words as
  `Dict.insert`'s ~18-node path copy, but in 4 objects instead of about 18.
- A `Dict Int` lookup over 140 K buckets is an ~18-level descent with an `Int` compare at each
  level.
- **So the win is on the ~99 %-hit lookup path.** The insert path is about neutral in bytes and
  better in objects retained.

### 1.5 No global has an integer identity today

- `TOpt.Global = Global ModuleName.Canonical Name` (`TypedOptimized.elm:293-294`) carries only
  strings. No hash is cached on it: `TOpt.globalHash` (330-351) runs `Eco.Hash.string64` over the
  name on every probe.
- Occurrences (`TOpt.Meta = { tipe, tvar }`, 135-138) carry no id.
- The only `globalIndex` in the tree is `Borrow.globalIndex`, which is post-mono and keyed by
  string.

So "stop hashing keys that already have an integer identity" means: **mint the identity once (G1),
then use it (G2, G3).** Every map keyed by an existing integer id (`MVarId`, `SpecId`, `LambdaId`,
`ArrowId`, Point) is already a `Dict Int` or an `Array`, not hashed.

Per translated global call today (from the code, `Translate.elm` 1843-3260 and `LssInfer.elm`):
1. One `Env.annotations` lookup through `Data.Map` (`lookupAnnotation`, T:7595-7597). That
   rebuilds `TOpt.toComparableGlobal`, a 5-part string concat, and then descends a `Dict String`.
2. Two `signatureFor` calls (`lssFastOk` T:2754, `instantiateLss` T:4795 → L:127). Each builds
   `gkey = TOpt.toComparableGlobal global` eagerly (L:82-85), even on a memo hit, and then does a
   HashMap probe. That is about 10^6 string builds per run (loop `:764`).
3. `declaredArityOf global 8` (`needsPapSlow`, T:2737): one `toptNodes` probe per `Link` hop.
4. On the fast path, `cachedSchemeMono (TOpt.toComparableGlobal global)` (T:2965): another string
   build plus a `Dict String` descent.
5. Per `enqueueSpecKeyed` (about 141 K per run): a 7-part `Mono.toComparableGlobal` build plus a
   `Dict String` descent into `specCountByGlobal` (Engine.elm 2319-2323).
6. Per item (about 43 K per run): a string build plus a `Dict String` descent into
   `nodeResolution` (`resolveGlobalNode`, M:4592-4598).
7. Per walked call in inference (`applyCalleeAt`, L:1659-1668):
   - another `Data.Map` annotation probe (`sigSourceTypeFor`, L:249-251);
   - a dead `gkey` string build (L:1661-1662; the binding is never read);
   - an `lssInProgress` probe.

### 1.6 Constraints

- **Stock Elm.** `compiler/src` also builds under stock Elm 0.19.1, for bootstrap stage 1 and
  elm-test-rs (`compiler/elm.json` source-directories `["src","src-xhr"]`). New modules there may
  import only elm/core and friends, not kernel modules. A pure `Array` table needs nothing else.
- **Record cap.** A record may have at most 32 fields: `RecordConstructOp::verify`,
  `runtime/src/codegen/EcoOps.cpp:450-456`. The comments in Engine that say `S` is "at the cap"
  overstate it by one.
  - `S` has 31 fields, `Env` 14, `ItemAux` 15, `MonoMemo` 3.
  - **This plan adds no field to `S`.** `Env` gains at most one; it is immutable and only
    referenced from `S`, so updates to `S` never copy it.
- **Byte identity.** Every step here is meant to be BI: the candidate compiler emits
  byte-identical MLIR. Where an id-indexed structure replaces a string-ordered or insertion-ordered
  one, ids are minted in ascending `TOpt.toComparableGlobal` order. That is `Data.Map.foldl`'s
  order: it folds the underlying `Dict comparable` (`Data/Map.elm:240-242`), and `toptNodes`
  already inherits that order today (M:3933-3937).
- **Invariants checked:**
  - HEAP_005: pure Elm, no mutation.
  - LSS_035: the `rezonkSettled` rollback needs persistence, which is kept.
  - The record cap above.
  - Tracks H, G and C0–C2 touch none of the REP_*, CGEN_* or HEAP_* invariants: no codegen or
    runtime change.
  - **C3 does touch codegen and kernels.** It relies on:
    - CGEN_072(f): gc-leaf only through `KernelFacts`;
    - KERNEL_FACTS_001: an evidence anchor per row;
    - TYPE_KERNEL_001: annotated wrappers;
    - REP_ABI_001: Int as `i64` at the kernel ABI;
    - HEAP_SNAPSHOT_001: kernels write only fresh arrays;
    - HEAP_034: allocation via `allocArray`, not the inline bump;
    - HEAP_062: node arrays are far below the large-object threshold;
    - LSS_004/LSS_022: `KernelSetFacts` rows for new kernels.

    §12 cites each where it applies. **No eco dialect op is added.**

### 1.7 `Bitwise` is 32-bit under JS and 64-bit natively (Track C)

- **Elm specifies 32-bit bitwise operations, and JS implements them that way.** That covers stock
  Elm, bootstrap stages 1–2 and elm-test-rs.
- **Eco's native backend is 64-bit, on purpose.**
  - `and`, `or`, `xor`, `complement` and the shifts are i64 intrinsics
    (`Generate/MLIR/Intrinsics.elm:599-617`).
  - `shiftRightZfBy` shifts the whole `int64` (`elm-kernel-cpp/src/core/Bitwise.cpp:85-97`).
  - The E2E suite pins it: `test/elm/src/BitwiseLargeShiftTest.elm` expects
    `shiftLeftBy 32 1 == 4294967296`, where JS gives `1`.
- **Two concrete traps follow:**
  - Bit 31 is negative under JS (`shiftLeftBy 31 1 == -2147483648`) and positive natively.
  - A SWAR popcount's final multiply-and-shift keeps bits above 32 natively that JS truncates.
- **Consequence.** Any bit-twiddling data structure that must behave the same on both hosts has to
  keep values in the low 32 bits, test bits only against 0, and mask after arithmetic. C0 packages
  that as `Data.Bits32`.
- **No row in `invariants.csv` records the native width.** §15 suggests one.

## 2. The steps

| Step | What | BI | Depends on | Estimate (to be measured) |
|---|---|---|---|---|
| **H0** | Leaves and `MVar` bypass the widen memo | yes | — | Unknown. It is 0 if w's leaf buckets are short and could be seconds if they are long. The H1 census measures what remains. |
| **H1** | `Data.HashTable` (Array of chains, insert-only, presized); Intern's m and w move onto it; a report-only `intern|` census line | yes | H0 (so the census sizes w after the fix) | Lookup-path only: bounded by the `Dict` share of `Intern.probe`. Pre-step-2 that was `Dict_get` 1.6 % self of the mono window (about 0.8 % of wall); after step 2 it is unmeasured. Expect −0.3 to −1.5 s. |
| **G0** | `signatureFor` builds `gkey` only on its miss and crash paths; delete the dead `gkey` in `applyCalleeAt` | yes | — | About 10^6 25–50-character string builds removed per run. Expect −0.3 to −1 s. |
| **G1** | `GlobalTable` on `Env`: dense ids in string order plus precomputed facts (node, annotation, declared arity, kernel alias); every `toptNodes` and annotation probe goes through it | yes | — | Removes the `Data.Map` string build per translated call and per walked call, and turns `Link`-chasing arity and alias walks into one probe. Expect −1 to −2 s. |
| **G2** | `lssSignatures` and `schemeMono` re-keyed by id (`GlobalMemo`); the id is looked up once in `translateCall` and threaded through the call path | yes | G0, G1 | Per call, about 5 hash or string lookups become 1 hash lookup plus array reads. Expect −1 to −2 s. |
| **G3** | `nodeResolution` and `specCountByGlobal` re-keyed by id | yes | G1 (G2's `GlobalMemo`) | About 43 K + 141 K string builds removed. Expect −0.3 to −1 s. |
| **C0** | `Data.Bits32`: `mask32`, `fragment`, `bitpos`, `below`, `popcount`, host-independent; unit tests (JS) plus an E2E pin (native) | n/a (no caller yet) | — | Not timed. Groundwork, like the loop's `3a`. |
| **C1** | `Data.HashMap` internals become a small-map list (≤ 8 entries) that promotes to a CHAMP trie. The exported API and every contract are unchanged. | yes | C0; run after H1 (see below) | Bounded by `HashMap`'s share of the profile's `Dict` time (6.9 % across all `Dict`s in the latest profile, not split by caller). Tiny maps get cheaper than today (no `Dict` node, `Cons` and `Tuple3` per entry); large maps get ~4-level lookups. Expect −0.5 to −2 s. Watch minor GCs: step 17's +25 is the regression to beat. |
| **C2** | Intern's two tables on the CHAMP `HashMap` instead of `Data.HashTable`, measured against H1 | yes | H1 and C1 both kept | A comparison, not a speed-up. The expectation is that H1 stays faster on Intern's one big table. If CHAMP is within the paired resolution, keep C2 and delete `Data.HashTable`. |
| **C3.0** | `KernelFacts` rows making `Eco.Hash`'s kernels gc-leaf | **no** (adds `eco.gc_leaf` to emitted decls) | — (independent of C1) | Every `TOpt.globalHash`, `aliasKeyOf` and `groundHash` call stops spilling and reloading the caller's live pointers. Unmeasured; expect −0.3 to −1.5 s. |
| **C3a** | `Eco.Bits.popcount32`, a gc-leaf C++ kernel (JS kernel plus pure twin); `Data.Bits32.popcount` delegates to it | **no** | C1 kept | Replaces about 12 inline ALU ops with one out-of-line call. **It may lose** (ghash63 lost this trade); keep it only if it wins. |
| **C3b** | `Eco.NodeArray`: an opaque node array over elm/core's `JsArray` kernel (no new kernel code). `get` without `Maybe`, no `Array` wrapper. `HashMap` switches its node storage to it. | **no** (codegen arm in `Intrinsics.arrayElementType`) | C1 kept | Removes a `Just` per trie level and one object per node array. Expect −0.3 to −1 s on top of C1. |
| **C3c** | `Eco.NodeArray.insertAt`/`removeAt` as allocating C++ kernels (one allocation each) | **no** | C3b kept | Structural edits drop from 4 allocations (C3b's slice, push, slice and append) to 1. Matters for insert-heavy maps only. |

H and G are independent; run them in either order. C must come after H1: then C1's delta covers
only the non-Intern maps (step 17's population), and C2 isolates Intern. Within a track, the order
above holds. The recommended overall order is H0 → H1 → C0 → C1 → C2 → C3b → C3c → C3a, with
Track G and C3.0 interleaved anywhere. C3a comes last because it is the likeliest to lose. Each step is its own loop iteration: build, measure, verdict, and gates only on a win
(§13). A losing step is reverted without touching the others.

## 3. H0: leaves and `MVar` bypass the widen memo

**File:** `compiler/src/Compiler/AST/Intern.elm`.

1. Rename the current `widenSets` body (448-471) to `widenSetsMemo`, keeping its doc comment,
   including the "deliberate divergence" paragraph.
2. Give `widenSets` a new body that dispatches on the node kind:

```elm
widenSets : MonoType -> Intern -> ( MonoType, Intern )
widenSets monoType intern0 =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            widenSetsMemo monoType intern0

        Mono.MList _ _ ->
            widenSetsMemo monoType intern0

        Mono.MTuple _ _ ->
            widenSetsMemo monoType intern0

        Mono.MRecord _ _ ->
            widenSetsMemo monoType intern0

        Mono.MCustom _ _ _ _ ->
            widenSetsMemo monoType intern0

        _ ->
            -- Leaves and `MVar`: widening is the identity (`widenSetsGo`'s
            -- `_ ->` arm), so the memo can only cost. Before H0 every distinct
            -- leaf was memoised, and every `MVar _ CEcoValue` hashes to 7:
            -- one ever-growing bucket scanned with `==` on each leaf probe.
            ( monoType, intern0 )
```

3. In `widenSetsMemo`, update the comment at 450-453 to say that the leaf filter lives in
   `widenSets`.

**Why this is BI.** For a leaf, the old code returned either the input (on a miss) or the
first-seen `==`-equal leaf (on a hit). The new code always returns the input. These differ only in
object identity. The widened type becomes a spec-registry key compared by `Mono.eqKeySpec`, which
has an identity fast path and a structural fallback, so the same keys match. `entries` changes, but
only the write-back guards read it, and they only need "equal ⇒ unchanged", which still holds.

**Tests** (in `compiler/tests/TestLogic/Monomorphize/ComparableKeyEncodingTest.elm`, next to the
K6 widen test at 136):
- `widenSets` of `MInt`, `MString` and 100 distinct `MVar _ CEcoValue` ids returns the input and
  leaves `Intern.entries` unchanged.
- `widenSets` of a composite twice: the second call returns a value `==` to the first, and
  `entries` does not change on the second call.
- The existing K6 test (`Intern.widenSets` agrees with `Mono.widenSets` over the corpus) must
  still pass unchanged.

## 4. H1: `Data.HashTable`, used only by Intern

### 4.1 Design choice: chaining, not open addressing

In a persistent `Array`, an insert costs one `Array.set` whichever scheme is used. The schemes
differ on lookups and on tolerance to bad hashes:

- **Open addressing (linear probing).** Each extra probe is another `Array.get`: a 4-level descent
  plus a `Just` allocation. The simulation (§1.3) puts the average hit at 1.4–1.9 probes at load
  0.46–0.62. The known weakness in the hash's low bits (§1.3) produces clusters, and the `MVar`
  leaves (§1.2) would form one primary cluster if H0 were ever reverted.
- **Chaining with inline links.** A lookup is exactly one `Array.get`, then a walk of a chain of
  `Link` cells. Each cell holds the full hash (an unboxed `Int` field, REP_HEAP_001), the key, the
  value and the rest of the chain. Links whose hash differs are rejected by an `Int` compare.
  There is one heap object per entry, where `HashMap` spends three: a `Dict` node, a `Cons` and a
  `Tuple3`.

Choose chaining, with load factor ≤ 1 and power-of-two capacity. Grow by doubling, splitting each
chain in one pass. Deletion and iteration are not provided, because Intern needs neither (§1.1).

### 4.2 `compiler/src/Data/HashTable.elm` (new)

```elm
module Data.HashTable exposing
    ( HashTable
    , withCapacity
    , getBy, insertNew
    , size, capacity
    , Stats, stats
    )

{-| An insert-only hash table on a persistent `Array` of chains, built for ONE
caller: `Compiler.AST.Intern`. Everything else uses `Data.HashMap`, and must:
step 17 (`benchmarks/lss-compile-opt-loop.md:861`) measured an array table
LOSING across the compiler's many small maps. This one pays off only for a big,
long-lived, probe-heavy table that is created once.

  - **Insert-only.** `insertNew` requires the key to be ABSENT (the caller has
    just missed with `getBy`); it does not check. There is no remove.
  - **No iteration.** Slot order depends on the hash and must never reach
    output; the table exposes no fold.
  - **Persistent.** Every operation returns a new table and leaves its input
    valid (`Array.set` path-copies). Intern relies on this: `rezonkSettled`
    drops a grown copy and keeps using the old one.
  - `hash` must satisfy "equal keys have equal hashes" and must be the same
    function at every call on one table. Negative and large hashes are correct;
    only hashes in `[0, 2^31)` land in the same slot on the JS and native hosts.

@docs HashTable, withCapacity, getBy, insertNew, size, capacity, Stats, stats

-}

import Array exposing (Array)
import Bitwise


{-| count, mask (capacity - 1; capacity is a power of two), slots.
-}
type HashTable k v
    = HashTable Int Int (Array (Chain k v))


{-| One slot's entries, newest first. `Link` carries the key's FULL hash, so a
different-hash entry sharing the slot is rejected by an `Int` compare without
calling `eq`.
-}
type Chain k v
    = Nil
    | Link Int k v (Chain k v)


{-| One full `JsArray` leaf.
-}
minCapacity : Int
minCapacity =
    32


{-| An empty table with room for `requested` entries before its first growth
(rounded up to a power of two, at least `minCapacity`).
-}
withCapacity : Int -> HashTable k v
withCapacity requested =
    let
        cap =
            powerOfTwoAtLeast (max minCapacity requested) 1
    in
    HashTable 0 (cap - 1) (Array.repeat cap Nil)


powerOfTwoAtLeast : Int -> Int -> Int
powerOfTwoAtLeast n c =
    if c >= n then
        c

    else
        powerOfTwoAtLeast n (c * 2)


{-| Where the slot index comes from. The identity today; §4.5 of
`plans/intern-hashtable-and-global-ids.md` decides whether it becomes a
finaliser. `grow` MUST split on the same function.
-}
spread : Int -> Int
spread h =
    h


getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashTable k v -> Maybe v
getBy hash eq probe (HashTable _ mask slots) =
    let
        h =
            hash probe
    in
    case Array.get (Bitwise.and mask (spread h)) slots of
        Just chain ->
            findIn eq probe h chain

        Nothing ->
            Nothing


findIn : (q -> k -> Bool) -> q -> Int -> Chain k v -> Maybe v
findIn eq probe h chain =
    case chain of
        Nil ->
            Nothing

        Link eh k v rest ->
            if eh == h && eq probe k then
                Just v

            else
                findIn eq probe h rest


{-| Insert a key the table does NOT hold. Grows (doubles) first when the table
is full (load factor 1).
-}
insertNew : (k -> Int) -> k -> v -> HashTable k v -> HashTable k v
insertNew hash key value ((HashTable count mask slots) as table) =
    if count > mask then
        insertNew hash key value (grow table)

    else
        let
            h =
                hash key

            i =
                Bitwise.and mask (spread h)
        in
        case Array.get i slots of
            Just chain ->
                HashTable (count + 1) mask (Array.set i (Link h key value chain) slots)

            Nothing ->
                -- Unreachable: `i` is in [0, mask] and `slots` has mask + 1 entries.
                table


{-| Double the capacity. Old slot j splits into new slots j (the `bit` of the
spread hash clear) and j + bit (set); relative order inside each chain is kept.
-}
grow : HashTable k v -> HashTable k v
grow (HashTable count mask slots) =
    let
        bit =
            mask + 1
    in
    HashTable count
        (2 * bit - 1)
        (Array.append
            (Array.map (splitChain bit 0) slots)
            (Array.map (splitChain bit bit) slots)
        )


splitChain : Int -> Int -> Chain k v -> Chain k v
splitChain bit want chain =
    rebuild (keepReversed bit want chain []) Nil


keepReversed : Int -> Int -> Chain k v -> List ( Int, k, v ) -> List ( Int, k, v )
keepReversed bit want chain acc =
    case chain of
        Nil ->
            acc

        Link h k v rest ->
            if Bitwise.and bit (spread h) == want then
                keepReversed bit want rest (( h, k, v ) :: acc)

            else
                keepReversed bit want rest acc


rebuild : List ( Int, k, v ) -> Chain k v -> Chain k v
rebuild reversed chain =
    case reversed of
        [] ->
            chain

        ( h, k, v ) :: more ->
            rebuild more (Link h k v chain)


size : HashTable k v -> Int
size (HashTable count _ _) =
    count


capacity : HashTable k v -> Int
capacity (HashTable _ mask _) =
    mask + 1


{-| Census only (report paths and tests). `hitCost` is the number of links
walked to find every stored key once — Σ n(n+1)/2 over chains — so
`hitCost / size` is the average depth of a hit.
-}
type alias Stats =
    { size : Int
    , capacity : Int
    , usedSlots : Int
    , maxChain : Int
    , hitCost : Int
    }


stats : HashTable k v -> Stats
stats (HashTable count mask slots) =
    Array.foldl
        (\chain acc ->
            let
                n =
                    chainLength chain 0
            in
            if n == 0 then
                acc

            else
                { acc
                    | usedSlots = acc.usedSlots + 1
                    , maxChain = max acc.maxChain n
                    , hitCost = acc.hitCost + (n * (n + 1)) // 2
                }
        )
        { size = count, capacity = mask + 1, usedSlots = 0, maxChain = 0, hitCost = 0 }
        slots


chainLength : Chain k v -> Int -> Int
chainLength chain n =
    case chain of
        Nil ->
            n

        Link _ _ _ rest ->
            chainLength rest (n + 1)
```

Notes for the implementer:
- **Stack safety.** Every recursion over a chain (`findIn`, `keepReversed`, `rebuild`,
  `chainLength`) is a self tail call, so it compiles to a loop. A degenerate constant hash makes a
  single chain of length n, and the tests exercise exactly that. Keep it this way.
- **Leave `Data.HashMap` untouched.**
- **Keep the module doc's "one caller" paragraph.** It is the guard against a second step 17.

### 4.3 `compiler/src/Compiler/AST/Intern.elm` changes

1. **Imports.** Replace `import Data.HashMap as HashMap` with
   `import Data.HashTable as HashTable exposing (HashTable)`.
2. **Types.** Replace `HashMap.HashMap` with `HashTable` in the `Intern` type (72-75) and in the
   signatures of `probe` (232) and `probeRO` (249).
3. **Capacities.** Add:
   ```elm
   {-| Presized so the self-compile never grows the table (H1 census, §4.5 of
   plans/intern-hashtable-and-global-ids.md). Growth still works past it.
   -}
   nodeTableCapacity : Int
   nodeTableCapacity =
       262144

   widenTableCapacity : Int
   widenTableCapacity =
       32768
   ```
   The initial values come from §1.1's ~140 K rows, rounded up to 2^18, and a guess of 2^15 for
   w. §4.5 replaces both with measured values.
4. **`empty`** becomes
   `Intern (HashTable.withCapacity nodeTableCapacity) (HashTable.withCapacity widenTableCapacity)`.
   It is a top-level constant, so it is built once and shared. Being persistent, sharing is safe.
   The cost is about 2.2 MB for the node array's 8 K leaves, kept alive for the run.
5. **`probe`.** `HashMap.getBy` becomes `HashTable.getBy`, and the miss path becomes
   `( mt, Intern (HashTable.insertNew canonHash (canonOf mt) mt m) w )`.
   - The key is absent by construction: `getBy` just missed on this table.
   - This also drops `HashMap.insert`'s redundant bucket rescan (`HashMap.elm:138`).
   - **Delete `canonEq` (110-112).** `insertNew` needs no equality.
6. **`probeRO`.** `HashMap.getBy` becomes `HashTable.getBy`.
7. **`size` and `entries`.** Every `HashMap.size` becomes `HashTable.size`.
8. **`widenSetsMemo`** (from H0). The lookup becomes
   `HashTable.getBy Mono.specHashOf widenEq monoType w`.
9. **`putWiden`.** Use `HashTable.insertNew Mono.specHashOf key widened w`. Add a comment
   explaining why the key is absent:
   - `widenSetsMemo` just missed on `monoType`.
   - `widenSetsGo` recurses only into proper subterms, and no proper subterm of a finite tree is
     `==` to the tree. So no insert of this key can happen in between.
10. **New export, report only:**
    ```elm
    stats : Intern -> Maybe { nodes : HashTable.Stats, widen : HashTable.Stats }
    stats intern =
        case intern of
            Intern m w ->
                Just { nodes = HashTable.stats m, widen = HashTable.stats w }

            ReadOnly m w ->
                Just { nodes = HashTable.stats m, widen = HashTable.stats w }

            Disabled ->
                Nothing
    ```
11. **Module docs.** Update the lines that name `HashMap` (the `probe`/`getBy` paragraph at 81-87)
    to name `Data.HashTable`, and say why Intern has its own table: one per run, about 10^7
    probes, never iterated.

Callers of Intern are unchanged: the exports and their types are the same, plus `stats`. `Engine`,
`Store`, `TypeSubst`, `Zonk`, `Specialize` and `State` need no edits.

### 4.4 The `intern|` report line

In `renderLssReport` (`MonoSolver/Monomorphize.elm:1475`), add one line built from
`Intern.stats s.intern`. Follow the existing `coverage:` line's style (1923-1940):

```
intern| nodes size=… cap=… used=… maxChain=… hitCost=… widen size=… cap=… used=… maxChain=… hitCost=…
```

It is rendered only under `lss.report`, like everything in that function, so it costs nothing on a
timed leg. No test pins report text by exact line (the report tests match substrings), but run
`LssSigFlowTest`, `LssHonestSourcesPipelineTest` and `LayoutQualTest` to be sure.

### 4.5 Census, then fix the constants (untimed, once, before the H1 timed legs)

1. Build the H1 candidate as §13 (loop Phase 1) describes. Run it once with `ECO_MONO_LSS_REPORT=1` on
   the self-compile workload, cold `eco-stuff`, and record the `intern|` line in the H1 loop entry.
2. Set `nodeTableCapacity` and `widenTableCapacity` to the smallest power of two ≥ the recorded
   final `size` of each. The self-compile then never grows either table.
3. If the node table's `hitCost / size` is above 1.6, or its `maxChain` above 16:
   - set `spread h = Bitwise.xor h (Bitwise.shiftRightZfBy 13 h)` in `Data.HashTable`;
   - rebuild, and re-run the census;
   - keep whichever `spread` gives the lower `hitCost`, and record both in the entry.
   - The finaliser folds hash bits 13–25 into the index bits. With `h < 2^26` it is exact on both
     hosts.
4. Rebuild with the final constants; that is the timed candidate. If the constants changed after
   the `try-H1` snapshot, take `try-H1b`.

### 4.6 Tests

**New file: `compiler/tests/Compiler/Data/HashTableTest.elm`**, exposing `suite` (elm-test-rs
discovers it; there is no central list). Model it on `HashMapTest.elm` and use three hashes:
`identity`, the degenerate `always 0`, and the low-bit collider `\k -> k * 64`. Pin:
1. Every inserted key is found, for 1,000 distinct keys under each hash.
2. Absent keys miss, in an empty table and in a populated one, under each hash.
3. `size` counts inserts. `withCapacity 32` followed by 33 inserts gives `capacity == 64`. After
   inserting 5,000 keys (seven doublings), every key is still found and `size == 5000`.
4. **Persistence.**
   - With `t1 = insertNew k1 t0` and `t2 = insertNew k2 t1`: `getBy k2 t1 == Nothing` and
     `getBy k1 t0 == Nothing`.
   - When the insert of `k2` triggers a growth, `t1` still answers exactly as before.
5. **Probe-typed `getBy`.** A stored `( String, Int )` key found by a bare `String` probe (as in
   `HashMapTest`).
6. Keys with hashes ≥ 2^26, and with negative hashes, are found.
7. **`stats` on a hand example.** Ten keys under `always 0` give `usedSlots == 1`,
   `maxChain == 10`, `hitCost == 55`.
8. **Fuzz.** `Fuzz.list Fuzz.int`, de-duplicated and inserted: all are found, `size` equals the
   distinct count, and probing ±1 of each key agrees with a `Set Int` model.

**Intern-level additions to `ComparableKeyEncodingTest.elm`:**
- The H0 pins (§3).
- A persistence pin: `( _, i1 ) = Intern.hashCons x i0` on a miss leaves `Intern.entries i0`
  unchanged, and `hashCons x i0` still misses.

**All existing K6/K7 Intern tests must pass unchanged.**

## 5. G0: `signatureFor` builds `gkey` only when it needs it

**File:** `compiler/src/Compiler/MonoSolver/LssInfer.elm`.

1. **`signatureFor` (81-113).** Delete the `let gkey = TOpt.toComparableGlobal global in` at
   82-85. The two uses move into their branches:
   - the crash message (L:96) becomes
     `EngineBug ("LssInfer.signatureFor re-entry on in-flight unit member: " ++ TOpt.toComparableGlobal global)`;
   - the fall-through (L:113) becomes `inferUnit global (TOpt.toComparableGlobal global) s0`.
   - The memo-hit path, about 10^6 times per run, then builds no string.
2. **`applyCalleeAt` (1659).** Delete the unused `gkey` binding (1661-1662). A grep of
   1659-1800 finds no other `gkey`, and the compiler's unused-binding warning confirms it.
3. **Nothing else changes.** `inferUnit`'s `String` parameter stays; G2 removes it.

BI: pure removal of work whose result the hit path never used. The error text is unchanged.

## 6. G1: `GlobalTable`: dense ids and precomputed facts

### 6.1 New module `compiler/src/Compiler/MonoSolver/GlobalTable.elm`

It holds the id table, the facts and the pure walks that facts are computed from. Engine imports
it. It imports only AST modules, `Data.HashMap`, `Data.Map` and `Array`, so no import cycle is
possible.

```elm
module Compiler.MonoSolver.GlobalTable exposing
    ( GlobalTable, GlobalFacts
    , build
    , idOf, idOfMono, factsAt, count
    , nodeOf, annotationOf, declaredArity, kernelAlias
    , foldNodes
    , declaredArityIn, kernelAliasIn
    , GlobalMemo, emptyMemo, memoFor, memoGet, memoInsert, memoSize, memoFoldl
    )

type alias GlobalFacts =
    { global : TOpt.Global
    , node : TOpt.Node TypeIds.MVarId
    , annotation : Maybe (Can.Annotation TypeIds.MVarId)
    , declaredArity : Int -- declaredArityIn with fuel 8 (every caller passes 8 today)
    , kernelAlias : Maybe ( Name, Name, Name )
    }

type GlobalTable
    = GlobalTable
        { ids : HashMap.HashMap TOpt.Global Int -- the ONE remaining Global hash probe
        , facts : Array GlobalFacts -- index = id; ids are dense 0..count-1
        , annotations : TOpt.AnnotationsByGlobal TypeIds.MVarId -- fallback for id-less globals
        }
```

**`build nodes annotations`.** Two passes, both O(globals):
1. `DMap.foldl TOpt.compareGlobal` over `nodes` assigns ids 0, 1, 2, … in fold order, which is
   ascending `toComparableGlobal`. It builds `ids` with
   `HashMap.insert TOpt.globalHash (==) g id`, plus a reversed list of `( g, node )`.
2. It then builds `facts` with `Array.fromList` over that list, reversed. For each entry it
   computes:
   - `annotation = DMap.get TOpt.toComparableGlobal g annotations` (one string build per global,
     once per run);
   - `declaredArity = declaredArityIn lookup name g 8`;
   - `kernelAlias = kernelAliasIn lookup g`;
   - where `lookup g2 = Maybe.map (\i -> nodeAt i) (HashMap.get … g2 ids)` reads the pass-1
     nodes.

**Accessors:**
- `idOf : TOpt.Global -> GlobalTable -> Maybe Int`, the one hash probe.
- `idOfMono : Mono.Global -> GlobalTable -> Maybe Int`. `Mono.Global home name` maps to
  `idOf (TOpt.Global home name)`; `Mono.Accessor _` maps to `Nothing`.
- `factsAt : Int -> GlobalTable -> Maybe GlobalFacts`, which is `Array.get`.
- `nodeOf g t = Maybe.andThen (\i -> Maybe.map .node (factsAt i t)) (idOf g t)`.
- `annotationOf : Maybe Int -> TOpt.Global -> GlobalTable -> Maybe (Can.Annotation …)`. With
  `Just i` it reads the facts; with `Nothing` it uses the `annotations` fallback, which is today's
  exact `DMap.get` (a global can have an annotation and no node).
- `declaredArity : Maybe Int -> TOpt.Global -> Int -> GlobalTable -> Int`:
  - with `Just i` and fuel 8, `.declaredArity`;
  - otherwise `declaredArityIn (\g2 -> nodeOf g2 t) name g fuel`, today's walk, exactly.
- `kernelAlias`: likewise.
- `foldNodes : (TOpt.Global -> TOpt.Node … -> b -> b) -> b -> GlobalTable -> b`. It folds `facts`
  in id order, which is the order `HashMap.foldl` over today's `toptNodes` produces.

**Moved code.** `declaredArityGo` (2195-2255), `canTypeArrowSpine` (2261-2275) and
`cycleDefArity` (from 2281) move verbatim from `LssInfer.elm`, along with any private helper the
compiler reports missing. `canTypeArrowSpine` stays private unless `LssInfer` still needs it
elsewhere; today its only callers are inside `declaredArityGo`. The lookup `s.env.toptNodes` becomes a `lookup : TOpt.Global -> Maybe (TOpt.Node …)`
parameter, giving `declaredArityIn lookup sought g fuel`. `kernelAliasOf` (L:2332-2346) moves the
same way as `kernelAliasIn lookup g`. The doc comments move with them; the GAP-7 and E9.2 history
belongs to the walk.

`GlobalMemo` is defined here for G2 and G3 (§7.1). G1 does not use it.

### 6.2 `Env` and `initState`

- **`Engine.Env` (E:1336-1360).** Replace `toptNodes : HashMap …` and
  `annotations : TOpt.AnnotationsByGlobal …` with **one** field, `globals : GlobalTable`. Env goes
  from 14 fields to 13. Move the 4c comment into `GlobalTable.build`'s doc.
- **`initState` (M:3909-3937).** Replace the `toptNodes = DMap.foldl …` and
  `annotations = annotations` entries with `globals = GlobalTable.build nodes annotations`.

### 6.3 Rewrite every `toptNodes` and `annotations` read

Mechanical: the compiler finds each site once the fields are gone. Every site in `compiler/src`
today:

| Site | Today | After G1 |
|---|---|---|
| L:99 (`signatureFor` Link chase), L:435 (`resolveUnit`) | `HashMap.get TOpt.globalHash (==) g s.env.toptNodes` | `GlobalTable.nodeOf g s.env.globals` |
| L:2201 (`declaredArityGo`), L:2334 (`kernelAliasOf`) | the walks | moved (§6.1). `LssInfer.declaredArityOf g fuel s = GlobalTable.declaredArity (GlobalTable.idOf g s.env.globals) g fuel s.env.globals`; `kernelAliasOf` likewise. Signatures unchanged, so their ~20 callers (T:480, 2737, 3255, 3678, 3864-3870, 4135, 4303; L:1746, 2424, 2469; M:1279, 2170, 4289; and T:1678, 2346, 3977, 4206; L:1246; M:3348) do not change. |
| T:2502 (`isCtorNode`), T:2525 (`isBodyNode`), T:4213 (`memberIdForDepth`) | `toptNodes` probe | `GlobalTable.nodeOf` |
| M:229, M:357 (settle passes), M:2224, M:3343 (report), M:4541 (`specializeNode` Link arm), M:4605 (`resolveGlobalNode`), M:4724 | `toptNodes` probe | `GlobalTable.nodeOf` |
| M:1238, M:2123 (folds into `Dict String`) | `HashMap.foldl … s.env.toptNodes` | `GlobalTable.foldNodes` (same order, §6.1) |
| M:4927 plus `buildMemberOrigins` (M:4951-5050) | takes `HashMap TOpt.Global (TOpt.Node …)` | takes `GlobalTable`. Its three helpers (`globalOrigin` 5015, `ctorBackedGlobal` 5024, and the rest to 5050) read with `GlobalTable.nodeOf`. |
| T:7595-7597 `lookupAnnotation` | `DMap.get TOpt.toComparableGlobal global s.env.annotations` | `GlobalTable.annotationOf (GlobalTable.idOf global s.env.globals) global s.env.globals`. G2 threads the id in. |
| L:249-251 `sigSourceTypeFor` | `DMap.get …` | same as `lookupAnnotation` |
| `Store.elm:122` | a comment naming `s.env.annotations` | reword it to name `GlobalTable.annotationOf` |

The subst engine's own `toptNodes` (`Monomorphize/State.elm`, `Specialize.elm`) is a different
structure and is out of scope.

### 6.4 BI argument, and a report counter

**BI.** Facts are pure functions of the same immutable `nodes` and `annotations`. `declaredArity`
with fuel 8 is today's walk evaluated early. Id order is today's `toptNodes` insertion order. No
decision reads an id's numeric value.

**Report counter.** Add `gid|` to `renderLssReport`: `count=<n> idless=<k>`. Here `k` counts
distinct globals that reached `GlobalTable.idOf` and got `Nothing`. It is counted only under
report: thread a report-gated counter through `LssStats`, whose 31 fields are within the cap. It
is expected to be about 0 (accessor pseudo-globals only). If it is large, the fallbacks are hot
and G2 must reconsider.

### 6.5 Tests

**New file: `compiler/tests/TestLogic/Monomorphize/GlobalTableTest.elm`**, exposing `suite`. Build
a small `DMap` of nodes by hand, following existing tests that construct `TOpt` nodes (grep
`TOpt.Define` under `compiler/tests`). If hand-building proves heavy, drive it from
`TestPipeline.runSolverMono*` on a tiny program instead. Pin:
- ids are 0..n-1 in ascending `toComparableGlobal` order;
- `idOf` of an unknown global is `Nothing`;
- for every global, `declaredArity (idOf g) g 8` equals the walk `declaredArityIn`. Cover a
  `Link` → `Cycle` member (the GAP-7 case), a `TrackedFunction`, a kernel alias (`(::)`) and a
  `Ctor`;
- `kernelAlias` equals the walk, including through a `Link`;
- `annotationOf` agrees with `DMap.get` for globals with and without ids.

Existing solver pipeline tests (`TestPipeline.elm:487, 531`) run through `initState` and cover the
rest. No test constructs `Env` or `S` directly.

## 7. G2: signatures and scheme memos keyed by id, and the id threaded down the call path

### 7.1 `GlobalMemo` (in `GlobalTable.elm`)

```elm
{-| A per-global memo: an Array indexed by global id, plus an exact fallback
for globals with no id (expected ~empty; see the `gid|` census).
-}
type alias GlobalMemo a =
    { byId : Array (Maybe a)
    , byGlobal : HashMap.HashMap TOpt.Global a
    }

emptyMemo : GlobalMemo a -- { byId = Array.empty, byGlobal = HashMap.empty }
memoFor : GlobalTable -> GlobalMemo a -- byId presized: Array.repeat (count t) Nothing

memoGet : Maybe Int -> TOpt.Global -> GlobalMemo a -> Maybe a
-- Just i  -> Array.get i byId |> Maybe.andThen identity (out of range = Nothing)
-- Nothing -> HashMap.get TOpt.globalHash (==) g byGlobal

memoInsert : Maybe Int -> TOpt.Global -> a -> GlobalMemo a -> GlobalMemo a
-- Just i -> if i < Array.length byId then Array.set i (Just v)
--           else extend byId with Nothing up to i, then set
--           (never silently drop: Array.set out of range is a no-op in Elm)
-- Nothing -> HashMap.insert TOpt.globalHash (==) g v byGlobal

memoSize : GlobalMemo a -> Int -- count of Just in byId + HashMap.size byGlobal
memoFoldl : (TOpt.Global -> a -> b -> b) -> GlobalTable -> b -> GlobalMemo a -> b
-- byId in id order (global from factsAt), then byGlobal in its insertion order
```

The out-of-range extension is what makes `emptyMemo` safe wherever a table is not at hand
(`Engine.emptyMonoMemo`, tests).

### 7.2 Retypes

- **`S.lssSignatures` (E:1385)** becomes `GlobalMemo LssSignature`. In `initState` it is
  `GlobalTable.memoFor globals`, which needs `globals` bound in a `let` so both `env` and this
  field can use it.
- **`MonoMemo.schemeMono` (E:502)** becomes `GlobalMemo Mono.MonoType`.
  - `emptyMonoMemo` (E:508) keeps `GlobalTable.emptyMemo`. Elm has no qualified record update,
    so `initState` binds `memo0 = Engine.emptyMonoMemo` in its `let` and sets
    `monoMemo = { memo0 | schemeMono = GlobalTable.memoFor globals }`.
  - `GroundAliasMemoTest` reads only `emptyMonoMemo.aliasMemo`, so it is unaffected.
- **`lookupSchemeMono` and `putSchemeMono` (E:2771-2782).** Their key parameter changes from
  `String` to `Maybe Int -> TOpt.Global`, and the bodies use `memoGet`/`memoInsert`.
- **Unchanged:** `S.lssInProgress` (§14).

### 7.3 Thread the id once, in `translateCall`

1. **`translateCall` (T:1843).** In the `VarGlobal` arm, compute
   `gid = GlobalTable.idOf global s0.env.globals` once. Call
   `lookupAnnotation gid global s0` and `translateGlobalCall region funcRegion gid global …`.
2. **`lookupAnnotation` (T:7595).** Add a leading `Maybe Int` parameter. Its other caller (T:2394)
   passes `GlobalTable.idOf global s.env.globals`.
3. **`translateGlobalCall` (T:2681)** and the Fast (2959), GroundMemo (3011) and Slow (3103)
   variants take `gid : Maybe Int` after `funcRegion` and pass it on:
   - `lssFastOk gid global args` (2690 → 2745). Its body calls
     `LssInfer.signatureForId gid global s`.
   - `needsPapSlow gid global …` (2692 → 2733). Its body reads
     `GlobalTable.declaredArity gid global 8 s.env.globals`.
   - Fast: `cachedSchemeMono gid global funcCanType` (2965; signature at 2913). The key becomes
     `(gid, global)`. `computeSchemeMono` (after 2929) takes the same pair and passes it to
     `putSchemeMono`.
   - Slow: `instantiateLss gid global funcCanType` (3115; signature at 4792). It calls
     `LssInfer.instantiateWithSignatureId gid global funcCanType`.
   - Callers of the Fast, GroundMemo and Slow variants elsewhere in Translate (the compiler lists
     them) pass `GlobalTable.idOf global s.env.globals`.
4. **`LssInfer`:**
   - **`signatureForId : Maybe Int -> TOpt.Global -> Engine.S -> ( LssSignature, Engine.S )`** is
     the body of today's `signatureFor`, with these changes:
     - every `HashMap.get/insert … s.lssSignatures` becomes `GlobalTable.memoGet/memoInsert gid global …`;
     - the Link-chase recursion calls `signatureFor target` (it computes the target's id), and the
       second probe of the linked global uses `gid`;
     - the `lssInProgress` check is unchanged (still a HashMap on `Global`, §14).
   - **`signatureFor g s = signatureForId (GlobalTable.idOf g s.env.globals) g s`** is kept for
     every caller without an id in hand: L:108, L:544 (`preResolveGo`), `instantiateWithSignature`
     and the rest.
   - **`instantiateWithSignatureId gid global funcCanType s`** calls `signatureForId`. The old
     `instantiateWithSignature` (L:125) is kept as a wrapper.
   - **`inferUnit` (L:388)** drops its `String` parameter. It builds
     `TOpt.toComparableGlobal global` only in the `[]` placeholder branch, if at all. It inserts
     with `memoInsert (GlobalTable.idOf k s.env.globals) k sg` at L:405 and 425. These are
     miss-path only, about 10 K per run.
   - **`preResolveGo`**'s `lssSignatures` probe (L:544) uses `memoGet (idOf …)`.
5. **`Engine.memoizedSignatureTrivial` (E:1219)** becomes
   `Maybe.map .trivial (GlobalTable.memoGet (GlobalTable.idOf g s.env.globals) g s.lssSignatures)`.
   Its callers (T:486, T:3224) are unchanged.
6. **Report readers of `lssSignatures`:**
   - M:1488 (size) uses `memoSize`.
   - M:1491-1500 and M:3281-3300 (folds) use `memoFoldl`.
   - M:3188 (single get) uses `memoGet (idOf …)`.
   - **Report order changes** from insertion order to id order. The report is not part of the
     artifact, and no test pins `sigCount` or signature line order. Record it in the G2 entry.

### 7.4 BI argument

- Memo keys and values are the same; only the container changes. No artifact path iterates
  `lssSignatures` or `schemeMono`.
- The order in which `signatureFor` is forced is unchanged. It is driven by
  `collectReferencedGlobals`, which is left alone (§14), and by call order.
- `inferUnit`'s placeholder and cycle handling are unchanged.

### 7.5 Tests

- **`GlobalTableTest`**: `memoGet` after `memoInsert`, for an id and for an id-less global.
  `memoInsert` past `Array.length` (from `emptyMemo`) is found, never dropped. `memoSize` counts
  both halves.
- **`memoFoldl`**: id order first, then `byGlobal`.
- **Existing LSS tests** (`LssSigFlowTest`, `LssHonestSourcesTest`, `LssDirectedFlowTest`,
  `LayoutQualTest`, `GroundAliasMemoTest`) must pass unchanged.

## 8. G3: node resolution and spec tallies keyed by id

1. **`S.nodeResolution` (E:1391).** `CoreDict.Dict String NodeResolution` becomes
   `GlobalMemo NodeResolution`, created with `memoFor globals` in `initState` (M:3920-3926 region).
   **`resolveGlobalNode` (M:4592-4618):**
   - `gid = GlobalTable.idOf (TOpt.Global home name) s.env.globals`;
   - `memoGet gid g`;
   - on a miss, `node = …` reads the facts when `gid` is `Just`, and otherwise
     `GlobalTable.nodeOf` (which gives `Nothing`);
   - `memoInsert gid g resolution`.
   - The `gkey` string (4595-4596) is gone.
   - The comment at E:1391 ("keyed by TOpt.toComparableGlobal") is updated.
2. **`S.specCountByGlobal` (E:1374)** becomes a new type in Engine:
   ```elm
   type alias SpecTallies =
       { byId : Array (Maybe SpecTally)
       , byKey : CoreDict.Dict String SpecTally -- Mono.Accessor and id-less globals, keyed by Mono.toComparableGlobal as today
       }
   ```
   `initState` presizes `byId` to `GlobalTable.count`.
   - **`enqueueSpecKeyed` (E:2316).** Replace the key build at 2319-2320 with
     `GlobalTable.idOfMono monoGlobal s.env.globals`. The get (2323) and the insert (2373,
     create-only) use `byId` when it is `Just`. Otherwise they build the string key as today and
     use `byKey`.
   - **`specIdsForGlobal` (E:99-106)** changes from `String -> S -> List Int` to
     `Mono.Global -> S -> List Int`, with the same split. Its callers are in `ctorFieldUnion`
     (T:7011-7037, reference at T:7037); pass the `Mono.Global` they rendered the key from.
   - The other reads at E:2311, 2371 and 2376 follow the same split. `SpecTally`'s contents,
     including the created-ids list order, are untouched.
   - `Array.set` on `byId` uses the same extend-if-out-of-range rule as `memoInsert`.
3. **BI.** Neither map is iterated. The tallies' `ids` order is kept inside each `SpecTally`.

**Tests.** Add `SpecTallies` get/insert pins to `GlobalTableTest` if the type lives where the test
can reach it: an id'd global, an id-less one and an accessor key, plus insert past `Array.length`.
Otherwise rely on the BI gate and E2E. `SpecWatchdogTest` (81-105) covers `createdCount` on the
registry, which this step does not touch, so it must pass unchanged.

## 9. C0: `Data.Bits32`, host-independent 32-bit bit helpers

**Why first.** C1's trie takes 5-bit slices of the hash, tests bitmap bits and counts bits. Every
one of those operations answers differently on JS and native unless it is written to the rules in
§1.7. A wrong popcount does not crash; it silently reads the wrong slot on one host only. So the
helpers are separate, small and pinned on both hosts before anything uses them.

### 9.1 `compiler/src/Data/Bits32.elm` (new)

```elm
module Data.Bits32 exposing (mask32, fragment, bitpos, below, popcount)

{-| 32-bit bit tricks that give the SAME answers on both of Eco's hosts.

`Bitwise` is 32-bit under JS (stock Elm, bootstrap stages 1-2, elm-test-rs) and
64-bit on Eco's native backend (`elm-kernel-cpp/src/core/Bitwise.cpp`; pinned by
`test/elm/src/BitwiseLargeShiftTest.elm`: `shiftLeftBy 32 1 == 4294967296`).
Everything here keeps values in the low 32 bits and follows three rules, and so
must any caller:

1.  Mask a hash with `mask32` before taking bits from it.
2.  Test a bit only against 0 (`/= 0`, `== 0`): bit 31 is NEGATIVE under JS and
    positive natively, so `<`, `>` and `==` against a non-zero value differ.
3.  Mask after arithmetic (see `popcount`): natively, bits above 31 survive a
    multiply or an add that JS would truncate.

Pinned on JS by `compiler/tests/Compiler/Data/Bits32Test.elm` and natively by
`test/elm/src/Bits32HostWidthTest.elm`, against the SAME table of values.

@docs mask32, fragment, bitpos, below, popcount

-}

import Bitwise


{-| The low 32 bits. Under JS the result is a SIGNED int32, natively it is
unsigned; nothing in this module can tell the difference, because every reader
goes through `shiftRightZfBy` or a test against 0.
-}
mask32 : Int -> Int
mask32 h =
    Bitwise.and 0xFFFFFFFF h


{-| The 5-bit slice of a `mask32`'d hash at `shift`, in [0, 31]. `shift` MUST be
in [0, 30] (at 30 only two bits remain): JS reduces shift counts modulo 32, so a
larger shift silently wraps there and not natively.
-}
fragment : Int -> Int -> Int
fragment shift h =
    Bitwise.and 31 (Bitwise.shiftRightZfBy shift h)


{-| The bitmap bit for a fragment. Bit 31 is negative under JS (rule 2).
-}
bitpos : Int -> Int
bitpos frag =
    Bitwise.shiftLeftBy frag 1


{-| How many bits of `bitmap` are set BELOW `bit`: the array index of `bit`'s
entry in a compressed node. `bit - 1` for bit 31 is -2147483649 under JS; `and`
truncates it to 0x7FFFFFFF on both hosts.
-}
below : Int -> Int -> Int
below bitmap bit =
    popcount (Bitwise.and bitmap (bit - 1))


{-| Set bits in the low 32 bits (SWAR). The final `and 0x3F` is rule 3: it drops
what natively survives above the low byte.
-}
popcount : Int -> Int
popcount x0 =
    let
        x1 =
            x0 - Bitwise.and 0x55555555 (Bitwise.shiftRightZfBy 1 x0)

        x2 =
            Bitwise.and 0x33333333 x1 + Bitwise.and 0x33333333 (Bitwise.shiftRightZfBy 2 x1)

        x3 =
            Bitwise.and 0x0F0F0F0F (x2 + Bitwise.shiftRightZfBy 4 x2)
    in
    Bitwise.and 0x3F
        (x3
            + Bitwise.shiftRightZfBy 8 x3
            + Bitwise.shiftRightZfBy 16 x3
            + Bitwise.shiftRightZfBy 24 x3
        )
```

**Hand-checked** for `0x80000000` and `0xFFFFFFFF` on both hosts: the intermediates differ by
multiples of 2^32 under JS, and `and` removes that. Every intermediate is below 2^33 in magnitude,
so JS float arithmetic stays exact.

### 9.2 The pin table (one table, two hosts)

| Label | Expression | Value |
|---|---|---|
| `pc0` | `popcount 0` | 0 |
| `pc31` | `popcount (bitpos 31)` | 1 |
| `pcAll` | `popcount (mask32 -1)` | 32 |
| `pcAlt` | `popcount 0x55555555` | 16 |
| `below31` | `below (mask32 -1) (bitpos 31)` | 31 |
| `frag30` | `fragment 30 (mask32 -1)` | 3 |
| `fragHigh` | `fragment 27 (mask32 (2 ^ 40 + 2 ^ 31))` | 16 |
| `bit31Set` | `Bitwise.and (mask32 -1) (bitpos 31) /= 0` | True |
| `bit31Clear` | `Bitwise.and (mask32 0x7FFFFFFF) (bitpos 31) /= 0` | False |

- **JS:** a new `compiler/tests/Compiler/Data/Bits32Test.elm`, exposing `suite`, asserts the
  table. Add a fuzz test on `Fuzz.int`: `popcount (mask32 x)` equals a naive count,
  `List.length (List.filter (\i -> Bitwise.and (mask32 x) (bitpos i) /= 0) (List.range 0 31))`.
- **Native:** a new `test/elm/src/Bits32HostWidthTest.elm` in the E2E format (see
  `BitwiseAndTest.elm`). It has one `-- CHECK: <label>: <value>` line per row and a `main` that
  `Debug.log`s each label.
  - It carries a **verbatim copy** of the five helpers, because the `test/elm` project cannot
    import `compiler/src`.
  - Its module doc names `Data.Bits32` and `Bits32Test.elm` and says to change all three together.

C0 has no timed leg (nothing calls it yet). Its gate is the unit suite plus the E2E suite, with the
new test passing on both hosts.

## 10. C1: `Data.HashMap` as a pure-Elm CHAMP

### 10.1 What must not change

`compiler/src/Data/HashMap.elm` keeps its exposing list and every signature: `HashMap`, `empty`,
`insert`, `get`, `getBy`, `member`, `remove`, `size`, `isEmpty`, `foldl`, `map`, `toList`,
`values`, `fromList`. It adds `Stats` and `stats` for census and tests. **None of its callers
changes:**
- `Compiler.AST.Monomorphized`, the `LayoutMap`, `SpecMap` and `SpecKeyMap` wrappers;
- `Engine`, `LssInfer`, `Monomorphize`, `Store` and `Translate` under `MonoSolver/`;
- `GlobalTable`, if G1 has landed;
- two test files.

After H1, `Intern` is no longer a caller until C2 moves it back.

The contracts C1 must keep exactly (the current code is at `HashMap.elm` 55-264):
1. `hash` and `eq` are supplied per call. Equal keys must hash equal; `eq` decides.
2. `insert` of a present key replaces the value and keeps the FIRST-inserted key object and its
   iteration position (`replaceInBucket` 155-166).
3. `remove` of an absent key returns the map unchanged.
4. `foldl`, `toList` and `values` iterate in **insertion order**, oldest first. A key that is
   removed and re-inserted moves to the end.
   - This is required for bootstrap equivalence, not only for the K4 bug.
   - `Eco.Hash.string64` deliberately gives different values in the pure twin, the JS kernel and
     the C++ kernel (`compiler/src-xhr/Eco/Hash.elm:10-13`).
   - The bootstrap chain runs different twins at different stages. Stage 2 uses pure twins, stages
     3–5 the JS kernel and stages 6 onward the C++ kernel, and mlir-equivalence compares stage 2
     against stage 6 (`test/CMakeLists.txt:264`).
   - So a fold in trie (hash) order would make compiler output differ between builds.
5. `map` keeps keys, order and size.
6. `getBy` takes a probe whose type differs from the stored key (Intern relies on it until C2).
7. `size` and `isEmpty` are O(1).
8. `fromList` is a left fold of `insert`.

**On `==` over maps.** Today `==` on two `HashMap`s compares `Dict` shapes and sequence numbers, so
it already depends on insertion history. After C1 it still depends on history (the sequence
numbers stay). Two maps built by the same deterministic sequence of operations are equal under
both representations. No source module compares `HashMap`-bearing values with `==` on purpose;
the BI gate and the unit suite are the check.

### 10.2 Representation

```elm
type HashMap k v
    = Small Int Int (List (Entry k v)) -- count, nextSeq, entries NEWEST first; count <= smallLimit
    | Trie Int Int (Node k v) -- count, nextSeq, root


{-| A CHAMP node. It covers one 5-bit slice of the hash (`Bits32.fragment
shift`), so it has 32 positions, and two bitmaps say what is at each:

  - `dataMap` bit i: exactly one entry has slice i, and it is stored INLINE in
    `entries`, at index `Bits32.below dataMap (bitpos i)`.
  - `nodeMap` bit i: several entries have slice i; they are in a child in
    `children`, at index `Bits32.below nodeMap (bitpos i)`.
  - neither: no entry has slice i. Never both.

The arrays hold occupied positions only. Inline entries are kept apart from
children (CHAMP's change to HAMT), so iteration needs no per-slot type test,
and removal compacts back to the one canonical shape.
-}
type Node k v
    = Bitmap Int Int (Array (Entry k v)) (Array (Node k v)) -- dataMap, nodeMap, entries, children
    | Collision Int (List (Entry k v)) -- all 32 hash bits equal (only below shift 30)


{-| The `mask32`'d hash (so a push-down never recomputes it), the insertion
sequence number (the iteration order), the key, the value.
-}
type Entry k v
    = Entry Int Int k v
```

**Constants.**
- `smallLimit = 8`. It is census-tunable (§10.6) and matches Clojure's array-map threshold.
- `maxShift = 30`. Levels sit at shifts 0, 5, …, 30 (the last with 2 bits). Two entries whose
  32-bit hashes are equal meet in a `Collision` node below shift 30.
- `emptyNode = Bitmap 0 0 Array.empty Array.empty`.

**`empty = Small 0 0 []`** is a constant. Like today's `HashMap 0 0 Dict.empty`, it allocates
nothing per map.

**Why a small form.** Step 17 found that most `HashMap`s hold a handful of entries. For those, a
list scan that compares the stored `Int` hash before calling `eq` beats any trie. It costs one
`Cons` plus one `Entry` per entry, against today's `Dict` node, `Cons` and `Tuple3`. At the 9th
distinct key the map is promoted to a trie. A trie is never demoted, because maps rarely shrink.

### 10.3 Operations

Code sketches, complete in logic. `import Data.Bits32 as Bits32` and `import Array exposing (Array)`.
Every recursion over a list is a self tail call. Trie recursion is at most 7 levels deep.

```elm
getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashMap k v -> Maybe v
getBy hash eq probe m =
    let
        h =
            Bits32.mask32 (hash probe)
    in
    case m of
        Small _ _ entries ->
            findEntry eq probe h entries

        Trie _ _ root ->
            lookupNode eq probe h 0 root


findEntry : (q -> k -> Bool) -> q -> Int -> List (Entry k v) -> Maybe v
findEntry eq probe h entries =
    case entries of
        [] ->
            Nothing

        (Entry eh _ k v) :: rest ->
            if eh == h && eq probe k then
                Just v

            else
                findEntry eq probe h rest


lookupNode : (q -> k -> Bool) -> q -> Int -> Int -> Node k v -> Maybe v
lookupNode eq probe h shift node =
    case node of
        Bitmap dataMap nodeMap entries children ->
            let
                bit =
                    Bits32.bitpos (Bits32.fragment shift h)
            in
            if Bitwise.and dataMap bit /= 0 then
                case Array.get (Bits32.below dataMap bit) entries of
                    Just (Entry eh _ k v) ->
                        if eh == h && eq probe k then
                            Just v

                        else
                            Nothing

                    Nothing ->
                        Nothing

            else if Bitwise.and nodeMap bit /= 0 then
                case Array.get (Bits32.below nodeMap bit) children of
                    Just child ->
                        lookupNode eq probe h (shift + 5) child

                    Nothing ->
                        Nothing

            else
                Nothing

        Collision ch entries ->
            if ch == h then
                findEntry eq probe h entries

            else
                Nothing
```

**`get`** is `getBy`. **`member`** has the same shape, returning `Bool` (`memberEntry`,
`memberNode`), so that a hit allocates no `Just`.

**`insert`.** Check membership first, then either replace in place or insert a known-absent entry.
Neither path returns a pair: the `( List, Bool )` per recursion step was a measured allocation pool
(`HashMap.elm:149-153`, Run C `Tuple2 +93.8M`).

```elm
insert : (k -> Int) -> (k -> k -> Bool) -> k -> v -> HashMap k v -> HashMap k v
insert hash eq key value m =
    let
        h =
            Bits32.mask32 (hash key)
    in
    case m of
        Small count nextSeq entries ->
            if memberEntry eq key h entries then
                Small count nextSeq (replaceEntry eq key h value entries)

            else if count < smallLimit then
                Small (count + 1) (nextSeq + 1) (Entry h nextSeq key value :: entries)

            else
                Trie (count + 1) (nextSeq + 1) (insertNewNode (Entry h nextSeq key value) 0 (promote entries))

        Trie count nextSeq root ->
            if memberNode eq key h 0 root then
                Trie count nextSeq (replaceNode eq key h value 0 root)

            else
                Trie (count + 1) (nextSeq + 1) (insertNewNode (Entry h nextSeq key value) 0 root)


{-| Seqs travel inside the entries, so the order entries are re-inserted in
does not matter.
-}
promote : List (Entry k v) -> Node k v
promote entries =
    List.foldl (\e node -> insertNewNode e 0 node) emptyNode entries


{-| Keeps the stored key and its seq (contract 2).
-}
replaceEntry : (k -> k -> Bool) -> k -> Int -> v -> List (Entry k v) -> List (Entry k v)
replaceEntry eq key h value entries =
    List.map
        (\((Entry eh seq k _) as e) ->
            if eh == h && eq key k then
                Entry eh seq k value

            else
                e
        )
        entries


{-| Insert an entry whose key the node does NOT hold.
-}
insertNewNode : Entry k v -> Int -> Node k v -> Node k v
insertNewNode ((Entry h _ _ _) as e) shift node =
    case node of
        Bitmap dataMap nodeMap entries children ->
            let
                bit =
                    Bits32.bitpos (Bits32.fragment shift h)
            in
            if Bitwise.and dataMap bit /= 0 then
                -- The slot holds a different key: push both down into a new child.
                let
                    i =
                        Bits32.below dataMap bit

                    nodeMap1 =
                        Bitwise.or nodeMap bit
                in
                case Array.get i entries of
                    Just old ->
                        Bitmap (Bitwise.xor dataMap bit)
                            nodeMap1
                            (removeAt i entries)
                            (insertAt (Bits32.below nodeMap1 bit) (mergeTwo old e (shift + 5)) children)

                    Nothing ->
                        node

            else if Bitwise.and nodeMap bit /= 0 then
                let
                    j =
                        Bits32.below nodeMap bit
                in
                case Array.get j children of
                    Just child ->
                        Bitmap dataMap nodeMap entries (Array.set j (insertNewNode e (shift + 5) child) children)

                    Nothing ->
                        node

            else
                let
                    dataMap1 =
                        Bitwise.or dataMap bit
                in
                Bitmap dataMap1 nodeMap (insertAt (Bits32.below dataMap1 bit) e entries) children

        Collision ch entries ->
            Collision ch (e :: entries)


{-| Two entries that share every hash slice above `shift`.
-}
mergeTwo : Entry k v -> Entry k v -> Int -> Node k v
mergeTwo ((Entry h1 _ _ _) as e1) ((Entry h2 _ _ _) as e2) shift =
    if shift > maxShift then
        Collision h1 [ e2, e1 ]

    else
        let
            f1 =
                Bits32.fragment shift h1

            f2 =
                Bits32.fragment shift h2
        in
        if f1 == f2 then
            Bitmap 0 (Bits32.bitpos f1) Array.empty (Array.repeat 1 (mergeTwo e1 e2 (shift + 5)))

        else
            Bitmap (Bitwise.or (Bits32.bitpos f1) (Bits32.bitpos f2))
                0
                (Array.fromList
                    (if f1 < f2 then
                        [ e1, e2 ]

                     else
                        [ e2, e1 ]
                    )
                )
                Array.empty
```

`replaceNode eq key h value shift node` walks like `lookupNode`. The key is known present, so an
inline entry at the slice's `dataMap` bit is that key. It rebuilds that entry as
`Entry eh seq k value` (same key, same seq) with `Array.set`. In a `Collision` it uses
`replaceEntry`.

**`remove`.** Check membership first; an absent key returns `m` itself.
- `Small`: `List.filter` out the entry and set `count - 1`.
- `Trie`: `removeNode`, then `count - 1`. A trie stays a trie.

`removeNode` keeps CHAMP's canonical form:

```elm
removeNode : (k -> k -> Bool) -> k -> Int -> Int -> Node k v -> Node k v
removeNode eq key h shift node =
    case node of
        Bitmap dataMap nodeMap entries children ->
            let
                bit =
                    Bits32.bitpos (Bits32.fragment shift h)
            in
            if Bitwise.and dataMap bit /= 0 then
                Bitmap (Bitwise.xor dataMap bit) nodeMap (removeAt (Bits32.below dataMap bit) entries) children

            else
                let
                    j =
                        Bits32.below nodeMap bit
                in
                case Array.get j children of
                    Just child ->
                        let
                            child1 =
                                removeNode eq key h (shift + 5) child
                        in
                        case singleEntry child1 of
                            Just single ->
                                -- Canonical form: a child left with one entry and no
                                -- children is pulled up inline.
                                let
                                    dataMap1 =
                                        Bitwise.or dataMap bit
                                in
                                Bitmap dataMap1
                                    (Bitwise.xor nodeMap bit)
                                    (insertAt (Bits32.below dataMap1 bit) single entries)
                                    (removeAt j children)

                            Nothing ->
                                Bitmap dataMap nodeMap entries (Array.set j child1 children)

                    Nothing ->
                        node

        Collision ch entries ->
            Collision ch (List.filter (\(Entry eh _ k _) -> not (eh == h && eq key k)) entries)


singleEntry : Node k v -> Maybe (Entry k v)
singleEntry node =
    case node of
        Bitmap _ nodeMap entries _ ->
            if nodeMap == 0 && Array.length entries == 1 then
                Array.get 0 entries

            else
                Nothing

        Collision _ [ e ] ->
            Just e

        Collision _ _ ->
            Nothing
```

**Array helpers, with the cheap cases peeled off:**

```elm
insertAt : Int -> a -> Array a -> Array a
insertAt i x arr =
    let
        n =
            Array.length arr
    in
    if i >= n then
        Array.push x arr

    else
        Array.append (Array.push x (Array.slice 0 i arr)) (Array.slice i n arr)


removeAt : Int -> Array a -> Array a
removeAt i arr =
    let
        n =
            Array.length arr
    in
    if n <= 1 then
        -- The shared constant: a leaf node's empty `children` must never be a
        -- fresh wrapper.
        Array.empty

    else if i == n - 1 then
        Array.slice 0 i arr

    else
        Array.append (Array.slice 0 i arr) (Array.slice (i + 1) n arr)
```

**Cost model of `Array` as node storage** (elm/core 1.0.5 `Array.elm`, as compiled by Eco):
- **Where the elements live.** An `Array` is two heap objects: the `Array_elm_builtin` wrapper
  (length, shift, tree, tail) and its tail `JsArray`. The empty tree is the shared
  `JsArray.empty`.
  - A node array of 1–31 elements lives entirely in the tail (`tailIndex len == 0`).
  - At exactly 32 elements, `unsafeReplaceTail` moves the tail into a one-leaf tree, so every
    access takes one extra hop. Only full nodes pay this, meaning the top levels of large maps.
- **`get`** is a bounds check, a `tailIndex` test and one `eco.array.get`, plus the `Just` it
  returns. A depth-4 lookup allocates 4 `Just`s. That is the main lookup overhead against a native
  node. Whether Eco's inliner removes the `Just` is unknown; the C1 entry should say what the
  profile shows.
- **`set`** (value replace, child replace on the insert path) is one `eco.array.set` tail copy
  plus a new wrapper. That is fine.
- **Structural edits have no Elm primitive.** A mid-array `insertAt` costs about 9 allocations and
  copies about 2n slots:
  - two slices, a push and an append, each allocating a wrapper and a tail;
  - `append` also allocates its recursive `foldHelper` closure and calls `JsArray.foldl`. That is a
    kernel call, not an intrinsic, although over `b`'s empty tree it does nothing.

  A native CHAMP does the same edit with one allocation. The peeled cases above are cheap:
  appending at the end is a push, and removing the last element is one slice. Structural edits
  happen only when a new key arrives or a key leaves, so they fall on the insert path, not the
  lookup path.
- **Against today's `HashMap`, C1 is still ahead.**
  - A new-key insert costs about depth × (wrapper + tail) for the path, one structural edit, and
    an `Entry`. That is roughly 15 allocations, in the same range as today's ~17-node `Dict`
    path copy plus a `Cons` and a `Tuple3`.
  - Lookups are about 4 levels instead of about 17.
  - Maps of 8 entries or fewer never touch an `Array`.
  - Against a native CHAMP, pure Elm pays several times the allocation per structural edit. That
    is what C3 removes (§12).
- **Why two arrays per node and not CHAMP's single mixed array.** Elm arrays are homogeneous, so
  one array would need a `Child` box around every child node.
  - Leaf nodes, the majority in a big trie, have no children. With two arrays their `children` is
    the shared `Array.empty`, so a leaf node costs 3 objects (the `Bitmap` plus one wrapper and
    tail). A mixed array would cost 4 (plus the parent's `Child` box).
  - Only nodes that hold both inline entries and children cost more with two arrays (5 objects
    against 4).
  - Two arrays is the better trade in Elm. `removeAt`'s `n <= 1` case keeps an emptied `children`
    on the shared constant.

**Iteration** (contract 4). A single `orderedEntries` again serves `foldl`, `toList` and `values`:
- `Small`: `List.reverse entries`. The list is newest-first, and replacing or removing an entry
  keeps its place, so reversing gives insertion order with no sort.
- `Trie`: collect every entry (`Array.foldl` over entries and children, recursively) and
  `List.sortBy` on the seq. This is exactly today's cost model (`HashMap.elm:223-226`); the sort is
  native (`plans/mono-comparable-key-optimization.md` §11).

**`map f`** maps `Small`'s list, or `Array.map`s each node's entries and children and `List.map`s
collisions. Hashes, seqs and shape are untouched.

**`fromList`** is `List.foldl (\( k, v ) acc -> insert hash eq k v acc) empty`, as today.
**`size`/`isEmpty`** read `count`.

**`stats`** (census and tests):
`{ size : Int, trie : Bool, nodes : Int, maxDepth : Int, collisionNodes : Int, inlineEntries : Int }`.

### 10.4 Module doc

Rewrite `HashMap.elm`'s module doc (1-40). Keep:
- the explicit `hash`/`eq` contract;
- the "collisions are resolved, not assumed away" paragraph;
- the INSERTION-ORDERED paragraph, verbatim; it is the contract.

Replace the bucket description with §10.2's `Node` doc (what `dataMap` and `nodeMap` mean) and
the small-form rationale. Name `Data.Bits32`'s three rules as binding on anyone editing the trie.

### 10.5 Tests

- **Existing: `compiler/tests/Compiler/Data/HashMapTest.elm` must pass unchanged.** Its `modBy 3`
  hash makes every key share one of three hashes, so with more than 8 keys it drives `Trie` into
  deep `Collision` nodes. That is good coverage for free.
- **New: `compiler/tests/Compiler/Data/HashMapChampTest.elm`**, exposing `suite`. Use three
  hashes: `identity`, `always 0` (everything collides), and `\k -> k * 32` (level 0 always slice
  0, so it forces depth). Pin:
  1. **Model fuzz.** A random sequence of `insert`/`remove`/`get` over `Int` keys in [0, 200],
     checked after every operation against a list model that keeps first positions and appends
     re-inserts. Check `get` for all 201 keys, `size`, and `toList` (order included). Run it
     under each hash.
  2. **Promotion boundary.** 8 keys stay `Small` (`stats.trie == False`); the 9th makes it a
     trie; order and all lookups survive.
  3. **Order semantics.** Insert a, b, c; replace b; remove a; insert a. `toList` is
     `[ b', c, a ]`, with b's new value in b's old position.
  4. **Canonical compaction.** Under `\k -> k * 32`, insert enough keys to build depth ≥ 2,
     remove all but one from a subtree, and check that `stats.maxDepth` and `stats.nodes`
     shrink and the survivor is found.
  5. **Collisions.** 100 keys under `always 0` are all found. After removing half, the rest are
     found and `stats.collisionNodes >= 1`.
  6. **Host-width hashes.** Hashes ≥ 2^32 (`\k -> k * 4294967296 + k`) and negative hashes
     (`negate`) find every key.
  7. **Persistence.** Earlier versions answer as before after later inserts, removes, promotion
     and compaction.
  8. **`map`, `fromList`, `values`, `foldl`.** They agree with `toList`, and duplicate keys in
     `fromList` keep the first position and take the last value.

### 10.6 Small-limit census (untimed, before the timed legs)

Add a report-only `hashmap|` line to `renderLssReport` (§4.4's pattern). It shows the size
histogram of the `HashMap`s that `S` holds at report time (buckets 0, 1–4, 5–8, 9–32, 33–1K, >1K),
from `HashMap.stats`. Run it once.
- If most maps under 32 entries sit just above 8, try `smallLimit = 16` in one extra census run.
- Keep the limit with the smaller total of `stats.nodes` plus list cells.
- Record both runs in the C1 entry.

The census sees only the maps reachable from `S`; per-item scratch maps are gone by then. Say so
in the entry.

### 10.7 BI argument

Every observable of `HashMap` is preserved: lookup results, the first key kept on replace, the
count, and iteration in insertion order. The trie shape is internal. The compiler's output
therefore cannot change. The BI gate is the proof: a failure is a contract bug in C1, not a reason
to reclassify it.

## 11. C2: Intern on the CHAMP `HashMap`, against H1

**Precondition:** H1 and C1 are both kept.

**The change** (`compiler/src/Compiler/AST/Intern.elm`) is H1's §4.3 in reverse, onto the new
`HashMap`:
1. Import `Data.HashMap as HashMap` in place of `Data.HashTable`.
2. Type the `Intern` and `ReadOnly` tables as `HashMap.HashMap`.
3. Restore `canonEq` (it was deleted in H1), because `HashMap.insert` needs an `eq`.
4. In `probe`, use `HashMap.insert canonHash canonEq (canonOf mt) mt m`.
   - Its membership check is a redundant descent on the ~1 % miss path. Leave it: an unchecked
     `insertNew` does not belong in the general `HashMap` API.
5. `putWiden` uses `HashMap.insert Mono.specHashOf widenEq`.
6. `size` and `entries` use `HashMap.size`.
7. `stats` returns `HashMap.Stats`, and the `intern|` line (§4.4) prints its fields.
8. Delete `nodeTableCapacity` and `widenTableCapacity`.

**Census (untimed).** Record the `intern|` line: trie depth, node count, collision nodes.

**Timed.** Paired legs against the H1-kept compiler.

**Decision:**
- **If the median paired difference is within the resolution (≤ 0.4 s) or faster: keep C2.**
  Then delete `Data.HashTable` and `HashTableTest.elm`, so there is one hash structure in the
  compiler instead of two. Record it in the entry.
- **If it is slower beyond the resolution: revert.** Keep H1, and record the gap. It measures what
  the specialised table is worth.

**BI:** yes. Intern's contract (§1.1) only needs insert-only, first-wins behaviour and an exact
count, and `HashMap` provides both.

## 12. C3: the hot primitives via kernel calls and existing ops

**Decision (2026-09-30).**
- The trie logic stays in Elm (C1's module). Only its hot primitives leave pure Elm.
- **Nothing is added to the eco dialect.**
- popcount becomes a gc-leaf C++ kernel call, not an inline op.
- The allocation-free read reuses the existing `eco.array.get`.
- insert-at and remove-at become allocating C++ kernel calls.

**Precondition:** C1 kept (C3.0 is independent).

**First, one untimed profile of the C1-kept compiler.** Use `perf record` on the self-compile,
as in `plans/lss-compile-time-optimizations.md` §1. Record the self time of the trie functions
(`lookupNode`, `insertNewNode`, `removeNode`, `Data.Bits32` / popcount, `Array.get` and the
`Array` slice/append path) in the C3 entries. **Skip any sub-step whose target shows under 0.2 %
self**; its ceiling is below the loop's resolution.

### 12.1 Facts this section relies on (code reading, 2026-09-30)

**Kernel dispatch keys on the home name only.**
- `Intrinsics.kernelIntrinsic home name …` (`Generate/MLIR/Intrinsics.elm:376-401`) switches on
  the kernel's home module name. The `Elm`/`Eco` prefix is dropped at both call paths
  (`Generate/MLIR/Expr.elm:4088-4097, 4419-4441`).
- `KernelFacts`, `KernelSetFacts`, `KernelAbi.kernelInstanceSymbol` and `suffixSelectingKernels`
  are all keyed by `(home, name)` as well.
- A new kernel home must not collide with elm/core's. `Bits` and `NodeArray` are free;
  `Bitwise` and `JsArray` are not.

**eco/kernel modules may call `Elm.Kernel.JsArray.*` directly.**
- `Package.isKernel` includes the `eco` author (`Elm/Package.elm:124-126`).
- Canonicalize accepts any kernel-prefixed name in a kernel package
  (`Canonicalize/Expression.elm:1431-1436`).
- A kernel that is not in the package crawls as `SKernelForeign` (`Builder/Elm/Details.elm:1695-1702`).
- JS resolves kernels by short name (`GraphAssembly.elm:103-105`). The precedent is `MVar.js`
  importing `Eco.Kernel.Scheduler`.
- Such calls inherit JsArray's C symbols, KernelFacts rows, KernelSetFacts `Transports` rows and
  suffix arms.

**gc-leaf has exactly one source** (CGEN_072(f)): a `KernelFacts` row whose `gcAlloc = GcNone`
and `callsBack = HofNo`.
- The chain: `KernelFacts.elm:116-119, 216-224` → `Context.elm:760-768` → `eco.gc_leaf` on the
  kernel declaration (`Functions.elm:2215-2223`, default-on `kernelGcLeaf`) →
  `attachGcLeafPassthrough` (`EcoToLLVMFunc.cpp:47-49, 99-100`) and `EcoMarkGCLeafCalls`.
- `KernelFactsTest.elm:66` pins the row count at 57.
- KERNEL_FACTS_001 requires an evidence anchor on every row.

**`Eco.Hash` has no row, so its calls are statepointed today.** This contradicts
`eco-kernel-cpp/src/Eco/Hash.elm:13-15` and the GC note in `Hash.hpp`.

**Heap arrays carry one element kind per array, not per slot.**
- The kind is `header.unboxed` bits 1:0 (`runtime/src/allocator/Header.hpp:128-133`).
- The GC traces `elements[0..length)` only when that kind is 0 (`NurseryChildWalk.hpp:93-97`).
- HEAP_019's mention of ElmArray is therefore stale wording (§15).
- Insert and remove copy the source's kind; there is no bitmap to shift. Allocate exactly the new
  length, because elements beyond `length` are not traced.

**How the existing array ops lower** (`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`):
- **`eco.array.get`** (`:1348-1395`) is an inline typed load at `16 + 8·i`, with no bounds check.
- **`eco.array.set`** (`:1400-1492`) calls `eco_clone_array` and then `eco_array_set_fix_kind`.
  Both are non-gc-leaf, so it carries two statepoints.
- **`empty`, `singleton`, `push`, `slice` and `append_n`** (`:1501-1611`) call runtime trampolines
  (`elm_array_*`, `JsArrayExports.cpp:665-1060`).
  - Every allocation goes through `alloc::allocArray` → `eco_alloc_with_roots` and is
    statepointed.
  - A node array is at most 16 + 33·8 bytes, far below the large-object threshold, so HEAP_062
    never applies.

**How the array element type is recovered.**
- `arrayElementType` (`Intrinsics.elm:873-883`) recognises `MCustom _ _ "JsArray" [elt]` and
  `"Array"` by type name.
- For any other array type:
  - `unsafeGet` inlines only when its result is an unboxed primitive (`:958-966`);
  - otherwise it calls `Elm_Kernel_JsArray_unsafeGet`, which is non-gc-leaf, with an `unaudited`
    row (`:909-916`).

**LLVM will not produce a native popcount from a JS-safe form.**
- In LLVM 21.1.8, `default<O2>` (which includes `aggressive-instcombine`) recognises only the
  classic SWAR with full-width masks and a final multiply as `ctpop`. This was checked with the
  toolchain's `opt` on test IR.
- The JS-safe forms are not recognised: 32-bit masks on i64, or `Compiler/Data/BitSet.elm:101-118`'s
  multiply-free version.
- The dev tier (O1) does not run the pass at all.
- So a kernel is the only way to get the native instruction without a new op.

**Wiring a new eco kernel home.** Template: `Eco.Hash`.
- **Elm, two copies with identical exports:**
  - the pure twin, `compiler/src-xhr/Eco/<X>.elm`;
  - the kernel wrapper, `eco-kernel-cpp/src/Eco/<X>.elm`, with annotated eta-free aliases
    (TYPE_KERNEL_001).
- **JS kernel:** `eco-kernel-cpp/src/Eco/Kernel/<X>.js`, with an empty `/*\n*/` header and
  `var _<X>_<name> = …`. It runs in bootstrap stages 3–5 and in the AOT E2E runner.
- **C++:** `eco-kernel-cpp/src/eco-kernel/<X>.hpp`, `<X>.cpp` and `<X>Exports.cpp`. The export is
  `<ret> Eco_Kernel_<X>_<name>(args in Elm order)`, with a prototype in
  `eco-kernel-cpp/src/eco-kernel/KernelExports.h`.
- **`eco-kernel-cpp/elm.json`:** add the module to `exposed-modules`.
- **CMake, five places:**
  - `eco-kernel-cpp/CMakeLists.txt`: the `add_library(EcoKernel_<X> …)` target, the `EcoKernel`
    interface list (:279) and the asserts list (:290);
  - `runtime/src/codegen/CMakeLists.txt:923` `ECO_KERNEL_MODS`;
  - `compiler/CMakeLists.txt:753, 813, 848` (the archive lists);
  - `test/CMakeLists.txt:165-256` (force-load).
- **Operational:**
  - `rm -rf ~/.eco/0.1.1/packages/eco/kernel`. The seeded package copy is not refreshed by edits
    (`Builder/Elm/Details.elm:948-985`).
  - Re-run the CMake configure, because the `KERNEL_SOURCES` glob has no `CONFIGURE_DEPENDS`
    (`compiler/CMakeLists.txt:252-255`).

**Which twin runs at each bootstrap stage** (`compiler/CMakeLists.txt`, `docs/bootstrap.md:3-8`):
- Stage 1 (`guida.js`, from stock `elm make` without `--optimize`) contains the **pure** twins.
- Stages 3–5 (`eco-boot*.js`) run the **JS** kernels.
- Stage 6 onward (native) run the **C++** kernels.
- The eco-kernel E2E pins are compiled by `guida.js` and run against the C++ kernels.

### 12.2 C3.0: make `Eco.Hash`'s kernels gc-leaf

1. **Audit** `eco-kernel-cpp/src/eco-kernel/HashExports.cpp` and `Hash.cpp` for both exported kernels,
   `stringWithSeed` (export at `HashExports.cpp:8`) and `string64`. Each must:
   - not allocate;
   - not call back into Elm;
   - only read the string through its `HPtr`.

   If either fails the audit, stop: the documentation is wrong, not the facts table.
2. **Add two rows** to `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, next to the other
   audited-pure rows:
   ```elm
   ( ( "Hash", "stringWithSeed" ), { auditedPure | gcAlloc = GcNone, evidence = "eco-kernel-cpp/src/eco-kernel/HashExports.cpp:8" } )
   , ( ( "Hash", "string64" ), { auditedPure | gcAlloc = GcNone, evidence = "eco-kernel-cpp/src/eco-kernel/HashExports.cpp:<line>" } )
   ```
3. **Update** `KernelFactsTest.elm:66` from 57 to 59.

**Not BI:** the emitted `Eco_Kernel_Hash_*` declarations gain `eco.gc_leaf`.

**Effect:** every `TOpt.globalHash` (a `string64` call per lookup), `Store.aliasKeyOf` and
`groundHash` call stops spilling and reloading the caller's live pointers.

### 12.3 C3a: `Eco.Bits.popcount32`, a gc-leaf kernel

**Files** (§12.1 wiring, home `Bits`):
- **`compiler/src-xhr/Eco/Bits.elm`** (pure twin): `module Eco.Bits exposing (popcount32)`,
  containing C0's multiply-free SWAR (§9.1) moved here. A final multiply would lose precision
  above 2^53 under JS; the shift-and-add form never does.
- **`eco-kernel-cpp/src/Eco/Bits.elm`:**
  ```elm
  module Eco.Bits exposing (popcount32)

  import Eco.Kernel.Bits

  {-| Set bits in the low 32 bits of the argument. -}
  popcount32 : Int -> Int
  popcount32 =
      Eco.Kernel.Bits.popcount32
  ```
- **`eco-kernel-cpp/src/Eco/Kernel/Bits.js`:** `var _Bits_popcount32 = function(x) { … }`. Apply
  `x >>> 0`, then the same shift-and-add SWAR. It must match the pure twin on every input.
- **`eco-kernel-cpp/src/eco-kernel/Bits.hpp`, `Bits.cpp` and `BitsExports.cpp`:**
  ```cpp
  int64_t Eco_Kernel_Bits_popcount32(int64_t x) {
      return std::popcount(static_cast<uint32_t>(x)); // <bit>, C++20
  }
  ```
  The ABI is `(i64) -> i64`: `Int -> Int` has no type variables, so ElmDerived applies
  (`Generate/MLIR/KernelAbi.elm:78-89`, REP_ABI_001). Add the prototype to `KernelExports.h`.
- **`eco-kernel-cpp/elm.json`:** add `"Eco.Bits"` to `exposed-modules`.
- **CMake:** `EcoKernel_Bits` in the five places listed in §12.1.
- **`KernelFacts.elm`:**
  `( ( "Bits", "popcount32" ), { auditedPure | gcAlloc = GcNone, evidence = "eco-kernel-cpp/src/eco-kernel/BitsExports.cpp:<line>" } )`.
  `KernelFactsTest` goes up by one.
- **`compiler/src/Data/Bits32.elm`:** `popcount = Eco.Bits.popcount32`. `mask32`, `fragment`,
  `bitpos` and `below` stay in Elm.

**Tests:**
- `Bits32Test` passes unchanged against the pure twin.
- A new `test/eco-kernel/src/BitsPopcountTest.elm` pins the §9.2 table against the C++ kernel.
  Format: `-- CHECK: <Name>: True`, a `Debug.log` per row in `init`, and a `Platform.worker`
  `main`.
- C0's `test/elm/src/Bits32HostWidthTest.elm` stays. It still pins the Elm SWAR natively, and that
  SWAR is the JS and pure-twin algorithm.

**Not BI.** **It may lose:** a gc-leaf call replaces about 12 inline ALU ops. On a loss, revert.
`Data.Bits32` then keeps the SWAR, and the entry records the result, which is useful data for any
future "kernel vs inline" call.

### 12.4 C3b: `Eco.NodeArray` over elm/core's `JsArray` kernel

**No new kernel code.** The wrapper calls `Elm.Kernel.JsArray.*` directly (§12.1).

**`eco-kernel-cpp/src/Eco/NodeArray.elm`:**

```elm
module Eco.NodeArray exposing
    ( NodeArray
    , empty, singleton, length, get, set, push, slice, appendN, foldl, map
    )

{-| A small immutable array for hash-trie nodes. Natively it IS the `JsArray`
heap object: no elm/core `Array` wrapper, and `get` returns the element itself
(no `Maybe`).

  - Elements must be BOXED (custom types, records, …). Trie nodes hold only
    `Entry` and `Node` values. A heap array has ONE element kind
    (`Header.hpp:128-133`), and a primitive instantiation would bind an unboxed
    kind.
  - `get` and `set` do not check the index: `0 <= i < length` is the caller's
    job. CHAMP derives every index from a bitmap popcount.
  - Intended for at most 32 elements.

Every function is an annotated, eta-free alias of the elm/core kernel, the same
shape as `Elm/JsArray.elm`. That keeps KernelSetFacts' `Transports` licence and
TYPE_KERNEL_001 valid.

-}

import Elm.Kernel.JsArray


type NodeArray a
    = NodeArray a -- phantom, never constructed (elm/core's `JsArray` pattern)


empty : NodeArray a
empty =
    Elm.Kernel.JsArray.empty


singleton : a -> NodeArray a
singleton =
    Elm.Kernel.JsArray.singleton


length : NodeArray a -> Int
length =
    Elm.Kernel.JsArray.length


get : Int -> NodeArray a -> a
get =
    Elm.Kernel.JsArray.unsafeGet


set : Int -> a -> NodeArray a -> NodeArray a
set =
    Elm.Kernel.JsArray.unsafeSet


push : a -> NodeArray a -> NodeArray a
push =
    Elm.Kernel.JsArray.push


slice : Int -> Int -> NodeArray a -> NodeArray a
slice =
    Elm.Kernel.JsArray.slice


{-| `appendN n dest source` is `dest` followed by the first `n - length dest`
elements of `source` (elm/core's `_JsArray_appendN`).
-}
appendN : Int -> NodeArray a -> NodeArray a -> NodeArray a
appendN =
    Elm.Kernel.JsArray.appendN


foldl : (a -> b -> b) -> b -> NodeArray a -> b
foldl =
    Elm.Kernel.JsArray.foldl


map : (a -> b) -> NodeArray a -> NodeArray b
map =
    Elm.Kernel.JsArray.map
```

**`compiler/src-xhr/Eco/NodeArray.elm`** (pure twin) has the same exports over elm/core `Array`:
- `type NodeArray a = NodeArray (Array a)`.
- `get i (NodeArray a)` returns the element, or on `Nothing` calls
  `Eco.Crash.crash "Eco.NodeArray.get: index out of range"`. src-xhr twins import `Eco.Crash`;
  elm-review's NoDebug exempts only the Crash modules (`compiler/review/src/ReviewConfig.elm:42-44`).
- `appendN n (NodeArray d) (NodeArray s) = NodeArray (Array.append d (Array.slice 0 (n - Array.length d) s))`.

**`eco-kernel-cpp/elm.json`:** add `"Eco.NodeArray"` to `exposed-modules`.

**Codegen** (`compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`, `arrayElementType` at 873-883):
- Add an arm for `Mono.MCustom _ home "NodeArray" [ elt ]` that returns `Just elt` **only when
  `home` is the canonical `eco/kernel` module `Eco.NodeArray`**. Build it the way `Elm/Package.elm`
  builds the `eco` author, so an unrelated user type named `NodeArray` is not misread.
- The calls are `Elm.Kernel.JsArray.*`, so `kernelIntrinsic`'s existing `"JsArray"` arm does the
  rest:
  - `get` → `ArrayGet { elementMlirType = ecoValue }`, an inline load;
  - `set` → `ArraySet`;
  - `length` → inline;
  - `push`, `slice`, `appendN`, `empty` and `singleton` → the runtime trampolines;
  - an `MVar` element still declines, as for JsArray.

**`Data.HashMap` (C1)** switches its node storage from `Array` to `NodeArray`, mechanically:
- `Array.get` → `NodeArray.get` (drop the `case … Just`);
- `Array.set` → `set`;
- `Array.length` → `length`;
- `Array.empty` → `empty`;
- `Array.repeat 1 x` → `singleton x`;
- `Array.fromList [ e1, e2 ]` → `push e2 (singleton e1)`;
- `Array.foldl` and `Array.map` → `foldl` and `map`.

The helpers become:

```elm
insertAt : Int -> a -> NodeArray a -> NodeArray a
insertAt i x arr =
    let
        n =
            NodeArray.length arr
    in
    if i >= n then
        NodeArray.push x arr

    else
        NodeArray.appendN 32 (NodeArray.push x (NodeArray.slice 0 i arr)) (NodeArray.slice i n arr)


removeAt : Int -> NodeArray a -> NodeArray a
removeAt i arr =
    let
        n =
            NodeArray.length arr
    in
    if n <= 1 then
        NodeArray.empty

    else if i == n - 1 then
        NodeArray.slice 0 i arr

    else
        NodeArray.appendN 32 (NodeArray.slice 0 i arr) (NodeArray.slice (i + 1) n arr)
```

- `appendN 32` is safe: a node has 32 positions, so neither array can grow past 32.
- A mid-array edit is now 4 allocations (slice, push, slice, append), with no wrappers, no closure
  and no `JsArray.foldl` call. With `Array` it was about 9 plus a kernel call (§10.3).
- `NodeArray.empty` is a top-level constant, so it is memoised and shared, as the "keep the
  shared empty" rule needs.

**Tests:**
- A new `compiler/tests/Compiler/Generate/MLIR/IntrinsicsNodeArrayTest.elm`, modelled on
  `IntrinsicsListConsTest.elm`, which calls the exposed `kernelIntrinsic`:
  - `"JsArray" "unsafeGet"` with an `eco/kernel` `Eco.NodeArray` `NodeArray` of a custom type
    gives `Just (ArrayGet { elementMlirType = Types.ecoValue })`;
  - a `NodeArray` from another module is not treated as an array;
  - an `MVar` element gives `Nothing`.
- A new `compiler/tests/TestLogic/NodeArrayTest.elm` tests the pure twin against a `List` model
  for every operation, including `appendN`'s truncation and `get`'s precondition.
- New `test/eco-kernel/src/NodeArrayRoundtripTest.elm` and `NodeArrayGcSurvivalTest.elm` (modelled
  on `CellStoreGcSurvivalTest`) run natively. Elements are records. They cover `get`, `set`,
  `push`, `slice`, `appendN` and the two helpers, across forced minor GCs.
- `HashMapTest` and `HashMapChampTest` pass unchanged against the pure twin.

**Lowering evidence.** In the C3b entry, record `grep -c 'eco.array.get'` and the count of
`Elm_Kernel_JsArray_unsafeGet` calls in the self-compile MLIR, before and after. `get` must lower
inline inside `HashMap`'s specialised functions.

**Not BI:** the `Intrinsics` arm and `HashMap`'s code change the emitted MLIR.

### 12.5 C3c: `insertAt` and `removeAt` as single-allocation C++ kernels

New kernel home: `NodeArray`, for `Eco.Kernel.NodeArray.insertAt` and `removeAt`.
`Eco.NodeArray`'s other functions stay on `Elm.Kernel.JsArray`.

**Elm (`eco-kernel-cpp/src/Eco/NodeArray.elm`).** Add `import Eco.Kernel.NodeArray` and the
exports:
```elm
insertAt : Int -> a -> NodeArray a -> NodeArray a
insertAt =
    Eco.Kernel.NodeArray.insertAt

removeAt : Int -> NodeArray a -> NodeArray a
removeAt =
    Eco.Kernel.NodeArray.removeAt
```
The pure twin gains the same two, implemented with `Array` slices. `Data.HashMap`'s helpers call
them directly, and the peeled cases can go.

**JS (`eco-kernel-cpp/src/Eco/Kernel/NodeArray.js`).** A JsArray is a plain JS array:
```js
var _NodeArray_insertAt = F3(function(i, x, arr) { var r = arr.slice(0, i); r.push(x); return r.concat(arr.slice(i)); });
var _NodeArray_removeAt = F2(function(i, arr) { return arr.slice(0, i).concat(arr.slice(i + 1)); });
```

**C++ (`eco-kernel-cpp/src/eco-kernel/NodeArray.cpp` and `NodeArrayExports.cpp`).** The signatures are
`HPtr Eco_Kernel_NodeArray_insertAt(int64_t i, HPtr x, HPtr arr)` and
`HPtr Eco_Kernel_NodeArray_removeAt(int64_t i, HPtr arr)`. The type variable `a` is erased to
boxed, and arguments are in Elm order. Follow `elm_array_push_box` (`JsArrayExports.cpp:775-798`):
1. `Export::decode` both pointers, and root them with `StackRootGuard guard(&srcHP, &valHP)`
   (`HeapHelpers.hpp:124`).
2. Read `len`, then allocate **exactly** `len + 1` (insert) or `len - 1` (remove) with
   `alloc::allocArray`. This may run a minor GC.
3. **Re-resolve `src` after the allocation.**
4. Copy `[0, i)`. Insert writes `x` at `i` and copies `[i, len)` to `[i + 1, len + 1)`; remove
   copies `[i + 1, len)` to `[i, len - 1)`.
5. Set `dst->length` and copy `dst->header.unboxed` from `src`. For node arrays this is always
   kind 0 (boxed).
6. Under `ECO_HEAP_VALIDATE`, assert `(src->header.unboxed & 3) == 0` and run the
   `validateNurseryHPtr` loop that `push` runs.

No builder bit is needed, because nothing allocates between `allocArray` and the last write.
Writes go only to the fresh `dst`, which satisfies HEAP_SNAPSHOT_001. Add the prototypes to
`KernelExports.h`.

**Wiring:**
- CMake: `EcoKernel_NodeArray` in the five places listed in §12.1.
- `Eco.NodeArray` is already exposed by C3b.

**Compiler tables:**
- **Compile-time boxed-only guard.** In `Generate/MLIR/KernelAbi.elm`'s `kernelInstanceSymbol`,
  crash for `("NodeArray", "insertAt")` at a primitive element type. This mirrors the CellStore
  guard at 406-431.
- **`KernelSetFacts` rows** mirroring JsArray's `push`/`unsafeSet` `Transports` rows
  (`KernelSetFacts.elm:1461-1558`). Without them, the kernel boundary poisons lambda-set precision
  (LSS_004/LSS_022). This is performance only.
- **No gc-leaf row:** both kernels allocate. A `KernelFacts` row with the allocating class is
  optional documentation.

**Tests:**
- A new `test/eco-kernel/src/NodeArrayInsertRemoveTest.elm` (native), covering:
  - insert at index 0, in the middle and at the end;
  - insert into an empty array;
  - remove down to empty;
  - a loop that allocates garbage between operations to force minor GCs.

  Run it once in the `dev` preset as well, where `ECO_HEAP_VALIDATE` is on.
- The pure-twin model test (`NodeArrayTest`) gains both functions.

**Not BI.**

### 12.6 Measuring C3

- **Every C3 step is NOT BI.** Use the loop's NOT-BI path: Phase 1.5 (the extra bootstrap turn to
  a new fixed point) plus the workload rail (`benchmarks/mlir-workload-rail.sh`), per loop §0 and
  §1.
- **Order:** C3b → C3c → C3a (the likeliest loss last), with C3.0 anywhere. Drop any sub-step the
  §12 profile rules out.
- **References:** each step is compared against the last kept compiler. C3a is expected to be
  close; its verdict is the loop's ordinary win-or-revert.

## 13. Measurement and gates

Use the loop protocol in `benchmarks/lss-compile-opt-loop.md` §1 unchanged: native only, the
compiler builds itself, three cold legs, verdict against the last kept compiler, gates on a win.
Additions for this plan:

- **Snapshots.** The loop's `snapshots/lss-loop/` directory is not present in this container.
  Start a new series: `benchmarks/lss-loop-snap.sh snap base-hg "intern-hashtable-and-global-ids series start"`.
  Take `try-<step>` before each build and `keep-<step>` on a win, as §1 describes.
- **Phase 0 again.** The runtime has changed since the loop's last row (the threaded-GC series), so
  none of its reference numbers carry over. Measure the tree's fixed-point compiler first, three
  cold legs. Its spread is this series' noise band.
- **Paired legs.** Every estimate in §2 is below or near the loop's unpaired resolution (about
  6 s spread). Use the interleaved-pair form (loop entry 15's method: three ref/cand pairs, median
  paired difference, about 0.4 s resolution) for every step. The triple is still recorded for the
  GC counters.
- **Verdict:** as in loop §1 Phase 3. A step with a flat wall but improved minor GC count or
  promotion is recorded as a no-win and reverted, unless a later step depends on it (G1 → G2/G3).
  In that case G1 is kept on the condition that G1+G2 together are judged against the reference
  before G1.
- **The BI gate, for every step:** the candidate compiler's self-compile MLIR is byte-identical to
  the reference's (`cmp`), and the fixed point holds. If a step marked BI fails this, it is a bug:
  stop and diagnose. Do not reclassify it.
- **Gates on a win:**
  - unit tests: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`, run
    once, per CLAUDE.md;
  - E2E: `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`;
  - record the pass counts in the entry.
- **H1's census (§4.5) is an untimed run**, done before the timed legs. It is never inside one
  (loop rule: "No census of any kind runs inside a timed leg").
- **C0 is not timed.** Its gate is the unit suite (`Bits32Test`) plus the E2E suite
  (`Bits32HostWidthTest`), both green, before C1 starts.
- **C1 against step 17.** Put the minor-GC and promoted-MiB deltas next to step 17's (+25 minor
  GCs, −9 MiB) in the entry. The small form exists to beat exactly that population. If C1 loses
  on minor GCs while the `hashmap|` census shows most maps above `smallLimit`, record it and try
  the census's alternative `smallLimit` once (as `try-C1b`) before reverting.
- **C2 is a comparison.** Its reference is the H1-kept compiler, and its decision rule is §11's,
  not "win or revert".
- **C3 is NOT BI throughout.** It follows §12.6: Phase 1.5 plus the workload rail, with its own
  untimed profile first.
- **Entries.** Append `H0`, `H1`, `G0`, `G1`, `G2`, `G3`, `C1`, `C2`, `C3.0`, `C3a`, `C3b` and
  `C3c` to `benchmarks/lss-compile-opt-loop.md`, in the existing entry format: table of legs,
  deltas, mechanism, gates, kept/reverted, and patch size from `lss-loop-snap.sh diff`.
- **Stopping rule.**
  - If H1 loses on its own, record it and stop Track H. Do not retry it as a change to all
    HashMaps (§0). C can still run: C1 does not depend on H1's result, only on the ordering.
  - If G1 loses with the `gid|` census showing many id-less globals, stop Track G and report,
    because the fallbacks are then the hot path.
  - If C1 loses after its one retry, stop Track C and keep `Data.HashMap` as it is. The loss
    measures what pure-Elm node storage costs (§10.3) and is the input to any native-node
    decision.

## 14. Deliberately not done

| Item | Why not |
|---|---|
| `S.lssInProgress` → id-indexed | It is tiny (the current unit's members) and hottest in `applyCalleeAt`, which has no id in hand. An `idOf` probe over 10–20 K globals plus `Array.get` costs more than a `HashMap` probe over a handful. 21a showed the same for `BitSet`. |
| `collectReferencedGlobals` (L:553) → `Dict Int` | Its `Dict.values` order (string order) decides the order in which `signatureFor` is forced, and so member-id minting. Id order equals string order only for globals that have ids; merging in id-less ones would reorder. Revisit only if the `gid|` census shows `idless=0` on the workload, as an optional G4 with its own BI gate. |
| `Registry.countByGlobal` (`Monomorphized.elm:3052`, `Registry.elm` 79-90) | Engine-agnostic (the subst engine and Prune share it), and only about 41 K creates per run. Seven test literals would change (PostSettleDevirtTest:265, CafHoistTest:179, AbiCloningFlatPeelPassTest:224, AbiCloningFenceTest:191, AbiCloningPapFastPassTest:389, BorrowFenceTest:129, CafDedupeTest:189) for a small gain. |
| `SpecKeyMap` (`registry.mapping`, `callMemo`) keyed by id | `SpecKey` holds a `Mono.Global` hashed with `Mono.globalHash` inside the engine-agnostic registry. That is a registry redesign, not this plan. |
| Member-identity keys (`LssMemberTable.byKey`, 62,647 string keys) | That is old step 13, which needs G1's ids first. It is a separate plan. |
| `Data.HashTable` for `GlobalTable.ids` | It would fit (big, built once, about 10^6 probes). This plan restricts `Data.HashTable` to Intern, as asked. Consider it after H1's result is known. |
| A mutable kernel table for Intern | It would need an off-heap store with a root scanner (HEAP_005, HEAP_047) and a pure twin, and it would break the persistence Intern relies on (§1.1). The ceiling is too low to justify that. |
| A native CHAMP (trie logic in C++) | It would duplicate the trie across three implementations (C++, JS and the pure twin) and would have to call back into Elm for `eq`. C3 takes the same hot costs (§10.3) out of pure Elm with kernel calls and existing ops, and leaves one trie implementation. Decided 2026-09-30. |
| New eco dialect ops (an inline `ctpop`, `array.insert`/`array.remove`) | Decided 2026-09-30: no dialect additions for this. popcount is a gc-leaf kernel call (C3a), and insert and remove are allocating kernel calls (C3c). `LLVM::CtPopOp` would be reachable (`EcoToLLVMArith.cpp:275` already uses LLVM-dialect ops), and that note stays here in case C3a's measurement ever argues for it. |
| A generic `hashable` hash (a structural hash consistent with `==`, crashing on functions like `==` does) | It has to be a kernel function: pure Elm has no reflection, so its stock-Elm twin cannot be generic. A constant-hash fallback is correct but O(n) per lookup, unusable for Intern-sized maps in stage 1. Compiler-internal maps keep explicit `hash` functions. This needs a design plan of its own (hash rules against `eqHelp`, `Utils.cpp:507`; host-independent string hashing over code points; iteration-order semantics if it ever becomes public). |
| Canonical `==` on `HashMap`s | CHAMP's canonical shape would make structural `==` depend on content only, but the sequence numbers (contract 4) keep it history-dependent, and nothing compares maps with `==`. |
| Demoting a trie back to the small form on `remove` | Maps rarely shrink. It adds a size check to every `remove` for no measured benefit. |
| CHAMP for core `Dict` | That is the closed Dict→HAMT avenue (§0). `Dict`'s key-order contract is incompatible. |

## 15. Documentation to update when steps land

- **`plans/lss-compile-time-optimizations.md`:**
  - Mark step 12 (the §2 row near 272 and the §9 spec at 5715-6086) "superseded by
    `plans/intern-hashtable-and-global-ids.md` Track G". Its line numbers and `Result`-based code
    are stale (for example `Step` no longer returns `Result`).
  - Mark step 17 (§2 row at 336, spec at 7853) "not retried as specified; the Intern-only variant
    is this plan's H1, and the all-HashMaps variant is Track C (CHAMP with a small form)".
- **`Compiler/AST/Intern.elm` module docs** (§4.3 item 11), and the `Data.HashTable` module doc.
  If C2 is kept, delete the latter along with the module.
- **`Data.HashMap` module doc** (§10.4), and `Data.Bits32`'s doc, which carries the three
  host-width rules.
- **`Eco.Hash`'s gc-leaf claim** (`eco-kernel-cpp/src/Eco/Hash.elm:13-15`, the GC note in
  `Hash.hpp`). It becomes true when C3.0 lands. If C3.0 is dropped or loses, correct the docs
  instead.
- **HEAP_019** says ElmArray has a per-slot 2-bit bitmap. The code gives an array one uniform kind
  (`Header.hpp:128-133`, `NurseryChildWalk.hpp:93-97`). Fix the invariant text.
- **Two findings for the runtime, not fixed by this plan.** Record them in a register or a small
  plan of their own:
  1. **Possible element-kind bug** (from code reading, not verified). The boxed-root paths of
     `Elm_Kernel_JsArray_push` (`JsArrayExports.cpp:304`) and `unsafeSet` (`:256`) appear to set
     the array's kind to 1 (Int) for any unboxed source. That would be wrong for Float and Char
     arrays when the intrinsic declines (an element-polymorphic wrapper). It needs a reproducing
     E2E test before anyone acts on it.
  2. **A small inefficiency.** `eco_array_set_fix_kind` never allocates but is declared
     non-gc-leaf (`EcoToLLVMRuntime.cpp:1048-1054`), so every `eco.array.set` carries two
     statepoints. A `gcLeaf = true` on that declaration would be a separate micro-step.
- **Invariants: `Bitwise` width.** Consider a documented `CrossPhase` row. It would say that
  native `Bitwise` is 64-bit, that JS is 32-bit, and that code which must agree across hosts
  follows `Data.Bits32`'s rules. It would cite `BitwiseLargeShiftTest` and `Bits32HostWidthTest`.
  Today nothing in `invariants.csv` records the divergence, and C1's correctness on one host
  depends on it.
- **`Engine.elm` comments** that describe `S` as being at the 32-slot cap (E:1387, 1390, 1415-1419,
  1579). Correct them to "31 of 32" wherever this plan touches the adjacent lines.
- **Invariants.** None are added or changed. If G1 lands, consider one documented invariant: "global
  ids are dense and minted in ascending `toComparableGlobal` order; no decision reads an id's
  numeric value." BI depends on it, and nothing else enforces it.
