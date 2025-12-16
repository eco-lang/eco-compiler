# Elm Test Verification Plan

## Problem Statement

Currently, Elm E2E tests can only verify that code compiles and runs without crashing. We have no way to verify that computations produce correct results.

Example: In `AddTest.elm`, we compute `17 + 25 = 42`, but we can't verify the result is actually 42.

```elm
main =
    let
        a = 17
        b = 25
        result = a + b  -- Should be 42, but how to verify?
    in
    text "hello"
```

## Analysis

### Current Infrastructure

1. **EcoRunner.runFile()** returns a `RunResult` with:
   - `success: bool` - execution completed without errors
   - `returnValue: int64_t` - value returned by `main()`
   - `output: string` - captured `eco_dbg_print` output
   - `errorMessage: string` - error details if failed

2. **Guida compiler** generates MLIR where `main` returns an `!eco.value` (heap pointer), which becomes an `int64_t` in JIT.

3. **Debug.log** writes to stderr via `fprintf` (not captured by EcoRunner's output mechanism which only captures `eco_dbg_print`).

### Options Considered

#### Option A: Use `main`'s Return Value

Have test programs return the value to verify directly from `main`.

**Pros:**
- Simple - no new infrastructure needed
- `returnValue` already captured in `RunResult`

**Cons:**
- Elm programs return `Html msg`, not arbitrary values
- Would require special test programs that don't fit normal Elm patterns
- Return value is a heap pointer, not the actual Int/Float value

#### Option B: Use Platform.worker with Test Ports

Make test programs `Platform.worker` instances that send results via ports.

**Pros:**
- Standard Elm pattern
- Could support multiple assertions per test

**Cons:**
- Ports require JavaScript interop which doesn't exist in our runtime
- Significant infrastructure to implement port handling in C++

#### Option C: Custom Test Kernel Function

Add a kernel function like `Test.assert : Bool -> a -> a` that:
1. Checks the condition
2. Records pass/fail
3. Returns the value unchanged (for chaining)

**Pros:**
- Clean Elm API
- Can have multiple assertions per test
- Easy to integrate with test runner

**Cons:**
- Need to add new kernel function
- Need shared state between kernel and test runner

#### Option D: Use Return Value with Integer Result (Recommended)

Create test programs that compute an integer result and return it via a specialized entry point. The Guida compiler could support a `--test` mode that:
1. Expects `main : Int` instead of `main : Html msg`
2. Returns the integer directly (unboxed)

**Pros:**
- Simple verification: expected vs actual integer
- Minimal infrastructure changes
- Clear test semantics

**Cons:**
- Requires compiler changes
- One result per test file

#### Option E: Use eco.dbg for Output Verification

Modify the Elm `Debug` kernel to use `eco_dbg_print` instead of `fprintf(stderr,...)`, then verify output patterns.

**Pros:**
- Works with existing `-- CHECK:` pattern matching
- No compiler changes needed
- Multiple assertions via multiple Debug.log calls

**Cons:**
- Output string matching is fragile
- Need to modify kernel implementation

## Recommended Approach: Option E (Short-term) + Option D (Long-term)

### Phase 1: Fix Debug.log Output Capture (Quick Win)

1. Modify `Elm_Kernel_Debug_log` in `elm-kernel-cpp/src/core/DebugExports.cpp` to use `eco_dbg_print` instead of `fprintf(stderr, ...)`

2. Use `-- CHECK:` patterns in Elm test files:
   ```elm
   module AddTest exposing (main)

   -- CHECK: result: 42

   main =
       let
           result = 17 + 25
           _ = Debug.log "result" result
       in
       text "done"
   ```

3. The test runner already supports `-- CHECK:` pattern extraction and verification.

### Phase 2: Test-Specific Entry Point (Future)

Add compiler support for test programs:

1. Test programs export `testMain : Int` instead of `main : Html msg`
2. Compiler generates MLIR that returns the integer directly (unboxed)
3. Test runner compares `returnValue` against expected value from `-- EXPECT:` comment

```elm
module AddTest exposing (testMain)

-- EXPECT: 42

testMain : Int
testMain =
    17 + 25
```

## Implementation Plan (Phase 1)

### Step 1: Modify Debug Kernel

File: `elm-kernel-cpp/src/core/DebugExports.cpp`

```cpp
// Before:
fprintf(stderr, "[%s] <value>\n", tagStr.c_str());

// After:
eco_dbg_print(tagStr.c_str());  // Print tag
eco_dbg_print(": ");
eco_dbg_print(toString(value));  // Need Debug.toString implementation
eco_dbg_print("\n");
```

This requires `Elm_Kernel_Debug_toString` to actually convert values to strings (currently a stub).

### Step 2: Update Test File

```elm
module AddTest exposing (main)

-- CHECK: AddTest: 42

main =
    let
        result = 17 + 25
        _ = Debug.log "AddTest" result
    in
    text "done"
```

### Step 3: Verify Pattern Matching Works

The existing `ElmTest.hpp` already extracts `-- CHECK:` patterns and verifies them against `result.output`.

## Decisions

1. **Phase 1 only for now** - Debug.log approach is sufficient to get started
2. **Full Debug.toString implementation** - Need to print all Elm values as strings
3. **Kernel symbols stay in EcoRunner.cpp** - No need to move to test/elm/

## Implementation Plan

### Step 1: Implement Debug.toString

File: `elm-kernel-cpp/src/core/DebugExports.cpp`

Need to fully implement `Elm_Kernel_Debug_toString` to convert all Elm value types to string representation:

- **Int**: `"42"`
- **Float**: `"3.14"`
- **Char**: `"'a'"`
- **String**: `"\"hello\""`
- **Bool**: `"True"` / `"False"`
- **List**: `"[1, 2, 3]"`
- **Tuple**: `"(1, \"hello\")"`
- **Record**: `"{ name = \"Alice\", age = 30 }"`
- **Custom types**: `"Just 42"` / `"Nothing"`
- **Unit**: `"()"`

This requires inspecting the heap object's tag and recursively converting nested values.

### Step 2: Modify Debug.log to Use eco_dbg_print

File: `elm-kernel-cpp/src/core/DebugExports.cpp`

```cpp
uint64_t Elm_Kernel_Debug_log(uint64_t tag, uint64_t value) {
    std::string tagStr = elmStringToStd(Export::toPtr(tag));
    std::string valueStr = elmToString(Export::toPtr(value));  // Use toString

    // Use eco_dbg_print for captured output
    std::string output = tagStr + ": " + valueStr + "\n";
    eco_dbg_print(output.c_str());

    return value;
}
```

### Step 3: Update Test File

File: `test/elm/src/AddTest.elm`

```elm
module AddTest exposing (main)

-- CHECK: AddTest: 42

main =
    let
        result = 17 + 25
        _ = Debug.log "AddTest" result
    in
    text "done"
```

### Step 4: Verify Test Passes

Run `./build/test/test --filter "elm/AddTest"` and confirm the CHECK pattern is found in captured output.

## Files to Modify

1. `elm-kernel-cpp/src/core/DebugExports.cpp`
   - Implement `Elm_Kernel_Debug_toString` fully
   - Modify `Elm_Kernel_Debug_log` to use `eco_dbg_print`

2. `test/elm/src/AddTest.elm`
   - Add `-- CHECK:` pattern for verification
