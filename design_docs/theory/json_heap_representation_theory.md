# JSON Heap Representation Theory

## Overview

JSON values in the ECO runtime are represented as heap-resident `Custom` objects rather than foreign C++ pointers. This design ensures GC safety, simplifies lifetime management, and eliminates the need for foreign pointer tracking.

**Phase**: Runtime, cross-cutting with MLIR Generation (for `Json.wrap` ABI)

**Pipeline Position**: Runtime data representation; JSON kernel functions operate on these heap objects

**Related Modules**:
- `elm-kernel-cpp/src/json/JsonExports.cpp` — Full JSON implementation (decoder, encoder, conversion)
- `elm-kernel-cpp/src/json/Json.hpp` — Minimal header for dependent stubs
- `runtime/src/allocator/Heap.hpp` — `Custom` struct definition
- `runtime/src/allocator/HeapHelpers.hpp` — Allocation helpers

## Motivation

The standard Elm JavaScript kernel represents JSON values as native JS objects. For native compilation, two approaches are possible:

1. **Foreign pointers**: Store `nlohmann::json` (or similar) objects as opaque C++ pointers, tracked separately from the GC heap.
2. **Heap-resident objects**: Convert JSON trees into GC-managed `Custom` objects using dedicated ctor tags.

ECO uses approach (2) because:

- **GC safety**: All JSON values are ordinary heap objects that the GC can trace, relocate, and collect. No special foreign-pointer tracking or custom destructor hooks are needed.
- **Simpler lifetime**: JSON values share the same lifetime model as all other Elm values. No reference counting or manual deallocation.
- **Uniform representation**: Decoders operate on the same `Custom` objects used everywhere in the runtime, reducing impedance mismatch.
- **No C++ object leaks**: The `nlohmann::json` tree is converted to heap objects immediately after parsing and then falls out of scope. No persistent C++ heap allocations.

## JSON Value ADT

JSON values are `Custom` objects (tag `Tag_Custom`) with ctor tags in the range 100–106:

| Ctor | Value | Fields | Boxed/Unboxed | Description |
|------|-------|--------|---------------|-------------|
| `CTOR_JSON_NULL` | 100 | 0 fields | — | JSON `null` |
| `CTOR_JSON_BOOL` | 101 | 1 boxed | `values[0].p` = True/False embedded constant | JSON boolean |
| `CTOR_JSON_INT` | 102 | 1 unboxed | `values[0].i` = i64 value | JSON integer |
| `CTOR_JSON_FLOAT` | 103 | 1 unboxed | `values[0].f` = f64 value | JSON float |
| `CTOR_JSON_STRING` | 104 | 1 boxed | `values[0].p` = HPointer to ElmString | JSON string |
| `CTOR_JSON_ARRAY` | 105 | 1 boxed | `values[0].p` = HPointer to ElmArray | JSON array |
| `CTOR_JSON_OBJECT` | 106 | 1 boxed | `values[0].p` = Elm List of (String, JsonValue) Tuple2s | JSON object |

Key points:
- `CTOR_JSON_BOOL` stores True/False as embedded HPointer constants (not as i1 or unboxed values), consistent with REP_ABI_001.
- `CTOR_JSON_INT` and `CTOR_JSON_FLOAT` store values unboxed (`unboxed = 1` bitmap), matching the convention for numeric `Custom` fields.
- `CTOR_JSON_OBJECT` uses a linked list of `Tuple2` pairs for key-value storage. Keys are `ElmString` values, and values are recursively JSON value ADT objects.
- `CTOR_JSON_ARRAY` stores elements in an `ElmArray` (contiguous, indexed).

## Decoder ADT

Decoders are also `Custom` objects, using ctor tags 0–22:

| Ctor | Value | Fields | Description |
|------|-------|--------|-------------|
| `DEC_STRING` | 0 | 0 | Decode JSON string |
| `DEC_BOOL` | 1 | 0 | Decode JSON boolean |
| `DEC_INT` | 2 | 0 | Decode JSON integer |
| `DEC_FLOAT` | 3 | 0 | Decode JSON float (accepts int too) |
| `DEC_NULL` | 4 | 1 boxed: fallback value | Decode JSON null, return fallback |
| `DEC_LIST` | 5 | 1 boxed: element decoder | Decode JSON array to Elm List |
| `DEC_ARRAY` | 6 | 1 boxed: element decoder | Decode JSON array to Elm Array |
| `DEC_FIELD` | 7 | 2 boxed: field name, nested decoder | Decode object field by name |
| `DEC_INDEX` | 8 | 1 unboxed (i64 index) + 1 boxed (decoder) | Decode array element by index |
| `DEC_KEYVALUE` | 9 | 1 boxed: value decoder | Decode object to List (String, value) |
| `DEC_VALUE` | 10 | 0 | Return raw JSON value |
| `DEC_SUCCEED` | 11 | 1 boxed: value | Always succeed with value |
| `DEC_FAIL` | 12 | 1 boxed: error message string | Always fail with message |
| `DEC_ANDTHEN` | 13 | 2 boxed: callback closure, inner decoder | Monadic bind |
| `DEC_ONEOF` | 14 | 1 boxed: list of decoders | Try decoders until one succeeds |
| `DEC_MAP1` | 15 | 2 boxed: callback, decoder | Map with 1 decoder |
| `DEC_MAP2` | 16 | 3 boxed: callback, decoder1, decoder2 | Map with 2 decoders |
| `DEC_MAP3`–`DEC_MAP8` | 17–22 | N+1 boxed: callback + N decoders | Map with 3–8 decoders |

