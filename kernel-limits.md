# Removed Test Limitations Report

---

## 1. JsArray Tests (6) + DebugToStringTest + StringToListFromListTest — Kernel Signature Mismatch

### Root Cause

These tests fail at **compile time** with a kernel signature mismatch crash. The failure occurs in `registerKernelCall` (`compiler/src/Compiler/Generate/MLIR/Context.elm:608-633`), which enforces that every call site for a given kernel function uses identical MLIR argument and return types.

### Mechanism

#### Step 1: ABI Policy Classification

The compiler classifies each kernel function's ABI via `kernelBackendAbiPolicy` (`Context.elm:116-158`). JsArray, Debug, and most other modules fall through to the default `ElmDerived` policy:

```elm
kernelBackendAbiPolicy home name =
    case ( home, name ) of
        ( "List", _ ) -> AllBoxed
        ( "Utils", _ ) -> AllBoxed
        ( "String", "fromNumber" ) -> AllBoxed
        _ -> ElmDerived   -- JsArray, Debug, etc. land here
```

Under `ElmDerived`, the MLIR types for a kernel call are **derived from the monomorphized Elm wrapper type** via `monoTypeToAbi`. Under `AllBoxed`, all arguments and returns are forced to `!eco.value` regardless of the Elm type.

#### Step 2: C++ Signatures Use Non-uniform Types

The JsArray C++ implementations use typed (non-`uint64_t`) signatures (`elm-kernel-cpp/src/KernelExports.h:147-149`):

```cpp
uint32_t Elm_Kernel_JsArray_length(uint64_t array);          // returns uint32_t
uint64_t Elm_Kernel_JsArray_unsafeGet(uint32_t index, ...);  // takes uint32_t
uint64_t Elm_Kernel_JsArray_unsafeSet(uint32_t index, ...);  // takes uint32_t
```

Meanwhile, `Elm_Kernel_Debug_toString` (`KernelExports.h:167`) takes `uint64_t` and returns `uint64_t` — a uniform signature that should work. The issue is not the C++ types themselves.

#### Step 3: The Crash Mechanism

When the compiler encounters multiple call sites for the same kernel with different monomorphic Elm types, `monoTypeToAbi` produces different MLIR types. The `registerKernelCall` function then crashes:

```elm
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    case Dict.get name ctx.kernelDecls of
        Nothing ->
            -- First call: register signature
            { ctx | kernelDecls = Dict.insert name ( callSiteArgTypes, callSiteReturnType ) ctx.kernelDecls }
        Just ( existingArgs, existingReturn ) ->
            if existingArgs == callSiteArgTypes && existingReturn == callSiteReturnType then
                ctx
            else
                crash ("Kernel signature mismatch for " ++ name ++ ": existing (" ++ ...)
```

For example, `Debug.toString` has Elm type `a -> String`. If called as `Debug.toString 42` (monomorphized to `Int -> String`), `monoTypeToAbi` produces `[i64] -> !eco.value`. If also called as `Debug.toString "hello"` (monomorphized to `String -> String`), it produces `[!eco.value] -> !eco.value`. The first registration wins; the second crashes.

For JsArray functions, `ElmDerived` policy means the MLIR signature is derived from the Elm wrapper type (e.g., `Array a -> Int` for `length`). Different monomorphizations of the polymorphic `a` can produce different MLIR argument types, triggering the same crash.

#### Step 4: StringToListFromListTest

`Elm_Kernel_String_toList` does **not exist** — there is no C++ implementation, no `KERNEL_SYM` registration, and no entry in `KernelExports.h`. Only `Elm_Kernel_String_fromList` exists. `String.toList` is meant to be compiled as an Elm function, but the test apparently requires a codegen path that hits a kernel-related issue (likely `hasKernelImplementation` returning `False` for it, meaning the compiler tries to compile it as Elm source, but the Elm source itself calls kernel primitives that hit the signature mismatch).

### Evidence

