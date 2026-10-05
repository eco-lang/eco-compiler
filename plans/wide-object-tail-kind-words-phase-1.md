# Wide objects, Phase 1: correctness fixes under today's layout

**Parent:** `plans/wide-object-tail-kind-words.md`. Its §S (shared definitions, commands, test
switch) is binding; §2 (layout), §3 (bugs), §5 (GC concurrency procedure) and §6 (test mechanics)
are the context. **Status:** DONE (2026-10-05): all steps implemented, gate green (§7.1).

**Scope:** B1, B2, B3, B6, B7, B8, B9, B10, B11, B13, B14, B15, B16, B17, B21 and B22, plus the
D-semantics walker split (1d). **No object layout changes.**
- `Closure` keeps `n:6 | max:6 | rk:2 | kinds:50` (25 inline kinds).
- `Custom` / `Record` keep their header bitmaps.
- No verifier cap is lifted.

Kinds a container cannot describe read as **boxed (0)**. That is D semantics.

**Depends on:** Phase 0 is done. Its pins exist and are red for the reasons recorded in the
Phase 0 gate (`-phase-0.md` Step 0.7), and the baselines are recorded (Steps 0.2–0.4). Two Phase 0
censuses (Step 0.4b) are inputs here:
- the kernel `closureCapture` / `allocClosureK` census (step 1c.3);
- the runtime-builder size census (step 1d.3).

**Pin names** are Phase 0's (Step 0.6): E2E files, the elm-test cases, the codegen fixtures in
`-phase-0.md` Appendix P0-C, and the unit pins `wide B…` in `test/allocator/WideObjectPinsTest.cpp`.
New tests this phase adds beyond the pins go into `test/allocator/WideKindsTest.cpp`.

**Line numbers** were verified against the tree on 2026-10-05. When a line has drifted, re-anchor on
the quoted code and the function name.

---

## 0. Order and commit plan

| Sub-phase | Area | Commits | Pins that turn green |
|---|---|---|---|
| 1c | runtime helpers + runtime bug fixes (first: later steps use the helpers) | 1c.1 helpers; 1c.2–1c.7 one commit per bug | unit pins `wide B6`, `wide B7: pointerMask…`, `wide B7: equality…`, `wide B8`, `wide B11` |
| 1d | walker split (touches TLA-pinned code; separate commit for audit) | one commit + AUDIT entries | unit pins `wide B7: boxed captures 32..39…`, `wide B8b` (validate tree); B17 oracles |
| 1b | codegen and dialect | one commit per bug (1b.1–1b.8) | fixtures `make_closure_packed_word`, `construct_*_i1_operand_rejected` ×2, `pap_simplify_fusion_slot_cap`; E2E `WideClosureGroupTest` (B15) |
| 1a | compiler (Elm) and compiler driver | 1a.1 B1+B9; 1a.2 B2; 1a.3 B3; 1a.4 B21 | elm-test: the 2 existing wide pins, the B3 record-pattern pin, AbiCloning test 9 (B9); E2E `WideRecordPatternTest` |
| 1e | comments | one commit | none |

Run the gate (§7) once, after all sub-phases.

---

## 1c. Runtime helpers and runtime fixes

### Step 1c.1: add the §S.1/§S.2/§S.6 helpers (Phase 1 form)

The overview's §S.1, §S.2 and §S.6 define the names and signatures. This step implements their
Phase 1 bodies: D semantics, 25 inline closure kinds, no extension words.

**File:** `runtime/src/allocator/Heap.hpp`. Insert after `pointerMaskFromKindBitmap`, which ends at
line 287 (`return mask;` / `}`), still inside `namespace Elm`.

Also harden the existing helpers at `Heap.hpp:265-287`:

```cpp
inline u64 fieldKind(u64 bitmap, unsigned index) {
    assert(index < 32 && "fieldKind: index past one 64-bit kind word (use the slot-kind accessors)");
    return (bitmap >> (2 * index)) & 0x3ULL;
}
inline u32 tupleFieldKind(u32 headerUnboxed, unsigned index) {
    assert(index < 3 && "tupleFieldKind: header.unboxed holds 3 slots");
    return (headerUnboxed >> (2 * index)) & 0x3U;
}
inline u64 bitmapSetKind(u64 bitmap, unsigned index, u64 kind) {
    assert(index < 32 && "bitmapSetKind: index past one 64-bit kind word");
    const u64 shift = 2ULL * index;
    const u64 mask  = 0x3ULL << shift;
    return (bitmap & ~mask) | ((kind & 0x3ULL) << shift);
}
inline u64 pointerMaskFromKindBitmap(u64 kindBitmap, unsigned numSlots) {
    // One kind word describes slots 0..31; slots 32..63 have no kind here and read as boxed
    // (D semantics). The mask itself is 64 bits wide; wider buffers use pushRootsByKinds.
    assert(numSlots <= 64 && "pointerMaskFromKindBitmap: mask covers 64 slots; use pushRootsByKinds");
    u64 mask = 0;
    for (unsigned i = 0; i < numSlots; ++i)
        if (i >= 32 || fieldKind(kindBitmap, i) == 0) mask |= (1ULL << i);
    return mask;
}
```

Every preset builds with asserts on (`-UNDEBUG`, `CMakePresets.json`), so these asserts are active
in gates.

**New helpers** (insert after the block above):

```cpp
// ---- Wide-object slot kinds (plans/wide-object-tail-kind-words.md §S.1; Phase 1 bodies) ----
constexpr u32 CUSTOM_HDR_SLOTS   = 24;    // Custom::unboxed:48
constexpr u32 RECORD_HDR_SLOTS   = 32;    // Record::unboxed:64
constexpr u32 CLOSURE_HDR_SLOTS  = 25;    // Closure::unboxed:50 (Phase 2 -> 20)
constexpr u32 SLOTS_PER_EXT_WORD = 32;
constexpr u32 CUSTOM_MAX_FIELDS  = 2040;
constexpr u32 RECORD_MAX_FIELDS  = 2047;
constexpr u32 CLOSURE_MAX_ARITY  = 63;    // Phase 2 -> 2047

constexpr u32 extWords(u32 n, u32 hdrSlots) {
    return n > hdrSlots ? (n - hdrSlots + SLOTS_PER_EXT_WORD - 1) / SLOTS_PER_EXT_WORD : 0;
}
inline u32 kindInWord(u64 word, u32 i) {
    assert(i < 32);
    return static_cast<u32>(word >> (2 * i)) & 3u;
}
// Phase 1 (D semantics): slots the header bitmap cannot describe are boxed.
// Phase 3A adds the extension-word branch bounded by header.unboxed.
inline u32 customSlotKind(const Custom* c, u32 i) {
    return i < CUSTOM_HDR_SLOTS ? kindInWord(c->unboxed, i) : 0u;
}
inline u32 recordSlotKind(const Record* r, u32 i) {
    return i < RECORD_HDR_SLOTS ? kindInWord(r->unboxed, i) : 0u;
}
// Direct closure accessor for NON-allocating readers (GC walkers, validate checks,
// printers). Allocating loops must use ClosureKinds (below). Phase 2 adds the ext branch.
inline u32 closureSlotKind(const Closure* cl, u32 i) {
    return i < CLOSURE_HDR_SLOTS ? kindInWord(cl->unboxed, i) : 0u;
}
struct ClosureKinds {
    u64 hdr;        // Phase 1: the 50-bit inline field (25 slots)
    u32 max;        // max_values
    u32 k;          // ext words copied; Phase 1: always 0
    u64 ext[64];    // used from Phase 2
};
inline void snapshotClosureKinds(const Closure* cl, ClosureKinds& out) {
    out.hdr = cl->unboxed;
    out.max = cl->max_values;
    out.k = 0;
}
inline u32 closureKindAt(const ClosureKinds& ks, u32 slot) {
    return slot < CLOSURE_HDR_SLOTS ? kindInWord(ks.hdr, slot) : 0u;   // Phase 2: ext[]
}
inline const u64* customExtWords(const Custom* c) { return reinterpret_cast<const u64*>(&c->values[c->header.size]); }
inline const u64* recordExtWords(const Record* r) { return reinterpret_cast<const u64*>(&r->values[r->header.size]); }

// Test switch (overview §S.6): Elm::testing::allow_wide_objects. Unit tests that build wide
// Custom/Record objects on purpose set it; from Phase 3B, EcoRunner also sets it for modules that
// carry the `eco.allow_wide_objects` attribute. Production code never sets it; Phase 3D deletes it.
// Plain bool: written only by single-threaded test setup.
namespace testing { inline bool allow_wide_objects = false; }
// Validate-and-debug check that no runtime/kernel path builds a Custom/Record wider than its
// header bitmap before Phase 3A (makes the walkers' tail loop provably dead outside tests).
inline void assertNarrowContainer(u32 tag, u32 size) {
    assert((testing::allow_wide_objects ||
            !((tag == Tag_Custom && size > CUSTOM_HDR_SLOTS) ||
              (tag == Tag_Record && size > RECORD_HDR_SLOTS))) &&
           "wide Custom/Record built before Phase 3A (plans/wide-object-tail-kind-words.md)");
    (void)tag; (void)size;
}
```

**Check:** `Closure` is declared below `pointerMaskFromKindBitmap` in `Heap.hpp`; the `Closure`
typedef is at line 615. The four accessors that dereference `Custom`/`Record`/`Closure` must sit
**after** those typedefs: put them right after the `static_assert`s that follow `Closure`
(`Heap.hpp:632-641`). The constants, `extWords` and `kindInWord` may stay near
`pointerMaskFromKindBitmap`.

