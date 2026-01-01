# E2E Test Issue 3: Incorrect Operand Count for Higher-Order Functions

## Affected Tests (14+)

- CompositionTest.elm
- HigherOrderTest.elm
- ListFilterTest.elm
- ListFoldlTest.elm
- ListFoldrTest.elm
- ListMapTest.elm
- MutualRecursionTest.elm
- PartialAppChainTest.elm
- PartialApplicationTest.elm
- PipelineTest.elm
- And others using `<<`, `>>`, `|>`, `List.map`, `List.filter`, etc.

## Analysis

### Symptom
Tests fail with:
```
error: 'llvm.call' op incorrect number of operands (2) for callee (expecting: 3)
```

### Root Cause
Higher-order functions like `<<` (composeL), `>>` (composeR), and `|>` (apR) are **curried functions** that return new functions. When partially applied, they should create closures, but the generated code attempts to call them directly with fewer arguments.

### Example: Composition Operators

The `<<` operator has type `(b -> c) -> (a -> b) -> a -> c` - it takes 3 arguments total.

Generated MLIR:
```mlir
%2 = "eco.call"(%0, %1) <{callee = @Basics_composeL_$_3}> : (!eco.value, !eco.value) -> !eco.value
```

This calls with **2 arguments**, expecting to get back a function.

But `Basics_composeL_$_3` is defined with **3 parameters**:
```mlir
"func.func"() ({
    ^bb0(%g: !eco.value, %f: !eco.value, %x: !eco.value):
      %3 = "eco.papExtend"(%f, %x) ...
      %5 = "eco.papExtend"(%g, %4) ...
      "eco.return"(%5) : (i64) -> ()
}) {function_type = (!eco.value, !eco.value, !eco.value) -> (i64), sym_name = "Basics_composeL_$_3"}
```

The code should either:
1. Create a partial application (PAP) when calling with 2 args
2. Have a separate 2-argument version that returns a closure

### Example: Pipe Operator

The `|>` operator with signature `a -> (a -> b) -> b`:

```mlir
%21 = "eco.call"(%19, %20) <{_operand_types = [i64, !eco.value], callee = @Basics_apR_$_5}> : (i64, !eco.value) -> i64
```

Here `Basics_apR_$_5` has signature `(!eco.value, !eco.value) -> (i64)`:
```mlir
"func.func"() ({
    ^bb0(%x: !eco.value, %f: !eco.value):
      %2 = "eco.papExtend"(%f, %x) ...
}) {function_type = (!eco.value, !eco.value) -> (i64)}
```

The call passes `(i64, !eco.value)` but function expects `(!eco.value, !eco.value)`.

### The Core Problem

The compiler is treating curried functions as if they were uncurried. When you write:
```elm
addOneThenDouble = addOne >> double
```

The `>>` is being called with 2 function arguments, expecting to get back a new function. But the generated code tries to call a 3-argument function with only 2 arguments.

## Proposed Solution

### Option A: Generate Partial Application at Call Sites (Recommended)

When calling a function with fewer arguments than its arity, generate a PAP:

```mlir
// Current (broken):
%2 = "eco.call"(%0, %1) <{callee = @Basics_composeL_$_3}> : (!eco.value, !eco.value) -> !eco.value

// Fixed: Create PAP with 2 captured args, 1 remaining
%2 = "eco.papCreate"() {arity = 3, function = @Basics_composeL_$_3, num_captured = 0} : () -> !eco.value
%3 = "eco.papExtend"(%2, %0) {remaining_arity = 2} : (!eco.value, !eco.value) -> !eco.value
%4 = "eco.papExtend"(%3, %1) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
// %4 is now a PAP with 1 remaining argument
```

When the PAP is later applied with the final argument, it invokes the actual function.

### Option B: Generate Arity-Specific Function Variants

For common cases, generate multiple versions:

```mlir
// 3-arg version (full application)
"func.func"() ({
    ^bb0(%g: !eco.value, %f: !eco.value, %x: !eco.value):
      ...
}) {sym_name = "Basics_composeL_$_3_arity3"}

// 2-arg version (returns closure)
"func.func"() ({
    ^bb0(%g: !eco.value, %f: !eco.value):
      %pap = "eco.papCreate"() {arity = 1, function = @Basics_composeL_inner, ...}
      %pap2 = "eco.papExtend"(%pap, %g) ...
      %pap3 = "eco.papExtend"(%pap2, %f) ...
      "eco.return"(%pap3) : (!eco.value) -> ()
}) {sym_name = "Basics_composeL_$_3_arity2"}
```

### Option C: Always Use PAP Machinery

Never generate direct calls to multi-argument functions. Always create a PAP and extend it:

```mlir
// Even for full application:
%pap = "eco.papCreate"() {arity = 3, function = @Basics_composeL_$_3}
%pap1 = "eco.papExtend"(%pap, %arg0) {remaining_arity = 2}
%pap2 = "eco.papExtend"(%pap1, %arg1) {remaining_arity = 1}
%result = "eco.papExtend"(%pap2, %arg2) {remaining_arity = 0}  // Triggers actual call
```

This is simpler but less efficient for full applications.

## Implementation Steps

1. **Track function arity** in the compiler's symbol table
2. **At call sites**, compare provided arg count to function arity
3. **If args < arity**, generate PAP creation and extension
4. **If args == arity**, generate direct call (optimization)
5. **If args > arity** (shouldn't happen in well-typed code), error
6. **Update eco.papExtend** to handle the final application (remaining_arity = 0)

## PAP Runtime Support

Verify the PAP operations work correctly:

```mlir
// eco.papCreate - creates empty PAP for function with given arity
%pap = "eco.papCreate"() {arity = N, function = @fn} : () -> !eco.value

// eco.papExtend - adds argument to PAP
// If remaining_arity > 0: returns new PAP
// If remaining_arity == 0: invokes function with all captured args
%result = "eco.papExtend"(%pap, %arg) {remaining_arity = M} : (!eco.value, !eco.value) -> !eco.value
```

## Files to Modify

- Compiler function call codegen
- Compiler symbol table (track arity)
- Possibly eco.papExtend lowering (ensure it handles remaining_arity = 0)

## Estimated Complexity

Medium-High - Requires changes to the compiler's call emission logic and verification that the PAP runtime support is complete.
