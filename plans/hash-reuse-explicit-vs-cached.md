---
status: partial
updated: 2026-11-25
remaining: "Part A on branch hash-explicit (not gated); Part B on hash-cache: B0-B5c implemented (v4 CRC32C, propagation, composition), B6 measured and removed (no site pays), B8 not done; self-build check done (fe-opt-loop hashcrc: 76.85 s, -1.72 s vs hashonce, FLAT); gates: full + bootstrap PASSED 2026-11-25 (native 3,184/3,184, JS E2E eco-system 248/248 + conformance 35/35; fixed check-large-body-access in checkStringHashSlot); the full ECO_HEAP_VALIDATE gate (B7) deferred by the user to a much later date (only targeted validate tests run); A-vs-B decided 2026-11-25: B for Strings, structures in plans/hashed-values-and-hash-consing.md"
---

# Hash reuse: explicit `Hashed` keys against a transparent String hash cache

A SeqDict or SeqSet operation hashes its key once, and the trie then works on the stored hashes.
But every operation hashes again: four lookups of one long key, made in four different functions or
loop iterations, hash it four times. (Repeats within **one** function are already merged: see §1.1.)
This plan builds two ways of hashing a key once and reusing the result, on two branches from one
base. It measures both the same way and picks one.

- **Part A, explicit:** an opaque `Hashed a` (a value and its hash) in eco/system's `Hash` module,
  and a `...Hashed` twin of every exposed SeqDict/SeqSet operation that hashes a key. A program
  opts in.
- **Part B, transparent:** Strings of length ≥ T carry a cached per-String hash in the heap. It is
  filled on demand, at creation where that is free (literals; a copy of a String with a known hash),
  by composing the hashes of the Strings a new String is built from (`++`, `concat`, `join`, ropes),
  and by hashing a String as it is built where that is measured to pay. Composition needs a
  composable hash: v4, CRC32C computed as crc32c-fold128 (§4.2, design_docs/string-hash-algorithm.md).
  No program changes. Strings only.

The user creates the branches and makes the commits at the points marked **USER**. Do not create
branches or commits yourself.

## 0. Review history

- **2026-11-24 first draft.**
- **2026-11-24 adversarial review against the code** (this revision). Corrections:
  1. §1.1 said the SeqDict wrappers are never inlined. They are now:
     plans/seqdict-hash-once-per-function.md has been implemented (A1-A6 in its log). `get`,
     `member`, `insert`, `remove` (SeqDict) and `member`, `insert`, `remove` (SeqSet) are in
     `InlineSimplify.defaultWhitelist`, and the Mono CSE hash mode merges repeated `FNV.hash` of one
     local in a function (CSE_001, CGEN_095). Consequences: the base includes that work. Neither
     part gains on seqdict-intern or seqdict-multi-lookup, whose repeats were within one function.
     The old §6 bullet "inlining is out of scope" is gone. (That plan's header still reads
     `status: not-started`; its owner should update it.)
  2. The SeqDict twin list left out `updateIfExists`, which is exposed and hashes its key.
  3. The twins must join `defaultWhitelist`. Otherwise a plain call is inlined and its twin is
     not, and Part A pays a call that the base does not.
  4. `Data.HashMap` belongs to the compiler (`compiler/src/Data/HashMap.elm`), not to eco/kernel.
     Only `Eco.Hash` is eco/kernel's.
  5. The slot holds the **per-String** hash `stringHash(s)` (ValueHash.cpp), not the walker's final
     number. The walker mixes a String in as `mix(kString); mix(stringHash(s))`, so a slot serves a
     top-level String key, a String nested in a tuple, record or custom key (walker and typed
     chains), and the `==` fast-reject.
  6. **Rope `height` does not fit in `header.unboxed`.** `makeRope` sets `height = 1 + max(children)`
     and nothing bounds it: a left-deep chain of `++` above `string_flatten_limit` (128 Ki units)
     grows by one per append. But nothing reads `height` or `leafCount` for a decision:
     `heightOf` and `leafCountOf` (StringOps.hpp:126-137) have no callers, and no test reads them.
     So `height` is stored saturated at 63 in `unboxed`, and its comment says so.
  7. **Data race.** The concurrent tenure engines copy objects with `memcpy` while the mutator runs
     (NurseryTenure.cpp:114, the exact engine on collector member 0; :1093, the concurrent parallel
     engine). A mutator store into the slot of an object being copied is a C++ data race, which
     the heap TSan build reports. The fix: the mutator uses relaxed atomic 32-bit loads and stores,
     and these two copy sites copy a String's slot word with a relaxed atomic load (§4.1.6).
  8. Validate builds have **two** P1 detectors that would flag a fill. Detector O re-hashes a
     sample of promoted objects, and detector N (NurserySpace) hashes survivors. Both must mask
     the slot. A third rule is broken too: HEAP_036 says PermanentSpace contents are immutable, and
     a fill writes into an interned literal or a CAF's copied String. So the carve-out amends
     HEAP_036 as well as HEAP_SNAPSHOT_001.
  9. If an allocation site forgets to zero a slot, the slot holds garbage, which reads as a cached
     hash: a **silent wrong SeqDict miss** in a release build. The safety nets are made explicit:
     a validate-build check of every slot at every minor, and one unit test per allocation route.
  10. seqdict-intern's Strings are PermanentSpace literals of about 5.5 units (D4 census, plans/
      seq-data-structures-performance.md). They are below T and get no slot, so Part B does
      nothing there. A literal hashed at intern (B3) helps only literals ≥ T, so B3 is expected
      flat.
  11. The `==` fast-reject (B4) had no workload. SeqDict compares keys only when their hashes are
      equal, and string-eq-prefix never hashes. B4 is measured by string-eq-prefix alone: with empty
      slots the check must cost nothing (string-eq-hashed, a pre-hashed variant, was added and
      then dropped, see the Part B log).
  12. The measuring scripts lived only in `/tmp/seqwork`, which a reboot clears. `ab.sh` there only
      rebuilds and copies a bench binary; it does no interleaved A/B runs. Step M makes persistent
      scripts under `local-dev/hashreuse/` (gitignored, so they survive branch switches) and adds
      the interleaving runner. The base JSON lives in `local-dev/` too, which is gitignored: the
      **USER** commit of step M commits the benchmark sources and this plan, not the figures.
  13. The estimate for seqdict-prefixkey was wrong. It does 180,000 hashes (20,000 inserts, then
      4 rounds of 20,000 present and 20,000 absent lookups), of which 140,000 repeat (7 of 9, not
      8 of 9). At v3's ~255 ns per 2,007-unit key that is ~46 ms of hashing, ~36 ms of it repeated,
      in a 135 ms workload (local-dev/post-hash-inline-bench.json). The old figure was ~20 ms.
      seqdict-longkey-reuse (190-unit keys) repeats ~240,000 × ~27 ns ≈ 6.5 ms of 294 ms (~2 %).
  14. "String bytes allocated (GC stats)" exists only in a `ENABLE_GC_STATS` build (the `dev`
      preset), as a size histogram (`string_alloc_size_histogram`) plus the nursery's
      `bytes_allocated`. §2.1 now says which build records them.
  15. A branch switch in this one worktree leaves stale builds and caches behind. Before every
      measurement, §2.3 rebuilds and wipes the caches.
  16. The Part A twins copy the plain bodies rather than refactoring the plain functions to share a
      helper. The plain functions stay byte-identical, so the plain workloads on `hash-explicit`
      measure the base's code.
  17. eco/system's normative API (the `ecosyskernel` stubs repo, memory of Oct 19) is not in this
      tree. Adding `Hashed` and the twins to it is a **USER** item.
- **2026-11-24 amendment (user): v4 is CRC32C as crc32c-fold128; compose wherever the parts' hashes
  are known; hash at build where that is efficient.** The String hash lab
  (`experiments/string-hash-lab/`, report design_docs/string-hash-algorithm.md) measured composable
  hashes against v3 and chose crc32c-fold128 (§4.2). Changes: §1.3 (superseded by the lab); §4.1.5
  (five fill policies: on demand, literals, propagation, composition, hash at build, with a table of
  build sites); §4.2 (the v4 definition, implementation, CPU support, quality); §4.3 (B5 split into
  B5a v4, B5b propagation, B5c composition; B6 hash at build for per-unit builders); §5 (rows for
  the composition workloads). The B0 decision "v4 not built" (§7) is overridden: composition was
  skipped because no workload hashed both sides of a `++` first, but the amended composition also
  hashes a short or unknown part as the build reads it and stores a part's hash in its own slot, so
  that later builds from the same part compose without reading it.

## 1. Where things stand (verified 2026-11-24)

### 1.1 Hashing in SeqDict and SeqSet

- SeqDict (`system-kernel-cpp/src/SeqDict.elm`) hashes keys with `FNV.hash` (the same kernel,
  `Eco.Kernel.FNV.hash`, as `Hash.hash`). The exposed operations that hash a key are:
  `get` (:181), `member` (:253), `insert` (:266), `remove` (:457), `update` (:565), `updateIfExists`
  (:589), and `singleton` (via `insert`). Each passes the number to a worker that takes it:
  `getEntry hash key root` (:193), `insertWithHash hash key value root order` (:274),
  `removeWithHash hash key dict` (:464). Entries store their key's hash. A lookup compares the
  stored hash before the key. Bulk operations (`union`, `diff`, `merge`, ...) reuse stored hashes.
- SeqSet (`SeqSet.elm`) is `SeqSet_elm_builtin (SeqDict a Bool)` and delegates `member`, `insert`
  and `remove` to SeqDict.
- **Within one function a key is hashed once** (natively): the seven wrappers above (not `update`,
  `updateIfExists`) are in `InlineSimplify.defaultWhitelist` (InlineSimplify.elm:1144-1151), and
  `Compiler.MonoOpt.Cse`'s hash mode merges repeated `FNV.hash x` of one local
  (design_docs/theory/runtime/value-hash.md, "One hash per key per function"). What is left is
  reuse **across** functions, loop iterations and data structures: the subject of this plan.
- String hash definition v3 (value-hash.md) costs ~0.127 ns per unit (255 ns at 2,016 units).
  `stringHash(s)` (ValueHash.cpp:191) is a per-String hash, never 0 (`nonZero`). The walker mixes
  it in as `mix(kString); mix(stringHash(s))`, and `eco_hash_string` (:470) and
  `eco_hash_mix_string` (:503) go through the walker's `string()` (:334). Under v3 every String
  form gives the same number (flat UTF-16, UTF-8 leaf, slice, rope, view, large).
- The ceiling on the reuse workloads (estimates, measured in A0): seqdict-prefixkey (135 ms native)
  ~36 ms of repeated hashing (~27 %). seqdict-longkey-reuse (294 ms) ~6.5 ms (~2 %).
  seqdict-intern and seqdict-multi-lookup: ~0 (repeats already merged; their Strings are short).
