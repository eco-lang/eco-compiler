---
status: not-started
updated: 2026-11-24
---

# Hash reuse: explicit `Hashed` keys against a transparent String hash cache

A SeqDict or SeqSet operation hashes its key once (`FNV.hash key`, then the trie walks on stored
hashes), but every operation hashes again: four lookups of one long key hash it four times. This
plan builds two ways of hashing a key once and reusing the result, on two branches from one base,
measures both the same way, and picks one.

- **Part A, explicit:** an opaque `Hashed a` (a value and its hash) in eco/system's `Hash` module,
  and a `...Hashed` twin of every SeqDict/SeqSet operation that hashes a key. A program opts in.
- **Part B, transparent:** Strings carry a cached hash in the heap, filled on demand, or at creation
  where that is free, or by combining the hashes of the two sides of a `++`. No program changes.
  Strings only, for now.

The user creates the branches and makes the commits at the points marked **USER**.

## 1. Where things stand (verified 2026-11-24)

### 1.1 Hashing in SeqDict and SeqSet

- `get`, `member`, `insert`, `remove`, `update` each call `FNV.hash key` once and pass the number
  down (`getEntry`, `insertWithHash`, `removeWithHash`); entries store their key's hash, a lookup
  compares the stored hash before the key (`h == hash && k == key`), and bulk operations reuse
  stored hashes. A full key comparison happens on a hit (or within a collision list).
- **No inlining:** in the compiled benchmark these are out-of-line functions at the front end
  (`eco.call @SeqDict_get_$_422` then `@SeqDict_insert_$_423` on the same key in seqdict-intern's
  `probe`) and in the binary (13 call sites of `SeqDict.get`, 17 of `insert`, 6 of `member`, 4 of
  `SeqSet.insert`). The runtime hash calls are declared with only the gc-leaf attribute, so LLVM
  could not merge two of them even if inlined. (Inlining the thin wrappers so that MLIR CSE merges
  the Pure `eco.hash` ops is a separate, cheaper idea for repeated use within one function; out of
  scope here, see §6.)
- String hash definition v3 (whole String, word at a time; design_docs/theory/runtime/value-hash.md)
  costs about 0.13 ns per unit. seqdict-prefixkey (2,000-character keys, 8 of 9 hashes repeated) is
  127 ms; the repeated hashes are roughly 20 ms of that (estimate, to be measured in A0/B0).
- **The compiler does not use SeqDict or `FNV.hash`.** It hashes with eco/kernel's `Eco.Hash`
  (`stringWithSeed`, `string64`, its own definitions) through `Data.HashMap`, which already takes
  caller-computed hashes (`getHashed`, `insertNew`): the explicit style of Part A, in eco/kernel.
  So compiler self-build time measures what each branch **costs** (memory, allocation, creation-time
  work), not what it gains, unless Part B also serves `Eco.Hash` (step B8, optional).

### 1.2 Header and payload space

`Header` (Heap.hpp:150) is one 64-bit word: `tag:5 color:2 pin:1 age:2 unboxed:6 refcount:15
builder:1` then `size:32`. 26 of the 32 tag values are used.

- `refcount` (15 bits) holds no reference count. Only a `Tag_Free` cell (old-gen free-list links)
  and the constructor census (a diagnostic, `Tag_Custom` only, `_census_id`) write it. **On a live
  object it is free**, apart from the census.
- `unboxed` (6 bits) means something per tag (below).
- **Concurrency:** concurrent markers write `color` with plain bit-field stores
  (`hdr->color = ...`, OldGenSpace.cpp), a read-modify-write of the whole first 32-bit word. So a bit
  that changes **after publication** cannot live in that word unless markers and mutator both switch
  to atomic RMW. A bit set **before publication** (at allocation) is safe. `size` is never written
  after allocation.

Space by type, for any type we might hash:

