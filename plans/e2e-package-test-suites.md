# Plan: E2E Test Suites for Elm Package Kernel Implementations

## Problem

The kernel C++ implementations for elm/core, elm/json, elm/http, elm/regex, elm/time, and elm/url lack dedicated E2E test suites. The existing `test/elm/` directory covers core language features (case, let, closures, basic arithmetic) but does not systematically exercise the kernel function exports for each package.

## Architecture

Each new test suite follows the elm-bytes pattern:

```
test/<suite-name>/
├── elm.json              # Elm project with package dependency
├── <SuiteName>Test.hpp   # Test runner (namespace, directory helpers, buildTestSuite)
└── src/
    └── <Category><Specific>Test.elm   # One .elm file per test case
```

Each `.hpp` file is a thin copy of the elm-bytes test runner pattern:
- Same `ElmSharedTestResult` / GCStats accumulation
- Same two-phase approach: Phase 1 compile Elm→MLIR, Phase 2 run MLIR in parallel via fork()
- Same `-- CHECK:` pattern verification in .elm files
- Same `discoverTests()` / `buildTestSuite()` / `ParallelTestSuite` class
- Only differs in: namespace name, directory path helper, suite display name

Each `.elm` test file uses `Debug.log` to print values and `-- CHECK:` comments to verify output.

### CMake integration

In `test/CMakeLists.txt`: no changes needed (test runners are header-only, .elm files compiled at test runtime).

In `test/main.cpp`: add `#include` for each new `.hpp` and register each suite in the same pattern as elm-bytes:
```cpp
auto elmCoreTests = ElmCoreTest::buildElmCoreTestSuite();
// ... etc
suite.add(std::move(elmCoreTests));
```

### Shared test runner refactoring

The elm-bytes and elm/ test runners are ~1100 lines each of nearly identical code. Rather than copy-pasting 6 more times, **extract a shared base** into `test/ElmE2ETestBase.hpp` that is parameterized by:
- namespace name
- suite display name
- directory path

Each package's `.hpp` becomes a thin wrapper (~30 lines) that specializes the base.

## Package test suites

### 1. test/elm-core/ (elm/core kernel functions)

**elm.json dependencies**: `elm/core` (direct), `elm/html` (direct for Debug.log output)