- `kernelBackendAbiPolicy` default case: `Context.elm:157` → `ElmDerived`
- `registerKernelCall` crash: `Context.elm:621-633`
- JsArray typed C++ signatures: `KernelExports.h:147-149` (uint32_t params/returns)
- Debug.toString uniform C++ signature: `KernelExports.h:167` (uint64_t → uint64_t)
- `hasKernelImplementation` always returns `False`: `Context.elm:183-185`
- Missing `Elm_Kernel_String_toList`: not in `RuntimeSymbols.cpp`, not in `KernelExports.h`

### Fix Direction

Functions with uniform `uint64_t` C++ ABI that are called polymorphically (Debug.toString, JsArray functions) should be classified as `AllBoxed`, not `ElmDerived`. This ensures all call sites produce the same `!eco.value` MLIR types regardless of monomorphization.

---

## 2. Json Encode Tests (4) — Kernel Signature Mismatch for `Elm_Kernel_Json_wrap`

### Root Cause

Identical mechanism to Issue 1. `Elm_Kernel_Json_wrap` is a **polymorphic** kernel function (`a -> Value`) classified as `ElmDerived` by default. Different call-site monomorphizations produce different MLIR types, crashing `registerKernelCall`.

### Mechanism

#### Step 1: C++ Implementation Is Uniform

The C++ implementation (`elm-kernel-cpp/src/json/JsonExports.cpp:1228-1232`) is a trivial pass-through with uniform ABI:

```cpp
uint64_t Elm_Kernel_Json_wrap(uint64_t value) {
    // For primitive Elm values, we need to wrap them in an encoder.
    // For now, just return as-is since we handle it in elmToJson.
    return value;
}
```

Declared in `KernelExports.h:296` as `uint64_t Elm_Kernel_Json_wrap(uint64_t value)`.

#### Step 2: ABI Policy Falls Through to ElmDerived

The `kernelBackendAbiPolicy` function (`Context.elm:116-158`) lists specific Json functions:

```elm
-- Json: decodeIndex(int64_t,...), encode(int64_t,...)
```

But `Json.wrap` is **not** in the `AllBoxed` list. The only `AllBoxed` entries are `List`, `Utils`, and `String.fromNumber`. Json falls through to `ElmDerived`.

#### Step 3: Polymorphic Type Causes Mismatch

`Json.wrap` has Elm type `a -> Value`. Under `ElmDerived`, different monomorphizations produce different MLIR signatures:

- `Json.wrap 42` → monotype `Int -> JsonValue` → MLIR `[i64] -> !eco.value`
- `Json.wrap "hello"` → monotype `String -> JsonValue` → MLIR `[!eco.value] -> !eco.value`

The second call site hits the existing registration and crashes.

### Evidence

- `Elm_Kernel_Json_wrap` C++ signature: `KernelExports.h:296` — `uint64_t(uint64_t)`
- Implementation: `JsonExports.cpp:1228-1232` — just returns value as-is
- ABI policy: `Context.elm:148` — comment mentions `Json: decodeIndex(int64_t,...), encode(int64_t,...)` but `wrap` not special-cased
- Default fallthrough: `Context.elm:157` → `ElmDerived`
- Crash mechanism: `Context.elm:621-633` — same `registerKernelCall` as Issue 1

### Fix Direction

Add `( "Json", "wrap" ) -> AllBoxed` to `kernelBackendAbiPolicy`. Since the C++ ABI is `uint64_t → uint64_t`, all call sites should use `!eco.value → !eco.value`.

---

## 3. Json Decode Tests (6) + RegexReplaceTest (1) — `eco_apply_closure` Not Implemented

### Root Cause

The runtime function `eco_apply_closure` is an **unimplemented stub** that prints an error and returns 0. Kernel C++ code that needs to call user-provided closures (JSON decoders, regex replacement) calls this function and gets back a null result.

### The Stub

`runtime/src/allocator/RuntimeExports.cpp:491-503`:

