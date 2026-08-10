# Kernel surface audit 04 — Json / Url / Parser / Regex / Bytes

Scope: `elm-kernel-cpp/src/json/`, `src/url/`, `src/parser/ParserExports.cpp`,
`src/regex/`, `src/bytes/`. Authoritative symbol list = the Json, Url, Parser,
Regex, Bytes sections of `elm-kernel-cpp/src/KernelExports.h` (lines 398–549).
All line references are absolute-file:line.

## Classification legend

`P` pure non-allocating · `PA` pure but allocates on the GC heap ·
`PH` pure, reads heap through HPtr args · `TB` Task builder · `RT`
runtime-internal mutable state · `E` effectful · `X` non-returning ·
`STUB` unimplemented · `HOF` calls back into an Elm closure.

## The description-vs-interpretation distinction (read this first)

Exactly as `Task` values describe IO without performing it, **Json decoders and
Bytes encoders/decoders are descriptions, not effects**:

* `Elm_Kernel_Json_decodeString()`, `Json_map2(f,d1,d2)`, `Json_andThen(f,d)`,
  `Json_oneOf(ds)` … do **one thing**: `eco_alloc_with_roots(Tag_Custom, …)`,
  set `ctor = DEC_*`, store the argument HPointers as fields
  (`JsonExports.cpp:464–539`, `:1456–1481`). They never look at a JSON value and
  never call the closure they capture. They are `PA`, and **not** `HOF`.
* Only `Json_run` / `Json_runOnString` / `Json_encode`
  (`JsonExports.cpp:1522`, `:1532`, `:1558`) interpret those trees. `run` and
  `runOnString` are the only two that reach `eco_apply_closure`.
* Symmetrically `Bytes_write_i32(endianness, value)` (`BytesExports.cpp:847`)
  allocates an `ENC_I32` Custom and returns; `Bytes_encode` /`Bytes_decode`
  (`:395`, `:418`) are the interpreters.
* Consequence for the audit: **33 of the 35 Json exports and 10 of the 26 Bytes
  exports are pure allocation of a fixed-ctor Custom.** Each is a single
  `eco.construct.custom` in the dialect — see Part 2.

---

## PART 1 + PART 2 — symbol table

