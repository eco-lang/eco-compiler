# UTF-8 String Pipeline Wiring: Zero-Copy Reads, UTF-8 Parsing, Conservative Widening

*(Plan created Jul 8, 2026; rewritten same day to implementation-ready depth —
every file:line reference below was verified against the working tree on
Jul 8, 2026. Successor to `plans/utf8-string-representation.md` (M0–M5, landed).
Prompted by the post-merge investigation: Stage 7a self-compile timing was flat
(~237 s vs ~241 s baseline) because the parser never receives a UTF-8 string.)*

> **IMPLEMENTATION STATUS (Jul 8, 2026).** W0–W4 implemented. W0 counters +
> invalid-UTF-8 goldens (KernelExportsTest K8b); W1 Bytes.Decode.string gate +
> dead-code deletion (K8c repr + elm-bytes E2E); W2 `tryMakeAsciiString` +
> `allocStringFromUTF8` gate; W3 `File.readString` direct-to-buffer zero-copy
> view; W4 `AsciiOut` builder + arms (append/concat/join/toUpper/toLower/
> reverse/repeat/pad/filter/foldl/foldr/split/lines/words + kernel map/filter/
> fold + narrowAsciiToStack). Invariant renumbered: UTF-8 rep is now **HEAP_032**
> (HEAP_028 duplicate resolved → HEAP_028 = PointerIsAddress). Adversarial
> GC-review workflow found + fixed 2 medium defects: (1) split/lines/words
> root-range chunked to <=64 slots (1ULL<<i UB); (2) read_string offset/length
> bounds guard (matches sibling readers). Deferred (transient-only / W7):
> `indexes` u16 snapshot, `toList` UTF-8 leaves, StringOps C-fn `map`,
> `trim` scan (output already UTF-8 via slice). Pre-existing latent
> single-range roots remain at StringOps toList (~:995) — out of scope.

## 1. Goal

The M0–M5 work built a correct UTF-8 (all-ASCII) string layer — heap forms, GC
arms, op fast paths, literal interning, a parser byte path — but the *pipeline
into it* is not wired, and most string-producing ops decay UTF-8 back to
UTF-16. This plan closes three gaps:

1. **Zero-copy reads become real**: `Bytes.Decode.string` and
   `Eco.File.readString` produce `Tag_StringUtf8View`/`Tag_StringUtf8Leaf` for
   ASCII content instead of transcoding to UTF-16.
2. **The parser actually parses UTF-8**: compiler source arrives as a UTF-8
   form, activating the existing `resolveString` narrow byte path
   (`elm-kernel-cpp/src/parser/ParserExports.cpp:53-69`) — 1 byte/char, no
   transcode, ~½ the RAM for source text.
3. **Widening becomes conservative**: ops that today emit UTF-16
   unconditionally keep results UTF-8 whenever the output is provably ASCII,
   so a UTF-8 string survives `append`/`split`/`trim`/`toUpper`/… instead of
   decaying after one operation.

Plus a first-class testing workstream (elm/bytes E2E + elm/core String E2E +
C++ differential/property) over ASCII **and** non-ASCII data.

**Scope property (verified):** every change in this plan is runtime/kernel C++
(+ tests). No compiler Elm code, no MLIR, no codegen changes. Consequences:
self-compile MLIR output must stay byte-identical (11,698,078 B), elm-tests
(front-end, runs as JS) are unaffected, and `--target check` is sufficient for
inner-loop iteration (still run `--target full` + bootstrap at milestone
exits).

## 2. Verified current state

### 2.1 What already works — do not rebuild

| Piece | Where (verified) |
|---|---|
| Heap forms: `elm_string_utf8_view` (24 B: base/offset/byteLen), `elm_string_utf8_leaf` (inline `u8 bytes[]`) | `runtime/src/allocator/Heap.hpp:631-647`; tags at `:109-110` |
| GC arms for both tags (evacuate / mark / fixup / size) | landed with M1; enumerated via `grep -n "StringUtf8" runtime/src/allocator/*.cpp` |
| `isUtf8` / `utf8Bytes` (payload resolver: leaf inline bytes; view through ByteBuffer / LargeByteHeader-body / leaf base + offset; pointer valid **only until next allocation**) | `runtime/src/allocator/StringOps.hpp:67-104` |
| Constructors: `makeUtf8View` (roots base across alloc; **self-collapses** `Tag_ByteBufferSlice` and `Tag_StringUtf8View` bases into base+offset), `makeUtf8LeafFromBytes` (kill-switch + LOT-fallback + stack snapshot + VALIDATE assert) | `runtime/src/allocator/StringOps.cpp:94-125`, `:127-164` |
| Op fast paths, no widen: `length` (`hpp:216`), `charAt` (`hpp:421-426`), `equal`/`compare` memcmp (`hpp:1316`, `:1387`), `slice` → tiny leaf ≤128 / view (`cpp:256-272`), `uncons` → view advanced 1 byte (`cpp:843-849` within `:817`), `contains`/`startsWith`/`endsWith` byte arms (`hpp:601`, `:643`, `:676`), `toStdString` byte copy | as cited |
| `trim`/`trimLeft`/`trimRight` **outputs** are already UTF-8 for UTF-8 input — they cut via `slice()` (`hpp:782-846`); only their whitespace *scan* widens (see 2.3) | `hpp:782`, `:807`, `:827` |
| Parser narrow byte path: `ParserStr{wide,narrow,len}`, `resolveString` checks `isUtf8` **before** `ensureFlat` | `ParserExports.cpp:43-69` — dead in practice: never fed UTF-8 |
| ASCII literals → `[N x i8]` globals → interned permanent `Tag_StringUtf8Leaf` in thread old-gen (`LiteralTable`, `RootSet::addRoot`) | `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp:54-199`; `runtime/src/allocator/RuntimeExports.cpp:437-539` |
| `fromInt`/`fromFloat` → UTF-8 leaves via `makeUtf8LeafFromBytes` | `StringOps.hpp:1024-1055` |
| Write side: `Encode.string` memcpy fast path (`BytesExports.cpp:220-225`), `elm_utf8_copy` (`ElmBytesRuntime.cpp:172-177`), `getStringWidth` O(1) (`BytesExports.cpp:311-324`, `ElmBytesRuntime.cpp:112-124`) | as cited |
| Config: `utf8_strings_enabled=true`, `utf8_view_min_len=32` (`AllocatorCommon.hpp:93-97`, fields `:361-364`; JSON plumbing `HeapConfigJson.cpp:264-265`) | as cited |
| Useful allocator helpers that already exist: `allocByteBuffer` (routes ≥ LOT to split-header, `HeapHelpers.hpp:902`), `allocByteBufferBlank` → `BlankByteBuffer{hp,bytes,length}` (same routing; large bodies pinned/stable, `HeapHelpers.hpp:927-966`), `BlankString`/`allocStringBlank` (`:422`, `:447`), `byteBufferView` (slice-aware: returns `bytes + slc->offset`, `:1609`) | as cited |

