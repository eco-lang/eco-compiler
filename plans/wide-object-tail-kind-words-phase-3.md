# Wide heap objects, Phase 3: Custom and Record (3A runtime, 3B lowering, 3C front end, 3D limits and final gate)

**Parent:** [`wide-object-tail-kind-words.md`](wide-object-tail-kind-words.md). The overview's §S
(shared helpers, limits, the `slot_kinds` attribute and its lifetime, the test switch, commands, how
to add tests) is binding. This file does not restate it.

**Status:** DONE (2026-10-05): 3A, 3B, 3C and 3D implemented; each group's gate result is recorded
before its checklist, and the whole-plan definition of done holds ("3D final gate result").

**Line numbers** were verified against the tree of 2026-10-05, before Phase 1. Phases 1, 2 and the
earlier Phase 3 groups move many of them, so **anchor on the function, op or quoted text** given with
each one. The number says where the code was on 2026-10-05.

**Order and gates.** The four groups run in order. Each has its own commit(s), gate, checklist and
rollback.

| Group | What | Commits | Gate | Depends on |
|---|---|---|---|---|
| **3A** | Custom/Record runtime layout C, inert: K in `Header.unboxed`, ext words after the fields, accessors, walkers, builders, validation, unit matrix; delete `AllocateCtorOp` / `scalar_bytes` | 3A.1–3A.9 runtime/test commits (revert in reverse order); 3A.10 one atomic commit | 3A gate | Phases 1 and 2 |
| **3B** | lowering and dialect: `slot_kinds` on construct.custom/record/to_heap, ext-word stores, sizes; wide ops only in fixtures carrying `eco.allow_wide_objects` | 3B.1; then 3B.2–3B.5 as **one** commit; 3B.6 fixtures | 3B.6.4 | 3A |
| **3C** | front end: no 24/26 caps, `slot_kinds` emitted for construct ops, checkers retargeted | 3C.1–3C.6 as **one** commit | 3C gate | 3B |
| **3D** | lift the caps to 2040/2047, user-facing limit errors, remove the test switch, sweep fixtures, delete the old bitmap attributes, invariants, theory docs, final gate | 3D.0 snapshot; 3D.1–3D.9 commits | 3D.10 (the plan's final gate) | 3C |

**List L3: the E2E expected-failure list for the 3A, 3B and 3C gates.** It is exactly the Phase 0
pins marked "green at P3D" (phase-0 Step 0.6a). After Phase 2 they all stop at the C++ verifier caps
that 3D.1 lifts. A gate passes when the `full` failures equal this list by name and reason (overview
§6.2), and nothing else fails.

| Test | Reason substring |
|---|---|
| `elm/WideCtorField24Test.elm` | `exceeds Custom's 24-slot limit` |
| `elm/WideCtorMixedTest.elm` | `exceeds Custom's 24-slot limit` |
| `elm/WideCtor1100Test.elm` | `exceeds Custom's 24-slot limit` |
| `elm/WideRecord33Test.elm` | `field_count (33) exceeds Record's 32-slot GC scan limit` |
| `elm/WideRecord40Test.elm` | `field_count (40) exceeds Record's 32-slot GC scan limit` |
| `elm/WideRecord600Test.elm` | `field_count (600) exceeds Record's 32-slot GC scan limit` |
| `elm/WideRecord1100Test.elm` | `field_count (1100) exceeds Record's 32-slot GC scan limit` |
| `elm/WideRecordDecoder70Test.elm` | `field_count (70) exceeds Record's 32-slot GC scan limit` (the arity error is gone since Phase 2) |
| `elm/WideRecordDecoder300Test.elm` | `field_count (300) exceeds Record's 32-slot GC scan limit` |
| `eco-kernel/WideHeapGcTest.elm` | `field_count (40) exceeds Record's 32-slot GC scan limit` |

**elm-tests expected for every Phase 3 gate:** only the 2 GOPT_003 failures
(`MonoCaseBranchResultTypeTest`). The wide elm-test pins have been green since Phases 1 and 2.

---

## 3A. Custom/Record runtime layout C (inert)

**Delivers:**
- Custom/Record objects with K = `extWords(n, CAP)` extension kind words after `values[n]`, with K
  stored in `Header.unboxed` (overview §2.1).
- It touches the runtime, the GC walkers, the builders, validation and unit tests, plus the deletion
  of `AllocateCtorOp` / `scalar_bytes` (3A.10).

**Depends on:**
- Phase 1: the accessors `customSlotKind` / `recordSlotKind` returning boxed past the header bitmap
  (§S.1), the D-semantics walker split, chunked builder rooting (B8), the `scalar_bytes` assert, and
  the test switch flag (§S.6).
- Phase 2: closures done, `CLOSURE_HDR_SLOTS = 20`.

**Inert:** compiled code is unchanged and the verifier caps (Custom 24, Record 32) still hold, so
every compiled object has K = 0. 3A.8 makes that a checked fact in validate builds.

### 3A.0 Invariants this group must keep (check after every step)

| Id | Statement |
|---|---|
| I1 | `getObjectSizeFromHeader` stays a function of the 8-byte header word alone (parallel copier `NurseryParallel.cpp:258`, `NurseryRegion.cpp:452`, sweep walkers `OldGenSpace.cpp:5730/5910/5935`) |
| I2 | For Custom/Record, `header.size` = logical field count n; `header.unboxed` = K = `extWords(n, CAP)`; ext words at `values[n .. n+K)`. Every allocation path writes all K words (zeros included) before the object can be seen by a GC |
| I3 | Small objects (n ≤ CAP) are byte-identical to today: K = 0, same size, same header word |
| I4 | Readers never recompute K. Slot i ≥ CAP with word index j ≥ `header.unboxed` reads as boxed |
| I5 | No new atomic, lock or memory order; header and ext words are written only at allocation (HEAP_031/034/SNAPSHOT_001) |
| I6 | Compiled objects have K = 0 (validate census, 3A.8) |

---


### 3A.1 Heap.hpp: accessor bodies with the ext-word branch, and kind-word helpers

**File:** `runtime/src/allocator/Heap.hpp`, in the block Phase 1 added after
`pointerMaskFromKindBitmap` (today `Heap.hpp:281-288`).

**Replace** the Phase 1 bodies of `customSlotKind` / `recordSlotKind`, which return 0 for i ≥ HDR:

```cpp
inline u32 customSlotKind(const Custom* c, u32 i) {
    if (i < CUSTOM_HDR_SLOTS) return kindInWord(c->unboxed, i);
    const u32 r = i - CUSTOM_HDR_SLOTS;
    const u32 j = r / SLOTS_PER_EXT_WORD;
    if (j >= c->header.unboxed) return 0;                 // I4: bounded by stored K
    return kindInWord(customExtWords(c)[j], r % SLOTS_PER_EXT_WORD);
}
inline u32 recordSlotKind(const Record* r, u32 i) {
    if (i < RECORD_HDR_SLOTS) return kindInWord(r->unboxed, i);
    const u32 q = i - RECORD_HDR_SLOTS;
    const u32 j = q / SLOTS_PER_EXT_WORD;
    if (j >= r->header.unboxed) return 0;
    return kindInWord(recordExtWords(r)[j], q % SLOTS_PER_EXT_WORD);
}
```

`c->unboxed` is the 48-bit bitfield. It promotes to u64, and `kindInWord` asserts i < 32; i < 24
holds here.

**Add** (new, Phase 3A):

```cpp
// Physical value words W = n + extWords(n, cap) -> (n, K). W is strictly increasing in n
// (proof below), so the inverse is unique; values of W not in the image return false.
constexpr bool splitPhysicalSlots(u32 W, u32 cap, u32& n, u32& k) {
    if (W <= cap) { n = W; k = 0; return true; }
    const u32 w = W - cap;               // w = m + ceil(m/32), m = n - cap >= 1
    if (w < 2) return false;             // w == 1 is not in the image
    const u32 q = (w - 2) / 33;          // m = 32q + r, r in [1,32]  =>  w = 33q + r + 1
    const u32 r = w - 33 * q - 1;
    if (r > 32) return false;            // w == 33(q+1) + 1 is not in the image
    n = cap + 32 * q + r; k = q + 1;     // k = ceil(m/32) = q + 1
    return true;
}
// Pack kinds[0..n) into the header bitmap (slots < cap) and ext words (rest).
inline u64 packHeaderKinds(const u8* kinds, u32 n, u32 cap) {
    u64 w = 0;
    for (u32 i = 0; i < n && i < cap; ++i) w |= u64(kinds[i] & 3u) << (2 * i);
    return w;
}
inline void packExtKinds(const u8* kinds, u32 n, u32 cap, u64* ext /* extWords(n,cap) words */) {
    const u32 k = extWords(n, cap);
    for (u32 j = 0; j < k; ++j) ext[j] = 0;          // I2: zero padding included
    for (u32 i = cap; i < n; ++i) {
        const u32 r = i - cap;
        ext[r / SLOTS_PER_EXT_WORD] |= u64(kinds[i] & 3u) << (2 * (r % SLOTS_PER_EXT_WORD));
    }
}
inline u64* customExtWordsMut(Custom* c) { return reinterpret_cast<u64*>(&c->values[c->header.size]); }
inline u64* recordExtWordsMut(Record* r) { return reinterpret_cast<u64*>(&r->values[r->header.size]); }

// The validate census of 3A.8 uses the test switch Elm::testing::allow_wide_objects
// (§S.6; defined here by Phase 1, deleted in 3D.3).
```

**Monotonicity proof.** For n ≤ cap, f(n) = n. For m = n − cap ≥ 1, f = cap + m + ⌈m/32⌉, and
f(m+1) − f(m) ∈ {1, 2}, so f is strictly increasing. Write m = 32q + r with r ∈ [1, 32]; then
⌈m/32⌉ = q + 1 and w = 33q + r + 1 ∈ [33q+2, 33q+33]. The image skips exactly w ≡ 1 (mod 33), and
the inverse above is exact. The 3A.9 unit test checks it exhaustively for n ∈ [0, 2047] with
both caps.

**Static asserts** (Heap.hpp):

```cpp
static_assert(extWords(CUSTOM_MAX_FIELDS, CUSTOM_HDR_SLOTS) == 63, "Custom K must fit Header.unboxed:6");
static_assert(extWords(RECORD_MAX_FIELDS, RECORD_HDR_SLOTS) == 63, "Record K must fit Header.unboxed:6");
static_assert(sizeof(Custom) + (CUSTOM_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Custom stays below born-old LOT"); // 16840
static_assert(sizeof(Record) + (RECORD_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Record stays below born-old LOT"); // 16896
```

The 32 KiB is `GroupLargeObjectThreshold` (`runtime/src/codegen/Passes/EcoGCPrepare.cpp:108`). The
codegen tree can't include it here, so the number is repeated with a comment naming it.

**Test:** 3A.9 T1 and T2. **Rollback:** restore the Phase 1 bodies; delete the new helpers.

### 3A.2 Object size: `getObjectSizeFromHeader`

**File:** `runtime/src/allocator/AllocatorCommon.hpp:491-496`, function `getObjectSizeFromHeader`
(starts `:448`). This file has a census pin (M3, M4), but the edit adds no concurrency line, so the
census hash is unchanged.

```cpp
// before
case Tag_Custom:
    size = sizeof(Custom) + hdr->size * sizeof(Unboxable);
    break;
case Tag_Record:
    size = sizeof(Record) + hdr->size * sizeof(Unboxable);
    break;
// after (I1: still header-only; K = hdr->unboxed is in the same word as tag/size)
case Tag_Custom:
    size = sizeof(Custom) + (size_t(hdr->size) + hdr->unboxed) * sizeof(Unboxable);
    break;
case Tag_Record:
    size = sizeof(Record) + (size_t(hdr->size) + hdr->unboxed) * sizeof(Unboxable);
    break;
```

`getObjectSize(obj)` (`AllocatorCommon.hpp:573`) forwards to it.

**Callers that inherit this with no change:**
- parallel and region copiers (`NurseryParallel.cpp:258`, `NurseryRegion.cpp:452`);
- the serial copy;
- `PermanentSpace.cpp` (deep copy uses `getObjectSize`, `:81`, `:89` of the `eco_caf_promote`
  body);
- compaction and sweep walkers (`OldGenSpace.cpp:5730`, `:5910`, `:5935`).

**Test:** 3A.9 T2 checks `getObjectSize == 16 + 8(n+K)`. **Rollback:** revert the two arms.

### 3A.3 `initHeaderForTag`: invert W, write the header once, zero ext words

**File:** `runtime/src/allocator/ThreadLocalHeap.cpp:126-165` (`void initHeaderForTag(Header*, Tag,
size_t)`), declared at `ThreadLocalHeap.hpp:24`.

Every runtime path that sizes by bytes reaches it:
- `eco_alloc_with_roots` fast path (`RuntimeExports.cpp:173`) and slow path (via `allocateSlow`);
- `ThreadLocalHeap::allocate` (`ThreadLocalHeap.cpp:277`, `:288`, `:303`);
- `allocateSlow` (`:350`, `:358`);
- `:515`;
- old-gen direct (`:605`);
- YLOS (`OldGenSpace.cpp:7710`);
- `RuntimeExports.cpp:673`.

```cpp
// before (:147-152)
case Tag_Custom:
    hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
    break;
case Tag_Record:
    hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
    break;
// after
case Tag_Custom:
case Tag_Record: {
    const bool isC = tag == Tag_Custom;
    const size_t base = isC ? sizeof(Custom) : sizeof(Record);
    const u32 cap  = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    const u32 maxN = isC ? CUSTOM_MAX_FIELDS : RECORD_MAX_FIELDS;
    const u32 W = static_cast<u32>((size - base) / sizeof(Unboxable));
    u32 n = 0, k = 0;
    if (!splitPhysicalSlots(W, cap, n, k) || n > maxN)
        ecoFatalWideObject(isC ? "initHeaderForTag(Custom)" : "initHeaderForTag(Record)", W);
    h.size = n;
    h.unboxed = k;
    if (k) std::memset(reinterpret_cast<char*>(hdr) + base + size_t(n) * 8, 0, size_t(k) * 8);  // I2
    break;
}
```

**Whole-word header** (overview §2.1.1). Restructure the function so all tags fill a
local `Header h{}` (`h.tag = tag;` then the switch writes `h.size` / `h.unboxed`), and end with one
8-byte store `std::memcpy(hdr, &h, sizeof(Header));`. `zeroNewObject(hdr, size)` stays first, so the
validate-build full-object zeroing is unchanged. Other tags' arms change only from `hdr->` to `h.`.

**`ecoFatalWideObject`** (new): `[[noreturn]] void ecoFatalWideObject(const char* where, u32 n);`,
declared in `ThreadLocalHeap.hpp` next to `initHeaderForTag` and defined in `ThreadLocalHeap.cpp`.
It prints `"[eco] FATAL: %s: %u slots exceeds the wide-object limit (HEAP_019)"` and calls
`std::abort()`. It is a release-mode abort.

**Header word consistency:** `Header.unboxed` is the bitfield at shift 10 (`EcoToLLVMInternal.h:316`
`HeaderUnboxedShift`). `testHeaderWordComposition` (`test/allocator/HPointerLayoutTest.cpp`) already
pins it; add one case with `unboxed = 63`, `tag = Tag_Record`.

**Test:** T1, T2; existing unit suite. **Rollback:** revert the function.

### 3A.4 YLOS header fix-up as one whole-word store

**File:** `runtime/src/allocator/OldGenSpace.cpp:7699-7726` (`OldGenSpace::allocateYoungLarge`).
This is not a TLA region (`OGS.promoteYoungLarge` starts at `:7729`).

```cpp
// before (:7708-7713)
const u32 saved_color = hdr->color;
initHeaderForTag(hdr, tag, size);
hdr->color = saved_color;
hdr->pin = 1;
hdr->age = 0;
// after
const u32 saved_color = hdr->color;
initHeaderForTag(hdr, tag, size);            // size/K/ext words (3A.3)
Header h = loadHeaderRelaxed(hdr);
h.color = saved_color; h.pin = 1; h.age = 0;
storeHeaderRelaxed(hdr, h);                  // one word: never a transient size without K
```

`loadHeaderRelaxed` / `storeHeaderRelaxed` are at `AllocatorCommon.hpp:593-600`. The call line
contains no census-regex token (`check-tla-manifest.sh:75`), so the OldGenSpace census hash is
unchanged.

**Same pattern, as hygiene with no concurrent reader:** the old-gen direct path
`ThreadLocalHeap.cpp:600-610`.

**Rollback:** revert.

### 3A.5 Explicit allocation entries (runtime) and their release aborts

Every entry below sets `size = n` and `unboxed = K`, sizes with `n + K`, and zeroes the K ext words.
A shared helper goes in `ThreadLocalHeap.hpp`, inline:

```cpp
// For entries that do NOT go through initHeaderForTag (they write the header themselves).
inline void initWideHeader(Header* hdr, Tag tag, u32 n) {
    const bool isC = tag == Tag_Custom;
    const u32 cap = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    if (n > (isC ? CUSTOM_MAX_FIELDS : RECORD_MAX_FIELDS)) ecoFatalWideObject("alloc", n);
    const u32 k = extWords(n, cap);
    const size_t base = isC ? sizeof(Custom) : sizeof(Record);
    zeroNewObject(hdr, base + size_t(n + k) * 8);
    Header h{}; h.tag = tag; h.size = n; h.unboxed = k;
    std::memcpy(hdr, &h, sizeof(Header));
    if (k) std::memset(reinterpret_cast<char*>(hdr) + base + size_t(n) * 8, 0, size_t(k) * 8);
}
inline size_t wideByteSize(Tag tag, u32 n) {
    const bool isC = tag == Tag_Custom;
    return (isC ? sizeof(Custom) : sizeof(Record))
         + size_t(n + extWords(n, isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS)) * 8;
}
```

| Entry (file:line) | Change |
|---|---|
| `eco_alloc_custom` `RuntimeExports.cpp:247-265` | `size = wideByteSize(Tag_Custom, field_count)` (plus `scalar_bytes` until 3A.10); the header comes from `initHeaderForTag` through `eco_alloc_with_roots` (`:258`); keep `ctor` / `unboxed = 0` |
| `eco_alloc_custom_fast` `:1391-1411` | size as above; replace `zeroNewObject` + `hdr->tag` + `hdr->size = …` (`:1402-1405`) with `initWideHeader(hdr, Tag_Custom, field_count)` |
| `eco_alloc_custom_slow` `:1413-1428` | size as above (`allocateSlow` → `initHeaderForTag`) |
| `eco_alloc_record` `:450-462` | `size = wideByteSize(Tag_Record, field_count)`; keep `rec->header.size = field_count` (equal by inversion; add `assert(rec->header.unboxed == extWords(field_count, 32))`) |
| `eco_alloc_record_fast` `:1565-1578` | `initWideHeader(hdr, Tag_Record, field_count)` replaces `:1570-1573` |
| `eco_alloc_record_slow` `:1580-1590` | size via `wideByteSize` |
| `eco_init_record_at` `:1894-1902` | `initWideHeader(getHeader(obj), Tag_Record, field_count)`. **Precondition** (comment): the codegen group region reserved `wideByteSize` bytes. True in 3A since n ≤ 32 ⇒ K = 0; 3B.3 updates `getFixedAllocSizeForGrouping` |
| `eco_init_custom_at` `:1904-1913` | `initWideHeader(…, Tag_Custom, field_count)` (same precondition) |

`unboxed_bitmap` arguments: the u64 still sets the header word (Record slots 0..31). Ext words stay
zero (boxed) until Phase 3B codegen stores them after the call in the same no-safepoint window. This
is GC-safe: no GC can run between the runtime return and those stores (HEAP_031), and zero means
boxed over not-yet-written fields that are zero or stale. In Phase 3A no compiled object has K > 0.

**Kernel / runtime builders that size by bytes** need no code change. They go through
`eco_alloc_with_roots` → `initHeaderForTag` with n ≤ 9, so K = 0.

| File | Lines | Note |
|---|---|---|
| `elm-kernel-cpp/src/json/JsonExports.cpp` | 126, 149, 165, 207, 220, 233, 248, 301, 380, 398, 422, 491, 704, 717, 734, 753, 1555 (`buildMapDecoder`, n ≤ 9, sets `header.size` explicitly), 1743, 1759, 1783, 1796, 1814, 1835, 1847, 1863, 1882, 1894, 1933, 1983 | |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp` | 447, 717, 742, 760, 780, 802, 824 | |
| `runtime/src/main.cpp` | 319, 353 | demo, Record |

Explicit `header.size = 1` writes (`JsonExports.cpp:208`, `:221`, `:234`, `:250`, `:400`) keep
K = 0. Verified by the 3A.8 census in the validate E2E run.

**Rollback:** revert per entry.

### 3A.6 Builders `custom()` / `record()` take a u8 kinds vector

**File:** `runtime/src/allocator/HeapHelpers.hpp:1433-1469` (`custom`) and `:1528-1555` (`record`).
Today they take a `u64 unboxed_mask`. Phase 1 made their rooting chunked (B8).

**New primary signatures:**

```cpp
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, const std::vector<u8>& kinds);
inline HPointer record(const std::vector<Unboxable>& values, const std::vector<u8>& kinds);
```

**Body (`custom`; `record` is analogous with `Tag_Record`, `RECORD_HDR_SLOTS` and `emptyRecord()`
for n = 0):**

```cpp
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, const std::vector<u8>& kinds) {
    const u32 n = static_cast<u32>(values.size());
    assert(kinds.size() == n);
    if (n == 0) { /* unchanged HEAP_044 null-cons branch (today :1435-1442) */ }
    if (n > CUSTOM_MAX_FIELDS) ecoFatalWideObject("alloc::custom", n);
    const size_t total = wideByteSize(Tag_Custom, n);
    std::vector<uint64_t> roots(n);
    for (u32 i = 0; i < n; ++i) std::memcpy(&roots[i], &values[i], 8);
    const size_t saved = eco_gc_stack_range_point();
    pushRootsByKinds(roots.data(), n, [&](u32 i) { return u32(kinds[i]); });   // §S.2, chunked
    auto* obj = static_cast<Custom*>(eco_alloc_with_roots(Tag_Custom, total, nullptr, 0, 0));
    eco_gc_restore_stack_range_point(saved);
    // initHeaderForTag set size = n, unboxed = K and zeroed the ext words (3A.3).
    obj->ctor = ctor;
    obj->unboxed = packHeaderKinds(kinds.data(), n, CUSTOM_HDR_SLOTS);
    packExtKinds(kinds.data(), n, CUSTOM_HDR_SLOTS, customExtWordsMut(obj));
    for (u32 i = 0; i < n; ++i) std::memcpy(&obj->values[i], &roots[i], 8);
    return Allocator::instance().wrap(obj);
}
```

- The `obj->unboxed = …` write needs `packHeaderKinds` to return < 2^48 for Custom; assert
  `(w >> 48) == 0` (n capped by `CUSTOM_HDR_SLOTS`).
- Keep the **u64 overloads** with their current signatures for the existing callers. They expand the
  mask into `kinds[i] = i < HDR ? (mask >> 2i) & 3 : 0` and forward:
  - `eco-kernel-cpp/src/eco-kernel/Process.cpp`;
  - `elm-kernel-cpp/src/browser/Browser.cpp` (6);
  - `bytes/Bytes.cpp`;
  - `core/PlatformExports.cpp` (3);
  - `json/JsonExports.cpp`;
  - `virtual-dom/VirtualDom.cpp`;
  - `test/allocator/MinorWorkload.hpp` (2), `NurserySpaceTest.cpp` (3), `P1CensusTest.cpp`.

  Their shift happens only for i < 24 / 32, so no UB.
- Delete the "up to 24 fields, 48 bits" / "up to 32 fields" comments (`:1431`, `:1527`).
- Delete Phase 1's narrow-width assert in both builders (`testing::allow_wide_objects || n <= CAP`):
  from this step the builders lay out wide objects themselves.

**Test:** T2 builds every size through these builders. **Rollback:** revert; the overloads keep
callers compiling either way.

### 3A.7 Walkers, equality, printers, test oracles: the tail loops read kinds

Phase 1 split every Custom/Record walker into a header loop `i < min(size, CAP)` plus a tail loop
over `[CAP, size)` that treats each slot as boxed. **Phase 3A changes only the tail loop's kind** to
`customSlotKind(c, i)` / `recordSlotKind(r, i)`. The header loop stays as it is: the fast path for
small objects (I3).

Tail loop shape:

```cpp
for (u32 i = CUSTOM_HDR_SLOTS; i < hdr->size; ++i)          // cold: dead unless K > 0
    if (customSlotKind(c, i) == 0) visit(c->values[i].p);
```

Sites (pre-P1 anchors; each has a Custom arm and a Record arm):

| # | File:line | Function | TLA |
|---|---|---|---|
| W1 | `runtime/src/allocator/HeapChildWalk.hpp:68-79` | `visitHeapChildren` (users `NurseryParallel.cpp:874`, `ThreadLocalHeap.cpp:1411`, `OldGenSpace.cpp:4070`, `PermanentSpace.cpp:144/182`, `NurserySpace.cpp:1841`) | unpinned |
| W2 | `runtime/src/allocator/NurseryChildWalk.hpp:36-47` | `forEachChildSlot` (tenure / region / CR-038 zap users) | unpinned |
| W3 | `runtime/src/allocator/NurserySpace.cpp:890-903` | validate pre-walk | unpinned |
| W4 | `NurserySpace.cpp:1068-1081` | validate old→young walk | unpinned |
| W5 | `NurserySpace.cpp:1899-1918` | `NurserySpace::scanObject` (serial minor) | unpinned |
| W6 | `runtime/src/allocator/NurseryParallel.cpp:500-508` | `scanEntryP` | **region `NP.scanEntryP` (M3)** |
| W7 | `runtime/src/allocator/OldGenSpace.cpp:3580-3592` | `scanChildren` (all mark modes) | unpinned |
| W8 | `OldGenSpace.cpp:7386-7398` | compaction fixup | unpinned |
| W9 | `test/allocator/HeapSnapshot.hpp:127-145`, `:299-317` | test oracle (B17) | n/a |
| W10 | `test/allocator/MinorWorkload.hpp:139-153` | test hash oracle (B17) | n/a |

**No change:**
- Prefetch arms that only touch slots < 4: `NurseryParallel.cpp:215-219` (`NP.MinorEnv`) and
  `NurseryRegion.cpp:395-399` (`NR.RegionEnv`).
- Fixed small indices: `RuntimeExports.cpp:3228`, `:3279`, `:3827`, `:4201`; `ListOps.cpp:247`;
  `Utils.cpp:764-772`; `File.cpp:72`, `:86`. All indices are < 4 and read the header bitmap. With
  Phase 1's accessor conversion they need no change.

**Equality and printers.** Phase 1 converted the loops to the accessors; Phase 3A needs no edit
there. Re-verify they call the accessor, not `fieldKind`:
- `elm-kernel-cpp/src/core/Utils.cpp:652-677` (`eqHelp`, Custom and Record arms);
- `RuntimeExports.cpp:3382-3415` (`print_custom`), `:3423-3440` (`print_record`);
- the typed record printer `:3979-4025` (it snapshots `uint64_t unboxed = record->unboxed` at
  `:3986`, which must become `recordSlotKind(record, i)`);
- the typed custom printer `:4100-4130`.

**Rollback:** revert the tail-loop kind expressions to `0`.

### 3A.8 Validation: K, padding, and the inertness census

There is no `validateBitmapSlotKind` to extend: it is a **disabled no-op**
(`NurserySpace.cpp:1725-1736`, "disabled — see comment above"). So add a new validate-only checker
in `runtime/src/allocator/AllocatorCommon.hpp`, next to `getObjectSize`:

```cpp
#if ECO_HEAP_VALIDATE
// HEAP_019 / HEAP_077: K and padding of a Custom/Record; and (Phases 3A–3C) the inertness census.
inline void validateExtKinds(const void* obj, const char* where) {
    const Header* h = static_cast<const Header*>(obj);
    if (h->tag != Tag_Custom && h->tag != Tag_Record) return;
    const bool isC = h->tag == Tag_Custom;
    const u32 cap = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    const u32 k = extWords(h->size, cap);
    const u64* ext = isC ? customExtWords(static_cast<const Custom*>(obj))
                         : recordExtWords(static_cast<const Record*>(obj));
    bool bad = h->unboxed != k;
    if (!bad && k) {
        const u32 used = (h->size - cap) - (k - 1) * SLOTS_PER_EXT_WORD;     // slots in last word, 1..32
        if (used < 32 && (ext[k - 1] >> (2 * used)) != 0) bad = true;       // padding bits must be 0
    }
    if (!bad && k && !testing::allow_wide_objects) bad = true;                    // census: compiled objects are narrow
    if (bad) {
        std::fprintf(stderr, "[heap-validate] %s: %s %p size=%u unboxed(K)=%u expected K=%u allowed=%d\n",
                     where, isC ? "Custom" : "Record", obj, h->size, h->unboxed, k, int(testing::allow_wide_objects));
        std::abort();
    }
}
#endif
```

**Calls** (all `#if ECO_HEAP_VALIDATE`):
- the W3 pre-walk Custom/Record arms (`NurserySpace.cpp:890`, `:898`);
- the W5 `scanObject` arms (`:1899`, `:1910`);
- the W7 `scanChildren` arms (`OldGenSpace.cpp:3580`, `:3587`).

