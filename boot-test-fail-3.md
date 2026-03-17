# Error 3: `eco.papExtend` saturated result type mismatch (2 errors)

## Root Cause

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`, `tryInlineCall` exact-application case (~line 1532-1546)

When `Basics.apR` (pipe operator `|>`) is inlined into a polymorphic function:

1. `apR` is monomorphized with type variables mapped to `CEcoValue`
2. Its body contains `MonoCall f [x] CEcoValue` — result type is `CEcoValue`
3. After inlining, `wrapInLetsForInline` wraps with the correct outer `resultType` (e.g., `MInt`), but does **not** update the inner `MonoCall`'s result type
4. The inner call's `CEcoValue` result type propagates to `monoTypeToAbi` -> `!eco.value` instead of `i64`
5. The saturated `papExtend` produces `!eco.value` but the target function returns `i64`

### Trigger conditions (ALL required)

1. **Polymorphic function** with a type variable in the result position (e.g., `a -> Maybe a -> a`)
2. **Pipe operator `|>`** (which desugars to `Basics.apR` call)
3. **Partial application** of a multi-argument function on the right side of the pipe (e.g., `Maybe.withDefault default`)

Removing any one condition makes the bug disappear.

## MLIR Evidence

```mlir
// In function: Compiler_LocalOpt_Erased_Case_arrayGetOr_$_18106
// Signature: (i64, i64, !eco.value) -> (i64)

%6 = "eco.papCreate"() {arity = 2, function = @Maybe_withDefault_$_17582, ...}
%4 = "eco.papExtend"(%6, %default) {newargs_unboxed_bitmap = 1, remaining_arity = 2} : (!eco.value, i64) -> !eco.value
%8 = "eco.papExtend"(%4, %3) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value  // ERROR
//   saturated result should be i64, not !eco.value
%9 = "eco.unbox"(%8) : (!eco.value) -> i64   // tries to unbox, but type is already wrong
```

While `Maybe_withDefault_$_17582` declares return type `i64`, the saturated `papExtend` produces `!eco.value`.

## Failing Test

`test/elm/src/PapSaturatePolyPipeMinimalTest.elm` — **FAILS** with: `Failed to parse or verify MLIR source`

## Fix Direction

After inlining substitution in `tryInlineCall` (line ~1542-1543), update the inner expression's result type to match the call site's `resultType`. The `substituted` body retains the callee's original monomorphized result type (`CEcoValue`) instead of being updated to the concrete type (`MInt`).
