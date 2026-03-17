# Error 6: SSA dominance violation (1 error)

## Root Cause

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm:128-135`, interaction with `Expr.elm:addPlaceholderMappings`

When a let-bound tail-recursive function makes a non-tail recursive call to itself:

1. **Outer scope** (`Expr.elm:addPlaceholderMappings`): A placeholder SSA var (e.g., `%1`) is allocated and mapped to the function name in `currentLetSiblings`
2. **PendingLambda** (`Expr.elm:3383`): `siblingMappings` captures `currentLetSiblings` with the outer SSA var
3. **Lambda compilation** (`Lambdas.elm:128-135`): Sibling mappings are merged into `varMappings`, but `nextVar` is reset to `List.length allArgPairs`:
   ```elm
   varMappingsWithSiblings =
       Dict.union varMappingsWithArgs lambda.siblingMappings
   ctxWithArgs =
       { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarAfterParams }
   ```
4. **SSA aliasing** (`TailRec.elm:97-98`): `freshVar` allocates `doneInitVar` as `%1` (since nextVar was reset), creating a **collision** with the sibling mapping's `%1`
5. When the non-tail self-call is compiled, `lookupVar("firstInlineExpr")` returns `%1`, which now refers to `doneInitVar` (a different SSA value), not the function closure

This produces a dominance violation because the wrong SSA value is referenced across block boundaries.

## MLIR Evidence

```mlir
// In function: _tail_firstInlineExpr_275172
// scf.while iterates with carries: (!eco.value, i1, !eco.value)
// %3, %4, %5 = "scf.while"(%decider, %1, %2) ({
//     ^bb0(%6, %7, %8): ...condition block...
// }, {
//     ^bb0(%9, %10, %11): ...body block...

// At line 539698 (inside the body block):
%27 = "eco.project.custom"(%11) {field_index = 1} : (!eco.value) -> !eco.value
%28 = "eco.project.custom"(%11) {field_index = 2} : (!eco.value) -> !eco.value
%29 = "eco.papExtend"(%3, %27) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
//                     ^^ %3 is the RESULT of scf.while, defined AFTER the loop body
```

`%3` is the first result of the `scf.while` operation. Inside the while-loop body block, `%3` is not yet defined — the body block's arguments are `%9`, `%10`, `%11`. The codegen incorrectly references the while-loop result `%3` instead of the body block argument for carry position 0.

## Trigger Conditions (ALL required)

1. A **let-bound** tail-recursive function (`MonoTailDef` producing `_tail_` prefix)
2. The function makes a **non-tail recursive call to itself** inside the loop body (e.g., `case firstInlineExpr yes of Just e -> ...; Nothing -> firstInlineExpr no`)
3. The self-reference is resolved through sibling mappings, producing an `eco.papExtend` with the function closure as an operand
4. The sibling mapping SSA var happens to alias with a freshly allocated var (`doneInitVar`, `resInitVar`, or scf.while result vars)

### Why top-level tail-rec functions are not affected

Top-level tail-recursive functions (`generateTailFunc` in `Functions.elm`) do not use sibling mappings. They create `freshVarMappings` with only the function parameters. Self-references are handled differently (direct `eco.call` to the function symbol).

## Failing Test

`test/elm/src/TailRecDeciderSearchTest.elm` — **FAILS** with: `error: use of value '%1' expects different type than prior uses: '!eco.value' vs 'i1'`

## Fix Direction

The sibling mapping SSA vars from the outer scope must not alias with fresh vars inside the compiled lambda. Options:

- **Option A:** When merging sibling mappings, offset `nextVar` to account for the sibling SSA vars (ensure no collision)
- **Option B:** Re-allocate sibling mappings with fresh vars inside the lambda's SSA namespace, creating `eco.papCreate` ops that reference the correct lambda-local closure values
- **Option C:** For tail-recursive let-bound functions specifically, handle self-references via function symbol (like top-level functions) rather than through sibling closure mappings
