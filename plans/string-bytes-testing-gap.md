# String / Bytes Representation Testing Gap — Plan

**Purpose:** Close the testing gap around the runtime's byte-buffer and String
representations (flat / slice / rope / large-split-header) and the kernel code
that consumes and converts between them. A five-part audit found that flat forms
are well tested on both axes, but the non-flat *representation machinery* is
barely tested for byte buffers, hardly tested end-to-end for either type, and
that the compiler-facing `elm-kernel-cpp` export ABI has **no C++ unit harness
at all**.

**Scope:** 52 new test cases (19 E2E `.elm`, 33 C++ unit) + 1 GC-generator
extension + 2 code fixes.

**Test formats:**
- E2E: `.elm` files with `-- CHECK: <label>: <expected>` lines, globbed by
  suite (`test/elm-bytes/src/`, `test/elm-core/src/`, `test/elm/src/`), run via
  `--target full` / `--target check`.
- C++ unit: rapidcheck + custom `TestSuite.hpp` harness under `test/allocator/`
  (and a new `test/kernel/`), linked into the `test` binary, run via the same
  targets or `build/test/test --filter <suite>`.

---

## Background: the representations

**Byte buffers** (`runtime/src/allocator/Heap.hpp`), all carrying logical byte
count in `header.size`:
- `Tag_ByteBuffer` — flat inline bytes.
- `Tag_LargeByteHeader` — 16 B nursery header → pinned flat body in old gen;
  taken at payload ≥ `LARGE_OBJECT_THRESHOLD` (8 KiB).
- `Tag_ByteBufferSlice` — 24 B offset+length view; produced only when slice
  length ≥ `MAKE_BYTEBUFFER_SLICE_MIN_LEN` (32 B), else flattened.
- (transient) `Custom` encoder tree → flat buffer (`BytesExports.cpp`); fused
  `bf` cursor `{i8*, i8*}` (`BFToLLVM.cpp`, covered by `bf-dialect-tests.md`).

**Strings** (`Heap.hpp`, HEAP_025), `header.size` = logical UTF-16 code units:
- `Tag_String` — flat leaf (only form the compiler emits directly).
- `Tag_StringSlice` — 24 B view; produced when slice length > 128 code units.
- `Tag_StringRope` — concat node; built when append/concat total > 32 KiB units.
- `Tag_LargeStringHeader` — split header → pinned leaf body; taken at ≥ 8 KiB.
- `Const_EmptyString` — the only interned string (embedded constant, no alloc).

**Conversion hubs:** `HeapHelpers.hpp` (`byteBufferView`, `resolveByteBufferBody`,
`makeByteBufferSlice`), `StringOps.hpp/.cpp` (`forEachSegment`, `charAt`,
`toStdU16String`, `flattenToLeaf`, `makeSlice`, `makeRope`).

**Compiler-facing kernel ABI (untested in isolation):**
`elm-kernel-cpp/src/bytes/BytesExports.cpp` (encoder-tree serialization,
extern-`"C"` decoders) and `elm-kernel-cpp/src/core/StringExports.cpp`
(closure-driven `foldl`/`map`/`filter`/… + `Const_EmptyString` handling).

---

## Status (2026-07-02)

Implemented all 60 tests and both code fixes; re-scoped the astral tests per the
F2 decision below. **Final run: 1547 passed, 0 failed (Result: PASSED).**
- **F1 — FIXED** (`getObjectSize` slice case; restores HEAP_004). Verified by U11
  (now passes) and U6/U15/U25 (no longer abort the collector).
- **F3 — FIXED** (`elm_bytebuffer_len` → `byteBufferLength`). Verified by K11/K13
  and E11/E20 (no longer SIGABRT); one fix covered all 5 call sites.
- **F2 — recorded as a deliberate divergence, not fixed.** Eco's Char is `i16`
  (enforced REP_ABI_001 / CGEN_015: "MChar → i16, not i32"), so a Char cannot hold
  a code point > U+FFFF. `String.foldl/map/filter/toList/reverse/uncons` therefore
  iterate by UTF-16 code unit, and `Char.fromCode` clamps astral code points to
  U+FFFF (65535). The astral tests (E2–E7, K10) were re-scoped to characterize
  this actual behavior. Full Elm astral parity is a separate project that would
  widen Char across the ABI/SSA/heap/codegen/kernel surface (changing the two
  enforced invariants above) — tracked as future work, not part of this plan.