### Json (`elm-kernel-cpp/src/json/JsonExports.cpp`) — 35 symbols

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Json_decodeString` | `() -> HPtr` | PA | – | 1 Custom, 0 fields (`makeDecoder0`, :464) | **Trivial** | `ctor=DEC_STRING(0)`. No args, no roots. |
| `Json_decodeBool` | `() -> HPtr` | PA | – | 1 Custom (`:464`) | **Trivial** | `ctor=DEC_BOOL(1)`. |
| `Json_decodeInt` | `() -> HPtr` | PA | – | 1 Custom (`:464`) | **Trivial** | `ctor=DEC_INT(2)`. |
| `Json_decodeFloat` | `() -> HPtr` | PA | – | 1 Custom (`:464`) | **Trivial** | `ctor=DEC_FLOAT(3)`. |
| `Json_decodeValue` | `() -> HPtr` | PA | – | 1 Custom (`:464`) | **Trivial** | `ctor=DEC_VALUE(10)`. |
| `Json_decodeNull` | `(HPtr) -> HPtr` | PA | – | 1 Custom, 1 boxed (`makeDecoder1`, :475) | **Trivial** | fallback rooted via `roots[]` mask `0x1`. |
| `Json_decodeList` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_LIST(5)`. |
| `Json_decodeArray` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_ARRAY(6)`. |
| `Json_decodeKeyValuePairs` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_KEYVALUE(9)`. |
| `Json_succeed` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_SUCCEED(11)`. |
| `Json_fail` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_FAIL(12)`. |
| `Json_oneOf` | `(HPtr) -> HPtr` | PA | – | 1 Custom (`:475`) | **Trivial** | `ctor=DEC_ONEOF(14)`; field is the Elm list. |
| `Json_decodeField` | `(HPtr,HPtr) -> HPtr` | PA | – | 1 Custom, 2 boxed (`makeDecoder2`, :503) | **Trivial** | roots mask `0x3`. |
| `Json_decodeIndex` | `(i64,HPtr) -> HPtr` | PA | – | 1 Custom, i64+boxed (`makeDecoder2ip`, :523) | **Trivial** | `unboxed=1`, roots mask `0x2`. |
| `Json_andThen` | `(HPtr,HPtr) -> HPtr` | PA | **no** | 1 Custom, 2 boxed (`:503`) | **Trivial** | Captures the closure; the call happens in `runDecoder:1117`. |
| `Json_map1` | `(HPtr,HPtr) -> HPtr` | PA | **no** | 1 Custom, 2 boxed (`:503`) | **Trivial** | Closure stored at slot 0. |
| `Json_map2`…`Json_map8` | `(HPtr,…) -> HPtr` | PA | **no** | 1 Custom, N+1 boxed (`buildMapDecoder`, :1456) | **Trivial** | 7 symbols; identical shape, only `ctor`/`nFields` differ. |
| `Json_run` | `(HPtr,HPtr) -> HPtr` | PA + PH | **HOF** | Result/Err Customs + everything `runDecoder` builds | **Hard-Infeasible** | Interpreter (`runDecoder`, :552–1267). Closure calls at `:1117` (andThen), `:1167`/`:1198`/`:1258` (mapN). Heavy `StackRootGuard`/`pushStackRootRange` discipline throughout. |
| `Json_runOnString` | `(HPtr,HPtr) -> HPtr` | PA + PH | **HOF** | nlohmann DOM (C++ heap) + full GC-heap mirror | **Hard-Infeasible** | `json::parse` at `:1537`, then `jsonToHeap` (:305) copies the DOM into `CTOR_JSON_*` Customs, then `runDecoder`. Irreducible piece = the JSON **text parser**. |
| `Json_encode` | `(i64,HPtr) -> HPtr` | PA + PH | **no** | nlohmann DOM + one ElmString | **Hard-Infeasible** | `elmToJson` (:1274) is a pure tree walk — **no closure calls**. Irreducible piece = nlohmann's shortest-round-trip **double formatter** in `dump()` (:1563/1565). |
| `Json_wrap` | `(HPtr) -> HPtr` | PA + PH | – | 1 ENC_* Custom | **Feasible** | Dispatches on runtime heap tag (`:1618` Int / `:1631` Float / `:1648` `isString`) → `eco.get_tag` + `eco.construct.custom` is a direct dialect equivalent. |
| `Json_wrap_Int` | `(i64) -> HPtr` | PA | – | 1 Custom, `unboxed=1` (:1671) | **Trivial** | one `eco.construct.custom{ctor=ENC_INT}`. |
| `Json_wrap_Float` | `(f64) -> HPtr` | PA | – | 1 Custom, `unboxed=2` (:1683) | **Trivial** | as above, `ENC_FLOAT`. |
| `Json_wrap_Char` | `(u16) -> HPtr` | PA | – | 1 Custom (:1695) | **Trivial** | Emits `ENC_INT` (code point) — Json has no char type. Semantically lossy but documented. |
| `Json_encodeNull` | `() -> HPtr` | PA | – | 1 Custom, 0 fields (:1711) | **Trivial** | `ENC_NULL`. Prime CAF-memoization candidate. |
| `Json_emptyArray` | `() -> HPtr` | PA | – | 1 Custom, 1 boxed=Nil (:1722) | **Trivial** | `ENC_ARRAY`. |
| `Json_emptyObject` | `() -> HPtr` | PA | – | 1 Custom, 1 boxed=Nil (:1734) | **Trivial** | `ENC_OBJECT`. |
| `Json_addEntry` | `(HPtr,HPtr,HPtr) -> HPtr` | PA + PH | **HOF** | closure result + cons + Custom (:1746) | **Feasible** | Calls `func(entry)` at `:1757`; then `cons` + `ENC_ARRAY`. All three are existing eco ops. |
| `Json_addField` | `(HPtr,HPtr,HPtr) -> HPtr` | PA + PH | – | Tuple2 + cons + Custom (:1787) | **Feasible** | Pure `eco.construct.tuple2` + `eco.construct.list` + `eco.construct.custom`. |

### Url (`elm-kernel-cpp/src/url/UrlExports.cpp`) — 2 symbols

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Url_percentEncode` | `(HPtr) -> HPtr` | PA + PH | – | 1 ElmString (`allocStringFromUTF8`, :61); plus `std::string`/`ostringstream` on the C++ heap | **Elm-source** | Pure char transform. **Semantics bug**: `shouldEncode` (:24–30) uses the RFC-3986 unreserved set, so `!*'()` get encoded; `encodeURIComponent` (what Elm's docs promise) leaves them alone. Also `std::ostringstream`+`std::hex`+`setw` per char (:49–58) — locale-dependent and very slow vs a 2-byte table. |
| `Url_percentDecode` | `(HPtr) -> HPtr` | PA + PH | – | 1 ElmString + 1 `Just` Custom (:96–99), or the `Nothing` embedded constant | **Elm-source** | **Two semantics bugs**: (a) `'+'` → `' '` at `:88–90`; `decodeURIComponent("+") == "+"`. (b) Decoded bytes are never UTF-8-validated — raw bytes go straight to `allocStringFromUTF8`, so a bad escape yields a corrupt String instead of `Nothing`. |