None of these is in a TLA region. The census line holds only while compiled code emits no wide
object. From 3B on, `EcoRunner` sets `Elm::testing::allow_wide_objects` for fixture modules that
carry `eco.allow_wide_objects` (3B.2.6, §S.6). 3D.3 deletes the flag and this census line.

**Pins:**
- T8: death test, validate tree only. Build a K > 0 Custom with `testing::allow_wide_objects = false`,
  run a minor, expect abort with `"[heap-validate]"`.
- Every other wide test sets `testing::allow_wide_objects = true` in its setup and restores it after.

**Rollback:** remove the checker and its calls.

### 3A.9 Unit tests: `test/allocator/WideObjectTest.cpp` (new)

**Register:**
- `void registerWideObjectTests(Testing::TestSuite&)` in `WideObjectTest.hpp`;
- `#include` and call in `test/main.cpp` (pattern: `main.cpp:46`, `:995`);
- add the source to `test/CMakeLists.txt` next to `allocator/GenericApplyBoxingTest.cpp` (`:104`).

**Common helpers in the file:**
- `kindsPattern(n, cap)`: `k[i] = (i * 7 + 3) % 4`, forced to 0 at `cap-1`, `cap`, `cap+31`,
  `cap+32`, `n-1` and to 1/2/3 at their neighbours, so every kind sits on both sides of each word
  boundary;
- a fill that stores boxed slots as fresh young `ElmInt`s holding `1000 + i` (`alloc::allocInt`),
  Int slots `i * 3`, Float `i + 0.5`, Char `(i % 26) + 'a'`;
- a `checkWide(obj, n, cap)` that reads every slot back through the accessors and compares;
- the `WideGuard` RAII: sets `testing::allow_wide_objects = true` and restores it.

**Heap configs** (all through `initAllocator(cfg)` / `initRegionAllocator(cfg)`,
`test/allocator/TestHelpers.hpp:36`, `:41`; unit tests ignore `ECO_HEAP_CONFIG`):

```cpp
HeapConfig wideSmall(u32 divisor) {         // = LargePtrPlacementTest.cpp:48 smallConfig
    HeapConfig c; c.alloc_buffer_size = 32*1024; c.nursery_block_count = 4; c.nursery_max_block_count = 4;
    c.initial_old_gen_size = 256*1024; c.max_heap_size = 256ULL<<20; c.large_object_threshold = 8*1024;
    c.large_ptr_nursery_divisor = divisor;  // 0 = every pointer-bearing large object is a YLOS
    c.decommit_on_oldgen_release = false; c.gc_thread_mode = 0; c.validate(); return c;
}
// nursery-large: wideSmall(2) with c.large_ptr_nursery_max_size = 64*1024 (objects <= cap stay in the nursery)
// parallel minor: wideSmall(2) with c.gc_minor_threads = 4, c.minor_parallel_min_bytes = 0
// region mode + concurrent tenuring, k = 2: copy ConcurrentTenureTest.cpp:36-58 tenureConfig and set
//   c.promotion_age = 2 (validate() accepts 1..3 for nursery_regions = 1, AllocatorCommon.hpp:969)
// concurrent mark t0: c.conc_mark = 2, gc_mark_threads = 1, conc_mark_threads = 1, conc_mark_priority = 0
//   (ConcurrencyRegisterTest.cpp:1720 cr017ConcConfig); use holdNextCycle / waitBackground from
//   ConcurrentMarkTest.cpp:125 / :137 (copy them into the file's anonymous namespace)
```

| Test name | Body | Expected |
|---|---|---|
| T1 `wide: splitPhysicalSlots inverts n + extWords` | for cap ∈ {24, 32}, n ∈ [0, 2047]: `split(n + extWords(n,cap))` gives `(n, extWords)`; and for every W ∈ [0, 2200] not in the image, `split` returns false | pass |
| T2 `wide: builders and accessors round-trip (Custom 25/56/1100/2040, Record 33/64/1100/2047)` | build through `alloc::custom` / `alloc::record` (kinds vector); check `header.size`, `header.unboxed`, `getObjectSize == 16 + 8(n+K)`, the accessors over all slots, padding = 0 | pass |
| T3 `wide: survive serial minors, promotion, major and compaction` | `wideSmall(2)`; root each of the 8 objects (`alloc.getRootSet().addRoot(&hp)`); 3× (`churn` + `alloc.minorGC()`); `alloc.majorGC()`; `OldGenSpaceTestAccess::scheduleCompaction(og)` + `alloc.majorGC()`; `checkWide` after each | pass; `minor_gc_count` rose by ≥ 3 and `major_gc_count` by ≥ 2 (`#if ENABLE_GC_STATS`; nursery `getStats()`, `GCStats.hpp:602`, `:1070`) |
| T4 `wide: parallel minor` | as T3 with the parallel-minor config | pass |
| T5 `wide: YLOS forced (1100/2040/2047 fields)` | `wideSmall(0)`: objects ≥ 8 KiB are YLOS; check `og.isYoungLarge(obj)`; minors age then promote in place (`LargePtrPlacementTest.cpp:303` pattern); a major | pass; `ogLp(alloc).ylos_allocs` ≥ 3, `ylos_promoted_in_place` ≥ 1 (`LargePtrPlacementTest.cpp:274` helpers) |
| T6 `wide: nursery-large placement` | nursery-large config, n = 1100 | `nurseryLp(alloc).nursery_allocs` ≥ 1; values survive the copy |
| T7 `wide: region mode with concurrent tenuring and promotion_age 2 (CR-038 zap path)` | region config; wide objects live across ≥ 4 minors, some made dead after the first age so the merge zap runs over them (`NurseryChildWalk` users) | pass; the region tenure counters in `GCStats` (`rg.*`) moved |
| T8 `wide: validate census aborts on a K>0 object when not allowed` (`#if ECO_HEAP_VALIDATE`) | fork; child builds Custom 30 with the guard **off**, `minorGC()` | child exits abnormally; stderr has `[heap-validate]` |
| T9 `wide: concurrent mark t0 snapshot over a wide YLOS` | conc config + `wideSmall(0)` placement; a wide YLOS reachable only from a young object at cycle start; `holdNextCycle`, a minor, release, `waitBackground`, major finish; `checkWide` | pass; `major_gc_count` rose |
| T10 `wide: CAF permanent copy` | `eco_caf_promote(bits, &slot)` (`PermanentSpace.hpp:85`) on a Record 64 and a Custom 56 (env `ECO_CAF_PERMANENT` unset = on) | the copy has the same `size` / `unboxed` / ext words / values; the original is unchanged |
| T11 `wide: equality` | `Elm::Kernel::Utils::equal` (`Utils.hpp:56`) on two identically built Custom 2040: true; flip an Int at slot 2039: false; flip kind only (Int vs boxed Int with the same value): true (`eqUnboxableSlot` semantics) | pass |
| T12 `wide: Debug.toString` | `eco_value_to_string(hp)` (`RuntimeExports.h:543`) on a Custom 30 and a Record 40 with mixed kinds; compare against an expected string built in the test with the printer's format (`print_custom` `Ctor%u` plus fields; `print_record` `{ f0 = …, … }`) | exact match |
| T13 `wide: release abort past limits` | fork; `alloc::custom(…, 2041 fields)`; fork; `alloc::record(…, 2048)`; fork; `eco_alloc_record(2048, 0)` | child aborts; stderr contains `exceeds the wide-object limit` |
| T14 `wide: small objects unchanged` | Custom 1..24, Record 1..32: `header.unboxed == 0`, `getObjectSize == 16 + 8n` | pass |

Death tests use the `fork()` + `waitpid` pattern of `test/allocator/ParallelMinorTest.cpp:440`.

**Commands (§S.7):**

```bash
cmake --build build --target test && ulimit -c 0 && build/test/test --filter "wide:" 2>&1 | tee /tmp/test_output.txt
cmake -S /work -B /work/build-validate -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DECO_HEAP_VALIDATE=ON   # if absent
cmake --build /work/build-validate --target test && ulimit -c 0 && /work/build-validate/test/test --filter "wide:" 2>&1 | tee /tmp/test_output_validate.txt
grep -E "FAIL|PASS|wide:" /tmp/test_output.txt | tail -40
```

**Expected:** T1–T7 and T9–T14 pass in both trees. T8 runs and passes only in the validate tree
(compiled out elsewhere).

### 3A.10 Delete `AllocateCtorOp` and `scalar_bytes` (one atomic commit)

Overview §2.1.2. No producer exists: `compiler/src` has no `allocate_ctor`, and in `runtime/src`
only its own lowering refers to it.

| File:line | Change |
|---|---|
| `runtime/src/codegen/Ops.td:1627-1666` | delete `Eco_AllocateCtorOp` |
| `runtime/src/codegen/EcoOps.cpp:351-362` | delete `AllocateCtorOp::verify` |
| `EcoOps.cpp:1002-1005` | delete `getGCRoots` / `setGCRoots` |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:172-176` | delete the `computeAllocSize` arm |
| `EcoToLLVMHeap.cpp:358-390` | delete the lowering |
| `EcoToLLVMHeap.cpp:1765-1775` | delete the group arm |
| `EcoToLLVMHeap.cpp:2178` | delete the pattern registration |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp:43` | drop from the predicate |
| `EcoGCPrepare.cpp:63` | drop from the predicate |
| `EcoGCPrepare.cpp:78-81` | drop the size arm |
| `runtime/src/codegen/Passes.h:29` | comment only |
| `RuntimeExports.cpp:247` `eco_alloc_custom`, `:1391` `eco_alloc_custom_fast`, `:1413` `eco_alloc_custom_slow`, `:1904` `eco_init_custom_at`; `RuntimeExports.h:82`, `:281`, `:296`, `:353` | drop the `uint32_t scalar_bytes` parameter and its size term; the HEAP_044 assert becomes `field_count > 0` |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:209-212` (`getOrCreateAllocCustom`), `:298-301` (`…Fast`), `:352-355` (`…Slow`), `:443-447` (`getOrCreateInitCustomAt`) | function types lose the last `I32_TY` |
| `EcoToLLVMHeap.cpp:1122` and `:1133` (`CustomConstructOpLowering` call path), `:1831-1834` (group construct), `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp:502-507` | drop the `scalarBytes` constant operand |
| tests: `test/allocator/RuntimeExportsTest.cpp:154`, `:258`, `:326`, `:345`, `:384`, `:403`, `:535`; `test/allocator/GCPressureTest.cpp:391`, `:770`, `:829`, `:858`, `:963` | drop the third argument |
| fixtures: delete `test/codegen/construct_scalar_bytes.mlir`, `allocate_ctor_minimal.mlir`, `allocate_ctor_max_size.mlir` (they test only this op); rewrite the 8 `eco.allocate_ctor` uses in `allocate_lowlevel.mlir` and the 1 in `dbg_all_values.mlir` as `eco.construct.custom` with the same fields, or drop those functions if they only exercise `allocate_ctor` | |

- `RuntimeSymbols.cpp` (`:34`, `:125`, `:167`, `:251`) binds by name and needs no change.
- This **is** a codegen ABI change inside a runtime phase. It must land in one commit, and the
  bootstrap gate covers the AOT side.
- **Alternative if the reviewer prefers 3A to stay runtime-only:** keep the parameter and add
  `if (scalar_bytes) ecoFatalWideObject("scalar_bytes", scalar_bytes);`, and do this table in Phase 3B.

**Build and test:** after this step `cmake --build build` (all runtime static libraries, §6.1),
then the full gate (3A gate below).

**Rollback:** revert the commit (self-contained).

---

### 3A TLA canary procedure (overview §5)

Expected to fire:
- **`NP.scanEntryP` (M3):** the tail-loop kind change in the `Tag_Custom` / `Tag_Record` arms
  (`NurseryParallel.cpp:500-508`).

Not expected:
- `NP.MinorEnv` / `NR.RegionEnv` are unchanged (their prefetch arms index slots < 4).
- `AllocatorCommon.hpp` and `OldGenSpace.cpp` census hashes are unchanged: no regex line is added
  (re-run to confirm).

Run once:

```bash
cmake --build build --target tla-canary 2>&1 | tee /tmp/test_output_tla.txt
grep -E "MISMATCH|pin|WARNING|new hash" /tmp/test_output_tla.txt
```

**For each fired pin's model (M3), plus voluntary entries in M1 and M5** (unpinned walkers W1, W2,
W5, W7, W8 and the YLOS fix-up), append to `test/tla/<model>/AUDIT.md`:

```markdown
## 2026-MM-DD — wide-object-tail-kind-words Phase 3A (Custom/Record ext kind words) (GC_MODEL_001)

Pin fired for M3: region `NP.scanEntryP`, new hash prefix **<12 hex>**.   <!-- M1/M5: "No pin fired; voluntary entry." -->

Change: Custom/Record objects may carry K = header.unboxed extension kind words after
values[size] (HEAP_019). Object size is still a function of the header word alone
(getObjectSizeFromHeader adds hdr->unboxed). The tail loop of the Custom/Record scan arms reads
the slot kind through customSlotKind / recordSlotKind (header bitmap, then the ext words, bounded by
header.unboxed). Ext words and K are written only at allocation, before the object is reachable by
any GC (HEAP_031/034/SNAPSHOT_001). The YLOS header fix-up is one relaxed whole-word store. No
atomic, lock, memory order, claim or publish is added; the header word is the same modelled
location; children are read from a frozen object.

**Verdict: no model change needed.**
```

Then `test/scripts/check-tla-manifest.sh . --update` (it refuses until M3's AUDIT quotes the prefix),
and the strict re-run:

```bash
cmake -S /work -B /work/build -DECO_TLA_CANARY_STRICT=ON && cmake --build build --target tla-canary 2>&1 | tee /tmp/test_output_tla.txt
```

After the group, run `tla-trace` M1/M3 once (overview §5):

```bash
cmake --build build --target tla-trace 2>&1 | tee /tmp/test_output_trace.txt
```

Expected: every accept row is accepted and every mutate row rejected.

---

### 3A gate

Run in this order. Each command runs **once**, with output tee'd (§S.7):
1. `cmake --build build` (all runtime libraries).
2. Unit tests, default tree: `build/test/test --filter "wide:"`, then the whole binary
   (`build/test/test 2>&1 | tee /tmp/test_output_unit.txt`). Expected: all pass, except E2E
   failures in the list below.
3. Unit tests, validate tree: the same two runs in `build-validate`. Expected: all pass,
   including T8.
4. `register-guards` (includes the TSan / fork arms). Expected: green, as at the end of Phase 2.
5. `tla-canary` strict (3A TLA canary procedure above).
6. **E2E:** cache wipe (§S.7), then `cmake --build build --target full`. The failures must equal
   **list L3** (top of this file) exactly, by name and reason. Nothing else may fail.
   `grep -E "FAIL" /tmp/test_output.txt | sort > /tmp/p3a_fail.txt` and compare with L3.
7. **E2E in the validate tree, once,** for the inertness census:
   `cmake --build /work/build-validate --target full 2>&1 | tee /tmp/test_output_validate_e2e.txt`,
   after the cache wipe. Expected: list L3 again, and **no `[heap-validate]` line** (every
   compiled Custom/Record has K = 0).
8. elm-tests: not affected (no Elm change). Skip unless 3A.10 touched shared fixtures. If run,
   the expected failures are the 2 GOPT_003 pins only.
9. **Bootstrap:** `bootstrap` + `eco-verify`, required because of 3A.10's codegen ABI change.
   Expected B==C.
10. **Perf triple** (`benchmarks/fe-opt-loop.md` §1). **Counters bit-identical to the Phase 2
    gate's** (no compiled object changed size; I3). Wall within the triple spread.

**3A is done when:** gate steps 1–10 hold; the AUDIT entries for M3 (fired) and M1/M5 (voluntary)
are committed; the 3A checklist is ticked.

---

### 3A gate result (recorded 2026-10-05)

- Gate 1–5 (implementer): ALL build clean (strict canary, LSS_022 license unchanged); default
  tree `wide:` 13/13 and the whole binary 2105 pass / 10 fail (L3); validate tree `wide:` 14/14 (T8
  included) and 2107 / 10 (L3); register-guards green; tla-canary strict. **No pin fired**: the
  Custom/Record arms of `NP.scanEntryP` already read kinds through the accessors since Phase 1d
  (only a comment changed, which the hash ignores); voluntary M1/M3/M5 AUDIT entries written;
  `tla-trace` 150/150.
- Gate 6: `full` after the cache wipe: 2,115 run, 2,105 pass, 10 fail = L3 exactly.
- Gate 7: validate-tree `full`: 2,117 / 10 = L3; the only `[heap-validate]` lines are the six
  existing negative-control tests (PM2–PM4, IM1, TV2) — none from `validateExtKinds`: every compiled
  Custom/Record has K = 0.
- AOT (3A.10 changed the allocation ABI): 922/934, identical to Phase 2 (L3 + FlagsRecordTest +
  PortEchoTest).
- Gate 9: bootstrap Stage 4b/8c fixed points hold; `eco-verify` rc 0.
- Gate 10 perf: `eco-optP3a` counters equal Phase 2's `eco-optP2b` (minor 1336, major 6; promoted
  and objects within the same run-to-run jitter), output byte-identical. Wall was +0.8 s (+1.1 %)
  interleaved: a profile showed `Elm::customSlotKind` had become an out-of-line call (0.70 % of
  samples) once the ext-word branch was added. **Fix:** the three slot-kind accessors are split
  into an `always_inline` header path and a `noinline, cold` ext-word path (`customExtSlotKind`,
  `recordExtSlotKind`, `closureExtSlotKind`). Re-measured interleaved, 3 runs each: P2b median
  69.00 s, P3a2 69.26 s (+0.4 %, within spread); unit `wide` 32/32, validate `wide` 33/33,
  `Closure` 48/48, `generic apply` 5/5 after the change.
- Deviations: 3A.6 builders share one template `detail::allocWideContainer` (the u64 path builds no
  vector); 3A.9 reads placement counters from the thread heap's stats and T11 flips the last
  ext-word Int slot; `HeapGenerators.cpp` got the narrow-only asserts (open question 3);
  `allocate_lowlevel.mlir` / `dbg_all_values.mlir` rewritten on `eco.construct.custom`, the three
  `allocate_ctor` fixtures deleted, the obsolete `test/codegen/TODO_*` planning checklists later deleted.

### 3A checklist

- [x] 3A.1 accessor bodies, `splitPhysicalSlots`, pack helpers, static_asserts, `testing::allow_wide_objects`, comments
- [x] 3A.2 `getObjectSizeFromHeader` Custom/Record arms
- [x] 3A.3 `initHeaderForTag` inversion, single header store, ext zeroing, `ecoFatalWideObject`; `testHeaderWordComposition` case
- [x] 3A.4 YLOS whole-word fix-up (plus the old-gen direct path)
- [x] 3A.5 the eight explicit entries; `initWideHeader` / `wideByteSize`
- [x] 3A.6 builders with kinds vectors; u64 overloads forwarding
- [x] 3A.7 tail loops W1–W10 read kinds; equality / printers verified on accessors (typed record printer `:3986`)
- [x] 3A.8 `validateExtKinds` plus calls; census flag
- [x] 3A.9 `WideObjectTest.cpp` T1–T14 registered
- [x] 3A.10 `AllocateCtorOp` / `scalar_bytes` removed; fixtures and tests updated
- [x] TLA: M3 AUDIT + manifest update; M1/M5 voluntary entries; trace run
- [x] Gate 1–10 green

### 3A rollback

- Steps 3A.1–3A.9 are runtime and test only. Revert them in reverse order; compiled code never depends
  on K > 0 in this phase.
- 3A.10 is one self-contained commit; revert it alone (it restores the op, the fixtures and the
  ABI parameter).
- Snapshot or tag the tree before the perf triple (overview §7).

### 3A open questions (with defaults; none blocks)

1. **Should 3A.10 move to Phase 3B** to keep Phase 3A runtime-only? Default: keep it in Phase 3A as one
   commit. Use the alternative in 3A.10 only if a reviewer objects.
2. **Ext-word zeroing in the explicit entries duplicates the codegen stores Phase 3B adds.** Default:
   keep it. It costs nothing for K = 0 and makes runtime-only callers safe.
3. **Should the old-gen test generator** (`test/allocator/HeapGenerators.cpp:355-366`
   `allocInOldGen`, which sets `hdr->unboxed = 0` and `hdr->size` by hand at `:468` / `:487`) also
   produce wide objects? Default: no. Its sizes are capped by `gen::resize(20, …)`
   (`HeapGenerators.hpp:220-227`), so K = 0 always. Add
   `assert(num_values <= 24 /* Custom */ / 32 /* Record */)` with a comment pointing to
   WideObjectTest.

---

## 3B. Custom/Record lowering and dialect

The names `slotKindOf`, `packKinds`, `extWords`, `slot_kinds` and the test switch are §S
definitions.

### 3B.0 Scope and preconditions

At the end of 3B, the lowering can build a Custom of up to 2040 fields and a Record of up
to 2047, each with every field unboxed:
- K = `extWords(n, 24|32)` extension kind words after the last field;
- a header word composed as `tag | K<<10 | n<<32`;
- a byte size of `16 + 8(n+K)`.

**What does not change yet:**
- The front end still emits `unboxed_bitmap` and stays within the 24/26 caps (Phase 3C).
- The verifier keeps the old caps for every module **except** one that carries the test-only module
  attribute `eco.allow_wide_objects` (§S.6; 3B.2.5 explains why it is a module attribute).

So production output has K = 0 everywhere, and LLVM IR for today's programs must come out
**identical**.

**Preconditions (from 3A, Phase 1 and Phase 2; check them before starting):**

| # | Precondition | Check |
|---|---|---|
| 3A-a | The runtime entries `eco_alloc_record(field_count, bitmap)`, `eco_alloc_custom(tag, field_count, 0)`, `eco_init_record_at(ptr, field_count, bitmap)` and `eco_init_custom_at(ptr, tag, field_count, 0)` compute `K = extWords(field_count, HDR)` themselves: they allocate `16 + 8(n+K)` bytes, set `header.size = n` and `header.unboxed = K`, and **write all K ext words as 0**. Their C signatures are **unchanged**, so codegen declarations in `EcoToLLVMRuntime.cpp` (`eco_alloc_record` at :203, `eco_init_record_at` at :438) stay as they are | read `RuntimeExports.cpp` after Phase 3A |
| 3A-b | `eco_store_field_i64` (`RuntimeExports.cpp:2009`, Custom arm stores `values[index]` with no bound) and `eco_store_record_field_i64` (`:473`) accept `index` in `[0, size+K)`. Phase 3B writes ext word `j` with `index = n + j`. If Phase 3A added an `index < header.size` assert, widen it to `index < header.size + header.unboxed` | grep both functions |
| 3A-c | `getObjectSize` for Custom/Record is `16 + 8*(size + unboxed)`, and the GC walkers and validate checks read ext words through `customSlotKind` / `recordSlotKind` | `AllocatorCommon.hpp` getObjectSize |
| 3A-d | `AllocateCtorOp` / `scalar_bytes` are deleted (overview §2.1.2). If they are not, leave the `AllocateCtorOp` arms in `computeAllocSize`, `getFixedAllocSizeForGrouping` and `emitInitAtPtr` untouched (they always have `scalar_bytes = 0` and never more than 24 fields) | grep `AllocateCtorOp` |
| P1-a | B14: the construct verifiers reject `i1` operands. B7: `kindBitmapFor` is bounded | `EcoOps.cpp` CustomConstructOp::verify / RecordConstructOp::verify |
| P2-a | `slot_kinds` exists on the closure ops, with Phase 2's file-static `operandKind` and `verifyClosureKinds` in `EcoOps.cpp` (step 2.1). 3B.2.2 reuses `operandKind` and adds `verifySlotKinds` beside it | grep `slot_kinds`, `operandKind` in `EcoOps.cpp` |
| P1-b | Phase 1 added `layout::CustomHdrSlots` / `RecordHdrSlots`, `slotKindOf`, `PackedKinds` and `packKinds` to `EcoToLLVMInternal.h` (§S.3). 3B.1 adds only what is missing | grep `packKinds` in `EcoToLLVMInternal.h` |

### 3B.I Inventory: every site this group touches (from grep, 2026-10-05)

#### 3B.I.1 Readers of the old `unboxed_bitmap` on construct.custom / construct.record / to_heap

Command:
`grep -n -E "getUnboxedBitmap|unboxed_bitmap|kindBitmapFor" runtime/src/codegen/{EcoOps.cpp,Passes/*.cpp}`,
ignoring tuples, closures and PAPSimplify.

| # | File:line | Function | Role |
|---|---|---|---|
| RD1 | `runtime/src/codegen/EcoOps.cpp:395` | `CustomConstructOp::verify` (364–436) | bitmap ⇔ operand kinds |
| RD2 | `EcoOps.cpp:465` | `RecordConstructOp::verify` (438–508) | same |
| RD3 | `Passes/EcoToLLVMHeap.cpp:946` | `RecordConstructOpLowering::matchAndRewrite` (926–1022) | meta word (inline) and `eco_alloc_record` argument (call path) |
| RD4 | `EcoToLLVMHeap.cpp:1100` | `CustomConstructOpLowering::matchAndRewrite` (1072–1180), inline path | meta word `tag \| bitmap<<16`, plus `assert(bitmap>>48 == 0)` |
| RD5 | `EcoToLLVMHeap.cpp:1168` | same, call path | `eco_set_unboxed(obj, bitmap)` |
| RD6 | `EcoToLLVMHeap.cpp:1820` | `emitInitAtPtr` (1734–1837), record arm | `eco_init_record_at(ptr, n, bitmap)` |
| RD7 | `EcoToLLVMHeap.cpp:1932` | `emitFieldStoresForOp` (1840–1940), custom arm | `eco_set_unboxed(hptr, bitmap)` |
| RD8 | `Passes/EcoToLLVMValueAgg.cpp:378-379` | `ToHeapOpLowering::matchAndRewrite` (198ff), record arm (374–456) | `mask = op.getUnboxedBitmap(); if 0 → kindBitmapFor` |
| RD9 | `EcoToLLVMValueAgg.cpp:461-462` | same, custom arm (457–549) | same, and `eco_set_unboxed` at 541–546 |
| RD10 | `EcoToLLVMValueAgg.cpp:231`, `:310` | same, tuple2/tuple3 arms | they read `to_heap`'s `unboxed_bitmap`, so they change **only** because the attribute's accessor type changes (3B.2.1) |
| RD11 | `EcoToLLVMValueAgg.cpp:77-87` | `kindBitmapFor` | deleted once RD8–RD10 and make.closure (`:796`, moved by Phase 2) no longer call it |

No other C++ reader exists:
- `create<RecordConstructOp|CustomConstructOp>` occurs nowhere;
- `create<ToHeapOp>` occurs only in `EcoToLLVMHeap.cpp:2161` (`materialiseAsBoxed`, no attributes);
- `setAttr("unboxed_bitmap"…)` occurs only at `EcoPAPSimplify.cpp:536` (closure, Phase 2).

Elm emitters are untouched in this phase (Phase 3C).

#### 3B.I.2 Size computations for Custom/Record (all become `16 + 8*(n + K)`)

| # | File:line | Function |
|---|---|---|
| S1 | `Passes/EcoToLLVMHeap.cpp:184-191` | `computeAllocSize` (168–198), record and custom arms. Its total also drives the group region at `:1960` (`lowerOneAllocGroup`) |
| S2 | `Passes/EcoGCPrepare.cpp:90-97` | `getFixedAllocSizeForGrouping` (74–103). Documented as "Must agree with computeAllocSize". It feeds the group thresholds (`:377`, `:424`, `:504`) and `hasInlineSingletonLowering` (`:175-176`, `<= 4096`) |
| S3 | `EcoToLLVMHeap.cpp:957-959` | `RecordConstructOpLowering`, `recByteSize` (inline gate and size) |
| S4 | `EcoToLLVMHeap.cpp:1097-1099` | `CustomConstructOpLowering`, `cusByteSize` |
| S5 | `Passes/EcoToLLVMValueAgg.cpp:393-395` | to_heap record, `recByteSize` |
| S6 | `EcoToLLVMValueAgg.cpp:475-477` | to_heap custom, `cusByteSize` |

#### 3B.I.3 Every Custom/Record field-store emission (ext-word stores go right after each)

| # | File:line | Path |
|---|---|---|
| F1 | `EcoToLLVMHeap.cpp:968-973` | record inline (`emitFreshFieldStore`) |
| F2 | `EcoToLLVMHeap.cpp:988-1018` | record call path (`emitFreshFieldStore` under `inlineDerefExtEnabled()`, else `eco_store_record_field*` calls) |
| F3 | `EcoToLLVMHeap.cpp:1111-1116` | custom inline |
| F4 | `EcoToLLVMHeap.cpp:1138-1165` | custom call path, then `eco_set_unboxed` at 1167–1173 |
| F5 | `EcoToLLVMHeap.cpp:1854-1886` | group merge block, record (`eco_store_record_field*` calls on the hptr) |
| F6 | `EcoToLLVMHeap.cpp:1888-1937` | group merge block, custom (`eco_store_field*`, then `eco_set_unboxed`) |
| F7 | `EcoToLLVMValueAgg.cpp:403-408` | to_heap record inline |
| F8 | `EcoToLLVMValueAgg.cpp:425-453` | to_heap record call path |
| F9 | `EcoToLLVMValueAgg.cpp:489-494` | to_heap custom inline |
| F10 | `EcoToLLVMValueAgg.cpp:513-546` | to_heap custom call path, plus `eco_set_unboxed` |

**Projections are unchanged:**
- `RecordProjectOpLowering` `EcoToLLVMHeap.cpp:1028-1065` and `CustomProjectOpLowering`
  `:1184-1225` compute `FieldsOffset + 8*index` and never read kinds.
- The folders (`EcoOps.cpp`, project folds) are type-guarded.

### 3B.1 Shared codegen layout helpers

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`. Inside `namespace layout` (opens at
:341, `RecordBaseSize` / `CustomBaseSize` at :400–401), next to Phase 1's `CustomHdrSlots` /
`RecordHdrSlots`, add:

```cpp
// 3B (plans/wide-object-tail-kind-words-phase-3.md): extension kind words.
// CustomHdrSlots (24) / RecordHdrSlots (32) exist since Phase 1.
constexpr unsigned SlotsPerExtWord  = 32;   // == Elm::SLOTS_PER_EXT_WORD
constexpr uint64_t extWords(uint64_t n, unsigned hdr) {
    return n > hdr ? (n - hdr + SlotsPerExtWord - 1) / SlotsPerExtWord : 0;
}
constexpr uint64_t recordByteSize(uint64_t n) { return RecordBaseSize + (n + extWords(n, RecordHdrSlots)) * PtrSize; }
constexpr uint64_t customByteSize(uint64_t n) { return CustomBaseSize + (n + extWords(n, CustomHdrSlots)) * PtrSize; }
static_assert(recordByteSize(32) == 16 + 32 * 8 && recordByteSize(33) == 16 + 34 * 8);
static_assert(customByteSize(24) == 16 + 24 * 8 && customByteSize(60) == 16 + 62 * 8);
static_assert(extWords(2047, RecordHdrSlots) == 63 && extWords(2040, CustomHdrSlots) == 63);
```

After `namespace layout` (next to `emitFreshFieldStore`, :922), beside Phase 1's `slotKindOf` /
`packKinds` (§S.3), add:

```cpp
inline llvm::SmallVector<uint8_t> slotKindsOfTypes(mlir::TypeRange ts) {
    llvm::SmallVector<uint8_t> ks; ks.reserve(ts.size());
    for (mlir::Type t : ts) ks.push_back(slotKindOf(t));
    return ks;
}
// Store the K ext words of a fresh Custom/Record (HEAP_031/034 window: no safepoint since the
// allocation). Direct stores when the base is an AS1 fresh pointer; runtime i64 stores otherwise.
inline void emitExtKindWordStores(mlir::OpBuilder &b, mlir::Location loc, mlir::Value obj,
                                  uint64_t fieldsOffset, uint64_t n,
                                  llvm::ArrayRef<uint64_t> ext) {
    auto i64Ty = mlir::IntegerType::get(b.getContext(), 64);
    for (size_t j = 0; j < ext.size(); ++j) {
        mlir::Value w = b.create<mlir::LLVM::ConstantOp>(loc, i64Ty, static_cast<int64_t>(ext[j]));
        emitFreshFieldStore(b, loc, obj, fieldsOffset + (n + j) * layout::PtrSize, w, i64Ty);
    }
}
```

- **Zero words are stored too.** The runtime zero-fills ext words on the call path (3A-a), but the
  inline path writes nothing else, and `zeroNewObject` clears only the header (overview §2.1).
  `emitExtKindWordStores` therefore stores every word, including all-zero ones.
- **The out-of-line (A/B leg) call path** stores through
  `eco_store_record_field_i64(obj, n+j, w)` / `eco_store_field_i64(obj, n+j, w)` (3B.4.1).

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`. Next to the existing `static_assert`s
(:43–61), add:

```cpp
static_assert(eco::detail::layout::CustomHdrSlots  == Elm::CUSTOM_HDR_SLOTS);
static_assert(eco::detail::layout::RecordHdrSlots  == Elm::RECORD_HDR_SLOTS);
static_assert(eco::detail::layout::SlotsPerExtWord == Elm::SLOTS_PER_EXT_WORD);
static_assert(eco::detail::layout::recordByteSize(Elm::RECORD_MAX_FIELDS) < 32 * 1024,
              "wide records must stay below GroupLargeObjectThreshold (young, no barrier needed)");
static_assert(eco::detail::layout::customByteSize(Elm::CUSTOM_MAX_FIELDS) < 32 * 1024);
```

(Use the real namespace qualifier of `layout` in that file; the existing asserts use
`eco::detail::value_enc::…`.)

- **Invariants:** the codegen and runtime constants are pinned equal; the maximum objects are
  nursery-born (overview §2.1, "Size and placement").
- **Test:** compiles (the `static_assert`s run at build time).
- **Rollback:** delete the additions.

### 3B.2 Dialect (Ops.td, verifiers)

#### 3B.2.1 TableGen (`runtime/src/codegen/Ops.td`)

**`Eco_RecordConstructOp`** (`Ops.td:894`, arguments at :925–929). Before:

```tablegen
  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$field_count,
    I64Attr:$unboxed_bitmap
  );
```

After:

```tablegen
  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$field_count,
    // Legacy 2-bit kinds of slots 0..31; verified against operand types when present.
    // Removed in Phase 3D. The lowering derives kinds from operand types (CGEN_026).
    OptionalAttr<I64Attr>:$unboxed_bitmap,
    // One kind (0 boxed, 1 Int, 2 Float, 3 Char) per field; verified when present.
    OptionalAttr<DenseI8ArrayAttr>:$slot_kinds
  );
```

**`Eco_CustomConstructOp`** (`Ops.td:964`, `unboxed_bitmap` at :1005):
`DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap` becomes `OptionalAttr<I64Attr>:$unboxed_bitmap`,
and `OptionalAttr<DenseI8ArrayAttr>:$slot_kinds` is added after `$constructor`.

**`Eco_ToHeapOp`** (`Ops.td:3276`): `DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap` becomes
`OptionalAttr<I64Attr>:$unboxed_bitmap`, and `OptionalAttr<DenseI8ArrayAttr>:$slot_kinds` is added
(record/custom only; tuple2/3 keep using `unboxed_bitmap`).

**Descriptions:**
- At :897–912 and :969–987, replace the "Record's bitmap is 64 bits … capped at 26" and "48 bits wide
  (up to 24 fields …)" text with: kinds of slots 0..31 (Record) / 0..23 (Custom) go in the meta word,
  the rest in K = extWords(n, HDR) extension kind words after the last field (HEAP_019); kinds are
  derived from operand types by the lowering; `slot_kinds` / `unboxed_bitmap` are checks only.
- Update the `Ops.td:3259` to_heap text the same way.
- The examples keep `unboxed_bitmap = 0` (still legal).

**Accessor fallout:** `getUnboxedBitmap()` now returns `std::optional<uint64_t>` for all three ops.
Every R-site in 3B.I.1 is rewritten in the steps below, and nothing else calls it for these ops
(grep after building: `grep -rn "getUnboxedBitmap()" runtime/src/codegen` must show only the
tuple/closure ops and the RD10 sites).

#### 3B.2.2 Verifier helper (`runtime/src/codegen/EcoOps.cpp`, file-static, above `CustomConstructOp::verify`)

```cpp
// 3B. Test-only lift of the old Custom/Record caps (module attribute §S.6, NOT emitted by the
// compiler). Deleted in 3D.3.
static bool wideObjectsAllowed(Operation *op) {
  auto m = op->getParentOfType<ModuleOp>();
  return m && m->hasAttr("eco.allow_wide_objects");
}
// operandKind(Type) is Phase 2's file-static helper (step 2.1): i64->1, f64->2, i16->3, else 0.
// Checks the operand types of `slots` against `slot_kinds` (when present) and the legacy
// `unboxed_bitmap` (when present, slots < legacySlots only). `what` names the operand ("field").
static LogicalResult verifySlotKinds(Operation *op, ValueRange slots,
                                     std::optional<ArrayRef<int8_t>> kinds,
                                     std::optional<uint64_t> legacyBitmap,
                                     unsigned legacySlots, StringRef what) {
  if (kinds && kinds->size() != slots.size())
    return op->emitOpError("slot_kinds has ") << kinds->size()
           << " entries but there are " << slots.size() << " " << what << "s";
  for (unsigned i = 0; i < slots.size(); ++i) {
    Type t = slots[i].getType();
    uint8_t k = operandKind(t);
    if (k == 0 && !isa<eco::ValueType, eco::Tuple2Type, eco::Tuple3Type,
                        eco::RecordType, eco::CustomType, eco::ConsType>(t))
      return op->emitOpError(what) << " " << i << " has non-storable SSA type " << t
             << " (i1 must be boxed first, B14)";
    if (kinds) {
      int8_t want = (*kinds)[i];
      if (want < 0 || want > 3)
        return op->emitOpError("slot_kinds[") << i << "] = " << int(want) << " is not a kind (0..3)";
      if (uint8_t(want) != k)
        return op->emitOpError("slot_kinds[") << i << "] = " << int(want)
               << " does not match operand type " << t << " (kind " << int(k) << ")";
    }
    if (legacyBitmap && i < legacySlots) {
      uint64_t lk = (*legacyBitmap >> (2 * i)) & 3u;          // i < 32: defined
      if (lk != k)
        return op->emitOpError(what) << " " << i << " has kind=" << lk
               << " in unboxed_bitmap but SSA type " << t;
    }
  }
  if (legacyBitmap && legacySlots < 32 && slots.size() <= legacySlots &&
      (*legacyBitmap >> (2 * slots.size())) != 0)
    return op->emitOpError("unboxed_bitmap has bits set beyond the last ") << what;
  return success();
}
```

(The first "non-storable" check replaces the per-kind `switch` that Phase 1 extended with the B14
`i1` rejection. If Phase 1's message text differs, keep Phase 1's text so the B14 negative fixture
still matches.)

#### 3B.2.3 Rewrite the two verifiers

**`CustomConstructOp::verify` (`EcoOps.cpp:364-436`).**
- Keep the size-0 rejection (:369–374) and the operand-count check (:379–385).
- Replace the cap at :387–392 and the kind loop at :394–432 with:

```cpp
  const int64_t cap = wideObjectsAllowed(*this) ? 2040 : 24;   // Phase 3D: always 2040
  if (size > cap)
    return emitOpError("size (") << size
           << ") exceeds Custom's 24-slot limit under 2-bit kind encoding";   // text unchanged
  return verifySlotKinds(*this, getFields().take_front(size), getSlotKinds(),
                         getUnboxedBitmap(), /*legacySlots=*/24, "field");