## Code fixes (tests pin/guard these)

| Fix | Location | Description |
|-----|----------|-------------|
| F1 | `AllocatorCommon.hpp:294` (`getObjectSize`) | Missing `case Tag_ByteBufferSlice` (the sibling `Tag_StringSlice` case is present at :221) → falls through to `default` (8 B) instead of `sizeof(ElmByteBufferSlice)` (24 B). **Highest severity — silent GC corruption, not an abort.** Drives minor-GC evacuation (`NurserySpace.cpp:1145/1159` memcpy 8 of 24 B → slice `base`+`offset` never copied) and Cheney scan stride (`:681/709` → collector parses the uncopied `base` as the next header → abort/garbage), plus latent old-gen sweep/mark/compaction (`OldGenSpace.cpp:1915/2682/3791/3955`). Any live ≥32 B byte slice across one minor GC. Verified by two independent audits. Guarded by U6, U11, U15, U25. |
| F2 | `StringExports.cpp` (`Elm_Kernel_String_{foldl,foldr,map,filter,any,all}`, `snapshotChars`) + `StringOps.cpp`/`String.cpp` fold variants; `Char.fromCode` | **Not a bug fixable in isolation — a consequence of `i16` Char (enforced REP_ABI_001/CGEN_015).** These iterate raw `u16` code units, so astral chars are handled as their two surrogate halves, and `Char.fromCode` clamps astral code points to U+FFFF. Elm code-point parity would require widening Char (a separate cross-phase project). Characterized (not pinned as fail-now) by E2–E7, K10. See the Status note above. |
| F3 | `ElmBytesRuntime.cpp:81` (`elm_bytebuffer_len`) | Reads length via `resolveByteBufferBody(ptr)->header.size`, which asserts on `Tag_ByteBufferSlice`. **Confirmed live crash**: `Bytes.width` on a slice (produced by `Bytes.Decode.bytes`) aborts — reproduced by `projects/eco-test` PNG decode (`Inflate.ZLib.slice` → `Bytes.width`). Fix: call slice-safe `byteBufferLength(ptr)`. Siblings `elm_bytebuffer_data`/`_with_data` already correct. **Blast radius = 5 call sites** funneling through this one function: the direct export `Elm_Kernel_Bytes_width` (`BytesExports.cpp:291`) + four fused `bf` lowerings — `bf.bytes_width` (`BFToLLVM.cpp:514`), `bf.cursor.init` (:217, fused encode), `bf.decoder.cursor.init` (:1031, fused decode over a slice), `bf.write.bytes` (:435, fused `Encode.bytes` embedding a slice). The one fix resolves all five. Debug/`ECO_HEAP_VALIDATE` builds abort; release accidentally returns the correct length via `header.size` aliasing. Pinned by E20, E22, K11. |

---

## G1 — Astral / surrogate-pair characters (known bug; no test at any layer)

Elm semantics asserted: `length` counts **code units**; `foldl`/`foldr`/`map`/
`filter`/`toList`/`reverse`/`uncons` iterate by **code point** and keep pairs
intact. Most **fail against current code** until F2 lands.

| ID | Test / File | Layer | Description | Status |
|----|-------------|-------|-------------|--------|
| E1 | `StringAstralLengthTest.elm` (`test/elm`) | E2E | `length "😀"`=2, `length "a😀b"`=4 (code units); exercises astral literal encoding | fail-now |
| E2 | `StringAstralFoldTest.elm` (`test/elm-core`) | E2E | `foldl`/`foldr` char-count `"😀"`=1, `"a😀b"`=3 | fail-now |
| E3 | `StringAstralToListFromListTest.elm` (`test/elm-core`) | E2E | `toList "a😀b"`=3 Chars; `fromList∘toList` round-trips | fail-now |
| E4 | `StringAstralReverseTest.elm` (`test/elm-core`) | E2E | `reverse "a😀b" == "b😀a"` (pair not byte-swapped) | fail-now |
| E5 | `StringAstralMapFilterTest.elm` (`test/elm-core`) | E2E | `map identity "😀"=="😀"`; filter keeps/drops the astral Char | fail-now |
| E6 | `StringAstralUnconsConsTest.elm` (`test/elm-core`) | E2E | `uncons "😀b" == Just('😀',"b")`; `cons '😀' "b"` round-trip | fail-now |
| E7 | `CharAstralCodeTest.elm` (`test/elm`) | E2E | `Char.toCode '😀'`=0x1F600; `fromCode 0x1F600` round-trip | fail-now |
| E8 | `EncodeDecodeStringAstralTest.elm` (`test/elm-bytes`) | E2E | encode→decode `"a😀b"` **content-equal**; width 6 | verify |
| U1 | `test_toStdString_combines_surrogate_pair` (`StringOpsTest.cpp`) | unit | u16 `{0xD83D,0xDE00}` → UTF-8 `F0 9F 98 80` | guard |
| U2 | `test_allocStringFromUTF8_emits_surrogate_pair` (`HeapHelpersTest.cpp`) | unit | 4-byte UTF-8 → two u16 units, `length`=2 | guard |
| U3 | `test_string_utf8_roundtrip_astral` (`StringOpsTest.cpp`) | unit | u16 → `toStdString` → `allocStringFromUTF8` → `equal` | guard |