### Parser (`elm-kernel-cpp/src/parser/ParserExports.cpp`) — 7 symbols

`resolveString` (:81) → `parserFlatten` (:59) → `StringOps::ensureFlat` **allocates**
for rope/slice sources, so every one of these is a potential GC point even when
its own body allocates nothing. UTF-8/ASCII and already-flat sources bypass it.

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Parser_isAsciiCode` | `(i64,i64,HPtr) -> HPtr` | PH | – | none of its own (returns the embedded Bool constant, `:133`); `ensureFlat` may | **Feasible** | Simplest of the family: `off>=0 && off<len && at(off)==code` (:132). Needs `eco.string.code_unit_at` + `eco.string.length` — neither exists in `Ops.td` today. |
| `Parser_isSubChar` | `(HPtr,i64,HPtr) -> i64` | PH | **HOF** | none of its own; closure may; `ensureFlat` may | **Feasible** (needs devirt) | Calls `eco_apply_closure_typed` at `:179` with a `PK_Char` layout. Roots the closure across `resolveString` (`StackRootGuard`, :145) precisely because flatten can GC. Handles surrogate pairs (`:162–168`), returns `-2` for `'\n'`. Best lever = compile-time recognition of the handful of real predicates (`Char.isAlphaNum`, literal-char lambdas — see `Parser/Advanced.elm:484`) and emit a non-HOF specialisation. |
| `Parser_isSubString` | `(HPtr,i64,i64,i64,HPtr) -> HPtr` | PA + PH | – | 1 Tuple3, all fields unboxed (`intIntIntTuple`, :119) | **Feasible** | Roots **both** strings across **both** flattens (`:201–205`) — correct and non-obvious. Scan + row/col + surrogate pairing at `:213–229`. |
| `Parser_findSubString` | `(HPtr,i64,i64,i64,HPtr) -> HPtr` | PA + PH | – | 1 Tuple3, unboxed (:119) | **Feasible** | Same rooting discipline. **Perf bug**: naive O(n·m) double loop at `:260–273`; the comment at `:258` claims parity with `String.prototype.indexOf` ("also linear") — it is not. Should be `memmem`/two-way regardless of where it lives. |
| `Parser_chompBase10` | `(i64,HPtr) -> i64` | PH | – | none of its own; `ensureFlat` may | **Feasible** | Pure digit-run scan (`:284–295`). Primitive in, primitive out — the single best dialect-op candidate in the whole audit. |
| `Parser_consumeBase` | `(i64,i64,HPtr) -> HPtr` | PA + PH | – | 1 Tuple2, both unboxed (`intIntTuple`, :113) | **Feasible** | `:299–312`. The tuple is already an `eco.construct.tuple2`; only the scan needs a new op. |
| `Parser_consumeBase16` | `(i64,HPtr) -> HPtr` | PA + PH | – | 1 Tuple2, unboxed (:113) | **Feasible** | `:316–336`. Same shape. |

### Regex (`elm-kernel-cpp/src/regex/RegexExports.cpp`) — 7 symbols

**Backing library: vendored SRELL** (`#include "../../vendor/srell.hpp"`,
`RegexExports.cpp:13`). Not `std::regex`, not PCRE. `Regex.hpp:16–19` records
why: `std::basic_regex<char16_t>` is a libstdc++ extension, libc++ ships no
`char16_t` regex_traits, and SRELL is properly Unicode-aware.
**This is a real implementation, not a stub** — the "STUBS" label at
`KernelExports.h:540` is stale.

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Regex_never` | `() -> HPtr` | **RT** + PA | – | `new srell::regex` (C++ heap, never freed) + 1 Custom (:152–169) | n/a (RT) | Mutates the global `regexTable()` + `s_nextRegexId` (`:36–46`). Compiles `(?!)` **on every call**. Non-atomic global counter → not thread-safe. |
| `Regex_infinity` | `() -> f64` | P | – | none (:171–174) | **Trivial** (should be a constant) | ⚠️ **Suspected ABI mismatch — see K12.** |
| `Regex_fromStringWith` | `(HPtr,HPtr) -> HPtr` | **RT** + PA + PH | – | `new srell::regex` + Custom + `Just` (:176–221) | n/a (RT) | Registers into the never-freed side table (`:204–205`). Returns `Nothing` on `regex_error`. Reads the options Record's boxed Bools at `:190–191`. |
| `Regex_contains` | `(HPtr,HPtr) -> HPtr` | PH | – | none on the GC heap (returns embedded Bool, `:236`); one `std::string` on the C++ heap | **Hard-Infeasible** | Needs a regex engine; nothing to move. |
| `Regex_findAtMost` | `(i64,HPtr,HPtr) -> HPtr` | PA + PH | – | per match: strings, `Just`s, cons cells, a 4-field Record (`createMatch`, :83–124) | **Hard-Infeasible** | Correct rooting: `std::deque` for address-stable slots (`:262`, rationale at `:259–261`), each pushed slot range-rooted at `:294`. **Index bug**: `byteOffsetToCharIndex` (:127) counts UTF-8 *code points*, but Elm's `Match.index` is a UTF-16 code-unit index — off by one per astral char. |
| `Regex_replaceAtMost` | `(i64,HPtr,HPtr,HPtr) -> HPtr` | PA + PH | **HOF** | Match records + result ElmString (:396) | **Hard-Infeasible** | `eco_apply_closure` at `:378`. Snapshots the subject to a C-stack `std::string` **before** rooting begins (`:330`) so GC can't invalidate it — good pattern. Same char-index bug via `createMatch`. |
| `Regex_splitAtMost` | `(i64,HPtr,HPtr) -> HPtr` | PA + PH | – | one ElmString per part + cons cells | **Hard-Infeasible** | Same `std::deque` rooting idiom (`:422`, `:442`, `:451`). |

### Bytes (`elm-kernel-cpp/src/bytes/BytesExports.cpp`) — 26 header symbols + 2 BF hooks

`KernelExports.h:469` labels this section "STUBS". **Stale** — it is fully
implemented. `alloc::nothing()` is `empty()` — an *embedded constant*
(`HeapHelpers.hpp:196`), so every `Nothing` return below is allocation-free.

| Symbol | Signature | Class | HOF | Allocates | Part2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Bytes_width` | `(HPtr) -> HPtr` | PH | – | none (:299) | **Trivial** | Returns a **raw i64** wrapped in `HPtr` — declaration lies about the type (same latent class the header already documents+fixed for `JsArray_length`, `KernelExports.h:236–240`). |
| `Bytes_getHostEndianness` | `() -> HPtr` | P | – | none (:303) | **Trivial** (compile-time constant) | ⚠️ Returns `HPtr::fromBits(0 or 1)` — a *heap pointer to address 0/1*, not a Custom. See K13. |
| `Bytes_getStringWidth` | `(HPtr) -> i64` | PH | – | none; may materialise a `std::u16string` for rope/slice (:336) | **Feasible** | O(1) on the UTF-8 fast path (`:320–322`); otherwise a UTF-16 scan (`:343–364`). |
| `Bytes_encode` | `(HPtr) -> HPtr` | PA + PH | – | 1 ByteBuffer, LOT-aware (`allocByteBufferBlank`, :409) | **Already-intrinsic** | The interpreter. `encoderSize` (:124) then `writeEncoder` (:144). Roots the encoder across the allocate via `StackRootRangeGuard` (:409). Fused path bypasses it entirely (`bf.alloc` + `bf.write_*`). |
| `Bytes_decode` | `(HPtr,HPtr) -> HPtr` | PA + PH | **HOF** | 1 `Just` Custom (:452) | **Already-intrinsic** | Calls the decoder closure with `(bytes, 0)` via `eco_apply_closure_typed` (:431). Short-circuits on the `Nothing` embedded constant (`resultHP.ptr_ind != 0`, :439). |
| `Bytes_decodeFailure` | `() -> HPtr` | P | – | none — returns `empty()` (:469) | **Trivial** | This is a *call* that returns a compile-time constant. Should be `eco.constant`. |
| `Bytes_read_i8` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii (`makeTuple2_ii`, :45) | **Already-intrinsic** / Feasible | `:492`. Load + bounds check. |
| `Bytes_read_u8` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii | **Already-intrinsic** / Feasible | `:499`. |
| `Bytes_read_i16` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii | **Already-intrinsic** / Feasible | `:507`. `memcpy` + conditional `__builtin_bswap16`. |
| `Bytes_read_i32` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii | **Already-intrinsic** / Feasible | `:518`. |
| `Bytes_read_u16` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii | **Already-intrinsic** / Feasible | `:529`. |
| `Bytes_read_u32` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 ii | **Already-intrinsic** / Feasible | `:539`. |
| `Bytes_read_f32` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 if (`makeTuple2_if`, :55) | **Already-intrinsic** / Feasible | `:549`. `bswap32` on the bit pattern, then reinterpret. |
| `Bytes_read_f64` | `(HPtr,HPtr,i64) -> HPtr` | PA + PH | – | 1 Tuple2 if | **Already-intrinsic** / Feasible | `:561`. |
| `Bytes_read_bytes` | `(i64,HPtr,i64) -> HPtr` | PA + PH | – | 1 ByteBufferSlice header + 1 Tuple2 ip (:573) | **Feasible** | Zero-copy slice view (`makeByteBufferSlice`, :581); flattens below a size threshold. |
| `Bytes_read_string` | `(i64,HPtr,i64) -> HPtr` | PA + PH | – | UTF-8 view / UTF-8 leaf / UTF-16 ElmString + Tuple2 ip (:586) | **Feasible** | Richest reader: HEAP_032 zero-copy UTF-8 view at `:631`, small inline UTF-8 leaf at `:636`, legacy 2-pass UTF-16 transcode at `:646–710`. Roots `srcHP` across the allocate and re-derives the raw pointer (`:668–676`). |
| `Bytes_write_i8` | `(i64) -> HPtr` | PA | – | 1 Custom, `unboxed=1` (`makeEncoder1`, :719) | **Elm-source (already done)** | See K7 — dead export. |
| `Bytes_write_i16` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Custom, boxed+i64 (`makeEncoder2_pi`, :738) | **Elm-source (already done)** | dead export. |
| `Bytes_write_i32` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Custom (:738) | **Elm-source (already done)** | dead export. |
| `Bytes_write_u8` | `(i64) -> HPtr` | PA | – | 1 Custom (:719) | **Elm-source (already done)** | dead export. |
| `Bytes_write_u16` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Custom (:738) | **Elm-source (already done)** | dead export. |
| `Bytes_write_u32` | `(HPtr,i64) -> HPtr` | PA + PH | – | 1 Custom (:738) | **Elm-source (already done)** | dead export. |
| `Bytes_write_f32` | `(HPtr,f64) -> HPtr` | PA + PH | – | 1 Custom, boxed+f64 (`makeEncoder2_pf`, :757) | **Elm-source (already done)** | dead export. |
| `Bytes_write_f64` | `(HPtr,f64) -> HPtr` | PA + PH | – | 1 Custom (:757) | **Elm-source (already done)** | dead export. |
| `Bytes_write_bytes` | `(HPtr) -> HPtr` | PA + PH | – | 1 Custom (`makeEncoderBytes`, :821) | **Elm-source (already done)** | dead export. |
| `Bytes_write_string` | `(HPtr) -> HPtr` | PA + PH | – | 1 Custom + a `getStringWidth` scan (`makeEncoderUtf8`, :796) | **Elm-source (already done)** | dead export. |
| `elm_encoder_size` *(not in header)* | `(HPtr) -> u32` | PH | – | none (:379) | keep C++ | BF escape hatch `bf.encoder.width`; gc-leaf. |
| `elm_encoder_write_into` *(not in header)* | `(HPtr,u8*) -> u32` | PH | – | none, writes into a caller buffer (:386) | keep C++ | BF escape hatch `bf.write.encoder`; gc-leaf. |

