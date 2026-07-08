# UTF-8 Second String Encoding — Investigation Report

*(Jul 7, 2026 — investigation only; no code changes)*

## 0. Scope and questions

Investigated: adding a second String encoding (UTF-8) alongside the existing
UTF-16 default. UTF-8 strings would be created when extracting a String from
Bytes, reading UTF-8 files, and at similar I/O boundaries. Three questions:

1. Can **identical results** to the UTF-16 semantics be derived from UTF-8
   encoded strings, for every core-lib String operation?
2. How would **automatic conversion** of the encoding at convenient boundaries
   work?
3. At the **String/Bytes seam**, can UTF-8 strings be slices onto Bytes (and
   Bytes encoders slices onto UTF-8 strings) to avoid copying?

Short answers: **(1) Yes — for every operation — with exactly two structural
caveats** (lone surrogates, and unit-index translation cost on non-ASCII
data; §3.4 analyzes the latter in depth — **DECIDED Jul 8, 2026: v1 gates
view creation on all-ASCII input**, where both caveats vanish); **(2) the runtime
already has the single decision point needed** (`maybeFlattenOrRebalance` +
`FlattenReason`), and the correct policy is *keep UTF-8 through
slice/append/search/stream, promote when transforms allocate* — but
`ensureFlat` promotion cannot be memoized (no GC write barrier), so per-call
consumers like the parser need explicit byte-path treatment (§3.4);
**(3) yes in both directions**, with all the required GC machinery already
proven by `Tag_ByteBufferSlice` and the pinned split-header bodies.

---

## 1. Current state (what exists today)

### 1.1 String heap forms (HEAP_025)

Four forms, all fronted by `Elm::StringOps` (`runtime/src/allocator/StringOps.{hpp,cpp}`),
tags in `runtime/src/allocator/Heap.hpp:76-105`:

| Tag | Struct | Size | Contents |
|---|---|---|---|
| `Tag_String` | `ElmString` (Heap.hpp:372) | 8 + 2·n | flat UTF-16 leaf, inline `u16 chars[]` |
| `Tag_StringSlice` | `ElmStringSlice` (Heap.hpp:386) | 24 | `HPointer base` + `u32 offset` + `u32 _padding` (reserved "all-ASCII bit") |
| `Tag_StringRope` | `ElmStringRope` (Heap.hpp:398) | 32 | `left`/`right` HPointers + `height` + `leafCount` |
| `Tag_LargeStringHeader` | `LargeStringHeader` (Heap.hpp:412) | 16 | nursery header → `Tag_String` body **pinned** in old gen (HEAP_026) |

**For all four forms `header.size` = logical UTF-16 code-unit count.** The
empty string is the embedded constant `Empty` (word `0x6`) and is never heap
allocated (REP_CONSTANT_001/003). String literals are emitted by codegen as
UTF-16 `[N x i16]` globals and allocated as permanent old-gen leaves
(`eco_alloc_string_literal`, RuntimeExports.cpp:414).

Access outside `StringOps`/`elm_utf8_*` is forbidden (HEAP_025, BFOPS_032).
The key internal APIs:

- `rawLen` — O(1) `header.size` read, any form.
- `charAt(str, i)` — tag-dispatched random access, allocation-free.
- `forEachSegment(str, cb)` — zero-alloc visitor, `cb(const u16*, u32)` per
  contiguous segment (StringOps.hpp:181). **The callback is u16-typed** —
  encoding-specific.
- `singleSegmentView` — `(ptr,len)` for leaf/slice/large, enabling `memcmp`.
- `toStdU16String` — flatten-to-C-stack, the universal materializer.
- `flattenToLeaf` / `ensureFlat` / `maybeFlattenOrRebalance(s, FlattenReason)` —
  the **single flatten decision point**; `FlattenReason` already includes a
  `Utf8Encode` member (StringOps.hpp:91-97).

Thresholds (AllocatorCommon.hpp:80-97): `STRING_FLATTEN_LIMIT` 32 Ki units,
`STRING_TINY_SLICE_LIMIT` 128 units, `LARGE_OBJECT_THRESHOLD` 8 KiB.

### 1.2 Char

`Char` is one UTF-16 code unit: `u16` in the heap (`ElmChar`, Heap.hpp:357),
`i16` in SSA/ABI (REP_ABI_001, CGEN_015). `Elm_Kernel_Char_fromCode` clamps to
`[0, 0xFFFF]` and `toCode` masks `& 0xFFFF` (CharExports.cpp:11-30) — **astral
code points do not exist at the Char level.** All Char-iteration String ops
(`foldl/foldr/map/filter/any/all/toList/uncons`) yield **surrogate halves** for
astral content, matching Elm 0.19/JS semantics. Case mapping is ASCII-only
(no ICU, no locale; `toLocaleUpper/Lower` fall back to the non-locale forms).

### 1.3 Bytes heap forms

Bytes already mirror the string structure (Heap.hpp:91-102, 420-442):
`Tag_ByteBuffer` (flat, `u8 bytes[]`, `header.size` = byte count),
`Tag_ByteBufferSlice` (24 bytes: `base` + `u32 offset`; slice-of-slice
collapses; slices shorter than `MAKE_BYTEBUFFER_SLICE_MIN_LEN = 32` are
copied instead — HeapHelpers.hpp:1639), and `Tag_LargeByteHeader` (pinned
old-gen body, HEAP_026). All readers go through
`byteBufferView`/`byteBufferLength` (HeapHelpers.hpp:999-1037, 1603-1623),
which resolve every form uniformly.

### 1.4 Existing UTF-8 machinery — duplicated and inconsistent

UTF-8 exists only as convert-on-the-fly at edges, duplicated across **six**
sites with **three different validation strictnesses**:

| Routine | Site | Validation |
|---|---|---|
| `elm_utf8_decode` (fusion ABI) | ElmBytesRuntime.cpp:208 | **strict** — rejects overlong, surrogate range, > U+10FFFF |
| `BytesOps::decodeUtf8` | BytesOps.cpp:91 | structural only (continuation bytes, truncation) |
| `read_string` (**the actual `Bytes.Decode.string` path**) | elm-kernel-cpp/src/bytes/Bytes.cpp:247 | **none — garbage in, garbage units out** |
| `allocStringFromUTF8` (HTTP/ports/JSON ingest) | HeapHelpers.hpp:490 | lenient — skips invalid lead bytes |
| encoders: `elm_utf8_copy`, `BytesOps::encodeUtf8`, `writeEncoder ENC_UTF8`, `toStdString` | 4 sites | n/a — lone surrogates emitted as 3-byte **WTF-8** sequences |
| width counters: `elm_utf8_width`, `Bytes::getStringWidth`, `BytesExports getStringWidth` | 3 sites | n/a — lone surrogate counted as 3 bytes (consistent with encoders) |