## G2 — Byte-buffer slice & large-header (functionally untested) + F1

| ID | Test / File | Layer | Description | Status |
|----|-------------|-------|-------------|--------|
| U4 | `test_slice_returns_slice_tag_for_large_range` (`BytesOpsTest.cpp`) | unit | slice ≥32 B → `getTag==Tag_ByteBufferSlice`, length correct | new |
| U5 | `test_bytebuffer_slice_of_slice_collapses` (`BytesOpsTest.cpp`) | unit | slice-of-slice stays one slice, offset absorbed | new |
| U6 | `test_bytebuffer_slice_survives_gc` (`BytesOpsTest.cpp`) | unit | ≥32 B slice + neighbours, `minorGC`, bytes intact | pins F1 |
| U7 | `test_byteBufferView_reads_through_slice_offset` (`BytesOpsTest.cpp`) | unit | `getAt`/view over a slice returns `base+offset` data | new |
| U8 | `test_decode_int_float_over_slice` (`BytesOpsTest.cpp`) | unit | `decodeUnsignedInt`/`decodeFloat64` over a slice | new |
| U9 | `test_large_bytebuffer_ops` (`BytesOpsTest.cpp`) | unit | ≥8 KiB `Tag_LargeByteHeader`: getAt/slice/decode/equal/hash/toBase64 | new |
| U10 | `test_large_bytebuffer_append` (`BytesOpsTest.cpp`) | unit | append two ≥8 KiB buffers (both-inputs large path) | new |
| U11 | `test_getObjectSize_bytebuffer_slice` (`AllocatorCommonTest.cpp`) | unit | white-box: `getObjectSize(slice)==24` | pins F1 |
| E9 | `BytesLargeHeterogeneousBufferTest.elm` (`test/elm-bytes`) | E2E | mixed u8/u16/u32/f64/string encoder seq >8 KiB → decode back, content asserted | new |
| E10 | `BytesSliceViewTest.elm` (`test/elm-bytes`) | E2E | `D.bytes 64` (≥32 → real slice), re-decode ints from slice, assert values | new |
| E11 | `BytesSliceOfLargeParentGCTest.elm` (`test/elm-bytes`) | E2E | ≥32 B slice of large buffer, drop parent, GC churn, read slice | new |

## G3 — String slice / rope / split / join at E2E (all non-gated today)

| ID | Test / File | Layer | Description |
|----|-------------|-------|-------------|
| E12 | `StringLargeSliceTest.elm` (`test/elm-core`) | E2E | `slice`/`left`/`right`/`dropLeft` on 300- and 5000-char sources taking >128 chars → `Tag_StringSlice`; exact substring |
| E13 | `StringSliceOfLargeParentGCTest.elm` (`test/elm-core`) | E2E | slice of large string, drop parent, GC churn, read slice content |
| E14 | `StringRopeContentTest.elm` (`test/elm-core`) | E2E | rope via looped `++` >32768 units; assert `slice 32760 32776` (crosses leaf boundary) — not length-only |
| E15 | `StringRopeFoldlSliceTest.elm` (`test/elm-core`) | E2E | over a rope: `foldl` count, `toList`/`reverse` of a modest rope — content asserted |
| E16 | `StringConcatContentTest.elm` (`test/elm-core`) | E2E | 20-operand `++` and `String.concat` of a long list — content asserted |
| E17 | `StringSplitTest.elm` (`test/elm-core`) | E2E | `String.split`: single/multichar/empty sep, sep at ends (zero coverage today) |
| E18 | `StringJoinTest.elm` (`test/elm-core`) | E2E | `String.join` direct: multichar sep, empty list, singleton |