### Class counts (77 header symbols)

| Class | Count | Where |
|---|---|---|
| `P` (pure, non-allocating) | **3** | `Regex_infinity`, `Bytes_getHostEndianness`, `Bytes_decodeFailure` |
| `PA` (allocates) | **56** | 33 Json + 2 Url + 3 Parser + 4 Regex + 14 Bytes |
| `PH` (reads heap via HPtr) | **50** (overlaps PA) | everything taking an `HPtr` payload |
| `PH`-only (no GC alloc of its own) | **7** | `Parser_isAsciiCode`, `Parser_isSubChar`, `Parser_chompBase10`, `Regex_contains`, `Bytes_width`, `Bytes_getStringWidth` (+`elm_encoder_size`) |
| `RT` (runtime-internal mutable state) | **2** | `Regex_never`, `Regex_fromStringWith` (global `regexTable`) |
| `HOF` | **6** | `Json_run`, `Json_runOnString`, `Json_addEntry`, `Parser_isSubChar`, `Regex_replaceAtMost`, `Bytes_decode` |
| `TB` / `E` / `X` | **0** | none in this group — no IO anywhere |
| `STUB` (live surface) | **0** | all 77 are implemented |
| `STUB` (dead files) | **6 functions** | `Bytes.cpp:108`, `Regex.cpp:50,73,81,89` + `Regex.cpp` `never` is a non-registering variant |