Relevant config values (`AllocatorCommon.hpp`): `LARGE_OBJECT_THRESHOLD = 8192`
(`:80`), `STRING_FLATTEN_LIMIT = 32768` (`:85`), `STRING_TINY_SLICE_LIMIT = 128`
(`:88`), `UTF8_VIEW_MIN_LEN = 32` (`:93`). Note **flatten limit > LOT**: a
"small enough to flatten" string can still be too big for a UTF-8 *leaf* —
this is why the output builder (BB-2 below) needs a buffer+view arm.

### 2.2 The three gaps

**GAP-1 — `Bytes.Decode.string` zero-copy path is dead code.**
`Elm::Kernel::Bytes::read_string` (`elm-kernel-cpp/src/bytes/Bytes.cpp:249-339`)
contains the complete, correct gate (scan → view/leaf/legacy) — and has **zero
callers** (only its decl `Bytes.hpp:64`). The symbol the runtime binds is
`Elm_Kernel_Bytes_read_string` (`BytesExports.cpp:588-677`, registered
`RuntimeSymbols.cpp:921`), which unconditionally: counts UTF-16 units
(`:607-625`), allocates `Tag_String` via `eco_alloc_with_roots` with `srcHP`
rooted (`:629-637`), transcodes (`:642-674`), returns
`makeTuple2_ip(offset+length, str)` (`:676`). Differences from the dead
version that the port must respect: the live export returns a **bare tuple**
(dead: `readSuccessBoxed` = `just(boxed(tuple))`, `Bytes.cpp:37-41`), handles
`length==0 → emptyString()` itself (`:596-598`), and has **no bounds check**
(dead: `decodeFailure()` on out-of-range — do **not** port that; bounds are
the Elm-side decoder's job today and adding a check would change behavior).
HEAP_028 (`design_docs/invariants.csv:561`) already documents `read_string` as
a gated UTF-8 producer — invariant and live code have diverged.

**GAP-2 — kernel string ingestion always widens.**
`alloc::allocStringFromUTF8(const std::string&)`
(`runtime/src/allocator/HeapHelpers.hpp:490-546`) transcodes to
`std::u16string` and calls `allocString` (UTF-16), unconditionally, with a
*lenient* decoder (skips invalid bytes, `:528-531`). It is the single
ingestion chokepoint behind: `Eco.File.readString`
(`eco-kernel-cpp/src/eco/File.cpp:82-98` → `succeedString`,
`TaskBinding.hpp:52` → `taskSucceedString`, `KernelHelpers.hpp:140-144`),
`Console.readLine`, `Env`, `Http` bodies (`Http.cpp` multiple),
`PortRuntime.cpp`. This is why compiler source is UTF-16 before the parser
sees it: `Builder/File.elm:177 readUtf8` → `Parse.fromByteString :
ProjectType -> String -> …` (`compiler/src/Compiler/Parse/Module.elm:63`;
call site `compiler/src/Builder/Build.elm:685-688`).

**GAP-3 — ops decay UTF-8 → UTF-16 even when output is provably ASCII.**
All verified against current bodies:

| Op | Site | Today for UTF-8 input |
|---|---|---|
| `append` (total ≤ flatten limit) | `StringOps.hpp:453`, widen at `:466-471` | `toStdU16String` both sides → UTF-16 leaf |
| `concat` / `join` (flatten path) | `StringOps.cpp:461` / `:551` | Pattern-B rooted walk → UTF-16 leaf |
| `split` | `StringOps.cpp:715` (snapshot `:735-736`, parts `:784-792`) | u16 snapshots of both operands; parts = fresh UTF-16 `allocString` |
| `lines` / `words` | `elm-kernel-cpp/src/core/String.cpp` (`grep -n "HPointer lines\|HPointer words"`) | u16 snapshot; parts = UTF-16 `allocString` |
| `toUpper`/`toLower` | `StringOps.hpp:706`/`:731` | `allocStringBlank` + `copyInto` (widening segment walk) |
| `reverse`/`repeat`/`padLeft`/`padRight` | `hpp:754`/`:847`/`:874`/`:903` | same BlankString pattern |
| `filter` (C-pred variant) | `StringOps.cpp:886` | two-pass `forEachSegment` → UTF-16 |
| `foldl`/`foldr` (C-fn variant) | `StringOps.cpp:920`/`:929` | `toStdU16String` transient widen |
| kernel exports `map`/`filter`/`any`/`all`/`foldl`/`foldr` | `elm-kernel-cpp/src/core/StringExports.cpp:229-336`, all via `snapshotChars` (`:223` = `toStdU16String` → `vector<u16>`) | u16 snapshot; map/filter output = UTF-16 `allocString` |
| kernel `String::foldl/foldr` (FoldFunc variant) | `elm-kernel-cpp/src/core/String.cpp:114-141` | `toStdU16String` snapshot |
| `toInt`/`toFloat` | `StringOps.hpp:953` (`narrowAsciiToStack` via `forEachSegment`) | UTF-8 → widen through 512-u16 chunks (`hpp:351-365`) → narrow back to char |
| `indexes` | `StringOps.cpp:658` (snapshots `:669-670`) | u16 snapshots (output is ints — only the widen cost matters) |
| `toList` | `StringOps.cpp:795` | u16 snapshot; per-char `fromChar` (UTF-16 1-char strings) |
| `makeUtf8LeafFromBytes` ≥ LOT | `StringOps.cpp:142-150` | widens to UTF-16 ("no large UTF-8 form in v1") |
| `ensureFlat` | `StringOps.cpp:199-204` via `maybeFlattenOrRebalance` | unconditional widen — **backstop only**: sole production caller is the parser (`ParserExports.cpp:65`), which short-circuits UTF-8 first (verified by unfiltered grep: no other callers exist) |

### 2.3 Sizing the win

- 179 of 253 `compiler/src/**.elm` files (~71%) are pure ASCII (74 contain
  ≥ 1 non-ASCII byte and keep the UTF-16 path whole-file — the gate is
  whole-string by design; per-file, not per-region).
- Stage 7a cold-self-compile baseline: **~237 s**, peak RSS 3.84 GiB
  (`frontendstats.txt`, 2026-07-08 entry).
- Artifact loads decode length-prefixed UTF-8 strings via
  `compiler/src/Utils/Bytes/Decode.elm:54-59` → the GAP-1 export; post-W1
  every persisted ASCII string ≥ 32 B becomes a 24-byte view instead of a
  transcoded UTF-16 copy.

## 3. Design principles and shared building blocks

1. **The ASCII gate stays** (HEAP_028). Nothing lifts non-ASCII into UTF-8
   forms. Non-ASCII and invalid input keep today's paths byte-for-byte,
   including the lenient/garbage-tolerant invalid-UTF-8 handling — goldens
   first (W0), legacy loops kept verbatim.
2. **Conservative widening = "ASCII in ⇒ UTF-8 out" wherever provable.**
   `toStdU16String` remains the universal fallback; the W0 counters tell us
   if any remaining widen matters in practice.
3. **One implementation per operation.** W1 deletes the dead duplicate.
4. **Observability before optimization** (W0 lands first).
5. **All creation sites honor `utf8_strings_enabled`**; new producers get
   added to HEAP_028's site list.
6. **GC discipline**: every new arm follows the existing patterns —
   *wrap source → StackRootGuard → allocate → re-resolve → copy*, or Pattern-B
   `eco_alloc_with_roots(roots[])` where the site already uses it. `utf8Bytes`
   pointers are invalid after any allocation; never hold one across an alloc.

### BB-1: `tryMakeAsciiString` — the ingestion gate (new, W2)

Layering fact (verified): `StringOps.hpp` includes `HeapHelpers.hpp`
(`StringOps.hpp:21`), never the reverse — so `allocStringFromUTF8` (inline in
`HeapHelpers.hpp`) cannot include `StringOps.hpp`. Use a forward declaration;
the definition lives in `StringOps.cpp` (which is linked into every target
that uses the allocator — single tree, verified: only
`runtime/src/allocator/StringOps.cpp` exists).

```cpp
// HeapHelpers.hpp, immediately after the #include block (:53-62):
namespace Elm { namespace StringOps {
// Defined in StringOps.cpp (layering: StringOps.hpp includes this header, so
// it cannot be included from here). If `data[0..len)` is all-ASCII and UTF-8
// strings are enabled, builds a Tag_StringUtf8Leaf (small) or
// ByteBuffer+Tag_StringUtf8View (>= LOT) and returns true. `data` must be
// C-heap memory (not a GC payload) — it is read after allocations.
bool tryMakeAsciiString(const char* data, size_t len, HPointer* out);
}}
```

```cpp
// StringOps.cpp, next to makeUtf8LeafFromBytes (:127):
bool tryMakeAsciiString(const char* data, size_t len, HPointer* out) {
    auto& allocator = Allocator::instance();
    if (!allocator.getConfig().utf8_strings_enabled) return false;
    if (len == 0 || len > 0xFFFFFFFFull) return false;   // empty handled by caller
    const u8* bytes = reinterpret_cast<const u8*>(data);
    if (!Utf8::allAscii(bytes, len)) return false;  // all-ASCII => valid UTF-8 (Utf8.hpp:104)
    size_t leafSize = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~7;
    if (leafSize < allocator.getLargeObjectThreshold()) {
        *out = makeUtf8LeafFromBytes(bytes, static_cast<u32>(len));
        return true;
    }
    // Large ASCII: leaf would widen (see :142-150). Copy into a ByteBuffer
    // (routes >= LOT to the pinned split-header form) + whole-buffer view.
    // `data` is C-heap, so it is stable across the buffer allocation.
    HPointer buf = alloc::allocByteBuffer(bytes, len);
    *out = makeUtf8View(buf, 0, static_cast<u32>(len));  // roots buf internally
    return true;
}
```

Use `Utf8::allAscii` (`Utf8.hpp:104-112`), not full `scan` — all-ASCII input
is trivially valid UTF-8, and the lenient legacy decoder differences only
matter for non-ASCII bytes, which `allAscii` rejects.

### BB-2: `AsciiOut` — the ASCII output builder (new, W4.a)

Every GAP-3 transform needs "allocate an ASCII result of `len` bytes, write
bytes, done" with the LOT split handled. One helper pair, defined entirely in
StringOps (leaf arm mirrors `makeUtf8LeafFromBytes` minus the copy; buffer arm
reuses `allocByteBufferBlank`):

```cpp
// StringOps.hpp (declare BEFORE append, ~:450); definitions in StringOps.cpp.
//
// ASCII result buffer. Contract: caller has checked utf8_strings_enabled and
// len > 0; caller writes exactly `len` ASCII bytes to `dst` BEFORE any other
// allocation on this thread (leaf payloads and sub-LOT buffers move on minor
// GC; >= LOT buffer bodies are pinned — but keep the uniform discipline);
// then calls finishAsciiOut, after which dst is invalid.
struct AsciiOut {
    HPointer hp;     // the leaf itself, or the backing ByteBuffer
    u8* dst;
    u32 len;
    bool isLeaf;
};
AsciiOut allocAsciiOut(size_t len);
// isLeaf: returns hp. Buffer: makeUtf8View(hp, 0, len) — allocates, hence
// "after writing". Under ECO_HEAP_VALIDATE asserts every byte < 0x80.
HPointer finishAsciiOut(const AsciiOut& out);
```

```cpp
// StringOps.cpp:
AsciiOut allocAsciiOut(size_t len) {
    auto& allocator = Allocator::instance();
    size_t leafSize = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~7;
    if (leafSize < allocator.getLargeObjectThreshold()) {
        ElmStringUtf8Leaf* leaf = static_cast<ElmStringUtf8Leaf*>(
            eco_alloc_with_roots(Tag_StringUtf8Leaf, leafSize, nullptr, 0, 0));
        leaf->header.size = static_cast<u32>(len);
        return {allocator.wrap(leaf), leaf->bytes, static_cast<u32>(len), true};
    }
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(len);
    return {bb.hp, bb.bytes, static_cast<u32>(len), false};
}
HPointer finishAsciiOut(const AsciiOut& out) {
#if ECO_HEAP_VALIDATE
    for (u32 i = 0; i < out.len; ++i)
        assert(!(out.dst[i] & 0x80) && "AsciiOut result must be all-ASCII");
#endif
    if (out.isLeaf) return out.hp;
    return makeUtf8View(out.hp, 0, out.len);
}
```

### P-B: the or-accumulate pattern (kernel map/filter, W4.e)

When output chars are *computed* (arbitrary closure results), ASCII-ness is
discovered, not proven: accumulate `acc |= c` while building the `vector<u16>`
result (already C-heap-snapshotted in these exports), then choose the
representation at materialization:

```cpp
if (utf8Enabled && !result.empty() && acc < 0x80) {
    AsciiOut out = allocAsciiOut(result.size());   // result is C-heap: no roots needed
    for (size_t i = 0; i < result.size(); ++i) out.dst[i] = static_cast<u8>(result[i]);
    return finishAsciiOut(out);
}
return alloc::allocString(result.data(), result.size());
```

Bonus: this yields UTF-8 outputs even from UTF-16 inputs when the result
happens to be ASCII. Representation-blind value tests already guard this (the
BFOPS_018 "compare values, never forms" rule).

## 4. Milestones

Protocol for every milestone: implement → `cmake --build build --target full
2>&1 | tee /tmp/test_output.txt` (run ONCE; grep the file) → E2E and elm-tests
never concurrently (cache race — memory: e2e-unit cache race). GC-stress
configs via `pressureHeapConfig()` (`test/allocator/TestHelpers.cpp:64-88`);
heap-validate tripwires need the `-DECO_HEAP_VALIDATE=ON` CMake configuration
(`/work/CMakeLists.txt:84-88`) — compile-time, not per-test.

---

### W0 — Observability, goldens, baselines (no behavior change)

**W0.1 Widen counters.** Follow the existing trampoline pattern exactly
(`recordStringAllocOnCurrentThread`, `GCStats.cpp:424-433`; macro shape
`GCStats.hpp:588-590`; gated by `ENABLE_GC_STATS`, CMake option `ECO_GC_STATS`
default ON for non-Release, `/work/CMakeLists.txt:107-116`):

1. `GCStats.hpp`: add fields `uint64_t utf8_widen_calls = 0;` and
   `uint64_t utf8_widen_units = 0;` + a `GC_STATS_UTF8_WIDEN(n)` macro +
   trampoline `recordUtf8WidenOnCurrentThread(u32 units)` in `GCStats.cpp`.
2. Increment at exactly two sites:
   - the UTF-8 arm of `toStdU16String` (`StringOps.hpp`, the
     `utf8Bytes`+`widenAscii` branch) — the single transient-widen chokepoint
     (covers foldl/split/trim/lines/… fallbacks);
   - the UTF-8 arm of `maybeFlattenOrRebalance` (`StringOps.cpp:199-204`) —
     the heap-object widen (`ensureFlat` backstop).
   Known blind spot, accepted: the `forEachSegment` wrapper's 512-unit
   chunked widen (`StringOps.hpp:355-364`) is not counted.
3. Wire one line each into `combine()` (`GCStats.cpp:651`), `print()`
   (`:807`; add to the string section near `:919-921`), `reset()` (`:1336`).
4. E2E-fork visibility (optional, do it — it's 4 small edits): add both
   fields to `ElmSharedTestResult` and to `copyStatsToShared` /
   `accumulateFromShared` (`test/ElmE2ETestBase.hpp:79-255`). Without this
   the counters only reflect in-process (unit-test) work in the final banner.

**W0.2 Golden-capture invalid-UTF-8 decode behavior.** Today NOTHING pins the
live export's behavior on invalid input (verified: `Utf8Test.cpp:125-152`
covers `Utf8::scan` only; `test/elm-bytes/src/` has no invalid-byte decode
test). Before touching the export:
- C++ unit `test/allocator/BytesDecodeGoldenTest.{cpp,hpp}` (register per
  §W6.0): call `Elm_Kernel_Bytes_read_string(len, wrap(buf), off)` directly on
  the invalid-vector battery from `Utf8Test.cpp:125-152` (bare continuation,
  truncated 2/3/4-byte at end, overlong C0 80 / E0 80 80 / F0 80 80 80,
  surrogate ED A0 80, F4 90 80 80, stray 0x80..0xBF) **plus** truncated
  sequences that read past `length` (the known quirk — pin it). For each:
  run once on the CURRENT build, record `(header.size, charAt(0..n))` into the
  test as expected values. These are bug-compatibility goldens, not "correct"
  values.
- E2E `test/elm-bytes/src/DecodeStringInvalidUtf8Test.elm` with `-- CHECK:`
  lines (harness conventions in §W6.0) for the decode-of-invalid length +
  round-trip observable behavior.

**W0.3 Baselines.** Stage 7a ~237 s is already recorded
(`frontendstats.txt`). Record `GC stats → Mutator Allocations by Object Kind`
from one self-compile (the AOT exit banner, `eco_entry.cpp:167`) as the
representation-mix baseline: expect `String` dominant, `StringUtf8*` near
zero on the parse path today.

**Exit:** counters visible in stats dump; goldens committed and green against
the unmodified export; suite green (`--target check` is enough here —
C++-only).

---

### W1 — Wire `Bytes.Decode.string` (kill GAP-1)

**File:** `elm-kernel-cpp/src/bytes/BytesExports.cpp` (already includes
`allocator/StringOps.hpp` at `:10`, which includes `Utf8.hpp` — no new
includes needed).

**W1.1** In `Elm_Kernel_Bytes_read_string` (`:588`), insert the gate after the
existing `srcHP`/`src_view`/`src` setup (`:603-605`) and before the
unit-count loop (`:607`):

```cpp
    // UTF-8 fast path (HEAP_028): a strictly-valid all-ASCII payload becomes
    // a zero-copy view over the source buffer (>= utf8_view_min_len) or a
    // small UTF-8 leaf — no transcode, no UTF-16 allocation. Non-ASCII or
    // invalid input falls through to the legacy two-pass decode below,
    // byte-for-byte unchanged (W0 goldens).
    const auto& cfg = allocator.getConfig();
    if (cfg.utf8_strings_enabled) {
        Elm::Utf8::ScanResult scan =
            Elm::Utf8::scan(src, static_cast<size_t>(length));
        if (scan.valid && scan.ascii) {
            HPointer result;
            if (static_cast<size_t>(length) >= cfg.utf8_view_min_len) {
                // makeUtf8View collapses a Tag_ByteBufferSlice base into
                // base + inner.offset itself (StringOps.cpp:100-112), which
                // matches byteBufferView's data pointer (HeapHelpers.hpp:1609
                // returns bytes + slc->offset) — offsets stay consistent for
                // buffer, slice, and large-header sources.
                result = Elm::StringOps::makeUtf8View(
                    srcHP, static_cast<u32>(offset), static_cast<u32>(length));
            } else {
                result = Elm::StringOps::makeUtf8LeafFromBytes(
                    src, static_cast<u32>(length));
            }
            return HPtr::fromBits(makeTuple2_ip(offset + length, result));
        }
    }
```

Notes an implementer needs:
- The scan runs on `src` before any allocation — pointer stable (same
  argument the existing count loop relies on, comment `:600-602`).
- Keep the live export's conventions exactly: bare-tuple return, `length==0`
  early-return at `:596-598` (stays above the gate), **no** bounds check.
- `makeUtf8LeafFromBytes` snapshots `src` to the C stack before allocating
  (`StringOps.cpp:152-154`) — no rooting needed at this call site.
- Do NOT reuse `scan.utf16Units` for the legacy path — the legacy count loop
  (`:607-625`) is non-validating and must keep its exact behavior.

**W1.2** Delete the dead `Elm::Kernel::Bytes::read_string`
(`Bytes.cpp:249-339`) and its declaration (`Bytes.hpp:64`). Its logic now
lives (adapted) in the export; two implementations invite re-drift. Check for
stragglers: `grep -rn "Bytes::read_string" elm-kernel-cpp runtime` must
return nothing.

**W1.3** The fused decode (`elm_utf8_decode`, `ElmBytesRuntime.cpp`) is
deliberately unchanged — it receives a raw `const u8*` with no base HPointer.
Fused vs interpreted decodes now produce different *representations* of equal
values; all tests compare values, never forms.

**Tests (specifics in §W6):**
- C++ unit `BytesDecodeReprTest`: representation as a function of
  (validity, ascii, length): ASCII ≥ 32 → `Tag_StringUtf8View` (assert
  `alloc::getTag(rz(hp))`), ASCII < 32 → `Tag_StringUtf8Leaf`,
  non-ASCII/invalid → `Tag_String`; decode from a `Tag_ByteBufferSlice`
  source and from a ≥ LOT (`Tag_LargeByteHeader`) source; W0 goldens still
  green (unchanged expected values); GC-stress decode loop under
  `pressureHeapConfig()`.
- E2E: `test/elm-bytes/src/` decode matrix (§W6.1).
- **Second-order check:** artifact loading now yields UTF-8 forms for
  persisted names — run a full self-compile.

**Exit:** `--target full` green incl. `TEST_FILTER=elm` and
`TEST_FILTER=codegen`; self-compile GC stats show `StringUtf8View/Leaf`
allocations from artifact loads.

---

### W2 — Kernel ingestion produces UTF-8 (kill GAP-2)

**W2.1** Add BB-1 (`tryMakeAsciiString` forward decl in `HeapHelpers.hpp`,
definition in `StringOps.cpp`) exactly as specced in §3.

**W2.2** In `allocStringFromUTF8` (`HeapHelpers.hpp:490`), after the empty
check (`:491-493`):

```cpp
    // ASCII fast path (HEAP_028): produce a UTF-8 form instead of widening.
    {
        HPointer asciiOut;
        if (StringOps::tryMakeAsciiString(utf8.data(), utf8.size(), &asciiOut))
            return asciiOut;
    }
    // Non-ASCII / invalid: legacy lenient transcode below, byte-for-byte.
```

The lenient decode loop (`:499-543`) stays verbatim. Every consumer —
`File.readString`, `Console`, `Env`, `Http`, ports — flips to UTF-8-for-ASCII
with zero call-site changes.

**W2.3** Invariants and docs:
- Update HEAP_028 (`invariants.csv:561`): add `allocStringFromUTF8` (and, at
  W1, the live-export site) to the producer list; note the large-ASCII
  buffer+view arm.
- Update the `Heap.hpp:103-108` "Produced only by…" comment likewise.
- Drive-by (careful): `invariants.csv` has **two** rows labeled `HEAP_028` —
  `:561` (Utf8StringRepresentation) and `:562` (PointerIsAddress). Renumber
  the PointerIsAddress row to a free ID and fix its references — HEAP_030
  (`:564`) and HEAP_031 (`:565`) cite "HEAP_028" *meaning PointerIsAddress*;
  update those two rows' text to the new ID.

**Tests:**
- C++ unit on `allocStringFromUTF8` (extend `Utf8StringTest.cpp`):
  ascii-small → leaf; ascii with `len` straddling the LOT leaf boundary
  (`8192 - sizeof(ElmStringUtf8Leaf)` ± 8) → leaf vs buffer+view; non-ASCII
  and invalid-UTF-8 inputs → `Tag_String` with content equal to the legacy
  twin (the lenient decoder's skip-invalid behavior — differential against
  a copy of the old expected outputs); kill switch off → `Tag_String`.
- E2E (`test/elm/` or `test/eco-kernel/` per §W6.0 conventions): file read →
  String-op chain; env-var round-trip; large (> 8 KiB) ASCII file read
  compared against a literal twin; a non-ASCII file read unchanged.
- **Bootstrap**: `cmake --build build --target bootstrap` — every source
  file, path, and env string now flows through the gate; Stage 4b + 8c fixed
  points and byte-identical MLIR (11,698,078 B) are the strongest available
  differential test.

**Exit:** suite + bootstrap green; self-compile GC stats now show
`StringUtf8View/Leaf` dominating source ingestion; `utf8_widen_calls` during
a parse-heavy run near zero (the parser narrow path is live).

---

### W3 — `File.readString` drops the intermediate `std::string` (perf polish; optional, after W2)

**File:** `eco-kernel-cpp/src/eco/File.cpp`, `readStringBody` (`:82-98`).

Today: `ostringstream → std::string` (copy 1) → W2 gate copies into
leaf/buffer (copy 2). Reshape to the `readBytesBody` pattern (`:100-118`) but
read **directly into a blank buffer**:

```cpp
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) { ... failErrno as today ... }
    auto size = static_cast<size_t>(file.tellg());
    file.seekg(0, std::ios::beg);
    if (size == 0) return succeedString("");        // empty → Const_Empty
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(size);
    HPointer bufHp = bb.hp;
    file.read(reinterpret_cast<char*>(bb.bytes), size);   // no Elm alloc between blank+read
    if (!file || static_cast<size_t>(file.gcount()) != size) { ... failErrno ... }
    const auto& cfg = Elm::Allocator::instance().getConfig();
    if (cfg.utf8_strings_enabled && Elm::Utf8::allAscii(bb.bytes, size)) {
        return succeed(Elm::StringOps::makeUtf8View(bufHp, 0, static_cast<u32>(size)));
    }
    // Non-ASCII: legacy lenient transcode (one extra copy, non-ASCII files only).
    return succeedString(std::string(reinterpret_cast<const char*>(bb.bytes), size));
```

Safety notes: nothing allocates between `allocByteBufferBlank` and the last
byte read (BlankByteBuffer contract, `HeapHelpers.hpp:921-926`); binding
bodies run on the mutator thread, no concurrent Elm allocation.
`succeed(HPointer)` is `TaskBinding.hpp:44`. Text-vs-binary mode: today's
reader uses text mode — on Linux they are identical; keep `std::ios::binary`
and note it. The wasted buffer on the non-ASCII path becomes garbage — fine.
mmap for very large files: W7 only.

**Exit:** suite green; representation identical to W2; one fewer full copy
per ASCII file read.

---

### W4 — Conservative widening (kill GAP-3)

W4.a is a prerequisite; b–g are independent, each landable alone. Every item
gates on `Allocator::instance().getConfig().utf8_strings_enabled` (directly
or through `allocAsciiOut` callers' checks) plus the stated input condition,
and places its arm AFTER the existing hot UTF-16 cases. Tests per item: §W6.2.

**W4.a Shared builder + narrow fix.**
- Add `AsciiOut` / `allocAsciiOut` / `finishAsciiOut` (§3 BB-2) to
  `StringOps.{hpp,cpp}` — declared before `append` (~`hpp:450`).
- `narrowAsciiToStack` (`hpp:953`) — fixes `toInt`/`toFloat` in one place;
  bytes are ASCII by HEAP_028, so no per-char check:
```cpp
    if (isUtf8(str)) {
        auto pr = utf8Bytes(str);
        if (pr.second > cap) return false;
        std::memcpy(buf, pr.first, pr.second);
        *out_len = pr.second;
        return true;
    }
```

**W4.b `append` / `concat` / `join` byte-concat.**
- `append` (`hpp:453`): before the flatten branch (`:466`):
```cpp
    if (isUtf8(a) && isUtf8(b) &&
        Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer aHp = allocator.wrap(a), bHp = allocator.wrap(b);
        AsciiOut out;
        { Elm::StackRootGuard g(&aHp, &bHp); out = allocAsciiOut(total_len); }
        auto pa = utf8Bytes(allocator.resolve(aHp));   // re-resolve after alloc
        auto pb = utf8Bytes(allocator.resolve(bHp));
        std::memcpy(out.dst, pa.first, pa.second);
        std::memcpy(out.dst + pa.second, pb.first, pb.second);
        return finishAsciiOut(out);
    }
```
  Apply only when `total_len <= string_flatten_limit` (place inside that
  branch); the rope path (`> limit`) already shares UTF-8 children unchanged.
  (Two-arg `StackRootGuard` exists — see `StringExports.cpp:308`.)
- `concat` (`cpp:461`): in pass 1 (`:466-482`), track
  `bool allUtf8 = true` (`if (strObj && !isUtf8(strObj)) allUtf8 = false;` —
  empty heads are skipped and don't affect it). In the flatten branch
  (`:490+`): if `allUtf8 && enabled`, mirror the existing Pattern-B rooted
  walk but into `allocAsciiOut(total_len)`: root `stringList` across the
  alloc (same `roots[1]` dance as `:496-500`), then walk copying
  `utf8Bytes(element)` — the walk itself does not allocate; `finishAsciiOut`
  runs after the walk.
- `join` (`cpp:551`): same, with the extra condition
  `sep_len == 0 || isUtf8(sepObj)`, rooting `sepHp` alongside (the site
  already uses `roots[2]`).

**W4.c `trim*` scans + `lines`/`words`.**
- `trim`/`trimLeft`/`trimRight` (`hpp:782`/`:807`/`:827`): outputs already
  UTF-8 via `slice()`. Replace only the scan: for `isUtf8(str)`, scan
  `utf8Bytes(str)` bytes in place (no allocation happens before the final
  `slice` call, so the pointer is stable); else keep the `toStdU16String`
  snapshot. ASCII whitespace set is unchanged (UTF-8 forms cannot contain
  U+00A0 etc. by the gate).
- `lines` / `words` (`elm-kernel-cpp/src/core/String.cpp`; locate with
  `grep -n "HPointer lines\|HPointer words"`): add an `isUtf8` arm:
  - Phase 1: compute `LineRange`s over `utf8Bytes` in place (scan only, no
    allocation).
  - Phase 2: instead of `alloc::allocString(strData + start, len)` parts,
    produce parts via `StringOps::slice(allocator.resolve(srcHp), start,
    start + len)` with `srcHp` wrapped and rooted in the same
    `pushStackRootRange` block that already roots `parts` — re-resolve
    `srcHp` each iteration (each `slice` may GC). Parts come out as UTF-8
    tiny-leaves (≤ 128) or views — no widen, no UTF-16 copies.
  - `words`: `StringOps::trim` already returns UTF-8 for UTF-8 input; apply
    the same arm to the trimmed string.

**W4.d Byte transforms (`toUpper`/`toLower`/`reverse`/`repeat`/`pad*`/`filter`).**
All follow one template — shown for `toUpper` (`hpp:706`); the others differ
only in the byte loop:
```cpp
    if (isUtf8(str) && Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        HPointer srcHp = allocator.wrap(str);
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(len); }
        auto pr = utf8Bytes(allocator.resolve(srcHp));
        for (u32 i = 0; i < len; ++i) {
            u8 c = pr.first[i];
            out.dst[i] = (c >= 'a' && c <= 'z') ? c - 32 : c;
        }
        return finishAsciiOut(out);
    }
```
- `toLower` (`:731`): `'A'..'Z' → +32`.
- `reverse` (`:754`): `out.dst[i] = pr.first[len-1-i]`.
- `repeat` (`:847`): copy once + `memcpy`-forward the byte prefix (mirror the
  existing u16 version).
- `padLeft`/`padRight` (`:874`/`:903`): additional gate `padChar < 0x80`;
  byte fill + copy. (The `!str` all-padding case: also emit a UTF-8 leaf when
  `padChar < 0x80 && enabled` — trivial arm.)
- `filter` (C-pred variant, `cpp:886`): count pass over bytes
  (`pred(static_cast<u16>(b))`), then write pass into `allocAsciiOut(kept)`;
  keep the existing shortcuts (`kept==0 → empty`); extend the identity
  shortcut: `kept == len → return allocator.wrap(resolve(srcHp))` (safe —
  strings are immutable; today's code restricts this to `isLeaf`, the UTF-8
  arm may return any UTF-8 form unchanged).

**W4.e Kernel closure exports (`StringExports.cpp`).**
- Add beside `snapshotChars` (`:223`):
```cpp
// Byte snapshot for UTF-8 forms; empty + false if str is not a UTF-8 form.
// The vector is C-heap: stable across closure calls that allocate/GC.
static bool snapshotBytes(void* str, std::vector<u8>& out) {
    if (!str || !Elm::StringOps::isUtf8(str)) return false;
    auto pr = Elm::StringOps::utf8Bytes(str);
    out.assign(pr.first, pr.first + pr.second);
    return true;
}
```
- `foldl`/`foldr`/`any`/`all` (`:302`/`:318`/`:265`/`:283`): branch on
  `snapshotBytes` → iterate bytes, passing `static_cast<u16>(b)` to the
  existing `callFoldClosure`/`callCharToBoolClosure`; else `snapshotChars`
  as today. Halves snapshot memory, removes the widen; rooting unchanged.
- `map` (`:229`) / `filter` (`:247`): source via `snapshotBytes`-or-
  `snapshotChars`; build `std::vector<u16> result` exactly as today but
  accumulate `u16 acc = 0; ... acc |= c;`, then materialize via P-B (§3).
- Same treatment for the `FoldFunc` variants in
  `elm-kernel-cpp/src/core/String.cpp:114-141` and the C-fn
  `StringOps::foldl/foldr` (`StringOps.cpp:920-937`): snapshot
  `std::vector<u8>` instead of `std::u16string` when `isUtf8` (the fold
  callback may allocate — never iterate heap payloads directly here).

**W4.f `split` + `indexes` byte search.**
- `split` (`cpp:715`): when `isUtf8(str) && sep && isUtf8(sep) && enabled`
  (the `sep_len == 0` → `toList` and empty-string cases stay above):
  - Phase 1: run the existing BMH/naive search structure (`:740-774`) over
    `utf8Bytes(str)` / `utf8Bytes(sep)` as `u8` (drop the `& 0xFF` — bytes
    already index the 256-entry table); collect `splitPositions`. No
    allocation during phase 1 → in-place pointers are stable.
  - Phase 2: replace the `alloc::allocString(strData + …)` part-building
    (`:784-791`) with `StringOps::slice(allocator.resolve(srcHp), start,
    end)` under the existing root-range block, `srcHp` rooted alongside
    `parts`, re-resolved per iteration. Mixed encodings (UTF-8 haystack,
    UTF-16 sep or vice versa) → legacy path; add a test for both mixes.
- `indexes` (`cpp:658`): when both `isUtf8` → same byte BMH; output is a
  list of ints (no representation concern; this only kills the widen).

**W4.g Optional (do last, or defer to W7):** `toList` (`cpp:795`) single-char
UTF-8 leaves for ASCII chars; `String::fromList`/`cons` P-B arms;
`StringOps::map` (C-fn variant, `cpp:865`) — the kernel-export map (W4.e)
covers Elm `String.map`; leave the C-fn variant UTF-16 unless a caller shows
up in profiles.

**Exit (W4 overall):** suite green; `utf8_widen_calls/units` ~0 on an
all-ASCII String-op stress E2E; string perf non-regressed for UTF-16 inputs
(watch the added tag checks — arms are placed after hot cases), improved for
UTF-8 inputs.

---

### W5 — Parser + self-compile validation, timing

1. **E2E linearity**: `test/elm-parser/src/` (or `test/elm/`) module that
   builds a large (≥ 256 KiB) ASCII pseudo-source via decode/file read and
   runs parser-shaped consumption (the elm-parser E2E package exercises
   `Compiler.Parse` externs). Assert outputs via `-- CHECK:`; wall-time
   sanity is observed, not asserted (the harness has no timing assertions —
   keep it that way; the Stage 7a run below is the timing gate).
2. **Non-ASCII source regression**: a module with astral chars in literals +
   comments parses byte-identically (UTF-16 whole-file fallback).
3. **Full bootstrap**: Stage 4b (JS) and Stage 8c (native) fixed points +
   MLIR byte-identity (11,698,078 B). The JS build has no UTF-8 forms, so
   the fixed points are the definitive representation-blindness check.
4. **Counters, manually**: run one self-compile with the stats banner
   (`eco_entry.cpp:167` prints at exit) and record: per-tag mix
   (`StringUtf8View/Leaf` should dominate string ingestion) and
   `utf8_widen_calls` (should be near zero; investigate any large residual —
   it names a missed W4 consumer).
5. **Stage 7a timing** per `frontendstats.txt` protocol (cold
   `build/compiler/build-kernel/eco-stuff` wiped immediately before each
   run, warm `~/.eco`, 4 samples, discard the first). Record a RUN LOG entry
   with time + peak RSS (baseline: ~237 s / 3.84 GiB) and the verdict.

**Exit:** all green; timing + memory recorded in `frontendstats.txt`.

---

### W6 — Test bolstering (cross-cutting; land each piece with the milestone it validates)

#### W6.0 Harness anatomy (reference — verified)

- **E2E Elm suites** (`test/elm-bytes/`, `test/elm-core/`, `test/elm/`, …):
  drop `FooTest.elm` with a `main` into `<pkg>/src/` — discovery is a runtime
  glob (`ElmE2ETestBase.hpp:1074-1106`), no registration, no reconfigure
  (`src` is symlinked into the build shadow, `test/CMakeLists.txt:15-43`).
  Assertions: `-- CHECK: <substr>` / `-- CHECK-NOT:` comment directives
  matched against captured stdout (`ElmE2ETestBase.hpp:355-359`); print via
  `Debug.log "Name" value` → `Name: value`. Each test forks
  (`:874-906`). `TEST_FILTER` is a case-sensitive substring of
  `<pkg>/<File>.elm` (`:1183`).
- **C++ allocator tests**: custom `Testing::TestCase` + rapidcheck.
  New file = `test/allocator/Foo{.cpp,.hpp}` with
  `void registerFooTests(Testing::TestSuite&)` + add to
  `add_executable(test ...)` (`test/CMakeLists.txt:98` area) + create/add the
  suite in `test/main.cpp` (`:730-731`, `:869` pattern). Helpers:
  `initAllocator([config])`, `pressureHeapConfig()`
  (`TestHelpers.cpp:13-24`, `:64-88`), `TEST_ASSERT`, `rc::check`.
  Representation assertions via `alloc::getTag(resolve(hp))` — precedent:
  `test_representation_tags` (`Utf8StringTest.cpp:267-288`). Crash-prone GC
  tests go in the fork-per-case `IsolatedTestRunner` suite
  (`main.cpp:790-815`).
- **Existing differential machinery to extend, not fork**:
  `Utf8StringTest.cpp` builders `makeU16`/`makeU8Leaf`/`makeU8View`
  (`:40-57`) and the forms-agree property (`:145-155`).

#### W6.1 elm/bytes E2E (with W1)

In `test/elm-bytes/src/` (one module per concern; `-- CHECK:` based):
- `DecodeStringReprMatrixTest.elm`: ASCII payloads of length 1, 31, 32, 33,
  200; assert value round-trips and op results (`length`, `slice`,
  `contains`, `==` against literal twins). (Representation itself is
  asserted in C++ — E2E stays representation-blind.)
- `DecodeStringNonAsciiTest.elm`: the §5a battery of the M-plan — 2-byte
  (é/ß/ñ/Cyrillic), 3-byte (中/€/U+FFFF), astral (😀 → `String.length == 2`),
  combining sequences, mostly-ASCII with one multibyte char at first/mid/last
  position; every case compared against literal twins.
- `DecodeStringInvalidUtf8Test.elm` (W0.2 golden).
- `DecodeStringSlicedSourceTest.elm`: decode after `Bytes.Decode.bytes`
  slicing (exercises the `Tag_ByteBufferSlice` collapse) and at nonzero
  offsets mid-buffer.
- `DecodeEncodeRoundTripTest.elm`: `Decode.string >> Encode.string` byte
  identity for ASCII, non-ASCII, astral; `getStringWidth` agreement.
- `DecodedStringAsKeyTest.elm`: `Dict`/`Set` keyed by decoded + literal +
  `String.fromInt` strings mixed; `case` dispatch on decoded strings.

#### W6.2 C++ differential + representation-aware (with W1/W2/W4)

Extend `test/allocator/Utf8StringTest.cpp`:
- New generators: decode-produced forms (call the live export), ingestion
  forms (`allocStringFromUTF8` post-W2, incl. the > LOT buffer+view arm) —
  add to the forms-agree battery.
- New **representation-asserting** section (separate from the blind value
  tests, which stay): for each W4 op, `op(utf8_input(s)) → getTag == leaf/view`
  and `op(utf16_input(s))` unchanged; the P-B ops additionally
  `map (always 'é')` over UTF-8 input → `Tag_String`.
- Mixed-operand: `append`/`split`/`join`/`equal`/`compare` with one UTF-8 and
  one UTF-16-ASCII operand in both orders → correct values (representation
  may be either; assert value only).
- GC-stress under `pressureHeapConfig()`: W4 outputs built in a churn loop,
  contents re-verified after forced `collectAtSafepoint()`; run in the
  isolated suite; exercise the `-DECO_HEAP_VALIDATE=ON` configuration in CI
  at least once per milestone (it enforces the all-ASCII invariant heap-wide).

#### W6.3 elm/core String E2E (with W2/W4)

In `test/elm-core/src/`:
- `StringCreationMatrixTest.elm`: build the same logical strings via literal /
  `fromInt` / `String.slice` of a literal / decode / `++` — full String API
  over each, all results printed and CHECKed identically (ASCII + non-ASCII
  variants).
- `StringOpChainSurvivalTest.elm`: `read/decode → split → map(toUpper-ish) →
  trim → join → case` chain — value assertions; (the "stayed UTF-8" property
  is checked by the C++ representation tests and the W5 counter run, not by
  E2E).
- `StringNonAsciiOpsTest.elm`: the W4 op list over non-ASCII strings —
  results must equal current behavior (these run the UTF-16 paths; guards the
  new arms' gating).

#### W6.4 Retention observability (with W1)

C++ test (isolated suite): decode many short (< 32 B) and several long
(≥ 32 B) strings from one large buffer; drop the buffer handle; root only the
decoded strings; force major GC; assert (a) short strings (leaves) survive
with content, (b) long strings (views) survive with content — and print the
per-tag alloc stats. There is **no live-bytes-by-tag census in GCStats**
(verified — allocation counts only, `GCStats.hpp:161-164`), so buffer
retention is asserted structurally: after GC, `utf8Bytes(view)` still
resolves — i.e., the base is alive. This is the observability hook for the
retention risk; a pass/fail memory bound is deliberately not asserted.

---

### W7 — Follow-ups (out of scope, noted)

`Http.expectString` → buffer+view (`HttpExports.cpp:411-436`); base-HPointer
threading through fused `bf.read_utf8`; `utf8_view_copyout_ratio` copy-out
heuristic if W6.4/self-compile shows pathological buffer pinning (add beside
`utf8_view_min_len`, `AllocatorCommon.hpp:361` + `HeapConfigJson.cpp:264`
plumbing); mmap large file reads; `toList`/`fromList`/`cons` ASCII arms;
`StringOps::map` C-fn variant; non-ASCII lifts (design doc §3.4 Choices
2b/3); content-dedup of interned literals; a live-bytes-by-tag GC census.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| **View retention pins base buffers** — post-W1, decoded ≥ 32 B strings are views into (possibly multi-MB) artifact buffers held for process lifetime | Same exposure class as existing `ByteBufferSlice`/`StringSlice` (accepted precedent with the min-len floor). W6.4 makes it observable; the W5 self-compile RSS measurement is the real gate — if RSS regresses, implement `utf8_view_copyout_ratio` (W7) as a fast follow. Measure before engineering. |
| Invalid-UTF-8 semantic drift when porting the gate | W0.2 goldens captured against the UNMODIFIED export first; legacy loops kept verbatim in W1/W2; `Utf8::allAscii` gate in W2 rejects every byte ≥ 0x80, so the lenient decoder is untouched for exactly the inputs where it does anything interesting |
| `AsciiOut` write-before-alloc GC hazard (new code class) | Single helper with an explicit contract mirroring `BlankString`/`BlankByteBuffer` (both established); `finishAsciiOut` VALIDATE-asserts ASCII; all call sites follow wrap→guard→alloc→re-resolve→write; GC-stress tests under `pressureHeapConfig()` + `ECO_HEAP_VALIDATE` config |
| A consumer assumes `Tag_String` after decode/ingestion (global representation shift) | The M1 read layer handles UTF-8 at every StringOps entry; `resolveStringBody`/`stringData` asserts backstop; bootstrap fixed points at W1/W2/W5; kill switch reverts the world via one config edit |
| `phase-2 slice`-based parts (`lines`/`words`/`split`) move the source mid-loop | Source `HPointer` rooted in the same stack-root-range as `parts`; re-resolved every iteration; only *positions* survive phase 1 (never raw pointers) |
| Kernel closure callbacks (map/filter/fold) allocate during iteration | Never iterate heap payloads across closure calls: byte snapshots into C-heap `std::vector<u8>` (mirrors the existing `snapshotChars` rationale, `StringExports.cpp:220-222`) |
| Perf regression on UTF-16-dominant workloads from added tag dispatch | Arms placed after existing hot cases; W4 exit re-checks string perf; the two counters are ENABLE_GC_STATS-gated |
| `Utf8::scan`/`allAscii` cost on every ingestion (W2) | Replaces an O(n) transcode with an O(n) scan for ASCII (strictly cheaper: no u16 alloc); adds one read pass for non-ASCII — if profiling objects, fuse the ASCII check into the legacy loop's first iteration instead |
| Duplicate `HEAP_028` id in invariants.csv | Renumber PointerIsAddress (`:562`) while editing; fix the two citing rows (HEAP_030 `:564`, HEAP_031 `:565`) |
| W0 counters invisible in E2E forks | `ElmSharedTestResult` marshaling additions (W0.1 step 4); per-tag arrays are known not to marshal — self-compile banner (in-process) is the primary read-out |
| Cache races / stale binaries | E2E + elm-tests serial; `--target full` at milestone exits; C++-only changes may use `--target check` inner-loop |

## 6. Landing order

**W0 → W1 → W2 → W4.a → W4.b/c/d/e/f (any order, independent) → W5**, with
W3 and W4.g trailing as perf polish, and W6 tests landing inside the
milestone they validate.

Rationale: W1 is the smallest diff and immediately benefits artifact loads
and user decodes while de-risking the representation shift; W2 is the parser
unlock; W4's items stop the decay routes so the W5 measurement reflects the
steady state; W3 only removes a copy and can trail.

## 7. Verification log (what was checked while writing this plan)

Re-run these to re-validate the plan against a drifted tree:

```
# The three gaps
grep -rn "Bytes::read_string" elm-kernel-cpp runtime          # dead impl + decl only
grep -n  "read_string" runtime/src/codegen/RuntimeSymbols.cpp # :921 binds the live export
grep -rn "ensureFlat" runtime/src elm-kernel-cpp/src eco-kernel-cpp/src \
    --include='*.cpp' --include='*.hpp'                       # parser is the only prod caller
grep -rn "allocStringFromUTF8" eco-kernel-cpp runtime | grep -v "\.elm"

# Layering / helpers the plan builds on
grep -n "#include" runtime/src/allocator/StringOps.hpp        # includes HeapHelpers (one-way)
grep -n "allocByteBufferBlank\|BlankByteBuffer" runtime/src/allocator/HeapHelpers.hpp
grep -n "UTF8_VIEW_MIN_LEN\|LARGE_OBJECT_THRESHOLD\|STRING_FLATTEN_LIMIT" \
    runtime/src/allocator/AllocatorCommon.hpp

# Widen sites (GAP-3 table)
grep -n "toStdU16String" runtime/src/allocator/StringOps.{hpp,cpp} \
    elm-kernel-cpp/src/core/String.cpp
grep -n "snapshotChars" elm-kernel-cpp/src/core/StringExports.cpp

# ASCII source-file share
T=$(find compiler/src -name '*.elm' | wc -l); \
N=$(grep -rlP '[^\x00-\x7F]' compiler/src --include='*.elm' | wc -l); \
echo "ascii-only: $((T-N))/$T"
```

Key facts an implementer should NOT have to re-derive: `makeUtf8View`
self-collapses slice/view bases and roots its base internally
(`StringOps.cpp:100-125`); `byteBufferView` returns slice-offset-adjusted
data pointers (`HeapHelpers.hpp:1609-1637`) — consistent with that collapse;
`makeUtf8LeafFromBytes` snapshots its input and enforces the kill switch +
LOT fallback internally (`StringOps.cpp:127-164`); `allocByteBufferBlank`
handles the ≥ LOT pinned-body split (`HeapHelpers.hpp:943-966`);
`Utf8::allAscii` is the cheap sufficient gate for ingestion
(`Utf8.hpp:104-112`); the live export's `srcHP` rooting pattern is at
`BytesExports.cpp:600-640`; `trim*` already produce UTF-8 outputs via
`slice()` — only their scans widen.