## G4 — Fuzzed GC never traces non-flat forms

Infra: extend `HeapGenerators.cpp` to emit `Tag_StringRope`, `Tag_StringSlice`,
`Tag_LargeStringHeader`, `Tag_ByteBuffer`, `Tag_ByteBufferSlice`,
`Tag_LargeByteHeader`, `Tag_Array` (today it emits none of these).

| ID | Test / File | Layer | Description |
|----|-------------|-------|-------------|
| U12 | `HeapGenerators.cpp` extension | unit-infra | random heaps include all 7 non-flat forms |
| U13 | `test_gc_traces_string_rope` (`NurserySpaceTest`/`OldGenSpaceTest`) | unit | random ropes survive minor+major GC, content intact |
| U14 | `test_gc_traces_string_slice` (`NurserySpaceTest`) | unit | slices survive; base evacuated & fixed-up |
| U15 | `test_gc_traces_bytebuffer_slice` (`NurserySpaceTest`) | unit | byte slices survive fuzzed GC (2nd guard on F1) |
| U16 | `test_gc_traces_large_headers` (`OldGenSpaceTest`) | unit | large string/byte headers + pinned bodies survive |

## G5 — Non-ASCII BMP content round-trips

| ID | Test / File | Layer | Description |
|----|-------------|-------|-------------|
| E19 | `EncodeDecodeStringUnicodeContentTest.elm` (`test/elm-bytes`) | E2E | encode `"café €λ"` (2/3-byte UTF-8) → decode → content-equal (only width checked today) |
| U17 | `test_encodeUtf8_decodeUtf8_multibyte` (`BytesOpsTest.cpp`) | unit | 2- and 3-byte UTF-8 round-trip (ASCII-only today) |

## G6 — Encode/decode width & offset holes; large-string top-level ops

| ID | Test / File | Layer | Description |
|----|-------------|-------|-------------|
| U18 | `test_encode_decode_signed_int32` (`BytesOpsTest.cpp`) | unit | signed W32 LE+BE (only signed 8/16 today) |
| U19 | `test_encode_decode_int64` (`BytesOpsTest.cpp`) | unit | 64-bit width LE+BE (no 64-bit int today) |
| U20 | `test_decode_at_nonzero_offset` (`BytesOpsTest.cpp`) | unit | int/float decode at offset > 0 (all start at 0 today) |
| U21 | `test_hash_distinguishes_buffers` (`BytesOpsTest.cpp`) | unit | different buffers → different hash (only consistency today) |
| U22 | `test_large_string_header_ops` (`StringOpsTest.cpp`) | unit | >4096-char top-level `Tag_LargeStringHeader`: length/charAt/slice/append/equal/toStdString |
| U23 | `test_compare_ordering_across_representations` (`StringOpsTest.cpp`) | unit | `compare` `<`/`>` (not just `==`) for slice-vs-flat & rope-vs-flat; `equal`→false for differing slices/ropes |

## G7 — Full op surface × non-flat representation (found via a live crash)

The `Bytes.width`-on-a-slice abort (F3) exposed a test-design flaw: the plan
covered each non-flat representation's *construction* plus hand-picked ops, but
never ran the **full public op surface against each representation**. A slice (or
rope / large-header) flowing into an op it was never paired with is exactly this
defect class. These matrix tests close it.

| ID | Test / File | Layer | Description | Status |
|----|-------------|-------|-------------|--------|
| E20 | `BytesWidthOfSliceTest.elm` (`test/elm-bytes`) | E2E | `decode (D.bytes 40) buf \|> Maybe.map Bytes.width == Just 40` (≥32 → real slice); minimal repro of the `Inflate.ZLib.slice` crash | fail-now (F3) |
| E21 | `BytesSliceOpMatrixTest.elm` (`test/elm-bytes`) | E2E | run every consumer op on one ≥32 B slice: `width`, `D.unsignedInt8/16/32`, `D.float64`, nested `D.bytes`, `D.string`, re-embed via `E.bytes` — assert each; catches any slice-hostile sibling | new |
| U24 | `test_string_op_matrix_slice_rope_large` (`StringOpsTest.cpp`) | unit | mirror for strings: run `length`/`charAt`/`slice`/`append`/`equal`/`toStdString`/`foldl` against slice, rope, and large-header inputs | new |
| E22 | `BytesFusedOpsOnSliceTest.elm` (`test/elm-bytes`) | E2E | fused paths over a slice: multi-field fused decoder run on a slice from a prior `D.bytes` (`bf.decoder.cursor.init`) + fused `E.bytes` embedding a slice (`bf.write.bytes`); correct results, no abort. Depends on the fusion pass firing — else fall back to a `bf`-dialect runtime lit test with a slice input | fail-now-in-debug (F3) |
| U25 | `test_bytebuffer_slice_survives_promotion` (`OldGenSpaceTest.cpp`) | unit | force a ≥32 B slice through multiple minor GCs into old gen, then major GC + compaction; validate content (old-gen sites 9–12; defense beyond F1) | pins F1 |