### Part 2 verdict counts

| Verdict | Count |
|---|---|
| `Already-intrinsic` | 12 (Bytes `encode`/`decode`/`read_*` — BF dialect already covers the fused path) |
| `Trivial` | 33 (30 Json constructors + `Bytes_width`/`getHostEndianness`/`decodeFailure`, + `Regex_infinity`) |
| `Feasible` | 15 (7 Parser, `Json_wrap`/`addEntry`/`addField`, `Bytes_getStringWidth`/`read_bytes`/`read_string`) |
| `Elm-source` | 12 (2 Url + 10 Bytes `write_*`, the latter already migrated) |
| `Hard-Infeasible` | 8 (`Json_run`/`runOnString`/`encode`, 5 real Regex ops) |

---

## Key findings

1. **The "STUBS" labels on Bytes (`KernelExports.h:469`) and Regex (`:540`) are
   stale and actively misleading.** Both modules are fully implemented in
   `BytesExports.cpp` and `RegexExports.cpp`. **No symbol on the live export
   surface is a stub.** Regex is backed by **vendored SRELL**
   (`RegexExports.cpp:13`), chosen over `std::regex` because libc++ has no
   `char16_t` regex_traits (`Regex.hpp:16–19`).

2. **Three whole files are compiled but unreachable, and they *are* the stubs.**
   `src/bytes/Bytes.cpp`, `src/regex/Regex.cpp`, `src/url/Url.cpp` are listed in
   `elm-kernel-cpp/CMakeLists.txt:192,252,277` but nothing in the tree references
   `Elm::Kernel::{Bytes,Regex,Url}::*`. `Bytes.cpp:108–113` (`decode` → `nothing()`)
   and `Regex.cpp:50–52,73–95` (`fromStringWith` → "TODO … For now return Nothing",
   `findAtMost`/`replaceAtMost`/`splitAtMost` → explicit stubs) are the real stubs.
   ~630 lines of dead object code. **Delete them.**