```

- With the attribute set, a size above 2040 gets the message
  `size (N) exceeds Custom's 2040-field limit (HEAP_019)` (the text 3D.1 makes the only one). Use a
  second `if` for it (§S.1 `CUSTOM_MAX_FIELDS`).
- Keep the cap message text **byte-identical** to today's for the no-attribute case: the Phase 0
  expected-failure lists match on it.

**`RecordConstructOp::verify` (`EcoOps.cpp:438-508`).** The same shape:
- the cap at :450–456: no attribute → 32, message unchanged
  (`field_count (N) exceeds Record's 32-slot GC scan limit`); with the attribute → 2047
  (`field_count (N) exceeds Record's 2047-field limit (HEAP_019)`);
- then `verifySlotKinds(*this, getFields().take_front(fieldCount), getSlotKinds(),
  getUnboxedBitmap(), 32, "field")`.

**`ToHeapOp::verify` (`EcoOps.cpp:1405-1420`).** After the aggregate check, for a `RecordType` /
`CustomType` value:
- `n = fields.size()`, with the same caps (24/2040 or 32/2047 by `wideObjectsAllowed`);
- if `slot_kinds` is present, its length is n and `slot_kinds[i] == operandKind(fieldTy[i])`;
- reject `i1` field types (no producer emits them; the closest producer, `prepareCtorSlots`, boxes
  Bool);
- the legacy `unboxed_bitmap`, when present, must match for `i < HDR`.

For tuple2/3 aggregates the existing behaviour is unchanged.

**Invariants:**
- CGEN_026 / REP_BOUNDARY_002 now hold as "attribute (when present) ⇔ operand types". The lowering
  derives kinds from operand types, so heap layout ⇔ SSA types by construction.
- The verifier remains the production check that the front end's layout and its operand types
  agree (overview §2.4).

#### 3B.2.4 Tests for 3B.2

New codegen fixtures in `test/codegen/` (full text in 3B.F):

| Fixture | Expectation |
|---|---|
| `wide_record_33_no_attr.mlir` | rejected with the unchanged 32-slot message |
| `wide_record_33_kind_mismatch.mlir` | rejected, `slot_kinds[32] = 2 does not match operand type i64 (kind 1)` |

All 43 existing fixtures carrying `unboxed_bitmap` must pass unchanged.

**Rollback:** revert `Ops.td` and `EcoOps.cpp`; the R-sites in 3B.3–3B.5 must revert with them, so
land 3B.2–3B.5 as **one commit**.

#### 3B.2.5 Why a module attribute and not a command-line option

Verifiers run when the module is parsed. JIT fixtures (`emit=jit`, e.g. `caf_memo_gc.mlir`) run
**in-process** through `EcoRunner` (`test/codegen/CodegenIsolatedTest.hpp:300-316`:
`runJITTest`; `EcoRunner.cpp:179-181` `parseSourceFile`), inside the forked child the test runner
starts per test (`test/IsolatedTestRunner.hpp`). No command line is parsed there, so a `cl::opt`
cannot be set per fixture. The subprocess path only whitelists `--exe-reachability` (:247–250).

The tools that parse command lines are:
- `runtime/src/codegen/ecoc.cpp:439`;
- `runtime/src/codegen/eco-boot.cpp:603` (also the `eco-boot-native` binary);
- `runtime/src/ecogen.cpp:71`.

None of them covers the in-process path.

A module attribute is per-file, needs no registration in any tool, works for JIT and subprocess
fixtures alike, and the compiler never emits it. **Decision:** `module attributes
{eco.allow_wide_objects}`. 3D.3 deletes `wideObjectsAllowed`, the 3B.2.6 hook and the attribute
from the fixtures.

#### 3B.2.6 `EcoRunner` sets the runtime test switch for wide fixtures

The 3A.8 validate census aborts on any Custom/Record with K > 0 unless
`Elm::testing::allow_wide_objects` (§S.6) is set. Wide fixtures run in-process (3B.2.5), so the
runner sets it.

**File:** `runtime/src/codegen/EcoRunner.cpp`, `EcoRunner::Impl::run` (`:127-152`), right after
`parseMLIR` succeeds (`:139-143`):

```cpp
#include "../allocator/Heap.hpp"     // Elm::testing::allow_wide_objects (top of file)
…
        // §S.6: wide-object fixtures (module attribute eco.allow_wide_objects) are exempt from the
        // validate census of HEAP_077 until 3D.3 removes both the attribute and the flag.
        struct WideGuard {
            bool saved = Elm::testing::allow_wide_objects;
            ~WideGuard() { Elm::testing::allow_wide_objects = saved; }
        } wideGuard;
        if ((*module)->hasAttr("eco.allow_wide_objects"))
            Elm::testing::allow_wide_objects = true;
```

- Each test runs in its own forked child (`IsolatedTestRunner`), so the process-global flag never
  leaks across tests.
- A fixture that crashes on purpose runs through the subprocess `ecoc` path instead. No wide fixture
  is of that kind.

**Test:** the 3B.F fixtures in `build-validate` (3B.6.3). Without this hook they abort with
`[heap-validate] … allowed=0`.

**Rollback:** with 3B.2–3B.5 (one commit).

### 3B.3 Sizes (S1, S2, S3–S6)

Every Custom/Record size becomes the layout helper. **The four sites must agree byte-for-byte**,
because `hasInlineSingletonLowering` (S2) decides the inline/group split and the lowerings (S3/S4)
decide inline versus call; a disagreement mis-sizes a group region.

- **S1** `computeAllocSize` (`EcoToLLVMHeap.cpp:184-191`). Before:

  ```cpp
      if (auto recOp = dyn_cast<eco::RecordConstructOp>(op)) {
          int64_t size = HeaderSize + 8 + recOp.getFieldCount() * UnboxableSize;
          return (size + 7) & ~7;
      }
      if (auto customOp = dyn_cast<eco::CustomConstructOp>(op)) {
          int64_t size = HeaderSize + 8 + customOp.getSize() * UnboxableSize;
          return (size + 7) & ~7;
      }
  ```

  After:

  ```cpp
      if (auto recOp = dyn_cast<eco::RecordConstructOp>(op))
          return static_cast<int64_t>(layout::recordByteSize(recOp.getFieldCount()));
      if (auto customOp = dyn_cast<eco::CustomConstructOp>(op))
          return static_cast<int64_t>(layout::customByteSize(customOp.getSize()));
  ```

- **S2** `getFixedAllocSizeForGrouping` (`EcoGCPrepare.cpp:90-97`): the identical change. The file
  already includes `EcoToLLVMInternal.h` (:16).
- **S3/S4:** `recByteSize = layout::recordByteSize(fieldCount)` and
  `cusByteSize = layout::customByteSize(opSize)`. **S5/S6** in ValueAgg: the same.

**Invariants:**
- HEAP_034(a): the inline size is a compile-time constant, 8-aligned, ≤ 4096. The `<= 4096` gates
  now see `n + K`, so a 509-field record (16 + 8·510 = 4096) is still inline, while a 510-field
  record goes to the call path.
- `computeAllocSize == getFixedAllocSizeForGrouping` for every op: add a debug-only assert at
  `lowerOneAllocGroup` (`EcoToLLVMHeap.cpp:1960`), or a unit check in 3B.6.1's fixture list (the
  600-field group fixture covers it end to end).

**Rollback:** with 3B.2–3B.5 (one commit).

### 3B.4 Construct lowerings (RD3–RD7, F1–F6)

Common preamble in both patterns:

```cpp
        auto kinds  = slotKindsOfTypes(op.getFields().take_front(n).getTypes());  // ORIGINAL types
        PackedKinds pk = packKinds(kinds, layout::RecordHdrSlots /* or CustomHdrSlots */);
        const uint64_t K = pk.ext.size();
```

**Use the original (pre-conversion) operand types,** `op.getFields()`, not `adaptor.getFields()`.
After type conversion an `!eco.value` is `ptr<1>`, but f64/i64/i16 stay as they are; the original
types are what `emitFreshFieldStore` already uses (`origFieldsInl[i].getType()`).

#### 3B.4.1 `RecordConstructOpLowering::matchAndRewrite` (`EcoToLLVMHeap.cpp:926-1022`)

- **:946** `int64_t unboxedBitmap = op.getUnboxedBitmap();` becomes the preamble. The bitmap is now
  `pk.hdrBits`.
- **Inline path (:957–975):**

  ```cpp
          uint64_t recByteSize = layout::recordByteSize(fieldCount);
          if (inlineAllocEnabled() && recByteSize <= 4096) {
              uint64_t header = value_enc::composeHeader(
                  value_enc::TagRecord, /*unboxedBits=*/K, static_cast<uint64_t>(fieldCount));
              Value objHPtr = emitInlineAllocWithHeader(rewriter, loc, runtime, recByteSize, header);
              emitInlineAllocMetaWord(rewriter, loc, objHPtr, pk.hdrBits);
              … existing field-store loop (F1) unchanged …
              emitExtKindWordStores(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                    fieldCount, pk.ext);          // NEW, before replaceOp
              rewriter.replaceOp(op, objHPtr);
              return success();
          }
  ```

  `composeHeader`'s `unboxedBits` is shifted by `HeaderUnboxedShift = 10` (`EcoToLLVMInternal.h:316`),
  i.e. `Header.unboxed = K` (6 bits, K ≤ 63).
- **Call path (:977–1018):**
  - `unboxedBitmapVal` becomes `pk.hdrBits`.
  - The runtime computes K from `fieldCount` (3A-a).
  - After the field loop (F2), store the ext words:

  ```cpp
          if (!pk.ext.empty()) {
              if (inlineDerefExtEnabled()) {
                  emitExtKindWordStores(rewriter, loc, objHPtr, layout::RecordFieldsOffset,
                                        fieldCount, pk.ext);
              } else {
                  for (size_t j = 0; j < pk.ext.size(); ++j) {
                      auto idx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                                     static_cast<int32_t>(fieldCount + j));
                      auto w = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
                                     static_cast<int64_t>(pk.ext[j]));
                      rewriter.create<LLVM::CallOp>(loc, storeI64Func, ValueRange{objHPtr, idx, w});
                  }
              }
          }
  ```

  `storeI64Func` is `eco_store_record_field_i64`; it is gc-leaf like the field stores (3A-b).

#### 3B.4.2 `CustomConstructOpLowering::matchAndRewrite` (`EcoToLLVMHeap.cpp:1072-1180`)

- **Inline (:1097–1120):**
  - `uint64_t bitmap = pk.hdrBits;` keep the assert (`(bitmap >> 48) == 0`, true by
    construction).
  - The header is `composeHeader(TagCustom, K, opSize)`.
  - The meta word is `(tag & 0xFFFF) | (bitmap << 16)`.
  - After the F3 loop, call `emitExtKindWordStores(…, layout::CustomFieldsOffset, opSize, pk.ext)`.
- **Call path (:1122–1176):** after the F4 loop and before the `eco_set_unboxed` call, emit the same
  ext-word block as 3B.4.1 with `storeI64Func = eco_store_field_i64` (Custom arm,
  `RuntimeExports.cpp:2016`). The `eco_set_unboxed` call (:1167–1173) uses `pk.hdrBits` (a
  non-zero test as before).

#### 3B.4.3 Group path: `emitInitAtPtr` (`EcoToLLVMHeap.cpp:1734-1837`) and `emitFieldStoresForOp` (`:1840-1940`)

- **RD6 (record arm of `emitInitAtPtr`, :1814–1822):** the bitmap constant is the record's
  `packKinds(...).hdrBits`. `eco_init_record_at` computes K from `fieldCount` and zero-fills the
  words (3A-a). The group region was carved with `computeAllocSize`, which includes K (S1).
- **Custom arm (:1825–1834):** unchanged. `eco_init_custom_at(ptr, tag, n, 0)` computes K (3A-a).
- **F5 (record arm of `emitFieldStoresForOp`):** after the field loop, for each `j` emit
  `eco_store_record_field_i64(hptr, n + j, ext[j])`, i.e. the `storeI64Func` call with constants.
  Only for non-zero words: the runtime already zeroed them, and this path never stores zero words
  inline.
- **F6 / RD7 (custom arm):** the same, with `eco_store_field_i64`. `int64_t bitmap =
  customOp.getUnboxedBitmap();` becomes `packKinds(...).hdrBits`.

`emitFieldStoresForOp` runs in the merge block with no safepoint between `eco_init_*_at` and the
stores (HEAP_031). The ext words are written in that window.

**Invariants (3B.4):**
- **HEAP_031 / HEAP_034:** every ext-word store is straight-line after the allocation, before any
  safepoint (gc-leaf runtime stores only).
- **HEAP_019 (as Phase 3A implements it):** header bits plus ext words describe exactly the operand
  types.
- **HEAP_077:** ext words are written at allocation only.
- **Field offsets are unchanged.**

**Test:** the 3B.F fixtures. Before Phase 3B they fail at the verifier (no `slot_kinds`, caps); after
it they pass.

**Rollback:** with 3B.2–3B.5.

### 3B.5 ValueAgg to_heap (RD8–RD11, F7–F10)

In `ToHeapOpLowering::matchAndRewrite` (`EcoToLLVMValueAgg.cpp:198ff`):

- **Record arm (:374–456):** replace :378–379

  ```cpp
              int64_t mask = op.getUnboxedBitmap();
              if (mask == 0) mask = kindBitmapFor(fields);
  ```

  with

  ```cpp
              llvm::SmallVector<uint8_t> kinds;
              for (Type t : fields) kinds.push_back(slotKindOf(t));
              PackedKinds pk = packKinds(kinds, layout::RecordHdrSlots);
  ```

  The attribute is verifier-only now. Today's lowering trusted a non-zero attribute over the types,
  so a stale attribute could disagree with the stores, which dispatch on type; deriving kinds removes
  that split.
  - **Size (S5):** `layout::recordByteSize(fieldCount)`.
  - **Inline:** header `composeHeader(TagRecord, K, n)`, meta `pk.hdrBits`, then the F7 loop, then
    `emitExtKindWordStores(rewriter, loc, objHPtr, layout::RecordFieldsOffset, fieldCount, pk.ext)`.
  - **Call path (F8):** `unboxedBitmapVal = pk.hdrBits`, then the field loop, then the 3B.4.1 ext
    block (direct stores under `inlineDerefExtEnabled()`, else `eco_store_record_field_i64`).
- **Custom arm (:457–549):** the same, with `CustomHdrSlots`, `composeHeader(TagCustom, K, n)`, meta
  `(tag & 0xFFFF) | pk.hdrBits << 16`, and the ext block before the `eco_set_unboxed` call
  (:541–546, which uses `pk.hdrBits`).
- **Tuple2/Tuple3 arms (:231, :310):** `op.getUnboxedBitmap()` becomes
  `op.getUnboxedBitmap().value_or(0)`; their behaviour is unchanged.
- **`kindBitmapFor` (:77–87):** delete it. Its last other caller, `make.closure` (:796), moved to the
  closure packer in Phase 2.

**Invariants:**
- CGEN_029: to_heap stays the only boxing path for aggregates.
- The kinds equal the element types, which is what the store dispatch uses.

**Rollback:** with 3B.2–3B.5.

### 3B.6 Fixtures, LLVM identity check, gate

#### 3B.6.1 New codegen fixtures (`test/codegen/`)