---

## Phase K — New `elm-kernel-cpp` export ABI unit suite

**Location:** `test/kernel/KernelExportsTest.cpp` (new), registered as suite
`KernelExports` in `test/main.cpp`; add `test/kernel/` to `test/CMakeLists.txt`.

**Purpose:** Unit-test the compiler-facing extern-`"C"` kernel ABI in
`elm-kernel-cpp/src/bytes/BytesExports.cpp` and
`elm-kernel-cpp/src/core/StringExports.cpp` **in isolation**, without going
through the compiler. This is the only place the encoder-tree serializer
(`encoderSize`/`writeEncoder`), the extern-`"C"` decoders (`read_*`), and the
closure-driven string ops live; today they are reachable only via E2E.

**Mechanics:** The `test` binary already whole-archive-links the kernel
archives, so `Elm_Kernel_*`, `elm_encoder_*`, and the `makeEncoder*` builders
are directly callable. Inputs are built with the `Allocator` singleton (strings
via `alloc::allocString`, buffers via `BytesOps::fromVector`, encoder trees via
the `makeEncoder*` builders). Closures for the higher-order string tests reuse
the existing closure-construction infra proven by the `EcoApplyClosureTyped` /
`GenericApplyBoxing` suites. Results are decoded with `byteBufferView` /
`alloc::getTag` / `StringOps` helpers.

| ID | Test | Target function(s) | Description | Status |
|----|------|--------------------|-------------|--------|
| K1 | `test_encoder_size_matches_write` | `encoderSize`, `writeEncoder`, `elm_encoder_size/_write_into` | Heterogeneous tree (u8,u16 BE,u32 LE,f64,utf8,bytes,nested seq): computed size == bytes written, final offset lands exactly at size | new |
| K2 | `test_encoder_endianness_bytes` | `writeEncoder` | `u16/u32/f32/f64` BE vs LE emit correctly byte-ordered output (`0x1234`→`12 34` / `34 12`) | new |
| K3 | `test_encoder_utf8_astral` | `writeEncoder` (`ENC_UTF8`) | encode `"a😀b"` → `61 F0 9F 98 80 62` (surrogate pair → 4-byte UTF-8) | new |
| K4 | `test_encoder_embeds_nonflat_bytes` | `writeEncoder` (`ENC_BYTES`) | `makeEncoderBytes` over a slice / large-header buffer copies correct bytes via `byteBufferView` | new |
| K5 | `test_encode_large_routes_large_header` | `Elm_Kernel_Bytes_encode` | tree summing >8 KiB → result length == encoder size; buffer is LOT-routed (`Tag_LargeByteHeader`) | new |
| K6 | `test_decoder_read_primitives` | `read_u8/u16/u32/f64`, `decoderNothing` | reads at various offsets return `Just(value)`; past-end returns `Nothing` | new |
| K7 | `test_decoder_read_bytes_produces_slice` | `read_bytes`, `makeByteBufferSlice` | `read_bytes 64` from a larger buffer → `Tag_ByteBufferSlice`, content matches | new |
| K8 | `test_decoder_read_string_utf8` | `read_string` | buffer with 2/3/4-byte UTF-8 → String with correct code-unit length + content (astral → pair) | new |
| K9 | `test_string_export_length_all_forms` | `Elm_Kernel_String_length` | correct length for `Const_EmptyString`, flat leaf, slice, and rope (covers the empty-constant special-case) | new |
| K10 | `test_string_export_foldl_map_astral` | `Elm_Kernel_String_{foldl,map,filter}`, `snapshotChars` | closure invoked with **code-point** Chars over `"a😀b"` (3 invocations, middle = 0x1F600) | fail-now (F2) |
| K11 | `test_elm_bytebuffer_len_on_slice` | `elm_bytebuffer_len` (`ElmBytesRuntime.cpp:81`) | `Tag_ByteBufferSlice` (≥32 B) → returns logical length, no abort | fail-now (F3) |
| K12 | `test_elm_bytebuffer_runtime_all_forms` | `elm_bytebuffer_len`/`_data`/`_with_data` | correct result for flat, large-header, AND slice inputs (accessor-trio regression matrix) | new |
| K13 | `test_bytes_export_ops_over_slice` | `Elm_Kernel_Bytes_width`, `read_*` | width + all `read_*` exports over a slice-form buffer: no abort, correct values | new |