Two facts here matter enormously for the design:

- **`elm_utf8_decode`'s validation pass already counts UTF-16 code units**
  (ElmBytesRuntime.cpp:212-250) before it copies anything. Validation is
  unavoidable for a trusted in-heap form — and it yields the logical length
  for free.
- The encode side is **WTF-8 in practice** (lone surrogates → 3-byte
  sequences), and the widths agree with the emitters. Strict UTF-8 cannot
  represent lone surrogates; this is the one place UTF-16 strings can hold
  states a UTF-8 form cannot.

### 1.5 Boundary crossings today (all copy + transcode)

- **JSON** (`JsonExports.cpp`): every string through `toStdString` /
  `allocStringFromUTF8` — nlohmann works in UTF-8 `std::string`.
- **Ports** (`PortRuntime.cpp:61-65, 414-418`) and the node addon
  (`napi_*_string_utf8`): UTF-8 on the wire.
- **HTTP** (`HttpExports.cpp:411-436`): `expectString` bodies →
  `allocStringFromUTF8` (transcode+copy); `arraybuffer` bodies → raw
  `ByteBuffer` memcpy (already transcode-free).
- **File I/O**: not built yet (`file/File.cpp` is a stub; filesystem goes via
  the Task/port bridge) — a greenfield for the UTF-8 form.
- **Bytes fusion** (`bf` dialect): `bf.width` → `elm_utf8_width` (O(n) walk),
  `bf.write_utf8` → `elm_utf8_copy`, `bf.read_utf8` → `elm_utf8_decode`. These
  runtime helpers are the single funnel — tag-dispatching them upgrades the
  fused path with **no compiler changes**.

### 1.6 GC mechanics available for reuse

No GC object ever stores an interior pointer: slices hold
`(HPointer base, u32 offset)` and payload addresses are computed on demand.
The three GC phases handle slices by tracing only `base`
(NurserySpace.cpp:1665-1675, OldGenSpace.cpp:1710-1714, 3958-3962); `offset`
survives relocation as a scalar. Large bodies are pinned (`header.pin=1`) and
never move; slice-of-large deliberately points `base` at the *header*, not the
body, to keep the nursery-owned-body lifetime tracking correct
(StringOps.cpp:244-255). A UTF-8 view is byte-for-byte this same pattern.

---

## 2. The pivotal design decision: keep `header.size` = UTF-16 units

The user-visible semantics of `String.length`, `slice`, `indexes`, `pad*` are
defined in UTF-16 code units. The naive fear — "length over UTF-8 is O(n)" —
dissolves once you notice the creation path *must* validate the bytes anyway,
and validation counts UTF-16 units as a byproduct:

> **Proposed invariant (extends HEAP_025):** every string form, including the
> UTF-8 form, stores the logical UTF-16 code-unit count in `header.size`.
> The UTF-8 form additionally stores its byte length.

Consequences:

- `String.length` stays **O(1)** on UTF-8 strings. No conversion needed, ever,
  for a size call.
- `byteLen == header.size` ⇔ the string is **all-ASCII** (1 byte = 1 unit).
  This is a free flag: on ASCII data, *every* index-based operation is O(1)
  byte arithmetic and every operation has identical semantics byte-wise. No
  `_padding` bit needed — it falls out of the two lengths.
- `REP_CONSTANT_003` (Empty compares EQ to any `header.size == 0` string)
  keeps working unchanged (and zero-length UTF-8 results canonicalize to the
  `Empty` constant like every other form).
- Rope accounting (`header.size = leftLen + rightLen`) is encoding-independent,
  so **ropes can mix UTF-8 and UTF-16 children** with no changes to `makeRope`.

### 2.1 Proposed representation

```c
// Tag_StringUtf8 — validated-UTF-8 view over a byte buffer.  24 bytes.
struct ALIGN(8) elm_string_utf8 {
    Header header;   // header.size = logical UTF-16 code-unit count
    HPointer base;   // -> Tag_ByteBuffer or Tag_LargeByteHeader
    u32 offset;      // byte offset into base's payload
    u32 byteLen;     // byte length; byteLen == header.size  <=>  all-ASCII
};
```

- Same shape as `ElmByteBufferSlice` / `ElmStringSlice`; `header.unboxed = 0`;
  GC traces only `base` — copy the three slice arms verbatim.
- **Contents are strictly valid UTF-8** (validated at creation). This is a
  hard invariant: it is what makes `charAt`/iteration/compare well-defined and
  is what a zero-copy view *buys* with its mandatory validation pass.
- **v1 additionally gates creation on all-ASCII** (`byteLen == header.size`;
  §3.4) so that unit indices are byte offsets and no lone-surrogate state is
  reachable. The struct is deliberately *not* ASCII-specific — lifting the
  gate later (Choice 2b/3) changes creation policy, not layout.
- A separate inline-leaf UTF-8 form (own `u8 chars[]`) complements the view:
  the view form covers the Bytes/files/HTTP zero-copy cases, while the inline
  leaf is what **string literals** want (§6.1 — one permanent object, 8 + N
  bytes) and what small copied results can use. Small results below a
  tiny-copy threshold may still materialize as UTF-16 leaves in early phases
  (mirroring `MAKE_BYTEBUFFER_SLICE_MIN_LEN`).

### 2.2 The one representational hole: lone surrogates

Elm strings can contain lone surrogates — `String.slice`/`uncons`/`left`/
`right`/`dropLeft` at a unit index that splits a surrogate pair produce them,
and the existing encoders handle them (WTF-8). Strict UTF-8 cannot represent
them. Two options:

- **(A) Fallback (recommended).** Any operation whose result would begin or
  end with a lone surrogate half returns a UTF-16 result instead. Detection is
  trivial during the index-to-byte-offset scan (the boundary lands inside a
  4-byte sequence). Frequency: only astral content sliced at odd unit indices
  — rare, and the fallback is a bounded copy of the result, not the source.
- **(B) WTF-8 internally.** The encoders already emit WTF-8, so the codec
  exists. But it poisons the "valid UTF-8" invariant that makes the zero-copy
  Bytes seam sound (`Encode.string` of a view = memcpy only if strictly valid),
  and complicates validation. Not recommended as the storage rule; keep WTF-8
  where it already lives (UTF-16 → bytes encode of lone surrogates).

---

## 3. Question 1 — per-operation analysis on UTF-8

Classification of every `String` export (implementation sites are cataloged in
§1.1 and the appendix). "Identical" = bit-identical observable results vs. the
UTF-16 implementation, including surrogate-half iteration order.

### 3.1 Identical and *cheaper or equal* on UTF-8 — no conversion, keep UTF-8