**Priority: pure functions not already covered by test/elm/**

The existing `test/elm/` already covers: basic arithmetic (+,-,*,/,^), int/float conversion (ceiling, floor, round, truncate, toFloat), Bool ops (&&, ||, not, xor), Char (fromCode, toCode, isAlpha, isDigit, toLower, toUpper), comparison ops, basic String (length, concat, empty), basic List (map, filter, foldl, foldr, head, tail, length, reverse, concat, take, drop, cons), Maybe/Result operations, Tuple (first, second, pair, mapFirst, mapSecond), Bitwise (and, or, xor, complement, shiftLeft, shiftRight, shiftRightZfBy).

**Tests to add** (functions NOT yet covered):

| File | Tests | Kernel functions exercised |
|------|-------|---------------------------|
| `BasicsIdentityTest.elm` | `identity`, `always` | `eco_elm_core_Basics_identity`, `eco_elm_core_Basics_always` |
| `BasicsClampTest.elm` | `clamp` with Int and Float | `eco_elm_core_Basics_clamp` |
| `BasicsModByTest.elm` | `modBy` edge cases (negative, zero) | `eco_elm_core_Basics_modBy` |
| `BasicsRemainderByTest.elm` | `remainderBy` edge cases | `eco_elm_core_Basics_remainderBy` |
| `BasicsIsNaNTest.elm` | `isNaN`, `isInfinite` | `eco_elm_core_Basics_isNaN`, `eco_elm_core_Basics_isInfinite` |
| `StringSliceTest.elm` | `String.slice` positive/negative indices | `eco_elm_core_String_slice` |
| `StringContainsTest.elm` | `String.contains` | `eco_elm_core_String_contains` |
| `StringStartsEndsTest.elm` | `String.startsWith`, `String.endsWith` | `eco_elm_core_String_startsWith/endsWith` |
| `StringSplitJoinTest.elm` | `String.split`, `String.join` | `eco_elm_core_String_split/join` |
| `StringTrimTest.elm` | `String.trim`, `String.trimLeft`, `String.trimRight` | `eco_elm_core_String_trim*` |
| `StringPadTest.elm` | `String.padLeft`, `String.padRight` | `eco_elm_core_String_pad*` |
| `StringMapFilterTest.elm` | `String.map`, `String.filter` | `eco_elm_core_String_map/filter` |
| `StringToIntFloatTest.elm` | `String.toInt`, `String.toFloat` | `eco_elm_core_String_toInt/toFloat` |
| `StringFromIntFloatTest.elm` | `String.fromInt`, `String.fromFloat`, `String.fromChar` | `eco_elm_core_String_from*` |
| `StringReplaceTest.elm` | `String.replace` | `eco_elm_core_String_replace` |
| `StringIndexesTest.elm` | `String.indexes`, `String.indices` | `eco_elm_core_String_indexes` |
| `StringLeftRightDropTest.elm` | `String.left`, `String.right`, `String.dropLeft`, `String.dropRight` | `eco_elm_core_String_left/right/drop*` |
| `StringRepeatTest.elm` | `String.repeat` | `eco_elm_core_String_repeat` |
| `StringWordsLinesTest.elm` | `String.words`, `String.lines` | `eco_elm_core_String_words/lines` |
| `StringToListFromListTest.elm` | `String.toList`, `String.fromList` | `eco_elm_core_String_toList/fromList` |
| `StringFoldlTest.elm` | `String.foldl`, `String.foldr` | `eco_elm_core_String_foldl/foldr` |
| `StringAnyAllTest.elm` | `String.any`, `String.all` | `eco_elm_core_String_any/all` |
| `ListSortTest.elm` | `List.sort`, `List.sortBy`, `List.sortWith` | `eco_elm_core_List_sort*` |
| `ListRangeTest.elm` | `List.range` | `eco_elm_core_List_range` |
| `ListRepeatTest.elm` | `List.repeat` | `eco_elm_core_List_repeat` |
| `ListAppendTest.elm` | `List.append`, `(++)` | `eco_elm_core_List_append` |
| `ListIntersperseMemberTest.elm` | `List.intersperse`, `List.member` | `eco_elm_core_List_intersperse/member` |
| `ListMap2345Test.elm` | `List.map2`, `map3`, `map4`, `map5` | `eco_elm_core_List_map2-5` |
| `ListConcatMapTest.elm` | `List.concatMap` | `eco_elm_core_List_concatMap` |
| `ListIndexedMapTest.elm` | `List.indexedMap` | `eco_elm_core_List_indexedMap` |
| `ListPartitionTest.elm` | `List.partition` | `eco_elm_core_List_partition` |
| `ListUnzipTest.elm` | `List.unzip` | `eco_elm_core_List_unzip` |
| `JsArrayBasicsTest.elm` | Round-trip: Array.fromList → Array.toList | `eco_elm_core_JsArray_*` |
| `JsArrayPushSliceTest.elm` | `Array.push`, `Array.slice` | `eco_elm_core_JsArray_push/slice` |
| `JsArrayMapFoldTest.elm` | `Array.map`, `Array.foldl`, `Array.foldr` | `eco_elm_core_JsArray_foldl/foldr/map` |
| `JsArrayGetSetTest.elm` | `Array.get`, `Array.set` | `eco_elm_core_JsArray_unsafeGet/unsafeSet` |
| `DebugToStringTest.elm` | `Debug.toString` on various types | `eco_elm_core_Debug_toString` |
| `DebugLogTest.elm` | `Debug.log` round-trip | `eco_elm_core_Debug_log` |

**~35 test files**

### 2. test/elm-json/ (elm/json kernel functions)

**elm.json dependencies**: `elm/core`, `elm/json` (direct), `elm/html`

**All 32 functions are pure. Tests use round-trip encode→decode patterns.**

| File | Tests | Kernel functions exercised |
|------|-------|---------------------------|
| `DecodeIntTest.elm` | `Json.Decode.decodeString Json.Decode.int` | `eco_elm_json_Json_Decode_int` |
| `DecodeFloatTest.elm` | decode float values | `eco_elm_json_Json_Decode_float` |
| `DecodeStringTest.elm` | decode string values | `eco_elm_json_Json_Decode_string` |
| `DecodeBoolTest.elm` | decode true/false | `eco_elm_json_Json_Decode_bool` |
| `DecodeNullTest.elm` | `Json.Decode.null` | `eco_elm_json_Json_Decode_null` |
| `DecodeListTest.elm` | `Json.Decode.list` | `eco_elm_json_Json_Decode_list` |
| `DecodeArrayTest.elm` | `Json.Decode.array` | `eco_elm_json_Json_Decode_array` |
| `DecodeDictTest.elm` | `Json.Decode.dict` | `eco_elm_json_Json_Decode_dict` |
| `DecodeFieldTest.elm` | `Json.Decode.field` | `eco_elm_json_Json_Decode_field` |
| `DecodeAtTest.elm` | `Json.Decode.at` | `eco_elm_json_Json_Decode_at` |
| `DecodeIndexTest.elm` | `Json.Decode.index` | `eco_elm_json_Json_Decode_index` |
| `DecodeMapTest.elm` | `Json.Decode.map` | `eco_elm_json_Json_Decode_map` |
| `DecodeMap2Test.elm` | `Json.Decode.map2` | `eco_elm_json_Json_Decode_map2` |
| `DecodeMap3Test.elm` | `Json.Decode.map3-map8` (sample) | `eco_elm_json_Json_Decode_map3-8` |
| `DecodeAndThenTest.elm` | `Json.Decode.andThen` | `eco_elm_json_Json_Decode_andThen` |
| `DecodeOneOfTest.elm` | `Json.Decode.oneOf` | `eco_elm_json_Json_Decode_oneOf` |
| `DecodeMaybeTest.elm` | `Json.Decode.maybe` | `eco_elm_json_Json_Decode_maybe` |
| `DecodeNullableTest.elm` | `Json.Decode.nullable` | `eco_elm_json_Json_Decode_nullable` |
| `DecodeSucceedFailTest.elm` | `Json.Decode.succeed`, `Json.Decode.fail` | succeed/fail |
| `DecodeLazyTest.elm` | `Json.Decode.lazy` for recursive JSON | `eco_elm_json_Json_Decode_lazy` |
| `DecodeValueTest.elm` | `Json.Decode.value`, `Json.Decode.decodeValue` | value/decodeValue |
| `DecodeKeyValuePairsTest.elm` | `Json.Decode.keyValuePairs` | keyValuePairs |
| `DecodeErrorToStringTest.elm` | `Json.Decode.errorToString` | errorToString |
| `EncodeObjectTest.elm` | `Json.Encode.object` round-trip | encode + decode |
| `EncodeListTest.elm` | `Json.Encode.list` round-trip | encode + decode |
| `EncodePrimitivesTest.elm` | `Json.Encode.int/float/string/bool/null` | all encode primitives |
| `EncodeDecodeRoundTripTest.elm` | Complex nested encode→decode | full round-trip |

**~27 test files**

### 3. test/elm-regex/ (elm/regex kernel functions)

**elm.json dependencies**: `elm/core`, `elm/regex` (direct), `elm/html`

**All 7 functions are pure.**

| File | Tests | Kernel functions exercised |
|------|-------|---------------------------|
| `RegexFromStringTest.elm` | `Regex.fromString`, `Regex.fromStringWith` (case insensitive, multiline) | `eco_elm_regex_Regex_fromStringWith` |
| `RegexContainsTest.elm` | `Regex.contains` with various patterns | `eco_elm_regex_Regex_contains` |
| `RegexFindTest.elm` | `Regex.find`, `Regex.findAtMost` with submatch groups | `eco_elm_regex_Regex_findAtMost` |
| `RegexReplaceTest.elm` | `Regex.replace`, `Regex.replaceAtMost` | `eco_elm_regex_Regex_replaceAtMost` |
| `RegexSplitTest.elm` | `Regex.split`, `Regex.splitAtMost` | `eco_elm_regex_Regex_splitAtMost` |
| `RegexNeverTest.elm` | `Regex.never` (matches nothing) | `eco_elm_regex_Regex_never` |
| `RegexEdgeCasesTest.elm` | Empty patterns, special chars, unicode | edge cases |

**7 test files**

### 4. test/elm-url/ (elm/url kernel functions)

**elm.json dependencies**: `elm/core`, `elm/url` (direct), `elm/html`

**Both functions are pure.**

| File | Tests | Kernel functions exercised |
|------|-------|---------------------------|
| `UrlPercentEncodeTest.elm` | `Url.percentEncode` on ASCII, Unicode, special chars | `eco_elm_url_Url_percentEncode` |
| `UrlPercentDecodeTest.elm` | `Url.percentDecode` including malformed input | `eco_elm_url_Url_percentDecode` |
| `UrlRoundTripTest.elm` | encode→decode round-trip for various inputs | both |
| `UrlBuilderTest.elm` | `Url.Builder.absolute`, `relative`, `crossOrigin` | Elm-level (no kernel) |

**4 test files**

### 5. test/elm-http/ (elm/http kernel functions)

**elm.json dependencies**: `elm/core`, `elm/http` (direct), `elm/json`, `elm/html`

**Mostly effectful (Cmd-producing). Limited pure-function testing possible.**

Note: HTTP is inherently effectful. We can test:
- Type construction (headers, body types)
- Expect construction
- The pure subset of the API

| File | Tests | Notes |
|------|-------|-------|
| `HttpHeaderTest.elm` | `Http.header` construction | Pure construction |
| `HttpExpectStringTest.elm` | `Http.expectString` construction | Pure construction |
| `HttpJsonBodyTest.elm` | `Http.jsonBody` construction | Pure construction |
| `HttpStringBodyTest.elm` | `Http.stringBody` construction | Pure construction |

**4 test files** (expand later when effect manager testing is available)

### 6. test/elm-time/ (elm/time kernel functions)

**elm.json dependencies**: `elm/core`, `elm/time` (direct), `elm/html`

**All 5 functions are effectful (Task/Cmd). Very limited pure testing.**

| File | Tests | Notes |
|------|-------|-------|
| `TimePosixTest.elm` | `Time.millisToPosix`, `Time.posixToMillis` round-trip | Pure Elm functions (no kernel) |
| `TimeZoneTest.elm` | `Time.utc`, `Time.toHour/toMinute/toSecond` etc. | Pure Elm time part extraction |

**2 test files** (expand later when effect manager testing is available)

## Implementation order

1. **Extract `ElmE2ETestBase.hpp`** from elm-bytes test runner (~1100 lines → shared base)
2. **Refactor `ElmBytesTest.hpp`** to use the shared base (verify no regressions)
3. **Refactor `ElmTest.hpp`** to use the shared base (verify no regressions)
4. **Create test/elm-core/** with ~35 test files
5. **Create test/elm-json/** with ~27 test files
6. **Create test/elm-regex/** with 7 test files
7. **Create test/elm-url/** with 4 test files
8. **Create test/elm-http/** with 4 test files
9. **Create test/elm-time/** with 2 test files
10. **Update test/main.cpp** to register all new suites

## Test count summary

| Suite | Test files | Priority |
|-------|-----------|----------|
| elm-core | ~35 | High (largest kernel surface) |
| elm-json | ~27 | High (complex encode/decode) |
| elm-regex | 7 | Medium |
| elm-url | 4 | Medium |
| elm-http | 4 | Low (mostly effectful) |
| elm-time | 2 | Low (mostly effectful) |
| **Total** | **~79** | |

## Running tests

```bash
cmake --build build && ./build/test/test

# Filter to specific suite:
TEST_FILTER=elm-core cmake --build build --target check
TEST_FILTER=elm-json cmake --build build --target check
TEST_FILTER=elm-regex cmake --build build --target check
```