Minimal core if scoped down to 6: K1, K2, K3, K6, K9, K10 (encoder size/endianness/
astral + decoder primitives + string length + the fail-now surrogate test). K11 is
also mandatory in the first cut — it pins a confirmed live crash (F3).

**Now in scope (promoted by the F3 crash):** the fused `bf` runtime
(`runtime/src/allocator/ElmBytesRuntime.cpp`, `elm_bytebuffer_*` / `elm_utf8_*`)
gets direct C++ unit tests here (K11–K13). The `bf` *dialect* IR shape is still
covered separately by the FileCheck plan in `bf-dialect-tests.md`, but those
assert on emitted IR, not runtime behaviour over non-flat inputs, so they would
not have caught F3.

---

## Totals

| Group | E2E | C++ unit | Notes |
|-------|-----|----------|-------|
| G1 Astral/surrogate | 8 | 3 | pins F2 |
| G2 Byte slice/large | 3 | 8 | pins F1 |
| G3 String slice/rope/split/join | 7 | 0 | |
| G4 Fuzzed GC | 0 | 5 | incl. 1 generator extension |
| G5 Non-ASCII BMP | 1 | 1 | |
| G6 Encode/decode + large-string | 0 | 6 | |
| G7 Op-surface × representation matrix | 3 | 2 | pins F3 (+ fused twins) & F1 promotion; found via live crash |
| K Kernel export suite | 0 | 13 | new suite (incl. ElmBytesRuntime) |
| **Total** | **22** | **38** | **60 tests** + F1 + F2 + F3 |

---

## Sequencing

1. **Phase 1 — pin the bugs (fail-now first).** Land F1, F2, and F3 code fixes
   together with the tests that prove them: E1–E8, U1–U3 (astral), U6/U11
   (byte-slice stride), K10, and **E20/K11 (the confirmed `Bytes.width`-on-slice
   crash)**. These lock down three known-live defects, one of which is a hard
   abort in real image-decode code.
2. **Phase 2 — byte-buffer representation parity + op matrix.** U4–U10, E9–E11,
   E21/U24/K12/K13: bring `Tag_ByteBufferSlice` and `Tag_LargeByteHeader` up to
   the coverage strings already have, and run the full op surface against every
   non-flat form (G7) so no op/representation pair is left unpaired.
3. **Phase 3 — string representation E2E.** E12–E18: slices, ropes, split, join
   through the real compiler pipeline.
4. **Phase 4 — fuzzed GC.** U12 generator extension + U13–U16.
5. **Phase 5 — content round-trips & width/offset holes.** E19, U17–U23.
6. **Phase 6 — kernel export suite.** K1–K9 (K10 already in Phase 1).

## Running

```bash
# Full suite (compiler + E2E + C++ unit)
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt

# Filtered C++ unit suites
build/test/test --filter BytesOps
build/test/test --filter StringOps
build/test/test --filter KernelExports

# Filtered E2E
TEST_FILTER=elm-bytes cmake --build build --target full
TEST_FILTER=elm-core  cmake --build build --target full
```

## Notes / invariants

- Threshold-sensitive: E2E tests must clear `MAKE_BYTEBUFFER_SLICE_MIN_LEN` (32),
  `STRING_TINY_SLICE_LIMIT` (128), `STRING_FLATTEN_LIMIT` (32 KiB units), and
  `LARGE_OBJECT_THRESHOLD` (8 KiB) to actually construct the intended
  representation rather than silently flattening. Assert the tag (unit) or use
  sizes comfortably past the boundary (E2E).
- Relevant invariants: HEAP_025 (four string forms), HEAP_026 (split header),
  REP_CONSTANT_003 (empty-string EQ), REP_ABI_001 (Char→i16), BFOPS_031/032
  (only runtime helpers are layout-aware).