3. **The dead `Url.cpp` is the *correct* implementation and the live
   `UrlExports.cpp` is the buggy one.** `Url.cpp:15–26 isUnreserved` has the
   `encodeURIComponent` set (`-_.!~*'()`); `UrlExports.cpp:24–30 shouldEncode`
   has the RFC-3986 set, so `Url.percentEncode "!"` returns `"%21"` where Elm
   promises `"!"`. `Url.cpp:82–134 utf8ToUtf16` validates and returns `Nothing`
   on malformed input; `UrlExports.cpp:96` does not. And
   `UrlExports.cpp:88–90` maps `'+'` → `' '`, which `decodeURIComponent` does
   not. None of the three divergences is covered by
   `test/elm-url/src/*.elm` (only space and `&`/`=` are tested).

4. **Q1 — Json decoder constructors are nothing but a tagged Custom allocation.**
   `makeDecoder0/1/1i/2/2ip` (`JsonExports.cpp:464–539`) and `buildMapDecoder`
   (`:1456`) are literally `eco_alloc_with_roots(Tag_Custom, size, roots, n, mask)`
   + set `ctor` + store fields. **30 of the 35 Json exports are one
   `eco.construct.custom` with a compile-time-constant ctor index** — an existing
   dialect op (`Ops.td:873`). Inlining them at the call site removes 30 kernel
   calls, their PLT hops, and (for the alloc-free path) their statepoints, with
   **no Elm-source rewrite required**. This is the single highest
   value/lowest risk item in the audit.

5. **Q1 — why they are C++ at all, and what genuinely blocks Elm source.** It is
   *not* the allocation. `elm/json`'s `type Decoder a = Decoder`
   (`json/1.1.4/src/Json/Decode.elm:62`) is a phantom stub, and the real blocker
   is that the decoder ADT is a **GADT**: `Map2 : (a -> b -> c) -> Decoder a ->
   Decoder b -> Decoder c` and `DecList : Decoder a -> Decoder (List a)` both
   need type variables that don't appear on the LHS of the `type` declaration.
   Elm has no existentials, so `type Decoder a = …` cannot express them.
   **The viable migration is the closure encoding** — `type Decoder a = Decoder
   (Value -> Result Error a)` — which is exactly what `Bytes.Decode` already does
   (`bytes/1.0.8/src/Bytes/Decode.elm:80,190–200`). Cost: it destroys
   `runDecoder`'s ability to *introspect* the tree, which it uses for the
   unboxed-element-kind specialisation at `JsonExports.cpp:641–645`, `:749–754`,
   `:999–1003`, and for the flags/incoming-port decoder path.

