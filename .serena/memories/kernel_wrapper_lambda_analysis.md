# Kernel Function Wrapper Lambda Analysis

## Research Summary
Comprehensive analysis of how the Eco Elm compiler decides between generating wrapper lambdas vs direct PAPs for kernel functions.

## Key Findings

### 1. The Decision Point: Arity Analysis in MLIR Generation

**Location**: `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`, function `generateVarKernel` (lines 613-780)

**Core Logic**:
The compiler determines kernel function arity using `Types.countTotalArity monoType`, which flattens the MonoType structure:

```elm
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction argTypes result ->
            List.length argTypes + countTotalArity result
        _ -> 0
```

For example:
- `f : a -> b -> c` → arity = 2
- `f : a -> (b -> c)` → arity = 2 (both flatten to same arity)

### 2. Direct PAP Creation (No Wrapper)

**Condition**: When `countTotalArity monoType > 0`

**Code Generation**:
```elm
eco.papCreate() {
    arity = <total_arity>,
    function = @Elm_Kernel_Json_addEntry,  -- KERNEL FUNCTION DIRECTLY
    num_captured = 0
}
```

**Example**: `Json.Encode.list`
- Elm source: likely `list : (a -> Value) -> List a -> Value`
- Monomorphized at a call site with encoder function `func`
- `func` parameter represents a curried function
- Kernel `Elm_Kernel_Json_addEntry` can be called directly via PAP

**Generated MLIR** (RoundTripListTest.mlir, line 71):
```mlir
%2 = "eco.papCreate"() {arity = 3, function = @Elm_Kernel_Json_addEntry, num_captured = 0}
%3 = "eco.papExtend"(%2, %func) {newargs_unboxed_bitmap = 0, remaining_arity = 3}
```

### 3. Wrapper Lambda Creation

**Condition**: When the kernel's parameter pattern doesn't match the expected calling convention

**Code Generation**:
```elm
eco.papCreate() {
    arity = 2,
    function = @RoundTripObjectTest_lambda_1,  -- USER-DEFINED WRAPPER
    num_captured = 0
}
```

**Example**: `Json.Encode.object`
- Elm source: likely `object : List (String, Value) -> Value`
- At call site: `List.foldl <function> emptyObject pairs`
- The foldl callback needs signature: `tuple -> accumulator -> result`
- Kernel `Elm_Kernel_Json_addField` signature: `(key, value, object) -> result`
- **Mismatch**: Input is a tuple, kernel expects 3 separate args

**Generated MLIR** (RoundTripObjectTest.mlir, lines 42-48):
```mlir
func.func() {
    ^bb0(%_v0: !eco.value, %obj: !eco.value):
        %2 = "eco.project.tuple2"(%_v0) {field = 0} : !eco.value
        %3 = "eco.project.tuple2"(%_v0) {field = 1} : !eco.value
        %4 = "eco.call"(%2, %3, %obj) <{callee = @Elm_Kernel_Json_addField}>
        "eco.return"(%4)
} {sym_name = "RoundTripObjectTest_lambda_1"}
```

The wrapper:
1. Takes 2 parameters: a tuple and an accumulator
2. Destructures the tuple to extract key and value
3. Calls the 3-arg kernel with (key, value, accumulator)
4. Returns the result

### 4. Root Cause: Elm Source Function Structure

The distinction stems from how these functions are defined in the Elm standard library:

**Json.Encode.list** (inferred):
```elm
list : (a -> Value) -> List a -> Value
list encoder items =
    List.foldl (\entry acc -> ???) emptyArray items
```
The callback function `encoder` can be passed directly to `addEntry` kernel because both expect the same parameter structure: `(entry, accumulator)`.

**Json.Encode.object** (inferred):
```elm
object : List (String, Value) -> Value
object pairs =
    List.foldl (\(key, value) acc -> addField key value acc) emptyObject pairs
```
The callback pattern is `(\(key, value) acc -> ...)`, but the kernel `addField` expects 3 separate parameters. The Elm compiler must generate a wrapper lambda to bridge this mismatch.

