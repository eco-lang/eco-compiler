---
status: partial
remaining: "Final gates; stage X (exploration, at the end)"
updated: 2026-11-23
---

# Faster SeqDict and SeqSet, and `eco.hash`

eco/system's `SeqDict` (`system-kernel-cpp/src/SeqDict.elm`) and `SeqSet` (`SeqSet.elm`, a
`SeqDict a Bool`) are dictionaries and sets whose keys need not be `comparable` and whose folds run
in insertion order. This plan:

1. makes them faster and smaller: a canonical hash trie with tagged slots, one shared entry object
   per key, structural compaction and bottom-up bulk construction, and a hardware popcount;
2. makes hashing any value a feature of eco: an `eco.hash` op with type-directed code, a public
   `Hash` module, and cached String hashes;
3. ends with an exploration of cached hashes in other heap objects.

The plan is in implementation order. §5 holds the procedures every step refers to; §6 holds the
work packages. Each work package lists what it depends on, its steps, its tests and its exit
criteria, and ships as its own commit(s) (messages per `GITSTYLE.md`, no attribution trailers).
§8 records the adversarial review of 2026-11-23 and what changed because of it.

## 1. Where things stand (verified 2026-11-23)

```elm
type SeqDict k v = SeqDict_elm_builtin Int (NodeArray k v) (IntDict k v)   -- root bitmap, root nodes, order
type alias NodeArray k v = JsArray2 (Node k v)
type Node k v
    = Leaf Int Int k v                     -- hash, order index, key, value
    | SubTree Int (NodeArray k v)          -- bitmap, nodes
    | Collision Int (List ( Int, k, v ))   -- hash, (order index, key, value)
type alias IntDict k v = { size : Int, array : Array (Maybe ( Int, k, v )) }   -- (hash, key, value)
```

- **The trie** answers `get`, `member`, `insert`, `remove`, `update`, `updateIfExists`: a HAMT on
  `FNV.hash`, 5 bits per level (`shiftStep`, `:94`), 32-way nodes compressed by a bitmap,
  `Collision` when two keys share all 32 hash bits.
- **The order array** drives `foldl`, `foldr`, `toList`, `keys`, `values`, native and JS `==`
  (`SeqDict.hpp`, `SeqDictEquality.js`) and `FNV.hash` of a SeqDict. A removal leaves a `Nothing`.
- `rebuildOnOverflow` (`:243`) runs *before* each `remove` (`:430`), each `update` to `Nothing`
  (`:555`) and each removal in `diff` (`:864`); when fewer than 80 % of the order slots are live it
  rebuilds the whole dict with one `insertHelp` per entry. In seqdict-churn it is 57 % of the time.
- `removeHelp` never collapses a `SubTree` left with one `Leaf`, and copies the path even when the
  key is absent. `getHelp` and `removeHelp` compare keys with `==` without comparing hashes first.
- `map` (`:664`) calls the user function twice per entry (trie order, then order array).
  `filter`, `filterMap`, `partition`, `intersect` rebuild by `insertHelp` with stored hashes;
  `union t1 t2` inserts `t1`'s entries into `t2`; `diff t1 t2` removes `t2`'s keys from `t1`;
  `merge` removes from its right dict without `rebuildOnOverflow` (`:897`) and builds no dict.
- Replacing a present key: the `Leaf` path keeps the old key in the trie and the new key in the order
  array (`:288-291`); the `Collision` path stores the new key in both (`:355-360`).
- `compressedIndex` (`:196`) is a software popcount; LLVM inlines it (about 16 instructions with an
  `imul` per level) and emits no `popcnt`, although eco targets `x86-64-v3`/`apple-m1`
  (`runtime/src/codegen/EcoBackend.h:68-77`).
- `JsArray2` operations are out-of-line kernel calls (`JsArray2Exports.cpp`). elm/core `JsArray` has
  intrinsics, but `kernelIntrinsicOn` (`Compiler/IR/Kernel/Intrinsics.elm:148`) matches the home
  `"JsArray"` only.
- `FNV.hash` (`FNV.elm` → kernel `Eco.Kernel.FNV.hash`): a primitive key is boxed (`eco.box`), the
  call goes out of line to `Eco_Kernel_FNV_hash` (`FNVExports.cpp:218`), which walks the value by
  heap tag. Flat UTF-16 Strings are mixed one unit at a time through `StringOps::charAt`; UTF-8
  forms byte by byte. Nothing is cached.
- **Layout couplings** (code outside `SeqDict.elm` that reads its fields):
  - `elm-kernel-cpp/src/core/SeqDict.hpp` `forEachSeqDictEntry` (used by `Utils.cpp` `seqDictEq`
    and `FNVExports.cpp:162-171`): reads `values[2]` as the order Record, finds its Array field,
    reads each element as a bare `Tuple3` (nullable `Just`) or a `Just` Custom holding one.
  - `system-kernel-cpp/src/Eco/Kernel/FNV.js` `_FNV_seqDictEntries` (`:82-90`): reads
    `seqDict.c.__$array`, and `slot.a.b` / `slot.a.c` as key / value.
  - `compiler/kernel-overrides/SeqDictEquality.js`, `test/scripts/js-kernel-overrides.test.js`:
    depend only on the constructor name and the `-3` tag.
  - `CTOR_SEQDICT` (0xFFFB): `CtorTag.elm:81-83,194-197`, `GenerateJs/Expression.elm:433-442`,
    `Heap.hpp:436`, `test/scripts/check-ctor-tags.sh`.
- **Kernel ownership and visibility.** `Visibility.kernelOwned` (`Visibility.elm:83-84`) lists
  `eco/system:SeqDict.SeqDict` and `eco/system:SeqDict.Node` (group comment: reserved tags,
  `Utils.cpp`/FNV special cases); `Utils.equal`/`notEqual` are
  `Inspects [SeqDict.Node, SeqDict.SeqDict, Dict.Dict]` (`:400`). Because `Node` is a visibility
  root and `Collision`'s field `List ( Int, k, v )` is not a bare type variable, the users' key and
  value types of every SeqDict are kernel-visible today and so keep their heap representation.
- **`Debug.toString` of a SeqDict prints its internals** on both backends (the native typed printer
  special-cases only Dict, Set and Array, `RuntimeExports.cpp:3744-3756`), and the two backends
  already print different things.
- **Tests**: `test/eco-system/src/SeqDict{Order,Churn,Equality,KeyKinds,Randomized}Test.elm`,
  `SeqDictModel.elm`, `SeqSetTest.elm`; the same files run on native JIT (`check`/`full`), native
  AOT (`run-aot-e2e`) and JS (`run-js-e2e`). `compiler/tests` has no SeqDict tests.

## 2. Baseline and profile

`/work/local-dev/pre-seq-bench.json` (2026-11-23, before any change; 24 workloads in
`examples/benchmarks/`; median of 11 runs; each workload and backend in a fresh process). Work
package P7 adds asymmetric workloads and re-records this file before any implementation change.

| workload | size | native ms | twin native ms | eco-js ms | native peak MiB (twin) |
|---|---:|---:|---:|---:|---:|
| seqdict-int | 200,000 | 131 | 129 (dict-int) | 253 | 498 (326) |
| seqdict-string | 130,000 | 91 | 139 (dict-string) | 217 | 414 (284) |
| seqdict-tuple | 150,000 | 105 | 132 (dict-tuple) | 230 | 447 (290) |
| seqdict-custom | 150,000 | 116 | — | 276 | 465 |
| seqdict-churn | 300,000 | 371 | — | 832 | 277 |
| seqdict-update | 300,000 | 180 | — | 418 | 316 |
| seqdict-iterate | 100,000 | 427 | — | 842 | 386 |
| seqdict-small | 300,000 | 233 | — | 377 | 269 |
| seqdict-equality | 100,000 | 405 | — | 957 | 646 |
| seqdict-algebra | 56,000 | 211 | 114 (dict-algebra) | 422 | 501 (371) |
| seqset-distinct | 230,000 | 163 | 130 (set-distinct) | 413 | 378 (307) |
| seqset-algebra | 70,000 | 208 | 120 (set-algebra) | 415 | 528 (387) |
| seqdict-longkey | 40,000 | 265 | 282 (dict-longkey) | 709 | 384 |
| seqdict-longkey-reuse | 40,000 | 355 | — | 789 | 442 |
| seqdict-intern | 40,000 | 343 | 281 (intern-cached-hash) | 1,352 | 330 |
| intern-rehash | 40,000 | 359 | — | 1,117 | 273 |

Profile (`sudo -n perf`, eco-native, default sizes, inclusive % of samples, DWARF call graphs):

| | int | string | custom | churn | iterate | algebra |
|---|---:|---:|---:|---:|---:|---:|
| `rebuildOnOverflow` | — | — | — | **57 %** | — | — |
| `copyArray` (`JsArray2` set/insert copies) | 21 % | 17 % | 17 % | 34 % | 17 % | 20 % |
| GC survivor copying (`evacuateR`) | 21 % | 20 % | 21 % | — | 12 % | 19 % |
| array reads (`JsArray_unsafeGet_Int`) + out-of-line `resolve` | 16 % | 14 % | 14 % | 15 % | — | — |
| `filter` (insert per entry) / `map` (fn twice, both structures) | — | — | — | — | 31 % / 13 % | — |
| hashing (`Eco_Kernel_FNV_hash`) | 0.8 % | 1.0 % | 1.4 % | — | — | — |

Single-key operations match `Dict`; churn is dominated by compaction; bulk operations rebuild one
insert at a time; every update copies whole node arrays; memory is 1.3–1.5× `Dict`'s. Hashing is
small: track D is justified as a feature of eco, not by this profile.

## 3. Constraints

### 3.1 Semantics contract

Every rule below is pinned by a test (existing, or added in P3) before the code it concerns changes.

1. Folds, `toList`, `keys`, `values` run in insertion order.
2. `insert` of a present key keeps its position and stores the *new* key object and value.
   `update`/`updateIfExists` store the *argument* key object.
3. `fromList` with duplicates: the first occurrence's position, the last occurrence's key object and
   value. `SeqSet.map` with colliding images: first position, last key object.
4. `union t1 t2`: `t2`'s order; for keys in both, `t1`'s key object and value at `t2`'s position;
   then `t1`'s other keys in `t1`'s order.
