# Bounded GC rooting in list-building kernels

Status: **DONE** (2026-10-06; results §6). Found by plans/staging-honesty-and-production-test-pipeline.md
§4 ("shadow-root overflow"), where `ECO_MONO_LSS_REPORT=1` aborted the self-compile.

## 0. Goal

No kernel may push a number of GC shadow-root records that grows with its input. After this plan:

- every runtime/kernel helper roots a whole buffer with ONE record, or keeps its results on the
  heap as it goes, so root-stack use per kernel call is O(1);
- the shadow stack cannot be overflowed silently: overflow is a clean fault in every build;
- every overflowing case has an E2E test that fails today and passes after the fix.

Non-goals: changing the collector's scanning, the compiled-code push sequence (its layout is frozen,
`RootSet.hpp`), or the list representation.

## 1. The defect

### 1.1 Why kernels root at all

The nursery is a copying, precise collector. C++ locals are invisible to it, so a kernel that holds
heap pointers across an allocation or a call back into Elm must register them on the shadow stack:
a TLS array of `{base, count, hpointer_mask}` records (`RootSet.hpp`, capacity
`kRootRangeStackSlots` = 65,536 records, plus 1,024 slack). A record covers `count` contiguous
8-byte slots; for `count > 64` only an all-ones mask is expressible (`stackRangeSlotIsRoot`).

### 1.2 Why they root each element

List-building kernels produce results front to back but must build the spine back to front (a cons
cell points at the rest of the list). They cannot allocate cell i and patch its tail later: the GC
has no write barrier (HEAP\_005), and a callback between allocation and patch can promote cell i,
making the patch an unremembered old→young pointer. So they park the result POINTERS in a C++
buffer, then build the spine from the end with no callbacks in between.

The buffers are `std::vector<std::pair<Unboxable, u8 kind>>` (pointer slots every 16 bytes,
interleaved with kind bytes and unboxed values that must not be traced) or `std::vector<HPointer>`
pushed element by element. Neither shape fits one record, so each boxed element gets its own
record: n elements → n records. The overflow check exists only under `!NDEBUG` / ECO\_HEAP\_VALIDATE
(`ecoRootRangePush`); an NDEBUG build writes past the slack.

Some sites root in 64-element chunks (`rootInChunks`, the string splitters): n/64 records, which
overflows at 64 × 65,536 = 4,194,304 elements.

### 1.3 Inventory (live paths), measured by the §4 E2E pins

| Elm entry point | site that overflows | records | first overflows at | E2E pin (fails today) |
|---|---|---|---|---|
| `List.sortBy` / `sortWith` / `sort` | `listFromPermutation` → `HeapHelpers.hpp` `listFromUnboxables` | per element | 65,536 | RootStackSortByTest, RootStackSortWithTest, RootStackSortTest |
| `List.take` / `List.drop` | `ListOps.cpp` `take`/`drop` → `listFromUnboxables` | per element | 65,536 | RootStackTakeDropTest |
| `++`, `List.append`, `List.concat` | above the `chunkChainFits` cap (≈ 4M elements, 128 MB nursery): fallback `listFromUnboxables` | per element | the chunk cap | RootStackAppendLargeTest (4.3M) |
| `String.split` / `lines` / `words` | `HeapHelpers.hpp` `listFromPointers` (also `StringOps.cpp` / `String.cpp` per-64 rooting) | per element | 65,536 | RootStackStringSplitTest, RootStackStringLinesTest, RootStackStringWordsTest |
| `Regex.find` / `findAtMost` / `split` / `splitAtMost` | `RegexExports.cpp` 294 / 442 / 451 | per element | 65,536 | RootStackRegexFindTest, RootStackRegexSplitTest |
| `Json.Decode.list` / `array` | `JsonExports.cpp` `rootInChunks` | per 64 | 4,194,304 | RootStackJsonLargeListTest (4.3M) |
| `Json.Decode.keyValuePairs` / `dict` | `JsonExports.cpp` `runDecoder` key-value | per 64 | 4,194,304 | RootStackJsonLargeKeyValueTest (4.3M) |
| eco kernel tasks returning `List String` | `eco-kernel-cpp` `KernelHelpers.hpp:163` `taskSucceedStringList` | per element | 65,536 | none: needs > 65,536 OS entries (directory listing) |
| eco `Http` archive download | `eco-kernel-cpp` `Http.cpp:254` | per element | 65,536 | none: needs a server fixture with > 65,536 files |

