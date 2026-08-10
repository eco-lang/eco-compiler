# Kernel surface audit — `String` (elm/core)

Scope: `elm-kernel-cpp/src/core/String.{hpp,cpp}`, `elm-kernel-cpp/src/core/StringExports.cpp`,
`runtime/src/allocator/StringOps.{hpp,cpp}`, `runtime/src/allocator/Utf8.hpp`.
Symbol list authority: `elm-kernel-cpp/src/KernelExports.h:107-147`.
Background: `design_docs/theory/string_rope_representation_theory.md` (HEAP_025 / HEAP_032).

## Representation recap (load-bearing for everything below)

Six concrete tags, all with `header.size` == logical UTF-16 code-unit count
(`Header` is `{u32 bitfield; u32 size;}`, `Heap.hpp:163-175`, size at **byte offset 4**):

| Tag | Shape | Size |
|---|---|---|
| `Tag_String` | flat UTF-16 leaf, inline `chars[]` | variable |
| `Tag_LargeStringHeader` | split header → pinned old-gen `Tag_String` body (`Heap.hpp:432-436`) | 16 B |
| `Tag_StringSlice` | `{base, offset}` view over a leaf/large-header | 24 B |
| `Tag_StringRope` | `{left, right, height, leafCount}` concat node | 32 B |
| `Tag_StringUtf8Leaf` | inline all-ASCII bytes (1 byte == 1 unit) | variable |
| `Tag_StringUtf8View` | `{base, offset, byteLen}` over ByteBuffer / large-byte / utf8-leaf | 24 B |

Plus the embedded `Const_EmptyString` HPointer constant (`ptr_ind != 0`, never heap-allocated).
Thresholds (`AllocatorCommon.hpp:99,102,427,430`): `string_flatten_limit = 32768` units,
`string_tiny_slice_limit = 128` units. Both runtime-tunable via `HeapConfig`.

## Part 1 + Part 2 — per-symbol classification