Decoders are created by kernel exports (e.g., `Elm_Kernel_Json_decodeField`) and stored as heap objects. They form a tree structure that is interpreted by `runDecoder`.

## Encoder ADT

Encoder values use ctor tags 0–6, distinct from decoders by context:

| Ctor | Value | Fields | Description |
|------|-------|--------|-------------|
| `ENC_NULL` | 0 | 0 | Encode null |
| `ENC_BOOL` | 1 | 1 boxed: True/False constant | Encode boolean |
| `ENC_INT` | 2 | 1 unboxed: i64 | Encode integer |
| `ENC_FLOAT` | 3 | 1 unboxed: f64 | Encode float |
| `ENC_STRING` | 4 | 1 boxed: ElmString pointer | Encode string |
| `ENC_ARRAY` | 5 | 1 boxed: Elm List of encoder values | Encode array |
| `ENC_OBJECT` | 6 | 1 boxed: Elm List of (String, encoder) Tuple2s | Encode object |

Encoder values are created by `Json.wrap` (via `Elm_Kernel_Json_wrap`) and accumulation functions (`addEntry`, `addField`).

## jsonToHeap Conversion

`jsonToHeap(const nlohmann::json& j) -> HPointer` recursively converts a parsed `nlohmann::json` tree into heap-resident JSON value ADT objects:

- `null` → `makeJsonNull()` (CTOR_JSON_NULL, 0 fields)
- `bool` → `makeJsonBool(b)` (CTOR_JSON_BOOL, True/False constant)
- `int` → `makeJsonInt(i)` (CTOR_JSON_INT, unboxed i64)
- `float` → `makeJsonFloat(f)` (CTOR_JSON_FLOAT, unboxed f64)
- `string` → `makeJsonString(allocElmString(s))` (CTOR_JSON_STRING, boxed ElmString)
- `array` → Recursively convert each element, build `ElmArray`, wrap in CTOR_JSON_ARRAY
- `object` → Recursively convert each value, build list of `Tuple2(key, val)`, wrap in CTOR_JSON_OBJECT

After `jsonToHeap` returns, the `nlohmann::json` object falls out of scope and is freed. All data now lives on the GC heap.

## heapJsonToNlohmann Conversion

`heapJsonToNlohmann(uint64_t jvalEnc) -> nlohmann::json` is the inverse: it walks heap-resident JSON objects and builds a `nlohmann::json` tree. Used by `Json.encode` to serialize values.

The function pattern-matches on the Custom ctor tag and recursively converts:
- CTOR_JSON_NULL → `json(nullptr)`
- CTOR_JSON_BOOL → `json(true/false)` based on embedded constant comparison
- CTOR_JSON_INT → `json(values[0].i)`
- CTOR_JSON_FLOAT → `json(values[0].f)`
- CTOR_JSON_STRING → `json(elmStringToStd(...))`
- CTOR_JSON_ARRAY → Iterate ElmArray elements, recurse
- CTOR_JSON_OBJECT → Iterate kv-list, recurse on values

## runDecoder Execution Engine

`runDecoder(Custom* decoder, uint64_t jvalEnc)` is an interpreter-style execution engine that pattern-matches on the decoder's ctor tag:

1. **Primitive decoders** (DEC_STRING, DEC_BOOL, DEC_INT, DEC_FLOAT, DEC_NULL): Check the JSON value's ctor tag matches the expected type. Extract and wrap the value in `Ok`. DEC_FLOAT accepts both JSON int and float.

2. **DEC_VALUE**: Return the raw heap-resident JSON value wrapped in `Ok`.

3. **Collection decoders** (DEC_LIST, DEC_ARRAY): Verify CTOR_JSON_ARRAY, then iterate elements, running the element decoder on each. Build an Elm List (reverse iteration + cons) or ElmArray.

4. **DEC_FIELD**: Verify CTOR_JSON_OBJECT, search the kv-list by string comparison, run nested decoder on the found value.

5. **DEC_INDEX**: Verify CTOR_JSON_ARRAY, bounds-check the index, run nested decoder on the element.

6. **DEC_KEYVALUE**: Verify CTOR_JSON_OBJECT, run value decoder on each pair's value, build result list of (key, decodedValue) tuples.

7. **Combinators** (DEC_SUCCEED, DEC_FAIL, DEC_ANDTHEN, DEC_ONEOF): DEC_SUCCEED returns Ok directly. DEC_FAIL returns Err. DEC_ANDTHEN runs inner decoder, then calls callback closure to get next decoder. DEC_ONEOF tries decoders sequentially.