**File:** `runtime/src/allocator/RuntimeExports.h` (§S.2: `pushRootsByKinds` is a template, so it
is defined in this header, which `HeapHelpers.hpp` already includes). Add after the
`eco_gc_*_stack_range*` declarations at lines 596-598. That block is inside `extern "C"`, so close it first, or put the
template after the `extern "C"` block. Needs `<algorithm>`.

```cpp
// plans/wide-object-tail-kind-words.md §S.2
template <class KindOf>
inline void pushRootsByKinds(uint64_t* base, uint32_t n, KindOf kindOf) {
    for (uint32_t off = 0; off < n; off += 64) {
        uint32_t c = std::min<uint32_t>(64, n - off);
        uint64_t mask = 0;
        for (uint32_t i = 0; i < c; ++i) if (kindOf(off + i) == 0) mask |= uint64_t{1} << i;
        if (mask) eco_gc_push_stack_range(base + off, c, mask);
    }
}
```

**Invariants:** HEAP_019 / REP_HEAP_002 encoding (2 bits per slot) and FORBID_REP_001 (kinds are
read only from the container's bitmap).

**Test** (new file `test/allocator/WideKindsTest.cpp`, registered in `test/main.cpp` and
`test/CMakeLists.txt` as overview §S.8 describes, next to Phase 0's `WideObjectPinsTest.cpp`):
- `"wide kinds: extWords boundaries"`: `extWords(24,24)==0`, `extWords(25,24)==1`,
  `extWords(56,24)==1`, `extWords(57,24)==2`, `extWords(2040,24)==63`,
  `extWords(2047,32)==63`, `extWords(2047,20)==64`.
- `"wide kinds: accessors return boxed past the header (Phase 1)"`:
  - a hand-made `Custom` with `unboxed` = all-Int (`0x5555…` masked to 48 bits) and size 30:
    `customSlotKind(c, 23) == 1`, `customSlotKind(c, 24..29) == 0`;
  - the same for `Record` at 32/33;
  - `closureSlotKind` at 24/25.

  Build the objects in a `std::vector<u64>` buffer, not the heap: these are pure functions.

**Rollback:** revert the commit. Nothing uses the helpers yet.

### Step 1c.2: B7, runtime readers that loop to a size (equality, printers, kernel)

Every site below loops `i` up to `header.size` / `n_values` / `max_values` (≤ 63), so a `fieldKind`
shift at `i ≥ 32` is UB. Replace each with the bounded accessor:

| # | Site (verified) | Before | After |
|---|---|---|---|
| 1 | `elm-kernel-cpp/src/core/Utils.cpp:656-657` (Custom equality) | `Elm::fieldKind(ac->unboxed, i)`, same for `bc` | `Elm::customSlotKind(ac, i)`, `Elm::customSlotKind(bc, i)` |
| 2 | `Utils.cpp:672-673` (Record equality) | `Elm::fieldKind(ar->unboxed, i)` / `br` | `Elm::recordSlotKind(ar, i)` / `br` |
| 3 | `runtime/src/allocator/RuntimeExports.cpp:3395` (`Debug.toString` custom) | `fieldKind(custom->unboxed, i)` | `customSlotKind(custom, i)` |
| 4 | `RuntimeExports.cpp:3433` (record) | `fieldKind(record->unboxed, i)` | `recordSlotKind(record, i)` |
| 5 | `RuntimeExports.cpp:4006` (typed record printer; `unboxed` is the record's bitmap read above it) | `fieldKind(unboxed, i) != 0` | `recordSlotKind(record, i) != 0` (drop the local `unboxed` if unused) |
| 6 | `RuntimeExports.cpp:4115` (typed custom printer) | `fieldKind(custom->unboxed, i) != 0` | `customSlotKind(custom, i) != 0` |

**Unchanged:** fixed small indices at `RuntimeExports.cpp:3228`, `:3279`, `:3827`, `:4201`;
`ListOps.cpp:247`; `Utils.cpp:764/765/771/772` (Dict node fields 1 and 2);
`elm-kernel-cpp/src/file/File.cpp:72/86` (small named fields). All index < 32.

**Pin:** `wide B7: equality of 40-field records compares slots >= 32 as boxed`
(`WideObjectPinsTest.cpp`) goes red → green. The pin sets `Elm::testing::allow_wide_objects` around
its record builds, because step 1c.7's builder assert fires otherwise.

**Extra test** (`WideKindsTest.cpp`, deterministic): `"wide kinds: Debug.toString of a 40-field
record prints slot 32 as a string"`.
- Set `Elm::testing::allow_wide_objects = true`.
- Build one 40-field Record with `HeapHelpers::record()`: slot 0 Int (mask bit), slots 1..39 boxed
  strings.
- Assert `Debug.toString`'s output contains the slot-32 string text, not a number.
- Before this step it fails: on x86, slot 32 reads slot 0's kind (Int) and prints the pointer bits.
- Restore the flag at the end. A crash also counts as red.

**Rollback:** per-file revert.

### Step 1c.3: B6, `closureCapture` never stores a typed value past the inline kinds

**File:** `runtime/src/allocator/HeapHelpers.hpp`, `closureCapture` (`:2039-2087`).

Before (`:2054-2058`):

```cpp
    size_t idx = cl->n_values;
    cl->values[idx] = value;

    if (kind != PK_Boxed && idx < 25) {
        cl->unboxed = bitmapSetKind(cl->unboxed, static_cast<unsigned>(idx),
                                    static_cast<u64>(kind));
    }
```

After:

```cpp
    size_t idx = cl->n_values;
    if (kind != PK_Boxed && idx >= CLOSURE_HDR_SLOTS) {
        // B6 / HEAP_077: kernel closures keep slots past the inline kinds boxed; a typed
        // capture here would be traced as a pointer. Permanent (Phase 2 lowers the bound to 20).
        std::fprintf(stderr, "[eco] FATAL: closureCapture of a typed value at slot %zu "
                             "(inline kinds cover %u)\n", idx, CLOSURE_HDR_SLOTS);
        std::abort();
    }
    cl->values[idx] = value;
    if (kind != PK_Boxed) {
        cl->unboxed = bitmapSetKind(cl->unboxed, static_cast<unsigned>(idx),
                                    static_cast<u64>(kind));
    }
```

- Update the validate block at `:2061-2081` to drop its `idx < 25` guard.
- Before landing, consult the Phase 0 kernel census: no kernel call site captures a typed value at
  index ≥ 25. If one does, that kernel boxes the value at its call site (`eco_alloc_int` etc.)
  instead.

**Pin:** `wide B6: closureCapture of a typed kind at slot >= 25 aborts` (`WideObjectPinsTest.cpp`,
fork-based death test) goes red → green.

**Existing test removed:** `test/allocator/HeapHelpersTest.cpp:1551`,
`"closureCapture beyond slot 24 demotes to boxed"`, asserts the B6 behaviour (30 `PK_Int` captures,
slots 25..29 reading kind 0). Delete it together with its registration, and add in its place:
- `"closureCapture of a boxed value at slot 25..29 is allowed"`: 25 Int captures plus 5 boxed;
  `closureSlotKind(cl, 0..24) == 1`, `25..29 == 0`.

**Invariants:** HEAP_SNAPSHOT_001 (unchanged: the write is still before publication); REP_CLOSURE_001.

**Rollback:** revert the step and restore the old test.

### Step 1c.4: B7, closure-kind reads in the apply paths (snapshot-based)

Every site reads `closure->unboxed` (or a copy) with `>> 2*slot` where `slot ≤ 62`.

| # | Site | Change |
|---|---|---|
| 1 | `RuntimeExports.cpp:2556` (`eco_pap_extend`, caller mask) | `pointerMaskFromKindBitmap(new_unboxed_bitmap, num_newargs)` stays: after step 1c.1 it is defined for ≤ 64 slots and treats slots ≥ 32 as boxed; `num_newargs ≤ 63` |
| 2 | `RuntimeExports.cpp:2564`, `:2571` (`eco_pap_extend`, slot kinds) | Before the loops: `ClosureKinds ks; snapshotClosureKinds(old_closure, ks);`. Replace `(old_unboxed >> (2 * (old_n_values + i))) & 0x3ULL` with `closureKindAt(ks, old_n_values + i)` (both loops) |
| 3 | `RuntimeExports.cpp:2572` (caller kind) | `(new_unboxed_bitmap >> (2 * i)) & 0x3ULL` becomes `i < 32 ? kindInWord(new_unboxed_bitmap, i) : 0` (a u64 caller bitmap describes 32 slots; Phase 2 replaces it with `EvalParamLayout`) |
| 4 | `RuntimeExports.cpp:2600` (re-resolve after boxing) | Also re-snapshot: `snapshotClosureKinds(old_closure, ks);`. `new_closure->unboxed = old_unboxed;` (`:2650`) is unchanged: the 50-bit field is copied whole |
| 5 | `RuntimeExports.cpp:2696` / `:2707` (`spliceArgsForSaturatedCall`) | `uint64_t bitmap = closure->unboxed;` becomes `ClosureKinds ks; snapshotClosureKinds(closure, ks);`. `(bitmap >> (2 * slot)) & 0x3ULL` becomes `closureKindAt(ks, slot)`. Every re-resolve inside the loop re-snapshots. `bitmap_out` keeps receiving `ks.hdr` (its callers only forward it) |
| 6 | `RuntimeExports.cpp:2777-2786` (validate tripwire) | `(bitmap >> (2 * dbg_i)) & 0x3ULL` becomes `closureKindAt(ks, dbg_i)` |
| 7 | `RuntimeExports.cpp:2899-2905` (`eco_closure_call_saturated` roots) | Replace the `pointerMaskFromKindBitmap(bitmap, max_values)` + `eco_gc_push_stack_range` pair with `ClosureKinds ks; snapshotClosureKinds(closure, ks); pushRootsByKinds(reinterpret_cast<uint64_t*>(combined_args), max_values, [&](uint32_t i){ return closureKindAt(ks, i); });` |
| 8 | `RuntimeExports.cpp:2978-2984` (`invokeSaturatedTyped` roots) | same as #7 |
| 9 | `RuntimeExports.cpp:2283-2297` (`eco_apply_segmentation_unknown`) and `:2431-2440` (`eco_apply_closure_eval` under-saturated) | The `assert(num_args <= 32 …)` becomes a release check: `if (num_args > 32) { fprintf(stderr, "[eco] FATAL: …"); abort(); }`. The `<< (2 * i)` builds (i < 32) are then defined. `:2292` keeps `pointerMaskFromKindBitmap` (≤ 32). Phase 2 replaces both with `eco_pap_extend_l` |
| 10 | `elm-kernel-cpp/src/core/ListExports.cpp:224-228` (`closureNewArgKind`) | `return static_cast<uint8_t>((meta.unboxed >> (2 * slot)) & 0x3ULL);` becomes `return slot < Elm::CLOSURE_HDR_SLOTS ? static_cast<uint8_t>(Elm::kindInWord(meta.unboxed, slot)) : 0;` (`ClosureMeta` is already a snapshot; Phase 2 turns it into `ClosureKinds`) |

**Why boxed past slot 24 is consistent today:**
- `eco_pap_extend` converts each new arg to the slot's kind. At slot ≥ 25 that is 0, so it boxes.
- The GC sees 0 (boxed).
- The typed consumer of such a slot is wrong today (E4). That is fixed in Phase 2; Phase 1 only
  removes the UB.

**Pins:** `wide B7: pointerMaskFromKindBitmap treats slots >= 32 as boxed` goes green with step
1c.1's bounded `pointerMaskFromKindBitmap` (`bm = 1`, `n = 40` gives `(1ULL<<40) - 2`).
`wide B7: boxed captures 32..39 of a 40-slot closure survive minor GCs` goes green with step 1d
(validate tree).

**Extra tests** (`WideKindsTest.cpp`; `GenericApplyBoxingTest.cpp` must stay green):
- `"wide kinds: closure kinds past slot 31 read boxed (snapshot)"`: a hand-built closure
  `max_values = 40`, slot 0 Int in `unboxed`. Assert `closureKindAt(ks, 32) == 0` and that
  `pushRootsByKinds` over 40 slots pushes masks whose bit 32 is set. Capture the pushes through
  `eco_gc_stack_range_point()` before and after: a range was added.
- `"wide kinds: eco_closure_call_saturated roots 40 slots"`: saturate an all-boxed `max_values = 40`
  kernel-style closure (an evaluator that returns its 40th arg). Force a minor GC inside: set the
  heap with `initAllocator` and a tiny nursery, and have the evaluator allocate. Assert the returned
  HPointer still resolves to the 40th string.

**Rollback:** per-site revert.

### Step 1c.5: B8, `custom()` / `record()` rooting past 64 slots

**File:** `HeapHelpers.hpp`.
- `custom()`: `:1433-1469`. Mask loop at `:1451-1456`, call at `:1458-1462`.
- `record()`: `:1528-1555`. Loop `:1538-1543`, call `:1545-1547`.

In both, replace the mask construction and the call with:

```cpp
    std::vector<uint64_t> roots(values.size());
    for (size_t i = 0; i < values.size(); ++i) std::memcpy(&roots[i], &values[i], sizeof(uint64_t));
    const uint32_t n = static_cast<uint32_t>(values.size());
    auto kindOf = [&](uint32_t i) -> uint32_t {            // header bitmap only: D semantics
        return i < CUSTOM_HDR_SLOTS /* RECORD_HDR_SLOTS in record() */ ? kindInWord(unboxed_mask, i) : 0u;
    };
    Custom* obj;                                          // Record* in record()
    if (n <= 64) {
        uint64_t hptr_mask = 0;
        for (uint32_t i = 0; i < n; ++i) if (kindOf(i) == 0) hptr_mask |= uint64_t{1} << i;
        obj = static_cast<Custom*>(eco_alloc_with_roots(Tag_Custom, total_size,
                                   roots.empty() ? nullptr : roots.data(), n, hptr_mask));
    } else {
        size_t saved = eco_gc_stack_range_point();
        pushRootsByKinds(roots.data(), n, kindOf);        // chunks of 64
        obj = static_cast<Custom*>(eco_alloc_with_roots(Tag_Custom, total_size, nullptr, 0, 0));
        eco_gc_restore_stack_range_point(saved);
    }
```

**Decision:** chunked rooting (review finding P12). Rejecting more than 64 fields is not an option.

`eco_alloc_with_roots` (`RuntimeExports.cpp:149-190`) is unchanged. With `n_roots = 0` it pushes
nothing, and our ranges stay open across its GC.

**Pins:** `wide B8: custom() with 70 boxed fields roots every slot on the slow path` goes green;
`wide B8b: slots 24..69 of a 70-field Custom survive a later minor GC` goes green after step 1d.
Both set `Elm::testing::allow_wide_objects = true` (step 1c.7's builder assert).

**Extra tests** (`WideKindsTest.cpp`, `Elm::testing::allow_wide_objects = true`, heap via
`initAllocator` with a tiny nursery): the same pair for `record()`, with slots 32..69 checked
across the later minor GC.

**Rollback:** revert the step.

### Step 1c.6: B11, `eco_set_unboxed` default arm

**File:** `RuntimeExports.cpp:267-299`. `default:` (`:294-298`) becomes:

```cpp
        case Tag_Record:
        case Tag_Closure:
            std::fprintf(stderr, "[eco] FATAL: eco_set_unboxed on tag %u (its kinds are not in header.unboxed)\n",
                         unsigned(header->tag));
            std::abort();
        default:
            // Array's uniform kind (and other header.unboxed users).
            header->unboxed = static_cast<u8>(bitmap & 0x3);
            break;
```

**Pin:** `wide B11: eco_set_unboxed on a Record aborts` (`WideObjectPinsTest.cpp`) goes red → green.

**Rollback:** revert.

### Step 1c.7: `scalar_bytes` and narrow-container asserts (overview §2.1.2)

- In `eco_alloc_custom` (`RuntimeExports.cpp:247`), `eco_alloc_custom_fast` (`:1391`),
  `eco_alloc_custom_slow` (`:1413`) and `eco_init_custom_at` (`:1904`), after `hdr->size` is set
  (`:1405`, `:1909`; for `:247`/`:1413` after the allocation returns):

  ```cpp
  assert((scalar_bytes == 0 || hdr->size <= CUSTOM_HDR_SLOTS) && "scalar words would enter the tail loop");
  assertNarrowContainer(Tag_Custom, field_count);
  ```

- In `eco_alloc_record` (`:449`, after `:458`), `eco_alloc_record_fast` (`:1565`),
  `eco_alloc_record_slow` (`:1580`) and `eco_init_record_at` (`:1894`):
  `assertNarrowContainer(Tag_Record, field_count);`.
- In `ThreadLocalHeap.cpp` `initHeaderForTag` (Custom arm `:147-149`, Record arm `:150-152`), after
  `hdr->size` is set: `assertNarrowContainer(hdr->tag, hdr->size);`. `ThreadLocalHeap.cpp` has a
  census pin, but plain asserts are not concurrency lines, so the hash is unchanged.
- `HeapHelpers::custom()` / `record()` reach `initHeaderForTag` through `eco_alloc_with_roots`, so
  they are covered.

**Tests:** existing unit tests stay green. Every test that builds a wide Custom/Record on purpose
sets `Elm::testing::allow_wide_objects` (the B7 equality pin, B8/B8b, the `WideKindsTest` extras).

**Rollback:** revert.

---

## 1d. D-semantics walker split (B7 walkers, B17 oracles)

### Step 1d.1: the pattern

For each Custom/Record arm, replace

```cpp
for (u32 i = 0; i < hdr->size && i < 24; i++) X(c->values[i], fieldKind(c->unboxed, i) == 0);
```

with

```cpp
{
    const u32 n = hdr->size, h = n < CUSTOM_HDR_SLOTS ? n : CUSTOM_HDR_SLOTS;
    for (u32 i = 0; i < h; i++) X(c->values[i], kindInWord(c->unboxed, i) == 0);
    for (u32 i = h; i < n; i++) X(c->values[i], customSlotKind(c, i) == 0);   // tail: boxed in Phase 1
}
```

- **Record:** `RECORD_HDR_SLOTS` and `recordSlotKind`.
- **Closure arms** keep `i < cl->n_values` and replace `fieldKind(cl->unboxed, i)` with
  `closureSlotKind(cl, i)`.
- Inside files whose code is in `namespace Elm`, the helpers need no qualifier. Elsewhere use
  `Elm::`.

### Step 1d.2: every site

| # | File:line (verified) | Arm | Pinned? |
|---|---|---|---|
| 1 | `runtime/src/allocator/HeapChildWalk.hpp:68-72` | Custom | no |
| 2 | `HeapChildWalk.hpp:74-78` | Record | no |
| 3 | `HeapChildWalk.hpp:87-94` | Closure (`:93`) | no |
| 4 | `runtime/src/allocator/NurseryChildWalk.hpp:36-40` | Custom | no |
| 5 | `NurseryChildWalk.hpp:42-46` | Record | no |
| 6 | `NurseryChildWalk.hpp:57` | Closure | no |
| 7 | `runtime/src/allocator/NurseryParallel.cpp:500-503` | Custom | **`NP.scanEntryP` (M3)** |
| 8 | `NurseryParallel.cpp:505-508` | Record | **`NP.scanEntryP`** |
| 9 | `NurseryParallel.cpp:516-519` | Closure | **`NP.scanEntryP`** |
| 10 | `runtime/src/allocator/NurserySpace.cpp:890-896` | Custom (validate walk) | no |
| 11 | `NurserySpace.cpp:898-904` | Record (validate walk) | no |
| 12 | `NurserySpace.cpp:906-912` | Closure (validate walk) | no |
| 13 | `NurserySpace.cpp:1046-1053` | Closure (validate old→young) | no |
| 14 | `NurserySpace.cpp:1068-1074` | Custom (validate old→young) | no |
| 15 | `NurserySpace.cpp:1076-1082` | Record (validate old→young) | no |
| 16 | `NurserySpace.cpp:1899-1909` | Custom (minor `scanObject`, incl. `validateBitmapSlotKind`) | no |
| 17 | `NurserySpace.cpp:1910-1920` | Record (minor `scanObject`) | no |
| 18 | `NurserySpace.cpp:1949-1962` | Closure (minor `scanObject`; the `ECO_GC_DEBUG` print at `:1961` too) | no |
| 19 | `runtime/src/allocator/OldGenSpace.cpp:3580-3585` | Custom (`scanChildren`) | no |
| 20 | `OldGenSpace.cpp:3587-3592` | Record | no |
| 21 | `OldGenSpace.cpp:3613-3616` | Closure | no |
| 22 | `OldGenSpace.cpp:7386-7391` | Custom (compaction fixup) | no |
| 23 | `OldGenSpace.cpp:7393-7398` | Record | no |
| 24 | `OldGenSpace.cpp:7412-7415` | Closure | no |
| 25 | `test/allocator/HeapSnapshot.hpp:127-137` | Custom oracle: `i < 48` becomes the full `hdr->size` plus `customSlotKind` | no (test) |
| 26 | `HeapSnapshot.hpp:139-149` | Record oracle: `i < 64` becomes `hdr->size` plus `recordSlotKind` | no |
| 27 | `HeapSnapshot.hpp:169-177` | Closure oracle: `i < 52` becomes `n_values` plus `closureSlotKind` | no |
| 28 | `HeapSnapshot.hpp:299-350` | the second copy of the three arms (Custom `:301`, Record `:313`, Closure `:345`) | no |
| 29 | `test/allocator/MinorWorkload.hpp:139-153` | Custom / Record hash: `fieldKind` becomes the accessors | no |

**Not changed:** the prefetch arms `NurseryParallel.cpp:215-219` (`NP.MinorEnv`) and
`NurseryRegion.cpp:395-399` (`NR.RegionEnv`). They loop `i < 4`, so they are UB-free and within
the header. Leaving them untouched keeps those two pins quiet.

`NurseryRegion.cpp` `scanEntryR` and `NurseryTenure.cpp` reach Custom/Record through
`forEachChildSlot` (row 4/5).

**Invariants:**
- Every walker of one collection visits exactly the same slots. The mark pass (rows 19–21) and the
  fix pass (rows 22–24) must agree; the comment at `OldGenSpace.cpp:7405-7407` says so. Using the
  same helper in all arms keeps them equal by construction.
- HEAP_019: kinds come only from the container.
- Closure walkers bound by `n_values` (comment at `NurserySpace.cpp:1930-1945`).

### Step 1d.3: dead-tail evidence

**In production**, before Phase 3A, the tail loop runs only for Custom/Record objects wider than 24/32:
- compiled code cannot build them (verifier caps, `EcoOps.cpp:388`, `:452`);
- runtime and kernel builders assert against them (step 1c.7).

**Census input:** the Phase 0 builder census shows every kernel builder ≤ 9 fields. If it shows a
wider one, that builder must keep its slots past the cap boxed, because D semantics trace them.
Review it before landing 1d.

**Rejected:** no runtime counter. A global atomic in the walkers would add a concurrency line to
census-pinned files, and the asserts give the same guarantee.

### Step 1d.4: TLA canary (overview §5)

After 1d, build. The canary (in ALL) reports `NP.scanEntryP` (M3) changed. Then:
1. Read `test/tla/M3-minor-forwarding/MAPPING.md` for `scanEntryP` / the object-scan abstraction.
   The change replaces a capped kind read with an uncapped accessor of the same frozen object; no
   atomic, lock or step changes.
2. Append to `test/tla/M3-minor-forwarding/AUDIT.md` (format as the 2026-10-01 entries):

   ```
   ## 2026-10-xx — wide objects Phase 1d: D-semantics walker split (GC_MODEL_001)

   Pins fired: region `NP.scanEntryP` (**<new 12-hex prefix>**).

   Change (plans/wide-object-tail-kind-words-phase-1.md §1d): the Custom/Record arms of scanEntryP
   scan all `hdr->size` slots (header-bitmap loop, then a tail loop treating slots past 24/32 as
   boxed); the Closure arm reads kinds through `closureSlotKind` (UB-free for n_values ≥ 32). The
   object is frozen (HEAP_SNAPSHOT_001); kinds are plain reads of the object, as before; no atomic,
   lock, memory order or step is added or reordered. The tail loop is dead in production (verifier
   caps; builder asserts). **Verdict: no model change needed.**
   ```

3. Write **voluntary** entries, same text, "Pins fired: none (unpinned shared walkers
   HeapChildWalk / NurseryChildWalk / OldGenSpace scanChildren / NurserySpace scanObject)", in
   `test/tla/M1-snapshot-mark/AUDIT.md` and `test/tla/M5-tenuring/AUDIT.md`.
4. `test/scripts/check-tla-manifest.sh . --update`.
5. `cmake --build build --target tla-canary 2>&1 | tee /tmp/test_output_tla.txt` must pass strict
   (`-DECO_TLA_CANARY_STRICT=ON` in the gate tree).

**Tests:**
- the pins `wide B8b` and `wide B7: boxed captures 32..39 of a 40-slot closure survive minor GCs`
  turn green in the validate tree;
- `HeapSnapshot`-based property tests (e.g. `--filter preserve`) stay green.

**Rollback:** revert the commit and the AUDIT entries, then `--update` again.

---

## 1b. Codegen and dialect

### Step 1b.1: codegen helpers (§S.3, Phase 1 form)

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`. Add to `namespace layout` (after
`ClosureBaseSize`, `:402`):

```cpp
constexpr unsigned CustomHdrSlots = 24, RecordHdrSlots = 32, ClosureHdrSlots = 25; // P2: 20
```

Add as free functions in the same header (inline; needs `mlir/IR/Types.h`, `llvm/ADT/SmallVector.h`):

```cpp
inline uint8_t slotKindOf(mlir::Type t) {
    if (t.isInteger(64)) return 1;
    if (t.isF64()) return 2;
    if (t.isInteger(16)) return 3;
    return 0;
}
// LLVM-level twin (types after conversion): ptr<1> -> 0.
inline uint64_t kindsWord(llvm::ArrayRef<uint8_t> kinds, size_t first, size_t count) {
    assert(count <= 32);
    uint64_t w = 0;
    for (size_t i = 0; i < count && first + i < kinds.size(); ++i)
        w |= uint64_t(kinds[first + i] & 3) << (2 * i);
    return w;
}
struct PackedKinds { uint64_t hdrBits; llvm::SmallVector<uint64_t, 2> ext; };
inline PackedKinds packKinds(llvm::ArrayRef<uint8_t> kinds, unsigned hdrSlots) {
    PackedKinds p;
    p.hdrBits = kindsWord(kinds, 0, std::min<size_t>(hdrSlots, kinds.size()));
    for (size_t s = hdrSlots; s < kinds.size(); s += 32)
        p.ext.push_back(kindsWord(kinds, s, std::min<size_t>(32, kinds.size() - s)));
    return p;
}
// Phase 1 layout (Heap.hpp Closure): n_values:6 | max_values:6 | result_kind:2 | unboxed:50.
inline uint64_t packClosureWord(uint32_t nValues, uint32_t maxValues, uint8_t resultKind,
                                uint64_t hdrBits) {
    assert(nValues < 64 && maxValues < 64 && resultKind < 4 && (hdrBits >> 50) == 0);
    return uint64_t(nValues) | (uint64_t(maxValues) << 6) |
           (uint64_t(resultKind & 3) << 12) | (hdrBits << 14);
}
```

**In `EcoToLLVMClosures.cpp`:**
- Replace `deriveAllParamKindsBitmap` (`:1453-1487`, forward decl `:32`) with:

  ```cpp
  static SmallVector<uint8_t> deriveAllParamKinds(const EcoRuntime &runtime, StringRef funcSymbol, int64_t arity);
  //   body = the existing lookup chain (:1455-1478), then:
  //   for (i < lim) out.push_back(mlirTypeToParamKind(paramTypes[i]) & 3);
  static uint64_t deriveAllParamKindsBitmap(const EcoRuntime &rt, StringRef sym, int64_t arity) {
      return packKinds(deriveAllParamKinds(rt, sym, arity), layout::ClosureHdrSlots).hdrBits;
  }
  ```

- **Effect:** no UB (`kindsWord` caps each word at 32 slots). Kinds of params ≥ 25 are still
  dropped, exactly as the 50-bit masks did before (B5 stays until Phase 2). The masks at `:784` and
  `:885` become redundant, but keep `packClosureWord`'s assert as the guard.
- **`EvaluatorDesc.kinds`** (`:3290-3291` call site): the descriptor's `kinds` documents params
  0..31. Pass `kindsWord(deriveAllParamKinds(…), 0, std::min<int64_t>(arity, 32))` instead of the
  hdr-only bitmap. Nothing reads it at run time, so outputs only change for arity > 25 targets'
  descriptor constants.

**Invariants:** CGEN_049 / REP_CLOSURE_001 (25 typed slots). The packed word is bit-identical for
every closure of arity ≤ 25.

### Step 1b.2: papCreate packers use `packClosureWord`

- `EcoToLLVMClosures.cpp:781-784` (interned) becomes
  `packClosureWord(0, arity, closureResultKind, bitmap0)`.
- `:881-885` (normal) becomes
  `packClosureWord(numCaptured, arity, closureResultKind, unboxedBitmap)`.
- Both inputs are ≤ 50 bits: `deriveAllParamKindsBitmap` now returns hdr bits; `op.getUnboxedBitmap()`
  is verified < 2^50 (`EcoOps.cpp:548`).

**Expected:** byte-identical LLVM IR for every existing fixture. Check with the existing fixtures,
e.g. `pap_unboxed_captured.mlir`.

### Step 1b.3: B13, `eco.make.closure` packing (user decision 2)

**File:** `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`, `MakeClosure` lowering (`:780-890`).

- Before (`:856-862`): `packed = numCaptured | arity<<6 | unboxedBitmap<<12`. This puts slot 0's
  kind in `result_kind`, shifts every kind one slot down, and writes no `result_kind`.
- After:

  ```cpp
  SmallVector<uint8_t> capKinds;
  for (Type t : captures) capKinds.push_back(slotKindOf(t));
  uint8_t rk = 0;
  if (auto a = op->getAttrOfType<IntegerAttr>("_result_kind")) rk = uint8_t(a.getInt() & 3);
  uint64_t packed = packClosureWord(uint32_t(numCaptured), uint32_t(arity), rk,
                                    packKinds(capKinds, layout::ClosureHdrSlots).hdrBits);
  ```

- **Kinds:** capture kinds only. make.closure uses the bare-function descriptor
  (`emitEvalDescAddrForFuncSymbol`, `:805`), which is the legacy args-array convention, as
  papCreate's untyped path (`op.getUnboxedBitmap()`, `EcoToLLVMClosures.cpp:864`).
- **Result kind:** an optional discardable `_result_kind : i8`, default 0, the papCreate
  convention. `Ops.td:3320-3352` needs no change; `attr-dict` carries discardable attributes.
- Delete `kindBitmapFor`'s use here (`:797`). `kindBitmapFor` itself (`:77-87`) gets
  `assert(elements.size() <= 32)` and its body becomes `return kindsWord(kinds, 0, n)`. Its other
  callers (to_heap record/custom fallbacks `:231`, `:310`, `:378`, `:461`) build ≤ 32 / ≤ 24
  element containers today.
- **Verifier** `MakeClosureOp::verify` (`runtime/src/codegen/EcoOps.cpp:1449-1452`): `> 26`
  becomes `> 25`, with message `"exceeds 25-slot limit under 2-bit kind encoding"` (B4 part).

**Pin:** `test/codegen/make_closure_packed_word.mlir` (Phase 0, text in `-phase-0.md` Appendix
P0-C) goes red → green: `@make_closure_packed` emits `llvm.mlir.constant(16578 : i64)`
(`2 | 3<<6 | 1<<14`; today `4290`).

**Extend the fixture in this step** with a `result_kind` case, appended inside its module:

```mlir
  func.func @make_closure_rk1(%cap0: i64, %cap1: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%cap0, %cap1)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64, _result_kind = 1 : i8}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }
// rk=1: 16578 | 1<<12 = 20674
// CHECK-LABEL: llvm.func @make_closure_rk1
// CHECK: llvm.mlir.constant(20674 : i64)
```

Phase 2 rewrites both CHECK constants for the new packed word: `16578` → `16783362`
(`2 | 3<<11 | 1<<24`) and `20674` → `20977666` (`… | 1<<22`).

The existing fixtures `value_make_closure.mlir` and `value_closure_env.mlir` must stay green. They
don't CHECK the packed constant (`value_make_closure.mlir:21-31`).

**Rollback:** revert. The fixture returns to red.

### Step 1b.4: B14, reject `i1` construct operands

**File:** `runtime/src/codegen/EcoOps.cpp`. In `CustomConstructOp::verify`, the kind-0 case at
`:403-412`, delete `&& !fieldType.isInteger(1)` at `:409`. Do the same in `RecordConstructOp::verify`
at `:481`. Add an explicit message before the switch in both:

```cpp
if (fieldType.isInteger(1))
  return emitOpError("field ") << i << " has i1 type: Bool must be boxed to !eco.value before construction";
```

The text must contain `has i1 type`: Phase 0's fixtures CHECK for it.

Update the record verifier's stale comment at `:474-477`.

**Producers checked:**
- The front end never emits an `i1` construct operand: reviewer C12 counted 0 of 953 generated
  `.mlir` files.
- No `test/codegen` fixture has one: `grep -E "construct\.(custom|record).*i1[,)]"` finds only SSA
  names like `%i1`.
- `emitFreshFieldStore` / `widenFieldToI64` keep their `i1` arms. They are now unreachable for
  construct ops; tuple/list paths are out of scope.

**Pins:** `test/codegen/construct_custom_i1_operand_rejected.mlir` and
`construct_record_i1_operand_rejected.mlir` (Phase 0, Appendix P0-C; `RUN: not %ecoc %s -emit=mlir
2>&1 | %FileCheck %s`, `CHECK: has i1 type`) go red → green.

**Rollback:** revert.

### Step 1b.5: B7, codegen packers and loops that shift by `2*i`

| # | Site | Bound today | Change |
|---|---|---|---|
| 1 | `EcoOps.cpp:573-577` (`PapCreateOp::verify` per-slot loop) | loops `captured.size()`, including GC-root operands | B22: step 1b.8 |
| 2 | `EcoOps.cpp:657` | `realNewargsCount ≤ 25` (checked at `:636`) | none |
| 3 | `EcoOps.cpp:777`, `:833-834` (group) | slot / `j < cc ≤ 25` | none; add `assert(slot < 25)` |
| 4 | `EcoToLLVMClosures.cpp:1485` | arity ≤ 63 | done in 1b.1 |
| 5 | `EcoToLLVMClosures.cpp:1808-1830` (sat filter in `getOrCreateEvalDesc`) | `shift = 2*(stageArity-n)` can reach 124 | wrap the `for (unsigned n = 1; n < satCount; ++n)` loop in `if (stageArity <= 16)`, the same bound `getOrCreateSatEntry` enforces at `:1683` |
| 6 | `EcoToLLVMClosures.cpp:1925-1933` (sat site `kc`) | n newargs unbounded | at the top of that function: `if (n > 16) return Value();` (no entry exists for n > 16) |
| 7 | `EcoToLLVMClosures.cpp:1719` | `captureCount < stageArity ≤ 16` | none; add `assert(stageArity <= 16)` |
| 8 | `EcoToLLVMClosures.cpp:3188-3194` | `n ≤ 8` (`:3188`) | none |
| 9 | `EcoToLLVMClosures.cpp:2954-2958` (papExtend `hptrMask` from attribute) | newargs ≤ 25 | compute from operand types: `slotKindOf(op.getNewargs()[i].getType()) == 0`. Same values; no attribute dependency (prepares Phase 2) |
| 10 | `runtime/src/codegen/EcoBackend.cpp:1829` | N ≤ 16 (sat entries) | add `assert(N <= 16)` |
| 11 | `EcoToLLVMValueAgg.cpp:84` (`kindBitmapFor`) | ≤ 32 (see 1b.3) | assert plus `kindsWord` |
| 12 | `EcoPAPSimplify.cpp:354` | **unbounded** (B16) | step 1b.6 |
| 13 | `EcoPAPSimplify.cpp:520` | ≤ 25 (`:506`) | none |

**Test:** fixtures stay green.

### Step 1b.6: B16, PAPSimplify chain fusion cap

**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`, `FusePapExtendChainPattern` (`:289`).
After `fusedNewargs` is built (`:341-343`), insert:

```cpp
        // Verifier limit (PapExtendOp::verify: newargs <= 25 under the 50-bit bitmap).
        // Release builds do not re-verify after passes, so the pattern must not exceed it.
        if (fusedNewargs.size() > 25)
            return failure();
```

This mirrors `FuseCreateIntoExtendPattern`'s `fusedCaptured > 25` (`:506`). Phase 2 raises both to
2047.

**Pin:** `test/codegen/pap_simplify_fusion_slot_cap.mlir` (Phase 0, Appendix P0-C: two typed
extends of 15 Int args each on an arity-32 papCreate). Today the chain fuses into one 30-newarg
extend that fails verification (`newargs_unboxed_bitmap exceeds 50-bit capacity`). After this step
fusion declines and both extends survive (`CHECK: eco.papExtend` twice, `CHECK-NOT: error`).
Phase 2 rewrites its CHECKs to one fused 30-newarg extend when the cap becomes 2047.

**Rollback:** revert.

### Step 1b.7: B15, papCreateGroup root range over 64 slots

**File:** `EcoToLLVMClosures.cpp`, papCreateGroup lowering.
- **Mask:** `:1130-1150`. **Push:** `:1157-1175`. The runtime asserts `count <= 64`
  (`RuntimeExports.cpp:4317`, debug), and in release the mask loses slots ≥ 64.
- Replace the single `hpointerMask` with a vector of `ceil(total/64)` masks built from the capture
  **operand types**: `slotKindOf(operand type) == 0`, which equals today's per-sibling attribute
  kinds by the verifier.
- Emit one `eco_gc_push_stack_range` call per chunk. Base = `GEP capturesArr[64*c]`, count =
  `min(64, total - 64*c)`, mask = chunk mask.
- The restore at the end (`savedRangeDepth`) is unchanged; one restore pops all chunks.
- **Runtime side:** `eco_alloc_closure_group_slow` (`RuntimeExports.cpp:1734-1800`) needs no change
  in Phase 1.

**Pin:** E2E `elm/WideClosureGroupTest.elm` (Phase 0; `group: 849`) goes red → green. Today it
aborts in `eco_gc_push_stack_range` (`count <= 64`).

**Extra fixture** (checks the chunking directly): `test/codegen/pap_group_root_chunks.mlir`.
- 3 siblings × 25 boxed captures (total 75), `-emit=mlir-llvm`.
- `CHECK-COUNT-2: llvm.call @eco_gc_push_stack_range`, with the counts `64` and `11` visible as
  `llvm.mlir.constant(64 : i64)` / `(11 : i64)` before the calls.
- Written by hand (no papCreateGroup fixture exists today):
  - three `$clo` functions as `llvm.func @sN$clo(%a: !llvm.ptr) -> !llvm.ptr`;
  - three `$cap` functions `func.func @sN$cap(25 × !eco.value, !eco.value) -> !eco.value`, with
    `arities = [26,26,26]`;
  - `num_captured = [25,25,25]`, `capture_counts = [25,25,25]`, `cross_edges = []`,
    `unboxed_bitmaps = [0,0,0]`, `functions` / `fast_evaluators` as above.

  Follow `PapCreateGroupOp` (`Ops.td:1397-1460`) and its verifier (`EcoOps.cpp:790-860`). If the
  verifier rejects a zero-cross-edge group, add one cross edge `[0, 1, 24]` and set sibling 1's
  `capture_counts` to 24.

**Rollback:** revert.

### Step 1b.8: B22, `PapCreateOp::verify` loops over GC-root operands

**File:** `runtime/src/codegen/EcoOps.cpp`, `PapCreateOp::verify`.
- The per-slot kind loop (`:573-577`) runs `for (size_t i = 0; i < captured.size(); ++i)` over
  `getCaptured()`, which includes the GC-root operands appended by `EcoGCPrepare`. With 25 captures
  plus 7 or more roots the shift `2*i` reaches 64 (UB) and can report a spurious "has kind=Int" on a
  root.
- The REP_CLOSURE_001 Bool loop (`:608-614`) iterates the same range.

Change both loops to the real captures:

```cpp
  auto captured = getCaptured();
  const size_t realCaptured = static_cast<size_t>(numCaptured);   // num_captured attr, read above
  for (size_t i = 0; i < realCaptured; ++i) {                      // was captured.size()
    ...
  }
  ...
  for (size_t i = 0; i < realCaptured; ++i) {                      // Bool check, was captured.size()
    ...
  }
```

`numCaptured` is the `num_captured` attribute already read at the top of the verifier, which is
≤ 25 by `:553`. Roots are always `!eco.value`, so the Bool check loses nothing.

**Test:** fixture `test/codegen/pap_create_verify_ignores_roots.mlir`:
- a papCreate of 25 `i64` captures, `unboxed_bitmap` = all-Int over 25 slots, followed by 8 extra
  `!eco.value` operands and `eco.gc_roots_count = 8 : i64`;
- `RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s`, `CHECK: eco.papCreate`, `CHECK-NOT: error`.
- Before the fix it is red only by chance (UB). After the fix the verifier never reads past slot 24.

**Rollback:** revert.

---

## 1a. Compiler (Elm) fixes

### Step 1a.1: B1 `generateCtor`, plus B9 AbiCloning guard

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`, `generateCtor` (`:1760`), non-nullary
branch.
- `argTypes` (`:1855-1866`) becomes the ABI type of every field.
- Add `slotTypes` (the stored type).
- Box where they differ. Keep `argNames`; replace `argTypes` and add the fold:

  ```elm
  -- REP_ABI_001: every parameter crosses the call at its ABI type (an Int is i64 even
  -- where the layout stores the field boxed); slotTypes is the type each field is stored at.
  argTypes = List.map (\field -> Types.monoTypeToAbi field.monoType) ctorLayout.fields
  slotTypes = List.map (\field -> if field.isUnboxed then Types.monoTypeToAbi field.monoType else Types.ecoValue) ctorLayout.fields

  -- box each argument whose ABI type is a primitive but whose slot is boxed
  ( boxOpsRev, slotPairsRev, ctxBoxed ) =
      List.foldl
          (\( ( argName, argTy ), slotTy ) ( opsAcc, pairsAcc, ctxAcc ) ->
              if argTy /= slotTy && Types.isEcoValueType slotTy then
                  let
                      ( boxedVar, ctxB ) = Ctx.freshVar ctxAcc
                      ( ctxB2, boxOp ) =
                          Ops.mlirOp ctxB "eco.box"
                              |> Ops.opBuilder.withOperands [ argName ]
                              |> Ops.opBuilder.withResults [ ( boxedVar, Types.ecoValue ) ]
                              |> Ops.opBuilder.withAttrs (Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr argTy ]))
                              |> Ops.opBuilder.build
                  in
                  ( boxOp :: opsAcc, ( boxedVar, Types.ecoValue ) :: pairsAcc, ctxB2 )
              else
                  ( opsAcc, ( argName, argTy ) :: pairsAcc, ctxAcc )
          )
          ( [], [], ctxFreshScope )
          (List.map2 Tuple.pair argPairs slotTypes)
  ```

  Then:
  - insert the fold after `ctxFreshScope` (`:1871-1874`);
  - `Ctx.freshVar ctxFreshScope` (`:1877`) becomes `Ctx.freshVar ctxBoxed`;
  - `Ops.ecoConstructCustom … argPairs constructorName` (`:1880`) takes `(List.reverse slotPairsRev)`;
  - `Ops.mkRegion argPairs [ constructOp ] returnOp` (`:1887`) becomes
    `Ops.mkRegion argPairs (List.reverse boxOpsRev ++ [ constructOp ]) returnOp`.
- The function signature (`Ops.funcFunc ctx2 funcName argPairs …`) keeps `argPairs`, now ABI-typed
  (REP_ABI_001).
- Recommended: express the fold with the same coercion as `Expr.prepareCtorSlots`
  (`Expr.elm:8557-8600`) by extracting a shared `coerceToSlot : Ctx.Context -> (String, MlirType) ->
  MlirType -> (List MlirOp, (String, MlirType), Ctx.Context)` into `Expr.elm` or `Intrinsics.elm`.
  If the module dependency (Functions → Expr) already exists, reuse it; otherwise keep the inline
  fold.

**B9, same commit:** `compiler/src/Compiler/GlobalOpt/AbiCloning.elm`.
- Delete the guard `if List.length shape.fieldTypes > ctorTypedSlotCap then Nothing else`
  (`:2988-2991`) and its comment `:2981-2987`, leaving
  `Just ( shape.fieldTypes, Tuple.second (Mono.decomposeFunctionType ty) )`.
- Delete `ctorTypedSlotCap` (`:2998-3004`).
- In the `specFunctionRow` docstring, `:2954` "a constructor with at most 24 fields" becomes "a
  constructor", and `:2955` drops "or a wider constructor".
- **Rationale:** the fast call passes every Int/Float/Char unboxed, and after B1 the ctor function
  takes them unboxed (REP_ABI_001).

**Pins:**
- elm-test `CallAbiConsistencyTest` "constructor with a field past the unboxed slot cap is called
  with matching operand types" (`CallAbiConsistencyTest.elm:77`) goes red → green.
- B9: Phase 0's rewrite of test 9 in `TestLogic/Monomorphize/AbiCloningPapFastPassTest.elm`
  ("9. §11.1 a constructor wider than 24 fields STAMPS …", `Expect.equal 1 st.stampedPapGlobal`,
  `Expect.equal 0 st.declinedNoInstance`) goes red → green. If the test pipeline cannot observe the
  stamp, the fallback is a decline counter `ctorRowDeclines : Int` in `AbiCloningStats`, asserted 0
  for the `CallAbiConsistencyTest` wide program.

**Rollback:** revert.

### Step 1a.2: B2, Patterns CustomContainer boxed branch

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm`, `generateMonoIndexOnHeap`
CustomContainer arm, boxed branch `:774-807`.
- `:786-788`: `if targetType == I1 then` becomes
  `if targetType == I1 || Types.isUnboxable targetType then`.