| Fixture | Exercises | Expected |
|---|---|---|
| `wide_record_40_jit.mlir` (3B.F.1) | record, inline path (344 B), K = 1, mixed kinds; forced minor ×2 plus major GC; projections either side of slot 32 | 11 printed lines as in its CHECKs |
| `wide_custom_60_jit.mlir` (3B.F.2) | custom, inline path (512 B), K = 2; projections either side of slots 24 and 56 | 12 lines |
| `wide_record_600_jit.mlir` (3B.F.3, generated) | record, 600 fields: 16 + 8·618 = 4960 B > 4096, so the **call path**. Its 150 preceding `eco.box` allocations plus the record make an allocation run with a non-inline member, so `EcoGCPrepare` keeps it as a **group**: `emitInitAtPtr` / `emitFieldStoresForOp` (RD6/F5) | 6 lines |
| `wide_record_33_llvm.mlir` (3B.F.4) | the exact header word, offset and ext constant at `-emit=mlir-llvm` | FileCheck |
| `wide_record_33_no_attr.mlir` (3B.F.5) | the cap without the attribute | the 32-slot message |
| `wide_record_33_kind_mismatch.mlir` (3B.F.6) | the slot_kinds verifier | the mismatch message |

**How GC pressure is applied:** declare and call the runtime's collectors, as `caf_memo_gc.mlir`
does:

```mlir
  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()
  …
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
```

- These are statepoints. The live `!eco.value` of the wide object is relocated, so the object is
  evacuated (and, after two minors, promoted) and then marked by the major. Every projection after
  the calls therefore reads a **copied** object, sized by `getObjectSize` with K and traced through
  the ext words.
- A wrong K mis-sizes the copy, so later slots read garbage.
- A wrong ext word traces a raw Int/Float as a pointer, which aborts in the validate tree
  ("Pointer below heap base"), or skips a boxed field, which then prints a stale value.

**Wide-object JIT runs in-process.** Run the fixtures in the validate tree as well (§S.7), where the
heap validator turns a mis-traced slot into an abort.

**A 600-field custom is not needed:** S1/S2 and F5/F6 share one code path per tag, and the custom
group path is exercised by `wide_custom_60` whenever it is grouped. If coverage tools show F6
unexercised, generate `wide_custom_600_jit.mlir` with 3B.F.3's script (`gen('custom', 600, …)`).

#### 3B.6.2 Identity check: no change for K = 0 (production programs)

**Before** implementing (on the Phase 3A tree), and again **after**, with the same `ecoc`:

```bash
mkdir -p /tmp/p4-ident/{before,after}
for f in $(ls /work/build/test/elm/eco-stuff/mlir/*.mlir | head -40); do
  /work/build/runtime/src/codegen/ecoc "$f" --emit=llvm > /tmp/p4-ident/before/$(basename $f).ll 2>&1
done
# … after Phase 3B is built: same loop into /tmp/p4-ident/after …
diff -r /tmp/p4-ident/before /tmp/p4-ident/after && echo IDENTICAL
```

- **Expected:** `IDENTICAL`. The front end emits no wide objects, so K = 0, `packKinds(...).hdrBits`
  equals the old attribute, and no ext stores are emitted.
- Run this **before** the cache wipe. It reads the `.mlir` that the last `full` left in
  `build/test/elm/eco-stuff`.
- **Any diff is a bug in this phase.** The likely causes: the operand-type derivation disagreeing
  with an attribute somewhere (the verifier would also catch that), or a size formula drift.

#### 3B.6.3 Commands (§S.7), in order. Each test command runs **once**, tee'd

```bash
cmake --build build 2>&1 | tee /tmp/p4_build.txt                   # libraries + tools + tla-canary (no allocator change: should not fire)
cmake --build build --target test && ulimit -c 0 && \
  build/test/test --filter "codegen/" 2>&1 | tee /tmp/test_output_p4_codegen.txt
grep -E "FAIL|passed|failed" /tmp/test_output_p4_codegen.txt | tail -20
# validate tree: the same fixtures under the heap validator
cmake --build /work/build-validate --target test && ulimit -c 0 && \
  /work/build-validate/test/test --filter "codegen/wide_" 2>&1 | tee /tmp/test_output_p4_validate.txt
# 3B.6.2 identity check (before the wipe)
# full E2E after the cache wipe (§S.7)
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.1.3/packages \( -name artifacts.dat -o -name typed-artifacts.dat \) -delete
rm -rf ~/.eco/0.1.3/packages/eco/kernel
ulimit -c 0; cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output_elm.txt     # front end unchanged: same as 3A
cmake --build build --target bootstrap 2>&1 | tee /tmp/test_output_boot.txt && \
  cmake --build build --target eco-verify 2>&1 | tee -a /tmp/test_output_boot.txt
# perf: one fe-opt-loop.md §1 timed triple; compare GC counters with the 3A entry
```

#### 3B.6.4 3B gate

| Gate | Expected |
|---|---|
| codegen fixtures (default and validate) | all pass: the 6 new ones, plus all existing ones (the 43 with `unboxed_bitmap` included). **No expected failures.** |
| `full` E2E | failures equal **list L3** (top of this file) exactly, by name and reason. The 6 new 3B.F fixtures pass |
| elm-tests | the 2 GOPT_003 failures only (`MonoCaseBranchResultTypeTest`) |
| 3B.6.2 identity | `IDENTICAL` |
| bootstrap | B==C |
| perf triple | GC counters **bit-identical** to the 3A entry (K = 0 everywhere; LLVM identical). Wall within the triple's spread |
| `tla-canary` | silent: no allocator file is touched in 3B |

### 3B.F Fixture texts

#### 3B.F.1 `test/codegen/wide_record_40_jit.mlir`

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Phase 3B (plans/wide-object-tail-kind-words-phase-3.md): a 40-field record with
// mixed kinds (i64, f64, i16, boxed) built by eco.construct.record, kept live across
// forced minor + major GCs, then projected. Slots >= 32 have their kinds in an
// extension kind word (HEAP_019); a wrong ext word makes the GC trace a raw value
// (crash under ECO_HEAP_VALIDATE) or lose a boxed one (stale value).
// The module attribute lifts the pre-3D verifier cap (deleted in Phase 3D).