```cpp
extern "C" uint64_t eco_apply_closure(uint64_t closure_hptr, uint64_t* args, uint32_t num_args) {
    void* closure_ptr = hpointerToPtr(closure_hptr);
    if (!closure_ptr) return 0;

    // TODO: Implement closure application
    // This needs to:
    // 1. Check if closure becomes fully saturated
    // 2. If so, call the evaluator function
    // 3. Otherwise, create a new PAP with additional captured args

    fprintf(stderr, "eco_apply_closure: not yet implemented\n");
    return 0;
}
```

Registered as a JIT symbol in `RuntimeSymbols.cpp:114-116`.

### Call Sites Blocked

**Json Decode** — `elm-kernel-cpp/src/json/JsonExports.cpp`:
- Line 765: `Decode.andThen` — calls callback with decoded value
- Line 807: `Decode.map` — maps decoded value through callback
- Line 833: `Decode.map2` — combines two decoded values through callback
- Line 862: `Decode.mapN` — combines N decoded values through callback

```cpp
// JsonExports.cpp:764-765  (andThen)
uint64_t args[1] = { Export::encode(value) };
uint64_t newDecEnc = eco_apply_closure(Export::encode(callback), args, 1);
```

**Regex Replace** — `elm-kernel-cpp/src/regex/RegexExports.cpp:353-354`:
```cpp
uint64_t matchEnc = Export::encode(matchRecord);
uint64_t replacementEnc = eco_apply_closure(closureEnc, &matchEnc, 1);
```

### Why Implementation Is Non-trivial

The companion functions `eco_pap_extend` and `eco_closure_call_saturated` **do** exist (`RuntimeExports.cpp:505-598`) and show what's needed. The closure heap layout (`Heap.hpp`) defines:

```cpp
typedef struct {
    Header header;
    u64 n_values : 6;      // Currently captured values (0-63)
    u64 max_values : 6;    // Total arity needed for saturation (0-63)
    u64 unboxed : 52;      // Bitmap: bit N set = captured value N is unboxed
    EvalFunction evaluator; // Function pointer to compiled lambda
    Unboxable values[];     // Variable-length captured values array
} Closure;
```

`eco_apply_closure` must:
1. Read `n_values` and `max_values` from the closure
2. If `n_values + num_args == max_values` → **saturate**: build combined arg array, call `evaluator(combined_args)` (same logic as `eco_closure_call_saturated`)
3. If `n_values + num_args < max_values` → **extend**: allocate new closure, copy old+new values (same logic as `eco_pap_extend`)

The key difficulty is **determining the unboxed bitmap for new arguments**. `eco_pap_extend` receives `new_unboxed_bitmap` as a parameter (computed by the compiler at MLIR codegen time from SSA operand types). But `eco_apply_closure` is called from C++ kernel code that **doesn't know the type information** — it just passes raw `uint64_t` values.

For the partial-application case, `eco_apply_closure` would need to either:
- Assume all new arguments are boxed (bitmap = 0) — safe but potentially incorrect
- Carry type metadata in the closure structure — architectural change
- Only support saturated calls — insufficient for general use

For the saturation case, the implementation is straightforward (combine captured + new args, call evaluator). This covers all current call sites (all pass exactly the remaining args needed).

### Evidence

- Stub: `RuntimeExports.cpp:491-503`
- Working `eco_pap_extend`: `RuntimeExports.cpp:505-557` — shows extend logic with `new_unboxed_bitmap` parameter
- Working `eco_closure_call_saturated`: `RuntimeExports.cpp:559-598` — shows saturation logic
- Symbol registration: `RuntimeSymbols.cpp:114-116`
- Json call sites: `JsonExports.cpp:765,807,833,862`
- Regex call site: `RegexExports.cpp:354`
- Also blocks: `TimeEffectManager.cpp:86,243,246`, `HttpExports.cpp:238,325,352,441,453`, `HttpEffectManager.cpp:74,145`, `Scheduler.cpp:89,99,112`