- `:797`: `Intrinsics.unboxToType ctxP valVar I1` becomes
  `Intrinsics.unboxToType ctxP valVar targetType`.
- **No** `aggOperand == Nothing` guard (review C10). `projCustom` (`:567-572`) already
  picks heap or aggregate projection, and promoted aggregates store boxed slots as `!eco.value`
  (`Expr.prepareCtorSlots`, `Expr.elm:8566-8572`).
- `Intrinsics.unboxToType` already handles `I64`/`F64`/`I16` targets: `Expr.generateRecordAccess`
  uses it that way (`Expr.elm:7312`).

**Pin:** elm-test `DestructorTypeProjectionTest` "Int field past the unboxed slot cap is projected
boxed, then unboxed" (`:157`) goes red → green.

**Rollback:** revert.

### Step 1a.3: B3, `generateMonoFieldOnHeap` symmetric, crash on missing field

**File:** `Patterns.elm:874-910` (`generateMonoFieldOnHeap`). Replace the body after `layout` with:

```elm
        fieldInfo =
            case findFieldInfoByName fieldName layout.fields of
                Just fi ->
                    fi

                Nothing ->
                    Utils.Crash.crash ("generateMonoFieldOnHeap: field " ++ fieldName ++ " is not in the record layout")

        storedType =
            if fieldInfo.isUnboxed then
                Types.monoTypeToAbi fieldInfo.monoType

            else
                Types.ecoValue
    in
    if storedType == targetType then
        let
            ( ctx3, projectOp ) =
                Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
        in
        ( projectOp :: revAcc1, resultVar, ctx3 )

    else if fieldInfo.isUnboxed && Types.isEcoValueType targetType then
        -- unboxed slot, boxed target: project the primitive, then box (mirrors the Custom arm :758-773)
        let
            ( primVar, ctxA ) =
                Ctx.freshVar ctx2

            ( ctxB, projectOp ) =
                Ops.ecoProjectRecord ctxA primVar fieldInfo.index storedType subVar

            ( ctxC, boxOp ) =
                boxPrimitive ctxB resultVar primVar storedType
        in
        ( boxOp :: projectOp :: revAcc1, resultVar, ctxC )

    else if not fieldInfo.isUnboxed && (targetType == I1 || Types.isUnboxable targetType) then
        -- boxed slot, primitive target (E3; and I1 for Bool, REP_CONSTANT_003): project !eco.value, unbox
        let
            ( valVar, ctxA ) =
                Ctx.freshVar ctx2

            ( ctxB, projectOp ) =
                Ops.ecoProjectRecord ctxA valVar fieldInfo.index Types.ecoValue subVar

            ( unboxOps, unboxedVar, ctxC ) =
                Intrinsics.unboxToType ctxB valVar targetType
        in
        ( List.foldl (::) (projectOp :: revAcc1) unboxOps, unboxedVar, ctxC )

    else
        let
            ( ctx3, projectOp ) =
                Ops.ecoProjectRecord ctx2 resultVar fieldInfo.index targetType subVar
        in
        ( projectOp :: revAcc1, resultVar, ctx3 )
```

