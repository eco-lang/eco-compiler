# CGEN_056 Test Failure Investigation

## Problem Statement
Test CGEN_056 (Saturated PapExtend Result Type) fails because it finds two func.func operations with the same name `Test_lambda_0`:
1. One with return type `i64` (CORRECT)
2. One with return type `!eco.value` (WRONG - causes test failure)

The test uses `Dict.fromList` which keeps the LAST duplicate, so if the wrong one comes second, it's the one found in the map.

## Key Findings

### MLIR Body Order (Backend.elm line 82)
```elm
{ body = typeTableOp :: kernelDeclOps ++ lambdaOps ++ ops ++ mainOps
```

Order of function generation:
1. typeTableOp
2. kernelDeclOps (kernel declarations)
3. **lambdaOps** - from `Lambdas.processLambdas` (FIRST)
4. **ops** - from `Functions.generateNode` loop over MonoGraph nodes (SECOND)
5. mainOps

### Pending Lambda Generation (Expr.elm line 947-956)
When a closure appears in an expression (like in a let binding), a `PendingLambda` is created:
```elm
pendingLambda : Ctx.PendingLambda
pendingLambda =
    { name = lambdaIdToString closureInfo.lambdaId
    , captures = captureTypes
    , params = closureInfo.params
    , body = body
    , returnType = Mono.typeOf body  -- **BODY TYPE, NOT CLOSURE TYPE**
    , siblingMappings = baseSiblings
    , isTailRecursive = False
    }
```

### Lambda Processing (Lambdas.elm line 129-309)
`generateLambdaFunc` generates a `func.func` with:
- For zero captures: name = `lambda.name` (no suffix)
- Return type: `Types.monoTypeToAbi lambda.returnType`

### Node Generation (Functions.elm line 75-141)
`generateNode` handles MonoDefine nodes:
- If expr is MonoClosure, calls `generateClosureFunc`
- For zero captures, calls `generateClosureFuncSingle` (line 232-293)
- Extracts return type from the MonoType parameter:
  ```elm
  extractedReturnType : Mono.MonoType
  extractedReturnType =
      case monoType of
          Mono.MFunction _ retType ->
              retType
          _ ->
              monoType
  ```

### The Duplicate Function Scenario

If a closure appears as BOTH:
1. A pending lambda in an expression (from `Expr.generateClosure`)
2. A MonoNode in the MonoGraph (from monomorphization/specialization)

Then BOTH would be processed:
1. `lambdaOps` contains: `func.func @Test_lambda_0` with return type = `monoTypeToAbi (Mono.typeOf body)` ✓ CORRECT
2. `ops` contains: `func.func @Test_lambda_0` with return type = `monoTypeToAbi extractedReturnType` from the node's monoType

### The Critical Issue: What Return Type Does the Node Have?

When a closure is monomorphized as a node, the node's type is `Mono.typeOf monoExpr` where monoExpr is the MonoClosure.

The question is: **What does `Mono.typeOf` return for a `MonoClosure`?**

Let me check the typeOf definition...

### Placeholder Mappings (Expr.elm line 3085-3098)
When a let expression is processed, placeholder mappings are created for let-bound names:
```elm
Ctx.addVarMapping name ("%" ++ name) Types.ecoValue acc
```
These use type `!eco.value` as placeholders.

But these are updated at line 3199:
```elm
Ctx.addVarMapping name effectiveVar exprResult.resultType exprResult.ctx
```
With the actual result type.

## Hypothesis to Verify

The `Mono.typeOf` function for a `MonoClosure` expression returns the CLOSURE TYPE (the function type like `i -> i`), NOT the return type of the body.

When this closure type is used in `generateClosureFuncSingle`, it extracts:
```elm
extractedReturnType = case (i -> i) of MFunction _ retType -> retType  -- returns i
```

So the return type should be correct (`i64`).

UNLESS: The closure node's monoType is NOT a function type, but rather `!eco.value` (the generic box type used for closures as values).

This could happen if:
1. The closure is wrapped in an !eco.value type somewhere in monomorphization
2. When extracting the return type from !eco.value, it falls through to `_ -> monoType`, giving !eco.value as the return type

## Root Cause Analysis - Updated

### Key Finding: Return Type Extraction in generateClosureFuncSingle

When `generateClosureFuncSingle` receives a monoType parameter that is NOT a function type, it extracts the return type like this:

```elm
extractedReturnType : Mono.MonoType
extractedReturnType =
    case monoType of
        Mono.MFunction _ retType ->
            retType
        _ ->
            monoType  -- FALLTHROUGH: Returns the monoType itself!
```

If `monoType` is `!eco.value` (not a function type), then `extractedReturnType = !eco.value`, causing the wrong return type!

### Hypothesis: Dual Function Generation with Different Return Types

The error shows TWO `func.func @Test_lambda_0` operations:
1. First (from lambdaOps): return type `i64` ✓ CORRECT
2. Second (from ops): return type `!eco.value` ✗ WRONG

The second function comes from a MonoDefine NODE in the MonoGraph where:
- The node's monoType is NOT a function type (possibly `!eco.value`)
- This causes the return type extraction to fallthrough and use `!eco.value` as the return type

### Why Would a Closure Node Have a Non-Function Type?

Possible causes:
1. The closure is wrapped in GlobalOpt (via `makeGeneralClosureGO` or `makeAliasClosureGO`)
2. The wrapper's type is not a proper function type
3. The wrapper closure is added to the MonoGraph as a node
4. When this node is processed, its type is used for return type extraction

### dict.fromList Behavior

The test uses `Dict.fromList` which keeps the LAST duplicate key's value. Since lambdaOps come before ops in the module body, the node's version (with wrong return type) OVERWRITES the correct pending lambda version in the map.

### Solution Path

The fix should ensure that when a closure function is generated, the return type is extracted correctly from the closure's ACTUAL return type, not from a wrapper type. Specifically:
1. For pending lambdas: return type should be `Mono.typeOf body` ✓ Already correct
2. For node closures: return type should be extracted from the monoType properly, handling wrapper cases

The fallthrough in `extractedReturnType` might need to handle wrapper closures specially, OR the node's monoType should never be set to a non-function type.