- **The compiler does not use SeqDict or `FNV.hash`.** It hashes with eco/kernel's `Eco.Hash`
  (`stringWithSeed`, `string64`: its own FNV-style definitions, `eco-kernel-cpp/src/Eco/Hash.elm`)
  through its own `Data.HashMap` (`compiler/src/Data/HashMap.elm`). That map already takes
  caller-computed hashes (`getHashed`, `insertNew`), the explicit style of Part A. So the
  compiler's self-build measures what each branch **costs**, not what it gains, unless Part B also
  serves `Eco.Hash` (B8, optional). `Data.HashMap` iterates in insertion order (`nextSeq`, its doc
  at :27), so changing its bucket numbers cannot change compiler output.

### 1.2 Header and payload space

`Header` (Heap.hpp:150) is one 64-bit word: `tag:5 color:2 pin:1 age:2 unboxed:6 refcount:15
builder:1`, then `size:32`. 26 of the 32 tag values are used.

- `refcount` holds no reference count. Only a `Tag_Free` cell (old-gen free-list links,
  OldGenSpace.hpp:148-196) and the constructor census (`Tag_Custom` only, `_census_id`,
  GCStats.hpp:100) use it.
- **Concurrency:** concurrent markers and the collectors write `color` with plain bit-field stores
  (`hdr->color = ...`): a read-modify-write of the whole first 32-bit word. So no bit in that word
  may change **after publication** unless all writers switch to atomic RMW. A bit or field set
  **before publication** (at allocation) is safe. `size` is never written after allocation.

String forms (Heap.hpp):

| form (tag) | layout | free space for a 32-bit slot |
|---|---|---|
| flat UTF-16 (`Tag_String`, `ElmString`) | header, `u16 chars[size]`, padded to 8 | none: a tail word (§4.1) |
| UTF-8 leaf (`Tag_StringUtf8Leaf`) | header, `u8 bytes[size]`, padded to 8 | none: a tail word |
| slice (`Tag_StringSlice`, 24 B) | header, `base`, `u32 offset`, `u32 _padding` | `_padding` |
| UTF-8 view (`Tag_StringUtf8View`, 24 B) | header, `base`, `u32 offset`, `u32 byteLen` | `byteLen` (== `header.size`; 1 writer StringOps.cpp:117, 1 reader StringOps.hpp:119) |
| rope (`Tag_StringRope`, 32 B) | header, `left`, `right`, `u32 height`, `u32 leafCount` | `height`, if it moves into `unboxed` (saturated, §0 item 6) |
| large (`Tag_LargeStringHeader`, 16 B, static_assert Heap.hpp:549) | header, `body` | none: grows to 24 B |

Default sizes: `string_flatten_limit` 128 Ki units (AllocatorCommon.hpp:130), so `++` of keys
shorter than that makes a flat copy. `LARGE_OBJECT_THRESHOLD` 8 KiB (:117), so an all-ASCII key of
2,007 characters is a UTF-8 leaf. The long-key benchmarks exercise mainly the UTF-8 leaf.

### 1.3 Can the String hash be computed at creation, or composed across `++`?

- **At creation: yes, for any definition**, by running it over the new String. The cost is one read
  of every unit of every String ≥ T made, most of which are never hashed. It is free only where
  creation already reads every unit and the hash is folded into that loop.
- **Across `++`: not with v3.** v3's lanes start from fixed seeds at the String's start, so
  `hash (a ++ b)` cannot be made from `hash a` and `hash b`. A composable definition is
  `H(a ++ b) = combine(H(a), H(b), length b)`. Measured (C++, `/tmp/seqwork/compose/c.cpp`, to be
  copied to `local-dev/hashreuse/compose/` in step M; ns per String, ASCII units widened):

  | length (units) | v3 | CRC32C, 1 stream | CRC32C, 3 streams | polynomial mod 2^61-1 |
  |--:|--:|--:|--:|--:|
  | 32 | 6.0 | 4.3 | 4.3 | 20.0 |
  | 192 | 27.1 | 33.5 | 24.2 | 127.4 |
  | 2,016 | 255.1 | 370.0 | 228.8 | 1,273.7 |
  | 4,096 | 565.6 | 829.0 | 503.6 | 2,593.8 |

  The combine for a ~2,000-unit right side takes 15.7 ns with CRC32C and 20.3 ns with the
  polynomial. CRC32C with three interleaved streams (the SSE4.2 / ARMv8 `crc32c` instruction) is as
  fast as v3, and it composes through the standard `crc32c_combine`: multiply by x^(8·bytes) mod P
  with carry-less multiplies, using a table of x^(2^k). It is linear over GF(2), so the raw value
  must be finalised (`fmix32`, a bijection) before SeqDict reads 5-bit groups. Finalising does not
  remove a collision of the raw value, so B0 must check its collisions on structured keys. The
  state cached for composition is the raw 32-bit CRC (the length is in the header).
- **Superseded (2026-11-24) by the String hash lab** (design_docs/string-hash-algorithm.md): the table
  above is scalar code. Vectorised, CRC32C with 16-byte PCLMULQDQ folding (crc32c-fold128) is faster
  than v3 below ~64 units and ~1.2× slower on long Strings at x86-64-v3 (2.4-3.4× faster with AVX-512
  folding); `combine` takes 3.4-4.3 ns at any length; its quality equals v3's on collisions,
  avalanche, every-window distribution and sparse differentials. It is v4 (§4.2).

## 2. Method

### 2.1 Base, branches and measurements

1. **USER:** commit the work already in the tree (String hash v3 and the long-String benchmarks;
   plans/seqdict-hash-once-per-function.md A1-A5) to main. **The full gate is owed first:** neither
   that plan's log nor plans/seq-data-structures-performance.md's v3 entry records a full gate.
   Remind the user; do not run it unasked. That commit is the **base**.
2. On the base, before branching, do step M (§2.2) and record the base figures (§2.3). **USER:**
   commit step M's sources (benchmarks, README, this plan) to main. That commit is the branch
   point.
3. **USER:** create branch `hash-explicit` from the branch point; Part A runs there. **USER:**
   commit at the end of Part A.
4. **USER:** create branch `hash-cache` from the branch point; Part B runs there. **USER:** commit
   at the checkpoints marked in §4.3 and at the end of Part B.