- `boxPrimitive` is at `Patterns.elm:1224`. `Utils.Crash` is imported (`:32`).
- `revAcc` is a **reversed** op list; check that the function's callers expect this shape. The
  current body returns `projectOp :: revAcc1`.
- **The I1 arm is needed.** A Bool record field is stored boxed (`canUnbox` excludes Bool). Today a
  pattern that scrutinises it as `I1` projects `i1` straight from the slot, reading the HPointer's
  low bit: the bug the Custom arm documents at `:776-785`.

**Also:** `compiler/src/Compiler/Generate/MLIR/Expr.elm:514-516` (MonoRecordAccess):
`|> Maybe.withDefault { name = fieldName, index = 0, monoType = fieldType, isUnboxed = False }`
becomes a `case … of Just fi -> fi; Nothing -> crash ("record access: field " ++ fieldName ++ " not in layout")`.
`crash` is imported at `Expr.elm:77`.

**Pins:**
- elm-test `DestructorTypeProjectionTest` "record pattern of a field past the record slot cap is
  projected boxed, then unboxed" (Phase 0, Step 0.6b-2) goes red → green. Its checker
  `checkRecordFieldProjection` (`TestLogic/Generate/CodeGen/DestructorTypeProjection.elm`) derives
  `isUnboxed` from `Types.computeRecordLayout`, not from a hard-coded index. Its docstring states
  that Phase 3C (record cap removal) re-checks the rule against the new layout; no edit is expected
  because the rule follows the layout.