| Op | How | Cost vs UTF-16 |
|---|---|---|
| `length`, `isEmpty` | `header.size` (precomputed) | equal, O(1) |
| `==` (`equal`) | same-encoding: `memcmp` bytes (valid UTF-8 is a canonical encoding — byte equality ⇔ unit equality). Mixed: lockstep segment walk with streaming transcode | equal or better (half the bytes on ASCII) |
| `append`/`++`, `concat`, `join`, `repeat` | rope children are encoding-agnostic; small totals flatten (choose UTF-16 or copy bytes if all inputs UTF-8) | equal; big win when inputs UTF-8 (no transcode) |
| `contains`, `startsWith`, `endsWith` | UTF-8 self-synchronization ⇒ byte-wise `memcmp`/`std::search` is sound when needle is transcoded to UTF-8 once (needles are typically short) | better on ASCII (SIMD-friendlier byte search) |
| `split`, `words`, `lines` | separators (`" \t\n\r"`, `\n`, `\r\n`) are ASCII; ASCII bytes never occur inside multibyte sequences ⇒ byte-wise split; **results are UTF-8 sub-views (zero-copy!)** with unit counts computed during the single scan | better — today these force full `toStdU16String` flattening |
| `trim`, `trimLeft`, `trimRight` | ASCII whitespace scan on bytes; result is a sub-view | better — today flattens |
| `toInt`, `toFloat` | already ASCII-narrowed (`narrowAsciiToStack`); UTF-8 bytes *are* the narrow form | better — narrowing becomes a pointer pass |
| `foldl`, `foldr`, `map`, `filter`, `any`, `all`, `toList` | streaming UTF-8 decoder that **yields surrogate halves for 4-byte sequences** (hi then lo) reproduces UTF-16 iteration exactly; results of `map`/`filter` materialize as UTF-16 (they're fresh strings anyway) | equal (single pass either way; foldr needs the two-pass or reverse-iterate trick UTF-8 supports via lead-byte scan-back) |
| `toUpper`, `toLower` | ASCII-only mapping today ⇒ byte-wise on UTF-8, non-ASCII bytes pass through untouched (multibyte sequences have all bytes ≥ 0x80) | equal or better |
| `fromInt`, `fromFloat` (intrinsics) | output is pure ASCII — either encoding valid; keep emitting UTF-16 leaves (zero churn) | equal |

### 3.2 Identical but with an O(scan) index translation — keep UTF-8, scan once

| Op | How | Notes |
|---|---|---|
| `slice`, `left`, `right`, `dropLeft`, `dropRight` | translate unit indices → byte offsets (O(1) if all-ASCII: `byteOff = unitIdx`; else a scan — **see §3.4, this is the deciding issue**); result is a **UTF-8 sub-view, zero-copy**; if a boundary splits a surrogate pair → §2.2 fallback | today's slice over a big leaf is already the zero-copy champion; UTF-8 keeps that property |
| `uncons` | first unit = first code point's first UTF-16 unit; rest = view advanced by the code point's byte width. Astral first char: first Char = high surrogate, rest must fall back to UTF-16 (starts with lone low surrogate) | rare-path fallback only |
| `cons`, `fromChar`, `fromList` | Chars are u16 units and may be lone surrogates ⇒ produce UTF-16 (status quo) unless all inputs ASCII | unchanged |
| `indexes`/`indices` | byte-wise needle search + running unit counter; **returned indices are UTF-16 units** as required | O(n) either way; today flattens both inputs |
| `pad`, `padLeft`, `padRight` | pure Elm over `length` + `repeat` + `++` — inherits O(1) length + rope append | fine as-is |
| `replace` | pure Elm: `split` + `join` — inherits UTF-8 split/join | fine as-is |

### 3.3 The two genuinely subtle ops

**`compare` (and therefore `Dict`/`Set` keys, `case` string patterns via
`equal`).** Elm order is UTF-16 *code-unit* order. UTF-8 byte order equals
*code-point* order. These differ in exactly one situation: a code point in
`[U+E000, U+FFFF]` vs. one in `[U+10000, U+10FFFF]` at the first difference
(UTF-16 says the BMP char sorts *higher*, because `0xE000+ > 0xD800-0xDFFF`
surrogates; code-point order says lower). Therefore:

- `equal` by `memcmp` is always sound (order-free).
- `compare` by `memcmp` is sound when **at least one side is all-ASCII**
  (free check: `byteLen == header.size`) — at the first differing byte, an
  ASCII byte < any lead byte, and ASCII unit < any unit ≥ 0x80. Also sound
  when neither string contains a 4-byte sequence, but that isn't tracked;
  don't rely on it.
- Otherwise `compare` must stream: decode each side to code points, map
  `cp ≥ 0x10000` to its high surrogate for the comparison (the standard
  UTF-16-order-over-UTF-8 fixup), and compare unit-wise. Still allocation-free
  and single-pass.

This is the **one place a naive byte implementation silently diverges** and
would corrupt `Dict` invariants. It needs a dedicated test (astral vs
`U+E000`-range keys in one Dict, both encodings).

**`reverse`.** Today it reverses u16 units and already corrupts surrogate
pairs (StringOps.hpp:620; a known Elm-semantics wart). Bit-identical behavior
on UTF-8 input = decode to units, reverse units, and since reversed pairs are
lone surrogates the result is generally **not valid UTF-8** ⇒ result must be
UTF-16. Trivial: `reverse` on UTF-8 input goes through the streaming decoder
and emits a UTF-16 leaf. (If eco ever chooses to fix `reverse` to be
code-point-safe, UTF-8 makes that *easier*, but that's a semantics change.)

### 3.4 Deep dive: unit-index translation in the slice family — the deciding issue

*(added Jul 8, 2026)*

`String.slice`, `left`, `right`, `dropLeft`, `dropRight` all take indices in
UTF-16 code units. In the current representation this is not merely *quick*
to translate — it is the identity by definition: **the index space and the
storage space are the same space** (`byteOffset = 2 · unitIndex`, O(1),
always — even for astral content; astral chars produce the *semantic* wart of
splittable surrogate pairs, but never an offset-computation problem). Under
UTF-8 the index space (units) and the storage space (bytes) genuinely
diverge, and the divergence is no longer a corner case:

| Encoding | multi-unit storage begins at | frequency in real text |
|---|---|---|
| UTF-16 | U+10000 (astral) | rare (emoji, some CJK extensions) |
| UTF-8 | **U+0080** (any non-ASCII) | common (accented Latin, all CJK, …) |

So "index ≠ scaled offset" flips from a rarity to the normal case for any
non-ASCII payload. Structurally, the whole question funnels through **one
kernel site**: `Elm_Kernel_String_slice` (StringExports.cpp:56) →
`StringOps::slice` — `left`/`right`/`dropLeft`/`dropRight` are pure Elm over
`slice` + `length` (String.elm:244-285) — plus `charAt` for per-character
consumers.

#### Choice 1 — O(N) walk to translate the index

A single `slice(start, end)` needs one scan (both offsets found in one pass).
Refinements that keep the constant factors down:

- **Anchored operations need little or no translation.** `dropLeft n`/`left n`
  scan `n` units from the view's start; `right n`/`dropRight n` scan from the
  end — UTF-8 is cleanly reverse-iterable *and unit-countable backward*
  (classify each byte: lead `F0-F4` → 2 units, lead `C2-EF` → 1, ASCII → 1,
  continuation `80-BF` → 0). `uncons`, `startsWith`, `foldl` are 0-anchored
  and need no translation at all. A `dropLeft 1` loop is O(1) per step —
  total O(N), same as today.
- **Pick the nearer end**: scan forward if `start < size/2`, else backward.

The composition patterns are what break Choice 1:

- **`Parser.getChompedString`**: `slice i j src` once per token against the
  *original* source string, with `i` growing through the input. Each call
  scans O(i) ⇒ Σ = **O(k·N)** for k tokens — quadratic-ish where UTF-16 pays
  O(1) per slice (a 24-byte view allocation).
- **`String.indexes` + slice-per-match**: same shape, O(matches · N).
- Any mid-string extraction loop written idiomatically in Elm.

And a second, independent killer found in the kernel: **the `ensureFlat`
re-promotion hazard.** The parser kernel flattens its source string **on
every primitive call** (`resolveString` → `StringOps::ensureFlat`,
ParserExports.cpp:38-46 — the comment explicitly calls the parser "the
heaviest consumer of String operations" and relies on `ensureFlat` being
identity for leaves). For a UTF-8 view, `ensureFlat` must produce a
`u16`-walkable leaf, i.e. transcode. And crucially, **the transcoded result
cannot be memoized on the string object**: eco's GC has *no write barrier and
no remembered set* — the design assumes heap objects are immutable
(NurserySpace.cpp:26), so lazily attaching a promoted pointer (or a lazily
built index) to an existing string is forbidden, not just awkward. Result:
UTF-8 source + parser = one full transcode *per parser primitive* —
catastrophically quadratic. Regex and Url have the same per-call shape via
`toStdU16String` (C-stack, no heap churn, but still O(N) per call).

**Verdict on Choice 1: sound as a correctness fallback, unacceptable as the
primary regime for non-ASCII data.**

#### Choice 2 — never create the problem: gate creation on ASCII

Take the zero-copy view **only when the validation pass reports
`unitCount == byteLen`** — i.e. pure ASCII, the exact subset of UTF-8 where
1 unit = 1 byte. Everything else transcodes to UTF-16 at the boundary,
exactly as today (no regression, no win). The gate costs nothing: validation
already computes both numbers (§2).

Inside the gate, the entire §3 subtlety collapses:

- `slice` family and `charAt`: **O(1)** byte arithmetic (`offset = index`).
- Lone surrogates, astral splits, `uncons`-fallbacks: **impossible** (no
  code point ≥ U+0080 exists, let alone ≥ U+10000).
- `compare`/`equal` by `memcmp`: **always sound** (§3.3's ASCII rule holds by
  construction).
- Iteration: one `zext u8 → u16` per char.
- Parser: `resolveString` gains an ASCII branch that walks `u8` directly
  (every comparison in ParserExports is `charCodeAt`-style against `u16`
  values; zext makes them exact, and `advancePosition`'s surrogate-skip is a
  no-op on ASCII) — no transcode, no quadratic.

**Precedent strongly favors this.** The JVM (compact strings, Latin-1) and
V8 (`SeqOneByteString`) both faced the identical problem — a unit-indexed
public string API over a compact 1-byte storage — and both chose *exactly*
this rule: use the 1-byte form only when 1 unit = 1 byte holds, decide at
creation, never index-translate. (For eco the 1-byte subset must be ASCII,
not Latin-1, because the bytes must *be* the wire UTF-8 for zero-copy;
ASCII = UTF-8 ∩ "1 byte = 1 unit".) The counterexample is Swift — full
UTF-8 storage with UTF-16-compatible offsets for Cocoa interop — but Swift
(a) redefined its public String API to opaque indices so unit indexing is
rare, and (b) memoizes its offset table ("breadcrumbs") by mutating the
string object in place. Elm's API semantics rule out (a); eco's
no-write-barrier GC rules out (b) in its lazy form.

The cost of the gate is coverage: a 1 MB JSON document containing a single
emoji fails `unitCount == byteLen` and loses zero-copy entirely. Two
extensions recover that without giving up O(1) indexing:

#### Choice 2b — hybrid segmentation (mostly-ASCII payloads)

During the (mandatory) validation scan, split the input at non-ASCII runs
and build a **rope** whose children are ASCII UTF-8 views (zero-copy) and
UTF-16 leaves (transcoded non-ASCII runs). This needs *no new machinery*:
ropes already take mixed children, `header.size` accounting is
encoding-independent, and rope descent already navigates by unit counts —
so an index lands in O(rope height) at a child where index = byte offset
(ASCII view) or ×2 (UTF-16 leaf). Guard against fragmentation by only
splitting when an ASCII run ≥ a threshold (e.g. 512 bytes) and capping leaf
count; below threshold, fold the run into the neighboring UTF-16 leaf. The
1 MB-JSON-with-one-emoji case becomes: two large zero-copy views + one tiny
UTF-16 leaf.

#### Choice 3 — eager breadcrumbs (full non-ASCII zero-copy)

Swift's solution, adapted to immutability: during validation, record the
byte offset of every K-th unit (K = 64) into a **pointer-free side object**
(reuse `Tag_ByteBuffer` as the container — no new tag, no GC tracing) and
store its HPointer in the view (view grows 24 → 32 bytes). Unit index →
`crumbs[i/K]` + a ≤ K-unit local scan: bounded O(K) ≈ O(1). Memory ≈ 4
bytes per 64 units (~1.6-3%), only for non-ASCII views. Must be built
**eagerly** at creation — lazy attachment is what the missing write barrier
forbids. Still needs the §2.2 surrogate-split fallback (a slice boundary can
land mid-astral). This is the "handle everything zero-copy" option; its
complexity is only worth paying if profiling shows heavy non-ASCII payloads.

For the `ensureFlat` hazard beyond ASCII (Choices 2b/3, or any future
non-ASCII view), the eco-idiomatic substitute for Swift's in-object
memoization is a **root-registered promotion cache**: a small thread-local
table (even 1-2 entries) mapping view identity → its UTF-16 promotion,
registered as a GC root range so the HPointers stay valid across
collections. Parser-style repeated `ensureFlat` on the same string then
transcodes once.

#### Decision *(adopted Jul 8, 2026)*

**Choice 2 is the decided approach for v1** — gate view creation on
all-ASCII (`unitCount == byteLen`). Free to decide, O(1) everywhere, kills
every semantic caveat, matches JVM/V8 precedent, and the parser needs only
a mechanical u8 branch. Ship the general unit→byte scan only as the
rarely-hit fallback inside `StringOps::slice`/`charAt` so the representation
isn't semantically ASCII-locked — lifting the gate later (Choice 2b, then
Choice 3 for truly random-access-heavy non-ASCII workloads) changes creation
policy, not layout, and is deferred until profiling demonstrates the need.

### 3.5 Verdict on question 1

**Every core String operation can produce identical results from UTF-8
storage.** The complete divergence surface is:

1. Lone surrogates are unrepresentable → per-op fallback to UTF-16 results
   (slice-family boundary splits, `uncons` on astral heads, `reverse`,
   `cons`/`fromChar`/`fromList` of surrogate-half Chars).
2. `compare` must not use raw byte order except in the proven-safe cases.
3. Invalid UTF-8 must be rejected *at creation* (see §5.1) so the in-heap form
   is always valid; the operations themselves then never see garbage.

Cost classes: ASCII data is identical-or-faster everywhere. Non-ASCII data
pays O(scan) for unit-index translation in the slice family (vs O(1) on flat
UTF-16), and equal-cost streaming for iteration — and §3.4 shows the scan
composes quadratically under idiomatic slicing patterns, which is why the
recommended v1 **gates view creation on all-ASCII** (`unitCount == byteLen`).
Under that gate, caveats 1 and 2 above vanish entirely (no multibyte
sequences ⇒ no surrogate splits, and `memcmp` ordering is exact); they
re-enter only if/when non-ASCII views are introduced via §3.4's Choice 2b or
Choice 3.

---

## 4. Question 2 — automatic conversion boundaries

### 4.1 Where conversion machinery already lives

`maybeFlattenOrRebalance(s, FlattenReason)` (StringOps.cpp:119) is the single
existing decision point, and `FlattenReason::{RandomAccess, Transform,
Equality, Utf8Encode, Structural}` already names the policies. The natural
extension: `flattenToLeaf` becomes encoding-aware — flattening a UTF-8 form
under `RandomAccess`/`Transform` produces a **UTF-16 leaf** (transcode), while
`Structural`/`Utf8Encode` keep bytes. `ensureFlat` callers (the hot loops that
walk `chars[]` directly) then transparently promote non-ASCII UTF-8 exactly
where per-character tag dispatch would hurt.

### 4.2 Promotion policy (recommended)

Strings are immutable and eco has no in-place forwarding, so a promotion
cannot be memoized into the existing object — repeated promotion of the same
value would thrash. The policy that avoids this without any new mechanism:

- **Keep UTF-8 through structural ops** — `slice`-family, `split`, `trim*`,
  `lines`, `words`, `append`/`concat`/`join` (rope children), search. These
  are precisely the "convenient moments" the user intuited, but the right
  move there is *keeping* the cheap encoding, not converting: results share
  the same base buffer, zero-copy.
- **Stream, don't convert, for one-shot reads** — `foldl`/`map`/`toList`/
  `toInt`/`equal`/`compare` never need a persistent UTF-16 copy; a streaming
  decoder does one pass and the temporary is C-stack, not heap.
- **Promote to UTF-16 when producing a fresh string from a transform** —
  `map`, `filter`, `reverse`, `toUpper`/`toLower` (non-ASCII input), `cons`.
  The output allocation happens anyway; making it UTF-16 means chains of
  transforms pay transcode once.
- **`ensureFlat` is a hazard, not a hook** *(revised Jul 8 — see §3.4)*.
  The parser kernel calls `ensureFlat` **per primitive** (ParserExports.cpp:
  38-46), and eco's GC has no write barrier/remembered set
  (NurserySpace.cpp:26), so a promotion can never be memoized onto the
  string object — per-call promotion of a UTF-8 view would transcode the
  same source once per primitive (quadratic). Under the v1 ASCII gate the
  fix is a `u8`-walking branch in `resolveString`-style consumers (zext
  comparisons; surrogate skips are no-ops on ASCII). If non-ASCII views are
  ever introduced, pair them with a root-registered promotion cache (§3.4).
- **All-ASCII strings never promote.** `byteLen == header.size` makes every
  operation byte-exact; ASCII UTF-8 is simply a better representation
  (half the memory, SIMD-friendly), and — per the HTTP/JSON reality — most
  boundary strings are ASCII.

### 4.3 Where UTF-8 strings get created

| Boundary | Today | With UTF-8 form |
|---|---|---|
| `Bytes.Decode.string` (`read_string`, Bytes.cpp:247) | non-validating transcode+copy | validate+count (one pass) → 24-byte view, zero-copy. Invalid bytes → legacy lenient path (bug-compatible; see §5.1) |
| fused `bf.read_utf8` (`elm_utf8_decode`) | strict validate + transcode+copy | validate+count → view; strictness already matches |
| HTTP `expectString` body (HttpExports.cpp:424-427) | `allocStringFromUTF8` transcode+copy | body lands as `ByteBuffer` (as `arraybuffer` already does) + validate → view; invalid → lenient legacy |
| JSON string values/keys (JsonExports.cpp) | transcode+copy per string | optional later phase: ASCII-only fast check → ASCII UTF-8 leaf/view (JSON keys are overwhelmingly ASCII) |
| Ports ingest | transcode+copy | same optional treatment |
| File reads (unbuilt) | — | design the API UTF-8-native from day one |
| String literals | UTF-16 `[N x i16]` globals, transcoded from UTF-8 attrs at the last pass | ASCII literals → `[N x i8]` globals + inline UTF-8 leaves (**§6** — phase 4; the literal is UTF-8 through the whole pipeline already, this *deletes* a transcode) |

### 4.4 Mixed-encoding plumbing

- `forEachSegment`'s `cb(const u16*, u32)` needs a dual form: either
  `cb(SegmentView{const void*, u32 len, Encoding})` or a transcoding shim that
  feeds UTF-8 segments through a fixed-size stack buffer of u16 chunks.
  Recommendation: add `forEachSegmentRaw` exposing encoding, keep the u16
  version as the shim — call sites migrate opportunistically.
- `makeRope` accepts any string tag already; mixed ropes work by construction.
  `buildBalancedRope`, `charAt` (per-child descent), `equal`/`compare`
  (segment walks) each add one tag case.
- `singleSegmentView` grows an encoding field; `memcmp` fast paths check
  encodings match (or one side is ASCII).

---

## 5. Question 3 — the Bytes seam, zero-copy in both directions

### 5.1 Bytes → String (`Decode.string`, HTTP, files)

The proposed `Tag_StringUtf8` **is** a byte-buffer slice with string
semantics: `base` → `Tag_ByteBuffer`/`Tag_LargeByteHeader`, byte `offset`,
`byteLen`, plus the unit count. Creation from `Bytes.Decode.string`:

1. Bounds-check (existing).
2. One validation pass over `[offset, offset+len)`: strict UTF-8 validation
   *and* UTF-16 unit counting (this loop already exists verbatim in
   `elm_utf8_decode` pass 1).
3. Valid **and all-ASCII** (`unitCount == byteLen` — the §3.4 v1 gate) →
   allocate the 24-byte view; **no payload copy, no transcode**. Below a
   tiny threshold (mirror `MAKE_BYTEBUFFER_SLICE_MIN_LEN = 32`), transcode
   to a small UTF-16 leaf instead — 24 bytes of view + retained base isn't
   worth it for short strings.
3b. Valid but non-ASCII → v1: transcode to UTF-16 exactly as today (no
   regression). Later phases may upgrade this arm to §3.4 Choice 2b
   (hybrid ASCII-view/UTF-16-leaf rope) or Choice 3 (breadcrumbed view).
4. Invalid → **fall back to the current lenient copy path**, preserving
   today's observable behavior exactly (`read_string` currently produces
   garbage units rather than failing; bug-compatibility means zero test
   churn). The strict fused path (`elm_utf8_decode`) keeps failing as today.

