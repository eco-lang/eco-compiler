# Plan: Heap-Resident JSON Values

## Problem

`JsonExports.cpp` stores `nlohmann::json*` C++ heap pointers inside Eco heap `Custom` objects via `reinterpret_cast<int64_t>`. This:
- Leaks memory (no `delete` when GC collects the wrapper)
- Violates heap discipline (foreign pointer masquerading as unboxed int)
- Creates an invisible dependency between Eco heap lifetime and C++ heap lifetime

## Solution

Eagerly convert parsed JSON into Eco heap objects using a `Custom`-based ADT. The `nlohmann::json` tree only exists transiently on the C++ stack during parsing.

## JSON Value ADT on Eco Heap

Use `Tag_Custom` with a dedicated ctor range (reuse `CTOR_JsonValue = 100` base):

| JSON Type | Ctor | Fields | Layout |
|-----------|------|--------|--------|
| null      | 100  | 0 fields | `Custom { size=0 }` |
| bool      | 101  | 1 boxed | `values[0].p = True/False constant` |
| int       | 102  | 1 unboxed | `values[0].i = int64_t`, `unboxed=1` |
| float     | 103  | 1 unboxed | `values[0].f = double`, `unboxed=1` |
| string    | 104  | 1 boxed | `values[0].p = HPointer to ElmString` |
| array     | 105  | 1 boxed | `values[0].p = HPointer to ElmArray` |
| object    | 106  | 1 boxed | `values[0].p = Elm List of (String, JsonValue) tuples` |

## Steps

### Step 1: Add `jsonToHeap` conversion function
- New function: `static HPointer jsonToHeap(const json& j)`
- Walks the `nlohmann::json` tree recursively
- Allocates Eco heap `Custom` objects for each JSON node
- Arrays become `ElmArray` of heap-resident JSON values
- Objects become Elm `List` of `Tuple2(ElmString, JsonValue)`

### Step 2: Add `heapJsonToNlohmann` helper (for encoding path)
- New function: `static json heapJsonToNlohmann(uint64_t enc)`
- Reads the heap-resident JSON ADT and reconstructs a `nlohmann::json`
- Used only in `Elm_Kernel_Json_encode` to produce the output string

### Step 3: Rewrite `runOnString` to use `jsonToHeap`
- Parse with `json::parse(str)` (unchanged)
- Call `jsonToHeap(jval)` to convert to heap objects
- Pass the `HPointer` result to a new heap-based `runDecoder`

### Step 4: Rewrite `runDecoder` to walk heap objects instead of `nlohmann::json`
- Change signature from `runDecoder(Custom* decoder, const json& jval)` to `runDecoder(Custom* decoder, uint64_t jval)`
- Each decoder case reads from the heap-resident JSON ADT via ctor tag dispatch
- `DEC_VALUE` case just returns the heap-resident JSON value directly
- `DEC_FIELD` resolves the field name against the object's key-value list
- `DEC_INDEX` indexes into the `ElmArray`
- `DEC_LIST`/`DEC_ARRAY` iterate the `ElmArray` elements

### Step 5: Rewrite `Elm_Kernel_Json_run`
- Remove `unwrapJson` — the value argument is already a heap-resident JSON value
- Pass it directly to the new `runDecoder`

### Step 6: Rewrite encoding path
- `Elm_Kernel_Json_wrap`: Convert an arbitrary Elm value to the JSON heap ADT
- `elmToJson`: Handle the `CTOR_JsonValue` range by reading the heap ADT (replacing the `reinterpret_cast<json*>` path)

### Step 7: Remove dead code
- Delete `wrapJson`, `unwrapJson`, `JsonStorage`, `jsonValues` vector
- Delete `Json.hpp` / `Json.cpp` (the old stub implementation is unused — `JsonExports.cpp` is the real implementation)

## GC Safety Notes

- `jsonToHeap` allocates recursively. Each allocation may trigger GC and move objects. Must re-resolve `HPointer` values after any allocation. Use the same pattern as other kernel code: store intermediate results as `HPointer` (logical pointers) not raw `void*`.
- All fields are proper HPointers or unboxed primitives — GC traces them correctly.
- No finalizers, weak refs, or cleanup hooks needed.

## Testing

- Existing E2E tests that exercise JSON decoding/encoding cover correctness
- `TEST_FILTER=elm cmake --build build --target check` for JSON-related integration tests
- Verify no memory leaks by checking that `new json` no longer appears in the codebase