5. `intersect t1 t2`: `t1`'s order, key objects and values, for keys present in `t2`.
6. `diff t1 t2`: `t1`'s order, key objects and values, for keys absent from `t2`.
7. `merge`: visits the left keys in order (calling `bothStep` or `leftStep`), then the right-only
   keys in order.
8. `filter`, `filterMap`, `partition`: kept entries in original order.
9. `==` compares entries in insertion order (holes ignored); `unorderedEquals` ignores order.
10. A `NaN` key is never found (`NaN /= NaN`): inserting it twice gives two entries.
11. **Changed on purpose by S1 (accepted):** `map` calls its function exactly once per entry, in
    insertion order. Observable only through `Debug.log` inside the function.
12. **Unspecified (decided in P8):** `Debug.toString` of a SeqDict or SeqSet value. It prints internals
    today and differs between backends; no test may pin it.
13. **Unspecified:** the numbers `FNV.hash` / `Hash.hash` return, except that equal values give equal
    numbers within one compiled program on one backend (§4.6).

### 3.2 Engineering constraints

- The public API of `SeqDict` and `SeqSet` does not change (D3 adds a new module).
- Native JIT, native AOT and JS all stay correct.
- Elm stays immutable: no mutable kernel stores, no state monads for speed.
- Representation invariants (`design_docs/invariants.csv`): MONO_029, MONO_032 (kernel
  visibility), MONO_033 (nullable), MONO_035 (tagged unions), HEAP_086 (tagged words), REP_HEAP_001
  (record field order is unboxed fields first, then by name, so C++ must never read SeqDict entries
  as records), HEAP_004 (object size is a function of the header word), HEAP_SNAPSHOT_001 / P1 (no
  runtime write to an object after it has survived a GC unless `builder == 1`).
- Kernel homes are unique across all kernels (`test/scripts/check-kernel-homes.sh`); `Bitwise` and
  `Hash` are taken. The new home is `Bitmap`.
- No mutually recursive let-bound local functions in Elm (known miscompile): write recursive
  helpers as top-level functions.
- Before modifying anything under `runtime/src/allocator/`, read `test/tla/README.md`.

## 4. Target design

### 4.1 Types

```elm
type SeqDict k v
    = SeqDict_elm_builtin (Node k v) (IntDict k v)      -- root (always a Branch), order

type Entry k v
    = Entry Int Int k v                                  -- hash, order index, key, value

type Node k v
    = Branch Int (JsArray2 (Slot k v))                   -- bitmap, slots in bit order
    | Collision Int (List (Entry k v))                   -- shared 32-bit hash; 2+ entries, ascending index

type Slot k v
    = Data (Entry k v)
    | Sub (Node k v)

type alias IntDict k v =
    { size : Int, array : Array (Maybe (Entry k v)) }
```

Representation (to be confirmed by the census in S1):

- `Entry` is a one-constructor custom type (`Custom`, 4 slots, 48 B; slots in declaration order,
  hash and index unboxed, key and value unboxed when Int/Float/Char). Not a record (§3.2).
- `Maybe (Entry k v)` is nullable (MONO_033: a non-kernel-owned custom payload), so `Just e` is `e`'s
  own pointer; `Nothing` is the Empty word. One object per entry is shared by trie and order array.
- `Slot` is a tagged union with both constructors Bare (MONO_035, HEAP_086): `Data e` is `e`'s pointer
  (index 0, untagged), `Sub n` is `n`'s pointer with 1 in bits 43–52. This needs `Node`, `Slot` and
  `Entry` *not* kernel-owned, `Node` without a nullary constructor and not nullable, `Slot` not
  kernel-visible and not the payload of a nullable type, and `Entry k v` present in `ctorShapes` at
  each instantiation.