This resolves the current three-way validation inconsistency by construction:
the *view* form is always strictly valid; anything else takes the legacy
copies with their legacy behaviors.

Cost accounting: today's path is O(n) validate-ish + O(n) transcode + 2n bytes
allocated + O(n) write. New path is O(n) validate + 24 bytes. Strictly better
even before any downstream zero-copy wins.

**GC**: copy the `Tag_ByteBufferSlice` treatment verbatim — evacuate/mark/fix
`base` only (NurserySpace.cpp:1665, OldGenSpace.cpp:1710, 3958). When `base`
is a `Tag_LargeByteHeader`, point at the *header* (not the pinned body),
exactly like slice-of-large-string does (StringOps.cpp:244-255), so the
nursery-owned-body accounting keeps working.

**Retention hazard**: a small view pins its whole base buffer (a 30-byte field
decoded from a 100 MB HTTP body keeps the body alive). Precedents and
mitigations: the tiny-copy threshold (above), plus the existing flatten
heuristics — and if it bites in practice, a "view ≪ base ⇒ copy out on
promotion" rule at the `maybeFlattenOrRebalance` decision point. `ElmStringSlice`
has the identical hazard today (unmitigated beyond the tiny-slice limit), so
this is not a new class of problem.

### 5.2 String → Bytes (`Encode.string`, `getStringWidth`)