- **E2E** `test/elm/src/WideRecordPatternTest.elm` (Phase 0 pin): CHECK `pattern: 1028025`, plus the
  access and update lines. Red today (prints `1120986464801025`); green after this step.

**Rollback:** revert.

### Step 1a.4: B21, the compiler driver exits 0 after an internal error

A JS exception inside the eco-io handler is logged and answered with HTTP 500, but the process
exits 0. A truncated `.mlir` then reaches the backend and fails later with a misleading message
(Phase 0 saw this for the large pins before Step 0.5).

**Files** (`compiler/bin/`):
- `index.js:22-25` (Stage 1 driver, used by the E2E harness): the `catch (e)` of the `eco-io` route.
- `eco-boot-runner.js:83-86`: the same `catch`; and `exitWith` at `:233-236`
  (`process.exit(request.body)`).
- `eco-io-handler.js:438-441`: `case "Process.exit": process.exit(args.code)`, the exit path Stage 1
  takes.

**Change:**

```js
// eco-io-handler.js (module scope)
let handlerFailed = false;
function markHandlerFailed() { handlerFailed = true; process.exitCode = 1; }
// in case "Process.exit":
process.exit(handlerFailed && args.code === 0 ? 1 : args.code);
// exports:
module.exports = { handleEcoIO, handleEcoIOBinary, markHandlerFailed };

// index.js and eco-boot-runner.js, in each eco-io catch:
} catch (e) {
  console.error("eco-io handler error:", e);
  markHandlerFailed();
  request.respond(500, null, JSON.stringify({ error: e.message }));
}

// eco-boot-runner.js exitWith:
const code = Number(request.body);
process.exit(code === 0 && handlerFailedFlag() ? 1 : code);
```