5. Compare (§5) and pick a winner; the other branch is kept for reference or deleted (user's call).

What each branch measures, exactly as the base did:

- **Benchmarks:** the whole suite with `local-dev/hashreuse/bench-full.sh <out.json>` (eco native and
  eco-js, run.mjs defaults warmup 3 / runs 11; it records peak RSS per workload with GNU time).
  Single runs of this suite move up to ±10 % on unrelated workloads (fib, string-compare-prefix).
  Re-measure any workload that moves by more than 5 % with `local-dev/hashreuse/ab-interleave.sh`
  (5 alternations of the base and branch bench binaries, medians) before reporting it.
- **Compiler self-build:** a cold self-compile of the compiler with the branch's native eco
  (`--no-cache`, `eco-stuff` moved aside under /tmp), wall time and peak RSS, N = 3, median. Use
  the same command as plans/seqdict-hash-once-per-function.md §7.2 (whose base self-build figure is
  recorded in its log). This is a cost check (§1.1).
- **Memory:** peak RSS per workload (the suite's). For Part B also String allocation: build the
  `dev` preset (`ENABLE_GC_STATS`) once on each side and run the reuse workloads plus seqdict-string
  and json-* with the GC stats banner on. Record `bytes_allocated` and the String size histogram.
- **Gates:** targeted tests during each part (§3.3, §4.3). The full gate runs once at the end of
  each part, before its final commit; the user runs it or asks for it.

### 2.2 Step M: shared measurement pieces (on the base)

M1. **Scripts** in `local-dev/hashreuse/` (gitignored; survives branch switches). Copy and adapt
from `/tmp/seqwork` if it still exists, otherwise write them from these descriptions:
- `eco`: wrapper, `exec /work/build/compiler/build-kernel/bin/eco "$@" --local-package=eco/system=/work/system-kernel-cpp`.
- `bench-full.sh OUT.json [run.mjs args]`: `cd examples/benchmarks`, move `eco-stuff` aside to
  `/tmp/eco-stuff-<date>`, run `ECO=<wrapper> node run.mjs --skip-elm "$@"`, then wrap
  `build/results.json` with `about`, `recorded`, `eco` (binary path and mtime) and `host` into
  OUT.json. (This is `/tmp/seqwork/bench-full.sh` with paths changed.)
- `save-bench.sh LABEL`: build the bench program for one workload
  (`node run.mjs --skip-elm --runs 1 --warmup 0 seqdict-string`) and copy
  `examples/benchmarks/build/bench` (native; the runtime is linked in) to
  `local-dev/hashreuse/bench-LABEL`. Check first how run.mjs invokes that binary for one workload
  (`grep -n "bench" examples/benchmarks/run.mjs`) and write the exact argument form into the
  script's header comment.
- `ab-interleave.sh A B WORKLOAD [N=5]`: run `bench-A` and `bench-B` on WORKLOAD alternately N times
  each, as run.mjs does (same size, warmup and runs), and print both medians.
- `compose/` and `hv3/`: copies of `/tmp/seqwork/compose` and `/tmp/seqwork/hv3` (B0 extends them).
  If they are gone, B0 rewrites them (§4.3 B0 says what they must compute).

M2. **Workloads**, in `examples/benchmarks/src/SeqLargeKeys.elm` and `StringCompare.elm`,
registered in `Bench.elm`'s workload list next to the existing seqdict-* entries, and described in
the module docs (the style of SeqLargeKeys.elm:3-41). Each checks itself in closed form, as its
neighbours do.
- **seqset-prefixkey-rounds** (`SeqLargeKeys.benchSetPrefixRounds`): `n` keys
  `StringCompare.prefixKey (StringCompare.prefixOf 500) code` for a permutation of `0..n-1` (as
  `benchPrefixKey`), built once and inserted into a `SeqSet String`. Then 32 rounds of
  `SeqSet.member` over all present keys and as many absent ones (`code + n`). Check:
  `hits == 32 * n`. Size: choose `n` so that native runs in ~100-200 ms on the base (start at
  5,000), and record it.
- **seqdict-shortkey-reuse** (`SeqLargeKeys.benchShortKeyReuse`): seqdict-string's keys
  (`String.fromInt k`, < 8 units), built once into a list, inserted, then 8 rounds of
  `SeqDict.get`. Check the sum of found values. It catches overhead where reuse cannot matter.
- seqdict-prefixkey, seqdict-longkey-reuse and seqdict-intern exist and are unchanged.

M3. A paragraph in `examples/benchmarks/README.md`: the `-hashed` workload variants exist only on
`hash-explicit`.

M4. Run `bench-full.sh local-dev/hashreuse-base-bench.json`, `save-bench.sh base`, the base
self-build (§2.1) and the base `dev`-preset String figures. Write them in §7.

### 2.3 Before every measurement or E2E run on a branch

The two branches share one worktree, so after the user switches branches:

1. `cmake --build build` (the whole tree: runtime libraries, compiler, `eco`; a stale runtime
   library gives wrong results, memory "RELOWER NEEDS ALL RUNTIME LIBS"), then
   `cmake --build build --target test` for the unit/E2E binary (test binaries are not in ALL).
2. Wipe caches: `rm -rf examples/benchmarks/eco-stuff build/test/*/eco-stuff`, the package
   artifacts `~/.eco/<version>/packages/**/{artifacts,typed-artifacts}.dat`, and the copied
   `~/.eco/<version>/packages/eco/kernel` (and `eco/system` if present). Here `<version>` is each
   directory under `~/.eco`. Part B changes the heap layout that compiled code assumes
   (`computeAllocSize`), so a stale `.o` or `.mlir` would be wrong, not merely slow.
3. `ulimit -c 0` before any validate-build run (negative-control tests dump cores).

## 3. Part A: explicit `Hashed` keys (branch `hash-explicit`)

### 3.1 API and code

`system-kernel-cpp/src/Hash.elm` becomes:

```elm
module Hash exposing (hash, Hashed, hashed, value, hashOf)

{-| Hash any value, or pair a value with its hash to reuse it.

@docs hash
@docs Hashed, hashed, value, hashOf

-}

import Eco.Kernel.FNV

-- `hash`: unchanged, including its doc comment.


{-| A value together with its `hash`, computed once.

`SeqDict.getHashed`, `SeqSet.memberHashed` and the other `...Hashed` operations take one instead of
a key and use the stored hash instead of hashing the key again. Build it once with `hashed` and
use it many times; that saves a hash per use, which pays for long `String` keys and large
structures. The hash and the value are paired by construction, so a `Hashed` can never carry a
wrong hash. As with `hash`, the number is only valid within one run of one program: never store a
`Hashed` or send it through a port. `==` on two `Hashed` values agrees with `==` on their values.
-}
type Hashed a
    = Hashed Int a


{-| Pair a value with its hash. -}
hashed : a -> Hashed a
hashed v =
    Hashed (Eco.Kernel.FNV.hash v) v


{-| The value. -}
value : Hashed a -> a
value (Hashed _ v) =
    v


{-| The hash: the number `hash (value h)` gives. -}
hashOf : Hashed a -> Int
hashOf (Hashed h _) =
    h
```

`Hashed` is exposed without its constructor (opaque). `hashed` must call `Eco.Kernel.FNV.hash`
directly, as `hash` does, so the Mono CSE hash mode (Cse.elm:873 matches the kernel call) and the
typed hash chains (CGEN_095) apply to it as they do to `FNV.hash`.

`SeqDict.elm`: add `import Hash exposing (Hashed)`, add the twins to the `exposing` list and to the
`@docs` lines (Build: `insertHashed, updateHashed, updateIfExistsHashed, removeHashed`; Query:
`getHashed, memberHashed`). Each twin is a **copy** of its plain function's body with `FNV.hash key`
replaced by `Hash.hashOf hk` and `key` by `Hash.value hk`. Do not refactor the plain functions
(§0 item 16).

```elm
getHashed : Hashed k -> SeqDict k v -> Maybe v
getHashed hk (SeqDict_elm_builtin root _) =
    case getEntry (Hash.hashOf hk) (Hash.value hk) root of
        Just (Entry _ _ _ v) ->
            Just v

        Nothing ->
            Nothing


memberHashed : Hashed k -> SeqDict k v -> Bool
-- as `member` (:253), with getEntry (Hash.hashOf hk) (Hash.value hk) root

insertHashed : Hashed k -> v -> SeqDict k v -> SeqDict k v
insertHashed hk v (SeqDict_elm_builtin root order) =
    insertWithHash (Hash.hashOf hk) (Hash.value hk) v root order

removeHashed : Hashed k -> SeqDict k v -> SeqDict k v
removeHashed hk dict =
    removeWithHash (Hash.hashOf hk) (Hash.value hk) (rebuildOnOverflow dict)

updateHashed : Hashed k -> (Maybe v -> Maybe v) -> SeqDict k v -> SeqDict k v
-- `update`'s body (:565-585) with `hash = Hash.hashOf hk` and `key = Hash.value hk` in its let

updateIfExistsHashed : Hashed k -> (v -> v) -> SeqDict k v -> SeqDict k v
-- `updateIfExists`'s body (:589-600), likewise
```

Mind the name clashes in SeqDict.elm: parameters called `value` and local bindings called `hash`
exist. Always write `Hash.value` / `Hash.hashOf` qualified, and name the twin's value parameter `v`.
Each twin's doc comment says "As `get`, with the key's hash computed once by `Hash.hashed`" (and so
on).

`SeqSet.elm`: `import Hash exposing (Hashed)`, and expose and document `memberHashed`,
`insertHashed` and `removeHashed`:

```elm
memberHashed : Hashed a -> SeqSet a -> Bool
memberHashed hk (SeqSet_elm_builtin dict) =
    Dict.memberHashed hk dict

insertHashed : Hashed a -> SeqSet a -> SeqSet a
insertHashed hk (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.insertHashed hk True dict)

removeHashed : Hashed a -> SeqSet a -> SeqSet a
removeHashed hk (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.removeHashed hk dict)
```

`compiler/src/Compiler/MonoOpt/InlineSimplify.elm` `defaultWhitelist` (:1144-1151): add
`"eco/system:SeqDict.getHashed"`, `memberHashed`, `insertHashed`, `removeHashed`, and
`"eco/system:SeqSet.memberHashed"`, `insertHashed`, `removeHashed`, mirroring the plain entries.
Extend the docstring above it (:1061) by one sentence: the `...Hashed` twins are listed so that
they cost what their plain wrappers cost. `updateHashed`/`updateIfExistsHashed` are not listed,
as `update` is not.

No kernel, runtime or JS change. Both backends run the same Elm. JS's `==` on SeqDict is
overridden (`compiler/kernel-overrides/SeqDictEquality.js`), but that does not involve `Hashed`.

### 3.2 Steps

- **A0. Measure first (on the base or this branch before A1).** Use `sudo -n perf record -g` on the
  base bench binary running seqdict-prefixkey and seqset-prefixkey-rounds. Record the share of
  `Hasher::string` / `stringHash` in §7. Expected: ~25-35 % on seqdict-prefixkey.
- **A1. Hash.elm** as in §3.1.
- **A2. Twins** in SeqDict.elm and SeqSet.elm; whitelist entries; the `eco-system-docs` target
  (`cmake --build build --target eco-system-docs`) must still build `system-kernel-cpp/docs.json`
  with stock elm. That checks the docs and the types.
- **A3. Tests** in a new `test/eco-system/src/SeqDictHashedTest.elm`, a `main` that prints `CHECK:`
  lines like its neighbours (copy the structure of SeqDictHashOnceTest.elm), with
  `-- ENV: ECO_SEQDICT_VALIDATE=1`:
  - For each key set: Strings (short, 190 and 2,000 units), the three colliding Strings
    `c600662`, `c5330492`, `c11005860` (SeqDictCollisionTest), `( String, Int )` tuples, records
    with a String field, and a custom-type tree. Build dict P with the plain operations and dict H
    with the twins (`insertHashed`, `removeHashed` of every 3rd key, `updateHashed` and
    `updateIfExistsHashed` on every 5th). Print `P == H` and `SeqDict.toList P == SeqDict.toList H`.
    `ECO_SEQDICT_VALIDATE=1` validates both operands of `==`, but its T1 only checks that each
    entry sits under its **stored** hash's path, not that the stored hash is `FNV.hash key`. A
    consistently wrong hash passes it and passes `==` (the negative control showed this). So the
    lookups must cross over: for present and absent keys, plain `get`/`member` of H and
    `getHashed`/`memberHashed` of P must agree with plain lookups of P.
  - The same for SeqSet.
  - `Hash.hashOf (Hash.hashed x) == Hash.hash x` for every key; `Hash.value (Hash.hashed x) == x`.
  - **Negative control** (run once by hand, not committed): make `hashed` store `hash v + 1`.
    The test must fail on every line (the cross lookups). Record the outcome in §7.
  - Run natively: `cmake --build build --target test`, then
    `./build/test/test --filter SeqDictHashed 2>&1 | tee /tmp/test_output.txt`. On JS:
    `TEST_FILTER=SeqDictHashed cmake --build build --target run-js-e2e 2>&1 | tee /tmp/test_output.txt`.
    Also re-run the existing `--filter SeqDict`, `--filter SeqSet`, `--filter Hash` sets once
    (natively and on JS) to show the plain functions are unchanged.
  - `compiler/tests/Compiler/MonoOpt/InlineSimplifyWhitelistTest.elm`: if it pins the default
    list's length or content, update it.
- **A4. Benchmarks.** In SeqLargeKeys.elm, add `-hashed` twins of seqdict-prefixkey,
  seqset-prefixkey-rounds, seqdict-longkey-reuse and seqdict-intern. Each does the same work, with
  every key wrapped once with `Hash.hashed` when the key list is built and the twin operations used
  throughout. For seqdict-intern's `probe`, use `getHashed` then `insertHashed`. Register them in
  Bench.elm as `<name>-hashed`. Then run the whole suite, the self-build and the `ab-interleave`
  confirmations (§2.1).
- **A5. Docs.** `design_docs/theory/runtime/value-hash.md` gets a section "Reusing a hash
  (`Hash.Hashed`)". `design_docs/theory/runtime/data-structures.md` §"SeqDict and the value hash"
  (:120) gets one paragraph on the twins. The SeqDict module doc (SeqDict.elm:15-17) gets one
  sentence pointing to `Hash.hashed` for reuse across functions. Write `docs.json` through
  `eco-system-docs`. **USER:** mirror the new API in the normative `ecosyskernel` stubs.

Exit: targeted tests green on both backends; the `-hashed` variants measured; full gate before the
**USER** commit.

## 4. Part B: transparent String hash cache (branch `hash-cache`)

### 4.1 Design

**4.1.1 Which Strings carry a slot.** A 32-bit slot. Whether a String has one follows from its tag
and `header.size` alone (no header bit):

| form | slot | how |
|---|---|---|
| slice | always | `_padding` renamed `hashSlot` |
| UTF-8 view | always | `byteLen` renamed `hashSlot`; its one reader (StringOps.hpp:119) uses `header.size`; its writer (StringOps.cpp:117) writes 0 |
| rope | always | `height` renamed `hashSlot`; the height moves to `header.unboxed`, saturated: `min(h, 63)`, with `heightOf` reading it there |
| large String | always | a new `u32 hashSlot; u32 _pad;` after `body` (16 → 24 B; update the static_assert; `LargeByteHeader` stays 16) |
| flat UTF-16, UTF-8 leaf, `size >= T` | yes | a tail word after the padded payload |
| flat, `size < T` | none | v3's short path costs a few ns |

T is the compile-time constant `kStringHashSlotMinUnits`, decided in B0 (expected 32-64).

**4.1.2 Flat-form geometry**, defined once in `Heap.hpp` next to the String structs:

```cpp
// Strings of at least this many units in a flat form carry a hash slot after their payload.
constexpr u32 kStringHashSlotMinUnits = /* B0 */;
// The payload size of a flat String rounded up to 8, i.e. the offset of its tail word.
inline constexpr size_t flatStringTailOffset(u32 n, size_t unit) { return (sizeof(Header) + n * unit + 7) & ~size_t(7); }
inline constexpr size_t flatStringByteSize(u32 n, size_t unit) {
    return flatStringTailOffset(n, unit) + (n >= kStringHashSlotMinUnits ? 8 : 0);
}
// Returns the String's hash slot, or null if its form has none. `s` must be a String object.
u32* stringHashSlot(void* s);
```

The slot is the first 4 bytes of the tail word, and the other 4 bytes are 0. Every size
computation for the two flat tags goes through `flatStringByteSize`: `getObjectSizeFromHeader`
(AllocatorCommon.hpp:472, :546), `allocString`/`allocStringBlank` (HeapHelpers.hpp:402-474), the
UTF-8 leaf builders (StringOps.cpp:155, :188), `concat`/`join` (StringOps.cpp ~:543, ~:643), and
the large-object threshold decisions next to them (`total_size >= getLargeObjectThreshold()`
compares the size **including** the tail word). Codegen has its own copy of the layout in
`runtime/src/codegen/Passes/EcoToLLVMInternal.h` `namespace layout` (:436). Add
`layout::kStringHashSlotMinUnits` and `layout::utf16StringByteSize(n)` there, used by
`computeAllocSize` (EcoToLLVMHeap.cpp:174) and `getFixedAllocSizeForGrouping`
(EcoGCPrepare.cpp:107). A unit test asserts that the two copies agree for n = 1..4 T.

**4.1.3 Every allocation writes the slot as 0** (fresh payload is not zeroed), through one helper
`initStringHashSlot(void* s)`, called right after the header is written. Find the sites with
`grep -rn "Tag_String\b\|Tag_StringUtf8Leaf\|Tag_StringSlice\|Tag_StringRope\|Tag_StringUtf8View\|Tag_LargeStringHeader" runtime/src elm-kernel-cpp/src eco-kernel-cpp/src system-kernel-cpp/src --include=*.cpp --include=*.hpp`.
The list verified on 2026-11-24 (and in plans/seq-data-structures-performance.md D5 step 3):
- HeapHelpers.hpp `allocString` (:402), `allocStringBlank` (:449), `makeSlice` (~:2247);
- StringOps.cpp `makeSlice` (:29), `makeRope` (:80), `makeUtf8View` (:114), `makeUtf8LeafFromBytes`
  (:155), `allocAsciiOut` (:188), `concat` (~:552), `join` (~:654);
- RuntimeExports.cpp `eco_alloc_string` (:641), `eco_alloc_string_literal` (:792), `..._utf8` (:805,
  both branches), `eco_alloc_string_fast`/`_slow` (:1745, :1759), `eco_init_string_at` (:2054);
- ThreadLocalHeap.cpp `initHeaderForTag` (:117-126; it derives the length from the byte size, so
  invert `flatStringByteSize` correctly there);
- `Allocator::allocLargeString` (the large header);
- elm-kernel-cpp BytesExports.cpp (:670). (The grep also lists `case Tag_String:` readers in
  Utils.cpp and ParserExports.cpp; those are not allocations.)
Any site the grep shows that is not on this list gets the helper too. Add the new site to this list
in the progress log.

**4.1.4 Present or absent.** 0 means "not computed". Under v3, `stringHash` is never 0. Under v4
the slot holds the raw CRC, and a String whose raw CRC is 0 is simply never cached (one in 2^32).
No header bit is used, because a bit written after publication would race with the colour stores
(§1.2).

**4.1.5 When the slot is filled.** Five policies. 1-2 are built (B2, B3); 3-5 need v4 (§4.2) except
3, which works with any definition. Each is built and measured on its own (§4.3).

1. **On demand (B2, the core).** In ValueHash.cpp, `Hasher::string(void* s, bool top)` (:334)
   becomes:
   ```cpp
   u32* slot = stringHashSlot(s);
   u32 sh = slot ? __atomic_load_n(slot, __ATOMIC_RELAXED) : 0;
   if (sh == 0) {
       sh = stringHash(s, n);
       if (slot) __atomic_store_n(slot, sh, __ATOMIC_RELAXED);
   }
   mix(kString); mix(sh);
   ```
   `eco_hash_string`, `eco_hash_mix_string`, `eco_hash_walk` and `eco_hash_value` all reach it. The
   census (`census::note`) stays before the slot check and counts a hit separately
   (`census::noteHit`), so `ECO_HASH_CENSUS=1` shows the hit rate. Under v4 the slot holds the raw
   CRC and the walker mixes `nonZero(fmix32(raw ^ n))`. **A rope is hashed by composition (B5c):**
   its raw is `combine(raw(left), raw(right), |right|)`, each child's raw taken from its slot or
   computed the same way and **stored in the child's slot**, so that ropes sharing a child compose
   without reading it again. The walk uses an explicit stack (a rope's height saturates at 63 in
   `unboxed`, so its real depth is unbounded). Slices and views are hashed from their units: there
   is no algebra that gives a substring's CRC from its base's.
2. **Literals (B3).** In `eco_alloc_string_literal[_utf8]`'s lambdas (RuntimeExports.cpp:792, :805),
   for a String ≥ T, store the hash (v4: the raw CRC) into the slot before returning (before
   publication).
3. **Propagation (B5b).** Where the runtime copies a String's units unchanged into a new object (a new
   form of the same String), the new object's slot takes the source's slot value: same units, same
   hash, no unit read. Sites: `flattenToLeaf` (StringOps.cpp:215, also reached from `ensureFlat`),
   `healAsciiResult` (:487), `append`'s all-ASCII re-encode of a UTF-16 copy (StringOps.hpp:526-534;
   its source is a fresh copy, so this applies only when the copy's raw was composed, policy 4), and
   any other site the grep `toStdU16String\|forEachSegment` shows copying one whole String into a new
   one. The GC copies already keep the slot (§4.1.6).