6. **Bytes is the existence proof that the migration works.**
   `Bytes.Encode.Encoder` is a **real Elm ADT**
   (`bytes/1.0.8/src/Bytes/Encode.elm:40–51`), and `writeEncoder`'s `EncoderTag`
   enum (`BytesExports.cpp:93–105`) pins `I8=0 … Bytes=10` to that declaration
   order. So the "C++ interpreter over an Elm-declared ADT" pattern is already
   shipping and green. The same contract would let the Json decoder tree be
   declared in Elm — the coupling is declaration order, which is unenforced by
   any test in either module. **Add a golden test pinning ctor indices** before
   relying on it further.

7. **All 10 `Elm_Kernel_Bytes_write_*` exports are dead, with an arity mismatch
   to boot.** Their only Elm caller is `Bytes.Encode.write`
   (`Encode.elm:286–298`) which passes **three** args (`mb offset n`); the C++
   takes **one** (`BytesExports.cpp:839`). And `write` is itself dead Elm —
   `Bytes.Encode.encode` (`Encode.elm:97–98`) goes straight to
   `Elm.Kernel.Bytes.encode`. The only other reference is BytesFusion's
   *compile-time* pattern `("write_u8", [valueExpr])`
   (`BytesFusion/Reify.elm:412–421`), which never emits a call. Safe to delete.

8. **Q2 — `Json_run`/`runOnString` are closure-calling; `Json_encode` is not.**
   `runDecoder` reaches `eco_apply_closure` at `:1117` (andThen), `:1167`
   (map1), `:1198` (map2), `:1258` (map3–8). `elmToJson` (`:1274–1370`) is a pure
   tree walk. The irreducible pieces are exactly two: the **JSON text parser**
   (`json::parse`, `:1537`) and the **shortest-round-trip double formatter**
   (nlohmann `dump()`, `:1563/1565`) — the latter must stay bit-exact or the
   round-trip goldens in `test/elm-json/` break.

9. **The JSON pipeline pays for three representations of the same data.**
   `runOnString` parses text → `nlohmann::json` DOM on the C++ heap →
   `jsonToHeap` (`:305`) copies the *entire* DOM into `CTOR_JSON_*` GC Customs →
   `runDecoder` walks that. Symmetrically `encode` walks the `ENC_*` tree into a
   fresh nlohmann DOM (`elmToJson`) and only then dumps. A streaming decoder
   driven straight off the text, and a direct `ENC_*`-tree→string writer, would
   delete both DOMs. **Biggest allocation-reduction opportunity in the group.**

10. **`runDecoder`'s `DEC_FIELD` is quadratic on record decoding.**
    `JsonExports.cpp:942` transcodes the field name to `std::string`, then
    `:959` transcodes **every key in the object** to `std::string` to compare
    (`:960`). `DEC_MAP2..MAP8` (`:1173–1262`) then run each sub-decoder over the
    *same* JSON value — so an 8-field record decode re-walks and re-transcodes
    the whole key list 8 times. Fix: compare `ElmString`s directly (StringOps
    has UTF-8 fast paths at `StringOps.hpp:656`) instead of materialising
    `std::string` per key. This is on the hot path for every `runOnString`.

11. **Q6 continued — Regex leaks compiled patterns and is not thread-safe.**
    `new srell::regex` at `RegexExports.cpp:155` and `:204` goes into a static
    `std::unordered_map` (`:36–46`) that is **never freed** (deliberate, per the
    comment) and is keyed by a plain non-atomic `s_nextRegexId++`. Building
    regexes in a loop leaks unboundedly. Separately, `Regex_never()` (`:152`)
    recompiles `(?!)` on **every call** — mitigated only by CAF memoization.
    And `Match.index` is wrong for astral input: `byteOffsetToCharIndex`
    (`:127–146`) counts UTF-8 code points, but Elm's `Match.index` is a UTF-16
    code-unit index.