### 5. How Arity Drives the Decision

In the list case:
- `Elm_Kernel_Json_addEntry : (!eco.value, !eco.value, !eco.value) -> !eco.value` (arity 3)
- After monomorphization, the Elm wrapper type remains compatible with this signature
- Direct PAP can wrap the kernel

In the object case:
- `Elm_Kernel_Json_addField : (!eco.value, !eco.value, !eco.value) -> !eco.value` (arity 3)
- But the Elm wrapper at the call site expects a 2-arg callback (tuple + accumulator)
- A wrapper lambda is necessary to adapt the calling convention

### 6. Original JavaScript Context

This reflects the original Elm-to-JavaScript pattern:
```javascript
// _Json_addField = F3(function(key, value, object) {...})
// Directly 3-arg, can't be partially applied as a callback

// _Json_addEntry(func) { return F2(function(entry, array) {...}) }
// Curried: takes encoder function, returns a 2-arg function
// The kernel dynamically creates the right callback signature
```

In the Eco compiler, this is resolved statically at compile time:
- If possible: use the kernel directly via PAP (list case)
- If necessary: generate a wrapper lambda (object case)

## Implementation Details

### Kernel ABI Types (KernelAbi.elm)

Three ABI modes determine how kernel function types are derived:

1. **UseSubstitution** (Monomorphic)
   - Kernels with no type variables
   - Example: `Basics.modBy : Int -> Int -> Int`
   - ABI matches the concrete types

2. **PreserveVars** (Polymorphic)
   - Kernels with type variables that must remain polymorphic
   - Example: `List.cons : a -> List a -> List a`
   - Type vars become `MVar _ CEcoValue` (all boxed)

3. **NumberBoxed** (Number-Polymorphic)
   - Kernels polymorphic over `number` (Int or Float)
   - Example: `Basics.add`, `String.fromNumber`
   - CNumber constraint treated as CEcoValue for ABI

### Type Flattening

`flattenFunctionType` in Types.elm converts nested function types to flat parameter list:

```elm
MFunction [a] (MFunction [b] (MFunction [c] d))
→ ([a, b, c], d)  -- Flattened to 3 parameters
```

This flattening is used by `countTotalArity` to determine if a direct PAP can be created.

## Key Code Locations

1. **MLIR Expr Generation**: `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`
   - `generateVarKernel` (lines 613-780): Main decision logic
   - `generateVarGlobal` (lines 520-609): Similar logic for user functions

2. **Type Analysis**: `/work/compiler/src/Compiler/Generate/MLIR/Types.elm`
   - `countTotalArity` (lines 269-275): Compute flattened arity
   - `flattenFunctionType` (lines 283-299): Flatten nested function types

3. **ABI Mode Selection**: `/work/compiler/src/Compiler/Monomorphize/KernelAbi.elm`
   - `deriveKernelAbiMode`: Determines which ABI mode to use
   - Type conversion functions for different modes

4. **Kernel Type Inference**: `/work/compiler/src/Compiler/Type/PostSolve.elm`
   - Infers kernel types from usage patterns

## Test Evidence

**RoundTripObjectTest.mlir**: Generates wrapper lambda
- `RoundTripObjectTest_lambda_1` (lines 42-48)
- `papCreate` references the lambda, not the kernel (line 76)
- Lambda destructures tuple before calling kernel

**RoundTripListTest.mlir**: Direct PAP
- `papCreate` references kernel directly (line 71)
- `papExtend` used to add remaining arguments (line 72)
- No wrapper lambda needed

## Conclusion

The compiler's decision is driven by **type structure alignment**:
- If the kernel function's arity and parameter types align with the monomorphized Elm function's signature → use direct PAP
- If there's a mismatch (e.g., tuple vs separate parameters) → generate a wrapper lambda

This is determined statically at MLIR generation time via `countTotalArity` and type compatibility checks.