4. **Composition at build (B5c).** A String built from parts p₁…p_k (in order) gets
   `raw = combine(…combine(raw(p₁), raw(p₂), |p₂|)…, raw(p_k), |p_k|)` written into its slot before
   publication. A part's raw is **known** when the part is Empty (raw 0xFFFFFFFF, the identity), has a
   filled slot, or has fewer than T units (no slot: its raw is computed from its ≤ T−1 units, at most
   a few ns). A part of T or more units with an empty slot is **unknown**. Rules:
   - **Copy paths** (the result is a flat copy, length ≤ `string_flatten_limit`, 128 Ki units by
     default, so almost every `++`): the build reads every part anyway. Unknown parts and short parts
     are hashed from their own units in the same call (the data is in cache), and an unknown part's
     raw is **stored into that part's slot** (a content-determined write after publication, covered
     by HEAP_088's carve-out exactly as policy 1), so the next build from the same part composes
     without reading it. Two settings (`StringOps::BuildHashConfig`), set by B5c's measurements to
     `shortBudget` = 32 and `hashUnknown` = true:
     `shortBudget` (the most units of short parts hashed directly per build; above it the
     result's slot stays 0, which bounds the cost of `join` over many short Strings, where composing
     costs as much as hashing the whole result) and `hashUnknown` (whether unknown long
     parts are hashed and stored, or the result's slot is left 0).
   - **Decided before any part is hashed** (`ComposeCheck`, added in B5c, §7): compose only when at
     least one part is long or already hashed, every long part's raw state is known or may be
     computed, and the short parts fit the budget, stopping at the first part over it. Without it, a
     `String.concat` of many short fragments composed part of the way and gave up (+11-38 %), and an
     `append` hashed its long side before failing on the short one, every time (+29 %).
   - **Rope paths** (`makeRope` from `append` above the limit, `buildBalancedRope` in `concat`/`join`,
     the rope `slice` makes when a range spans both children): combine only when both children are
     known; never read a long child at build time (a rope exists so as not to read it).
   - Separators: `join` computes the separator's raw once per call.
   - `String.repeat` is Elm code that doubles with `++`, so it composes through `append`.
5. **Hash at build for per-unit builders (B6; measured and removed, §7: no site's Strings are hashed
   later).** Builders that produce a String one unit at a time
   (`fromList`, `map`, `filter`, `toUpper`/`toLower`, `reverse`, UTF-8 decoding: Bytes `read_string`,
   JSON string decoding, and the eco/system and eco-kernel text reads that the grep
   `allocString\|allocStringBlank\|allocAsciiOut\|makeUtf8LeafFromBytes\|tryMakeAsciiString` lists)
   could hash the finished buffer while it is in cache. That pays only if enough of those Strings are
   hashed later: with c_b the cost of hashing at build (cache-warm) and c_d the cost on demand
   (usually cache-cold, so larger), a site pays when the fraction p of its Strings hashed later
   exceeds c_b / c_d. B6 measures p per site (census) and c_b, c_d (microbenchmark), and keeps only
   the sites where p > c_b / c_d. Expected: few or none.

Where each build site lands:

| site | builds | hash of the result |
|---|---|---|
| `append` copy (StringOps.hpp:489, both UTF-8 and UTF-16 paths) | flat copy of a ++ b | compose (policy 4, copy rules) |
| `append` rope (above 128 Ki units) | `makeRope(a, b)` | compose if both known |
| `concat`, `join` copy paths (StringOps.cpp:505, :588) | flat copy of the parts | compose, fold over the parts (and separators) |
| `concat`, `join` rope paths, `buildBalancedRope` (:439) | balanced ropes | each `makeRope` composes if both known |
| `slice` of a rope spanning both children (:417-425) | rope of two new slices | the pieces are new slices (unknown): slot 0 |
| `slice`, `makeSlice`, `makeUtf8View`, `tinyFromFlat` | substrings | on demand only |
| `flattenToLeaf`, `ensureFlat`, `healAsciiResult`, the all-ASCII re-encode | the same units in a new form | copy the source's slot (policy 3) |
| literals ≥ T | | filled at intern (policy 2) |
| `cons` (StringOps `cons`) | c ++ s | compose: the char is a short part |
| per-unit builders (policy 5) | a new buffer | B6: only sites measured to pay |
| GC copies | | keep the slot (§4.1.6) |

**4.1.6 Concurrency and the collectors.** Policy 1 writes the slot of an object that may have
survived a collection. Keys built in bulk are hashed after surviving: in the D4 census only 2,642 of
120,000 first hashes happened at nursery age 0. That breaks P1 (HEAP_SNAPSHOT_001) and HEAP_036
(PermanentSpace immutable). The carve-out, as argued here and checked in B2:

- **Content-determined, write-once.** The slot goes once from 0 to a value that depends only on the
  String's units. Every writer writes the same value. Under v4 the writers are policy 1 (on demand,
  including a rope's children), policy 4 (a build storing an unknown part's raw into that part) and
  the GC copies; policies 2-5 write the new String's own slot before publication, which needs no
  carve-out. Reads and writes are relaxed 32-bit atomics,
  so they cannot tear. A lost write only costs a recomputation.