12. ⚠️ **Suspected ABI mismatch: `Elm_Kernel_Regex_infinity`.** It is declared
    and defined as returning `double` (`KernelExports.h:544`,
    `RegexExports.cpp:171–174` → `+inf` in `xmm0`), but its only consumers are
    `findAtMost`/`splitAtMost`/`replaceAtMost`, whose first parameter is `Int`
    (`elm/regex/1.0.0/src/Regex.elm:240,254,265`; used at `:143,169,226`). Kernel
    types here are **inferred from usage** (`compiler/src/Compiler/Type/KernelTypes.elm`
    — there is no static signature table for Regex), so the call site should
    expect an integer in `rax`. `test/elm-regex/RegexFindTest.elm` and
    `RegexSplitTest.elm` exercise this path and pass — but only because the C++
    treats any `n <= 0` as unlimited (`if (n > 0 && matchNum >= n) break;`,
    `:272,347,433`), so a garbage `rax` is usually harmless. A garbage value
    that happens to be a small positive integer would silently truncate
    `Regex.find`/`split`/`replace`. **Verify by disassembling the caller**;
    the fix is to make `infinity` an `i64` sentinel (e.g. `-1`) or a compiler
    constant.

13. ⚠️ **`Elm_Kernel_Bytes_getHostEndianness` returns a malformed HPointer.**
    `BytesExports.cpp:303–307` returns `HPtr::fromBits(0)` or `fromBits(1)` —
    words with `ptr_ind == 0`, i.e. **heap pointers to address 0 or 1**, not
    Customs and not embedded constants. The nullary-enum optimisation that would
    make bare ctor indices legal is explicitly **not implemented**
    (`Heap.hpp:199–207`: `enum_idx : 10` … "always 0 for now"). Anything that
    resolves the result — e.g. `endiannessHPointerToBool`
    (`BytesExports.cpp:111–116`), which the `write_*` path uses — will
    dereference garbage. There is also an arity mismatch: the Elm side is
    `Elm.Kernel.Bytes.getHostEndianness LE BE` (`bytes/1.0.8/src/Bytes.elm:138`,
    2 args) vs 0 args in C++. Untested and latent. Relatedly,
    `Elm_Kernel_Bytes_width` (`:299`) declares an `HPtr` return but returns a raw
    `i64` — the same declaration lie the header already documents and fixed for
    `JsArray_length` (`KernelExports.h:236–240`).

14. **Q5 — Bytes `read_*` as dialect ops is the *wrong* framing; it's already
    done, and the load was never the cost.** The BF dialect already has
    `bf.read_u8/u16/u32/f32/f64` + `bf.require`
    (`design_docs/theory/bytes_fusion_theory.md:79–89`), lowered in `BFToLLVM.cpp`
    to "bounds check + dereference + endian swap + advance" with `llvm.bswap`.
    The C++ `Elm_Kernel_Bytes_read_*` are the *non-fused fallback* only. In that
    fallback the load+bswap is 1–2 instructions (`BytesExports.cpp:507–571`) while
    the **`Tuple2` allocation per primitive read** (`makeTuple2_ii`/`_if`,
    `:45–63`) plus the `Maybe` wrap in `Bytes_decode` (`:447–466`) is a heap
    allocation and a GC point. The win is removing the tuple — which is exactly
    what fusion does by threading `!bf.cursor` in SSA. **Invest in broader BF
    reification coverage, not in new `eco.*` load ops.**

15. **Q3 — the Parser family is the best dialect candidate, but is blocked on
    one missing primitive, not on seven functions.** All seven are pure index
    scans with primitive signatures. What blocks them is that Eco has **six**
    string representations (`Tag_String`, `Tag_LargeStringHeader`,
    `Tag_StringSlice`, `Tag_StringRope`, `Tag_StringUtf8View`,
    `Tag_StringUtf8Leaf` — `Heap.hpp:80–112`) and `Ops.td` has **no** string
    indexing op at all (only `eco.string_literal`, `eco.string.from_int`,
    `eco.string.from_float`). Today `resolveString` (`ParserExports.cpp:81`) calls
    `ensureFlat`, which **allocates** — so none of these is even gc-leaf. Adding
    `eco.string.code_unit_at` + `eco.string.length` over a canonical flat view
    would make `isAsciiCode`, `chompBase10`, `consumeBase`, `consumeBase16`
    allocation-free and gc-leaf (eligible for the shipped
    gc-free-function-propagation win), and would let `isSubString`/`findSubString`
    keep only their tuple allocation. `isSubChar` stays HOF
    (`eco_apply_closure_typed`, `:179`) unless the compiler devirtualises the
    handful of real predicates (`Char.isAlphaNum`, literal-char lambdas —
    `Parser/Advanced.elm:484`). Elm-source is **not** viable here: without an
    indexing primitive, `String.uncons`/`String.slice` per character makes every
    scan O(n²) with an allocation per step. Independently, `findSubString`'s
    naive O(n·m) double loop (`:260–273`) should become `memmem`/two-way
    regardless of where it lives — the comment claiming parity with
    `String.prototype.indexOf` (`:258`) is wrong.