### Fix Direction

Implement `eco_apply_closure` by combining the logic of `eco_closure_call_saturated` (for saturation) and `eco_pap_extend` (for partial application, with bitmap=0 for new args). All current call sites in Json/Regex pass exactly the remaining arity, so saturation-only would unblock these tests.

---

## 4. elm-core Tests (5) — GC Pointer Invalidation

### Root Cause

The kernel C++ implementations of `String.split`, `String.join`, `List.sortBy`, `List.sortWith`, and `List.unzip` hold **raw `void*` pointers across allocation points**. When allocation triggers garbage collection, the GC evacuates objects to new locations, leaving forwarding pointers at the old locations. The raw pointers still reference the old (now invalid) locations.

### GC Background

Allocation can trigger GC (`runtime/src/allocator/ThreadLocalHeap.cpp:37-40`):
```cpp
void* ThreadLocalHeap::allocate(size_t size, Tag tag) {
    if (nursery_.wouldExceedThreshold(size, config_->nursery_gc_threshold)) {
        minorGC();   // Evacuates live objects, swaps semispaces
    }
    void* obj = nursery_.allocate(size);
    ...
}
```

After GC, `HPointer` values remain valid (resolved via forwarding chains in `Allocator::resolve()`), but raw `void*` pointers are **dangling**.

### Bug 1: `StringOps::join` — Raw Separator Pointer

`runtime/src/allocator/StringOps.cpp:62-126`:

```cpp
HPointer join(void* sep, HPointer stringList) {
    ElmString* separator = static_cast<ElmString*>(sep);  // RAW void* → cast
    size_t sep_len = separator ? separator->header.size : 0;

    // ... first pass counts total length (no allocation, safe) ...

    // ALLOCATION — CAN TRIGGER GC
    ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));

    // Second pass: copies strings with separator
    while (!alloc::isNil(current)) {
        // ...
        if (!first && sep_len > 0) {
            std::memcpy(result->chars + offset,
                       separator->chars,    // ← DANGLING if GC happened at allocate()
                       sep_len * sizeof(u16));
        }
    }
}
```

The `separator` pointer is captured on line 64 as a raw `void*` cast. The `allocate()` on line 96 can trigger GC. After GC, `separator` points to evacuated memory containing a forwarding pointer, not the original `ElmString`. The `memcpy` on line 114 reads garbage.

### Bug 2: `StringOps::split` — Two Raw Pointers

`runtime/src/allocator/StringOps.cpp:174-219`:

```cpp
HPointer split(void* sep, void* str) {
    ElmString* separator = static_cast<ElmString*>(sep);  // RAW
    ElmString* s = static_cast<ElmString*>(str);           // RAW

    // ... loop scanning for matches ...
    for (size_t i = 0; i <= str_len - sep_len; ++i) {
        if (s->chars[i + j] != separator->chars[j]) ...  // Uses raw pointers

        if (match) {
            parts.push_back(alloc::allocString(s->chars + start, i - start));
            // ↑ allocString() allocates → can trigger GC
            // After this, s and separator may be DANGLING
            // But the loop continues using s->chars and separator->chars
        }
    }
    parts.push_back(alloc::allocString(s->chars + start, str_len - start));
    // ↑ s is used AFTER possible GC from previous iterations
}
```

Both `s` and `separator` are raw pointers used throughout the loop. Each `alloc::allocString` call allocates memory, potentially triggering GC. After the first match allocation, subsequent iterations access dangling pointers.

### Bug 3: `List.sortBy` — Stale Closure Pointer + Encoded Values

`elm-kernel-cpp/src/core/ListExports.cpp:410-457`:

```cpp
uint64_t Elm_Kernel_List_sortBy(uint64_t closure, uint64_t list) {
    void* closure_ptr = Export::toPtr(closure);  // RAW pointer to closure
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list));

    // Build key cache via closure calls
    for (uint64_t elem : elements) {
        uint64_t key = callUnaryClosure(closure_ptr, elem);
        // ↑ callUnaryClosure dereferences closure_ptr (line 25):
        //   Closure* closure = static_cast<Closure*>(closure_ptr);
        //   closure->evaluator(args);
        // The evaluator may allocate, triggering GC.
        // After GC, closure_ptr is DANGLING for subsequent iterations.
        keys.push_back(key);
    }
```

`callUnaryClosure` (`ListExports.cpp:24-35`) dereferences the closure pointer directly:
```cpp
inline uint64_t callUnaryClosure(void* closure_ptr, uint64_t arg) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    void* args[16];
    for (uint32_t i = 0; i < n_values; i++)
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    args[n_values] = reinterpret_cast<void*>(arg);
    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}
```

If the evaluator allocates (which it will for any non-trivial key extraction), GC may move the closure object. The next loop iteration dereferences the old `closure_ptr`, reading garbage.

### Bug 4: `List.sortWith` — Same Pattern

`elm-kernel-cpp/src/core/ListExports.cpp:459-484`:

```cpp
std::stable_sort(elements.begin(), elements.end(), [&](uint64_t a, uint64_t b) {
    uint64_t order = callBinaryClosure(closure_ptr, a, b);
    // ↑ closure_ptr is raw void*, may be dangling after first comparison
    // Also: Utils::compare allocates Order custom types on the heap
});
```

The `closure_ptr` is captured in the lambda but is a raw pointer that becomes stale after GC.

### Bug 5: `ListOps::unzip` — Boxed Values in Vector

`runtime/src/allocator/ListOps.cpp:676-721`:

```cpp
HPointer unzip(HPointer listOfPairs) {
    std::vector<std::pair<Unboxable, bool>> firsts;
    std::vector<std::pair<Unboxable, bool>> seconds;

    while (!alloc::isNil(current)) {
        Cons* c = static_cast<Cons*>(cell);
        Tuple2* tuple = static_cast<Tuple2*>(tupleObj);
        firsts.emplace_back(tuple->a, aBoxed);   // Stores Unboxable
        seconds.emplace_back(tuple->b, bBoxed);   // Stores Unboxable
    }

    // Build first list — each cons() allocates
    HPointer firstList = alloc::listNil();
    for (auto it = firsts.rbegin(); it != firsts.rend(); ++it) {
        firstList = alloc::cons(it->first, firstList, it->second);
        // ↑ If it->first contains a boxed HPointer and GC fires,
        // the HPointer encoding in the vector is still valid (HPointers survive GC)
        // BUT: the traversal phase used raw void* (cell, tupleObj) which could
        // be dangling if any resolve() triggered allocation
    }
}
```