- **Minor and major STW copies** (NurserySpace, NurseryParallel, NurseryRegion, OldGenSpace
  compaction, which only unit tests start) run with the mutator stopped. They copy the slot
  verbatim, so a cache survives a copy.
- **The concurrent tenure engines** (NurseryTenure.cpp `copy` at :111-114, the exact engine, which
  may run on collector member 0 while the mutator runs; and :1093, the concurrent parallel engine)
  may copy an object while the mutator writes its slot. The copy may miss the write (the new copy
  keeps 0). The mutator's writes to the original are harmless: originals are reclaimed only after
  `tenureJoin`/merge, in a pause, and the merge heals the mutator's references to the new copies.
  To make this race-free in C++ terms (the heap TSan build), both sites call
  `copyObjectForTenure(dst, src, size)`. That function does the `memcpy`, except that for a String
  tag with a slot it copies the bytes before and after the slot with `memcpy` and the slot itself
  with `__atomic_load_n(src_slot, RELAXED)` followed by a plain store into `dst`.
- **Markers and sweepers** never read a String's slot: marking a slice, view or rope reads only its
  `base`/`left`/`right`, and flat Strings hold no pointers. The rope height in `unboxed` is written
  only before publication.
- **PermanentSpace** has one writer thread (the mutator) and readers that only read. HEAP_036 is
  amended: "contents are immutable except String hash slots (HEAP_0xx)".
- **TLA+.** Read `test/tla/README.md`. M5-tenuring (`test/tla/M5-tenuring/`, Tenuring.tla and
  MAPPING.md) is the model of concurrent tenure copying. Check in its MAPPING.md whether payload
  (non-pointer) words are modelled at all. If not, the slot write is outside the model's
  abstraction: add a dated AUDIT.md entry saying so, with the argument above, and change nothing.
  If `copyObjectForTenure` or `Hasher::string` touches a file the canary pins, the canary
  (`tla-canary`) fires. Investigate the models it names, write the AUDIT.md entries, and only then
  re-pin as its README says. Never repair the hash alone.