`eco-boot-runner.js` imports `markHandlerFailed` with the other names from `./eco-io-handler`;
expose `handlerFailedFlag = () => handlerFailed` from the same module for its `exitWith`.

**No pin** (the failure needs an internal error, which is not portable to provoke).
**Check by hand once:** temporarily remove the Phase 0 Step 0.5 stack flags, compile
`test/elm/src/WideRecordDecoder300Test.elm` with `node compiler/bin/index.js make …`, and confirm
`echo $?` is non-zero. Restore the flags.

**Invariant:** none; tooling only.

**Rollback:** revert the three files.

---

## 1e. Comments (B10, no pins)

| Site | New text |
|---|---|
| `runtime/src/allocator/Heap.hpp:551` | `u64 unboxed : 48; // 2-bit kinds for fields 0..23 (24 slots); fields 24+ per HEAP_019` |
| `Heap.hpp:557` | `u64 unboxed; // 2-bit kinds for fields 0..31 (32 slots); fields 32+ per HEAP_019` |
| `Heap.hpp:628-630` | `// 2-bit kinds for slots 0..24 (25 slots); slots 25+ read boxed until the Phase 2 widening` |
| `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp:856-858` | rewritten by 1b.3 |
| `runtime/src/allocator/RuntimeExports.cpp:1342-1349` (`eco_intern_closure0`) | "…the closure scans iterate `n_values` slots (0 here); the memset keeps the body defined for debug walkers and permanent-space copies" |
| `test/elm/src/WideCtorField24Test.elm` header (`:16-19`) | replace only the false claim "although the heap `Custom` object and `computeCtorLayout` both allow boxed fields past 24" with "the GC walkers ignored slots past 24 until plans/wide-object-tail-kind-words Phase 1". The sentence saying the verifier rejects more than 24 fields stays true until Phase 3D, which rewrites it |