8. **Map decoders** (DEC_MAP1–DEC_MAP8): Run N sub-decoders, collect results, call the callback closure with all N values.

**GC safety**: After every recursive `runDecoder` call or `eco_apply_closure` call, decoder and JSON value pointers are re-resolved because allocation may trigger GC.

### Result Wrapping

Results are `Custom` objects using standard Elm Result constructors:
- **Ok**: `ctor = 0`, 1 boxed field (the decoded value)
- **Err**: `ctor = 1`, 1 boxed field (a Failure custom: message string + context list)

## String Handling

Elm strings are UTF-16 encoded (`ElmString` with `u16 chars[]`). JSON strings are UTF-8. Two conversion functions handle the mismatch:

- **`allocElmString(std::string)`** / **`allocStringFromUTF8`**: UTF-8 → UTF-16 conversion.
- **`elmStringToStd(uint64_t)`**: UTF-16 → UTF-8 conversion with surrogate pair handling. High surrogates (0xD800–0xDBFF) followed by low surrogates (0xDC00–0xDFFF) are combined into full Unicode code points and emitted as 4-byte UTF-8 sequences.

## Kernel Function Exports

| Export | Elm Function | Description |
|--------|-------------|-------------|
| `Elm_Kernel_Json_decodeString` | `Json.Decode.string` | Create string decoder |
| `Elm_Kernel_Json_decodeBool` | `Json.Decode.bool` | Create bool decoder |
| `Elm_Kernel_Json_decodeInt` | `Json.Decode.int` | Create int decoder |
| `Elm_Kernel_Json_decodeFloat` | `Json.Decode.float` | Create float decoder |
| `Elm_Kernel_Json_decodeNull` | `Json.Decode.null` | Create null decoder with fallback |
| `Elm_Kernel_Json_decodeList` | `Json.Decode.list` | Create list decoder |
| `Elm_Kernel_Json_decodeArray` | `Json.Decode.array` | Create array decoder |
| `Elm_Kernel_Json_decodeField` | `Json.Decode.field` | Create field decoder |
| `Elm_Kernel_Json_decodeIndex` | `Json.Decode.index` | Create index decoder |
| `Elm_Kernel_Json_decodeKeyValuePairs` | `Json.Decode.keyValuePairs` | Create key-value pairs decoder |
| `Elm_Kernel_Json_decodeValue` | `Json.Decode.value` | Create identity decoder |
| `Elm_Kernel_Json_succeed` | `Json.Decode.succeed` | Always-succeed decoder |
| `Elm_Kernel_Json_fail` | `Json.Decode.fail` | Always-fail decoder |
| `Elm_Kernel_Json_andThen` | `Json.Decode.andThen` | Monadic bind for decoders |
| `Elm_Kernel_Json_oneOf` | `Json.Decode.oneOf` | Try multiple decoders |
| `Elm_Kernel_Json_map1`–`map8` | `Json.Decode.map`–`map8` | Map N decoders with callback |
| `Elm_Kernel_Json_run` | `Json.Decode.decodeValue` | Run decoder on heap JSON value |
| `Elm_Kernel_Json_runOnString` | `Json.Decode.decodeString` | Parse string, convert to heap, run decoder |
| `Elm_Kernel_Json_encode` | `Json.Encode.encode` | Convert encoder to JSON string |
| `Elm_Kernel_Json_wrap` | `Json.Encode.int/float/string/bool/null/...` | Wrap Elm value as encoder |
| `Elm_Kernel_Json_encodeNull` | `Json.Encode.null` | Create null encoder |
| `Elm_Kernel_Json_emptyArray` | `Json.Encode.list` (initial) | Create empty array encoder |
| `Elm_Kernel_Json_emptyObject` | `Json.Encode.object` (initial) | Create empty object encoder |
| `Elm_Kernel_Json_addEntry` | (internal) | Append encoded entry to array |
| `Elm_Kernel_Json_addField` | (internal) | Add key-value pair to object |

## Relationship to Kernel ABI

- **`Json.wrap`** uses `AllBoxed` ABI: the compiler auto-boxes primitives (`i64` → `ElmInt`, `f64` → `ElmFloat`) before calling, so the C++ function always receives `HPointer`-encoded `uint64_t` values.
- All other Json functions use `ElmDerived` ABI with appropriate typed parameters (e.g., `decodeIndex` takes `int64_t` for the index).
- The `kernelBackendAbiPolicy` in the compiler designates `Json.wrap` as `AllBoxed`.

## See Also

- [Heap Representation Theory](heap_representation_theory.md) — Custom struct layout, unboxed field bitmaps
- [Kernel ABI Theory](kernel_abi_theory.md) — AllBoxed vs ElmDerived ABI modes
- [Platform & Scheduler Theory](platform_scheduler_theory.md) — Flag decoding uses JSON decoders