- **Validate builds** (`ECO_HEAP_VALIDATE`, and `ECO_P1_CENSUS`):
  - Detector O (P1Census.cpp: hashes sampled promoted objects and re-hashes them later) and
    detector N (NurserySpace's survivor hash) both skip the 4 slot bytes. Add one helper
    `p1::maskedBytes(obj, size, fn)` that yields the object's bytes with the slot range of a
    String tag zeroed, and use it in both.
  - The pre-evacuation walks (NurserySpace.cpp's validate walk, ~:2019-2060, and NurseryRegion's
    eden pre-walk, ~:778) check every String with a slot: the slot is 0 or equals `stringHash`
    recomputed, and the tail word's high 4 bytes are 0. This is the safety net for a forgotten
    allocation site (§0 item 9). Fresh nursery memory is not cleared (allocation sites must write
    every word), so a forgotten slot holds leftover bytes. With `ECO_NURSERY_POISON=1` (validate
    builds only; NurserySpace.cpp:1982, NurseryRegion.cpp:1169) free nursery memory is filled with
    0xD8, so a forgotten slot reads 0xD8D8D8D8 and this check fails deterministically. Run the B1
    and B2 validate checks with it set.
- **Invariants and docs.** Add a new `HEAP_0xx` row in `design_docs/invariants.csv` (take the next
  free number): the slot, the forms that have one, T, 0 = absent, write-once relaxed atomic,
  content-determined; GC copies preserve it except a concurrent tenure copy may drop it; validate
  checks. Amend HEAP_SNAPSHOT_001 and HEAP_036 with the exception, and the `[Pure]` notes on the
  String ops in Ops.td (:1274-1278 and :3067-3080): the cache write is invisible to Elm. Update
  value-hash.md (a "Cached String hashes" section).

**4.1.7 Equality (B4).** In `StringOps::equal` (StringOps.hpp:1623), after the length check, load
both slots (relaxed). If both are non-zero and differ, return false. `equal` never computes a hash.
This is valid because the slot is a function of the units, and every form gives the same number
for the same units.

### 4.2 Hash definition for Part B: v4 = CRC32C, computed as crc32c-fold128

- Policies 1-3 and 5 work with any definition; composition (policy 4, and a rope hashed from its
  children under policy 1) needs v4. v3 stays until B5a.
- **Decision** (user, 2026-11-24), on the evidence of the String hash lab
  (design_docs/string-hash-algorithm.md, code `experiments/string-hash-lab/`).
- **Definition v4:**
  - `raw(s)` = the CRC32C register (Castagnoli, reflected polynomial 0x82F63B78) after the String's
    UTF-16 units as little-endian byte pairs, starting from 0xFFFFFFFF, without the final
    inversion. A UTF-8 form's bytes are its units. `raw("")` = 0xFFFFFFFF.
  - `stringHash(s)` = `nonZero(fmix32(raw ^ n))`, n the length in units; the walker mixes it as
    before (`mix(kString); mix(stringHash)`).
  - The slot holds `raw`. 0 means "not computed", so a String whose raw is 0 is never cached (one in
    2^32).
  - `combine(ra, rb, nb)` = `(ra ^ 0xFFFFFFFF) · x^(16·nb) ^ rb` mod P. Multiplication is one
    carry-less multiply reduced by the `crc32` instruction: `M(a, b)` = `crc32(0, clmul(a, b))` =
    a·b·x³³, with a table `hatPow[k]` = x^(2^k − 33); popcount(16·nb) + 1 multiplies, 3.4-4.3 ns.
- **Implementation:** port the lab's `crc` namespace (`raw3b` and its stride tiers, `fold128Core`,
  `fold128Raw`, `M`, `shiftBits`, `combine`, and `init`'s constants, baked into `constexpr` tables)
  into new `runtime/src/allocator/Crc32c.{hpp,cpp}`:
  - a contiguous UTF-16 run: 16-byte folding from 64 units, the 3-stream `crc32` path below;
  - a UTF-8 run: the same with each 8 bytes widened to 16 (`pmovzxbw`). The lab did not build this
    path; B5a does and measures it;
  - an update form, `crc32cUpdate(state, run)`, so that a String of several segments
    (`forEachSegmentEx`) continues one register across them; a rope composes its children instead
    (policy 1).
- **CPU support:** x86-64-v3 (eco's floor) has the SSE4.2 `crc32` instruction; 16-byte PCLMULQDQ is on
  every x86-64-v3 CPU in practice but not in the level's definition. Either
  design_docs/compatability.md says so, or a start-up check falls back to the 3-stream `crc32` path
  (SSE4.2 only), with combine on a software carry-less multiply. AArch64 (`mac-build`, apple-m1):
  `__crc32cd` and `vmull_p64` (PMULL), the same values. A table-driven software CRC is the test
  reference and the fallback for any other target. Faster variants (32-byte VPCLMULQDQ, 512-bit
  AVX-512 folding) give the same values and may be selected at start-up later (the static musl build
  has no IFUNC: a function pointer set at start-up).
- **Speed** (lab, x86-64-v3 build): 6.9 ns at 1 unit (v3 11.5), 12.3 at 33 (v3 16.4), 133 at 2,016
  (v3 110), 4,020 at 65,536 (v3 3,440). On Skylake-class CPUs long Strings may lose by 1.3-1.6×
  (estimate: slower PCLMULQDQ). With AVX-512 folding: 45.8 ns at 2,016 units. The old acceptance
  rule (v4 at least as fast as v3 at every length) is replaced by the user's decision; B5a reports
  the long-String cost on the suite.
- **Quality** (lab §4): equal to v3 on collisions over structured key sets, avalanche, every-window
  distribution and sparse differentials; 0 collisions where keys differ within 32 bits (better than
  random). It is linear over GF(2) with a fixed polynomial: equal-length Strings whose XOR is a
  multiple of P (for example P·x^s) collide by construction, and no key can remove that. v3 has its
  own constructible family (lab §5.2), which v4 retires for Strings.
- The JS backend keeps its own hash.

### 4.3 Steps

- **B0. Decide v4 and T** (C++ only, under `local-dev/hashreuse/`). Extend `compose/c.cpp` and
  `hv3/quality.cpp` (or rewrite them: a timing loop over Strings of the listed lengths, and a
  quality program that counts equal-hash pairs and runs chi² on each 5-bit group of the finalised
  hash over the key sets of §4.2). For T, measure per String the cost of a slot check plus a hit,
  and of a check, a miss and a fill, against v3 by length (1-128 units). T is the smallest length
  where a hit saves more than the check costs on a miss. Record both decisions in §7.
- **B1. Layout only; every slot stays 0.** §4.1.1-4.1.3: the structs, the geometry helpers, the
  codegen layout copy, every allocation site, `getObjectSizeFromHeader`, the rope height move, the
  view `byteLen` reuse and the large header. Tests:
  - Update the hard-coded String sizes: `test/allocator/HeapGenerators.cpp` (:200, :409),
    `AllocatorCommonTest.cpp` (:159-188, :644), `AllocatorTest.cpp` (:849-863) and
    `StringFormsCompareTest.cpp` (:350), plus anything else that fails on sizes.
  - New `test/allocator/StringHashSlotTest.cpp` (registered like its neighbours): for every
    allocation route of §4.1.3, at lengths T-1, T, T+1, 4T and just below and above the large
    threshold, check that the object size equals `flatStringByteSize`/the struct size, that the
    slot exists exactly when the table says, and that it is 0. Also check that the codegen and
    runtime layout copies agree.
  - Run `./build/test/test --filter String`, `--filter Allocator`, the E2E String tests
    (`--filter elm` subset with String in the name) and the eco-system Hash and SeqDict sets.
  - Measure the suite and memory: the cost of the space alone. **USER** checkpoint commit.
- **B2. On-demand fill and the carve-out** (§4.1.5.1, §4.1.6): `Hasher::string`, `stringHashSlot`,
  `copyObjectForTenure`, the P1 masking, the validator checks, the TLA review, the invariant rows.
  Tests:
  - In StringHashSlotTest: after `eco_hash_string` the slot equals `stringHash`, for every form. A
    second hash returns the same number. The slot survives a forced minor GC (`requestMinor`, as
    the GC-safety repro tests do) and a major GC. A PermanentSpace literal ≥ T fills. A nested
    String in a tuple fills through `eco_hash_value`.
  - A new GC-pressure E2E test (`test/eco-system/src/SeqDictAgedKeysTest.elm`, with
    `-- ENV: ECO_SEQDICT_VALIDATE=1`, and run once by hand under
    `ECO_HEAP_CONFIG=/work/benchmarks/heap-config-gc-pressure.json`): build 20,000 keys of 300
    units, force them to age (allocate garbage between rounds), and look each up 4 times in a
    SeqDict and a SeqSet while tenure jobs run. Every lookup must hit, and `==` of the dicts must
    pass the validator.
  - Negative controls (by hand, recorded in §7, not committed): (a) fill with `sh + 1`; the
    validate pre-evacuation check must abort. (b) Skip `initStringHashSlot` at one route; the
    validate build with `ECO_NURSERY_POISON=1` must abort on 0xD8D8D8D8. (c) A reader that ignores the slot; seqdict-prefixkey
    must show no gain (proves the measurement sees the cache).
  - Run the heap TSan build's tenure tests once (`test/gc-heap-tsan`, as its README says) with a
    String-hashing mutator, to show `copyObjectForTenure` is race-free.
  - Measure. **USER** checkpoint commit.
- **B3. Literals ≥ T hashed at intern** (§4.1.5.2). Measure. Expected: flat (most literals are
  short); keep it only if not slower.
- **B4. Equality fast-reject** (§4.1.7). Unit tests: equal Strings in different forms with filled
  slots compare equal; different Strings with filled slots compare unequal without reading units
  (check with a String whose units were altered in a test-only copy: the fast path must answer
  before memcmp). Measure string-eq-prefix and the String compare workloads.
- **B5a. v4** (§4.2). `Crc32c.{hpp,cpp}`, with a unit test against the table-driven reference on
  lengths 0-1,100 and some large ones, unit offsets 0-7, UTF-16 and UTF-8 runs and multi-segment
  Strings, and on composition (pairs with empty sides and every block boundary; many-piece joins left
  to right, right to left and as a tree, as the lab's `test` mode). Switch `stringHash`,
  `Elm::stringHashUncached`, `Elm::checkStringHashSlot` (compares the slot with the raw CRC),
  `fillLiteralHashSlot` and `Hasher::string` (slot raw, then finish).
  - Pins: recompute HashIdentityTest/-GenericTest with an independent Python reference (bitwise
    CRC32C, `fmix32`, the walker's FNV mix), as v3 did (plans/seq-data-structures-performance.md log,
    2026-11-24 v3).
  - Colliding keys: constructed, not searched. For a key k, k ⊕ P·x^s and k ⊕ P·x^t (two shifts,
    chosen so every changed unit stays a non-surrogate BMP unit) have k's raw CRC and length, so the
    three collide fully. They replace `c600662`/`c5330492`/`c11005860` in SeqDictCollisionTest and
    SeqDictMapTest.
  - Docs: value-hash.md "Definition v4"; the HEAP_088 row (the slot holds the raw CRC32C);
    compatability.md (PCLMULQDQ, or the fallback).
  - If a file the kernel license manifest or the TLA canary pins changes, follow Part B's procedure
    (§7, B2 paperwork).
  - Measure the suite and the String microbenchmarks: the definition's own cost, before any
    composition. **USER** checkpoint commit.
- **B5b. Propagation** (policy 3). Tests: at each site, a source with a filled slot gives a result
  with the same slot, and the validate pre-walk agrees. Measure (expected flat).
- **B5c. Composition** (policy 4, and policy 1's rope walk).
  - Census first: extend `ECO_HASH_CENSUS` with per-site build counters (results of T+ units, parts
    known / short / unknown, units hashed at build) and a census-only table of results that are
    hashed before the next minor GC (as the existing repeat table). Run it on the suite and the
    compiler self-build; record it in §7.
  - Build the rules with the two settings; measure `hashUnknown` off and on, and
    `shortBudget` at 0, T and 4T: the gain on seqdict-prefixkey-fresh and a new
    seqdict-built-keys (keys `prefix ++ middle ++ code`, where `prefix` and `middle` are long Strings
    also used as keys, looked up in 4 rounds); the cost on string-concat, string-join, csv-split,
    the String compare workloads and the self-build. Keep the variant that passes §5 rule (1) with the
    best gain, and record the trade-off for the user.
  - Tests: for every build site of the table in §4.1.5, every pair of forms and lengths around T,
    empty sides, separators, and both sides of the 128 Ki limit (copy and rope paths), the result's
    slot equals the directly computed raw. A rope hashed on demand fills its children's slots. The
    validate pre-walk (`checkStringHashSlot`) covers it all under `ECO_NURSERY_POISON=1`. Negative
    control (by hand, recorded in §7): a wrong shift in `combine` makes the validate check abort.
  - **USER** checkpoint commit.
- **B6. Hash at build for per-unit builders** (policy 5). Per site: the census fraction p of its
  Strings hashed later, and microbenchmarks of c_b and c_d. Keep only sites with p > c_b / c_d, each
  with a test that its slot equals the raw CRC; remove the rest.
- **B7. Validate gate** (`build-validate` tree, `cmake --build build-validate` in full first, then
  unit + E2E + pressure stress, as in /tmp/seqwork/final.sh's validate lines, `ulimit -c 0`).
  Run it once at the end of Part B: memory "ECO_HEAP_VALIDATE ONCE AT PLAN END".
- **B8. Optional: serve `Eco.Hash.string64` from the slot**, so that the compiler's
  `Data.HashMap` benefits and the self-build can show a gain. `string64 seed s` becomes
  `mix64(seed, stringHash(s))` natively. That changes bucket numbers only: `Data.HashMap` iterates
  in insertion order, so compiler output cannot change (verify: bootstrap fixed point byte-equal).
  JS keeps its own definition (agreement was a nicety, Eco/Hash.elm:23-26). Only Strings ≥ T gain,
  and most compiler Strings are short. Do it only if B2-B5c are kept, and measure the self-build.

Exit: targeted tests and the validate gate green; full gate before the final **USER** commit.

## 5. Comparison and choice

One table, each branch against `local-dev/hashreuse-base-bench.json`:

| measure | base | `hash-explicit` | `hash-cache` |
|---|---|---|---|
| seqdict-prefixkey / seqset-prefixkey-rounds / seqdict-longkey-reuse | | `-hashed` variants | plain |
| seqdict-intern (control: expected flat on both) | | `-hashed` | plain |
| seqdict-shortkey-reuse, seqdict-string (overhead) | | | |
| string-eq-prefix | | plain | plain |
| seqdict-prefixkey-fresh, seqdict-built-keys (composition) | | plain | plain |
| string-concat, string-join, csv-split (cost of v4 and composition) | | | |
| whole suite, workloads moving > 5 % (A/B-confirmed) | | | |
| compiler cold self-build wall / peak RSS | | | |
| String allocation (`dev` build: bytes_allocated, histogram) | | | |
| lines changed, invariants added, P1 carve-out | | none | yes |

Choose by, in order: (1) no confirmed regression above 3 % on the suite or the self-build; (2) the
gain on the reuse workloads; (3) cost and risk (a P1 carve-out and a heap layout change, against
an API). Part A's gain needs a program to opt in and Part B's does not, so if both pass (1), the
choice between them is the user's: the table states both gains and both costs side by side.

## 6. Not in this plan

- Caching hashes of tuples, records, customs or lists (§1.2: an extra word per object).
- Changing elm/core `Dict` (comparison-based; a hash cannot order).
- (Merging repeated hashes within one function is done: plans/seqdict-hash-once-per-function.md.)

## 7. Progress log

- **2026-11-24 Reviewed and lowered** (§0). Plan otherwise not started; base not yet committed.
- **2026-11-24 Part A implemented** (user request; in the working tree, no branch: the user manages
  branches). `Hash.elm`: `Hashed`, `hashed`, `value`, `hashOf`. `SeqDict.elm`: `getHashed`,
  `memberHashed`, `insertHashed`, `removeHashed`, `updateHashed`, `updateIfExistsHashed` (copies
  of the plain bodies; plain functions unchanged). `SeqSet.elm`: `memberHashed`, `insertHashed`,
  `removeHashed`. `InlineSimplify.defaultWhitelist`: the seven twins of the whitelisted wrappers.
  `system-kernel-cpp/docs.json` regenerated (`eco-system-docs`, stock elm type-checks the package).
  Benchmarks: SeqLargeKeys.elm `benchPrefixKeyHashed`, `benchLongKeyReuseHashed`,
  `benchInternHashed`, `benchSetPrefixRounds` (15,000 keys; 5,000 ran in 12 ms) and
  `benchSetPrefixRoundsHashed`, registered in Bench.elm; README paragraph.
  - **Tests.** New `test/eco-system/src/SeqDictHashedTest.elm`: native 1/1, with all 14
    eco-system Seq* and 4 Hash* tests green; JS (`run-js-e2e`, filter SeqDict,SeqSet,Hash) 16 pass,
    2 skipped (HashIdentity*: JS numbers differ, by design); compiler `elm-test-rs --filter
    whitelist` 7/7. Caches wiped first (`build/test/*/eco-stuff`, `~/.eco/0.2.0` package `.dat`
    artifacts; the `eco/kernel` and `eco/system` package copies moved to the session scratchpad).
  - **Negative control** (`hashed` stores `hash v + 1`, by hand, reverted, file diffed against a
    copy): the first version of the test failed only on its `hash:` line. `P == H` and twin-vs-twin
    lookups passed, because `ECO_SEQDICT_VALIDATE`'s T1 checks an entry against its *stored* hash,
    not against `FNV.hash key` (A3 text corrected). Cross lookups added (plain lookups of the
    twin-built dict, twin lookups of the plain-built dict); with them every line fails under the
    control, and the real code passes.
  - **Benchmarks**, whole suite, warmup 1 / runs 5 like the reference
    (`local-dev/hashreuse/post-part-a-bench.json` against `local-dev/post-hash-inline-bench.json`;
    `local-dev/hashreuse/compare.py`). All 113 ok. Native ms (JS ms):

    | workload | reference | plain now | `-hashed` | hashed vs plain |
    |---|--:|--:|--:|--:|
    | seqdict-prefixkey | 135 (556) | 135 (559) | 56 (197) | −58.5 % (−64.8 %) |
    | seqset-prefixkey-rounds | – | 184 (745) | 48 (192) | −73.9 % (−74.2 %) |
    | seqdict-longkey-reuse | 294 (823) | 289 (822) | 265 (761) | −8.3 % (−7.4 %) |
    | seqdict-intern (control) | 315 (1,302) | 315 (1,320) | 320 (1,227) | +1.6 % (−7.0 %) |

    Peak RSS unchanged (prefixkey 610 → 611 MiB, longkey-reuse 377 → 384). Suite geometric mean
    vs the reference: native 1.002, JS 1.000 (non-Seq/String workloads 1.002 both). The gains are
    far above §1.1's estimate (−27 % ceiling on seqdict-prefixkey). Likely reason (not profiled):
    the estimate used cache-hot hash cost (255 ns per 2,000 units), but the 40,000 keys (~80 MB)
    are read from DRAM at every plain lookup; with a `Hashed` key a hit compares the key with
    itself (same object), so a lookup reads no key bytes at all.
  - **A/B confirmation** of native moves > 5 % (`ab-interleave.sh`, 5 alternations of
    `bench-base`, built from a scratch copy of the sources with Part A removed, and
    `bench-parta`; `local-dev/hashreuse/ab-results.txt`): seqdict-update +3.3 %, seqdict-custom
    −2.1 %, seqdict-tuple +1.3 %, string-eq-prefix 0, set-float-pairs −1.6 %, seqdict-string 0,
    plain seqdict-prefixkey −1.5 %, seqdict-longkey-reuse −1.0 %, seqdict-intern −0.9 %: noise.
    **fib +16.0 % and dict-char-pairs +6.9 % are stable but are layout:** `Fib_fib`'s machine
    code is instruction-identical in both binaries, and only its address moved (offset 32 → 0
    within a 64-byte line). dict-char-pairs (elm/core `Dict`, untouched code) is presumed the
    same (not disassembled). Part A changes no plain workload's code.
  - **Not done:** full gate (owed before the USER commit); compiler self-build (Part A cannot
    change it: the compiler uses no SeqDict); A0 profile; A5 docs; the ecosyskernel stubs (USER).
- **2026-11-24 Part B implemented** (branch `hash-cache`, user request; base = the user's branch point,
  with step M's seqset-prefixkey-rounds restored from local-dev/hashreuse/stepM and the Part A log above
  restored from local-dev/hashreuse/plan-after-part-a.md).
  - **B0 decisions.** T = 32 (`kStringHashSlotMinUnits`): `local-dev/hashreuse/b0/t.cpp` (v3 as in
    ValueHash.cpp, UTF-8 leaf path) gives hash 10-31 ns at 8-190 units, a slot hit 0.5 ns, a first hash
    plus fill +0.2-0.3 ns over a plain hash. Every length pays on CPU, so T is a memory choice: below
    32 units the +8 bytes would be +20-33 % of the object. **v4 / composition (B5) not built:** it
    pays only when both sides of a `++` were already hashed, which no suite workload does
    (seqdict-prefixkey-fresh concatenates a never-hashed prefix), against a hash-definition change
    (new pins, new colliding keys, a linear hash's quality risk). B6 (eager hashing) not built.
  - **B1 layout.** Heap.hpp: `hashSlot` replaces slice `_padding`, view `byteLen` (its one reader uses
    `header.size`) and rope `height` (now `header.unboxed`, saturated at `kRopeHeightMax` = 63:
    nothing bounds a chain's height and nothing decides on it, §0 item 6); `LargeStringHeader` 16 ->
    24 bytes; flat Strings of 32+ units get a tail word (`flatStringByteSize`, `stringHashSlot`,
    `initStringHashSlot`, `loadStringHashSlot`). Sizes: AllocatorCommon `getObjectSizeFromHeader`,
    HeapHelpers `allocString`/`allocStringBlank`, StringOps (utf8 leaf builders, `concat`, `join`),
    RuntimeExports (`eco_alloc_string`, literals, `_fast`, `_slow`, `eco_init_string_at`), BytesExports
    `read_string`; codegen `layout::utf16StringByteSize` (EcoToLLVMInternal.h, static_assert-tied to
    Heap.hpp in EcoToLLVMHeap.cpp) for `computeAllocSize` and `getFixedAllocSizeForGrouping`. Zeroing:
    `initStringHashSlot` at every route, plus `initHeaderForTag` zeroes a flat String's last word as a
    catch-all (every runtime route except `_fast` and `eco_init_string_at` passes through it). No
    kernel shrinks a String in place (checked).
  - **B2 fill.** `Hasher::string` (ValueHash.cpp) reads/fills the slot with relaxed atomics (census
    gains "served by hash slot"); `Elm::stringHashUncached`, `Elm::checkStringHashSlot` exported.
    `copyObjectForTenure` in both tenure engines (NurseryTenure.cpp). P1Census `hashObject` and
    `wordSignature` mask the slot (both detectors use them). Validate pre-walks (NurserySpace,
    NurseryRegion) call `checkStringHashSlot`. Invariants: new HEAP_088; HEAP_SNAPSHOT_001 and HEAP_036
    amended; Ops.td `[Pure]` notes; value-hash.md "Cached String hashes".
  - **B3** literals of 32+ units filled at intern (`fillLiteralHashSlot`). **B4** `StringOps::equal`
    returns False on two filled, different slots (only for 32+ units).
  - **Paperwork.** Kernel license: BytesExports.cpp pins 26 Elm.Bytes kernels; re-audit lines added
    (the change is inside `read_string`'s body only) and `check-kernel-license-manifest.sh --update`.
    TLA canary (NR.minorGCRegion, NT.TenureHeapEnv, NT.TenureParEnv): AUDIT.md entries in M1, M2, M3,
    M5, M7 and test/genmc (W5); verdict no model change (the slot is a non-pointer word outside every
    model's state); M5 MAPPING.md T1 row amended; manifest re-pinned.
  - **Tests.** New `test/allocator/StringHashSlotTest.cpp` (7 tests: every route zeroes the slot in a
    nursery dirtied with filled slots; fill/hit/forms/nested; minor and major GC keep it; literals;
    rope height saturates; checkStringHashSlot rejects a wrong slot; equal fast-reject; fill after
    survival). AllocatorCommonTest and HeapGenerators sizes updated. Whole `build/test/test` (unit +
    JIT E2E) **3,178/3,178** after a cache wipe. Validate tree (`build-validate`, built in full) with
    `ECO_NURSERY_POISON=1`: HEAP_088 7/7, HEAP_025 1/1, eco-system Seq* 13/13, Hash* 4/4. Negative
    controls (by hand, reverted, files diffed): no zeroing in `initHeaderForTag` and `allocString` ->
    the route test fails at `allocString n=32`; no P1 masking -> the validate census aborts
    ("VIOLATION (old gen, major-start) ... StringUtf8Leaf ... written after promotion").
  - **Workload trap found:** string-eq-hashed first measured no gain because its hash sum was used only
    in the final check, and the compiler evaluated that once-used `let` after the `==` loop (inferred:
    making the loop's start value depend on it fixed it, 135 -> 12 ms). Benchmarks that pre-hash must
    make the later work depend on the hashing.
  - **string-eq-hashed dropped** (user, 2026-11-24): it called `Hash.hash` on every key by hand so
    that `==` would find filled slots, which no program does for `==`'s sake (String `==` never
    hashes). The fair comparison across base, A and B is string-eq-prefix: interleaved 114 / 115 / 116 ms
    native (`ab3-results.txt`; the reference suite run's 142 was run-to-run noise), i.e. B4's check
    costs nothing measurable when the slots are empty. `==` computing hashes on demand was
    considered and rejected: hashing reads both Strings whole, where an unequal compare usually stops
    early, so it would only pay for the same long near-equal String objects compared repeatedly.
  - **Benchmarks**, whole suite, warmup 1 / runs 5 (`local-dev/hashreuse/post-part-b-bench.json`, all
    110 ok; `compare3.py`). Native ms (Part B is native only; its JS numbers move only by noise, up to
    ±30 % on ctor-wrapper):

    | workload | reference | plain (A run) | Part A `-hashed` | Part B plain |
    |---|--:|--:|--:|--:|
    | seqdict-prefixkey | 135 | 135 | 56 | 69 (−49 %) |
    | seqset-prefixkey-rounds | – | 184 | 48 | 65 (−65 %) |
    | seqdict-longkey-reuse | 294 | 289 | 265 | 267 (−8 %) |
    | seqdict-intern (control) | 315 | 315 | 320 | 326 (A/B +1.3 %) |
    | string-eq-prefix (B4) | 114 | 115 | – | 116 (interleaved) |

    Suite geometric mean B vs the A run: native 0.987 (non-Seq/String 1.002), peak RSS 1.000
    (seqset-prefixkey-rounds 267 -> 275 MiB, +3 %).
  - **A/B confirmation** against `bench-base` (pre-Part-B runtime), 5 alternations
    (`local-dev/hashreuse/ab-results-b.txt`): noise: sha256 +2.7, fasta +0.4, dict-int −7.9, nsieve
    +2.2, seqdict-collide 0, seqdict-string 0, seqdict-update −5.7, fib 0. Stable: levenshtein +14.2 %
    and decoded-snapshot +7.5 % are **layout** (`perf stat`: instructions +0.02 % / +0.14 %, IPC 4.86 ->
    4.25 on levenshtein, cache misses not up). **Real Part B costs**: seqdict-prefixkey-fresh +6.0 %
    (instructions +1.8 %, cache misses +10 %: each fresh 2,000-unit key is 8 bytes bigger and hashed once,
    and `==` on an equal key loads the cold stored key's slot before its memcmp), string-concat +4.5 %
    (misses +15 %), csv-split +2.9 % (instructions +1.9 %, misses +15 %): the slot word on every String of
    32+ units, its zeroing, and the slot loads in `equal`.
  - **A versus B** (for the user's choice, §5): Part A gains more where it is used (prefixkey 56 vs 69 ms,
    set rounds 48 vs 65: a `Hashed` key skips even the slot load, and needs no fill) and costs nothing
    elsewhere, but only programs that opt in gain. Part B gains −49/−65/−8 % with no program change,
    serves Strings nested in keys, and costs 3-6 % on
    String-building workloads, a heap-layout change and a P1 carve-out (HEAP_088). Both pass §5's rule
    (1) only if the 6 % on seqdict-prefixkey-fresh and 4.5 % on string-concat are accepted (the rule
    says 3 %). Not measured: compiler self-build (B's 8 bytes per 32+-unit String do apply there);
    String bytes allocated (`dev` build).
- **2026-11-24 plan amended (user): v4 = crc32c-fold128, composition and hash at build.** The String
  hash lab (`experiments/string-hash-lab/`, design_docs/string-hash-algorithm.md) compared v3 with
  CRC32C, a 64-bit Rabin fingerprint and polynomials mod 2^61−1 and 2^52−47, vectorised (PCLMULQDQ,
  VPCLMULQDQ, AVX2, AVX-512, IFMA), on speed, composition and quality (avalanche, every-window
  distribution, differentials). The user chose crc32c-fold128. §4.1.5 now has five policies (on
  demand with ropes composed, literals, propagation, composition at build, hash at build), §4.2 the v4
  definition, §4.3 steps B5a-B5c and B6. The lab also found that v3's tail costs ~6 ns at lengths not
  a multiple of 32 (a store-forwarding stall; a masked load fixes it with the same values) and that a
  16-unit block equal to v3's K erases all four lanes (a constructible collision family); v4 retires
  v3 for Strings.
- **2026-11-24 B5a-B5c implemented, B6 measured and removed** (branch `hash-cache`, ungated).
  - **B5a v4.** New `runtime/src/allocator/Crc32c.{hpp,cpp}`: the lab's crc32c-fold128 (16-byte
    PCLMULQDQ folding from 64 units, three `crc32` streams below; UTF-8 runs widened with `pmovzxbw`;
    `combine` by one carry-less multiply per set bit of 16·|b|) behind per-function
    `target("sse4.2,pclmul")` attributes and a CPUID check, so the `build` preset (no `-march`) is
    unaffected; a slicing-by-8 portable path gives the same numbers elsewhere. `ValueHash.cpp`:
    `stringHash` = `nonZero(fmix32(raw ^ n))`, the slot holds the raw CRC, `rawFill` composes a rope
    from its children and fills their slots; `stringRawUncached`/`stringRaw` exported;
    `checkStringHashSlot` compares with the raw CRC; `fillLiteralHashSlot` stores the raw CRC. Pins:
    `experiments/string-hash-lab/v4ref.py` (bit-by-bit CRC32C plus the walker's mixing) first
    reproduced every v3 pin, then gave the v4 ones (HashIdentityTest/-GenericTest strings, collide,
    values[0]). Colliding keys are constructed, not searched: `collisio`, `klsygdlo`, `fskwtmhm`
    (one raw CRC, found by solving the CRC's linear system over the low 5 bits of each letter), in
    HashIdentity*, SeqDictCollisionTest, SeqDictMapTest and SeqDictHashOnceTest. Docs: value-hash.md
    "Definition v4" and the cache section; HEAP_088; compatability.md (the CPUID check adds no
    requirement). Kernel license manifest and TLA canary: no pinned file touched, both pass.
  - **v4 alone** (`post-v4-only-bench.json`, composition and propagation off): suite geomean 0.999
    against Part B (v3); seqdict-prefixkey-fresh 155 -> 120 ms and seqdict-prefixkey 71 -> 64 (UTF-8
    leaf keys: v3 widened bytes four at a time in scalar code, the CRC path eight per `pmovzxbw`).
  - **B5b propagation:** `flattenToLeaf` copies the source's slot; `healAsciiResult` carries the
    composed raw state to its re-encoded result.
  - **B5c composition:** `append` (both copy paths), `concat`, `join` (separator once), `cons` and
    `makeRope` (so every rope path) give the result `combine` of its parts' raw states before
    publication (`giveBuiltHash`); a long part with an empty slot is hashed during the build and its
    own slot filled (`partRaw`). Two traps found by measurement and fixed with a decision taken before
    any part is hashed (`ComposeCheck`: at least one long or hashed part, every long part known or
    storable, short parts within `kStringHashSlotMinUnits` units, stopping at the first part over
    budget): (1) a `String.concat` of many short fragments composed part of the way and gave up,
    costing seqdict-longkey/-reuse and dict-longkey +11 % at budget 32 and +38 % at 128; (2) with
    budget 0, `append` hashed the long side, failed on the short one, and the next append hashed the
    whole accumulator again (string-append +29 %). The env switches used to measure
    (`ECO_STRING_COMPOSE`, `_BUDGET`, `_PROPAGATE`, `_HASH_AT_BUILD`) were removed afterwards; the
    defaults are constants in `StringOps::BuildHashConfig`. Settings, interleaved on one binary
    (`local-dev/hashreuse/ab-env-results-c.txt`, ms, change against v4 alone):

    | workload | v4 alone | known parts, 32 | store, 0 | **store, 32** | store, 128 |
    |---|--:|--:|--:|--:|--:|
    | seqdict-prefixkey | 63 | +1.6 % | +1.6 % | **−22.2 %** | −20.6 % |
    | seqdict-prefixkey-fresh | 120 | −2.5 % | −0.8 % | **−20.8 %** | −13.3 % |
    | seqdict-built-keys (new) | 89 | −24.7 % | −21.3 % | **−19.1 %** | −13.5 % |
    | string-eq-prefix | 116 | −2.6 % | −1.7 % | **−91.4 %** | −91.4 % |
    | seqdict-longkey | 250 | +3.2 % | 0.0 % | **+3.2 %** | +12.8 % |
    | dict-longkey | 286 | +4.2 % | +0.3 % | **+3.1 %** | +10.8 % |
    | string-concat / string-join / csv-split | | ±1 % | ±1 % | **±1 %** | ±1 % |

    string-eq-prefix is the B4 fast-reject paying at last: its keys are built as `prefix ++ code`, so
    they now carry slots and `==` on two different keys reads two words.
  - **Census** (`ECO_HASH_CENSUS=1`, new build-site rows; `local-dev/hashreuse/census-build-sites*.txt`):
    every key of seqdict-prefixkey-fresh (180,017 of 180,021), seqdict-built-keys and seqdict-prefixkey
    is given its hash at build and every one is hashed later; seqdict-longkey's keys (`String.concat`
    of short fragments) are never composed (over budget) and all hashed later; in csv-split,
    string-append and string-compare-prefix composition gives hashes nothing reads (cost measured:
    ≤ 2 %, string-compare-prefix +2.0 %, string-concat +1.4 %, csv-split +0.3 %, word-freq 0 %).
  - **B6 hash at build: removed.** The census found almost no 32+-unit Strings built by the per-unit
    builders in the suite (reverse 6, toUpper 3) and none hashed later (p = 0 at every site); with the
    hook on, revcomp +0.8 %, unicode-string 0 %, string-callbacks −0.6 %, k-nucleotide 0 %. By §4.3's
    rule (keep a site only if p > c_b / c_d) no site stays, so the hooks, their census rows and their
    test were removed. Not measured: `fromList` and the Bytes/JSON decoders, whose files the kernel
    license manifest pins.
  - **Tests.** New `test/allocator/StringHashComposeTest.cpp` (5 tests: the CRC module against a
    bit-by-bit CRC32C for UTF-16 and UTF-8 runs, every offset, continued states, pairs and
    many-piece joins left/right/tree; every form follows v4; a hashed rope fills its children; every
    build site's slot is the raw CRC of its units or 0 as the settings say, for each form, empty parts,
    separators, both sides of the 128 Ki limit; propagation). `--filter HEAP_088` 12/12;
    `--filter eco-system/` 256/256 (the new pins and colliding keys); `--filter String` 209/209.
    Negative control (by hand, reverted, rebuilt): `composeRaw` with |b| + 1 fails the two composition
    tests ("slot is not the raw CRC32C of its units"). Validate tree (`build-validate`, rebuilt in full) with
    `ECO_NURSERY_POISON=1`: `--filter HEAP_088` 12/12, `--filter eco-system/` 256/256: the
    pre-evacuation walk recomputes every slot, composed ones included, at every minor. The final code
    (after `ComposeCheck` and the B6 removal) also passes `--filter String` and `--filter eco-system/`
    in the normal build. Not run: the full gate, the full validate gate (B7), the self-build.
  - **Benchmarks.** Suite (`local-dev/hashreuse/post-v4-final-bench.json`, native only: the JS backend
    has its own hash and none of this code; all 110 ok): geomean against the base 0.971 (non-Seq/String
    1.005), against Part B (v3) 0.968 (0.996). Interleaved, base / Part A / Part B (v3) / final, 3
    alternations (`local-dev/hashreuse/ab4-results.txt`), native ms:

    | workload | base | Part A plain | Part A `-hashed` | Part B (v3) | **final** | final vs base |
    |---|--:|--:|--:|--:|--:|--:|
    | seqdict-prefixkey | 130 | 132 | 55 | 67 | **51** | −61 % |
    | seqset-prefixkey-rounds | 184 | 185 | 47 | 62 | **61** | −67 % |
    | seqdict-longkey-reuse | 292 | 289 | 264 | 268 | **280** | −4 % |
    | seqdict-intern (control) | 316 | 316 | 322 | 324 | **319** | +1 % |
    | seqdict-prefixkey-fresh | 150 | 148 | – | 155 | **105** | −30 % |
    | string-eq-prefix | 117 | 113 | – | 114 | **10** | −92 % |
    | seqdict-longkey | 254 | 247 | – | 250 | **256** | +1 % |
    | dict-longkey | 283 | 286 | – | 283 | **291** | +3 % |
    | string-concat | 202 | 202 | – | 210 | **215** | +6 % |
    | string-join | 251 | 250 | – | 262 | **267** | +6 % |
    | string-append | 325 | 339 | – | 339 | **349** | +7 % |
    | csv-split | 342 | 341 | – | 352 | **364** | +6 % |
    | string-compare-prefix | 96 | 100 | – | 99 | **107** | +11 % |
    | fib (layout control) | 75 | 87 | – | 75 | **88** | +17 % |

    The String-building costs against the base are mostly Part B's slot word (B: +2-4 %, §7 above);
    composition adds ≤ 2 % (above); v4 itself, from the suite runs (not interleaved), moved
    string-concat +0.5 %, string-join +0.8 % and csv-split +5 % against Part B.
    string-compare-prefix's +8 % against B is mostly layout: the same code paths measure 101 ms in the
    measurement binary (v4 alone 99) and 107 in the final one, as fib's +17 % is (Part A has it too).
  - **Verdict.** Composition is an improvement: with no program change, Part B now beats Part A's
    opt-in on seqdict-prefixkey (51 vs 55 ms), gives keys built from hashed parts their hash for free
    (prefixkey-fresh −30 %, built-keys −20 % against v4 alone), and makes `==` on such keys answer from
    the slots (string-eq-prefix −92 %); it costs ≤ 2 % where the hashes go unread. Hash at build for
    per-unit builders is not: nothing in the suite hashes what they build.