Guards that PASS today and must keep passing (they exercise paths that already root O(1)):
RootStackReverseTest, RootStackAppendTest, RootStackConcatTest (70,000 elements: `reverse`/`append`/
`concat` already fill a builder chunk chain below the cap — the §2.1 design, in production), RootStackMapNTest
(`map2`..`map5` root whole arrays), RootStackJsonListTest, RootStackJsonKeyValueTest (70,000: per-64 rooting
is 1,094 records).

Dead (no caller outside their own file; delete, §2.4): `ListOps.cpp` `map`, `indexedMap`, `filter`,
`filterMap`, `partition`, `sortBy`, `sortWith`, `map2`, `map3`; `List.cpp` `toArray`, `map2`–`map5`.
`ListOps.cpp` `foldr` (reverse cursor, per-64 `rootNodes`) has no live caller found either; confirm
before deleting.

## 2. Design

### 2.1 Forward-filled builder chains (preferred)

This is already how `ListOps::reverse`, `append` and `concat` work below the chunk cap
(`listChunkChain` + `ListChainWriter`/`ListChainReverseWriter` + `finishChunkChain`); their only gap
is the over-cap fallback. The builder bit (HEAP\_BUILDER\_001..003) already makes in-place writes safe: a builder object is
never aged or promoted, so a write after a GC cannot create an old→young pointer. `listChunkChain`
already allocates every chunk backing and view as a builder; `finishChunkChain` clears them.

A kernel whose output size is bounded before its first callback (`map`-like kernels, `split`,
`lines`, `words`, regex `split`, JSON `list`/`array`) will:

1. allocate the result chunk chain for the bound as builders (`listChunkChain(bound, kind, nil)`;
   boxed slots start null, which `evacuate` skips);
2. root only the chain head — one record — and fill through a NEW `RootedChainWriter` that holds an
   index, not raw addresses, and re-resolves after every callback (today's `ListChainWriter` holds
   raw pointers, which is why `listChunkChain` forbids allocating during the fill);
3. write each result into its slot as it is produced (the result is then reachable from the rooted
   head and needs no record of its own);