- **`getStringWidth` on a UTF-8 string: O(1)** — return `byteLen`. Today it's
  a full O(n) surrogate-combining walk. Same for the fused `bf.width` /
  `bf.encoder.width`, since they funnel through `elm_utf8_width`.
- **`Encode.string` of a UTF-8 string into an encoder buffer: `memcpy`** —
  the bytes are already UTF-8 (`writeEncoder ENC_UTF8` and `elm_utf8_copy`
  branch on the tag). Today: materialize u16 + recombine surrogates + emit.
- **True zero-copy (`Bytes` as a slice onto the string)**: when the entire
  encoder output *is* one string — `Bytes.Encode.encode (Bytes.Encode.string
  s)` — and `s` is a UTF-8 view, return a `Tag_ByteBufferSlice` over `s`'s
  own `base` with the same offset/length. No new aliasing rules needed:
  the result's base is the ByteBuffer that already backs the string.
  If an inline UTF-8 leaf form is ever added, slicing Bytes onto *it* means a
  ByteBufferSlice whose base is a string object — new invariant territory
  (GC fine — same trace-the-base — but `byteBufferView` and HEAP_025/BFOPS_032
  contracts must be widened). Recommendation: defer; the view-backed case
  covers the round-trip (`bytes → string → bytes` becomes two 24-byte
  allocations over one buffer).