| type | `unboxed` (6 bits) | `refcount` (15 bits) | spare payload space |
|---|---|---|---|
| Int, Float | free | free | none (the value fills the word) |
| Char | free | free | `u32 padding` |
| String, flat UTF-16 (`ElmString`) | free | free | none; tail padding only by accident of length |
| String, UTF-8 leaf | free | free | none (same) |
| String slice | free (0) | free | `u32 _padding` |
| String UTF-8 view | free | free | `u32 byteLen`, which duplicates `header.size` |
| String rope | free (0) | free | none; `u32 height` (< 64) could move into `unboxed` |
| Large String header | free | free | none (16 bytes, static_assert) |
| Tuple2 | 4 bits used (2 free) | free | none |
| Tuple3 | all 6 used | free | none |
| Cons, ConsChunk | 2 bits used | free | none |
| Custom (incl. Dict, SeqDict nodes) | K, needs all 6 | census only | none (`ctor` + 48 kind bits fill word 2) |
| Record | K, needs all 6 | free | none (word 2 is 32 slot kinds) |
| Array | 2 bits used | free | `u32 padding` |

So **two header bits are free on every type** (in `refcount`; the census would take 13 bits
instead of 15), but only for flags fixed at allocation (§ concurrency). A 32-bit hash fits for free
only in a String slice, a UTF-8 view (reusing `byteLen`), a rope (if `height` moves to `unboxed`),
a Char and an Array. Everything else needs an extra word. Primitives need no cache (their hash is a
few inline instructions); tuples, records and customs would cost 8 bytes per object, which is why
this plan does Strings only.

### 1.3 Can the String hash be computed at creation, or composed across `++`?

- **At creation (a): yes, for any definition**, by running it over the new String. The cost is a
  read of every unit of every String made, most of which are never hashed. Free cases: literals
  (hash at compile time or when the literal is interned into PermanentSpace), and Strings whose
  creation already reads every unit (a flattening concat, `String.fromList`, decoders) if the hash
  is folded into that loop.
- **Across `++` (b): not with v3.** v3's lanes start from fixed seeds at the String's start, so
  `hash (a ++ b)` cannot be made from `hash a` and `hash b`. A composable definition is needed:
  `H(a ++ b) = combine(H(a), H(b), length b)`. Two candidates, measured (C++ microbenchmark,
  /tmp/seqwork/compose/c.cpp; ns per String, units widened from ASCII as for a UTF-8 leaf):

  | length (units) | v3 | CRC32C, 1 stream | CRC32C, 3 streams | polynomial mod 2^61-1 |
  |--:|--:|--:|--:|--:|
  | 32 | 6.0 | 4.3 | 4.3 | 20.0 |
  | 192 | 27.1 | 33.5 | 24.2 | 127.4 |
  | 2,016 | 255.1 | 370.0 | 228.8 | 1,273.7 |
  | 4,096 | 565.6 | 829.0 | 503.6 | 2,593.8 |

  Combine for a ~2,000-unit right side: CRC32C 15.7 ns, polynomial 20.3 ns. **CRC32C (the SSE4.2 /
  ARMv8 `crc32c` instruction, three interleaved streams) is as fast as v3 and composes** (the
  standard `crc32c_combine`: multiply by x^(8·bytes) mod P with carry-less multiplies, log2(len)
  steps, or a table of x^(2^k)). It is linear over GF(2), so its raw value must be finalised
  (`fmix`) before SeqDict reads 5-bit groups, and its collision behaviour on structured keys must be
  checked (B0). The cached state for composition is the raw 32-bit CRC (the length is in the
  header), so a 32-bit slot suffices. The polynomial hash is 5x slower and needs a 61-bit state.

## 2. Method

### 2.1 Base, branches and measurements

1. **USER:** commit the current work (String hash v3, the long-String benchmarks) to main after its
   full gate. That commit is the **base**.
2. On the base, before branching, add the shared measurement pieces (step M below) and record the
   base figures. **USER:** commit them to main.
3. **USER:** create branch `hash-explicit` from the base; Part A runs there. **USER:** commit at the
   end of Part A.
4. **USER:** create branch `hash-cache` from the base; Part B runs there. **USER:** commit at the
   end of Part B (and at the B-step checkpoints marked below, if wanted).
