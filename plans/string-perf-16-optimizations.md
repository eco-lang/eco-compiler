# String Performance: 16 Optimisations

## Problem

Runtime `StringOps` and the kernel `String` module suffer from a pervasive
"snapshot-then-copy" idiom. Every operation that wants to read a string
allocates a fresh `std::u16string` via `toStdU16String`, often builds a second
`std::vector<u16>` from it, then calls `alloc::allocString` which memcpys a
third time into the GC heap. For leaf inputs (the common case) this is **3
heap allocations + 3 memcpys** when **1 + 1** would suffice.

Search ops (`contains` / `startsWith` / `endsWith`) walk via `charAt`, which
re-dispatches on tag and re-resolves the slice base every character — a leaf
fast path using `memcmp` / `std::search` would be far faster.

`equal`/`compare` over mixed forms (rope-vs-leaf etc.) currently char-walks
via `charAt`; a lockstep leaf-cursor with `memcmp` is asymptotically the same
but cache-friendly and free of per-char tag dispatch.

`toInt`/`toFloat` allocate a narrowed `std::string` to feed `strtoll`/`strtod`;
`fromInt` uses `std::ostringstream` — a heavyweight locale-aware path. Both
should use `<charconv>`.

`indexes`/`split` implement naive O(n·m) substring search; for large needles
that's the wrong algorithm.

The full list, ordered by impact:

| #  | Item | Files |
|----|------|-------|
| 1  | Tag-aware `forEachSegment` visitor (no `std::u16string` alloc on leaves) | `StringOps.{hpp,cpp}` |
| 2  | `allocStringBlank(len, &out_hp)` API + adopt in `toUpper`/`toLower`/`reverse`/`repeat`/`cons`/`padLeft`/`padRight`/`map`/`filter`/`fromList` | `HeapHelpers.hpp`, `StringOps.{hpp,cpp}`, `String.cpp` |
| 3  | `concat`/`join` copy segments directly into `result->chars` | `StringOps.cpp` |
| 4  | Fast leaf path for `contains`/`startsWith`/`endsWith` (`memcmp` / `std::search`) | `StringOps.hpp` |
| 5  | Lockstep leaf cursors for `equal`/`compare` on mixed forms | `StringOps.hpp` |
| 6  | Drop redundant `std::vector` dup in `toUpper`/`toLower`/`split` | `StringOps.{hpp,cpp}` |
| 7  | `slice` tiny-path: stop building a vector to memcpy from | `StringOps.cpp` |
| 8  | `fromInt` via `std::to_chars` | `StringOps.hpp` |
| 9  | `toInt`/`toFloat` via `std::from_chars` | `StringOps.hpp` |
| 10 | BMH search for `indexes`/`split` (needles ≥ 4 chars) | `StringOps.cpp` |
| 11 | ASCII `fromChar` constant pool | `StringOps.hpp` |
| 12 | `uncons` builds `Tag_StringSlice` regardless of length | `StringOps.cpp` |
| 13 | `lines`/`words` drop redundant snapshot-to-vector copy | `String.cpp` |
| 14 | Leaf cursor for `slice` tiny-path over rope | `StringOps.cpp` |
| 15 | Two-pass UTF-8 encode in `toStdString` | `StringOps.cpp` |
| 16 | Cache `Allocator::instance()` in `contains`/`startsWith`/`endsWith`/`all`/`any` | `StringOps.hpp` |

## Invariants honoured

- **HEAP_011** — any allocation may trigger minor GC. New `allocStringBlank`
  returns the writable `chars[]` pointer *after* the allocation has run;
  callers must complete the buffer fill before any subsequent allocation.
- **HEAP_025/026** — `Tag_String` / `Tag_LargeStringHeader` distinction is
  preserved. `allocStringBlank` re-uses the same large-object split-header
  path; the writable pointer in the large case is into the pinned old-gen
  body (no relocation hazard there). For small strings it points into the
  freshly-allocated nursery object, safe until the next alloc.
- **HEAP_010 / REP_CONSTANT_003** — `Const_EmptyString` for zero-length
  results is unchanged; embedded-constant comparison semantics preserved.
- **FORBID_LAYOUT_001 / HEAP_025 §"all structure access via StringOps"** —
  new helpers live inside `StringOps` and add no external direct-field access.

## Design: the two new primitives

```cpp
// In StringOps.hpp:

// Invokes `cb(const u16* segPtr, u32 segLen)` for each contiguous segment of
// `str`, in logical order. Zero allocations. Safe on leaves, slices, large
// split headers, and ropes (iterative — explicit stack, no C-stack blow on
// deep ropes). The callback must NOT allocate.
template <class F>
void forEachSegment(void* str, F&& cb);
```

```cpp
// In HeapHelpers.hpp (alloc:: namespace):

struct BlankString {
    HPointer hp;   // GC-tracked handle for the new string
    u16* chars;    // writable; valid until next alloc
    u32 length;
};

// Allocates a fresh string of `length` u16 code units; returns a writable
// pointer to the chars[]. The caller MUST fill all `length` slots before any
// subsequent allocation (no exceptions). Routes length==0 to emptyString().
// Large-payload sizes use the split-header path (body is pinned in old gen).
inline BlankString allocStringBlank(size_t length);
```

## Rollout order (each step incremental, separately compilable)

1. Add `forEachSegment` (read-only, no allocator change).
2. Add `allocStringBlank` in HeapHelpers.
3. Adopt in transforms (`toUpper`/`toLower`/`reverse`/`repeat`/`cons`/`padLeft`/`padRight`/`map`/`filter`/`fromList`).
4. Adopt in `concat`/`join` for the flat-allocation path.
5. Drop redundant vector dups (toUpper/toLower/split/lines/words/toList/slice-tiny).
6. Swap `fromInt`→`to_chars`, `toInt`/`toFloat`→`from_chars`.
7. Switch `indexes`/`split` to BMH for non-trivial needles.
8. Fast leaf path for `contains`/`startsWith`/`endsWith`.
9. Lockstep leaf cursor for `equal`/`compare` mixed forms.
10. `uncons` → unconditional `Tag_StringSlice` for n-1.
11. Rope tiny-slice leaf cursor.
12. Two-pass UTF-8 `toStdString`.
13. ASCII `fromChar` cache (low-impact, can land last).
14. `Allocator::instance()` hoisting (mechanical, last).

## Verification gates

After implementation:

1. `cmake --build build --target full` (E2E suite).
2. Stress-test target (if available; otherwise `TEST_FILTER=string` E2E run).
3. Full bootstrap per `@guides/bootstrap.md`.

## Files modified

- `runtime/src/allocator/StringOps.hpp`
- `runtime/src/allocator/StringOps.cpp`
- `runtime/src/allocator/HeapHelpers.hpp`
- `elm-kernel-cpp/src/core/String.cpp`