- **WTF-8 caveat**: UTF-16 strings containing lone surrogates keep the legacy
  WTF-8 emit path; UTF-8 views by invariant never contain them, so their
  memcpy path is exact.

### 5.3 Bytes fusion (`bf` dialect)

No compiler changes needed for the wins: `elm_utf8_width`, `elm_utf8_copy`,
`elm_utf8_decode` are the fusion ABI (BFOPS_032) and are where the tag
dispatch lands. `bf.read_utf8` output becoming a view also means fused
decoders that extract many strings from one buffer become one validation scan
plus N 24-byte views — no per-string transcode allocations. (BFOPS invariants
are unaffected: cursor discipline, bounds-first, Nothing-propagation all
unchanged; only the string materialization step inside `read_utf8` changes.)

---

## 6. String creation in user code — compile-time ASCII knowledge

*(added Jul 8, 2026)*

Beyond the Bytes boundary, most strings in a program originate in *source
code*: literals, `fromInt`/`fromFloat`, and combinations thereof. A literal
like `"hello"` is a compile-time constant whose ASCII-ness is statically
known. Investigated: how far should that knowledge be pushed into the
compiler (parser → IRs → monomorphization), and what does it buy?

### 6.1 The literal pipeline is already UTF-8 — until the very last pass

Tracing `"hello"` through the compiler:

1. Source files are UTF-8; the parser stores the literal in the AST.
2. Monomorphized IR carries it as `LStr String`
   (`Compiler/AST/Monomorphized.elm:607`).
3. MLIR generation emits `eco.string_literal` with a **StringAttr — which is
   UTF-8 by MLIR definition** (`Expr.elm:527-541` → `Ops.ecoStringLiteral`).
   The MLIR bytecode string section stores these bytes (with the
   surrogate-half length fix noted in the bytecode work).
4. Only in the **final lowering pass** does `preMaterializeStringLiterals`
   call `utf8ToUtf16` and emit a `[N x i16]` global
   (`EcoToLLVMTypes.cpp:124-158`), and `eco_alloc_string_literal` memcpys it
   into a permanent old-gen UTF-16 leaf (`RuntimeExports.cpp:414-428`). The
   string-pattern path synthesizes the same call
   (`EcoToLLVMControlFlow.cpp:396`).

So "go straight to UTF-8 for ASCII literals" is not new machinery — it is
**deleting the transcode** for the ASCII case at the one site that performs
it. The lowering pass holds the UTF-8 bytes in hand; an all-ASCII check is
one scan of a compile-time constant. Emit `[N x i8]` globals for ASCII
literals and call a new `eco_alloc_string_literal_utf8(ptr, byteLen)`
(`units == byteLen` by construction). **No parser, IR, type-system, or
monomorphization change is required for the literal win.**