Class key: **P** pure non-allocating · **PA** pure + GC-heap allocating · **PH** pure, reads heap
through HPtr · **TB** Task builder · **RT** runtime mutable state · **E** effectful · **X** non-returning.

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_String_length` | `(HPtr) -> i64` | **PH** | – | none | **Trivial** (`eco.string.length`) | `StringOps::length` = `rawLen` = one `u32` load at `Header+4` (`StringOps.hpp:111,239`). O(1) for **all six** tags. Export adds an `isEmptyString` guard (`StringExports.cpp:18-27`). Inline lowering = `icmp ptr_ind` → select 0, else GEP+4 / `load i32` / `zext` — exact analogue of `ArrayLengthOpLowering` (`EcoToLLVMHeap.cpp:1219-1250`). No rooting, no GC. |
| `Elm_Kernel_String_append` | `(HPtr,HPtr) -> HPtr` | **PA** | – | leaf **or** `AsciiOut` **or** rope | **Hard-Infeasible** (whole op); *Feasible* for one sliver | `StringOps::append` `StringOps.hpp:477-537`. **NOT** just a rope node: `total <= 32768` ⇒ full memcpy into a fresh UTF-8 leaf (both-UTF-8 arm) or a UTF-16 leaf, plus an O(n) ASCII rescan for "chain healing" (H2, `:517-526`). Rope only above 32768. 3 size regimes × 6×6 tag matrix × 2 config flags. Roots both operands via `StackRootGuard`/`makeRope`. |
| `Elm_Kernel_String_join` | `(HPtr sep, HPtr list) -> HPtr` | **PA** | – | leaf / AsciiOut / balanced rope | **Hard-Infeasible** | `StringOps.cpp:659-776`. Two-pass over a `ListCursor`; Pattern-B rooting via `eco_alloc_with_roots(...,roots,2,0x3)`; large path = `buildBalancedRope` merge stack. `String.concat` in Elm is `join ""` (`String.elm:178-180`), so `StringOps::concat` is only reachable from tests. |
| `Elm_Kernel_String_cons` | `(u64 c, HPtr) -> HPtr` | **PA** | – | 1 leaf (len+1) | **Elm-source** (costs one alloc) | `StringOps.hpp:1241-1270`. Semantically `String.fromChar c ++ str`. Char arrives widened to `u64` then truncated (`StringExports.cpp:40-44`, see CharExports.cpp rationale). |
| `Elm_Kernel_String_uncons` | `(HPtr) -> HPtr` | **PA** | – | slice(24) + Tuple2(24) + Just(16) | **Feasible** — best inline-alloc candidate after `length` | `StringOps.cpp:1009-1055`. Deliberately bypasses `slice()`'s tiny-copy path so fold-with-uncons is O(n) not O(n²). All three allocations are **compile-time-constant sizes**, and `eco.construct.tuple2` / `eco.construct.custom` already have inline-alloc lowerings. Only `charAt(str,0)` + the slice/view node need custom IR. |
| `Elm_Kernel_String_fromList` | `(HPtr chars) -> HPtr` | **PA** | – | 1 AsciiOut or 1 blank leaf | **Hard-Infeasible** (variable size, list walk) | `String.cpp:63-107`. Two-pass with an or-accumulator ASCII gate; rooted correctly (`StackRootGuard` around the single alloc, then an alloc-free write walk). |
| `Elm_Kernel_String_slice` | `(i64,i64,HPtr) -> HPtr` | **PA** | – | slice(24) / view(24) / fresh leaf / rope | **Hard-Infeasible** (whole op); **Feasible** for the large-range-over-leaf arm | `StringOps.cpp:307-473`. **NOT** unconditionally zero-copy: `len <= 128` ⇒ *copies* into a fresh leaf (`tinyFromU16`, `:293-305`, incl. an ASCII rescan). Zero-copy only above 128. Rope ranges recurse and may build a rope-of-slices. The 24-byte node itself fits `emitInlineAllocWithHeader` exactly (see Key findings #6). |
| `Elm_Kernel_String_split` | `(HPtr sep, HPtr) -> HPtr` | **PA** | – | N parts + list spine | **Hard-Infeasible** | `StringOps.cpp:839-983`. BMH search for `sep_len>=4`. UTF-8 arm cuts via `slice()` (parts stay UTF-8, share the source); UTF-16 arm copies each part. Chunked ≤64-slot `pushStackRootRange` (mask `1ULL<<i` is UB at i>=64). Elm wraps the result in `Elm.Kernel.List.fromArray`, which is a pass-through for Cons/ConsChunk (`ListExports.cpp:327-329`) — a wasted kernel call per split. |
| `Elm_Kernel_String_lines` | `(HPtr) -> HPtr` | **PA** | – | N parts + spine | **Elm-source** possible, slower | `String.cpp:179-284`. Two arms (UTF-8 byte scan → `slice`; UTF-16 snapshot → `allocString`). CR/CRLF/LF handling matches elm/core's `/\r\n|\r|\n/`. |
| `Elm_Kernel_String_words` | `(HPtr) -> HPtr` | **PA** | – | trim result + N parts + spine | **Elm-source** possible, slower | `String.cpp:286-389`. ASCII-whitespace only (` \t\n\r`) vs elm/core's Unicode `/\s+/` — divergence, see Key findings #12. |
| `Elm_Kernel_String_reverse` | `(HPtr) -> HPtr` | **PA** | – | 1 AsciiOut or 1 blank leaf | **Hard-Infeasible** | `StringOps.hpp:838-872`. Must materialise (segment walk writing backwards). **Reverses raw u16 units** — breaks surrogate pairs; elm/core's `_String_reverse` is pair-aware (`elm.js:927-945`). |
| `Elm_Kernel_String_toUpper` | `(HPtr) -> HPtr` | **PA** | – | 1 AsciiOut or 1 blank leaf | **Elm-source** feasible (it is a `map` over ASCII) | `StringOps.hpp:762-796`. ASCII-only `a-z`→`A-Z`; elm/core uses JS `.toUpperCase()` (full Unicode). No ICU anywhere in the runtime. |
| `Elm_Kernel_String_toLower` | `(HPtr) -> HPtr` | **PA** | – | 1 AsciiOut or 1 blank leaf | **Elm-source** feasible | `StringOps.hpp:801-833`. Same ASCII-only caveat. |
| `Elm_Kernel_String_trim` | `(HPtr) -> HPtr` | **PA** | – | 0 (whole/empty) or 1 slice/leaf via `slice()` | **Hard-Infeasible** | `StringOps.hpp:878-900`. **Always widens first** (`toStdU16String` on the whole string, counted by `UTF8_WIDEN_TRIM`) even though the trim set is pure ASCII — see Key findings #9. |
| `Elm_Kernel_String_trimLeft` | `(HPtr) -> HPtr` | **PA** | – | as above | **Hard-Infeasible** | `StringOps.hpp:905-922`. Same eager widen. |
| `Elm_Kernel_String_trimRight` | `(HPtr) -> HPtr` | **PA** | – | as above | **Hard-Infeasible** | `StringOps.hpp:927-944`. Same eager widen. |
| `Elm_Kernel_String_startsWith` | `(HPtr,HPtr) -> HPtr` | **PH** | – | **none** (boxed-Bool result is an embedded constant) | **Hard-Infeasible** as an op; **mark `gc-leaf`** | `StringOps.hpp:688-714`. 3 tiers: both-UTF-8 `memcmp` → both-single-segment `memcmp` → `charAt` loop. No Elm allocation on any path. |
| `Elm_Kernel_String_endsWith` | `(HPtr,HPtr) -> HPtr` | **PH** | – | **none** | **Hard-Infeasible** as an op; **mark `gc-leaf`** | `StringOps.hpp:719-748`. Same 3 tiers, offset at the tail. |
| `Elm_Kernel_String_contains` | `(HPtr,HPtr) -> HPtr` | **PH** | – | **none** | **Hard-Infeasible** as an op; **mark `gc-leaf`** | `StringOps.hpp:645-683`. `std::search` on bytes / on `u16*`, else naive `charAt` double loop. |
| `Elm_Kernel_String_indexes` | `(HPtr,HPtr) -> HPtr` | **PA** | – | Int list (`listFromInts`) | **Hard-Infeasible** | `StringOps.cpp:778-837`. **Always** widens both sides via `toStdU16String` (no UTF-8 byte arm, unlike `contains`/`split`) — see Key findings #10. BMH for `needle_len>=4`. |
| `Elm_Kernel_String_toInt` | `(HPtr) -> HPtr` | **PA** | – | `Just` + unboxed Int | **Elm-source** (and it would fix a bug) | `StringOps.hpp:1132-1149`. `narrowAsciiToStack` into `char[64]`, then **`std::from_chars(base 10)`** — locale-free, no libc locale. Rejects `+5` and any string > 64 units. |
| `Elm_Kernel_String_toFloat` | `(HPtr) -> HPtr` | **PA** | – | `Just` + unboxed Float | **Hard-Infeasible** in Elm; fix in place | `StringOps.hpp:1155-1180`. `char[128]` + **`std::strtod`** — the **only locale-dependent call in the whole surface** (LC_NUMERIC decimal point) and it accepts hex floats / leading whitespace. |
| `Elm_Kernel_String_fromNumber` | `(HPtr) -> HPtr` | **PA** | – | 1 UTF-8 leaf | **Already-intrinsic** for the mono'd cases | `String.cpp:451-464` — runtime tag dispatch on `Tag_Int`/`Tag_Float`. Legacy fallback for call sites where `number` stayed polymorphic; mono picks the `_Int`/`_Float` variants (`KernelAbi.elm:267-272`) or the intrinsics. |
| `Elm_Kernel_String_fromNumber_Int` | `(i64) -> HPtr` | **PA** | – | 1 UTF-8 leaf | **Already-intrinsic** (call-lowered) | `StringExports.cpp:144-147` → `StringOps::fromInt` → `std::to_chars` (locale-free, non-allocating) → `makeUtf8LeafFromBytes`. |
| `Elm_Kernel_String_fromNumber_Float` | `(f64) -> HPtr` | **PA** | – | 1 UTF-8 leaf | **Already-intrinsic** (call-lowered) | `StringExports.cpp:149-152` → `StringOps::fromFloat` (`StringOps.hpp:1199-1218`); `std::to_chars` shortest round-trip, special-cases NaN/±Infinity/0. |
| `elm_string_from_int` | `(i64) -> HPtr` | **PA** | – | 1 UTF-8 leaf | **Already-intrinsic — but it is a CALL, not inline IR** | `StringExports.cpp:157-160`. `Eco_StringFromIntOp` (`Ops.td:1102-1112`) lowers via `StringFromIntOpLowering` → `rewriter.create<LLVM::CallOp>(...)` (`EcoToLLVMHeap.cpp:1523-1539`). |
| `elm_string_from_double` | `(f64) -> HPtr` | **PA** | – | 1 UTF-8 leaf | **Already-intrinsic — CALL** | `StringExports.cpp:162-165`; `Ops.td:1114-1124`; `EcoToLLVMHeap.cpp:1541-1556`. |
| `Elm_Kernel_String_map` | `(HPtr clo, HPtr) -> HPtr` | **PA** | **HOF** | `vector<u16>` snapshot + result vector + 1 AsciiOut/leaf + whatever the closure allocates | **Elm-source** (strongly indicated) | `StringExports.cpp:251-267`. Per char: `eco_apply_closure_eval` with a `kLayoutChar1` descriptor (`:186-200`). Roots `closureHP` with `StackRootGuard`. |
| `Elm_Kernel_String_filter` | `(HPtr clo, HPtr) -> HPtr` | **PA** | **HOF** | as above | **Elm-source** | `StringExports.cpp:269-285`; `eco_apply_closure_typed`, boxed-Bool result. |
| `Elm_Kernel_String_any` | `(HPtr clo, HPtr) -> HPtr` | **PA** (via callback) | **HOF** | full `vector<u16>` snapshot even for an index-0 hit | **Elm-source** (clear win) | `StringExports.cpp:287-303`. Returns an embedded Bool constant; allocates nothing itself, but the callback can GC ⇒ needs the safepoint + root. |
| `Elm_Kernel_String_all` | `(HPtr clo, HPtr) -> HPtr` | **PA** (via callback) | **HOF** | as above | **Elm-source** (clear win) | `StringExports.cpp:305-322`. |
| `Elm_Kernel_String_foldl` | `(HPtr clo, HPtr acc, HPtr) -> HPtr` | **PA** | **HOF** | snapshot + closure allocations | **Elm-source** if a `charAt` primitive lands | `StringExports.cpp:324-338`. Correctly roots `closureHP` **and** `accHP` (`StackRootGuard loopRoots`). |
| `Elm_Kernel_String_foldr` | `(HPtr clo, HPtr acc, HPtr) -> HPtr` | **PA** | **HOF** | as above | **Elm-source** if a `charAt` primitive lands | `StringExports.cpp:340-354`. |

**Counts** — 33 symbols: **PA 29**, **PH 4** (`length`, `startsWith`, `endsWith`, `contains`),
**P 0, TB 0, RT 0, E 0, X 0**. **HOF 6**. No symbol in this surface performs IO, builds a Task,
or touches the string-literal intern table (`RuntimeExports.cpp:574`) — that table is reached
only from `Eco_StringLiteralOp` lowering, never from these entry points. The only mutable
runtime state touched is the `GC_STATS_*` census, compiled out in non-stats builds
(`GCStats.hpp:790-792`).

### Answers to the specific questions

1. **`String_length` — O(1)?** Yes, unconditionally, for all six tags, because HEAP_025 defines
   `header.size` as the logical UTF-16 length for every string form (`StringOps.hpp:106-111`).
   Even `Tag_StringRope` stores the total, and `Tag_LargeStringHeader` mirrors its body's
   (`Heap.hpp:427-435`). It is a *single `u32` load at byte offset 4*, plus one branch for
   `Const_EmptyString`. **Yes — it should be an `eco.string.length` op**, ~3 instructions.

2. **`String_append` — just a rope-concat node?** **No.** Below 32768 units it is a full copy
   (`StringOps.hpp:489-527`); only `total > 32768` allocates a `Tag_StringRope`
   (`:530-536`). Since virtually all Elm string building is far below 32 KiB, the rope path is
   effectively cold and append is *memcpy-shaped*, not *node-shaped*. An inline
   `eco.consAlloc`-style sequence is blocked because the byte size is a runtime value while
   `emitInlineAllocWithHeader` (HEAP_034) requires a compile-time-constant, 8-aligned, ≤4096 size
   (`EcoToLLVMInternal.h:824-861`).

3. **`String_slice` — zero-copy view?** **Only above `string_tiny_slice_limit` = 128 units.** At or
   below 128 it copies into a fresh leaf (`StringOps.cpp:349-410`) — and the UTF-16 tiny path
   additionally rescans for ASCII to narrow into a UTF-8 leaf (`tinyFromU16`, `:293-305`). The
   node itself (24 B, constant) *would* fit an inline allocation; the tag dispatch, the tiny-limit
   config read, and the rope recursion would not.

4. **Must normalise/flatten vs can stay lazy.**
   *Must materialise:* `reverse`, `toUpper`, `toLower`, `repeat`, `padLeft/Right`, `map`, `filter`,
   `cons`, `fromList`, `toList`, `indexes`, `toInt`, `toFloat`, `trim*` (widen-then-slice), the
   `split`/`lines`/`words` UTF-16 arms, and `append`/`concat`/`join` under 32768.
   *Stay lazy (structure-preserving):* `length`, `charAt`, `contains`, `startsWith`, `endsWith`,
   `equal`, `compare` (all three tiers), `uncons`, `slice` above 128, the `split`/`lines`/`words`
   UTF-8 arms, and `append`/`concat`/`join` above 32768.
   `ensureFlat`/`maybeFlattenOrRebalance` (`StringOps.cpp:241-279`) is the single decision point;
   note it **always** widens a UTF-8 form regardless of size, because `ensureFlat` consumers cast
   to `ElmString*` and index `chars[]`.

5. **libc / ICU / locale.** No ICU. No `<cctype>` classifier is actually called (the header is
   included but `trim`/`toUpper`/`toLower` use explicit comparisons). Locale-free: `std::to_chars`,
   `std::from_chars`, `memcmp`, `memcpy`, `std::search`. **Locale-dependent: exactly one call,
   `std::strtod` in `toFloat` (`StringOps.hpp:1174`)** — a host embedding eco that calls
   `setlocale(LC_NUMERIC, "de_DE")` would make `String.toFloat "1.5"` return `Nothing`.

6. **`toInt`/`toFloat`/`fromNumber`.** `toInt` → `std::from_chars`; `toFloat` → `strtod`;
   `fromInt`/`fromFloat` → `std::to_chars` then `makeUtf8LeafFromBytes`. `toInt` is a ~15-line digit
   loop and **should be Elm-source** (that is literally what elm/core's JS does, `elm.js:1124-1146`),
   which would also fix the `+5` and >64-unit gaps for free. `toFloat` should stay in C++ but move
   from `strtod` to `std::from_chars(..., chars_format::general)`. `fromNumber` is already a dialect
   op for the monomorphised cases — but see Key findings #4.

7. **The HOFs / opaque boundary.** Confirmed opaque: each character crosses into
   `eco_apply_closure_{typed,eval}`, which reads the closure header **at runtime** and dispatches
   under-/saturated/over-saturated (`StringExports.cpp:171-218`). No inlining, no HOF-elimination,
   no arity specialisation can see through it, and every call site pays a full dynamic apply plus a
   `std::vector<u16>` snapshot of the entire string (`snapshotChars`, `:225-233`) — even `any`,
   which may exit at index 0. **They should be Elm-source**, gated on exporting a non-allocating
   indexed accessor (see Key findings #1).

---

## Key findings

1. **The missing primitive: `String.charAt`.** `StringOps::charAt` (`StringOps.hpp:410-463`) is
   already perfect — iterative (deep ropes can't blow the C stack), tag-dispatched over all six
   forms, **allocation-free so callers need no rooting** — yet it is **not exported** in
   `KernelExports.h`. Exporting it (as a kernel symbol *and* an `eco.string.char_at` op) unlocks
   Elm-source rewrites of all six HOFs plus `toUpper`/`toLower`/`toInt`, deleting the closure
   trampoline, the `std::vector<u16>` snapshot, and the opaque optimisation boundary in one move.
   This is the highest-leverage item in the audit.

2. **`eco.string.length` is nearly free and blocked on nothing.** One `u32` load at `Header+4`,
   valid for every tag, with `ArrayLengthOpLowering` (`EcoToLLVMHeap.cpp:1219-1250`) as a
   line-for-line template. The only extra work versus `array.length` is a `ptr_ind` guard for
   `Const_EmptyString`.

3. **`String.length` (and the three predicates) currently *poison* GC-free propagation.**
   `propagateGcFreeLeafAttrs` treats any call to a **non-gc-leaf declaration** as poison
   (`EcoBackend.cpp:1666`), and poison propagates callee→caller to a fixpoint. `length`,
   `startsWith`, `endsWith` and `contains` are provably GC-free (verified: no `eco_alloc*` on any
   path), yet their externs carry no `gc-leaf-function` attr — so one `String.length` call
   disqualifies its whole function *and every transitive caller* from the C2 optimisation, and adds
   an RS4GC statepoint (spilling all live roots) around a single load. Stamping the attribute
   (mechanism: `EcoToLLVMRuntime.cpp:143-149`) is a ~10-line, zero-risk change that should land
   before any dialect work.

4. **`eco.string.from_int` / `from_float` are ops in name only — they lower to `LLVM::CallOp`.**
   `EcoToLLVMHeap.cpp:1523-1539` and `:1541-1556`. Their real (and genuine) value is the *unboxed*
   `i64`/`f64` operand, which avoids boxing an `ElmInt`/`ElmFloat` just to hand it to
   `fromNumber`. Neither op carries `[Pure]` or a folder, so `String.fromInt 42` — common in
   generated code — is not constant-folded into an `eco.string_literal`. Adding a folder for
   constant operands is small and self-contained.

5. **`String.toInt` rejects a leading `+`.** `std::from_chars` (`StringOps.hpp:1145`) accepts only
   `-`; elm/core explicitly handles `0x2B` (`elm.js:1128`). So `String.toInt "+5"` is `Just 5` in
   Elm and `Nothing` in eco. It also silently returns `Nothing` for any input longer than the
   64-byte stack buffer (`:1140`). No E2E test covers `String.toInt` — `grep -rl "String.toInt"
   test/elm/src/` is empty.

6. **`String.toFloat` accepts inputs Elm rejects, and is locale-fragile.** elm/core rejects any
   string matching `/[\sxbo]/` before parsing (`elm.js:1148-1157`); eco's `strtod` skips leading
   whitespace and parses hex floats, so `String.toFloat " 1.5"` → `Just 1.5` and
   `String.toFloat "0x10"` → `Just 16` where Elm gives `Nothing`. Conversely `"Infinity"` is
   `Just Infinity` in Elm and `Nothing` in eco (`:1177`). Plus the LC_NUMERIC exposure noted above.
   Also untested.

7. **`String.indexes ""` returns `[0..length]`; Elm returns `[]`.** `StringOps.cpp:780-787` and
   `:801-804` both build the full index range for an empty needle; elm/core short-circuits
   `if (subLen < 1) return _List_Nil;` (`elm.js:1094-1098`). Two code paths, same bug.

8. **`String.reverse` corrupts surrogate pairs.** `StringOps.hpp:838-872` reverses raw `u16`
   units; elm/core's `_String_reverse` keeps astral pairs in order (`elm.js:927-945`). The UTF-8
   arm is fine by construction (all-ASCII), so this only bites UTF-16 content — which is exactly
   the content that has astral chars.

9. **`trim`/`trimLeft`/`trimRight` widen the entire string to find ASCII whitespace.**
   `StringOps.hpp:882, 909, 931` call `toStdU16String` unconditionally and count a
   `UTF8_WIDEN_TRIM` event, then hand the *original* pointer to `slice()`. The trim set is
   ` \t\n\r` — pure ASCII — so the UTF-8 forms could scan bytes directly, exactly as `lines`
   (`String.cpp:185-224`) and `words` (`:298-336`) already do. This is a straightforward
   widen-elimination in the same style as the shipped W4 arms.

10. **`indexes` is the last search op with no UTF-8 byte arm.** `contains`, `startsWith`,
    `endsWith` (`StringOps.hpp:656, 698, 731`) and `split` (`StringOps.cpp:858`) all have one;
    `indexes` (`StringOps.cpp:789-798`) widens both needle and haystack every call. Its BMH loop is
    byte-index-safe under the all-ASCII invariant, so the arm is a near-copy of `split`'s.

11. **`String_uncons` is the strongest inline-allocation candidate.** All three objects it builds
    have compile-time-constant sizes (slice/view 24 B, Tuple2 24 B, `Just` 16 B), two of the three
    already have inline-alloc lowerings, and the header word for a variable-length node is a
    one-instruction extension: `Header` is `{u32 bits; u32 size}`, so
    `headerWord = constTagBits | (u64(len) << 32)` — a `shl`+`or` on top of
    `emitInlineAllocWithHeader`. `uncons` is the hot path in char-by-char Elm parsing.

12. **ASCII-only case mapping and whitespace, versus elm/core's Unicode.** `toUpper`/`toLower`
    handle only `a-z`/`A-Z` (`StringOps.hpp:776, 815`) where elm/core calls JS
    `.toUpperCase()`/`.toLowerCase()` (`elm.js:1026-1034`); `words` splits on ` \t\n\r` where
    elm/core uses `/\s+/`; `trim` likewise versus JS `.trim()`. These may be deliberate (no ICU
    dependency is a real design win) but they are undocumented in the theory doc and untested.

13. **Dead API surface with a latent rooting bug.** `Elm::Kernel::String::{map,filter,any,all,
    foldl,foldr}` (`String.hpp:70-114`, `String.cpp:113-161`) take raw C function pointers and are
    called by **nothing** — the exported HOFs go straight to closures. `String.cpp`'s `foldl`
    (`:133-147`) and `foldr` (`:149-161`) hold `HPointer result` across `func(...)` with **no
    `StackRootGuard`**, so if that callback ever allocated the accumulator would dangle; the live
    `StringExports.cpp` versions root it correctly (`:330, :346`). Dead today, a trap if ever
    revived. `StringOps::{left,right,dropLeft,dropRight,repeat,padLeft,padRight,concat}` are
    likewise test-only — the Elm module implements all of them in Elm source
    (`String.elm:130-136, 244-284, 385-397`).

14. **Two heavyweight headers included for nothing.** `StringOps.hpp:29-30` pulls in `<sstream>`
    and `<iomanip>`; no stream, manipulator, or `std::hex` appears anywhere in `StringOps.{hpp,cpp}`.
    `StringOps.hpp` is included across the whole kernel, so dropping them is free compile time.

15. **The rooting discipline in scope is otherwise sound.** Spot-checked the hard cases: `slice`'s
    rope arm re-derives `right` from the rooted `self` after the recursive left call
    (`StringOps.cpp:466-471`, with the reason documented); `concat`/`join` use Pattern-B
    `eco_alloc_with_roots` and re-read the handle out of `roots[]` (`:615-619, :723-729`);
    `buildBalancedRope` roots the whole merge stack across each `makeRope` (`:516, :529`);
    `makeUtf8LeafFromBytes` snapshots movable payload bytes to the C stack before allocating
    (`:154`); and every `pushStackRootRange` over a parts vector is chunked to ≤64 slots because
    the mask is `1ULL<<i` (`String.cpp:209-215, 272-276, 323-327`; `StringOps.cpp:895-901`) — the
    one place `StringOps.cpp:970` still pushes one range per element, which is correct but O(n)
    ranges where the UTF-8 arm uses O(n/64).

## Recommended ordering

| # | Change | Risk | Payoff |
|---|---|---|---|
| 1 | Stamp `gc-leaf-function` on `String_{length,startsWith,endsWith,contains}` externs | very low | un-poisons GC-free propagation; drops statepoints |
| 2 | Add `eco.string.length` (inline `Header+4` load) | low | removes a call from the hottest string op |
| 3 | Export `charAt` + add `eco.string.char_at` | low | prerequisite for #4 |
| 4 | Move `map/filter/any/all/foldl/foldr`, `toUpper/toLower`, `toInt` to Elm source over `length`+`charAt` | medium | kills the opaque HOF boundary and the snapshot vectors; fixes #5 |
| 5 | Fix `indexes ""`, `toFloat` (`from_chars` + elm/core's reject set), `reverse` surrogate pairs | low | correctness; add E2E tests (none exist) |
| 6 | UTF-8 byte arms for `trim*` and `indexes` | low | removes the last two unconditional widen sites |
| 7 | Constant-folder for `eco.string.from_int`/`from_float` | low | `String.fromInt 42` → literal |
| 8 | `eco.string.uncons` inline-alloc sequence (needs variable-`size` header word) | medium-high | O(1) parsing loops |