module attributes {eco.allow_wide_objects} {
  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func @main() -> i64 {
    %v0 = arith.constant 1000 : i64
    %v1 = arith.constant 1.5 : f64
    %v2 = arith.constant 67 : i16
    %r3 = arith.constant 2003 : i64
    %v3 = eco.box %r3 : i64 -> !eco.value
    %v4 = arith.constant 1004 : i64
    %v5 = arith.constant 5.5 : f64
    %v6 = arith.constant 71 : i16
    %r7 = arith.constant 2007 : i64
    %v7 = eco.box %r7 : i64 -> !eco.value
    %v8 = arith.constant 1008 : i64
    %v9 = arith.constant 9.5 : f64
    %v10 = arith.constant 75 : i16
    %r11 = arith.constant 2011 : i64
    %v11 = eco.box %r11 : i64 -> !eco.value
    %v12 = arith.constant 1012 : i64
    %v13 = arith.constant 13.5 : f64
    %v14 = arith.constant 79 : i16
    %r15 = arith.constant 2015 : i64
    %v15 = eco.box %r15 : i64 -> !eco.value
    %v16 = arith.constant 1016 : i64
    %v17 = arith.constant 17.5 : f64
    %v18 = arith.constant 83 : i16
    %r19 = arith.constant 2019 : i64
    %v19 = eco.box %r19 : i64 -> !eco.value
    %v20 = arith.constant 1020 : i64
    %v21 = arith.constant 21.5 : f64
    %v22 = arith.constant 87 : i16
    %r23 = arith.constant 2023 : i64
    %v23 = eco.box %r23 : i64 -> !eco.value
    %v24 = arith.constant 1024 : i64
    %v25 = arith.constant 25.5 : f64
    %v26 = arith.constant 65 : i16
    %r27 = arith.constant 2027 : i64
    %v27 = eco.box %r27 : i64 -> !eco.value
    %v28 = arith.constant 1028 : i64
    %v29 = arith.constant 29.5 : f64
    %v30 = arith.constant 69 : i16
    %r31 = arith.constant 2031 : i64
    %v31 = eco.box %r31 : i64 -> !eco.value
    %v32 = arith.constant 1032 : i64
    %v33 = arith.constant 33.5 : f64
    %v34 = arith.constant 73 : i16
    %r35 = arith.constant 2035 : i64
    %v35 = eco.box %r35 : i64 -> !eco.value
    %v36 = arith.constant 1036 : i64
    %v37 = arith.constant 37.5 : f64
    %v38 = arith.constant 77 : i16
    %r39 = arith.constant 2039 : i64
    %v39 = eco.box %r39 : i64 -> !eco.value
    %obj = eco.construct.record(%v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7, %v8, %v9, %v10, %v11, %v12, %v13, %v14, %v15, %v16, %v17, %v18, %v19, %v20, %v21, %v22, %v23, %v24, %v25, %v26, %v27, %v28, %v29, %v30, %v31, %v32, %v33, %v34, %v35, %v36, %v37, %v38, %v39) {field_count = 40 : i64, slot_kinds = array<i8: 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0>} : (i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value) -> !eco.value
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %p0 = eco.project.record %obj[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    %p1 = eco.project.record %obj[1] : !eco.value -> f64
    eco.dbg %p1 : f64
    %p2 = eco.project.record %obj[2] : !eco.value -> i16
    eco.dbg %p2 : i16
    %p3 = eco.project.record %obj[3] : !eco.value -> !eco.value
    %u3 = eco.unbox %p3 : !eco.value -> i64
    eco.dbg %u3 : i64
    %p31 = eco.project.record %obj[31] : !eco.value -> !eco.value
    %u31 = eco.unbox %p31 : !eco.value -> i64
    eco.dbg %u31 : i64
    %p32 = eco.project.record %obj[32] : !eco.value -> i64
    eco.dbg %p32 : i64
    %p33 = eco.project.record %obj[33] : !eco.value -> f64
    eco.dbg %p33 : f64
    %p34 = eco.project.record %obj[34] : !eco.value -> i16
    eco.dbg %p34 : i16
    %p35 = eco.project.record %obj[35] : !eco.value -> !eco.value
    %u35 = eco.unbox %p35 : !eco.value -> i64
    eco.dbg %u35 : i64
    %p38 = eco.project.record %obj[38] : !eco.value -> i16
    eco.dbg %p38 : i16
    %p39 = eco.project.record %obj[39] : !eco.value -> !eco.value
    %u39 = eco.unbox %p39 : !eco.value -> i64
    eco.dbg %u39 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: 1000
// CHECK-NEXT: 1.5
// CHECK-NEXT: 'C'
// CHECK-NEXT: 2003
// CHECK-NEXT: 2031
// CHECK-NEXT: 1032
// CHECK-NEXT: 33.5
// CHECK-NEXT: 'I'
// CHECK-NEXT: 2035
// CHECK-NEXT: 'M'
// CHECK-NEXT: 2039
```

#### 3B.F.2 `test/codegen/wide_custom_60_jit.mlir`

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Phase 3B (plans/wide-object-tail-kind-words-phase-3.md): a 60-field custom with
// mixed kinds (i64, f64, i16, boxed) built by eco.construct.custom, kept live across
// forced minor + major GCs, then projected. Slots >= 24 have their kinds in an
// extension kind word (HEAP_019); a wrong ext word makes the GC trace a raw value
// (crash under ECO_HEAP_VALIDATE) or lose a boxed one (stale value).
// The module attribute lifts the pre-3D verifier cap (deleted in Phase 3D).

module attributes {eco.allow_wide_objects} {
  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func @main() -> i64 {
    %v0 = arith.constant 1000 : i64
    %v1 = arith.constant 1.5 : f64
    %v2 = arith.constant 67 : i16
    %r3 = arith.constant 2003 : i64
    %v3 = eco.box %r3 : i64 -> !eco.value
    %v4 = arith.constant 1004 : i64
    %v5 = arith.constant 5.5 : f64
    %v6 = arith.constant 71 : i16
    %r7 = arith.constant 2007 : i64
    %v7 = eco.box %r7 : i64 -> !eco.value
    %v8 = arith.constant 1008 : i64
    %v9 = arith.constant 9.5 : f64
    %v10 = arith.constant 75 : i16
    %r11 = arith.constant 2011 : i64
    %v11 = eco.box %r11 : i64 -> !eco.value
    %v12 = arith.constant 1012 : i64
    %v13 = arith.constant 13.5 : f64
    %v14 = arith.constant 79 : i16
    %r15 = arith.constant 2015 : i64
    %v15 = eco.box %r15 : i64 -> !eco.value
    %v16 = arith.constant 1016 : i64
    %v17 = arith.constant 17.5 : f64
    %v18 = arith.constant 83 : i16
    %r19 = arith.constant 2019 : i64
    %v19 = eco.box %r19 : i64 -> !eco.value
    %v20 = arith.constant 1020 : i64
    %v21 = arith.constant 21.5 : f64
    %v22 = arith.constant 87 : i16
    %r23 = arith.constant 2023 : i64
    %v23 = eco.box %r23 : i64 -> !eco.value
    %v24 = arith.constant 1024 : i64
    %v25 = arith.constant 25.5 : f64
    %v26 = arith.constant 65 : i16
    %r27 = arith.constant 2027 : i64
    %v27 = eco.box %r27 : i64 -> !eco.value
    %v28 = arith.constant 1028 : i64
    %v29 = arith.constant 29.5 : f64
    %v30 = arith.constant 69 : i16
    %r31 = arith.constant 2031 : i64
    %v31 = eco.box %r31 : i64 -> !eco.value
    %v32 = arith.constant 1032 : i64
    %v33 = arith.constant 33.5 : f64
    %v34 = arith.constant 73 : i16
    %r35 = arith.constant 2035 : i64
    %v35 = eco.box %r35 : i64 -> !eco.value
    %v36 = arith.constant 1036 : i64
    %v37 = arith.constant 37.5 : f64
    %v38 = arith.constant 77 : i16
    %r39 = arith.constant 2039 : i64
    %v39 = eco.box %r39 : i64 -> !eco.value
    %v40 = arith.constant 1040 : i64
    %v41 = arith.constant 41.5 : f64
    %v42 = arith.constant 81 : i16
    %r43 = arith.constant 2043 : i64
    %v43 = eco.box %r43 : i64 -> !eco.value
    %v44 = arith.constant 1044 : i64
    %v45 = arith.constant 45.5 : f64
    %v46 = arith.constant 85 : i16
    %r47 = arith.constant 2047 : i64
    %v47 = eco.box %r47 : i64 -> !eco.value
    %v48 = arith.constant 1048 : i64
    %v49 = arith.constant 49.5 : f64
    %v50 = arith.constant 89 : i16
    %r51 = arith.constant 2051 : i64
    %v51 = eco.box %r51 : i64 -> !eco.value
    %v52 = arith.constant 1052 : i64
    %v53 = arith.constant 53.5 : f64
    %v54 = arith.constant 67 : i16
    %r55 = arith.constant 2055 : i64
    %v55 = eco.box %r55 : i64 -> !eco.value
    %v56 = arith.constant 1056 : i64
    %v57 = arith.constant 57.5 : f64
    %v58 = arith.constant 71 : i16
    %r59 = arith.constant 2059 : i64
    %v59 = eco.box %r59 : i64 -> !eco.value
    %obj = eco.construct.custom(%v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7, %v8, %v9, %v10, %v11, %v12, %v13, %v14, %v15, %v16, %v17, %v18, %v19, %v20, %v21, %v22, %v23, %v24, %v25, %v26, %v27, %v28, %v29, %v30, %v31, %v32, %v33, %v34, %v35, %v36, %v37, %v38, %v39, %v40, %v41, %v42, %v43, %v44, %v45, %v46, %v47, %v48, %v49, %v50, %v51, %v52, %v53, %v54, %v55, %v56, %v57, %v58, %v59) {tag = 3 : i64, size = 60 : i64, slot_kinds = array<i8: 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0>} : (i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value) -> !eco.value
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %p0 = eco.project.custom %obj[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    %p1 = eco.project.custom %obj[1] : !eco.value -> f64
    eco.dbg %p1 : f64
    %p2 = eco.project.custom %obj[2] : !eco.value -> i16
    eco.dbg %p2 : i16
    %p3 = eco.project.custom %obj[3] : !eco.value -> !eco.value
    %u3 = eco.unbox %p3 : !eco.value -> i64
    eco.dbg %u3 : i64
    %p23 = eco.project.custom %obj[23] : !eco.value -> !eco.value
    %u23 = eco.unbox %p23 : !eco.value -> i64
    eco.dbg %u23 : i64
    %p24 = eco.project.custom %obj[24] : !eco.value -> i64
    eco.dbg %p24 : i64
    %p25 = eco.project.custom %obj[25] : !eco.value -> f64
    eco.dbg %p25 : f64
    %p26 = eco.project.custom %obj[26] : !eco.value -> i16
    eco.dbg %p26 : i16
    %p27 = eco.project.custom %obj[27] : !eco.value -> !eco.value
    %u27 = eco.unbox %p27 : !eco.value -> i64
    eco.dbg %u27 : i64
    %p55 = eco.project.custom %obj[55] : !eco.value -> !eco.value
    %u55 = eco.unbox %p55 : !eco.value -> i64
    eco.dbg %u55 : i64
    %p56 = eco.project.custom %obj[56] : !eco.value -> i64
    eco.dbg %p56 : i64
    %p59 = eco.project.custom %obj[59] : !eco.value -> !eco.value
    %u59 = eco.unbox %p59 : !eco.value -> i64
    eco.dbg %u59 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: 1000
// CHECK-NEXT: 1.5
// CHECK-NEXT: 'C'
// CHECK-NEXT: 2003
// CHECK-NEXT: 2023
// CHECK-NEXT: 1024
// CHECK-NEXT: 25.5
// CHECK-NEXT: 'A'
// CHECK-NEXT: 2027
// CHECK-NEXT: 2055
// CHECK-NEXT: 1056
// CHECK-NEXT: 2059
```

**Expected kind words (for debugging with `-emit=mlir-llvm`):**

| Object | Header word | Meta word | Ext words |
|---|---|---|---|
| record 40 | `0x2800000408` = 171798692872 (Record tag 8, K = 1, n = 40) | `0x3939393939393939` | `[0x3939]` |
| custom 60 (tag 3) | `0x3c00000807` = 257698039815 (Custom tag 7, K = 2, n = 60) | `3 \| 0x393939393939 << 16` = `0x3939393939390003` | `[0x3939393939393939, 0x39]` |

#### 3B.F.3 `test/codegen/wide_record_600_jit.mlir` (generated, then checked in)

Field `i` has kind `[1,2,3,0][i % 4]`, with the values: Int `1000+i`, Float `i.5`,
Char `65 + i%26`, boxed Int `2000+i`. The fixture probes slots 0, 31, 32, 63, 64 and 599, with the
expected outputs `1000`, `2031`, `1032`, `2063`, `1064`, `2599`. Generator (keep it as
`test/codegen/gen_wide_fixtures.py` so the fixtures can be regenerated):

```python
import sys
KIND_TY={0:'!eco.value',1:'i64',2:'f64',3:'i16'}
def kind_of(i): return [1,2,3,0][i%4]
def ext_words(n,hdr): return (n-hdr+31)//32 if n>hdr else 0
def pack(kinds,hdr):
    h=0
    for i,k in enumerate(kinds[:hdr]): h|=k<<(2*i)
    ext=[]
    for j in range(ext_words(len(kinds),hdr)):
        w=0
        for i,k in enumerate(kinds[hdr+32*j:hdr+32*j+32]): w|=k<<(2*i)
        ext.append(w)
    return h,ext
def expected(i):
    k=kind_of(i)
    if k==1: return str(1000+i)
    if k==2: return f"{i}.5"
    if k==3: return "'"+chr(65+i%26)+"'"
    return str(2000+i)
def gen(kind,n,probe,name,tag=None):
    hdr=24 if kind=='custom' else 32
    kinds=[kind_of(i) for i in range(n)]
    L=[]
    L.append(f"// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s")
    L.append("//")
    L.append(f"// Phase 3B (plans/wide-object-tail-kind-words-phase-3.md): a {n}-field {kind} with")
    L.append(f"// mixed kinds (i64, f64, i16, boxed) built by eco.construct.{kind}, kept live across")
    L.append("// forced minor + major GCs, then projected. Slots >= %d have their kinds in an" % hdr)
    L.append("// extension kind word (HEAP_019); a wrong ext word makes the GC trace a raw value")
    L.append("// (crash under ECO_HEAP_VALIDATE) or lose a boxed one (stale value).")
    L.append("// The module attribute lifts the pre-3D verifier cap (deleted in Phase 3D).")
    L.append("")
    L.append("module attributes {eco.allow_wide_objects} {")
    L.append("  llvm.func @eco_minor_gc()")
    L.append("  llvm.func @eco_major_gc()")
    L.append("")
    L.append("  func.func @main() -> i64 {")
    ops=[];tys=[]
    for i,k in enumerate(kinds):
        if k==1: L.append(f"    %v{i} = arith.constant {1000+i} : i64")
        elif k==2: L.append(f"    %v{i} = arith.constant {i}.5 : f64")
        elif k==3: L.append(f"    %v{i} = arith.constant {65+i%26} : i16")
        else:
            L.append(f"    %r{i} = arith.constant {2000+i} : i64")
            L.append(f"    %v{i} = eco.box %r{i} : i64 -> !eco.value")
        ops.append(f"%v{i}"); tys.append(KIND_TY[k])
    sk=", ".join(str(k) for k in kinds)
    if kind=='record':
        L.append(f"    %obj = eco.construct.record({', '.join(ops)}) {{field_count = {n} : i64, slot_kinds = array<i8: {sk}>}} : ({', '.join(tys)}) -> !eco.value")
    else:
        L.append(f"    %obj = eco.construct.custom({', '.join(ops)}) {{tag = {tag} : i64, size = {n} : i64, slot_kinds = array<i8: {sk}>}} : ({', '.join(tys)}) -> !eco.value")
    L.append("    llvm.call @eco_minor_gc() : () -> ()")
    L.append("    llvm.call @eco_minor_gc() : () -> ()")
    L.append("    llvm.call @eco_major_gc() : () -> ()")
    proj='record' if kind=='record' else 'custom'
    checks=[]
    for i in probe:
        k=kinds[i]
        if k==0:
            L.append(f"    %p{i} = eco.project.{proj} %obj[{i}] : !eco.value -> !eco.value")
            L.append(f"    %u{i} = eco.unbox %p{i} : !eco.value -> i64")
            L.append(f"    eco.dbg %u{i} : i64")
        else:
            L.append(f"    %p{i} = eco.project.{proj} %obj[{i}] : !eco.value -> {KIND_TY[k]}")
            L.append(f"    eco.dbg %p{i} : {KIND_TY[k]}")
        checks.append(f"// CHECK{'' if not checks else '-NEXT'}: {expected(i)}")
    L.append("    %z = arith.constant 0 : i64")
    L.append("    return %z : i64")
    L.append("  }")
    L.append("}")
    L.append("")
    L+=checks
    h,ext=pack(kinds,hdr)
    return "\n".join(L)+"\n", h, ext
if __name__=='__main__':
    r,h,e=gen('record',40,[0,1,2,3,31,32,33,34,35,38,39],'wide_record_40')
    open('wide_record_40_jit.mlir','w').write(r); print('record hdr',hex(h),'ext',[hex(x) for x in e])
    c,h,e=gen('custom',60,[0,1,2,3,23,24,25,26,27,55,56,59],'wide_custom_60',tag=3)
    open('wide_custom_60_jit.mlir','w').write(c); print('custom hdr',hex(h),'ext',[hex(x) for x in e])
    r,h,e=gen('record',600,[0,31,32,63,64,599],'wide_record_600')
    open('wide_record_600_jit.mlir','w').write(r); print('rec600 ext count',len(e))
    for nm,n,hdr,tag in (('record',40,32,8),('custom',60,24,7),('record',600,32,8)):
        K=(n-hdr+31)//32
        print(nm,n,'K',K,'header word',hex(tag | (K<<10) | (n<<32)), 'bytes',16+8*(n+K))
```

#### 3B.F.4 `test/codegen/wide_record_33_llvm.mlir`

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Phase 3B: a 33-field record (32 boxed + one Int at slot 32) lowers with
// K = 1 extension kind word: header word = TagRecord(8) | K<<10 | 33<<32
// = 141733921800, the meta word holds kinds 0..31 (all boxed = 0), and the
// ext word at byte offset 16 + 8*33 = 280 holds slot 32's kind (Int = 1).
// emitExtKindWordStores creates the word constant before the offset constant.

module attributes {eco.allow_wide_objects} {
  func.func @wide33(%b: !eco.value, %i: i64) -> !eco.value {
    %r = eco.construct.record(%b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %i) {field_count = 33 : i64, slot_kinds = array<i8: 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @wide33
// CHECK: llvm.call @__eco_alloc_inline
// CHECK: llvm.mlir.constant(141733921800 : i64)
// CHECK: llvm.mlir.constant(1 : i64)
// CHECK: llvm.mlir.constant(280 : i64)
// CHECK: llvm.store
```

#### 3B.F.5 `test/codegen/wide_record_33_no_attr.mlir`

```mlir
// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3B: without the test-only module attribute the pre-3D cap holds.

module {
  func.func @wide33(%b: !eco.value, %i: i64) -> !eco.value {
    %r = eco.construct.record(%b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %i) {field_count = 33 : i64, slot_kinds = array<i8: 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: field_count (33) exceeds Record's 32-slot GC scan limit
```

#### 3B.F.6 `test/codegen/wide_record_33_kind_mismatch.mlir`

```mlir
// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3B: slot_kinds must match the operand types (slot 32 is i64 = 1, attr says 2).

module attributes {eco.allow_wide_objects} {
  func.func @wide33(%b: !eco.value, %i: i64) -> !eco.value {
    %r = eco.construct.record(%b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %b, %i) {field_count = 33 : i64, slot_kinds = array<i8: 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2>} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i64) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: slot_kinds[32] = 2 does not match operand type i64 (kind 1)
```

**Coverage note for 3B.F.3:** confirm once that the 600-field record really lowers through the group
path. Run `ECO_GCPREPARE_CENSUS=1 build/runtime/src/codegen/ecoc test/codegen/wide_record_600_jit.mlir
-emit=mlir-llvm 2>&1 | grep -c eco_init_record_at`; it must be ≥ 1.
- If grouping does not form (e.g. a safepoint between the boxes and the record), the singleton call
  path (3B.4.1) is what runs.
- Add a second fixture with no preceding allocations (all 600 fields `i64` constants) to pin the
  singleton call path, so both paths are covered whichever one the grouping takes.

### 3B gate result (recorded 2026-10-05)

- ALL build clean (strict canary silent, license hashes unchanged); codegen fixtures 342/342 (8 new
  `wide_*`), validate tree `codegen/wide_` 8/8 with no `[heap-validate]`; whole binary default
  2113 / 10 and validate 2115 / 10, the 10 = L3 exactly; register-guards green.
- **LLVM identity (3B.6.2): byte-identical** LLVM IR for all 934 production `.mlir` modules
  (`build/test/aot-e2e/*/eco-stuff`, 820 allocate), Phase 3A `ecoc` vs Phase 3B `ecoc`. Because the
  front end is unchanged in 3B and the IR is identical, the `full`/AOT/bootstrap/perf results of 3B
  equal 3A's; they were run once, combined with the 3C gate below.
- Deviations: `kindBitmapFor` kept (the tuple to_heap arms use it); the plan's "bitmap bits beyond
  the last field" verifier check left out (the old verifier never had it and a stray bit is valid
  today); MLIR diagnostics quote types, so `wide_record_33_kind_mismatch.mlir` CHECKs
  `operand type 'i64' (kind 1)`; the 600-field record never forms an allocation group, so two extra
  group fixtures (`wide_record_600_group_jit.mlir`, `wide_custom_600_group_jit.mlir`) cover the group
  path; `ecoc -emit=jit` sets the same test flag as `EcoRunner`.

### 3B checklist

- [x] Preconditions 3A-a…d, P1-a, P1-b and P2-a checked (3B.0).
- [x] 3B.1: layout helpers and `static_assert`s in `EcoToLLVMInternal.h` / `EcoToLLVMHeap.cpp`;
      builds.
- [x] Before 3B.2: 3B.6.2 "before" LLVM dump captured.
- [x] 3B.2: `Ops.td` (3 ops), `verifySlotKinds`, `wideObjectsAllowed`, the 3 verifiers (cap
      messages without the attribute unchanged), the 3B.2.6 `EcoRunner` hook.
- [x] 3B.3: S1–S6 use `recordByteSize` / `customByteSize`, and `grep -n "RecordBaseSize\|CustomBaseSize"`
      shows no other size formula.
- [x] 3B.4: RD3–RD7, F1–F6. Ext words stored in the allocation window on the inline, call and group
      paths.
- [x] 3B.5: RD8–RD11, F7–F10. `kindBitmapFor` deleted.
- [x] 3B.2–3B.5 land as **one commit** (the accessor type change spans them).
- [x] 3B.6: 6 fixtures plus the generator added. Codegen run green in the default and validate
      trees.
- [x] 3B.6.2 identity `IDENTICAL`; `full` matches list L3 exactly; elm-tests 2 GOPT_003;
      bootstrap B==C; perf counters bit-identical to 3A.

**3B is done when** every item above is checked and the 3B.6.4 table holds.

### 3B rollback

- **3B.2–3B.5 revert as one commit.** 3B.1's helpers and asserts are harmless to keep.
- **Phase 3A is not affected:** its runtime computes K from n, and K = 0 for every object the
  reverted lowering emits.
- **The fixtures revert with the commit.**
- **Snapshot before the perf triple:** `lss-loop-snap.sh` or a git tag.

### 3B open questions (resolved where possible)

| # | Question | Resolution or default |
|---|---|---|
| Q2 | Does any C++ pass create construct.custom/record or set their bitmap? | **Resolved (grep):** no. `materialiseAsBoxed` creates `to_heap` without attributes (`EcoToLLVMHeap.cpp:2161`) |
| Q3 | Must the group path store zero ext words? | **Resolved:** no. The runtime `eco_init_*_at` zero-fill them (3A-a). The inline path stores all words, because nothing else initialises them |
| Q4 | Is `index = n + j` legal for `eco_store_*field_i64`? | **Resolved:** yes today (no bound check, `RuntimeExports.cpp:473`, `:2016`). 3A keeps it legal (3A-b) |
| Q5 | Should the legacy `unboxed_bitmap` be *checked* or *ignored* when `slot_kinds` is present? | **Default:** check both when present (cheap; catches front-end drift during Phase 3C's transition) |
| Q6 | Do we need `to_heap` with `slot_kinds` from the front end? | **Default:** no producer emits it; it stays a verifier-only optional attribute, so `materialiseAsBoxed` needs no change |
| Q7 | Does the LLVM identity check (3B.6.2) need `ECO_MLIR_SPLIT=0` or other env? | **Default:** run both dumps in the same shell with the same env. If the dumps differ only in symbol order or partition naming, re-run both with `ECO_MLIR_SPLIT=0` (not verified whether `ecoc --emit=llvm` partitions) |

---

## 3C. Custom/Record front end

**Design:** overview §2.4 (`slot_kinds`). **Gate mechanics:** overview §6.

### 3C.0 Scope

**Does:**
- `computeCtorLayout`: `isUnboxed = canUnbox ty`, with no index cap.
- `computeRecordLayout`: drops the 26 cap and keeps the primitives-first, name-sorted order.
- In the **same commit**, `eco.construct.custom` / `eco.construct.record` get their per-slot kinds
  as `slot_kinds` (§S.5) instead of `unboxed_bitmap`.
  - This is a hard dependency. A 32-slot record bitmap needs 64 bits, but Elm `Int` is exact only
    to 2^53 (`Types.bitmapSetKind`, `Types.elm:420-450`).
  - So the cap drop is only safe once nothing computes a record or ctor bitmap in Elm.
- `Ops.ecoConstructCustom` / `Ops.ecoConstructRecord` take a `List Int` of kinds. Every caller
  passes the kinds of the **layout**, never of the operands, so the C++ verifier's
  `slot_kinds ⇔ operand types` check stays a real layout witness (overview §2.4).
- The elm-test checkers that read `unboxed_bitmap` on these two ops are retargeted, and so are the
  destructor-projection rules that hard-code 24 (custom) and 26 (Phase 1's record rule).

**Does not:**
- Tuples / list cons keep `unboxed_bitmap` (≤ 3 slots).
- Closure ops were done in Phase 2.
- The C++ verifier caps (Custom 24, Record 32) stay until Phase 3D. So a ctor of 25+ fields or a
  record of 33+ fields still fails in `eco-boot-native`, exactly as before.
- **What changes in emitted code:** only records with 27–32 Int/Float/Char fields become fully
  unboxed, all within the 64-bit header word, with no ext words.

### 3C.P Preconditions (check before starting; stop if one fails)

| # | Check | How |
|---|---|---|
| 3C-0a | Phase 3B has landed: `eco.construct.custom` / `eco.construct.record` accept `slot_kinds`, verify it against operand types, and accept a **missing** `unboxed_bitmap`. `construct.record`'s `unboxed_bitmap` was a plain `I64Attr` (`runtime/src/codegen/Ops.td` around `:928`, `RecordConstructOp`), so it must be `OptionalAttr` / `DefaultValuedAttr` now | `grep -n "slot_kinds" runtime/src/codegen/Ops.td runtime/src/codegen/EcoOps.cpp` shows both ops. A hand fixture with only `slot_kinds` parses under `ecoc -emit=mlir` |
| 3C-0b | Phase 2 step 2.0 made the bytecode encoder write dense arrays with the element width (`Mlir/Bytecode/AttrType.elm` `EDenseArrayAttr`: 1/2/4/8 bytes for `I8`/`I16`/`I32`/`I64`) | a closure `slot_kinds` op round-trips through the **bytecode** path (the default compile, without `--text-mlir`) |
| 3C-0c | `Ops.slotKindsAttr : List Int -> MlirAttr` exists (Phase 2 step 2.8) | `grep -n slotKindsAttr compiler/src/Compiler/Generate/MLIR/Ops.elm` |
| 3C-0d | Phase 2 removed every **closure** use of `Types.bitmapSetKind`. Today these are `Expr.elm:1250, 1849, 1989, 2154, 2357, 2499, 2741, 6014, 6246`, `Lambdas.elm:228` and `BytesFusion/Emit.elm:1679`. The remaining users must be only `Types.elm:509` (record layout), `:574` (tuple layout), `:613` (ctor layout) and `BytesFusion/Emit.elm:1879` | `grep -rn bitmapSetKind compiler/src` |
| 3C-0e | Phase 1 removed the AbiCloning `ctorTypedSlotCap` guard (B9; `AbiCloning.elm:2988`, `:3002-3004` today) | `grep -n ctorTypedSlotCap compiler/src/Compiler/GlobalOpt/AbiCloning.elm` is empty |
| 3C-0f | The 3B gate is green, and the Phase 0 census row "records with more than 26 primitive fields" (phase-0 Step 0.4) is recorded | the phase-0 baselines table |

### 3C.I Inventory (grep of `compiler/src` and `compiler/tests`, 2026-10-05) and the fate of each hit

`grep -rn -E "unboxedBitmap|bitmapSetKind|maxTypedSlots|computeCtorLayout|computeRecordLayout|ecoConstructCustom\b|ecoConstructRecord\b|unboxed_bitmap|unboxedCount" compiler/src compiler/tests --include=*.elm`

#### `compiler/src`

| Site | What it is | Phase 3C action |
|---|---|---|
| `Types.elm:6`, `:53` | exports / docs `bitmapSetKind` | stop exporting `bitmapSetKind` (3C.1) |
| `Types.elm:30-43` | module doc: "record field at index 26 or above, and a constructor field at index 24 or above, is stored boxed" | reword (3C.1) |
| `Types.elm:354-359` | `RecordLayout { fieldCount, unboxedCount, unboxedBitmap, fields }` | drop `unboxedCount` and `unboxedBitmap` (no users outside Types) |
| `Types.elm:381-387` | `CtorLayout { name, tag, fields, unboxedCount, unboxedBitmap }` | drop `unboxedCount` and `unboxedBitmap` |
| `Types.elm:393-397` | `TupleLayout { arity, unboxedBitmap, elements }` | **keep** |
| `Types.elm:423-430` | `maxTypedSlots = 26` | delete (3C.1) |
| `Types.elm:442-454` | `bitmapSetKind` | make private, rename `tupleBitmapSetKind`, used only by `computeTupleLayout`; or replace by the inline fold of 3C.1 |
| `Types.elm:465-518` | `computeRecordLayout` (cap at `:490`, bitmap at `:498-511`) | 3C.1 |
| `Types.elm:556-580` | `computeTupleLayout` (`bitmapSetKind` at `:574`) | keep the behaviour; private helper |
| `Types.elm:588-626` | `computeCtorLayout` (cap at `:597`, bitmap at `:602-615`) | 3C.1 |
| `Expr.elm:492`, `:512`, `:526` | `computeRecordLayout` for create / access / update | no change (they use `fields` / `index` / `isUnboxed`) |
| `Expr.elm:7253` | `generateRecordCreate` → `Ops.ecoConstructRecord … layout.unboxedBitmap` | 3C.3 |
| `Expr.elm:7400` | `generateRecordUpdate` → `Ops.ecoConstructRecord … layout.unboxedBitmap` | 3C.3 |
| `Expr.elm:7479`, `:7483` | tuple construct with `layout.unboxedBitmap` | no change (TupleLayout) |
| `Expr.elm:8495` | `generateCustomCreateValue` (`eco.make.custom` aggregate; no bitmap) | no change |
| `Expr.elm:8524-8538` | `generateCustomCreateHeap` → `Ops.ecoConstructCustom … layout.unboxedBitmap` | 3C.3 |
| `Expr.elm:859`, `1245-1250`, `1362`, `1849…2782`, `6010-6056`, `6241-6269` | closure bitmaps | Phase 2's; must already be gone (3C-0d) |
| `Patterns.elm:388`, `:395` | split-tuple materialise | no change |
| `Patterns.elm:405` | `materializeSplitParam`, `SplitCtor` → `Ops.ecoConstructCustom … layout.unboxedBitmap` | 3C.3 |
| `Patterns.elm:889` | `generateMonoFieldOnHeap` record layout | no change (P1's B3 fix keys on `isUnboxed`) |
| `Patterns.elm:966`, `:1143` | ctor layout for projection | no change |
| `Functions.elm:474` | `MonoCtor` → `generateCtor` | no change |
| `Functions.elm:1880` | `generateCtor` → `Ops.ecoConstructCustom … ctorLayout.unboxedBitmap …` (after P1/A.1 it passes `List.reverse slotPairsRev`) | 3C.3 |
| `Functions.elm:1120`, `:1123`, `:1728`, `:1731` | sret tuple boxing with `sretInfo.layout.unboxedBitmap` | no change (TupleLayout) |
| `BytesFusion/Emit.elm:1854` | `Just ()`: kinds `0` | 3C.3: `[ 0 ]` |
| `BytesFusion/Emit.elm:1879-1882` | `Just prim`: `bitmapSetKind 0 0 (mlirTypeToKind varType)` | 3C.3: `[ Types.mlirTypeToKind varType ]` |
| `BytesFusion/Emit.elm:1894` | `Just boxed`: kinds `0` | 3C.3: `[ 0 ]` |
| `Backend.elm:1040`, `TailRec.elm:501` | `SplitCtor` layouts for 2..6-field ctors | no change (≤ 6 fields: identical layouts) |
| `TypeTable.elm:241`, `:452` | type-table field order and type ids only | no change (verified: no kind information emitted) |
| `LogicalTypes.elm:111` | `LRecord (List.map (kindOf << .monoType) layout.fields)`: kinds from types, not `isUnboxed` | no change; the field order is unchanged |
| `GlobalOpt/AbiCloning.elm:2828`, `:2954`, `:2998-3004` | ctor cap comments/guard | done in P1 (3C-0e); re-read the docs at `:2828`, `:2954` and fix any stale "24" text |
| `Ops.elm:4`, `:33` | exports | unchanged names |
| `Ops.elm:292-325` | `ecoConstructRecord` | 3C.2 |
| `Ops.elm:329-370` | `ecoConstructCustom` | 3C.2 |
| `Ops.elm:245-283` | tuple builders | no change |
| `Ops.elm:1466`, `:1512-1513`, `:1582` | papCreateGroup `unboxedBitmap(s)` | Phase 2's |

**Mono side (MONO_013).** `Compiler/AST/Monomorphized.elm` and `Compiler/Monomorphize/*` contain no
slot cap or bitmap (the only "26" hits are the 2^26 hash bounds at `Monomorphized.elm:52-53`,
`:204`). Ctor shapes carry only field types. MONO_013's wording is updated in 3D.8; there is no code change here.

#### `compiler/tests`

| Site | Phase 3C action |
|---|---|
| `TestLogic/Generate/CodeGen/UnboxedBitmap.elm:25`, `:130-157` (`checkContainerBitmap` reads `unboxed_bitmap`; a missing bitmap reads as 0, so after this phase **every unboxed record/custom operand would be reported**) | 3C.4: read `slot_kinds` for record/custom ops |
| `UnboxedBitmap.elm:164` (doc: "52 bits … bitmapSetKind") | reword |
| `UnboxedBitmapTest.elm:49-51` (`wideRecord`, 17 Ints + 2 Strings) | keep; add the cases in 3C.6 |
| `CtorLayoutConsistency.elm:3-41`, `:67`, `:134-221` (`getIntAttr "unboxed_bitmap"`; `layoutMatches` compares `layout.unboxedBitmap`; **every op would report "missing … unboxed_bitmap attribute"**) | 3C.4: compare `slot_kinds` with `Types.ctorSlotKinds layout` |
| `CtorLayoutConsistencyTest.elm:4`, `:19`, `:23` (docs) | reword |
| `DestructorTypeProjection.elm:17`, `:116-136` (`checkRawBoxedRead`: an `eco.project.custom` with `field_index >= 24` and a primitive result **is reported**), `:205-213` (`isCustomProjection`: counts only `field_index < 24`) | 3C.5: remove the index rule. After this phase a field at 24 or above is stored unboxed when its type is primitive, so `project.custom[24] -> i64` is correct |
| `DestructorTypeProjectionTest.elm:138-190` (pin "Int field past the unboxed slot cap is projected boxed, then unboxed") | 3C.5: rewritten to the new layout |
| `DestructorTypeProjection.elm` `checkRecordFieldProjection` (added in Phase 0 step 0.6a, used by the B3 pin; it derives "boxed" from `Types.computeRecordLayout`) | 3C.5: no code change. After 3C.1 every primitive record field is unboxed, so it simply sees no boxed primitive slots; re-run it |
| `DestructorTypeProjectionTest.elm` B3 record pin ("record pattern of a field past the record slot cap is projected boxed, then unboxed", 28-Int record, `viaPat { f27, f25 }`) | 3C.5: rename to "record pattern of field 27 of a 28-Int record is projected unboxed (i64)"; the program is unchanged, and the expectation becomes `project.record[27] -> i64` with no unbox |
| `CallAbiConsistencyTest.elm:69-106` (pin "constructor with a field past the unboxed slot cap is called with matching operand types") | 3C.5: rename and re-document; code unchanged (it passes: param `i64`, slot `i64`) |
| `TestLogic/Monomorphize/MonoCtorLayoutIntegrity.elm:13`, `:34` | docs only; no change needed |
| `CustomConstruction.elm:17`, `RecordConstruction.elm:12` | docs mention the Ops builders; no change |


All of 3C.1–3C.5 are **one commit**. The front-end emission, the layout change and the checkers that
read the attribute must change together, or elm-tests go red for the wrong reason. The steps are
ordered so the compiler builds after each, for local iteration.

### 3C.1 `Types.elm`, layouts without caps and without Elm-side bitmaps

`compiler/src/Compiler/Generate/MLIR/Types.elm`

1. **Exports** (`:6-9`, `:53-56`): remove `bitmapSetKind`; add `ctorSlotKinds` and
   `recordSlotKinds`.
2. **Module doc** (`:37-43`). Before: "…A record field at index 26 or above, and a constructor field
   at index 24 or above, is stored boxed even when it could be unboxed." After: "Every Int, Float
   and Char field of a record or constructor is stored unboxed, whatever its index. A slot's kind is
   recorded per slot (`ctorSlotKinds`, `recordSlotKinds`), and the backend packs the kinds of slots
   beyond an object's header bitmap into extension words (HEAP_019). Tuples keep a small Elm-side
   bitmap (`TupleLayout.unboxedBitmap`, at most 3 slots)."
3. **Layout types** (`:354-359`, `:381-387`):
   ```elm
   type alias RecordLayout =
       { fieldCount : Int
       , fields : List FieldInfo
       }

   type alias CtorLayout =
       { name : Name
       , tag : Int
       , fields : List FieldInfo
       }
   ```
4. **Kinds helpers** (new, after `encodeUnboxedKind` at `:407-420`):
   ```elm
   {-| The slot kind of each field of a constructor layout, in field order: 1 Int,
   2 Float, 3 Char for an unboxed field, 0 for a boxed one. This is the
   `slot_kinds` attribute of `eco.construct.custom` (HEAP_019, CGEN_020).
   -}
   ctorSlotKinds : CtorLayout -> List Int
   ctorSlotKinds layout =
       List.map fieldSlotKind layout.fields


   {-| The slot kind of each field of a record layout, in layout order (the
   `slot_kinds` attribute of `eco.construct.record`).
   -}
   recordSlotKinds : RecordLayout -> List Int
   recordSlotKinds layout =
       List.map fieldSlotKind layout.fields


   fieldSlotKind : FieldInfo -> Int
   fieldSlotKind field =
       if field.isUnboxed then
           encodeUnboxedKind field.monoType

       else
           0
   ```
5. **Delete** `maxTypedSlots` (`:423-430`) and the exported `bitmapSetKind` (`:432-454`). Replace
   them with a private tuple-only helper. It is exact because a tuple has at most 3 slots, so the
   value is below 4^3:
   ```elm
   {-| The bitmap of a tuple layout (at most three slots, so plain Int
   arithmetic is exact): slot i's kind times 4^i.
   -}
   tupleBitmap : List Int -> Int
   tupleBitmap kinds =
       List.foldr (\kind acc -> acc * 4 + kind) 0 kinds
   ```
   `computeTupleLayout` (`:556-580`) then computes:
   ```elm
   unboxedBitmap =
       tupleBitmap
           (List.map
               (\( ty, isUnboxed ) -> if isUnboxed then encodeUnboxedKind ty else 0)
               elements
           )
   ```
   This is the same value as today (`bitmapSetKind` of 3 slots).
6. **`computeRecordLayout`** (`:465-518`):
   - before (`:490`): `isUnboxed = canUnbox ty && idx < maxTypedSlots`; after:
     `isUnboxed = canUnbox ty`;
   - delete `unboxedCount` (`:495-496`) and `unboxedBitmap` (`:498-511`);
   - the returned record is `{ fieldCount = List.length orderedFields, fields = indexedFields }`;
   - keep `sortedUnboxed ++ sortedBoxed` (`:471-482`) unchanged: changing the order would move every
     record's layout;
   - doc (`:457-463`): drop "A field at index 26 or above is stored boxed…".
7. **`computeCtorLayout`** (`:588-626`):
   - before (`:597`): `isUnboxed = canUnbox ty && idx < 24`; after: `isUnboxed = canUnbox ty`;
   - delete `unboxedBitmap` (`:602-615`) and `unboxedCount` (`:618-619`);
   - the result is `{ name = shape.name, tag = shape.tag, fields = fields }`;
   - doc (`:583-587`): drop the index-24 sentence.

**Invariants preserved:**
- REP_ABI_001: unaffected; ABI types come from `monoTypeToAbi`.
- MONO_029: the layout is a pure function of the mono type.
- CGEN_026 equivalence: the kinds come from the same `isUnboxed` the construct sites use to choose
  operand types.

**Build check:** `cmake --build build --target elm-tests` will not compile until 3C.2–3C.5 are in.
Iterate with the compiler build (`cmake --build build`, which builds Stage 1 `compiler/bin/index.js`)
and read the Elm compile errors: they list exactly the remaining `unboxedBitmap` users.

### 3C.2 `Ops.elm`, builders take kinds

`compiler/src/Compiler/Generate/MLIR/Ops.elm`

```elm
-- before (:292-293)
ecoConstructRecord : Ctx.Context -> List ( String, MlirType ) -> String -> List ( String, MlirType ) -> Int -> Int -> ( Ctx.Context, MlirOp )
ecoConstructRecord ctx gcRootHints resultVar fieldPairs fieldCount unboxedBitmap =
-- after
ecoConstructRecord : Ctx.Context -> List ( String, MlirType ) -> String -> List ( String, MlirType ) -> Int -> List Int -> ( Ctx.Context, MlirOp )
ecoConstructRecord ctx gcRootHints resultVar fieldPairs fieldCount slotKinds =
```
In `attrs` (`:313-318`), replace `( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )` with
`( "slot_kinds", slotKindsAttr (checkKindsLength "eco.construct.record" fieldCount slotKinds) )`.

```elm
-- before (:329-330)
ecoConstructCustom : Ctx.Context -> List ( String, MlirType ) -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> Maybe String -> ( Ctx.Context, MlirOp )
ecoConstructCustom ctx gcRootHints resultVar tag size unboxedBitmap operands maybeCtorName =
-- after
ecoConstructCustom : Ctx.Context -> List ( String, MlirType ) -> String -> Int -> Int -> List Int -> List ( String, MlirType ) -> Maybe String -> ( Ctx.Context, MlirOp )
ecoConstructCustom ctx gcRootHints resultVar tag size slotKinds operands maybeCtorName =
```
In `attrs` (`:358-366`), replace `( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )` with
`( "slot_kinds", slotKindsAttr (checkKindsLength "eco.construct.custom" size slotKinds) )`.

`slotKindsAttr` is Phase 2's helper (3C-0c). New helper `checkKindsLength`:
```elm
{-| Crashes when a construct op is given a kinds list whose length is not its
slot count: the C++ verifier would reject the op anyway, and the crash names
the emitter.
-}
checkKindsLength : String -> Int -> List Int -> List Int
checkKindsLength opName count kinds =
    if List.length kinds == count then
        kinds

    else
        Utils.Crash.crash
            (opName ++ ": slot_kinds has " ++ String.fromInt (List.length kinds)
                ++ " entries for " ++ String.fromInt count ++ " slots")
```
Add `import Utils.Crash` if `Ops.elm` doesn't have it yet (`grep -n "^import Utils.Crash" Ops.elm`).
Update the two docstrings (`:290`, `:327`) to name `slot_kinds`.

### 3C.3 Every caller passes the layout's kinds

| Caller | Before | After |
|---|---|---|
| `Expr.elm:7253`, `generateRecordCreate` | `… fieldVarPairs layout.fieldCount layout.unboxedBitmap` | `… fieldVarPairs layout.fieldCount (Types.recordSlotKinds layout)` |
| `Expr.elm:7400`, `generateRecordUpdate` | `… fieldVarsAndTypes layout.fieldCount layout.unboxedBitmap` | `… fieldVarsAndTypes layout.fieldCount (Types.recordSlotKinds layout)` |
| `Expr.elm:8533-8540`, `generateCustomCreateHeap` | `layout.tag (List.length layout.fields) layout.unboxedBitmap slotPairs …` | `layout.tag (List.length layout.fields) (Types.ctorSlotKinds layout) slotPairs …` |
| `Patterns.elm:405`, `materializeSplitParam` (`Ctx.SplitCtor layout`) | `layout.tag (List.length info.slots) layout.unboxedBitmap info.slots …` | `layout.tag (List.length info.slots) (Types.ctorSlotKinds layout) info.slots …` |
| `Functions.elm:1880`, `generateCtor` (post-P1 form, Appendix A.1) | `ctorLayout.tag arity ctorLayout.unboxedBitmap (List.reverse slotPairsRev) constructorName` | `ctorLayout.tag arity (Types.ctorSlotKinds ctorLayout) (List.reverse slotPairsRev) constructorName` |
| `BytesFusion/Emit.elm:1854` | `Ops.ecoConstructCustom ctx3 [] justVar 0 1 0 [ ( unitVar, Types.ecoValue ) ] (Just "Just")` | `… 0 1 [ 0 ] [ ( unitVar, … ) ] …` |
| `BytesFusion/Emit.elm:1876-1882` | `bitmap = Types.bitmapSetKind 0 0 (Types.mlirTypeToKind varType)` then `… 0 1 bitmap …` | delete `bitmap`; `… 0 1 [ Types.mlirTypeToKind varType ] [ ( varName, varType ) ] …` |
| `BytesFusion/Emit.elm:1894` | `… 0 1 0 [ ( varName, Types.ecoValue ) ] …` | `… 0 1 [ 0 ] …` |

Also update the BytesFusion doc at `:1860-1863` ("with unboxed_bitmap = 1/0" becomes "slot kind
1..3 / 0").

**Why the layout's kinds and not the operands':**
- `prepareCtorSlots` (`Expr.elm:8557ff`), `generateCtor` (A.1) and `generateRecordCreate` /
  `generateRecordUpdate` already coerce each operand to its layout slot type, so the two agree when
  the code is correct.
- When it isn't (the B1/B2/B3 bug class), the C++ verifier reports the mismatch instead of silently
  storing a primitive in a slot the projection reads as a pointer.

**After P1/A.1, `generateCtor`'s boxing loop is dead for Int/Float/Char.** Their ABI type now equals
their slot type. Bool's ABI is `!eco.value` (REP_ABI_001), and so is its slot. Keep the loop as
defensive code; do not delete it in this phase.

### 3C.4 Retarget the two attribute checkers

**4a. `compiler/tests/TestLogic/Generate/CodeGen/UnboxedBitmap.elm`.**
- Split `targetOps` (`:88-118`):
  - `tuple2Ops ++ tuple3Ops` keep `checkContainerBitmap` (unchanged);
  - `recordOps ++ customOps` go through a new `checkContainerSlotKinds`.
- Add `extractInt` to the import from `TestLogic.Generate.CodeGen.Invariants` (`:51-59`); it is
  exposed at `Invariants.elm:218`.
```elm
{-| Returns the violations in the `slot_kinds` of a record or custom construct
op: the attribute must be present and hold one kind per field, and slot N's kind
must be the kind operand N's type requires. Trailing GC-root hint operands
(beyond the slot count) are not compared. An op with no recorded operand types
gives none.
-}
checkContainerSlotKinds : MlirOp -> List Violation
checkContainerSlotKinds op =
    case ( getArrayAttr "slot_kinds" op |> Maybe.map (List.filterMap extractInt), extractOperandTypes op ) of
        ( _, Nothing ) ->
            []

        ( Nothing, Just _ ) ->
            [ { opId = op.id, opName = op.name, message = op.name ++ " has no slot_kinds attribute" } ]

        ( Just kinds, Just operandTypes ) ->
            List.map2 (\( i, kind ) ty -> checkKindAgainstType op i kind ty) (List.indexedMap Tuple.pair kinds) operandTypes
                |> List.filterMap identity


checkKindAgainstType : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkKindAgainstType op index kind ty =
    if ty == I1 then
        Just { opId = op.id, opName = op.name, message = "operand " ++ String.fromInt index ++ " is i1 (Bool must be boxed)" }

    else if kind /= typeToKind ty then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "slot_kinds[" ++ String.fromInt index ++ "] = " ++ String.fromInt kind
                    ++ " but operand " ++ String.fromInt index ++ " has type requiring kind "
                    ++ String.fromInt (typeToKind ty)
            }

    else
        Nothing
```
- `getArrayAttr` must be added to the import list.
- The `MlirType` constructor for `i1` is whatever `checkBitmapKind` already matches. Reuse its `i1`
  test (read `:200ff`) rather than spelling `I1` if the name differs.
- Update the module doc (`:20-37`): records and customs carry `slot_kinds`; tuples carry
  `unboxed_bitmap`; the "52-bit" sentence applies to tuples only.

**4b. `compiler/tests/TestLogic/Generate/CodeGen/CtorLayoutConsistency.elm`.**
- `checkConstructOp` (`:139-190`): replace `getIntAttr "unboxed_bitmap" op` with
  `getArrayAttr "slot_kinds" op |> Maybe.map (List.filterMap extractInt)`. The tuple pattern becomes
  `( Just size, Just kinds )`.
- The failure messages (`:184`, `:188`) print the kinds list and say "slot_kinds" instead of
  "unboxed_bitmap".
- `layoutMatches` (`:194-196`):
  ```elm
  layoutMatches : Int -> List Int -> Types.CtorLayout -> Bool
  layoutMatches size kinds layout =
      List.length layout.fields == size && Types.ctorSlotKinds layout == kinds
  ```
- `layoutToString` (`:210-222`): `", kinds=" ++ kindsToString (Types.ctorSlotKinds layout)`, with
  `kindsToString = String.join "," << List.map String.fromInt`.
- Docs (`:3-41`, `:67`, `:134`) and `CtorLayoutConsistencyTest.elm:4`, `:19`, `:23`: "unboxed_bitmap"
  becomes "slot_kinds".

### 3C.5 Retarget the destructor-projection checker and its pins

**`compiler/tests/TestLogic/Generate/CodeGen/DestructorTypeProjection.elm`.**
- `checkRawBoxedRead` (`:115-136`) hard-codes "index ≥ 24 is boxed". After this phase that is false:
  a primitive field at 24 or above is unboxed and `eco.project.custom[24] -> i64` is correct.
  **Delete `checkRawBoxedRead`** and its use at `:112`.
  - The property it guarded (never read a boxed slot as a raw primitive) rests on the layout-driven
    projection code and on the construction-side `slot_kinds ⇔ operand types` verifier (3B.2), which
    keeps stores and layout in step. It is covered end to end by E3 and the `WideCtor*` E2E pins.
- **`checkRecordFieldProjection`** (Phase 0 step 0.6a) is layout-driven: it calls
  `Types.computeRecordLayout`, so it stays correct with no change. Rename and invert the B3 record
  pin as in the table above.
- `isCustomProjection` (`:204-213`): drop the `field_index < 24` clause, so every
  `eco.project.custom` counts:
  ```elm
  isCustomProjection : MlirOp -> Bool
  isCustomProjection op =
      op.name == "eco.project.custom"
  ```
- Module doc (`:17`, `:116`, `:205`): remove the index-24 statements.

**`DestructorTypeProjectionTest.elm` pin** (`testBoxedFieldPastSlotCap`, `:138-190`). It is renamed
and its expectation inverted; the program is unchanged:
- New name: `Test.test "Int field at index 24 is projected unboxed (i64) with no unbox"`.
- New function name: `testUnboxedFieldPastHeaderBitmap`.
- Same 25-`Int`-field `Wide` program.
- Expectation:
  - `expectProjectedWithoutSpuriousUnbox` passes (no `eco.unbox` on the projection);
  - **new assertion:** the module contains `eco.project.custom` with `field_index = 24` whose result
    type is `i64`.

  Add a helper next to `countCustomProjections`:
  ```elm
  hasProjectionOf : Int -> MlirType -> MlirModule -> Bool
  hasProjectionOf index ty mlirModule =
      findOpsNamed "eco.project.custom" mlirModule
          |> List.any (\op -> getIntAttr "field_index" op == Just index && List.map Tuple.second op.results == [ ty ])
  ```
  The test is `Expect.all [ projected-without-spurious-unbox, \m -> hasProjectionOf 24 I64 m |> Expect.equal True ]`
  over `runToMlir`'s module.
- Docstring: say the field is unboxed because layouts have no index cap (HEAP_019).
- **Boxed path past the header bitmap (String-at-24 variant).** Add
  `Test.test "boxed field at index 24 is projected as !eco.value"` (`testBoxedStringFieldAtIndex24`):
  the same program shape with field 24 of type `String` (`tType "String" []`) and
  `lastField : Wide -> String` returning `f24`, built from `strExpr "x"` arguments (check the helper
  name in the test's imports). It asserts `project.custom[24] -> !eco.value` and no violations, and
  pins the `Patterns.elm` CustomContainer boxed branch at an index past the header bitmap. A
  primitive is never boxed by index any more, so no Int variant of that path exists. Register it in
  the module's `suite` list.
- **Polymorphic variant** (cheap, add it): `testPolymorphicFieldAtIndex24` with
  `type Wide a = Wide Int … a`, used at `a = Int`. It exercises `lookupCtorFieldInfo`'s
  shape-scanning path (`Patterns.elm:1112-1143`) past slot 24.

**Phase 1's B3 record pin** (`DestructorTypeProjectionTest.elm`, "record field past the record slot
cap is projected boxed, then unboxed"; 28-`Int` record, `viaPat { f27, f25 } = f27`). Same program,
inverted expectation:
- New name: `Test.test "record field 27 of a 28-Int record is projected unboxed (i64)"`.
- Expectation: no violations, and an `eco.project.record` with `field_index = 27` whose result type
  is `i64` (a `hasRecordProjectionOf` twin of `hasProjectionOf`, using `"eco.project.record"`).

**`CallAbiConsistencyTest.elm`** (`wideCtorCallTest`, `:75-107`): code unchanged.
- Rename the test (`:77`) to `"constructor with 25 Int fields is called with matching operand types"`.
- Docstring (`:67-74`): "`computeCtorLayout` stores field 24 unboxed as `i64`; the constructor
  function's parameter and slot are both `i64`. The test still pins REP_ABI_001 for constructors
  wider than the header bitmap." It must still pass.

### 3C.6 New elm-test cases (fail-first where possible)

In `UnboxedBitmapTest.elm` (`suite`, `:47-52`) add:

1. `Test.test "a record with 30 Int fields is fully unboxed in slot_kinds"`.
   - Program: `testValue : { i00 : Int, …, i29 : Int }` (30 fields) as a record literal, built the
     same way as `wideRecord` (`:56-80`).
   - Expectation: `expectUnboxedBitmap` passes, **and** the record op's `slot_kinds` equals
     `List.repeat 30 1`.
   - Add a small `expectSlotKinds : String -> List Int -> Src.Module -> Expectation` helper in
     `UnboxedBitmap.elm` (exposed), which finds the single op of the given name and compares its
     `slot_kinds`.
   - **Fail-first:** before 3C.1 the op carries `unboxed_bitmap`, no `slot_kinds`, so it fails on
     the missing attribute.
2. `Test.test "a constructor with 30 Int fields is fully unboxed in slot_kinds"`. A
   `type W = W Int … Int` (30 fields) and `testValue = W 0 … 29`; `slot_kinds == List.repeat 30 1`
   on the `eco.construct.custom`.
3. `Test.test "mixed record kinds past slot 26"`. 28 fields: `f00..f13 : Int`, `g00..g09 : Float`,
   `c0..c1 : Char`, `s0..s1 : String`.
   - Expected `slot_kinds`: the layout order is primitives first by name, then boxed by name. That
     is `c0,c1` (3,3), `f00..f13` (1 ×14), `g00..g09` (2 ×10), then `s0,s1` (0,0).
   - So `[3,3] ++ List.repeat 14 1 ++ List.repeat 10 2 ++ [0,0]`.
   - Check the name ordering against `computeRecordLayout`'s `List.sortBy Tuple.first` (it uses Elm
     `String` comparison, so `"c0" < "f00" < "g00"`).

### 3C.7 Run the gate (3C commands, then 3C gate)

### 3C.E Expected effects

- **E2E:**
  - Records with 27–32 Int/Float/Char fields now store every primitive unboxed in the 64-bit header
    word (no ext words, since ≤ 32 slots). `WideRecordPatternTest` (E3, 28 Ints) stays green: the P1
    B3 fix projects by `isUnboxed`, now `True` for f26/f27.
  - `WideRecordDecoder26Test` (E8, 26 and 30 fields) stays green, with its 30-field record fully
    unboxed.
  - Nothing else in the corpus has records of more than 26 primitives (`CrossSpecWideRecordTest`:
    6; `WideRecordGcBitmapTest`: 1 Int).
- **No pin flips to green in this phase.** The Custom ≥ 25 and Record ≥ 33 pins still stop at the C++
  verifier caps (Phase 3D).

**Expected-failure list for the 3C E2E gate:** **list L3** (top of this file), by name and reason
(overview §6.2). Any other failure, or any of these failing for another reason, fails the gate.

**elm-tests expected result:** only the 2 GOPT_003 failures (`MonoCaseBranchResultTypeTest`). The wide
pins pass (renamed in 3C.5), and the 3C.5/3C.6 cases pass.

**Bootstrap:**
- The compiler's own output changes only where the self-compile builds records with more than 26
  primitives (the Phase 0 census row, phase-0 Step 0.4) and in the attribute form (`slot_kinds` replaces `unboxed_bitmap` on
  every record/custom construct).
- Expect stage A ≠ B, since the attribute change propagates. **Gate B == C** (memory:
  "a default flip needs ONE EXTRA bootstrap iteration").

**Performance (overview §7):**
- Wall flat.
- The GC counters (minor/major cycles, promoted MiB, objects allocated) may differ from Phase 3B
  **only** by the census's records with more than 26 primitives: each such construction no longer
  allocates boxes for primitive fields 26–31.
- If the census row is 0, the counters must be bit-identical to Phase 3B. A non-zero delta with a zero
  census is a bug: stop.
- MLIR size grows slightly (`array<i8: …>` instead of one integer). This is not gated; note it in the
  entry.

### 3C commands (overview §S.7; each command once, tee'd, then read the file)

```bash
# 1. front-end build + elm-tests
cmake --build build 2>&1 | tee /tmp/p5_build.txt            # Stage 1 compiler; read Elm errors here
cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt
grep -E "Passed|Failed|✗|FAIL" /tmp/test_output.txt | head -40

# 2. text-MLIR spot check of the new attribute (scratch dir only)
mkdir -p /tmp/claude-1000/-work/04eeaa03-3e96-4a66-af5b-c09e4554e41e/scratchpad/phase5 && cd $_ \
  && cp /work/build/test/elm/elm.json . && mkdir -p src && cp /work/test/elm/src/WideRecordPatternTest.elm src/ \
  && node /work/compiler/bin/index.js make src/WideRecordPatternTest.elm --output=R.mlir --text-mlir \
  && grep -o 'slot_kinds = array<i8:[^>]*>' R.mlir | sort | uniq -c
#    expect one record op with 28 entries of 1; no "unboxed_bitmap" on construct.record/custom:
grep -c '"eco.construct.record".*unboxed_bitmap' R.mlir   # expect 0
#    bytecode path (default, no --text-mlir) must lower too (exercises 3C-0b):
node /work/compiler/bin/index.js make src/WideRecordPatternTest.elm --output=R.mlirbc \
  && /work/build/runtime/src/codegen/eco-boot-native R.mlirbc -o R.elf && ./R.elf | grep -E "pat|f27"

# 3. E2E (cache wipe first)
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.1.3/packages \( -name artifacts.dat -o -name typed-artifacts.dat \) -delete
rm -rf ~/.eco/0.1.3/packages/eco/kernel
ulimit -c 0; cmake --build build --target full 2>&1 | tee /tmp/test_output_e2e.txt
grep -E "FAILED|failed|PASS|passed" /tmp/test_output_e2e.txt | tail -40   # compare with 3C.E list

# 4. AOT, bootstrap, perf (as the gate requires)
cmake --build build --target run-aot-e2e 2>&1 | tee /tmp/test_output_aot.txt        # eco-stuff moved aside first
cmake --build build --target bootstrap 2>&1 | tee /tmp/test_output_boot.txt && cmake --build build --target eco-verify 2>&1 | tee -a /tmp/test_output_boot.txt
# perf: benchmarks/fe-opt-loop.md §1 timed triple; record wall, GC time and counters next to the 3B row
```

### 3C rollback

- **3C.1–3C.5 are one commit; revert it as a unit.** The C++ side (Phases 2–3B) accepts both forms,
  so the previous front end, which emits `unboxed_bitmap`, keeps working.
- 3C.6 tests are in the same commit; they revert with it.
- After 3D.5 deletes `unboxed_bitmap` from `Ops.td`, 3C can no longer be reverted alone
  (overview §8).

### 3C open questions (resolved, or with a default)

1. **Emit both `unboxed_bitmap` and `slot_kinds` during the transition?** **No.**
   - For records of 27–32 primitives the bitmap is not exactly representable in Elm (bits up to 63).
   - The C++ side verifies `slot_kinds` whenever present (Phase 3B).
   - Tuples/cons keep their bitmap.
2. **Should `slot_kinds` come from operand types (simpler) or the layout?** **The layout** (3C.3
   rationale).
3. **Delete `generateCtor`'s now-dead primitive boxing loop?** **No** (defensive; harmless).
4. **`unboxedCount` removal:** it has no user outside `Types.elm` (grep), so remove it with
   `unboxedBitmap`.

### 3C checklist

- [x] 3C-0a…3C-0f preconditions verified.
- [x] `Types.elm`: caps gone; `ctorSlotKinds` / `recordSlotKinds` added; `bitmapSetKind` /
  `maxTypedSlots` gone (tuples use a private `tupleBitmap`); module and function docs reworded.
- [x] `Ops.elm`: new signatures; `slot_kinds` emitted; `checkKindsLength` crash guard.
- [x] All 8 caller sites of 3C.3 converted; `grep -rn "unboxedBitmap" compiler/src` lists only
  `TupleLayout` users (`Types.elm` tuple layout, `Expr.elm:7479/7483`, `Patterns.elm:388/395`,
  `Functions.elm:1120/1123/1728/1731`) plus any Phase 2 leftovers (should be none).
- [x] `grep -rn "bitmapSetKind\|maxTypedSlots" compiler/src compiler/tests` lists only doc text, or
  is empty.
- [x] `UnboxedBitmap.elm`, `CtorLayoutConsistency.elm` and `DestructorTypeProjection.elm`
  retargeted (`checkRawBoxedRead` deleted; `checkRecordFieldProjection` unchanged); custom, record and CallAbi
  pins renamed/rewritten; String-at-24 and polymorphic variants; three new 3C.6 cases.
- [x] elm-tests: only the 2 GOPT_003 failures.
- [x] Text and bytecode spot checks (3C commands 3C.2).
- [x] `full` after a cache wipe: failures exactly equal the 3C.E list.
- [x] `run-aot-e2e` (known harness gaps only); bootstrap B==C.
- [x] Perf triple: counter delta explained by the census (or zero).
- [x] 3C perf row recorded next to the Phase 0 baseline (overview §7).

### 3C gate result (recorded 2026-10-05, combined 3B + 3C)

- elm-tests: 14,078 pass / 2 fail (GOPT_003).
- Spot check: `WideRecordPatternTest` text MLIR has `slot_kinds` (28 × 1 on the record ops) and 0
  record ops with `unboxed_bitmap`. The plan's ELF step (`eco-boot-native R.mlirbc -o R.elf`) cannot
  run here: this `eco-boot-native` is not linked with EcoNativeDriverStatic ("native driver
  unavailable"); the bytecode path is covered by `full`, which compiles bytecode by default.
- `full` (cache wiped): 2,123 run, 2,113 pass, 10 fail = L3. AOT: 922/934 = L3 + FlagsRecordTest +
  PortEchoTest. Bootstrap: Stage 4b/8c fixed points hold, `eco-verify` rc 0.
- Perf triple (`eco-optP3c`, sha256 `207c476d3021f530…`): 69.91 / 68.87 / 69.29 s (median 69.29;
  3A 69.26 interleaved: flat); minor 1337, major 6, promoted 178,467,331 (6392 MiB), objects
  ≈ 304,185,150, GC 2.78–2.80 s; deterministic + fixed point. Against 3A: about 164k fewer objects
  allocated and 24k fewer promoted (records with primitives past slot 26 no longer box them — the
  census's 5 sites — plus the compiler source changed in 3C), one more minor GC. Output MLIR +2.6 KB
  (`slot_kinds` arrays instead of one integer).

### 3C gate (all must hold)

1. elm-tests: exactly the 2 GOPT_003 failures.
2. `full` E2E (cache wiped): failures equal list L3, by name and reason.
3. `run-aot-e2e`: the same pass/fail set as the Phase 0 baseline, adjusted only by pins that flipped
   earlier.
4. Bootstrap fixed point B == C.
5. Perf triple: wall inside the spread; counters bit-identical to 3B when the census row is 0, else
   the delta is explained.
6. No C++ change in this phase. `tla-canary` and unit tests need not be re-run beyond the default ALL
   build's warn-only canary.

---

## 3D. Lift the caps, remove the test switch and the old bitmap attributes, final gate

**In one paragraph:**
- Phase 2 and 3A–3C made every Custom/Record/Closure kind travel as `slot_kinds`, made the runtime
  and lowering understand tail kind words, and made the front end emit wide objects.
- What still stops a wide Custom/Record from compiling is the two old verifier caps (24 / 32). A
  test switch (§S.6) lets fixtures bypass them.
- 3D lifts the caps to the real limits (**Custom 2040, Record 2047**, §S.1), adds the user-facing
  limit errors, and removes the test switch.
- It sweeps the codegen fixtures onto `slot_kinds`, then deletes the old u64 bitmap attributes
  (`unboxed_bitmap` on construct.custom / construct.record / papCreate / to_heap,
  `newargs_unboxed_bitmap` on papExtend, `unboxed_bitmaps` on papCreateGroup). Tuple2/Tuple3 keep
  `unboxed_bitmap`; list keeps `head_unboxed` / `head_kind`.
- It flips the last pins (list L3), writes the invariants and theory docs, and runs the plan's final
  gate.

### 3D.P Preconditions and decisions

| # | Precondition (verify before 3D.1) | How to verify |
|---|---|---|
| 3D-P1 | Phases 0, 1, 2 and 3A–3C are complete and their gates passed (list L3 at 3C) | the 3C gate record |
| 3D-P2 | `slot_kinds` exists on construct.custom, construct.record, papCreate, papExtend, papCreateGroup (and optionally to_heap). The front end emits it on **every** such op (Phase 2 for closures, Phase 3C for construct) | `grep -rn '"unboxed_bitmap"\|newargs_unboxed_bitmap\|unboxed_bitmaps' compiler/src` returns only the tuple2/tuple3 emitters in `compiler/src/Compiler/Generate/MLIR/Ops.elm` (`ecoConstructTuple2`, `ecoConstructTuple3`; today `Ops.elm:256`, `:280`) |
| 3D-P3 | The old attributes are **optional** in `Ops.td` (Phases 2/3B turned them from `DefaultValuedAttr`/`I64Attr` into `OptionalAttr`, verified "when present" with `hasAttr`) | read the six op definitions named in 3D.5 |
| 3D-P4 | The test switch (§S.6) is in place: the module attribute `eco.allow_wide_objects`, `wideObjectsAllowed` (3B.2.2), the `EcoRunner` hook (3B.2.6) and `Elm::testing::allow_wide_objects` (Phase 1, used by 3A.8) | `grep -rn "allow_wide_objects\|wideObjectsAllowed" runtime/src test` |
| 3D-P5 | The Phase 0 baselines are recorded (elm-tests 14,059/4, E2E 2,040/1, AOT list, bootstrap, perf triple + counters, censuses) | the phase-0 baselines table |
| 3D-P6 | `slot_kinds` is still **optional** (§S.5): verified when present, derived from operand types when absent, so un-swept fixtures pass until 3D.4/3D.5 | read the verifiers named in 3D.5 |

**Decisions resolved here (from reading the code):**
- **3D-D1. The caps come from `Heap.hpp`.** `runtime/src/codegen/EcoOps.cpp:12` already includes
  `../allocator/Heap.hpp` (for `NULL_CONS_MAX`), so the verifiers use `Elm::CUSTOM_MAX_FIELDS` and
  `Elm::RECORD_MAX_FIELDS` directly. No duplicate constant is needed.
- **3D-D2. `slot_kinds` becomes required** on construct.custom, construct.record, papCreate,
  papExtend and papCreateGroup once the old attributes are gone. It keeps the production layout
  check that was the reason for `slot_kinds` (overview §2.4). It stays **optional on `eco.to_heap`**:
  - the front end never sets a kind attribute on to_heap (`compiler/src/Compiler/Generate/MLIR/Ops.elm`
    `ecoToHeap`, today `:820-864`, emits only `_operand_types` and `eco.gc_roots_count`);
  - `materialiseAsBoxed` (`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:2155-2162`) builds it with no
    attributes;
  - its kinds come exactly from the aggregate's element types (3B.5 derives them with
    `slotKindOf` / `packKinds`).
- **3D-D3. Stale-MLIR guard.** After the old attributes leave the op definitions, MLIR would carry a
  leftover `unboxed_bitmap` on these ops as an unregistered discardable attribute and silently
  ignore it. A stale `.mlir` cache produced by a pre-3C compiler would then run with kinds
  derived from operand types only.
  - Each of the five verifiers rejects the old attribute names explicitly, with
    `"stale attribute 'unboxed_bitmap': regenerate the MLIR (plans/wide-object-tail-kind-words.md Phase 3D)"`.
  - This also catches a missed fixture.
- **3D-D4. Front-end limit diagnostics (D5).** The verifier is the backstop, but users get a
  located error. Ctors with more than 2040 fields and records with more than 2047 fields are
  rejected in canonicalization (3D.2). That step reuses Phase 2's `TooLarge` error,
  `HeapLimits` module and report (overview §S.9), which already cover arity and captured
  variables.

---


### 3D.0 snapshot for rollback (mandatory, before any edit)

`lss-loop-snap.sh` covers `compiler/src compiler/src-xhr runtime/src elm-kernel-cpp/src
eco-kernel-cpp/src compiler/tests test/eco-kernel/src test/allocator test/gc-helper-tsan
test/gc-heap-tsan`, plus `design_docs/invariants.csv`, `THEORY.md`, `test/main.cpp` and the CMake files
(`benchmarks/lss-loop-snap.sh:24`, `:30`). It does **not** cover `test/codegen`, `test/elm/src`,
`design_docs/theory`, `test/tla` or `plans/`, so tar those too:

```bash
cd /work
benchmarks/lss-loop-snap.sh snap pre-wide-3d "wide objects: before Phase 3D (caps + attr deletion)"
tar czf snapshots/lss-loop/pre-wide-3d/extra.tgz test/codegen test/elm/src test/eco-kernel/src \
    design_docs/theory test/tla plans/wide-object-tail-kind-words*.md
mkdir -p snapshots/lss-loop/pre-wide-3d/bin
cp -p build/compiler/build-kernel/bin/eco-opt-prev snapshots/lss-loop/pre-wide-3d/bin/   # perf baseline arm
```

**Rollback of the whole phase:**

```bash
benchmarks/lss-loop-snap.sh restore pre-wide-3d
tar xzf snapshots/lss-loop/pre-wide-3d/extra.tgz
```

Then rebuild everything (`cmake --build build`) and wipe the caches (§S.7).

### 3D.1 lift the verifier caps

**File:** `runtime/src/codegen/EcoOps.cpp`.

(a) `CustomConstructOp::verify` (function at `:364`). **Before** (the form 3B.2.3 left):

```cpp
  const int64_t cap = wideObjectsAllowed(*this) ? 2040 : 24;
  if (size > cap)
    return emitOpError("size (") << size
           << ") exceeds Custom's 24-slot limit under 2-bit kind encoding";
  // + 3B.2.3's second `if` for the attribute case: "... exceeds Custom's 2040-field limit (HEAP_019)"
```

**After** (one cap, one message):

```cpp
  // HEAP_019: slots 0..23 in the header bitmap, the rest in <= 63 tail kind words.
  if (size > static_cast<int64_t>(Elm::CUSTOM_MAX_FIELDS)) {
    return emitOpError("size (") << size << ") exceeds Custom's "
           << Elm::CUSTOM_MAX_FIELDS << "-field limit (HEAP_019)";
  }
```

(b) `RecordConstructOp::verify` (function at `:438`). Before: the same `wideObjectsAllowed`
conditional with the 32-slot / 2047-field messages. After:

```cpp
  // HEAP_019: 32 header slots + <= 63 tail kind words; 2047 (not 2048) so the
  // record-alias constructor (arity = field count) fits CLOSURE_MAX_ARITY.
  if (fieldCount > static_cast<int64_t>(Elm::RECORD_MAX_FIELDS)) {
    return emitOpError("field_count (") << fieldCount << ") exceeds Record's "
           << Elm::RECORD_MAX_FIELDS << "-field limit (HEAP_019)";
  }
```

(c) `ToHeapOp::verify` (`:1405-1420`): 3B.2.3 added caps chosen by `wideObjectsAllowed`. Replace
them with the fixed limits, after the closure_env check:

```cpp
  if (auto rt = dyn_cast<eco::RecordType>(valTy); rt && rt.getFields().size() > Elm::RECORD_MAX_FIELDS)
    return emitOpError("record aggregate has ") << rt.getFields().size()
           << " fields; limit is " << Elm::RECORD_MAX_FIELDS << " (HEAP_019)";
  if (auto ct = dyn_cast<eco::CustomType>(valTy); ct && ct.getFields().size() > Elm::CUSTOM_MAX_FIELDS)
    return emitOpError("custom aggregate has ") << ct.getFields().size()
           << " fields; limit is " << Elm::CUSTOM_MAX_FIELDS << " (HEAP_019)";
```

After (a)–(c), `wideObjectsAllowed` has no caller; 3D.3 deletes it.

**Invariants:** HEAP_019 limits, and REP_BOUNDARY_002 (per-slot kind check unchanged; 3B moved it
onto `slot_kinds`).

**Tests, codegen fixtures in `test/codegen/`, new and generated by a script.** Check in the script
too: `test/codegen/gen_wide_limit_fixtures.py`, run once, outputs committed.

| Fixture | Content | RUN / expected |
|---|---|---|
| `construct_custom_2040.mlir` | `func.func @main() -> i64` builds a 2040-field `eco.construct.custom`. Field k is an `i64` constant k when `k % 3 == 0`, a boxed `eco.constant Empty` when `k % 3 == 1`, and an `f64` when `k % 3 == 2`, with matching `slot_kinds`. It calls `eco.dbg` on it, projects fields 23, 24, 55, 2039 as their kinds, and prints them | `// RUN: %ecoc %s -emit=jit 2>&1 \| %FileCheck %s`; CHECK the four values |
| `construct_record_2047.mlir` | the same for `eco.construct.record` with `field_count = 2047`; projects 31, 32, 63, 2046 | JIT, CHECK the four values |
| `construct_custom_2041_rejected.mlir` | 2041 fields | `// RUN: not %ecoc %s -emit=mlir 2>&1 \| %FileCheck %s`; `// CHECK: size (2041) exceeds Custom's 2040-field limit` |
| `construct_record_2048_rejected.mlir` | 2048 fields | `// CHECK: field_count (2048) exceeds Record's 2047-field limit` |

The 2040/2047 objects are about 16 KiB each, so they are large objects (≥ 8 KiB): this also
exercises the call path above 4096 B and `placeLarge`. Before writing the negative fixtures, check
how existing ones use `not` (e.g. `test/codegen/eco-case-scrutinee-invalid.mlir`) and copy that RUN
form.

**Same commit:** delete `test/codegen/wide_record_33_no_attr.mlir` (3B.F.5). It expected the old
32-slot cap without the attribute; a 33-field record is valid now, and
`construct_record_2048_rejected.mlir` takes over the cap check.

**Rollback:** revert the two `if` blocks, the `ToHeapOp` caps and the four fixtures, and restore
`wide_record_33_no_attr.mlir`.

### 3D.2 front-end limit diagnostics (3D-D4)

**Goal:** a source program with a ctor of more than 2040 fields, or a record type, record alias or
record literal of more than 2047 fields, gets a located canonicalization error naming it. Today it
would reach the verifier as an op-level error. This step **extends** the shared machinery Phase 2
built (overview §S.9, phase-2 steps 2.8.1–2.8.2); it adds no new error constructor.

1. **Constants:** add `maxCtorFields = 2040` and `maxRecordFields = 2047` to
   `compiler/src/Compiler/Data/HeapLimits.elm` (exposing list and comment pointing at `Heap.hpp`
   `CUSTOM_MAX_FIELDS` / `RECORD_MAX_FIELDS`). `Generate/MLIR/Types.elm` imports them where it
   needs the caps.
2. **Variants:** add `TooManyCtorFields Name` and `TooManyRecordFields (Maybe Name)` to
   `TooLargeWhat` in `compiler/src/Compiler/Reporting/Error/Canonicalize.elm`. Extend the
   `TooLarge` report `case` (phase-2 step 2.8.2) with these rows:

   | variant | title | subject | unit | invariant |
   |---|---|---|---|---|
   | `TooManyCtorFields name` | `TOO MANY FIELDS` | "The constructor `<name>`" | "fields" | HEAP_019 |
   | `TooManyRecordFields (Just name)` | `TOO MANY FIELDS` | "The record type `<name>`" | "fields" | HEAP_019 |
   | `TooManyRecordFields Nothing` | `TOO MANY FIELDS` | "This record" | "fields" | HEAP_019 |

   The advice line is "Split it into nested records or constructors."
3. **Emission sites:**
   - `compiler/src/Compiler/Canonicalize/Environment/Local.elm` `canonicalizeUnion` (`:502-503`):
     per ctor, if the arg count exceeds `maxCtorFields`, throw
     `TooLarge ctorRegion (TooManyCtorFields ctorName) n maxCtorFields`.
   - `canonicalizeAlias` (`:453-454`): if the alias body is a record with more than
     `maxRecordFields` fields, throw `TooLarge aliasRegion (TooManyRecordFields (Just aliasName)) n
     maxRecordFields`.
   - `compiler/src/Compiler/Canonicalize/Expression.elm` `Src.Record` (`:334`): a literal with too
     many fields gives `TooManyRecordFields Nothing` at the literal's region.
   - `compiler/src/Compiler/Canonicalize/Type.elm`: a record type annotation with too many fields
     gives `TooManyRecordFields Nothing` at the type's region (next to the `TupleLargerThanThree`
     check at `:116`).
4. **Pins** (add to `compiler/tests/TestLogic/Canonicalize/LimitErrorsTest.elm`, using the Phase 2
   `expectTooLarge`; build the source programmatically with `List.range`):
   - "a ctor with 2041 fields is TooLarge TooManyCtorFields" (2041, 2040);
   - "a record alias with 2048 fields is TooLarge TooManyRecordFields" (2048, 2047);
   - "a record literal with 2048 fields is TooLarge TooManyRecordFields Nothing";
   - "a ctor with 2040 fields and a record alias with 2047 fields are accepted" (boundary);
   - "the TooLarge field report says TOO MANY FIELDS" (rendered text contains the name and the
     limit).
5. **Command:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`. Expected:
   only the 2 GOPT_003 failures, and the five new cases green.
6. **CLI check (once):** a generated `Fields2048.elm` alias compiled with
   `node /work/compiler/bin/index.js make` exits non-zero, and its output contains `TOO MANY FIELDS`
   and the alias's line.

There is no E2E pin, because the harness has no expected-compile-error mode; the elm-tests and the
CLI check cover it.

**Rollback:** revert the two variants, their report rows, the two constants and the four sites.
Phase 2's arity diagnostics are untouched.

### 3D.3 Remove the test switch (§S.6)

After 3D.1 every Custom/Record within the real limits is legal, so the test-only switch has no job
left.

1. `grep -rn "eco.allow_wide_objects\|wideObjectsAllowed\|allow_wide_objects\|WideGuard" runtime/src test compiler`
   lists every definition and use.
2. Delete:
   - `wideObjectsAllowed` in `EcoOps.cpp` (3B.2.2; no caller after 3D.1);
   - the `EcoRunner` hook (3B.2.6) and its `Heap.hpp` include if nothing else needs it;
   - `Elm::testing::allow_wide_objects` in `Heap.hpp` (Phase 1);
   - the census line in `validateExtKinds` (3A.8: `if (!bad && k && !testing::allow_wide_objects) bad = true;`)
     and the `allowed=` field of its message. The K and padding checks stay;
   - unit test T8 (3A.9, the census death test) and every `WideGuard` / `testing::allow_wide_objects = true`
     use in `test/allocator` (3A.9's `WideObjectTest.cpp`, Phase 1's unit pins). Those tests keep
     their wide objects; they are legitimate now.
3. In `test/codegen/*.mlir`, drop the module attribute:

   ```bash
   sed -i 's/module attributes {eco.allow_wide_objects} {/module {/' $(grep -l "eco.allow_wide_objects" test/codegen/*.mlir)
   ```

   Every such fixture is within the real limits: 3B fixtures stay ≤ 2040/2047.
4. Re-run the grep: **zero hits** is the check.

**Rollback:** restore from the snapshot (the switch is test-only).

### 3D.4 fixture sweep onto `slot_kinds` (scripted, op-scoped)

**Inventory today** (2026-10-05; counted op-scoped by the dry-run below over 330 fixtures in
`test/codegen/`):

| Op | Attribute | Occurrences | Files |
|---|---|---|---|
| `eco.construct.custom` | `unboxed_bitmap` | 73 | 18 |
| `eco.papExtend` | `newargs_unboxed_bitmap` | 37 | 16 |
| `eco.papCreate` | `unboxed_bitmap` | 25 | 20 |
| `eco.construct.tuple2` | `unboxed_bitmap` (**stays**) | 4 | 3 |
| `eco.construct.tuple3` | `unboxed_bitmap` (**stays**) | 1 | 1 |
| comment lines | (manual rewording) | 28 | 13 |
| `eco.construct.record`, `eco.papCreateGroup`, `eco.to_heap` | | **0** | 0 |

The total is 168 textual hits. There are **no negative fixtures** that expect a bitmap-mismatch or
cap error today:
- `grep -n -E "(CHECK|expected-error).*(unboxed_bitmap|kind=|exceeds|bits set beyond|50-bit|slot limit)" test/codegen/*.mlir`
  is empty.
- The only negative-looking mention is a *comment* in `test/codegen/construct_constants.mlir:11-14`
  ("ERROR: unboxed_bitmap bit 0 is set…"), which is not a RUN-checked expectation.
- Outside `test/codegen`, nothing checks the verifier messages. The only hit is the docstring of
  `test/elm/src/WideCtorField24Test.elm:17`, handled in 3D.7.
- Phases 0–3C added negative fixtures: the B14 `i1` operand fixtures (Phase 0), the arity-2048
  fixture (Phase 2) and `wide_record_33_kind_mismatch.mlir` (3B.F.6). The sweep rewrites any old
  bitmap they carry like any other fixture (an `i1` operand derives kind 0, as its bitmap says), and
  their CHECKs name `i1`, arity or `slot_kinds` messages, not bitmaps. Re-run the grep above after the
  sweep: it must list only those.

**Files rewritten by the script** (39 files on today's tree):
- **construct.custom:** `construct_all_unboxed`, `construct_alternating_types`,
  `construct_large_unboxed_bitmap`, `construct_many_unboxed`, `construct_mixed_ordering`,
  `construct_nested`, `construct_unboxed_fields`, `project_unboxed_*`, …
- **papCreate/papExtend:** `pap_unboxed_captured`, `pap_simplify_*`, `papextend_*`, `wrapper_*`,
  `call_direct`, …

The script prints the exact list; record it in the phase log.

**The script:** check it in as `test/scripts/sweep_slot_kinds.py`. Full text:

```python
#!/usr/bin/env python3
"""Phase 3D fixture sweep (plans/wide-object-tail-kind-words-phase-3.md, 3D.4).

Rewrites the old u64 kind bitmaps on eco.construct.custom / eco.construct.record /
eco.papCreate / eco.papExtend / eco.papCreateGroup / eco.to_heap into `slot_kinds =
array<i8: ...>` in every test/codegen/*.mlir fixture. Tuple2/Tuple3/list attributes are untouched.

Per op occurrence it:
  1. finds the op's attribute dict and its trailing functional type `: (T0, T1, ...) -> R`;
  2. computes the slot count S (custom: `size`; record: `field_count`; papCreate: `num_captured`;
     papExtend: #operands - 1 - eco.gc_roots_count);
  3. derives kinds from operand types 0..S-1 (papExtend: 1..S): i64->1, f64->2, i16->3, else 0;
  4. decodes the old bitmap and REPORTS any disagreement (a fixture that was deliberately
     inconsistent is a negative test and must be rewritten by hand, never silently);
  5. replaces `<attr> = N[ : i64]` with `slot_kinds = array<i8: k0, ..., kS-1>`
     (`array<i8>` when S == 0), unless the dict already has slot_kinds (then the old attr is
     just deleted).
Comment lines are never edited; they are listed for manual rewording.

Usage:  sweep_slot_kinds.py [--write] FILE...      (default: dry run, prints a report)
Exit 1 if any disagreement or unparsable occurrence is found.
"""
import re
import sys

OPS = {
    "eco.construct.custom": ("unboxed_bitmap", "size", 0),
    "eco.construct.record": ("unboxed_bitmap", "field_count", 0),
    "eco.papCreate": ("unboxed_bitmap", "num_captured", 0),
    "eco.papExtend": ("newargs_unboxed_bitmap", None, 1),
    "eco.to_heap": ("unboxed_bitmap", None, None),   # attr only deleted (lowering derives)
}
KIND = {"i64": 1, "f64": 2, "i16": 3}
OP_RE = re.compile(r'"?(eco\.[A-Za-z_.0-9]+)"?')


def split_types(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def find_dict(txt, start):
    """Return (open, close) indices of the first top-level {...} at/after start."""
    i = txt.find("{", start)
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(txt)):
        if txt[j] == "{":
            depth += 1
        elif txt[j] == "}":
            depth -= 1
            if depth == 0:
                return i, j
    return None


def operand_types(txt, after):
    m = re.compile(r":\s*\(([^)]*(?:\([^)]*\)[^)]*)*)\)\s*->").search(txt, after)
    return split_types(m.group(1)) if m else None


def int_attr(d, name):
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*(-?\d+)", d)
    return int(m.group(1)) if m else None


def process(path, write):
    txt = open(path).read()
    problems, edits, comments = [], [], []
    for m in re.finditer(r"\b(unboxed_bitmaps?|newargs_unboxed_bitmap)\s*=\s*(-?\d+|\[[^\]]*\])(\s*:\s*i64)?", txt):
        ls = txt.rfind("\n", 0, m.start()) + 1
        line = txt[ls:txt.find("\n", m.start())]
        if line.lstrip().startswith("//"):
            comments.append((txt.count("\n", 0, m.start()) + 1, line.strip()))
            continue
        ops = list(OP_RE.finditer(txt, 0, m.start()))
        op = ops[-1].group(1) if ops else "?"
        lineno = txt.count("\n", 0, m.start()) + 1
        if op not in OPS and op != "eco.papCreateGroup":
            continue  # tuple2/tuple3 etc. keep their attribute
        if op == "eco.papCreateGroup":
            problems.append((lineno, op, "papCreateGroup: rewrite by hand (per-sibling ArrayAttr)"))
            continue
        attr, count_attr, skip = OPS[op]
        if m.group(1) != attr:
            problems.append((lineno, op, f"unexpected attribute {m.group(1)}"))
            continue
        dspan = find_dict(txt, ops[-1].end())
        d = txt[dspan[0]:dspan[1] + 1] if dspan else ""
        if op == "eco.to_heap":
            edits.append((m.start(), m.end(), None))
            continue
        tys = operand_types(txt, dspan[1] if dspan else m.end())
        if tys is None:
            problems.append((lineno, op, "no functional type found"))
            continue
        if count_attr:
            n = int_attr(d, count_attr)
        else:
            roots = int_attr(d, "eco.gc_roots_count") or 0
            n = len(tys) - 1 - roots
        if n is None or n < 0:
            problems.append((lineno, op, f"slot count unknown ({count_attr})"))
            continue
        slot_tys = tys[skip:skip + n]
        kinds = [KIND.get(t, 0) for t in slot_tys]
        old = int(m.group(2))
        decoded = [(old >> (2 * i)) & 3 for i in range(n)]
        if decoded != kinds or (n < 32 and old >> (2 * n)):
            problems.append((lineno, op, f"bitmap {old} decodes to {decoded}, operand types give {kinds}"))
            continue
        new = "slot_kinds = array<i8" + (": " + ", ".join(map(str, kinds)) if kinds else "") + ">"
        edits.append((m.start(), m.end(), None if "slot_kinds" in d else new))
    if write and not problems:
        for s, e, new in sorted(edits, reverse=True):
            if new is None:
                # delete the attribute and one adjacent comma
                pre = txt[:s].rstrip()
                if pre.endswith(","):
                    txt = pre[:-1] + txt[e:]
                else:
                    post = txt[e:]
                    txt = txt[:s] + re.sub(r"^\s*,\s*", "", post, count=1)
            else:
                txt = txt[:s] + new + txt[e:]
        open(path, "w").write(txt)
    return problems, edits, comments


def main():
    write = "--write" in sys.argv
    files = [a for a in sys.argv[1:] if a != "--write"]
    bad = 0
    for f in files:
        problems, edits, comments = process(f, write)
        if edits or problems or comments:
            print(f"{f}: {len(edits)} rewrite(s), {len(problems)} problem(s), {len(comments)} comment mention(s)")
        for ln, op, why in problems:
            print(f"  PROBLEM {f}:{ln} {op}: {why}")
            bad += 1
        for ln, text in comments:
            print(f"  COMMENT {f}:{ln}: {text[:100]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
```

**Procedure:**

```bash
cd /work/test/codegen
python3 ../scripts/sweep_slot_kinds.py *.mlir 2>&1 | tee /tmp/sweep_dry.txt       # dry run
grep -c PROBLEM /tmp/sweep_dry.txt                                             # must be 0
python3 ../scripts/sweep_slot_kinds.py --write *.mlir 2>&1 | tee /tmp/sweep_write.txt
grep -n -E "unboxed_bitmaps?|newargs_unboxed_bitmap" *.mlir | grep -v -E "^\S+:[0-9]+:\s*//" \
  | grep -v -E "eco\.construct\.tuple[23]"                                     # must be empty
```

**Validated:** the script was run on a scratch copy of today's `test/codegen`:
- dry run: 0 problems, 39 files with rewrites, 28 comment mentions;
- write run: 135 rewrites;
- what remains are exactly the 5 tuple2/tuple3 attributes (`caf_memo_gc.mlir:24`,
  `construct_tuple2_char.mlir:11`, `inline_alloc_tuple.mlir:21`, `:32`, `:39`) and the comments.
- Example result: `pap_unboxed_captured.mlir:27` `unboxed_bitmap = 5 : i64` became
  `slot_kinds = array<i8: 1, 1>`.

**Comments: manual rewording** of the 28 mentions in 13 files: `call_direct`,
`construct_alternating_types`, `construct_constants`, `construct_list`, `construct_many_unboxed`,
`construct_mixed_ordering`, `construct_nested`, `construct_unboxed_fields`, `dbg_all_values`,
`papextend_saturated_float_result`, `papextend_typed_saturation`, `pap_unboxed_captured`,
`verify_constants_boxed`.
- Replace "unboxed_bitmap = N (0b…)" prose with "slot_kinds = [k0, …]".
- `construct_list.mlir` comments may refer to list `head_unboxed`; keep those.
- **Rename** `construct_large_unboxed_bitmap.mlir` to `construct_large_slot_kinds.mlir`, since its
  premise ("large unboxed_bitmap values") is gone. Keep the content.

**Ordering:** do the sweep **before** 3D.5. With the old attributes still optional (3D-P3), swept and
un-swept fixtures both verify, so the sweep can be checked on its own: run the codegen subset
(3D.4 test below) before deleting anything.

**Test after 3D.4** (no Elm change, so `check`-style subset):

```bash
cmake --build build --target test && ulimit -c 0 && build/test/test --filter codegen 2>&1 | tee /tmp/test_output.txt
grep -A50 "Failed tests:" /tmp/test_output.txt        # expected: none
```

Check how the codegen fixtures are named in `--filter` (`build/test/test --list | grep -m3 codegen`)
and use that prefix.

**Rollback:** `tar xzf …/extra.tgz test/codegen` (3D.0).

### 3D.5 delete the old attributes; make `slot_kinds` required

**File `runtime/src/codegen/Ops.td`.** Anchor by `def`; today's lines are given for orientation.

| Op (def) | Today | Phase 3D after |
|---|---|---|
| `Eco_RecordConstructOp` (`:894`) | `I64Attr:$unboxed_bitmap` (`:928`; `OptionalAttr` since 3B.2.1) | delete the line; `DenseI8ArrayAttr:$slot_kinds` (drop any `OptionalAttr<>` wrapper 3B used) |
| `Eco_CustomConstructOp` (`:964`) | `DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,` (`:1005`) | delete; `DenseI8ArrayAttr:$slot_kinds,` |
| `Eco_PapCreateOp` (`:1343`) | `DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,` (`:1387`) | delete; `DenseI8ArrayAttr:$slot_kinds,` (captures; empty array for zero captures) |
| `Eco_PapCreateGroupOp` (`:1397`) | `I64ArrayAttr:$unboxed_bitmaps,` (`:1451`) | delete; `ArrayAttr:$slot_kinds,` (one `DenseI8ArrayAttr` per sibling, §S.5) |
| `Eco_PapExtendOp` (`:1461`) | `DefaultValuedAttr<I64Attr, "0">:$newargs_unboxed_bitmap,` (`:1533`) | delete; `DenseI8ArrayAttr:$slot_kinds,` (newargs) |
| `Eco_ToHeapOp` (`:3246`) | `DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,   // record/custom` (`:3276`) | delete; keep/introduce `OptionalAttr<DenseI8ArrayAttr>:$slot_kinds` (3D-D2) |
| `Eco_Tuple2ConstructOp` (`:785`) / `Eco_Tuple3ConstructOp` (`:815`) | `DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap` (`:808`, `:838`) | **unchanged** |

Also edit the op `description`s, which mention the bitmap:
- record `:900-906`, `:920` example;
- custom `:978-981`, `:995` example;
- papCreate `:1354-1360`, `:1375`;
- papCreateGroup `:1435`, `:1440`;
- papExtend `:1500-1505`, `:1517`, `:1524`;
- to_heap `:3259`;
- the type-level comments at `:105` and `:136`.

New wording for record and custom:
> `slot_kinds` holds one kind per field (0 boxed, 1 Int, 2 Float, 3 Char) and must equal the kinds
> of the field operands; the lowering packs slots 0..CAP-1 into the header bitmap and the rest into
> tail kind words (HEAP_019); field_count ≤ 2047 (record) / size ≤ 2040 (custom).

Update the examples to `slot_kinds = array<i8: …>`.

**C++ that used the deleted accessors** (anchors from 2026-10-05; Phases 2/3B already moved the
logic onto `slot_kinds`, so after this step these must not exist for the five ops):
- `runtime/src/codegen/EcoOps.cpp`:
  - `CustomConstructOp::verify` `:395`;
  - `RecordConstructOp::verify` `:465`;
  - `PapCreateOp::verify` `:545`;
  - `PapExtendOp::verify` `:621`;
  - `PapCreateGroupOp::verify` `:740` (the cross-edge "slot must be boxed" check at `:775-779`
    now reads `slot_kinds[consumer][slot] == 0`).
- `Passes/EcoToLLVMHeap.cpp`: `:946` (record), `:1100` and `:1168` (custom), `:1820` and `:1932`
  (group/coalesced path).
- `Passes/EcoToLLVMValueAgg.cpp:378`, `:461` (to_heap record/custom).
- `Passes/EcoToLLVMClosures.cpp:780`, `:864`, `:965`, `:2930`.
- `Passes/EcoPAPSimplify.cpp`:
  - `:376-388`: the `create<PapExtendOp>` positional builder passed the bitmap as the 5th argument;
    the regenerated builder no longer has that parameter;
  - `:536`: `setAttr("unboxed_bitmap", …)` on the cloned papCreate.
- **Unchanged:** the tuple uses `EcoToLLVMHeap.cpp:673`, `:765`, `:1799`, `:1810`.
- **The to_heap tuple arms** (`EcoToLLVMValueAgg.cpp:231`, `:310`) read to_heap's `unboxed_bitmap`
  (`.value_or(0)` since 3B.5), which this step deletes. Derive the tuple kinds from the element
  types instead: `packKinds(slotKindsOfTypes(elementTypes), 3).hdrBits`.

**Verifier additions (3D-D2, 3D-D3).** In each of the five verifiers, first:

```cpp
static LogicalResult rejectStaleBitmapAttr(Operation* op) {
  for (StringRef n : {"unboxed_bitmap", "newargs_unboxed_bitmap", "unboxed_bitmaps"})
    if (op->hasAttr(n))
      return op->emitOpError("stale attribute '") << n
             << "': regenerate the MLIR (slot_kinds replaced it; plans/wide-object-tail-kind-words.md Phase 3D)";
  return success();
}
```

(file-static helper in `EcoOps.cpp`, beside `getGCRootsCountAttr`). Then require `slot_kinds`. With
a non-optional ODS attribute the generated verifier already reports "requires attribute
'slot_kinds'"; keep the length and kind checks from Phase 3B. `ToHeapOp::verify` calls
`rejectStaleBitmapAttr` too.

**Build and check:**

```bash
cmake --build build 2>&1 | tee /tmp/build_p3d.txt          # tblgen regenerates builders; compile errors list stragglers
grep -rn -E "getUnboxedBitmap\(|getNewargsUnboxedBitmap|getUnboxedBitmaps|\"unboxed_bitmaps?\"|\"newargs_unboxed_bitmap\"" \
     runtime/src/codegen | grep -v -i tuple                   # expected: only Tuple2/Tuple3 lowering lines
```

Then add `test/codegen/stale_unboxed_bitmap_rejected.mlir`: an `eco.construct.custom` carrying both
`slot_kinds` and `unboxed_bitmap = 1`. RUN with `not %ecoc … -emit=mlir`, and
`// CHECK: stale attribute 'unboxed_bitmap'`.

**Rollback:** restore `runtime/src/codegen` and `test/codegen` from the snapshot. Phase 3C cannot be
reverted after this step without also reverting it (overview §8).

### 3D.6 front end and elm-test cleanup

1. `grep -rn -E "unboxed_bitmap|newargs_unboxed_bitmap|unboxed_bitmaps|unboxedBitmap|bitmapSetKind|maxTypedSlots" compiler/src`.
   - **Expected:** tuple-only uses of `unboxed_bitmap` / `unboxedBitmap`: `Ops.elm`
     `ecoConstructTuple2`/`ecoConstructTuple3`, `Types.computeTupleLayout` (`Types.elm:556-580`, via
     the private `tupleBitmap` of 3C.1), `Patterns.elm:388`, `:395`, `Functions.elm:1120`, `:1123`,
     `:1728`, `:1731` and `Expr.elm:7479`, `:7483` (tuple construct sites). **No**
     `bitmapSetKind` / `maxTypedSlots` hit (3C.1 deleted them).
   - Any other hit is a Phase 2/3C leftover: fix it here.
2. `compiler/tests`: the same grep.
   - `TestLogic/Generate/CodeGen/UnboxedBitmap.elm` and `CtorLayoutConsistency.elm` were retargeted
     to `slot_kinds` in Phase 3C. Their docstrings must no longer say "52-bit" or describe
     construct/closure bitmaps (`UnboxedBitmap.elm:3-40`).
   - If the module name `UnboxedBitmap` still fits its tuple+slot_kinds job, keep it.
   - **Default:** rename to `SlotKinds.elm` / `SlotKindsTest.elm` only if the docstring would
     otherwise be misleading. A rename touches only the test tree.
3. `elm-format` the touched files (toolchain in `build/toolchain/bin/`).

**Rollback:** snapshot.

### 3D.7 flip and maintain the pins

**E2E pins that turn green in 3D:** list L3 (phase-0 Step 0.6a, "green at P3D"). They must pass in
`full`; none may stay on an expected-failure list:

| Pin | Covers |
|---|---|
| `elm/WideCtorField24Test.elm` | E1 |
| `elm/WideRecord33Test.elm`, `elm/WideRecord40Test.elm` | E2 |
| `elm/WideRecord600Test.elm` | call path over 4096 B |
| `elm/WideRecord1100Test.elm` | large object |
| `elm/WideCtorMixedTest.elm` | 60 mixed fields |
| `elm/WideCtor1100Test.elm` | large ctor |
| `elm/WideRecordDecoder70Test.elm` | E9 |
| `elm/WideRecordDecoder300Test.elm` | decoder at scale |
| `eco-kernel/WideHeapGcTest.elm` | wide records and ctors across minor + major GC |

**`WideCtorField24Test.elm` docstring** (`:3-22`). Phase 1 rewrote its false claims about B1/B2; the
remaining sentence, "the verifier rejects more than 24 fields", is false after 3D.1. Replace the
docstring with:

> Pins wide constructors end to end: 25 Int fields, a Float and a Char (27 fields). Fields 0..23
> keep their kinds in the Custom header bitmap, fields 24..26 in the first tail kind word
> (HEAP_019). Historically: the verifier rejected > 24 fields, generateCtor declared field 24 as
> !eco.value (B1) and the boxed projection branch read pointer bits (B2).

The CHECK lines (`:24-28`) stay.

The elm-test wide pins were renamed and re-documented in 3C.5 (with the String-at-24 and
polymorphic variants). 3D.7 only checks that they still pass.

**Rollback:** the pins are tests only; revert from the snapshot.

### 3D.8 invariants (`design_docs/invariants.csv`)

**Format:** header `id;phase;category;status;description;source`. The file is not strictly
6-column (descriptions in many rows contain `;`; field counts vary, 6..14), and no tool parses it
(only `benchmarks/lss-loop-snap.sh:30` snapshots it). Rules for new text: **no `;` inside the
description** (use " - " or ","), keep `id;phase;category;status;` and the trailing `;source`, and
append the dated note in the house style `(Updated 2026-10-xx: …)`.

Phase 2 (step 2.9) wrote the closure rows: HEAP_077, HEAP_078, HEAP_033, CGEN_003, CGEN_049,
REP_CLOSURE_001, REP_CLOSURE_002, FORBID_CLOSURE_002, and the Closure clauses of HEAP_019 and
HEAP_034. 3D.8 checks those are present and writes the rest. The HEAP_019 row below is the final
row with both clauses. Full replacement rows follow; `2026-10-xx` is the commit date.

```text
HEAP_019;Runtime_Heap;UnboxedBitmap;enforced;Custom Record and Closure keep 2-bit slot kinds (00=boxed HPointer, 01=Int, 10=Float, 11=Char) for slots 0..CAP-1 in their header bitmap (Custom 24 in Custom.unboxed:48, Record 32 in Record.unboxed:64, Closure 20 in the packed word, slot i at bits [2i, 2i+1]) and for slots CAP.. in K tail kind words of 32 slots each - Custom/Record: the words sit at values[header.size .. header.size+K) with K = header.unboxed = extWords(header.size, CAP) - Closure: header.size counts allocated value slots plus K and the words are the last K words with K = extWords(max_values, 20) (Closure header.unboxed is 0). Limits: Custom 2040 fields, Record 2047 fields, Closure stage arity 2047. Cons Tuple2 Tuple3 ElmArray ListBacking and Task keep their kinds in header.unboxed. GC equality and debug code read kinds only through customSlotKind / recordSlotKind / closureSlotKind or a ClosureKinds snapshot (closureKindAt) (Heap.hpp) (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: tail kind words, plans/wide-object-tail-kind-words.md);Heap.hpp and RuntimeExports.cpp
REP_HEAP_002;Runtime_Heap;Representation;enforced;Each unboxed slot carries a 2-bit kind (00=boxed HPointer, 01=Int, 10=Float, 11=Char) at the slot's position in the container's kind words (header bitmap or tail kind word, HEAP_019) - GC and debug logic must rely exclusively on this 2-bit kind or on constant bits in HPointer values to distinguish pointers from unboxed values (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: tail kind words);HEAP_019|HEAP_010|HEAP_014
HEAP_004;Runtime_Heap;NewTypes;documented;When introducing a new heap object type you must update the Tag enum the C plus plus struct definition getObjectSize scanObject and markChildren so all GC logic stays consistent with the Tag - including the tail kind words of HEAP_019 in getObjectSize and every child walker - object size remains a function of the 8-byte header word alone (Updated 2026-10-xx: tail kind words);THEORY.md
MONO_013;Monomorphization;Layouts;documented;For each custom type every constructor has a CtorLayout whose field count ordering and per-slot kinds (ctorSlotTypes) match the constructor's fields - all construction and pattern matching nodes that use that constructor are consistent with its CtorLayout - Custom supports up to 2040 fields all of which may be unboxed (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: no typed-slot cap, slot_kinds replaces unboxedBitmap);Compiler.AST.Monomorphized
XPHASE_001;CrossPhase;Layouts;implied;RecordLayout TupleLayout and CtorLayout from the monomorphized IR must agree with the eco.construct attributes (tag, size, slot_kinds for record/custom, unboxed_bitmap for tuple2/tuple3) and with the Custom and Record C plus plus structs and HEAP_019's kind words so that MLIR objects match runtime layouts - Elm-side encodeUnboxedKind and the runtime kind accessors must use the same 2-bit encoding (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: slot_kinds);Compiler.AST.Monomorphized and Compiler.Generate.MLIRMono and Heap.hpp
REP_BOUNDARY_002;CrossPhase;Boundaries;enforced;Construction of heap objects from SSA values sets per-slot 2-bit kinds based solely on SSA operand MLIR types (i64→01, f64→10, i16→11, else→00) - construct.custom and construct.record carry slot_kinds (one kind per slot) which the verifier checks against the operand types and the lowering packs into the header bitmap and tail kind words - the runtime layout must match the kinds exactly (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: slot_kinds and tail kind words);CGEN_026|CGEN_027|XPHASE_001|HEAP_019
CGEN_026;MLIR_Codegen;UnboxedBitmap;enforced;For eco.construct.record and eco.construct.custom the slot_kinds attribute (DenseI8Array, one kind per field, 0=boxed 1=i64 Int 2=f64 Float 3=i16 Char) is required and must equal the kinds of the field operand MLIR types (i1 operands are rejected) - field_count <= 2047 and size <= 2040 - for eco.construct.tuple2 and eco.construct.tuple3 the unboxed_bitmap is derived solely from SSA operand MLIR types via encodeUnboxedKind with slot i at bits [2i, 2i+1] - the old u64 unboxed_bitmap on record/custom/closure ops is rejected as stale (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: slot_kinds);runtime/src/codegen/Ops.td and Compiler.Generate.MLIR.Expr and Compiler.Generate.MLIR.Ops
CGEN_020;MLIR_Codegen;Construction;enforced;eco.construct.custom is used only for user defined custom ADTs and its tag size and slot_kinds attributes and operand count match the CtorLayout selected from MonoGraph.ctorLayouts - size <= 2040 (Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds per slot) (Updated 2026-10-xx: slot_kinds, size <= 2040);Compiler.Generate.MLIR.Functions and Compiler.Generate.MLIR.Expr and Compiler.Generate.Monomorphize
```

**HEAP_046** is long. Edit one phrase, after which the rest of the row is unchanged. Before:
`and compiled readers consult only the CtorLayout - never header.unboxed - so`. After:
`and compiled readers consult only the static layout (CtorLayout / RecordLayout) - never an object's kind words (header bitmap, tail kind words or header.unboxed) - so`.

**HEAP_034** is long. Edit clause (b) only. Before:
`(value_enc::composeHeader = tag | unboxed<<10 | sizeField<<32, runtime-pinned by testHeaderWordComposition since bitfield packing is not static_assert-able) plus any metadata word and EVERY payload field`.
After:
`(value_enc::composeHeader = tag | unboxed<<10 | sizeField<<32, runtime-pinned by testHeaderWordComposition since bitfield packing is not static_assert-able - unboxed = K tail kind words for Custom/Record, 0 for Closure whose sizeField counts value slots plus K, HEAP_019) plus any metadata word and EVERY payload field and every tail kind word (HEAP_077)`.
This is the merged clause: Phase 2's Closure part plus the Custom/Record part.

**Check:**
- `grep -n -E "24 typed|26 typed|52-bit|50-bit|<= 24\)|size <= 24|32-slot|first 32 slots" design_docs/invariants.csv`
  returns nothing outside rows marked retired.
- `grep -c '^HEAP_07[78];' design_docs/invariants.csv` returns 2 (Phase 2 added them).

**Rollback:** `lss-loop-snap.sh` covers `invariants.csv`.

### 3D.9 theory docs

Exact passages (2026-10-05 lines):

| File:lines | Today | Change |
|---|---|---|
| `design_docs/theory/heap_representation_theory.md:172-186` | "Bitmap capacity limits" table: Custom 24 (48 bits), Record 32, Closure 26 (52-bit) | Replace with the layout C table: header slots 24/32/20, tail words 32 slots each, limits 2040/2047/2047. Add a short paragraph with overview §2.1's layout block (K in `header.unboxed` for Custom/Record; physical `header.size` with the last K words for Closure; ext words always written). Replace the helper list `fieldKind` / `bitmapSetKind` / `pointerMaskFromKindBitmap` (`:180-183`) with `kindInWord`, `customSlotKind`, `recordSlotKind`, `ClosureKinds` / `closureKindAt`, `pushRootsByKinds` (§S.1, §S.2) |
| same file `:114-155` | `RecordLayout { … unboxedBitmap : Int … }` and the Point example (`unboxedBitmap = 0b011`, heap `[Header:8][unboxed_bitmap:8]…`) | Show the layout record after 3C.1, which has no `unboxedBitmap` field. Heap line: `[Header:8][kinds 0..31:8][x][y][label]` (+ tail words when > 32 fields) |
| same file `:375` | `uint64_t ctor_unboxed;   // ctor_tag:8 \| unboxed_bitmap:56` (already wrong today) | `u64 ctor:16 \| unboxed:48 (kinds of slots 0..23); tail kind words after values[size] (HEAP_019)` |
| same file `:427`, `:430` | XPHASE_001 bullet "`eco.construct` attributes (`tag`, `size`, `unboxed_bitmap`)" and "the `unboxed_bitmap` cannot disagree…" | `slot_kinds` (record/custom), `unboxed_bitmap` (tuples) |
| same file `:513` | "Does `unboxedBitmap` match field types?" | "Do `slot_kinds` match the operand types (and the layout's `ctorSlotTypes`)?" |
| `design_docs/theory/pass_eco_to_llvm_theory.md:205-232` | Records/Custom lowering pseudo-code with `unboxed_bitmap`, `eco_set_unboxed` | `slot_kinds` → `packKinds(kinds, CAP)` → header bits in the meta word plus K tail words stored after the fields, `composeHeader(tag, K, n)`, size `16 + 8(n+K)`; tuples unchanged (`:208-216` stays) |
| same file `:255-305` | closure layout `n_values:6 \| max_values:6 \| unboxed:52`, papCreate packing `<< 12`, papExtend lowering `& 0x3F`, `>> 12` | Phase 2 (step 2.9) updated this passage (HEAP_078). Check it says `n:11 \| max:11 \| rk:2 \| kinds:40`, tail words, `packClosureWord` |
| `design_docs/theory/mlir_verification_theory.md:98-106` | `PapExtendOp::verify` pseudo-code: "newargs_unboxed bitmap must be consistent with types" | "slot_kinds must equal the newarg operand kinds; ≤ 2047 newargs; stale u64 bitmap attributes rejected". Add a sentence that construct.custom/record verify `slot_kinds` with caps 2040/2047 |
| `design_docs/theory/pass_mlir_generation_theory.md:318-326` | `eco.construct.record [fieldVars] fieldCount unboxedBitmap`, `eco.construct.custom tag size [fieldVars] unboxedBitmap` | `… slotKinds` for record/custom; tuple2 keeps `unboxedBitmap` |
| `design_docs/theory/pass_monomorphization_theory.md:359`, `:376`, `:389`, `:461-464` | `unboxedBitmap : Int` fields in RecordLayout / TupleLayout / CtorLayout | Keep TupleLayout's. Drop RecordLayout's and CtorLayout's (3C.1 removed them), and say "per-slot kinds via `ctorSlotTypes` / record field `isUnboxed`, no index cap" |
| `design_docs/theory/platform_scheduler_theory.md:90` | Task frame "`unboxed_bitmap` is `0x1`" | **unchanged**: a kernel-built frame, not an `eco.construct` attribute |

**Check:**
`grep -rn -E "52-bit|48-bit within|26 captures|24 fields \(2|unboxed:52|ctor_tag:8" design_docs/theory`
returns nothing.

### 3D.10 Final gate (overview §6, §7)

Run everything **once**, each tee'd (CLAUDE.md); read results from the files.

```bash
cd /work && ulimit -c 0
cmake --build build 2>&1 | tee /tmp/p3d_build.txt                         # all runtime libs + tools (relower trap)
# 1. elm front end
cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt
# 2. E2E + unit + codegen fixtures (cache wipe first, §S.7)
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.1.3/packages \( -name artifacts.dat -o -name typed-artifacts.dat \) -delete
rm -rf ~/.eco/0.1.3/packages/eco/kernel
cmake --build build --target full 2>&1 | tee /tmp/test_output_full.txt
# 3. validate tree: unit + GC-stress pins
cmake -S /work -B /work/build-validate -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DECO_HEAP_VALIDATE=ON
cmake --build /work/build-validate && cmake --build /work/build-validate --target test
/work/build-validate/test/test --filter Wide 2>&1 | tee /tmp/test_output_validate.txt
/work/build-validate/test/test 2>&1 | tee /tmp/test_output_validate_all.txt
# 4. register guards (includes the validate-only and TSan/fork arms)
cmake --build build --target register-guards 2>&1 | tee /tmp/test_output_rg.txt
# 5. AOT (move caches aside first: corrupt-cache trap)
for d in build/test/aot-e2e/*/eco-stuff; do [ -d "$d" ] && mv "$d" "$d.bak-3d"; done
cmake --build build --target run-aot-e2e 2>&1 | tee /tmp/test_output_aot.txt
# 6. bootstrap fixed point, then cross-stage MLIR equivalence
cmake --build build --target bootstrap 2>&1 | tee /tmp/test_output_boot.txt
cmake --build build --target eco-verify 2>&1 | tee -a /tmp/test_output_boot.txt
cmake --build build --target run-mlir-equivalence 2>&1 | tee /tmp/test_output_equiv.txt
# 7. TLA canary, strict (configure flag once), and trace validation
cmake -S /work -B /work/build -DECO_TLA_CANARY_STRICT=ON && cmake --build build --target tla-canary 2>&1 | tee /tmp/test_output_tla.txt
cmake --build build --target tla-trace 2>&1 | tee /tmp/test_output_tlatrace.txt
# 8. perf triple: benchmarks/fe-opt-loop.md §2 (REG=~/.eco/0.1.3/packages/registry.dat), arms eco-opt-prev (P0 baseline, kept in snapshots/lss-loop/pre-wide-3d/bin or the P0 snapshot) vs the 3D compiler
```

**Expected results (the Phase 3D expected-failure list):**

| Gate | Expected |
|---|---|
| elm-tests | `Failed: 2`: exactly `JoinpointABI case branch types match after GlobalOpt` and `Higher-order function tests case branch types match after GlobalOpt` (both GOPT_003 bug pins in `TestLogic/Monomorphize/MonoCaseBranchResultTypeTest.elm`, unrelated). `grep "✗" /tmp/test_output.txt` shows only those two. Passed = Phase 0's 14,059 + 2 (the wide pins) + the elm-tests added by Phases 0–3D |
| `full` | `Tests failed: 0`. `grep -A40 "Failed tests:" /tmp/test_output_full.txt` is empty. Phase 0 baseline: 2,040 pass / 1 fail, the 1 being `elm/WideCtorField24Test.elm`, now green. Tests run = 2,041 + all pins added in Phases 0–3D |
| validate tree | 0 failures. The GC-stress pins print their GC-count CHECK lines (they must show minors > 0 and, for the eco-kernel variants, majors > 0) |
| `register-guards` | green |
| `run-aot-e2e` | exactly the Phase 0 AOT failure list (historically the two harness gaps `FlagsRecordTest`, `PortEchoTest`: the AOT runner lacks FLAGS and port echo). Any wide pin failing in AOT is a regression |
| bootstrap / `eco-verify` | B==C fixed point. Phase 3C already absorbed the extra propagation iteration; Phase 3D changes the MLIR form again only by attribute deletion, which the compiler already stopped emitting, so expect A==B too |
| `run-mlir-equivalence` | all equal |
| `tla-canary` strict | green after any AUDIT.md entries (3D.11) |
| `tla-trace` | all rows accepted / rejected as `traces.txt` expects |
| perf triple | wall within the triple's spread of the Phase 3C triple. Counters (minor/major cycles, promoted MiB, objects) **bit-identical to Phase 3C**: Phase 3D changes no object layout in the self-compile, only verifier caps, attribute names and docs. Against Phase 0 the counters may differ only by the explained Phase 2 (closures arity 21..25 and > 25) and 3C (records > 26 primitives) census deltas (overview §7) |

### 3D.11 GC concurrency procedure check (overview §5)

Phase 3D edits no allocator code. If `tla-canary` fires anyway, a step strayed into pinned code:
follow overview §5 (MAPPING.md, AUDIT.md entry with the 12-hex prefix, then `--update`). There are
no voluntary AUDIT entries for Phase 3D.

### 3D.12 memory notes and plan status

- **Update** `/home/dev/.claude/projects/-work/memory/elm-tests-12-known-failures.md`: the baseline
  becomes **2 failures (the GOPT_003 pins)**. The wide pins are fixed; record the plan and date.
- **Add** a memory entry, `wide-objects-tail-kind-words-done.md`, with a one-line index entry in
  `MEMORY.md` (MEMORY.md is already over its size budget: keep the index line under ~200 chars). It
  records:
  - the limits (Custom 2040, Record 2047, Closure arity 2047);
  - the layout C rule, including closure physical `header.size` with K from `max_values`;
  - `slot_kinds`, with the u64 bitmaps gone except on tuples;
  - the traps: ext words not cleared by `zeroNewObject`; stale MLIR caches are now rejected (3D-D3);
  - the arity-21..25 closures' extra word.
- Set the overview `Status:` to `DONE (2026-10-xx)`, and append the measured perf row and the final
  failure lists.

---

### 3D final gate result (recorded 2026-10-05)

| Gate | Result |
|---|---|
| elm-tests | 14,085 pass / 2 fail: exactly the two GOPT_003 pins |
| `full` (cache wiped) | **2,128 run, 2,128 pass, 0 fail**: every list-L3 pin green, all codegen fixtures (346) and unit pins |
| validate tree (full rebuild, `eco-stuff` wiped) | `Wide` 36/36; whole binary 2,129/2,129; only the six negative-control `[heap-validate]` lines |
| register-guards | green (22 PASS, 1 WONTFIX CR-012(e), as before) |
| `run-aot-e2e` | 932/934: exactly the Phase 0 harness gaps `FlagsRecordTest`, `PortEchoTest`; every wide pin passes in AOT |
| bootstrap / `eco-verify` | Stage 4b and 8c fixed points hold; rc 0 |
| `run-mlir-equivalence` | 945/946 after one fix (below): the only failure is `elm/IntOverflowTest` (stage2 != stage6), **pre-existing and unrelated**: the JS Stage 2 compiler reads the literal `9223372036854775807` through a double (test dated 2026-09-15) |
| `tla-canary` strict / `tla-trace` | green / all rows as expected; no pin fired in 3D (3D.11: no AUDIT entry needed) |
| perf triple (`eco-optP3d`, sha256 `4d81362953f90246…`) | 68.78 / 68.48 / 68.54 s (median 68.54; 3C 69.29); minor 1337, major 6, promoted 178,326,215 (6386 MiB), objects ≈ 304,296,675, GC 2.73–2.80 s; deterministic + fixed point. Not bit-identical to 3C because 3D.2 changed the compiler's own source (the workload); the 3C binary on the 3D source gives byte-identical output, the same objects (≈ 304,296,68x), minor 1337 / major 6, wall 68.58–69.64 s: 3D adds no runtime cost |

**Fixes and deviations recorded in 3D:**
- `run-mlir-equivalence`'s Stage 2 compile ran node with `--stack-size=65536` and segfaulted on
  `WideClosureArity2047Test` (exit 139). `test/mlir_equivalence_main.cpp` now runs node under
  `ulimit -s unlimited` with `--stack-size=500000` (the Phase 0 step 0.5 fix, which had covered only
  the E2E and AOT runners); the pin then passes.
- `WideRecord33Test` / `WideRecord40Test`: every value correct, but their generated `show:` CHECK
  expected Elm's alphabetical field order while Eco's typed printer prints heap-layout order
  (unboxed fields first, then boxed, each by name), existing behaviour (`TypeAliasCtorTest`). The
  generator (`plans/wide-object-tail-kind-words-pins.py`, Appendix P0-A) now emits layout order; only
  those two files changed. **Open (not part of this plan):** Eco's `Debug.toString` record field
  order differs from Elm's alphabetical order.
- `slot_kinds` on papCreate/papExtend defaults to an empty array (the front end omits it when there
  are no captures/newargs); a missing non-empty one still fails the length check
  (`papcreate_missing_slot_kinds_rejected.mlir`). Required on construct.custom/record and
  papCreateGroup; optional on to_heap.
- 3D.4: 184 ops had neither bitmap nor `slot_kinds` (the old attribute defaulted); the sweep script
  gained `--add-missing` (kinds from operand types). `pap_group_root_chunks.mlir` rewritten by hand.
- 3D.3 also removed `assertNarrowContainer` (it depended on the switch; compiled code may now be
  wide).
- 3D.0 snapshot is `snapshots/lss-loop/pre-3d`; the perf binaries `eco-optP0`…`eco-optP3d` stay in
  `build/compiler/build-kernel/bin`.

### 3D checklist

- [x] 3D.0 snapshot `pre-wide-3d` + `extra.tgz` + baseline compiler binary
- [x] 3D.1 caps 2040/2047 in CustomConstructOp/RecordConstructOp; ToHeapOp caps; 4 limit fixtures (2 JIT, 2 negative)
- [x] 3D.2 `TooManyCtorFields` / `TooManyRecordFields` variants of the shared `TooLarge` error (ctor > 2040; record alias / literal / type > 2047), `HeapLimits` field constants, 5 `LimitErrorsTest` cases, CLI check
- [x] 3D.3 test switch gone: attribute, `wideObjectsAllowed`, `EcoRunner` hook, flag, census line, T8, `WideGuard` (grep = 0)
- [x] 3D.4 sweep: dry run 0 problems; write; only tuple attributes and comments remain; 28 comments reworded; fixture rename; codegen subset green
- [x] 3D.5 Ops.td attributes deleted (6 ops), `slot_kinds` required (5 ops; optional on to_heap), stale-attribute rejection + fixture, C++ greps clean
- [x] 3D.6 compiler/src and compiler/tests greps show only tuple uses; checker docstrings updated
- [x] 3D.7 the 10 list-L3 pins green; `WideCtorField24Test` docstring; 3C.5 elm-test pins still green
- [x] 3D.8 invariants: 8 full rows + 2 phrase edits; Phase 2 rows verified present; greps clean
- [x] 3D.9 theory docs: 9 passages; grep clean
- [x] 3D.10 final gate: every row of the expected-results table
- [x] 3D.11 canary quiet (or audited)
- [x] 3D.12 memory notes + overview status

### 3D rollback

| Step | Rollback |
|---|---|
| 3D.1, 3D.2, 3D.3 | independent; revert the code + fixtures |
| 3D.4 | restore `test/codegen` from `extra.tgz` (old attributes are still accepted until 3D.5) |
| 3D.5 | the point of no return for Phase 3C: restore `runtime/src/codegen` **and** `test/codegen` together (`lss-loop-snap.sh restore pre-wide-3d` + `extra.tgz`). Reverting 3D.5 alone without 3D.4 is fine; reverting 3D.4 alone after 3D.5 is not (fixtures would carry rejected stale attributes) |
| 3D.6–3D.9 | docs/tests only; restore from the snapshot |
| Whole group | `benchmarks/lss-loop-snap.sh restore pre-wide-3d && tar xzf snapshots/lss-loop/pre-wide-3d/extra.tgz`, `cmake --build build`, cache wipe (§S.7), re-run the 3C gate |

### 3D open questions (with defaults)

| # | Question | Default |
|---|---|---|
| 3D-Q1 | Where do the canonicalization limits live (module dependency)? | `Types.elm` constants if the import is acyclic, else a new leaf `Compiler/Data/HeapLimits.elm` |
| 3D-Q2 | Rename `UnboxedBitmap.elm` checker? | Only if its docstring would mislead after the retarget; renaming is test-tree-only |
| 3D-Q3 | Add an E2E for exactly 2040/2047 fields? | No: the codegen fixtures of 3D.1 cover the limit; `WideCtor1100Test` / `WideRecordDecoder300Test` cover the front end at scale. Revisit if a front-end-only bug at > 1100 fields appears |
| 3D-Q4 | Does the E2E harness name codegen fixtures with a filterable prefix? | Check `build/test/test --list` once; use the prefix it shows |

---

## Definition of done: the whole plan (all phases)

The plan is done when **all** of the following hold on one tree, verified by the 3D final gate
(3D.10) and recorded in the overview.

**Bugs** (overview §3): B1–B11 and B13–B23 fixed (B12 was withdrawn), each with its pin green.

| Bug | Pin (where it is written) |
|---|---|
| B1 | `CallAbiConsistencyTest` wide ctor (Phase 0; renamed in 3C.5) |
| B2 | `DestructorTypeProjectionTest` wide ctor (Phase 0; rewritten in 3C.5) plus the String-at-24 variant |
| B3 | `elm/WideRecordPatternTest.elm` and the B3 record elm-test (Phase 1 step 1a.3; rewritten in 3C.5) |
| B4 | `UnboxedBitmapTest` "closure kind attributes stay within the backend's slot limits" (Phase 0) |
| B5 | `elm/WideClosurePap27bTest.elm`, `elm/WideRecordDecoder26Test.elm`, `elm/WideRecordDecoder30Test.elm` |
| B6 | `closureCapture` death test (Phase 0 unit pin; replaces "closureCapture beyond slot 24 demotes to boxed") |
| B7 | the accessor unit pins (Phase 0 / Phase 1) |
| B8 | the 70-field `custom()` rooting pin (Phase 0) |
| B9 | `AbiCloningPapFastPassTest` case 9 (Phase 0 rewrite) |
| B10 | comments (no pin) |
| B11 | `eco_set_unboxed` death test (Phase 0) |
| B13 | `codegen/make_closure_packed_word.mlir` (Phase 0; CHECK updated in Phase 2) |
| B14 | `codegen/construct_custom_i1_operand_rejected.mlir`, `construct_record_i1_operand_rejected.mlir` |
| B15 | `elm/WideClosureGroupTest.elm` |
| B16 | `codegen/pap_simplify_fusion_slot_cap.mlir` (Phase 0; CHECKs updated in Phase 2) |
| B17 | the test oracles `HeapSnapshot.hpp` / `MinorWorkload.hpp` converted (Phase 1, 3A.7) |
| B18 | `elm/WideClosureArity2047Test.elm` and the `LimitErrorsTest` cases (phase-0 step 0.6b item 5, green in Phase 2 step 2.8.6) |
| B19 | the all-boxed layout unit test at arity 100 (Phase 2) |
| B20 | the sat-guard test of Phase 2 step 2.6.5 |
| B21 | none (Phase 1 fix, exit status checked by hand) |
| B22 | the papCreate verifier pin of Phase 1 |
| B23 | the chunked-root tests of Phase 2 step 2.2 |

**Evidence programs** (overview §1): E3 green from Phase 1; E4–E8 and E10 green from Phase 2; E1, E2
and E9 green from 3D.

**Pins** (phase-0 Step 0.6 is the authoritative list):
- **E2E (`test/elm/src`, `test/eco-kernel/src`):** all 23 Phase 0 pins pass:
  - `WideCtorField24Test`, `WideRecordPatternTest`, `WideClosureGroupTest`;
  - `WideClosurePap27bTest`, `WideClosureSat26Test`, `WideClosureBoxed27Test`,
    `WideClosureCapture27Test`;
  - `WideRecordDecoder26Test`, `WideRecordDecoder30Test`;
  - `WideClosureArity63Test`, `WideClosureArity300Test`, `WideClosureArity2047Test`;
  - `eco-kernel/WideClosureGcTest`;
  - `WideRecordDecoder70Test`, `WideRecordDecoder300Test`;
  - `WideRecord33Test`, `WideRecord40Test`, `WideRecord600Test`, `WideRecord1100Test`;
  - `WideCtorMixedTest`, `WideCtor1100Test`;
  - `eco-kernel/WideHeapGcTest`.

  The GC-stress pins print GC counts that prove minors and majors ran.
- **elm-test:**
  - the Phase 0 pins: CallAbi, DestructorTypeProjection ×2, AbiCloning 9, UnboxedBitmap closure
    limits, `LimitErrorsTest` (arity, lambda, captures, boundary, report);
  - the bytecode dense-array round trip (Phase 2 step 2.0);
  - the 3C.5 and 3C.6 cases;
  - the `LimitErrorsTest` field cases ×5 (3D.2);
- **Codegen fixtures:**
  - Phase 0's four;
  - Phase 2's (`eval_desc_sat_sizes`, `eval_desc_sat_wide_jit`, the arity-2047/2048 fixtures);
  - 3B's (`wide_record_40_jit`, `wide_custom_60_jit`, `wide_record_600_jit`, `wide_record_33_llvm`,
    `wide_record_33_kind_mismatch`);
  - 3D's (`construct_custom_2040`, `construct_record_2047`, `construct_custom_2041_rejected`,
    `construct_record_2048_rejected`, `stale_unboxed_bitmap_rejected`).
- **Unit:** every pin in `WideObjectPinsTest.cpp` (Phase 0), the Phase 1 unit tests,
  `WideClosureTest.cpp` (Phase 2: the closure boundary matrix at 20/21/52/53/2047, kernel
  descriptors) and `WideObjectTest.cpp` (3A T1–T7, T9–T14: YLOS, nursery-large, region/CR-038 zap,
  concurrent-mark t0, compaction, CAF permanent copy). They must pass in the default **and**
  `build-validate` trees.

**Gates green on the final tree** (3D.10):
- elm-tests (only the 2 GOPT_003 pins fail);
- `full` with 0 failures (after the cache wipe);
- the validate tree;
- `register-guards`, including the TSan and fork arms;
- `run-aot-e2e` (only the Phase 0 harness gaps fail);
- bootstrap B==C and `eco-verify`;
- `run-mlir-equivalence`;
- `tla-canary` strict and `tla-trace`;
- perf triple within spread, with counters explained (overview §7).

**Layout and representation facts true in code:**
- Custom ≤ 2040, Record ≤ 2047, Closure arity ≤ 2047 (§S.1), enforced by verifiers, release-mode
  runtime aborts and located front-end errors: the shared `TooLarge` canonicalization error for
  arity and captures (Phase 2) and for fields (3D.2), plus the post-mono `ValidateLimits` backstop.
- Kinds travel as `slot_kinds` (§S.5). No u64 kind bitmap remains on Custom/Record/closure/to_heap
  ops, and a leftover one is rejected as stale. The tuple2/tuple3 `unboxed_bitmap` remains.
- Every runtime kind read goes through the §S.1 accessors and snapshots. No `fieldKind` /
  `pointerMaskFromKindBitmap` call with a possible index ≥ 32 remains: grep `fieldKind(` and
  `pointerMaskFromKindBitmap(` and check each hit's bound.
- Root ranges over 64 slots go through `pushRootsByKinds` (§S.2).
- Wide evaluators (stage arity > `SAT_MAX_ARITY`) carry an empty `sat[]` (Phase 2 step 2.6.8).

**Invariants:**
- Phase 2 rows: HEAP_077, HEAP_078 (new), HEAP_033, CGEN_003, CGEN_049, REP_CLOSURE_001,
  REP_CLOSURE_002, FORBID_CLOSURE_002.
- 3D.8 rows: HEAP_019, REP_HEAP_002, HEAP_004, HEAP_046, HEAP_034, MONO_013, XPHASE_001,
  REP_BOUNDARY_002, CGEN_026 (with the record cap), CGEN_020.

All are reworded as specified. `design_docs/invariants.csv` contains no "24 typed slots", "26 typed
captures", "52-bit" or "32-slot" text outside retired rows.

**Docs:**
- the theory passages of 3D.9;
- the overview §2 layout block matches the code;
- the TLA AUDIT.md entries for Phase 1d, Phase 2 and 3A (M1, M3, M5, plus any the canary named) exist.

**Tools and instrumentation:**
- the test switch is removed (3D.3): no `eco.allow_wide_objects`, `wideObjectsAllowed` or
  `Elm::testing::allow_wide_objects`;
- the census is a script (`plans/wide-object-tail-kind-words-census.py`, Phase 0); no census code
  exists in the tree;
- `test/scripts/sweep_slot_kinds.py`, `test/codegen/gen_wide_fixtures.py` and
  `test/codegen/gen_wide_limit_fixtures.py` are checked in;
- the old `eco_pap_extend` (u64) and `eco_alloc_closure_group_slow` entries are deleted (Phase 2);
- `AllocateCtorOp` / `scalar_bytes` are deleted (3A.10).

**Memory notes:** the elm-tests baseline note is updated, and the new wide-objects note and index
line are added (3D.12).

**Plan:** overview `Status: DONE`, with the final perf row and failure lists recorded.