5. Compare (§5) and pick a winner; the other branch is kept for reference or deleted (user's call).

Each branch is measured with exactly the base's procedure:

- **Benchmarks:** the whole suite, `/tmp/seqwork/bench-full.sh local-dev/<label>-bench.json`
  (eco native and eco-js; default warmup 3 / runs 11), plus the reuse workloads of step M.
  Single-run noise in this suite is up to ±10 % on unrelated workloads (fib, string-compare-prefix):
  any workload that moves by more than 5 % is re-measured with interleaved runs of the base and
  branch binaries (`/tmp/seqwork/ab.sh`), 5 alternations, medians, before it is reported.
- **Compiler self-build:** a cold self-compile of the compiler with the branch's native eco
  (`--no-cache`, eco-stuff moved aside), wall time and peak RSS, N = 3, median. The compiler does
  not use SeqDict, so this is a cost check (§1.1).
- **Memory:** peak RSS per workload (the suite records it) and, for Part B, String bytes allocated
  (GC stats).
- **Gates:** targeted tests during each part; the full gate once at the end of each part, before its
  final commit (the user runs it, or asks for it).

### 2.2 Step M: shared measurement pieces (on the base)

- Reuse workloads in `examples/benchmarks/src/SeqLargeKeys.elm`, keys built once and used many
  times, each with a plain version (benefits from Part B only) whose code Part A copies into a
  `-hashed` version:
  - seqdict-prefixkey (exists): 2,000-character keys, 4 rounds of lookups.
  - seqdict-longkey-reuse (exists): ~190-character keys, 4 rounds.
  - seqdict-intern (exists): type-tree keys, `get` then `insert` of the same key (Part B helps only
    with the Strings inside; Part A hashes the tree once).
  - **seqset-prefixkey-rounds** (new): 32 rounds of `SeqSet.member` over 5,000 keys of 500
    characters: hashing-dominated reuse at a moderate length.
  - **seqdict-shortkey-reuse** (new): seqdict-string's keys (< 8 units) looked up 8 times: the case
    where reuse should not matter, to catch overhead.
- A note in the README that the `-hashed` variants exist only on `hash-explicit`.
- Record `local-dev/hashreuse-base-bench.json` and the base self-build figures in §7.

## 3. Part A: explicit `Hashed` keys (branch `hash-explicit`)

### 3.1 API

In eco/system's `Hash` module (system-kernel-cpp/src/Hash.elm), next to `hash : a -> Int`:

```elm
type Hashed a                 -- opaque; one constructor `Hashed Int a`
hashed : a -> Hashed a        -- computes `hash` once
value : Hashed a -> a
hashOf : Hashed a -> Int      -- the same number `hash` gives
```

In `SeqDict` and `SeqSet`, a twin of every operation that hashes a key:

| module | functions |
|---|---|
| SeqDict | `getHashed`, `memberHashed`, `insertHashed`, `removeHashed`, `updateHashed` |
| SeqSet | `memberHashed`, `insertHashed`, `removeHashed` |

Each is the plain function with `FNV.hash key` replaced by the stored number (`getEntry`,
`insertWithHash`, `removeWithHash` already take it), so each is a few lines.

Rules, in the docs:

- The value and its hash are paired by construction (`hashed` is the only way to make one), so a
  `Hashed` key can never carry the wrong hash; this is what eco/kernel's `Data.HashMap.getHashed`
  (a bare `Int` from the caller) does not guarantee, and a wrong hash in a trie is a silent miss or a
  broken invariant.
- Like `hash`, the number differs between backends and programs: never persist a `Hashed` or send
  it through a port.
- `==` on two `Hashed a` compares the number and the value (a Custom), which agrees with `==` on the
  values.

No kernel change, no runtime change, both backends (the functions are Elm). `Debug.toString` shows
`Hashed <n> <value>`.

### 3.2 Steps

- **A0. Measure first.** Profile seqdict-prefixkey and seqset-prefixkey-rounds on the base: the
  share of `Hasher::string` (expected ~20 % and more). Record it here.
- **A1. Hash.** `Hashed`, `hashed`, `value`, `hashOf`; docs.
- **A2. SeqDict/SeqSet twins** (§3.1), with `ECO_SEQDICT_VALIDATE` checks unchanged (the stored hash
  must equal `FNV.hash key`, which the validator already checks).
- **A3. Tests** (eco-system, both backends): every twin agrees with its plain function on the
  SeqDictSemanticsTest key sets, including colliding keys (`c600662`, `c5330492`, `c11005860`) and
  structured keys; `hashOf (hashed x) == Hash.hash x`; a negative control (a twin that hashes
  `hashOf + 1`) fails.
- **A4. Benchmarks.** The `-hashed` variants of the step M workloads (same work, keys built with
  `Hash.hashed` once). Whole suite + self-build (§2.1).
- **A5. Docs.** `design_docs/theory/runtime/data-structures.md` (SeqDict section), the module docs,
  `docs/` API pages if generated.

Exit: targeted tests green on both backends; the `-hashed` variants measured; full gate before the
**USER** commit.

## 4. Part B: transparent String hash cache (branch `hash-cache`)

### 4.1 Design

**Which Strings carry a slot.** A String carries a 32-bit cache slot when its form has room, or
gains one, as follows; the slot's presence follows from tag and size alone (no header bit):

| form | slot |
|---|---|
| slice | its `_padding` (free) |
| UTF-8 view | its `byteLen` (duplicates `header.size`; readers switch to `header.size`) |
| rope | its `height` word, after `height` moves into `header.unboxed` (< 64; assert) |
| large String | a new word (16 → 24 bytes; rare objects) |
| flat UTF-16, UTF-8 leaf, length ≥ T | a tail word after the payload (size from the header) |
| flat, length < T | none: the short path of v3 is a few nanoseconds |

T is decided in B0 (the smallest length where a cached hash pays; expected 32-64 units). Tail words
need every allocation site of the two flat forms to size and zero them: the list in
plans/seq-data-structures-performance.md D5 step 3 (HeapHelpers.hpp `allocString`/`allocStringBlank`,
StringOps.cpp `concat`/`join`, RuntimeExports.cpp `eco_alloc_string*`, `eco_init_string_at`,
ThreadLocalHeap.cpp `initHeaderForTag`, BytesExports.cpp, every `Tag_StringUtf8Leaf` allocation,
EcoGCPrepare.cpp `getFixedAllocSizeForGrouping`, EcoToLLVMHeap.cpp `computeAllocSize`), funnelled
through one helper so a new site cannot forget, plus `getObjectSizeFromHeader`.

**Present or absent.** The slot holds the hash, and 0 means "not computed" (no header bit: a bit
written after publication would race with the markers' colour stores, §1.2). With v3 the finished
hash is never 0. With a composable definition the slot holds the raw state, and a String whose raw
state is 0 is simply never cached (one in 2^32).

**When the slot is filled.** Four policies, built in this order and measured one at a time:

1. **On demand:** `eco_hash_string` and the walker's String path read the slot; on 0 they compute
   and store. This is the core of Part B.
2. **Literals:** hashed when interned into PermanentSpace (`allocInternObject`, before publication).
3. **Composition at `++`:** a rope whose two sides both hold a hash gets
   `combine(left, right, length right)`; a flattening concat whose parts hold hashes gets it the
   same way instead of rereading. Needs a composable definition (4.2).
4. **Eager at creation** (experiment, expected to lose): hash every String ≥ T when it is made.

**Equality.** `StringOps::equal` returns `False` when both slots are non-zero and differ (never
computes a hash; §1.3). Measured separately (string-eq-prefix after the keys have been hashed).

**P1 and the collectors.** Policy 1 writes the slot of an object that may have survived a
collection (keys built in bulk are hashed after surviving; D4 census: 2,642 of 120,000 first
hashes at nursery age 0). That breaks P1 (HEAP_SNAPSHOT_001: no write to an object after it
survived a GC). The carve-out to argue and test:

- The slot is written at most once from 0 to a value that depends only on the String's content; any
  writer writes the same value; a 32-bit aligned store cannot tear.
- The tenure collector may copy an aged object while the mutator stores into it: the copy may lose
  the store (the slot stays 0 in the new copy), which only costs a recomputation. The old copy's
  memory is reclaimed only at a stop-the-world point, so the store never lands in freed memory.
- Old-generation objects never move; markers do not read String slots.
- Read `test/tla/README.md` first; check which models cover tenure copying and nursery reclamation,
  and whether a mutator store into an aged object is a new action they must model. If the canary
  fires, investigate the named models; never repair the hash alone.
- `ECO_HEAP_VALIDATE`: the pre-evacuation walks (NurserySpace.cpp, NurseryRegion.cpp) check every
  non-zero slot equals the recomputed hash; the P1 census and survivor-write census skip the slot
  (an allow-list by tag and offset), and nothing else.
- A new `HEAP_0xx` invariant row; amend the `[Pure]` notes on the String ops in Ops.td.

### 4.2 Hash definition for Part B

- Policies 1, 2 and 4 work with v3 unchanged.
- Policy 3 needs a composable definition, **v4**: CRC32C over the UTF-16 units (a UTF-8 form's
  bytes widened), three interleaved streams for speed, `crc32c_combine` for `++`, finalised with
  `fmix32` (and the length) to the 32-bit hash, never 0. The slot stores the raw CRC.
- v4 replaces v3 on this branch only if B0 shows it at least as fast as v3 on the suite's String
  workloads, with collision and 5-bit-uniformity figures as good as v3's on: 1 M short keys, shared
  long prefixes, sparse edits, and structured sets (keys differing by one fixed pattern at many
  offsets, which a linear hash maps to fixed XOR differences). A software fallback (slicing-by-8
  tables) for hosts without the instruction; the JS backend keeps its own hash.

### 4.3 Steps

- **B0. Decide v4 and T.** Microbenchmarks and quality checks of 4.2 in C++ (extend
  /tmp/seqwork/compose and /tmp/seqwork/hv3/quality.cpp); measure the per-String cost of a slot
  check, a fill and a hit against the hash cost by length to choose T. Record both decisions here.
- **B1. Layout.** Slots in every form of 4.1, allocation sites through one helper, sizes, the rope
  `height` move, the view `byteLen` reuse. No caching yet: every slot stays 0. Test: allocator unit
  tests for sizes and initial zero; StringFormsCompareTest; E2E String tests. Measure the suite and
  memory: the cost of the space alone. **USER** checkpoint commit.
- **B2. On-demand fill + P1 carve-out** (4.1): `eco_hash_string`, the walker, `eco_hash_mix_string`
  (typed chains) read and fill; validation and census changes; TLA review; invariant row. Tests:
  unit tests that a slot is 0 after every allocation route, filled after a hash, kept by minor and
  major GC copies, and equal to the recomputed hash in validate builds; a GC-pressure E2E test that
  hashes aged keys while the tenure collector runs; negative controls (a fill of `hash + 1` fails the
  validator; a reader that ignores the slot shows no gain). Measure. **USER** checkpoint commit.
- **B3. Literals** hashed at intern. Measure.
- **B4. Equality fast-reject.** Measure (string-eq-prefix with pre-hashed keys).
- **B5. v4 and composition** (only if B0 chose v4): switch the definition (pins, reference model,
  docs as for v3), combine at rope creation and flattening concat when both sides hold hashes.
  Measure with a workload that builds keys by `++` from hashed parts.
- **B6. Eager creation hashing** (experiment): measure, then remove unless it wins.
- **B7. Validate gate** (`ECO_HEAP_VALIDATE` build, unit + E2E + pressure stress), since B2 touches
  P1.
- **B8. Optional: serve `Eco.Hash.string64`** from the slot when the definitions can agree (it only
  needs a bucket Int), so that the compiler's `Data.HashMap` benefits and self-build time can show a
  gain. Only if B2-B5 are kept.

Exit: targeted tests and the validate gate green; full gate before the final **USER** commit.

## 5. Comparison and choice

One table, each branch against `local-dev/hashreuse-base-bench.json`:

| measure | base | `hash-explicit` | `hash-cache` |
|---|---|---|---|
| seqdict-prefixkey / seqset-prefixkey-rounds / seqdict-longkey-reuse | | `-hashed` variants | plain |
| seqdict-intern | | `-hashed` | plain |
| seqdict-shortkey-reuse, seqdict-string (overhead) | | | |
| whole suite, workloads moving > 5 % (A/B-confirmed) | | | |
| compiler cold self-build wall / peak RSS | | | |
| String bytes allocated (suite total) | | | |
| lines changed, invariants added, P1 carve-out | | none | yes |

Choose by, in order: (1) no confirmed regression above 3 % on the suite or the self-build; (2) the
gain on the reuse workloads; (3) cost and risk (a P1 carve-out and a heap layout change against an
API). Part A's gain needs a program to opt in and Part B's does not, so if both pass (1), the
choice between them is the user's: the table states both gains and both costs side by side.

## 6. Not in this plan

- Caching hashes of tuples, records, customs or lists (§1.2: an extra word per object).
- Inlining the SeqDict wrappers so that MLIR CSE merges repeated `eco.hash` ops within one function
  (independent of both parts; could follow either).
- Changing elm/core `Dict` (comparison-based; a hash cannot order).

## 7. Progress log

(empty)