`compiler/tests/TestLogic/Generate/CodeGen/UnboxedBitmap.elm:37` ("52-bit") stays true until the
front end stops packing 26 slots; Phase 2 changes it.

---

## 6. Invariants touched in Phase 1

No row changes text in Phase 1. Every step must preserve:
- **HEAP_019 / REP_HEAP_002:** kinds are read only from the container.
- **HEAP_SNAPSHOT_001:** no new post-publication write. `closureCapture` writes before publication,
  as before.
- **HEAP_031 / HEAP_034:** construct stores are unchanged.
- **REP_ABI_001:** B1 makes `generateCtor` comply.
- **CGEN_005 / REP_BOUNDARY_001:** B2/B3 make projections match the slot kind.
- **CGEN_049 / REP_CLOSURE_001:** 25 typed slots, now agreed by make.closure too; the papCreate
  verifier checks only real captures (B22).
- **GC_MODEL_001:** §1d.4.

---

## 7. Phase 1 gate

Run in this order. Each command runs **once**, tee'd, with `ulimit -c 0` (overview §6.1); commands
are overview §S.7.

1. `cmake --build build 2>&1 | tee /tmp/p1_build.txt`. The tla-canary runs in ALL; it must report
   no unaudited pin (after §1d.4).
2. **elm-tests:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`.
   - **Expected failures: exactly 8** (Phase 0 had 12):
     - `MonoCaseBranchResultTypeTest` × 2 (GOPT_003, unrelated);
     - `UnboxedBitmapTest` "closure kind attributes stay within the backend's slot limits" (green
       in Phase 2);
     - `LimitErrorsTest`: the five non-boundary limit-diagnostic cases (green in Phase 2, step 2.8.6).
   - Green now: the two existing wide pins (B1, B2), the B3 record-pattern pin, AbiCloning test 9
     (B9).
   - Check: `grep -E "^(✗|FAIL)|Failed" /tmp/test_output.txt`.
3. **Cache wipe** (overview §6.3), then `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`.
   **Expected failures: exactly these** (reasons are Phase 0's recorded substrings):

   | Name | Reason substring | Green at |
   |---|---|---|
   | `elm/WideCtorField24Test.elm` | `exceeds Custom's 24-slot limit` | P3D |
   | `elm/WideClosurePap27bTest.elm` | CHECK `res: [23702, 40502]` missing | P2 |
   | `elm/WideClosureSat26Test.elm` | `newargs_unboxed_bitmap exceeds 50-bit capacity` | P2 |
   | `elm/WideClosureBoxed27Test.elm` | `newargs count (27) exceeds 25-slot limit` | P2 |
   | `elm/WideClosureCapture27Test.elm` | `num_captured (27) exceeds 25-slot limit` | P2 |
   | `elm/WideRecordDecoder26Test.elm` | CHECK `f0025: Just 1025` missing | P2 |
   | `elm/WideRecordDecoder30Test.elm` | CHECK `f0025: Just 25.5` missing | P2 |
   | `elm/WideClosureArity63Test.elm` | crash or CHECK `res: [72873]` missing | P2 |
   | `elm/WideClosureArity300Test.elm` | `arity (300) exceeds 6-bit max_values limit (63)` | P2 |
   | `elm/WideClosureArity2047Test.elm` | `arity (2047) exceeds 6-bit max_values limit (63)` | P2 |
   | `eco-kernel/WideClosureGcTest.elm` | CHECK `WideClosureGcTest value: 8956201` missing (in Phase 0 a fused 27-newarg extend failed the verifier; B16's fusion cap removes that) | P2 |
   | `elm/WideRecordDecoder70Test.elm` | `arity (70) exceeds 6-bit max_values limit (63)` | P3D |
   | `elm/WideRecordDecoder300Test.elm` | `arity (300) exceeds 6-bit max_values limit (63)` | P3D |
   | `elm/WideRecord33Test.elm`, `…40…`, `…600…`, `…1100…` | `field_count (N) exceeds Record's 32-slot GC scan limit` | P3D |
   | `elm/WideCtorMixedTest.elm`, `elm/WideCtor1100Test.elm` | `exceeds Custom's 24-slot limit` | P3D |
   | `eco-kernel/WideHeapGcTest.elm` | `field_count (40) exceeds Record's 32-slot GC scan limit` | P3D |

   **Must pass (green in this phase):**
   - E2E `elm/WideRecordPatternTest.elm` (B3) and `elm/WideClosureGroupTest.elm` (B15);
   - codegen fixtures `make_closure_packed_word.mlir` (both functions),
     `construct_custom_i1_operand_rejected.mlir`, `construct_record_i1_operand_rejected.mlir`,
     `pap_simplify_fusion_slot_cap.mlir`, plus the extra fixtures `pap_group_root_chunks.mlir` and
     `pap_create_verify_ignores_roots.mlir`;
   - unit pins `wide B6 …`, `wide B7: pointerMask…`, `wide B7: equality…`, `wide B8 …`,
     `wide B11 …`, every `WideKindsTest` case, and the changed `HeapHelpersTest` cases.
4. **Validate tree** (overview §S.7): `--filter` is a plain substring match on test names (not a
   regex, not suite names), so run `/work/build-validate/test/test --filter <p>` once per pattern
   `wide`, `closureCapture`, `GCPressure`, `generic apply`, each tee'd.
   All pass, including `wide B7: boxed captures 32..39 …` and `wide B8b …`, which are only
   deterministic here. `ECO_PERSITE_ZERO` is unset, so the 0xD8 poison is active.
5. `cmake --build build --target register-guards 2>&1 | tee /tmp/test_output_rg.txt`: the Phase 0
   baseline result.
6. TSan arms: as `register-guards` runs them; no new report.
7. `tla-canary` strict: pass.
8. **Bootstrap:** `bootstrap` + `eco-verify`. B==C holds. Expected MLIR change against the Phase 0
   bootstrap: none, unless the Phase 0 census found ctors over 24 fields / records with more than 26
   primitives, or make.closure, in the compiler (all 0 expected).
9. **Perf triple** (`benchmarks/fe-opt-loop.md` §1, overview §7): GC counters **bit-identical** to the
   Phase 0 baseline (no layout change, no allocation change). Wall within the triple's spread. Over
   budget still ships (correctness), with the cost recorded.

---

### 7.1 Gate result (recorded 2026-10-05)

- **Build + strict tla-canary:** green (the canary fired only on `NP.scanEntryP`, new prefix
  `e06ed77f04e5`; M3 AUDIT entry plus voluntary M1/M5 entries; manifest updated).
- **LSS_022 kernel licenses** (not foreseen by this plan): the 1c edits to `Utils.cpp` and
  `ListExports.cpp` re-hashed 19 licensed rows. Re-audited (kind reads only; no application,
  retention, fabrication or type change), `audited:` dates advanced with a re-audit note
  (17 `KernelSetFacts` rows, 2 `KernelIntrinsics` rows), manifest `--update`d.
- **elm-tests:** 14,063 pass / 8 fail, exactly the 8 listed in step 2.
- **full** (after the cache wipe): 2,082 run, 2,062 pass, 20 fail, exactly the 20 listed in step 3,
  each with its listed reason. `WideClosureArity63Test` is a CHECK miss (not a crash) and
  `WideClosureGcTest` a CHECK miss (B16's fusion cap removed Phase 0's fused 27-newarg extend).
  Green: `WideRecordPatternTest`, `WideClosureGroupTest`, all six fixtures, every `wide B…` and
  `WideKindsTest` case, the changed `HeapHelpersTest` case.
- **Fixture not foreseen:** `test/codegen/allocate_ctor_max_size.mlir` allocated a 50-field
  Custom through `eco.allocate_ctor` (uninitialised fields) and aborted on 1c.7's
  `assertNarrowContainer`, correctly. Its stress case was lowered to 24 fields (Phase 3A deletes
  `AllocateCtorOp`).
- **Validate tree** (one run per substring): `wide` 18/18, `closureCapture` 2/2, `GCPressure` 1/1,
  `generic apply` 4/4.
- **register-guards:** green. **Bootstrap:** Stage 4b and Stage 8c fixed points hold; `eco-verify`
  rc 0.
- **Perf triple** (`eco-optP1`, sha256 `4044c08c2ae82ef3…`, built like `eco-optP0`): deterministic +
  fixed point; wall 67.62 / 67.12 / 67.86 s (median 67.62, Phase 0 68.12); minor 1335, major 7,
  promoted 6384 MiB, objects ≈ 304,480,819, GC time 2.88–2.96 s.
  - The counters are **not** bit-identical to Phase 0, but the workload changed: the triple
    compiles the compiler's own source, which Phase 1 edited (out.mlir +8.6 KB). Cross-check on
    the SAME source: the Phase 0 binary (`eco-optP0`) compiling the Phase 1 source gives
    byte-identical output to `eco-optP1` and counters minor 1334, objects ≈ 304,452,955, promoted
    6384 MiB, wall median 68.85 s. The binary-only difference is +27,864 objects (+0.009 %) and one
    minor GC, from the compiler's own new code (most likely B1's `generateCtor` building ABI and
    slot type lists per constructor). No wall regression. Recorded; ships (correctness).