Representation note: literals want the **inline UTF-8 leaf** variant
(`Tag_StringUtf8` with inline `u8 bytes[]`) rather than the view form — a
single permanent object of `8 + N` bytes vs `8 + 2N` (UTF-16 today) vs
`24 + (8 + N)` for a view + permanent ByteBuffer pair. This concretely
motivates promoting §2.1's "optional inline leaf" into the literal phase.
(Dead end checked: pointing a view's `base` directly at the rodata global
is not possible — HPointer words are raw heap addresses constrained below
2^43 (HEAP_008) with GC-readable Headers; PIE rodata satisfies neither.)

### 6.2 Pre-existing wrinkle: literals allocate per execution

`eco_alloc_string_literal` does `allocatePermanent` + memcpy **on every
execution of the op** — no hoisting or caching pass exists (checked
`Expr.elm`, the EcoToLLVM* passes, and the optimizer; there is no literal
pool). *(Corrected Jul 8: "permanent" is a misnomer — it is a plain direct
old-gen allocation; dropped copies ARE reclaimed at major GC, and live ones
can be moved by compaction. So this is repeated allocation churn and old-gen
pressure, not a monotonic leak.)* Any literal work should bundle the obvious
companion fix: **runtime literal interning**, keyed by the literal's global
data pointer (`__eco_str_N` addresses are unique and stable), with cached
HPointers registered as long-lived GC roots (`RootSet::addRoot`) for
liveness and compaction fixup. With interning, the literal transcode cost
becomes once-per-program either way — the encoding choice then matters for
memory footprint (half) and for *seeding runtime propagation* (§6.3), not
for allocation cost. See `plans/utf8-string-representation.md` M3.

### 6.3 Should ASCII-ness be type-level / IR-level information? — No

ASCII-ness is a **value property, not a type property**: Elm has one
`String` type, and a `String`-typed parameter can receive any string at
runtime. Sound static ASCII-ness for non-constants is a dataflow analysis
(abstract interpretation), not unification. Exploiting it at
monomorphization would mean splitting `MString` into
`MStringAscii | MString` and specializing every String-consuming function
per property — doubling String specializations, polluting specialization
keys and ctorShapes, and stepping directly into the constraint-fragility
class that CNumber occupies (MONO_028; two historical miscompilations from
by-name constraint loss). Against that cost, the runtime alternative is
one compare on data already in a register: `byteLen == header.size`.

**Verdict: do not represent ASCII-ness in the Elm-side IRs or the type
system.** The exploitable compile-time knowledge, ranked:

1. **Literals at final lowering** (§6.1) — the full win, zero propagation:
   a constant *is* its value; ASCII-ness is recomputable in O(n) at the
   single site that consumes it. Annotating earlier (parser/Canonical/Mono)
   would thread a bit through every AST encoder and the `.ecot` wire format
   (cf. the blast radius in `plans/ecot-string-interning.md`) to carry
   information that is one scan away where it's needed.
2. **Runtime propagation covers all derived strings with zero compiler
   work**, because construction sites see their inputs' encodings: slice of
   an ASCII view is an ASCII view (structural); `append`/`concat` check
   each child in O(1) and pick the result encoding; `fromInt`/`fromFloat`
   outputs are ASCII by construction (flip the intrinsics' allocation to
   UTF-8 leaves); `toUpper`/`toLower` preserve ASCII. The runtime is the
   natural propagation medium for a per-value property.
3. **Bytes-fusion literal inlining** (small, targeted): `Bytes.Encode.string
   "literal"` — Reify already sees the constant (`EUtf8`, width cached);
   the emitter could write the UTF-8 bytes straight from the rodata global
   into the encoder buffer, skipping the string heap object entirely.
4. **MLIR-level ASCII dataflow** (rejected for now): string ops are opaque
   kernel calls, so propagation needs a transfer-function table over ~30
   kernel symbols, and the only consumer would be selecting `*_ascii`
   kernel variants to skip a runtime compare+branch. Thin payoff, real
   complexity. Reconsider only if profiling shows encoding-dispatch
   overhead in hot loops that the free `byteLen == size` check doesn't
   already hide.

### 6.4 Expected coverage

Literal-origin strings + `fromInt`/`fromFloat` + ASCII Bytes/HTTP payloads
+ everything derived from them (slices, appends, splits, case transforms)
— in typical Elm programs (JSON keys, URLs, CSS classes, config, generated
code) that is the large majority of live strings, all becoming UTF-8 with
1-byte chars and O(1) everything. Non-ASCII user text and i18n content
stays UTF-16 exactly as today, by the §3.4 gate.

## 7. Change inventory (what a new tag touches)

Hand-maintained per-tag switches that must gain a `Tag_StringUtf8` arm:

| Area | Sites |
|---|---|
| Sizing | `getObjectSize` (AllocatorCommon.hpp:204) — fixed 24 bytes |
| Minor GC | evacuate + post-copy scan + 2 debug validators (NurserySpace.cpp:810-823, 943-956, 1665-1704) |
| Major GC | `markChildren`, pointer fixup (OldGenSpace.cpp:1710, 3958) |
| StringOps | `isString`/`isLeaf` family, `rawLen`, `charAt`, `forEachSegment`(+raw variant), `singleSegmentView`, `toStdU16String`, `toStdString`, `copyInto`, `equal`, `compare`, `slice`, `uncons`, `flattenToLeaf`, `maybeFlattenOrRebalance` |
| HeapHelpers | `isString`, `stringLength`; `stringData` keeps its leaf-only assert |
| Kernel entry | none directly (String.cpp delegates to StringOps) — that's the payoff of HEAP_025's discipline |
| Fusion ABI | `elm_utf8_width`/`copy`/`decode` (ElmBytesRuntime.cpp) tag branches |
| Bytes kernel | `read_string`, `writeEncoder ENC_UTF8`, `getStringWidth` (×2), `BytesOps::encodeUtf8` |
| Debug | `print_value`/`print_string_content` Tag switch (RuntimeExports.cpp:2477 area) |
| Literals (phase 4) | `preMaterializeStringLiterals` + `StringLiteralOpLowering` (EcoToLLVMTypes.cpp), string-pattern path (EcoToLLVMControlFlow.cpp:396), new `eco_alloc_string_literal_utf8` ABI fn + JIT symbol (RuntimeSymbols.cpp), `fromInt`/`fromFloat` intrinsic allocation |
| Invariants | HEAP_025 (five forms + validity invariant + unit-count rule), REP_CONSTANT_003 (add tag to the size==0 list), BFOPS_032 (unchanged in spirit), new invariant for "strictly valid UTF-8 + lone-surrogate fallback" |
| Tag space | 5-bit tag, ~22 used incl. `Tag_Forward` (must stay last) — room exists; append before `Tag_Forward`, never renumber `Tag_String` (baked into lowering) |

Compiler/MLIR: **zero changes required** (CGEN_039 already says codegen emits
only `Tag_String` leaves; the UTF-8 form is runtime-internal like ropes and
slices were).