4. trim to the produced count (set the views' `len`; filter-like kernels) and `finishChunkChain`.

Guard: `chunkChainFits(bound)` (the chain must fit in a quarter of the nursery, because builders are
copied at every minor GC). Above it, use §2.2.

### 2.2 One record per buffer (fallback, and for random access)

`RootedSlots`: an RAII helper owning a `std::vector<HPointer>` sized to the bound and zero-filled,
rooted by ONE all-ones record pushed at construction. Slots are filled in place (null slots are
skipped by `evacuate`). When a bound is not known (regex `find`), it grows by doubling and patches
its own record's `base`/`count` in place — safe because the record is the helper's own and no GC
can run during the C++ reallocation. Unboxed values go in a separate untraced `std::vector<u64>`
with a parallel kind array (a list's elements share one representation; validate builds assert it).

Users: `listFromUnboxables`/`listFromPointers` (callers already hold the elements), the sort family
(sort an index array of plain integers, read elements through one record), the reverse cursor's node
array, JSON key-value accumulation, and every §2.1 kernel above the `chunkChainFits` cap.

### 2.3 No silent overflow

Map the shadow stack (both the range stack and the single-slot stack) with `mmap` and a guard page
after the slack, so an overflow from deep non-tail recursion in compiled code faults cleanly in every
build. Keep the existing debug check (its message names the cause). This touches `Allocator.cpp` /
`RootSet.cpp` setup: run the TLA canary procedure (GC\_MODEL\_001) for any pinned file.

### 2.4 Dead code

Delete the uncalled per-element implementations (`ListOps.cpp` `map`, `indexedMap`, `filter`,
`filterMap`, `partition`, `sortBy`, `sortWith`, `map2`, `map3`; `List.cpp` `toArray`, `map2`–`map5`)
rather than fix them, after confirming no JIT symbol table or test references them.

## 3. Steps

1. **E2E pins** (§4) — done with this plan; each fails today.
2. `RootedSlots` + unit tests in `test/` (GC during fill, growth patching, null tail, validate build).
3. `RootedChainWriter` + unit tests (fill across forced minor GCs; trim; builder bits cleared;
   HEAP\_BUILDER\_001 holds under ECO\_HEAP\_VALIDATE).
4. Convert `listFromUnboxables`, `listFromPointers`, the reverse cursor, the sort family (§2.2).
5. Convert `split`/`lines`/`words`, regex, JSON decoders (§2.1, falling back to §2.2).
6. eco kernel `taskSucceedStringList`, `Http.cpp` (§2.2). Re-audit LSS\_022 kernel licences
   (advance `audited:` with a reason) and `check-kernel-license-manifest.sh --update`.
7. Delete the dead implementations (§2.4).
8. Guard page (§2.3) + TLA canary audit.
9. A static check: a grep script in the `check` target that fails on `pushStackRootRange` /
   `ecoRoot1Push` inside a `for`/`while` body in `runtime/src`, `elm-kernel-cpp/src`,
   `eco-kernel-cpp/src` unless the line carries `// root-bounded: <reason>`.

## 4. Tests (E2E pins, test/*/src/RootStack*Test.elm)

Each builds more boxed elements than the stack can hold through ONE entry-point family (so a failure
names its site) and checks the result. Per-element sites use 70,000 strings; per-64 sites and the
over-cap fallback use 4,300,000. 12 pins fail today with `FATAL: GC shadow root stack overflow at
depth 65536` (§1.3); 6 guards pass. After the fix all 18 pass, including on the validate tree.

## 5. Gates

elm-tests; `full` with the cache wipe; AOT; MLIR equivalence; validate tree (unit + E2E; the
RootStack pins must pass there too); bootstrap fixed point; strict TLA canary; perf triple (the
self-compile sorts and splits large lists — expect flat or better); `ECO_MONO_LSS_REPORT=1`
self-compile completes (the original symptom).

## 6. Results

**Step 1 (pins).** 18 `RootStack*Test` E2E programs; 12 failed with `FATAL: GC shadow root stack
overflow at depth 65536` before the fix, 6 guards passed.

**Steps 2/4 (§2.2, one record per buffer).** `runtime/src/allocator/RootedSlots.hpp`:
`RootedSlots` (a growable `std::vector<HPointer>` rooted by ONE all-ones record whose `base`/`count`
it patches in place on growth) and `RootedElems` (boxed values in a `RootedSlots`, unboxed bits in an
untraced array, kinds alongside). Converted:

- `HeapHelpers.hpp`: `listFromUnboxables` and `listFromPointers` (new `RootedElems` / `RootedSlots`
  overloads; the vector overloads copy into them), `ListBackwardCursor::rootNodes` (one record);
- `ListOps.cpp`: the sort family, take/drop, the append/concat over-cap fallback (all via
  `listFromUnboxables`), and map/indexedMap/filter/filterMap/partition/map2/map3/unzip. `unzip` also had
  a latent bug: `seconds` was unrooted while the first list was being built;
- `StringOps.cpp` and `String.cpp` split/lines/words: one record instead of per 64;
- `RegexExports.cpp` findAtMost/splitAtMost: one `RootedSlots` record (the per-element deque is
  gone);
- `JsonExports.cpp`: `rootInChunks` renamed `rootBuffer`, now one record (list/array decode and
  keyValuePairs);
- eco kernel `KernelHelpers.hpp` `taskSucceedStringList` and `Http.cpp` getArchive: one record.

**Step 3 (§2.1, `RootedChainWriter`): NOT BUILT, deviation.** No live site needs it. Every converted
site falls into one of three groups:

- its elements are already in hand before the spine is built (split/lines/words, regex, sort, take,
  drop, eco kernel), and `listFromPointers`/`listFromUnboxables` already take the builder chunk-chain
  path below `chunkChainFits`;
- it builds an Elm `Array`, not a list (JSON `array`/`list` decode via `buildElmArrayFromElements`);
- it is a C++-only helper with no Elm caller (the `ListOps` map family; compiled Elm implements
  `List.map` etc.).

The overflow is fixed by §2.2 everywhere, so §2.1 would only save one buffer copy per call. During a
callback-heavy fill it would also copy a builder chain at every minor GC, where the current buffer is
only scanned.

**Step 5 deviation.** Same reason: the decoders and splitters use §2.2 only.

**Step 6 (eco kernel + LSS\_022).** Converted. 64 `TypeFaithful` rows whose pinned files changed were
re-audited: the edits are rooting-only or delete dead code, so there is no apply, no retention and no
closure mint, and B1/B2/B3 are unchanged. Each row gets a `re-audit 2026-10-06` note, and the manifest
is regenerated (369 pins).

**Step 7 (§2.4) deviation.** Deleted `List.cpp` `toArray` and `map2`–`map5` (no caller). KEPT and FIXED
the `ListOps.cpp` per-element functions instead of deleting them: `test/allocator/ListOpsTest.cpp` and
`ChunkedListTest.cpp` exercise them (and `foldr`), so they stay as tested runtime API.

**Step 8 (§2.3).** `RootSet.cpp` maps both shadow stacks with `mmap` plus one `PROT_NONE` guard page
after the slack (it was `malloc`). The debug check and its message are kept. TLA: `RootSet.cpp` is not
pinned. `RootSet.hpp` (census M1) was deliberately left unchanged: the mapped size is recomputed rather
than stored in a new member.

**Step 9.** `test/scripts/check-root-bounded.py` is the first command of the `check` and `full`
targets. It is green; the one bounded loop push (`StackRootGuard`'s initializer list) carries
`// root-bounded:`.

**Latent GC bug found by the pins: the list scratch stack lost its root scanner after a heap reset.**
With the overflow fixed, `RootStackJsonLargeListTest` got further and aborted in the unit-test binary's
forked E2E run:

```
[minorwork] FATAL: to-space overflow claiming 24 bytes (the P§3.2 space bound is wrong)
```

The space bound was right. Temporary diagnostics showed:

- from-space held only Cons cells (95.6 MB);
- the parallel minor copied 100.5 MB, including 8 MB of Int and StringRope "objects";
- the first bad slot was a Cons head pointing at another cell's TAIL FIELD.

The mutator had built cells from stale pointers. `RuntimeExports.cpp` `listScratch()` registered its
external root scanner once per thread (a `thread_local` `registered` flag). The test harness's
`initAllocator` destroys the thread heap, its `RootSet` and that scanner. The forked E2E child
inherited `registered == true`, so `Json.Decode.list`'s scratch entries were never evacuated across
the GCs inside the 4.3M-element decode, and `eco_scratch_finish` consed stale pointers.

Production initialises the heap once, so only the test binary was exposed. The AOT/JIT `full` phase
of the same test passed. The bug was latent because this pin used to abort earlier, on the shadow-stack
overflow.

Fix: the registration is keyed on `Allocator::heapGeneration()`, the existing mechanism the literal
table uses. `eco_scratch_mark` re-validates it, so per-element pushes are unchanged. Pin:
`ChunkedListTest` "Scratch stack survives a heap reset", which fails with the generation check
removed (negative control) and passes with it. All GC files touched by the diagnostics were restored
byte-exact (strict TLA canary green; the `RuntimeExports.cpp` census pin is unchanged). Other scanners
registered with a one-time flag (`Time`, `Http` `std::once_flag`) have the same shape, but no pin
exercises them across a reset. They are noted here, not changed.

**Gates.**

| gate | result |
|---|---|
| `check-root-bounded.py` | ok |
| elm-tests | 14,098 pass, 5 fail = the known real-bug pins (MONO\_006 ×2, MONO\_011, MONO\_017, REP\_BOUNDARY\_003) |
| `full` (cache wiped) + unit binary | 2,146/2,147 after the scratch fix; the one fail = PolyLetTailRecTwoTypesTest (known MONO\_011 pin). All 18 RootStack tests pass |
| LSS\_022 manifest | 64 rows re-audited, 369 pins |
| strict TLA canary | green |
| perf (self-compile, `ecoG5.mlir` relowered on the new runtime vs the old, N=3 interleaved) | wall median 68.76 → 67.94 s (−1.2 %, inside noise), RSS flat, output byte-identical |
| `ECO_MONO_LSS_REPORT=1` self-compile | completes (rc 0); was the original abort |