- **Gate command fix:** step 4's `--filter "a|b|c"` matched nothing (substring filter); the step now
  says to run one filter per pattern.

## 8. Phase 1 checklist

- [x] 1c.1 helpers + `WideKindsTest.cpp` registered; `fieldKind` / `bitmapSetKind` /
      `pointerMaskFromKindBitmap` asserts.
- [x] 1c.2 equality and printers use the accessors (6 sites); `wide B7: equality…` green.
- [x] 1c.3 `closureCapture` abort; `wide B6` green; `HeapHelpersTest.cpp:1551` removed, boxed-past-25
      test added; kernel census checked.
- [x] 1c.4 apply paths: 10 rows (`ClosureKinds` snapshots, `pushRootsByKinds`, release checks).
- [x] 1c.5 `custom()` / `record()` chunked rooting; `wide B8` green; `record()` extras.
- [x] 1c.6 `eco_set_unboxed` abort; `wide B11` green.
- [x] 1c.7 `scalar_bytes` / narrow-container asserts.
- [x] 1d walker split, 29 rows (24 runtime, 5 test oracles); M3 audit plus voluntary M1/M5;
      manifest `--update`.
- [x] 1b.1 codegen helpers; `deriveAllParamKinds`; `EvaluatorDesc.kinds` params 0..31.
- [x] 1b.2 papCreate uses `packClosureWord` (IR byte-identical).
- [x] 1b.3 make.closure fixed; fixture extended with `@make_closure_rk1`; verifier 26 → 25.
- [x] 1b.4 `i1` construct operands rejected (`has i1 type`); 2 Phase 0 fixtures green.
- [x] 1b.5 codegen UB sites (13 rows).
- [x] 1b.6 PAPSimplify chain cap; `pap_simplify_fusion_slot_cap.mlir` green.
- [x] 1b.7 group roots chunked; `WideClosureGroupTest` green; extra fixture.
- [x] 1b.8 B22 papCreate verifier loops bounded by `num_captured`; extra fixture.
- [x] 1a.1 B1 plus B9; AbiCloning test 9 green (or the stats-counter fallback).
- [x] 1a.2 B2.
- [x] 1a.3 B3; the record-pattern elm-test pin and `WideRecordPatternTest` green; the Expr.elm crash
      default.
- [x] 1a.4 B21 driver exit status; checked by hand once.
- [x] 1e comments.
- [x] Gate §7 green against its lists; results recorded in the parent plan's Phase 1 entry.

## 9. Open questions (with defaults; none blocks)

1. **`-split-input-file` in `ecoc`:** unknown. Default: one fixture per negative case (1b.4).
2. **The B9 pin's reachability:** default as in 1a.1 (the stats-counter fallback).
3. **The papCreateGroup fixture** may need a cross edge to satisfy the verifier. Default as in 1b.7.
4. **Helper placement in Functions.elm** (shared coercion with `prepareCtorSlots`): default is the
   inline fold of step 1a.1, unless the import already exists.
5. **Any unit test asserting old UB-dependent behaviour:** `HeapHelpersTest.cpp:1551` is known and
   handled. If the gate shows another, fix the test to the accessor semantics; the behaviour change
   is the point of the step.