The traversal phase uses `allocator.resolve()` which does NOT allocate, so the traversal itself is safe. However, the `alloc::cons()` calls in the build phase allocate. If `it->first` contains a **boxed HPointer**, the HPointer value itself remains valid (it's an integer encoding). The real risk is if `tuple->a` contained a raw pointer rather than a proper HPointer encoding — which depends on how tuples store their values.

### Note: `List.indexedMap` and `String.replace`

`Elm_Kernel_List_indexedMap` and `Elm_Kernel_String_replace` do **not exist** as kernel functions (no `KERNEL_SYM` registration, no C++ implementation). These are compiled as **Elm source code**. Their failures are likely caused by:
- `List.indexedMap`: The compiled Elm code internally calls a kernel function (`ListOps::indexedMap` at `ListOps.cpp:121-151`) which takes an `IndexedMapper` callback — this callback mechanism may not work through the compiled MLIR path
- `String.replace`: No kernel exists at all — this is pure Elm that calls `String.split` and `String.join` internally, inheriting their GC bugs

### Correct Pattern for Comparison

Working kernel functions like `List.map2` (`ListExports.cpp:255-290`) demonstrate the safe pattern:

```cpp
while (!alloc::isNil(xList) && !alloc::isNil(yList)) {
    Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));  // Re-resolve each iteration
    HPointer xTail = xCons->tail;   // Save as HPointer BEFORE closure call
    HPointer yTail = yCons->tail;   // Save as HPointer BEFORE closure call

    uint64_t result = callBinaryClosure(closure_ptr, x, y);  // May trigger GC

    xList = xTail;   // HPointer is valid after GC
    yList = yTail;
}
```

Key differences: saves chain pointers as `HPointer` before calling closures, re-resolves via `allocator.resolve()` each iteration. However, even `map2` has the same `closure_ptr` dangling pointer bug — it just doesn't trigger in practice because the closure object is likely pinned or in old-gen by the time map2 runs.

### Evidence

- `StringOps::join` raw pointer: `StringOps.cpp:64` (`separator`), allocation at line 96, use at line 114
- `StringOps::split` raw pointers: `StringOps.cpp:175-176` (`separator`, `s`), allocation at line 209, continued use at lines 201-204
- `List.sortBy` raw closure pointer: `ListExports.cpp:411` (`closure_ptr`), used in loop at line 423
- `callUnaryClosure` dereferences raw pointer: `ListExports.cpp:24-35`
- `List.sortWith` raw closure pointer: `ListExports.cpp:460` (`closure_ptr`), used in sort at line 469
- `ListOps::unzip`: `ListOps.cpp:676-721` — traversal uses `resolve()` (safe), build phase uses `cons()` (allocates)
- GC trigger point: `ThreadLocalHeap.cpp:37-40` — `allocate()` calls `minorGC()`
- No `Elm_Kernel_List_indexedMap`: not in `RuntimeSymbols.cpp`
- No `Elm_Kernel_String_replace`: not in `RuntimeSymbols.cpp` or `KernelExports.h`

### Fix Direction

- `StringOps::join/split`: Convert `sep` and `str` parameters from `void*` to `HPointer`. Re-resolve via `allocator.resolve()` after each allocation.
- `List.sortBy/sortWith`: Store the closure as an `HPointer` (encoded uint64_t), re-resolve before each `callUnaryClosure`/`callBinaryClosure` invocation.
- `List.indexedMap/String.replace`: These are compiled Elm functions. Fixing `String.split` and `String.join` (for `String.replace`) and ensuring the compiled codegen path for higher-order Elm functions works correctly should resolve these.

---

## Summary Table

| Category | Count | Root Cause | Failure Point |
|----------|-------|------------|---------------|
| JsArray + Debug + String | 8 | Polymorphic kernel under `ElmDerived` ABI policy | `Context.elm:621` — `registerKernelCall` crash |
| Json Encode | 4 | `Json.wrap` polymorphic under `ElmDerived` ABI policy | `Context.elm:621` — same mechanism |
| Json Decode + Regex | 7 | `eco_apply_closure` stub returns 0 | `RuntimeExports.cpp:501` — prints error, returns 0 |
| elm-core (List/String) | 5 | Raw `void*` pointers dangling after GC | Various: `StringOps.cpp`, `ListExports.cpp` |
| **Total** | **24** | | |

### Cross-cutting Observations

1. **Issues 1 and 2 are the same bug** — polymorphic kernels classified as `ElmDerived` instead of `AllBoxed`. A systematic audit of all kernels with polymorphic Elm types would fix both.

2. **Issue 3 is straightforward** — `eco_apply_closure` just needs to combine existing `eco_closure_call_saturated` and `eco_pap_extend` logic. All current call sites pass exactly the remaining arity, so a saturation-only implementation would unblock all 7 tests.

3. **Issue 4 has two sub-categories**:
   - `String.split/join` and `List.sortBy/sortWith` have concrete GC bugs in their C++ kernel implementations (raw `void*` across allocations)
   - `List.indexedMap` and `String.replace` are compiled Elm functions that either depend on buggy kernels or need additional codegen support