Testing: extend the byte-slice/String suite from
`plans/string-bytes-testing-gap.md`; the critical new cases are (a) astral vs
`U+E000`-range ordering in a Dict across encodings, (b) surrogate-splitting
slice/uncons fallbacks, (c) invalid-UTF-8 `Decode.string` bug-compatibility,
(d) GC stress with views over nursery and large-pinned bases
(`ECO_HEAP_VALIDATE` + tiny-nursery forced GC, per the List.mapN precedent).

---

## 8. Recommended phasing

1. **Consolidate the UTF-8 codecs.** One header (validation levels as flags,
   unit counting, streaming decode yielding u16 units, encode). Replaces six
   divergent copies; independently valuable; de-risks everything after.
2. **Introduce `Tag_StringUtf8` conservatively, ASCII-gated (§3.4 Choice 2).**
   GC arms + `StringOps` dispatch where every operation begins with "if
   UTF-8 and not handled, promote via `flattenToLeaf`-to-UTF-16". Create
   views only in `Bytes.Decode.string`, and only for valid **all-ASCII**
   input above the tiny threshold. Because ASCII views make every index a
   byte index, even the conservative fallbacks are cheap; and the
   `ensureFlat`-per-primitive consumers (parser) get their `u8` branch in
   this phase, before views can reach them. Semantics are unchanged by
   construction; land it green (`--target full`, 1555/1555).
3. **Peel fast paths in order of value:** O(1) `length` (free from day one) →
   `equal`/`compare` (memcmp — exact under the ASCII gate) →
   `getStringWidth`/`Encode.string` memcpy + round-trip slice → byte paths
   (search, O(1) slice/trim/split returning sub-views) → streaming
   iteration (`foldl` et al.) → `bf` helper dispatch.
4. **ASCII literals to UTF-8 at final lowering (§6):** inline UTF-8 leaf
   form + `[N x i8]` globals + `eco_alloc_string_literal_utf8` in
   `EcoToLLVMTypes.cpp`/`EcoToLLVMControlFlow.cpp`; flip the
   `fromInt`/`fromFloat` intrinsic outputs to ASCII leaves. Bundle (or
   precede with) runtime literal interning — §6.2's per-execution permanent
   allocation should be verified and fixed first so literal costs are
   once-per-program.
5. **Widen creation boundaries:** HTTP string bodies, then JSON/ports ASCII
   fast paths, then file I/O when that surface is built. Optionally the
   bytes-fusion literal-inlining peephole (§6.3 item 3).
6. **(Only if profiling demands it) non-ASCII zero-copy:** §3.4 Choice 2b
   (hybrid segmentation rope) first; Choice 3 (eager breadcrumbs) plus the
   root-registered promotion cache only for genuinely random-access-heavy
   non-ASCII workloads. Each re-opens the §2.2 surrogate-split fallback and
   the §3.3 compare fixup, so they ship with the Dict-ordering and
   split-boundary test batteries.

---

## Appendix A — operation catalog (implementation sites)

Elm module: `~/.eco/0.1.0/packages/elm/core/1.0.5/src/String.elm`; kernel
wrappers `elm-kernel-cpp/src/core/{String.cpp,StringExports.cpp}`; logic in
`runtime/src/allocator/StringOps.{hpp,cpp}`.

| Op | Impl | Flatten behavior today | UTF-8 class (§3) |
|---|---|---|---|
| `length` | StringOps.hpp:151 | none (O(1)) | identical, O(1) |
| `isEmpty` | via `equal` | size check | identical, O(1) |
| `append` | StringOps.hpp:343 | ≤32Ki→leaf; else rope | keep UTF-8 (rope child) |
| `concat`/`join` | StringOps.cpp:362/452 | small→leaf; else balanced rope | keep UTF-8 |
| `slice`/`left`/`right`/`dropLeft`/`dropRight` | StringOps.cpp:156, hpp:403-441; pure-Elm String.elm:244-285 over slice | zero-copy slice ≥128 units | UTF-8 sub-view; O(1) under v1 ASCII gate, else unit→byte scan + surrogate-split fallback (§3.4) |
| `contains`/`startsWith`/`endsWith` | StringOps.hpp:479-560 | no flatten (`singleSegmentView`/`charAt`) | byte-wise, needle transcoded once |
| `indexes` | StringOps.cpp:559 | flattens both | byte search + unit counter |
| `split`/`words`/`lines` | StringOps.cpp:616; String.cpp:160-271 | flatten | byte-wise; results = UTF-8 sub-views |
| `trim`/`trimLeft`/`trimRight` | StringOps.hpp:648-711 | flatten + slice | byte-wise ASCII scan; sub-view |
| `toUpper`/`toLower` | StringOps.hpp:572/597 | copyInto → leaf | ASCII byte map; non-ASCII passes through |
| `map`/`filter`/`foldl`/`foldr`/`any`/`all`/`toList` | StringExports.cpp:229-332; StringOps.cpp:696-832 | snapshot (`toStdU16String`) | stream-decode yielding surrogate halves; outputs UTF-16 |
| `uncons`/`cons`/`fromChar`/`fromList` | StringOps.cpp:718, hpp:924-935; String.cpp:46 | uncons rest = slice | uncons rest = UTF-8 view (astral head → fallback); constructors emit UTF-16 |
| `reverse` | StringOps.hpp:620 | segment reverse (surrogate-unsafe) | decode → unit-reverse → UTF-16 result |
| `repeat`/`pad`/`padLeft`/`padRight`/`replace` | pure Elm over append/length/split | — | inherit |
| `toInt`/`toFloat` | StringOps.hpp:837/860 | ASCII-narrow via segments | bytes are already narrow |
| `fromInt`/`fromFloat` | intrinsics `eco.string.from_int/from_float`; StringOps.hpp:890/904 | fresh leaf | unchanged (ASCII output) |
| `==`/`compare` | StringOps.hpp:1129/1181 via Utils.cpp:427/234 | segment lockstep, no flatten | memcmp (equal); compare needs order fixup (§3.3) |

## Appendix B — the three decoders' behavior on invalid input (today)

| Path | Elm surface | Invalid UTF-8 behavior |
|---|---|---|
| `read_string` (Bytes.cpp:247) | `Bytes.Decode.string` (interpreter) | silently decodes garbage units; fails only on out-of-bounds |
| `elm_utf8_decode` (ElmBytesRuntime.cpp:208) | `Bytes.Decode.string` (fused) | strict fail → decode `Nothing` |
| `allocStringFromUTF8` (HeapHelpers.hpp:490) | HTTP/ports/JSON ingest | skips invalid lead bytes |

Note the interpreter and fused paths **already disagree** on invalid input —
a pre-existing semantics bug worth fixing (or at least documenting) during
phase 1 codec consolidation.