- **Kernel visibility of users' types changes (found by the S1 census, accepted 2026-11-23).** The
  root field `Node k v` of the kernel-owned `SeqDict_elm_builtin` is followed by the visibility
  closure, and so are `Collision`'s `List (Entry k v)` and `Entry`, but `Entry`'s fields are declared
  as bare type variables, where the closure stops. So users' key and value types are no longer
  kernel-visible (before S1, `Collision`'s `List ( Int, k, v )` tuple reached them) and get the
  representation passes like any other type (e.g. a key type's one-field constructor becomes a
  Bare tagged word). The hash walker and `==` read every representation by design, and the P3
  representation tests (erased, Maybe-shaped, tagged keys and values) pass on JIT, AOT and JS with
  the validator on. `Slot` is reached only through `JsArray2`'s type-variable field, so it is not
  visible.
- On JS there are no tagged words: `Data`/`Sub` are `{$, a}` objects. The design is native-first; the
  eco-js column is gated with a stated tolerance (§5.3).

### 4.2 Invariants of a SeqDict (checked by the validator, P4)

- **O1** `array[i]` is `Nothing` or `Just e` with `index e == i`; `size` equals the number of `Just`s.
- **O2** Every entry in the trie is the same object as `array[index e]`, and every live slot of the
  array is reachable in the trie; the counts agree.
- **T1** Every `Branch`: `popCount32 bitmap == length slots`; slot `j` sits at the `j`-th set bit; an
  entry or sub-node reached at shift `s` under bit `b` has `(hash >>> s) & 31 == b` for every entry
  below it, for every level on its path; shifts never exceed 30.
- **T2 (canonical form)** The root is a `Branch` (any number of slots, 0 included). A non-root
  `Branch` has at least 2 slots, or exactly 1 slot that is `Sub (Branch …)`. Equivalently: no non-root
  `Branch` has 0 slots, a single `Data`, or a single `Sub (Collision …)`.
- **T3** `Collision h es`: at least 2 entries, all with hash `h`, distinct keys under `==`, ascending
  `index`. It sits at the shallowest level at which its bucket holds only entries with hash `h`.
- Consequence: the trie's shape is a function of the set of (hash, key) pairs and their order
  indices alone, whatever sequence of operations built it. The bottom-up builder (§4.4) produces
  exactly this shape.

### 4.3 Operations

- **Lookup**: at shift `s`, bit `b = (hash >>> s) & 31`; absent bit → not found; slot
  `Bitmap.index bitmap b`: `Data e` → found iff `hash e == hash && key e == key` (hash first);
  `Sub (Branch …)` → shift + 5; `Sub (Collision h es)` → if `h == hash`, find the key in `es`.
- **Insert** (new entry index = `Array.length array`, pushed): empty bit → insert `Data e`; `Data x`
  with the same key → replace by `Entry (hash x) (index x) key value` (new key object) and
  `Array.set (index x)`; `Data x` with the same hash and another key → `Sub (Collision h [x, e])`;
  `Data x` with another hash → `Sub (pair (s+5) x e)`, nesting single-slot `Branch`es while the
  5-bit chunks agree; `Sub (Collision h es)` with `h == hash` → replace or append; with another hash
  → `Sub (Branch …)` at `s+5` holding the collision and the new entry, nesting while the chunks agree.
- **Remove** returns "absent" without copying anything when the key is not there. Otherwise it
  rebuilds the path bottom-up and normalises each non-root branch: a branch left with one slot that
  is `Data` or `Sub (Collision …)` is replaced in its parent by that slot; a `Collision` left with one
  entry becomes `Data`. The order slot becomes `Nothing`, `size - 1`.
- **Compaction** (§4.5) runs, as before, before a removal; its trigger moved from 80 % to 50 % live
  slots (when it happens is not observable).

### 4.4 Structural rebuild (replaces the planned bottom-up builder)

The bottom-up builder planned here (sort the entries by hash chunks, then build each node from its
run) was built in S2 and measured slower than inserting one entry at a time: the comparator sort
recomputes the chunk key on every comparison (seqdict-churn 370 → 800 ms, seqdict-algebra 207 → 293 ms).
It was replaced by a structural rebuild, `rebuildWith`: the result of compaction, `filter`,
`filterMap`, `partition`, `intersect` and bulk `diff` is a renumbered subset of the old trie, so one
pass over the old trie (`remapSlots`/`remapSlot`) copies each node once, leaves out dropped entries,
restores the canonical form on the way up and replaces each kept entry by its renumbered copy, found
by its old index in a flat `JsArray2` built once. No hashing, no sorting, no path copying.

### 4.5 Compaction and bulk operations (as built)

- **Compaction**: `rebuildWith` keeping every entry. The trigger moved from 80 % to **50 %** live
  slots (checked before a removal, as before): when compaction happens is not observable, and at 80 %
  a FIFO workload paid about three entry rebuilds per removal (seqdict-churn 57 % in
  `rebuildOnOverflow`); at 50 % it pays about one.
- **`map f`**: map the order array once (`f` once per entry, in insertion order), then copy the
  trie's shape, replacing each entry by the new one at its index (a flat `JsArray2` lookup). The
  per-entry lookup is an out-of-line kernel call until A2; `map` is 1.6× slower than before the plan
  (scratch measurement, 100,000 entries ×10: 120 → 197 ms) while its result keeps one object per
  entry.
- **`filter`, `filterMap`, `partition`, `intersect`**: `rebuildWith` (predicate/function once per
  entry, in insertion order).
- **`union`**: incremental (insert `t1`'s entries into `t2` with their stored hashes), as before: its
  result is a superset of `t2`, which a rebuild cannot serve better.
- **`diff t1 t2`**: incremental when `size t2 * 8 <= size t1`, else `rebuildWith`.
- **`merge`**, **`fromList`**, **`SeqSet.map`**, **`SeqSet.fromList`**: unchanged.
- **Lesson (found by a benchmark regression and the census):** no helper may return a
  `Maybe (Slot k v)`. A nullable `Maybe (Slot k v)` makes `Slot` a nullable payload, which excludes it
  from the tagged-union pass (MONO_035) at that instantiation, and those dicts lost their Bare slots
  (seqdict-int 122 → 147 ms, 419 → 495 MiB). `remapSlot` returns a `Slot`, with an empty branch as
  its "nothing remains" marker.

### 4.6 `eco.hash`

- **The rule**: the hash of a value is a function of the runtime representation that `==` compares.
  The generic runtime walker is the definition; every specialised path gives bit-identical results.
  Results are deterministic within one compiled program on one backend. They are not stable across
  programs, compiler versions, build modes or backends, and must not be persisted.
- **Definition v2** (D0): today's walker with three changes. (a) A String contributes
  `mix(kString); mix(stringHash s)`, where `stringHash` is an independent, finished hash of the
  String's units: hashing is compositional at Strings, so a cached String hash serves nested Strings.
  (b) Units are mixed two per step from contiguous segments (`StringOps::forEachSegmentEx`), never
  through `charAt`. (c) The final result is never 0 (a 0 from the finaliser becomes 1), so 0 can mean
  "not cached". The depth cap (16) and the item budget (256, shared across the walk) stay.
- **The op**: `eco.hash` is emitted from the kernel-call arm for `FNV.hash` at a known type (a special
  arm like `Debug.toString`'s, because the intrinsic `Operation` path can unbox but cannot box).
  Lowering: Int, Char, Float, Bool inline; String → `eco_hash_string`; other types → a generated
  per-type function (D2) or the generic walker `eco_hash_value`.
- **Public API**: `Hash.hash : a -> Int` (new eco/system module, kernel home stays `FNV`).
- JS keeps its own `FNV.js`; it need not match native bit for bit.

### 4.7 Cached String hashes (D5, gated on the D4 census)

A cache word holds `stringHash s` (never 0; 0 = not cached). It exists in a flat `ElmString` or
`ElmStringUtf8Leaf` of at least `T` units (a tail word after the payload, so the size stays a
function of the header) and in `ElmStringSlice` (its spare `u32 _padding`). It is written:
at construction by every allocation site (as 0, or the hash for literals filled into
PermanentSpace, before they are published); or by `eco_hash_string` when the object is in the
nursery, `age == 0` and not a builder (never survived a GC, so P1 holds and no GC thread reads it
concurrently: background markers never read the nursery, the tenure collector reads only aged
objects). `StringOps::equal` rejects two Strings whose cache words are both set and differ.

### 4.8 `bitmapIndex`

`Bitmap.index bitmap i = popCount (bitmap & (2^(i & 31) - 1) & 0xFFFFFFFF)` and
`Bitmap.popCount32 x = popCount (x & 0xFFFFFFFF)`: eco/system kernel functions (home `Bitmap`),
intrinsics on native lowered to `arith` + `llvm.intr.ctpop` (`bzhi` + `popcnt` on x86-64-v3), JS
kernels in software. 32-bit on purpose: identical on both backends; SeqDict stays 32-bit.

### 4.9 Considered and not planned

- `JsArray2` through the array intrinsics: deferred by decision (2026-11-23, "not yet"); revisit in S4.
- Two-bitmap CHAMP: its `dataMap`/`nodeMap` split tells entries from sub-nodes and groups them; eco's
  tagged slots already tell them apart without a load, and SeqDict iterates through its order array,
  so grouping buys nothing. One bitmap saves 8 B per node and keeps one popcount per level. It
  remains the fallback layout if the census in S1 rejects the tagged `Slot` (§7).
- A kernel-level C++/JS node; a 64-bit hash with 64-way nodes; a flat small-dict mode (re-measure
  seqdict-small in S4: a dict of up to about 32 keys is already a single root node).
- Making users' key and value types kernel-invisible (`Collision` over `JsArray2`): a separate
  experiment with its own census.
- Printing SeqDict/SeqSet as `SeqDict.fromList [...]` in `Debug.toString` (P8 leaves it unspecified).

## 5. Procedures

### 5.1 Build and benchmark

```bash
S=/tmp/seqwork; mkdir -p $S
cat > $S/eco <<'EOF'
#!/bin/sh
exec /work/build/compiler/build-kernel/bin/eco "$@" --local-package=eco/system=/work/system-kernel-cpp
EOF
chmod +x $S/eco
cd /work/examples/benchmarks
mv eco-stuff $S/eco-stuff-$(date +%s) 2>/dev/null       # after any compiler change
ECO=$S/eco node run.mjs --skip-elm <workloads...> 2>&1 | tee $S/bench.txt
```

`build/compiler/build-kernel/bin/eco` must be rebuilt (`cmake --build build`) after compiler or
runtime changes. Compare medians against the baseline file named in the work package; a change of
5 % or more is flagged and explained in the commit message. Profiles:
`sudo -n perf record -F 1999 --call-graph dwarf,16384 -o $S/p.data ./build/bench --warmup 0 --runs 3 <w>`
then `sudo -n perf report -i $S/p.data --stdio --children --sort symbol -g none`.

### 5.2 Cache wipe (before any test run that must see a compiler or eco/system change)

```bash
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.2.0/packages -name '*artifacts.dat' -delete
rm -rf ~/.eco/0.2.0/packages/eco/kernel
```

(`full` clears none of these; stale artifacts make E2E results meaningless.)

### 5.3 Gates

Run each test command once, `2>&1 | tee /tmp/test_output.txt`, and read failures from that file.

- **G-elm** (eco/system Elm or JS kernel changes only): 5.2, then
  `TEST_FILTER=eco-system cmake --build build --target check`;
  `ECO_AOT_PACKAGES=eco-system cmake --build build --target run-aot-e2e`;
  `cmake --build build --target run-js-e2e`;
  `cmake --build build --target run-js-kernel-override-tests`;
  `ECO_HEAP_CONFIG=/work/benchmarks/heap-config-gc-pressure.json cmake --build build --target stress`
  (the default heap config runs no minor GCs);
  benchmarks (5.1). Native workloads: no regression of 5 % or more without a stated reason.
  eco-js: no regression of 10 % or more (S1 adds a wrapper object per trie slot on JS).
- **G-cpp** (runtime, kernel C++): G-elm plus `cmake --build build --target check` (all suites).
- **G-compiler** (any `compiler/src` change): 5.2, `cmake --build build --target full`,
  `cmake --build build --target elm-tests`, `cmake --build build --target bootstrap`, plus G-cpp.
- **End of plan only**: the `ECO_HEAP_VALIDATE` build (`build-validate`, `-DECO_HEAP_VALIDATE=ON`)
  with the unit suite, the eco-system E2E suite and the stress suite under the pressure config.
  Do not run a validate self-compile.

### 5.4 Constructor census

```bash
cd /work/examples/benchmarks
ECO_CTOR_CENSUS=$S/census-table.tsv $S/eco make src/Bench.elm --output=$S/census-bench
ECO_CTOR_CENSUS_OUT=$S/census-counts.tsv $S/census-bench --warmup 0 --runs 1 seqdict-int seqdict-custom seqdict-intern seqset-distinct
python3 /work/scripts/ctor-census.py $S/census-table.tsv $S/census-counts.tsv --by tagged
grep -E 'eco/system:(SeqDict|SeqSet)' $S/census-table.tsv
```

If the native `eco` binary does not honour `ECO_CTOR_CENSUS`, use the route in
`benchmarks/ctor-census-bench.sh` (Stage-1 compiler to `.mlir`, then `eco-boot-native`). The
`tagged` column reads `bare`, `nullary`, an `alloc-*` reason, `excluded-<reason>` or `-`; the `+kv`
mark (per type constructor) says kernel-visible.

### 5.5 Test conventions

E2E tests in `test/eco-system/src/*Test.elm` print with `Debug.log "label" value` and pin output with
`-- CHECK: label: value` lines; directives: `-- ENV: NAME=VALUE` (runtime environment of the
program), `-- SKIP-JS:` (skip on JS), `-- XFAIL-NATIVE:`. Expected values are computed by hand from
§3.1 and confirmed by running the current implementation on JIT and JS before they are committed.
Unit tests for the compiler live in `compiler/tests/<exact src folder>/<Module>Test.elm`.

## 6. Work packages

Order: stage 0 (P1–P8) → stage 1 (A1) → stage 2 (S1) → stage 3 (S2) → stage 4 (S3) → stage 5 (S4)
→ stage 6 (D0, D3, D1, D2, D4, D5) → Final → stage X. Track D starts only after S4 because D0
changes hash values (and so trie shapes and timings) and D1 moves code that S1 rewrites; D is
gated against the post-S baseline recorded in S4.

### Stage 0 — prerequisites (no behaviour change)

#### P1. Profiles — done (§2).

#### P2. Representation census, before

Depends on: nothing.
1. Run §5.4 on the current tree.
2. Save `census-table.tsv` and the `grep` output as `local-dev/census-before-seq.tsv`.
3. Record for each SeqDict-related type: its `tagged` value and whether it is `+kv`; and the same for
   the user key/value types used by the benchmark (`Ty`, `Key` in `SeqDictKeys.elm`, tuples).
Exit: the file exists and the plan's S1 census step has a "before" to compare with.

#### P3. Safety-net tests

Depends on: nothing. Gate: G-elm (tests only).
Add, each passing on the current code on JIT, AOT and JS:
1. `test/eco-system/src/SeqDictSemanticsTest.elm` pinning §3.1 rules 2–8 with key objects that are
   equal but distinguishable (Floats `0` and `-0`, told apart by `1 / k`): insert of a present key;
   `update`/`updateIfExists` key object; `fromList` duplicates; `union` (key and value from `t1`,
   order from `t2`, appended keys); `intersect`; `diff`; `merge` visiting order and its result after
   removals; `filter`/`filterMap`/`partition` on dicts with holes (build, remove some, then filter);
   `SeqSet.map` collisions.
2. `test/eco-system/src/SeqDictReprKeysTest.elm`: keys and values of every representation — an
   erased wrapper (`type Id = Id Int`), a Maybe-shaped user type (`type Opt = None | Some (Int, Int)`),
   a tagged union (`type Shape = Dot | Circle Float | Box { w : Int, h : Int }`), records, tuples,
   `Maybe (Int, Int)`, Strings built as literal, concatenation, slice and rope, Floats ±0 and `NaN`
   (rule 10); for each: insert, get, remove, update, `==`, `unorderedEquals`, folds.
3. `test/eco-system/src/SeqDictCollisionTest.elm`: keys that collide on each backend — native: Strings
   equal in their first 4096 units, lists equal in their first 256 items, values nested 17 deep that
   differ below depth 16; JS: Floats with the same integer part (`1.25`, `1.5`), nesting deeper than
   16. Exercise insert into, removal from (down to one entry and zero), and replace within collisions,
   plus a third key sharing only the first 5-bit chunk (forces a collision to be pushed down and later
   hoisted).
4. `test/eco-system/src/SeqDictCompactionTest.elm`: dicts whose live ratio crosses 0.8 exactly at a
   `remove`, an `update` to `Nothing` and inside `diff`; removing absent keys; then all observers
   (order, `get`, `==` with a freshly built dict).
5. `examples/benchmarks`: nothing here (P7).
Exit: G-elm green with the new tests on all three backends.

#### P4. SeqDict structural validator

Depends on: nothing (written against today's layout, then updated in S1). Gate: G-cpp.
1. In `elm-kernel-cpp/src/core/SeqDict.hpp` add `bool validateSeqDict(Custom* d, std::string* why)`
   checking O1, O2 and T1 for the current layout (T2/T3 are added in S1). Read every word through its
   heap tag, its tag bits 43–52 (`wordTag`, `hpBits`) and per-field slot kinds (`customSlotKind`,
   `tupleFieldKind`): never assume one representation of `Node`, entries or `Maybe`. Compare keys
   with `Utils::equal` only where needed (O2 uses object identity).
2. Read `ECO_SEQDICT_VALIDATE` once (a function-local static); when it is `1`, call the validator on
   both operands at the start of `seqDictEq` (`elm-kernel-cpp/src/core/Utils.cpp:749`) and abort with
   `why` on failure.
3. Add `-- ENV: ECO_SEQDICT_VALIDATE=1` to every `test/eco-system/src/SeqDict*Test.elm` and
   `SeqSetTest.elm` (JS ignores it).
4. Add a note to `Compiler/IR/Kernel/Visibility.elm` next to the SeqDict entries: the validator reads
   SeqDict internals in every representation and pins nothing.
5. Negative control: temporarily break one invariant in `SeqDict.elm` locally (e.g. skip
   `intDictRemove` in `removeHelp`) and confirm a test aborts; revert.
Exit: G-cpp green with validation on; the negative control fails as expected.

#### P5. Ownership and visibility decisions — done by analysis (record in the S1 commit)

- `SeqDict.Node` leaves `kernelOwned`, and the `Utils.equal`/`notEqual` `Inspects` list (no C++ reads
  it; P4's validator is representation-agnostic). `SeqDict.SeqDict` stays kernel-owned.
- `scripts/check-kernel-opaque.py` only scans modules that import `Eco.Kernel.*` directly;
  `SeqDict.elm` imports `FNV`, `JsArray2` and (after A1) `Bitmap`, so its new one-constructor `Entry`
  needs no entry. `Bitmap.elm` declares no types.
- Users' key/value types stay kernel-visible (§4.1): the S1 census must show the same `+kv` marks as
  P2 for them.

#### P6. Hash definition spec

Depends on: nothing.
1. Write `design_docs/theory/runtime/value-hash.md` describing exactly what `FNVExports.cpp` computes:
   the `Marker` values; `mix`/`mix64` (low word first); per kind (Int boxed or unboxed, Float with
   `-0.0` normalised, Char, constants including Empty and tagged constant words, every String form,
   lists over cells and chunks with `kList`…`kListEnd`, Dict in key order, SeqDict in insertion
   order, Custom with constructor, Record in heap slot order, Tuple2/3, Array, other kinds); the tag
   handling (bits 43–52 mixed with `kTag` before the object); the bounds (`kMaxDepth` 16, `kMaxItems`
   256 shared across the walk, `kMaxUnits` 4096 per String); the finaliser `fmix32`.
2. Add a "v2" section with the three changes of §4.6 (stated precisely in D0).
Exit: the note exists; D0 and D2 cite it.

#### P7. Asymmetric workloads and re-baseline

Depends on: nothing. Must land before any implementation change.
1. Add to `examples/benchmarks/src/SeqDictAlgebra.elm` `benchUnionSmall` (seqdict-union-small: `union`
   of a 1/64-size dict into a large one, repeated 64 times with disjoint small dicts, plus `diff` of
   the small from the large), and to `SeqSetOps.elm` `benchUnionSmall` (seqset-union-small, the same
   for sets); self-checked in closed form like seqdict-algebra. Add a portable twin to
   `DictAlgebra.elm` (dict-union-small) and `ElmBench.elm`.
2. Register them in `Bench.elm` (eco-only for the seq ones) with sizes giving 200–400 ms native.
3. Check at sizes 1, 2, 3, 64, 1000 and the default; build the official-elm twin.
4. Re-record `local-dev/pre-seq-bench.json` with all workloads in one session (§5.1), keeping its
   metadata header.
Exit: the baseline file holds 27 workloads, all `ok`.

#### P8. `Debug.toString` of SeqDict

Depends on: nothing.
1. `grep` `test/`, `examples/` and `system-kernel-cpp/tests` for `Debug.log`/`Debug.toString` applied
   to a SeqDict or SeqSet value (not to `toList`, `keys`, booleans); change any to print `toList`.
2. Add §3.1 rule 12 to the SeqDict module documentation ("`Debug.toString` shows internals; use
   `toList`").
Exit: no test pins SeqDict internals.

### Stage 1 — A1: `Bitmap.index` and `Bitmap.popCount32`

Depends on: stage 0. Gate: G-compiler.
1. **Elm module** `system-kernel-cpp/src/Bitmap.elm`:
   `module Bitmap exposing (index, popCount32)`, `import Eco.Kernel.Bitmap`,
   `index : Int -> Int -> Int` / `index = Eco.Kernel.Bitmap.index`, likewise `popCount32`; docs state
   the semantics of §4.8. Not added to `elm.json` `exposed-modules` (internal, like `FNV`).
2. **JS kernel** `system-kernel-cpp/src/Eco/Kernel/Bitmap.js`:
   `var _Bitmap_popCount32 = function (x) { x = x - ((x >>> 1) & 0x55555555); x = (x & 0x33333333) +
   ((x >>> 2) & 0x33333333); return Math.imul((x + (x >>> 4)) & 0x0F0F0F0F, 0x01010101) >>> 24; };`
   and `var _Bitmap_index = F2(function (bitmap, i) { return _Bitmap_popCount32(bitmap & ((1 << (i & 31)) - 1)); });`
   (`(1 << 31) - 1` becomes `0x7FFFFFFF` under `&`'s ToInt32, `i & 31` handles negative `i`).
3. **C++ export** `system-kernel-cpp/src/eco-system/Bitmap/BitmapExports.cpp` (header comment in the
   style of `JsArray2Exports.cpp`): `extern "C" int64_t Eco_Kernel_Bitmap_index(int64_t bitmap, int64_t i)`
   returning `std::popcount(static_cast<uint32_t>(bitmap) & ((1u << (static_cast<uint32_t>(i) & 31u)) - 1u))`
   and `Eco_Kernel_Bitmap_popCount32(int64_t x)` returning `std::popcount(static_cast<uint32_t>(x))`.
   Register `eco_system_module(Bitmap POSIX src/eco-system/Bitmap/BitmapExports.cpp)` in
   `system-kernel-cpp/CMakeLists.txt` and add `Bitmap` to `ECO_SYSTEM_MODS`
   (`runtime/src/codegen/CMakeLists.txt:925`).
4. **Kernel tables**: `Visibility.elm` `transparentKernels` gets `( "Bitmap", [ "index", "popCount32" ] )`
   with a source comment; `design_docs/elm_kernel_functions.csv` gets two rows (format of the FNV row,
   line 60); `Compiler/IR/Kernel/Facts.elm` `rows` gets two `auditedPure` rows keyed
   `( "Eco", "Bitmap", name )` with `gcAlloc = GcNone` and an evidence anchor `BitmapExports.cpp:<line>`.
5. **Intrinsic**: in `Compiler/IR/Kernel/Intrinsics.elm` add `"Bitmap" -> bitmapIntrinsic name args`
   to `kernelIntrinsicOn`, mapping `( "index", [ ( a, MInt ), ( b, MInt ) ] )` to
   `BinaryInt { op = "eco.int.bitmap_index" } a b` and `( "popCount32", [ ( a, MInt ) ] )` to
   `UnaryInt { op = "eco.int.popcount32" } a`. No other compiler module needs a change
   (`GenerateMlir/Intrinsics.elm` and `ConstThunks.pureIntrinsic` already handle `BinaryInt`/`UnaryInt`).
6. **Ops** in `runtime/src/codegen/Ops.td` next to `Eco_IntAndOp` (`:2676`):
   `Eco_IntBitmapIndexOp : Eco_Op<"int.bitmap_index", [Pure]>` with `(ins Eco_Int:$bitmap, Eco_Int:$index)`,
   `(outs Eco_Int:$result)`, format `"$bitmap `,` $index attr-dict `:` type($result)"`, and
   `Eco_IntPopCount32Op : Eco_Op<"int.popcount32", [Pure]>` with `(ins Eco_Int:$value)`; descriptions
   state §4.8 exactly.
7. **Lowering** in `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` next to `IntAndOpLowering`
   (`:952`): `bitmap_index` → `i = andi(index, 31)`, `mask = subi(shli(1, i), 1)`,
   `m = andi(bitmap, mask)`, `LLVM::CtPopOp(m)` (the mask already clears bits 32–63);
   `popcount32` → `LLVM::CtPopOp(andi(value, 0xFFFFFFFF))`. Register both in
   `populateEcoArithPatterns` (Bitwise group, `:1544-1551`).
8. **SeqDict**: replace `compressedIndex index bitmap` by `Bitmap.index bitmap index` at every call site
   and delete `compressedIndex`.
9. **Tests**:
   - `test/codegen/bitmap_index_ctpop.mlir`: `-emit=mlir-llvm` with `// IR: llvm.intr.ctpop`
     (arguments through calls so nothing folds), and `-emit=jit` printing with `eco.dbg`:
     `index 0xFFFFFFFF 0 = 0`, `index 0xFFFFFFFF 31 = 31`, `index 0x100000003 2 = 2` (bits above 31
     ignored), `index 7 -1 = 3` (`-1 & 31 = 31`), `popcount32 -1 = 32`, `popcount32 0x1FFFFFFFF = 32`.
   - `compiler/tests/Compiler/IR/Kernel/IntrinsicsBitmapTest.elm` in the style of
     `IntrinsicsListConsTest.elm`: both names map to the expected `Operation`; other names and
     non-Int argument types give `Nothing`.
   - SeqDict E2E tests (all three backends) cover the JS kernel and the C++ export.
10. **Verify**: rebuild, build the benchmarks, `objdump -d examples/benchmarks/build/bench | grep -c popcnt`
    is non-zero and `SeqDict_compressedIndex` no longer exists; benchmarks per §5.1 against
    `local-dev/pre-seq-bench.json`.
Exit: G-compiler green; `popcnt` present; no workload regresses.

### Stage 2 — S1: trie core rewrite

Depends on: A1, P2–P8. Gate: G-compiler (Visibility changes) + census.
1. **Types**: replace §1's types by §4.1's in `SeqDict.elm`. `empty = SeqDict_elm_builtin (Branch 0 JsArray2.empty) { size = 0, array = Array.empty }`;
   `isEmpty d = size d == 0`; `size` reads the order record.
2. **Lookup**: top-level `getHelp : Int -> Int -> k -> Int -> JsArray2 (Slot k v) -> Maybe (Entry k v)`
   (shift, hash, key, bitmap, slots) per §4.3, with `collisionFind : k -> List (Entry k v) -> Maybe (Entry k v)`.
   `get`, `member` use it.
3. **Insert**: top-level `insertHelp : Int -> Int -> k -> v -> Int -> JsArray2 (Slot k v) -> IntDict k v -> ( Int, JsArray2 (Slot k v), IntDict k v )`
   returning the new bitmap, slots and order record, per §4.3, with top-level helpers
   `pairBranch : Int -> Entry k v -> Entry k v -> Node k v` (two entries with different hashes,
   nesting while chunks agree) and `collisionAndEntry : Int -> Int -> List (Entry k v) -> Entry k v -> Node k v`.
   New entries get `index = Array.length array` and are pushed; replacements keep the index and use
   `Array.set`. `insert`, `update` (`Just`), `updateIfExists` use it with the argument key.
4. **Remove**: top-level `removeHelp : Int -> Int -> k -> Int -> JsArray2 (Slot k v) -> Maybe ( Int, ( Int, JsArray2 (Slot k v) ) )`
   returning `Nothing` when absent, else the removed index and the new bitmap/slots; a top-level
   `normalize : Int -> JsArray2 (Slot k v) -> Slot k v` applies T2 to a non-root branch; collision
   shrink to one entry yields `Data`. `remove`, `update` (`Nothing`) and `diff` call
   `rebuildOnOverflow` first exactly as today, then remove; absent keys return the dict unchanged.
5. **Everything else, unchanged in algorithm** but on the new primitives: `rebuildOnOverflow`
   (re-insert with stored hashes), `filter`, `filterMap`, `partition`, `union`, `intersect`, `diff`,
   `merge`, `unorderedEquals` (stored hash from `Entry`), `fromList`, `toList`, `keys`, `values`,
   `foldl`, `foldr`, the `intDict*` helpers (now over `Maybe (Entry k v)`).
6. **`map`** per §4.5: `Array.map` over the order array (one call per entry), then a top-level
   `mapSlots : Array (Maybe (Entry k b)) -> JsArray2 (Slot k a) -> JsArray2 (Slot k b)` that copies the
   shape and replaces each entry by the new array's entry at its index (`Array.get`).
7. **SeqSet**: no source change expected; re-read every function against §3.1.
8. **Couplings**:
   - `SeqDict.hpp`: the order record is `values[1]`; an element is a Custom with `size == 4`
     (the `Entry` itself, nullable `Just`) or `size == 1` (a `Just` holding the `Entry`); key is
     `values[2]` with `customSlotKind(e, 2)`, value `values[3]` with kind 3; assert anything else.
     Update the header comment (layout, both forms, why sizes distinguish them).
   - `FNV.js` `_FNV_seqDictEntries`: `seqDict.b.__$array`; `slot.a.c` / `slot.a.d`; update its comment.
   - `Visibility.elm`: remove `( "eco/system:SeqDict", "Node" )` from `kernelOwned` and from the
     `Utils` `Inspects` list; comment why (P5).
   - The validator (P4): the new layout, plus T2 and T3.
9. **Census** (§5.4): `Slot` `tagged` with `Data` and `Sub` both `bare`; `Maybe` over `Entry` nullable;
   `Entry` and `Node` boxed; user key/value types with the same `+kv` marks as P2. If `Slot` is not
   tagged, stop and switch to the fallback layout (§7) after re-reading the exclusion reason.
10. **Tests**: all eco-system tests (with validation on), the P3 tests,
    `run-js-kernel-override-tests`; the benchmarks against `local-dev/pre-seq-bench.json` (expect
    peak memory down on every seqdict workload; seqdict-churn, seqdict-algebra unchanged in
    algorithm).
Exit: G-compiler green on JIT/AOT/JS; census as designed; validator green; no native regression of
5 %, eco-js within 10 %.

### Stage 3 — S2: builder and structural compaction

Depends on: S1. Gate: G-elm.
1. **Builder** (§4.4) as top-level functions in `SeqDict.elm`: `build : List (Entry k v) -> Node k v`
   (root, shift 0), `buildBranch : Int -> List (Entry k v) -> Node k v`, `bucketBy : Int -> List (Entry k v) -> Array (List (Entry k v))`
   (32 buckets; `List.foldr` keeps ascending order within a bucket), `slotFor : Int -> List (Entry k v) -> Slot k v`
   (one entry → `Data`; one hash → `Sub (Collision h es)`; else `Sub (buildBranch (shift + 5) es)`).
2. **Renumber**: `renumber : List (Entry k v) -> List (Entry k v)` giving index = rank (new `Entry`
   objects), and `fromEntries : List (Entry k v) -> SeqDict k v` = renumber, `Array.fromList (List.map Just …)`,
   `build`.
3. **Compaction**: `rebuildOnOverflow` = `fromEntries (live entries in order)` with the same trigger.
4. **Tests**: P3's compaction test; a new `SeqDictShapeTest.elm` that builds the same key set by
   different operation sequences (insert-only, insert then remove extras, `fromList`, after a
   compaction) and compares them with `==` and `unorderedEquals` while the validator (T2/T3) checks
   each shape; seqdict-churn benchmark.
Exit: G-elm green; seqdict-churn substantially down (target: under 50 % of baseline).

### Stage 4 — S3: bulk operations

Depends on: S2. Gate: G-elm.
1. `filter`, `filterMap`, `partition`, `intersect` → collect kept entries in order, `fromEntries`.
2. `union`, `diff` → the size-ratio switch of §4.5 (constant `bulkRatio = 8`), bottom-up branch via
   `fromEntries`, incremental branch as in S1.
3. `merge`, `fromList`, `SeqSet.map`, `SeqSet.fromList`: unchanged; confirm against §3.1.
4. Tune `bulkRatio` with seqdict-union-small, seqset-union-small, seqdict-algebra, seqset-algebra
   (try 4, 8, 16; keep the best overall and record the numbers in the commit message).
Exit: G-elm green; seqdict-algebra, seqset-algebra, seqdict-iterate down; the union-small workloads
not worse than baseline.

### Stage 5 — S4: measure and decide

Depends on: S3.
1. Run all workloads (§5.1) and the profiles of §2; write the "after" figures into §2.
2. Save the results as `local-dev/post-seq-bench.json` (same header format): the baseline for track D.
3. Decide, recording each decision in this plan: a small-dict mode (only if seqdict-small trails
   meaningfully); iteration follow-ups (seqdict-iterate); A2 (`JsArray2` intrinsics) — ask the user
   with the profile in hand.
4. Set this plan's `updated`; status stays `partial` until track D ends.

### Stage 6 — track D: `eco.hash`

#### D0. Definition v2

Depends on: S4, P6. Gate: G-cpp.
1. In `FNVExports.cpp` `Hasher::string`: compute `stringHash` with its own FNV state from the offset
   basis: `mix(kString)`, `mix64(length)`, then the units (capped at `kMaxUnits`) two per step as
   `u1 | (u2 << 16)` (an odd last unit alone), read from segments via `StringOps::forEachSegmentEx`
   (UTF-8 bytes are units), finished with `fmix32`, 0 mapped to 1. The walker then does
   `mix(kString); mix(stringHash)`. The Empty constant keeps `mix(kEmpty)`.
2. The final result of `Eco_Kernel_FNV_hash`: `fmix32(h)`, 0 mapped to 1.
3. Update `design_docs/theory/runtime/value-hash.md` (v2 is now current) and the `FNVExports.cpp`
   header.
4. JS (`FNV.js`): no change required (§4.6); note in its header that native and JS differ.
Exit: G-cpp green (SeqDictKeyKindsTest, collision test: bounds unchanged, so collisions still occur);
benchmarks against `local-dev/post-seq-bench.json`.

#### D3. Public `Hash` module (before D1, so tests can print hashes)

Depends on: D0. Gate: G-elm.
1. `system-kernel-cpp/src/Hash.elm`: `module Hash exposing (hash)`, `hash : a -> Int`,
   `hash = Eco.Kernel.FNV.hash`; module docs: §4.6's guarantees and non-guarantees, range
   [0, 2^32) (never 0 on native), equal values (`==`) hash equal, not for persistence.
2. Add `Hash` to `system-kernel-cpp/elm.json` `exposed-modules`; check `eco-system-docs` builds.
3. Test `test/eco-system/src/HashTest.elm`: equal values in different representations hash equal
   (the P3 representation corpus, String forms, Float ±0), within one program; no pinned numbers.
Exit: G-elm green.

#### D1. The `eco.hash` op, phase 1

Depends on: D3. Gate: G-compiler.
1. **Runtime walker**: move `Hasher` from `FNVExports.cpp` into
   `runtime/src/allocator/ValueHash.{hpp,cpp}` exposing `extern "C" int64_t eco_hash_value(HPtr)`,
   `eco_hash_string(HPtr)`, `eco_hash_i64(int64_t)`, `eco_hash_f64(double)`, `eco_hash_char(int32_t)`.
   Move `forEachSeqDictEntry` and the layout helpers from `elm-kernel-cpp/src/core/SeqDict.hpp` into
   `runtime/src/allocator/SeqDictLayout.hpp`; `SeqDict.hpp` keeps the validator and includes it.
   `Eco_Kernel_FNV_hash` becomes a call of `eco_hash_value`. Add the new symbols to
   `runtime/src/codegen/RuntimeSymbols.cpp`. Read `test/tla/README.md` first; no concurrency line
   changes, so the canary must stay quiet.
2. **Op** in `Ops.td`: `Eco_HashOp : Eco_Op<"hash", [Pure]>` with `(ins AnyType:$value, I64Attr:$type_id, StrAttr:$kind)`
   (`kind` ∈ `int`, `float`, `char`, `bool`, `string`, `value`) and `(outs Eco_Int:$result)`;
   verifier: `kind` agrees with the operand type — `int` `i64`, `float` `f64`, `char` `i32`,
   `bool` `i1`, `string` and `value` `!eco.value`. A Bool that reaches the call already as
   `!eco.value` (its heap form, a True/False constant word) takes kind `value`.
3. **Front end**: in `Compiler/GenerateMlir/Expr.elm`'s kernel-call arm, next to
   `( "Debug", "toString", … )` (`:4043`), add `( "FNV", "hash", [ ( valueExpr, ( valueVar, valueType ) ) ] )`
   when the config flag `hashIntrinsic` is on: compute `kind` from the post-representation Mono type;
   box to `!eco.value` for `value` (reuse the Debug arm's boxing); get the type id with
   `Ctx.getOrCreateTypeIdForMonoType`; emit `eco.hash`. Add the flag to `Compiler/Config.elm` and
   `Builder/Eco/Config.elm` (`ECO_HASH_INTRINSIC`, default on), following an existing `repr` flag.
4. **Lowering** (new `HashOpLowering` in `EcoToLLVMArith.cpp`, or a new `EcoToLLVMHash.cpp`
   registered in `populateEcoArithPatternsWithRuntime`): `int`/`float`/`char` inline per the spec
   (constant-fold the `kInt`/`kFloat`/`kChar` prefix; `-0.0` normalised with a select; `fmix32`; 0 → 1;
   zero-extend), `bool` inline from the True/False constant words (use the runtime's constant
   encoding helpers, never literal numbers), `string` → call `eco_hash_string`, `value` → call
   `eco_hash_value`. When the environment variable `ECO_HASH_INLINE=0` is set at lowering time, every
   kind calls the runtime (`eco_hash_i64` etc.) instead: this is the identity switch.
5. **Tests**:
   - `test/codegen/hash_inline_*.mlir`: for a table of values per kind (including Int min/max, ±0,
     NaN, Char 0 and 0x10FFFF, True/False), print the inline result and the runtime result with
     `eco.dbg` and CHECK they are equal.
   - `test/eco-system/src/HashIdentityTest.elm` and `HashIdentityGenericTest.elm` (the latter with
     `-- ENV: ECO_HASH_INLINE=0`): the same program printing `Hash.hash` of the corpus with identical
     `-- CHECK` lines; `-- SKIP-JS:` on both (JS numbers differ). First confirm that `-- ENV:`
     reaches JIT lowering (the program is lowered in the child process); if it does not, add a
     harness directive for the lowering environment.
   - `compiler/tests/Compiler/GenerateMlir/HashIntrinsicTest.elm` (style of
     `ArrayGetIntrinsicTest.elm`): `eco.hash` appears with the right `kind` for Int/String/record.
Exit: G-compiler green; identity tests green; seqdict-int/-custom/-string not slower.

#### D2. Generated per-type hash functions

Depends on: D1. Gate: G-compiler.
1. Runtime: a resumable walker entry `eco_hash_walk(HPtr value, int64_t h, int64_t items, int64_t depth, int64_t* outItems) -> int64_t h`
   that continues the walk from a given state (for fields D2 does not specialise).
2. Front end: a new module `Compiler/GenerateMlir/HashFns.elm` generating, per Mono type id and on
   demand (memoised in `Ctx`, emitted with the other synthesised functions — follow how
   `__closure_wrapper_typed_*` functions are collected and emitted), a function
   `__eco_hash$<typeId>(value, h, items, depth) -> (h, items)` (a multi-result `func.func`, CGEN_067)
   that mirrors the spec for: tuples, records (heap slot order from `Types.computeRecordLayout`),
   custom types in each representation (boxed: `kCustom`, constructor index, fields; tagged:
   `eco.word_tag`, `kTag` + index when non-zero, `eco.untag`, the Bare field is the word; nullary: the
   null-cons word as a constant; nullable: `Nothing` = Empty → `kEmpty`, `Just x` = `x`; erased
   wrappers: the field), with the depth and item checks in the same places as the walker. Any field
   whose type is a String calls `eco_hash_string`-equivalent mixing; any list, recursive type,
   container or type variable calls `eco_hash_walk`.
3. `eco.hash` of kind `value` with a generated function gets an attribute `fn = @__eco_hash$<id>`;
   lowering calls it (and `fmix32`, 0 → 1) unless `ECO_HASH_INLINE=0`.
4. Tests: extend the identity corpus to every representation (P3's types, nested records of tagged
   unions, `Maybe` of records, tuples of Strings); both identity tests must still agree; codegen test
   for one generated function's MLIR shape.
Exit: G-compiler green; identity green; seqdict-custom, seqdict-tuple, seqdict-intern not slower than
`local-dev/post-seq-bench.json`.

#### D4. String hash census

Depends on: D1. Gate: G-cpp.
1. Under `ENABLE_GC_STATS`, counters in `eco_hash_string` and the walker's String path (copy the
   `utf8_widen_*` pattern in `GCStats.hpp/.cpp`: field, macros, record/merge/print/reset): calls and
   units by form (flat UTF-16, UTF-8 leaf, slice, rope, large, view), length bucket (<32, <256,
   <4096, ≥4096), age class at hash time (nursery age 0, nursery survived, old generation,
   PermanentSpace), and top-level vs nested.
2. A repeat estimate behind `ECO_HASH_CENSUS=1`: a per-minor-epoch open-addressing table keyed by
   object address (pattern of `ECO_CLOSURE_STATS` in `RuntimeExports.cpp`), cleared at each minor GC,
   counting second and later hashes of the same address and the units they cost.
3. Run on seqdict-longkey, seqdict-longkey-reuse, seqdict-string, seqdict-intern and the eco-system
   SeqDict tests; write the table into this plan.
4. Decide D5 go/no-go and `T`: go if, on seqdict-longkey-reuse, repeated hashing is at least half the
   String units and most first hashes happen at nursery age 0; `T` = the smallest length bucket whose
   repeated units dominate.
Exit: the census table and the decision are recorded here.

#### D5. Cached String hashes (only on "go")

Depends on: D4 (go). Gate: G-cpp, plus the P1-census build at the end of the work package.
1. Read `test/tla/README.md`; this adds no concurrent access (§4.7), so no TLA pin should move. If the
   canary fires, investigate the named models first; never repair a hash alone.
2. **Layout**: a tail word after the payload of `ElmString` and `ElmStringUtf8Leaf` when
   `header.size >= T`; `getObjectSizeFromHeader` (`AllocatorCommon.hpp:460-558`) adds 8 for them;
   `ElmStringSlice` uses `_padding` (`u32`).
3. **Every allocation site** initialises the word to 0 (fresh payload is not zeroed): `HeapHelpers.hpp`
   `allocString` (`:402-426`), `allocStringBlank` (`:449-474`); `StringOps.cpp` `concat` (`:543-552`),
   `join` (`:643-654`); `RuntimeExports.cpp` `eco_alloc_string` (`:641`), `eco_alloc_string_literal`
   (`:792`), `eco_alloc_string_literal_utf8`'s UTF-16 fallback (`:805`), `eco_alloc_string_fast`/`_slow`
   (`:1745-1769`), `eco_init_string_at` (`:2054`); `ThreadLocalHeap.cpp` `initHeaderForTag`
   (`:117-118`, derive the length correctly with the tail word); `elm-kernel-cpp/src/bytes/BytesExports.cpp`
   (`:664-671`); every `Tag_StringUtf8Leaf` allocation (find them with
   `grep -rn "Tag_StringUtf8Leaf" runtime elm-kernel-cpp eco-kernel-cpp system-kernel-cpp`); codegen
   `EcoGCPrepare.cpp` `getFixedAllocSizeForGrouping` (`:107-110`) and `EcoToLLVMHeap.cpp`
   `computeAllocSize` (`:174-177`) for `eco.allocate_string`. Funnel them through one helper
   `initStringHashWord(void*)` so a new site cannot forget.
4. **Literals**: compute and store the hash in `allocInternObject`'s lambda (`RuntimeExports.cpp:740-756`)
   before the slot is published.
5. **Fill**: `eco_hash_string` reads the word; if 0, computes; stores only if
   `Allocator::instance().isInNursery(obj) && hdr->age == 0 && !hdr->builder`.
6. **Equality**: in `StringOps::equal` (`StringOps.hpp:1623-1644`), after the length check, return
   false when both words are non-zero and differ.
7. **Validation**: in the `ECO_HEAP_VALIDATE` pre-evacuation walk (`NurserySpace.cpp:2019-2060`) and the
   region eden pre-walk (`NurseryRegion.cpp:778`), check that a cache word is 0 or equals the
   recomputed hash.
8. **Docs/invariants**: a new `HEAP_0xx` row (the word, who writes it and when, 0 = absent, copied
   verbatim by the GC); amend the `[Pure]` notes on String ops (`Ops.td:1274-1278`, `:2975-2980`) to
   say the cache write is invisible to Elm; update `value-hash.md`.
9. **Tests**: update hard-coded String sizes (`test/allocator/HeapGenerators.cpp:200,409`,
   `AllocatorCommonTest.cpp:159-188,644`, `AllocatorTest.cpp:849-863`, `StringFormsCompareTest.cpp:350`);
   new unit tests: the word is 0 after every allocation route; it fills at age 0; it does not fill
   after a minor GC (age ≥ 1) or in the old generation; literals carry their hash; `equal` fast-reject;
   GC copies keep the word. Run the P1 census build (`-DECO_P1_CENSUS=ON`) over the eco-system suite.
Exit: G-cpp green; P1 census clean; seqdict-longkey-reuse down; no String-heavy workload slower.

### Final

Depends on: everything above.
1. The `ECO_HEAP_VALIDATE` build (§5.3) with the unit, eco-system and pressure stress suites.
2. `cmake --build build --target bootstrap`.
3. `design_docs/invariants.csv`: rows for `eco.hash` (CGEN), the String cache (HEAP, if D5 shipped),
   the SeqDict layout and its readers; `design_docs/theory/` updated (value-hash.md, the SeqDict
   section of the kernels docs).
4. Final benchmark table in §2; plan status `done` (or `partial` with `remaining`), `updated` set.

### Stage X — explore: cached `eco.hash` values in heap structures (last)

> **Revisit feasibility when this stage is reached, and only after all the other implementation
> work in this plan (stages 0–6 and Final) is done.** It is an exploration, not a commitment: its
> outcome is a go/no-go note and, on "go", a plan of its own.

D5 caches the hash of flat Strings only. This stage asks whether other heap objects should carry a
cached `eco.hash` value, as the compiler already does by hand for `MonoType` (every composite node
stores its packed hash) and as intern-cached-hash against intern-rehash measures (22 % natively).
Questions to answer, with what is known today:

- **Which objects?** Only objects that are both expensive to hash and hashed repeatedly. Candidates:
  Custom, Record and Tuple values used as keys (tree-shaped keys like `MonoType`), Lists, and
  container values used as keys (Dict, Set, SeqDict, Array). Small objects are never worth it.
  Decide from an extended D4 census: hash calls per object by tag and size, units walked, and how
  often the same object is hashed again.
- **Where to store the value, and how to mark it.** The 64-bit header word has no free bits
  (`tag:5 color:2 pin:1 age:2 unboxed:6 refcount:15 builder:1 size:32`; `refcount` is not a
  reference count but is used: free-list links on `Tag_Free` cells, the constructor census on
  Customs). So the marks must come from elsewhere:
  - *"Space is reserved"*: make it a pure function of what the header already says, so
    `getObjectSize` stays a function of the header word (HEAP_004): e.g. `tag` plus `size` at or
    above a threshold (as D5 does for Strings). Alternatively new tag values (a "with hash word"
    variant of each chosen tag): 27 of the 32 `TAG_BITS` codes are used, but `Tag_Free` and
    `Tag_Forward` must stay last and tag values must not be renumbered (Heap.hpp:89-91), so new tags
    need that rule revisited first.
  - *"The hash has been computed"*: needs no bit: the hash is never 0 (D0), so 0 means "not
    computed", as in D5.
  - Two header bits (one for space, one for computed) are therefore not needed if both rules above
    hold. If a per-object opt-in is wanted (space for some objects of a tag and size but not others),
    that one bit is the real requirement, and the header has none to give.
  - *A hidden field in the compiler's layout*: the compiler adds an unboxed Int slot to chosen
    constructors (REP_HEAP_002 slot kind 01), so the GC and the size function see an ordinary field
    and need no change. But every generic reader (the hash walker, `==`, the value printer,
    `Debug.toString`, kernels that read fields by index, the type table) must then know that the last
    slot is a cache, and a Custom object does not carry its type, so something must identify it at run
    time, which brings back the marking question.
- **Size threshold, and how to compute size.** A threshold must be decidable from the header (tag and
  `size`) or at compile time (per constructor). An object's own size is a poor proxy for walk cost: a
  two-field node can root a deep tree, and subtree size cannot be known without walking. A
  type-directed choice at compile time (recursive types, types used as hash keys, decided with
  `eco.hash`'s type knowledge) fits better than a run-time size rule for non-String objects.
- **When to compute.**
  - *Eagerly at construction*, from the children's cached values (as `MonoType` does): no P1 issue;
    costs a few operations on every construction even if never hashed; needs a compositional
    definition for those types. The bounded walk (depth and item caps) is not compositional, so cached
    types would need their own, unbounded, definition that the generic walker then honours.
  - *On demand, the first time it is hashed*: the space must be reserved in advance (0 = not
    computed), and the write into an existing object is allowed by HEAP_SNAPSHOT_001 (P1) only before
    the object has survived a GC (nursery, `age == 0`). Objects first hashed later would stay uncached
    unless P1 gets a carve-out for a write-once cache word, which needs the TLA+ models
    (`test/tla/README.md`) reviewed for concurrent tenuring and marking.
  - *During a minor GC*: the collector's own writes during a pause are outside P1, so filling the word
    while copying a survivor is possible in principle; it needs the children's hashes at that moment
    and adds work to the pause.
- **Consistency.** Whatever is cached must equal the definition exactly; `==` may use differing cached
  values as a fast reject; printers and kernels must ignore the word.

#### Stage X outcome (2026-11-23): not feasible now; no go

Revisited after everything else in this plan was implemented. What the work showed:

- **Writes after survival are the blocker.** D4's census found that reused keys are first hashed after
  they have survived a collection (2,642 of 120,000 first hashes at nursery age 0 in
  seqdict-longkey-reuse; the rest in the survived nursery or the old generation). So an on-demand cache
  limited by P1 to young objects serves almost nothing (D5 was dropped for that reason), and the same
  holds for any heap object. Making it work needs a P1 carve-out for a write-once cache word in objects
  that have survived: background markers read surviving objects concurrently (HEAP_065), the P1
  census's detectors N and O re-hash surviving objects and would have to skip the word, and the TLA+
  models that assume P1 (M1 snapshot marking, M5 tenuring) would need a review and probably a change.
  That is a GC-concurrency project of its own, not a SeqDict optimisation.
- **Eager caching at construction avoids P1, but needs a mark the header cannot give.** A type-directed
  hidden hash field (chosen at compile time) is sound for the compiler-generated code, but every generic
  reader (the hash walker, `==`, the printers, kernels) would need to know the last slot is a cache, and a
  Custom does not carry its type; the header has no free bit, and new tag values need the "`Tag_Free` and
  `Tag_Forward` last" rule changed first.
- **The payoff is small where the work went.** With D1/D2 and A2, hashing is a small share of SeqDict
  time (§2), and the compiler already caches its `MonoType` hashes by hand.
- **A cheaper route exists for the one case that pays (large structured keys hashed repeatedly):** the
  pattern the compiler uses, as a library type, e.g. `Hashed a = Hashed Int a` built with
  `Hash.hash` once, whose `==` compares the stored hash first. It needs no runtime or GC change, and the
  intern-cached-hash workload measures its effect today (22 % against rehashing natively).

**Verdict:** no go for runtime-level hash caching in heap structures. If it is wanted later, start a
plan of its own with the P1 carve-out design and the M1/M5 model review, and measure first with an
extended D4 census over the target programs.

## 7. Risks

- **The census rejects the tagged `Slot` or the nullable `Maybe (Entry k v)`.** Possible exclusions:
  `meets` (`TaggedUnions.elm:95-106`), `nullable-payload` (any `Maybe (Slot k v)` made nullable),
  kernel visibility, `Entry k v` missing from `ctorShapes` at an instantiation
  (`TaggedUnions.elm:187-190`). Fallback layout: two bitmaps and two arrays per node,
  `Branch Int Int (JsArray2 (Entry k v)) (JsArray2 (Node k v))` (data map, node map, entries,
  sub-nodes); if `Maybe (Entry k v)` is not nullable, entries cost a `Just` box but stay shared.
- **Entry readers.** C++ and JS must accept both element forms (a bare `Entry` Custom with 4 fields or a
  `Just` Custom with 1); the size distinguishes them and both readers assert anything else.
- **JS cost.** One extra object per trie slot on JS (no tagged words); gated at 10 %.
- **`eco.hash` disagreement** between specialised and generic paths is a silent miss in every hash
  table; guarded by the inline/runtime codegen tests and the two identity tests.
- **The String cache** touches every String allocation site, the object-size function and P1; it is
  last, census-gated, funnelled through one initialiser and checked by the validate build.
- **Benchmark drift.** D0 changes hash values and so trie shapes; track D is measured against
  `local-dev/post-seq-bench.json`, not the pre-plan baseline.

## 8. Review log

Adversarial review of the medium-detail plan, 2026-11-23 (16 findings). Changes made:

1. S1 would have made users' key/value types kernel-invisible (by dropping `Node`); the root is now a
   `Node` field so visibility is kept as today, stated in §4.1, checked by P2/S1 census.
2. Canonical form missed single-`Sub (Collision …)` branches; T2/T3 now cover them, collisions sit
   at the shallowest possible level, entries in a collision are ordered by index.
3. The validator is representation-agnostic and documented in `Visibility.elm`; it runs from native
   `==` only; no JS validator is claimed.
4. `union`/`diff` bottom-up would lose on small-into-large; size-ratio switch and asymmetric
   workloads (P7) added; `merge` removed from the builder's users.
5. §3.1 now lists the key-object and duplicate rules; tests in P3.
6. `Debug.toString` of SeqDict declared unspecified (P8).
7. `Hash.hash` stability documented (within one program and backend only).
8. Track D moved after S4; `forEachSeqDictEntry` moves into the runtime in D1; D gated on a post-S
   baseline.
9. The String cache needs compositional String hashing (D0) to serve nested Strings; the D4 census
   counts age at hash time and nesting.
10. Gates: pressure stress at every gate, cache wipe procedure, validate build at the end only.
11. JS cost of `Data`/`Sub` objects noted and gated.
12. Additional tagged-union exclusions listed; fallback layout corrected (two bitmaps).
13. `map` keeps sharing (order array first, then the trie's shape).
14. Factual line numbers and descriptions corrected (`Visibility.elm:83-84`, UTF-8 hashing, `map`,
    `union`).
15. Collision tests cover both backends' collision kinds, and `NaN`.
16. Builder and helpers are top-level functions.

## 9. Progress log

- **2026-11-23 stage 0 done.** P2 census in `local-dev/census-before-seq.tsv`; P3 tests
  `SeqDict{Semantics,ReprKeys,Collision,Compaction}Test.elm`; P4 validator (`ECO_SEQDICT_VALIDATE=1`,
  negative control aborts); P6 `design_docs/theory/runtime/value-hash.md`; P7 three union-small
  workloads, baseline re-recorded (27 workloads); P8 no test pins internals, module doc notes it.
- **2026-11-23 A1 done.** `Bitmap.index`/`popCount32` (home `Bitmap`), `eco.int.bitmap_index` /
  `eco.int.popcount32` → `llvm.intr.ctpop`; 14 `popcnt` in the benchmark binary. Gate green (full,
  elm-tests 918 + 22,087, bootstrap, unit 3,163, AOT 249, JS 243 + 35, overrides, pressure stress
  114/114 with `ECO_TEST_TIMEOUT_SECONDS=5400`: the two socket tests exceed the 60 s default
  watchdog under the pressure config). Benchmarks `local-dev/a1-seq-bench.json`: no regression;
  seqdict-small 237 → 222 ms, seqdict-equality 370 → 351 ms.
- **2026-11-23 S1.** New layout in; census: `Slot` `Data` and `Sub` both `bare`, `Maybe (Entry k v)`
  nullable (no `Just` built in `intDictPush`), `Node` boxed; users' key types no longer
  kernel-visible (§4.1). Deviation from D1's plan text noted ahead: the identity switch will be the
  lowering-time `ECO_HASH_INLINE=0` only, without a compile-time config flag.
- **2026-11-23 S1 gate green** (full, elm-tests, bootstrap, unit 3,163, AOT 249, JS, overrides,
  pressure stress 114). Benchmarks `local-dev/s1-seq-bench.json`: peak memory down on every
  SeqDict workload (seqdict-int 498 → 419 MiB, seqdict-equality 646 → 577 MiB, seqdict-algebra
  500 → 450 MiB); native mostly faster (seqdict-custom 113 → 97 ms, seqdict-equality 351 → 310 ms);
  seqdict-iterate slower (434 → 524 ms, `map`); eco-js seqdict-iterate +30 %, seqdict-equality +15 %
  (one wrapper object per trie slot on JS).
- **2026-11-23 S2/S3**: the sort-based builder replaced by the structural rebuild (§4.4); compaction
  trigger 50 %; `union` incremental; the nullable-payload regression found and fixed (§4.5).
  `SeqDictShapeTest.elm` added. One gate run hung in the parallel E2E compile of the eco-system
  suite (around test 105 of 250, 0 % CPU; HTTP-server tests, which do not use SeqDict); killed and
  re-run.
- **2026-11-23 S2/S3 gate green** (eco-system JIT 250, AOT 250, JS 244 + 35, overrides, pressure
  stress 114). The compaction test now crosses the 50 % point through `remove`, `update` and an
  incremental `diff` of a dict with holes.
- **2026-11-23 S4 (stage 5).** `local-dev/post-seq-bench.json` (= `s3-seq-bench.json`) is track D's
  baseline. Native against the pre-plan baseline: seqdict-churn 374 → 194 ms (52 %); seqdict-algebra
  210 → 181 ms; seqset-algebra 207 → 179 ms; seqdict-int 126 → 120 ms; seqdict-string 90 → 84 ms;
  seqdict-custom 110 → 101 ms; seqdict-equality 370 → 317 ms; seqdict-small 237 → 221 ms;
  seqdict-iterate 435 → 536 ms (`map`, §4.5); union-small level (433 → 395 ms). Peak memory
  seqdict-int 499 → 419 MiB, seqdict-equality 646 → 578 MiB, seqdict-algebra 501 → 439 MiB,
  seqset-algebra 529 → 425 MiB. eco-js: seqdict-iterate 849 → 1,036 ms (+22 %) and seqdict-equality
  947 → 1,112 ms (+17 %) exceed the 10 % JS tolerance (no tagged words on JS: one wrapper object per
  trie slot); the others are within it.
  Decisions: no small-dict mode (seqdict-small already 7 % faster); `bulkRatio` stays 8 (no workload
  lies near the switch: `diff` is its only user); A2 (`JsArray2` intrinsics) would remove `map`'s
  per-entry kernel lookups and every trie read's kernel call — put to the user.
- **2026-11-23 D0 done.** Definition v2 in the walker (compositional Strings, two units per step
  from segments, never 0); `value-hash.md` marks v2 current. Bounds unchanged, so the collision tests
  still collide.
- **2026-11-23 D3 done.** `Hash` exposed in eco/system (`src/Hash.elm`, docs state the guarantees and
  non-guarantees); README rewritten for SeqDict's new layout and `Hash`; `HashTest.elm` (equal values,
  every representation, JIT and JS).
- **2026-11-23 D1 done.** The walker moved into the runtime (`runtime/src/allocator/ValueHash.{hpp,cpp}`,
  with `SeqDictLayout.hpp` holding `forEachSeqDictEntry`; `elm-kernel-cpp/src/core/SeqDict.hpp` keeps
  the validator; `Eco_Kernel_FNV_hash` calls `eco_hash_value`; `check-ctor-tags.sh` reads the new
  header). `eco.hash` op (kinds int, float, char, bool, string, value) emitted by `Expr.elm`'s
  `( "FNV", "hash", … )` arm; lowered inline for primitives, else `eco_hash_string`/`eco_hash_value`;
  runtime decls in `materializeAllRuntimeDecls`, JIT symbols in `RuntimeSymbols.cpp`. Tests:
  `test/codegen/hash_inline_matches_runtime.mlir` (17 values, inline = walker); identity pair
  `HashIdentityTest.elm` / `HashIdentityGenericTest.elm` (`-- ENV: ECO_HASH_INLINE=0`); negative control
  (inline Int marker broken) fails only the inline copy, so the switch reaches the JIT's lowering.
  Deviations: no compile-time `ECO_HASH_INTRINSIC` flag (the lowering switch serves the identity test);
  no `HashIntrinsicTest.elm` compiler unit test (the unit-test source builder cannot import eco/system;
  the E2E tests and an MLIR check of `SeqDictReprKeysTest` cover it: 36 `eco.hash`, no kernel calls).
  A `Hash.hash` passed as a function value still calls the kernel (by design).
- **2026-11-23 D2 done (reduced scope).** Typed hashing of tuples and records whose fields are Int,
  Float, Char, Bool or String: `eco.hash.mix` (kinds int, float, char, bool, boolword, string, marker)
  and `eco.hash.finish`, emitted by `generateTypedHash` with fields read through
  `Patterns.generateMonoPath` (a record in heap slot order); `eco_hash_mix_string` applies the walker's
  String step. Such shapes need no depth or item bookkeeping, so the chain is exact. Not done: generated
  functions for custom types, lists and nested aggregates (they keep calling the walker; the hash is a
  small share of SeqDict time, §2). Test `HashTypedTest.elm` compares the typed chain with the kernel
  (`Hash.hash` as a function value) on tuples, records and 200 built values. A Bool field is read as its
  stored constant word and compared with True (no `ptrtoint`, REP_LLVM_001).
- **2026-11-23 A2 done (user decision after S4: "Yes, do A2").** `kernelIntrinsicOn` routes home
  `JsArray2` through `jsArray2Intrinsic` (`unsafeGet`, `unsafeSet`, `length`, `push`, `singleton` take
  `JsArray`'s operations; `arrayElementType` knows the `JsArray2` type); `unsafeInsert`, `removeIndex`
  stay kernel calls. SeqDict's trie reads are inline (`SeqDictReprKeysTest`: 108 `eco.array.get`, 126
  `eco.array.set`, no `JsArray2.unsafeGet` call). Test `compiler/tests/Compiler/IR/Kernel/
  IntrinsicsJsArray2Test.elm`. Gate green (with the D0-D2 gate: full, elm-tests, bootstrap, unit 3,169,
  AOT 254, JS 246 + 35, overrides, stress 114; the D1 codegen test's function-scoped CHECK-NOT, which
  this harness scopes differently, became file-wide checks). Benchmarks `local-dev/a2-seq-bench.json`
  against `post-seq-bench.json`: seqdict-int 120 → 100 ms, seqdict-tuple 91 → 77, seqdict-custom
  101 → 90, seqdict-churn 194 → 163, seqdict-update 172 → 146, seqdict-equality 317 → 265,
  seqdict-algebra 181 → 155, seqset-algebra 179 → 153, seqset-distinct 171 → 149, union-small
  395 → 359, seqdict-longkey-reuse 343 → 299, seqdict-iterate 536 → 515 (still above the pre-plan
  435 ms: `map`'s per-entry lookup and the closure calls of `JsArray2.map`, §4.5).
- **2026-11-23 D4 done.** `ECO_HASH_CENSUS=1` (`ValueHash.cpp` `census`: String hashes and units by
  form, length, where the String lived at hash time, nesting, and repeats of the same object within a
  minor epoch; printed at exit; documented in `docs/options.md`). Its `std::atexit` fired the TLA+
  canary's `F.atexit` grep pin (M6): investigated, no model change needed (it reads only mutator-owned
  counters, takes no lock, touches no heap), AUDIT.md entry and MAPPING.md row updated, manifest
  re-pinned. Census (native, default sizes):

  | workload | String hashes | repeated (same object) | first hashes at nursery age 0 |
  |---|---:|---:|---:|
  | seqdict-longkey | 80,000 (15.3 M units) | 0 | all |
  | seqdict-longkey-reuse | 360,000 (68.7 M units) | 240,000 (45.8 M units, 67 %) | 2,642 of 120,000 |
  | seqdict-string | 260,000 (1.4 M units) | 0 | all (all < 32 units) |
  | seqdict-intern | 213,894 (1.2 M units) | 213,882 | none: PermanentSpace literals, nested, ~5.5 units |

- **2026-11-23 D5: no-go (census rule of D4).** Repeats are two thirds of the reused-key units, but only
  2,642 of the 120,000 first hashes happen while the String is still in the nursery at age 0: keys
  built in bulk survive a collection before they are first hashed, and under P1 the cache could not be
  filled for them. The repeated literals are tiny. So the young-only cache would serve almost nothing;
  D5 was not built. Stage X keeps the question of caching (including a P1 carve-out for a write-once
  word) for the end.
- **2026-11-23 Final, docs.** `design_docs/invariants.csv`: CGEN_095 (value hash ops), CGEN_096 (bitmap
  counts), KERN_009 (SeqDict layout); `design_docs/theory/runtime/data-structures.md` gains a "SeqDict
  and the value hash" section; `docs/options.md` lists `ECO_HASH_INLINE`, `ECO_HASH_CENSUS`,
  `ECO_SEQDICT_VALIDATE`.
