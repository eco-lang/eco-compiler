# NormalizeLambdaBoundaries Theory

## Overview

The NormalizeLambdaBoundaries pass flattens nested lambda structures by lifting let-bindings and case expressions out of lambda boundaries. This reduces spurious staging boundaries, enabling simpler and more efficient code generation in downstream passes (GlobalOpt, MLIR generation).

**Phase**: Typed Optimization

**Pipeline Position**: After PostSolve and the main Typed Optimization (addDecls), before Monomorphization. Specifically, `normalizeLocalGraph` is applied between `addDecls` and `finalizeLocalGraph` in the Typed Optimization pipeline.

**Related Modules**:
- `compiler/src/Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm` — The pass implementation
- `compiler/src/Compiler/LocalOpt/Typed/Module.elm` — Pipeline integration point (calls `normalizeLocalGraph`)

## Motivation

After standard typed optimization, lambdas may contain unnecessary nesting patterns:

```elm
-- Before: spurious let boundary inside a lambda
\x -> let t = expensive x in \y -> body t y

-- After normalization: flattened lambda
\x y -> let t = expensive x in body t y
```

The nested form creates an artificial staging boundary: the outer lambda takes one argument, allocates a closure capturing `t`, and returns a new closure. The flattened form takes both arguments at once, avoiding the intermediate closure.

Similarly, case expressions whose branches all return lambdas of the same arity can be unified:

```elm
-- Before: each branch returns a lambda
\x -> case x of
    A -> \y -> bodyA y
    B -> \y -> bodyB y

-- After: lambda parameters pulled out
\x y -> case x of
    A -> bodyA y
    B -> bodyB y
```

Without this pass, GlobalOpt's staging analysis would need to handle these patterns, and the resulting MLIR would contain more closure allocations than necessary.

## Let-Boundary Lifting

**Transformation**: `\outerParams -> let defs in \innerParams -> body` → `\(outerParams ++ innerParams) -> let defs in body`

The `tryNormalizeLetBoundary` function:

1. **Peel lets**: `peelLets body []` collects `Let` definitions, peeling through nested `Let` wrappers until it reaches a non-Let expression.
2. **Check for inner lambda**: If the innermost expression is a `Function` or `TrackedFunction`, the boundary can be lifted.
3. **Guard**: If there are no let definitions between the outer and inner lambda (i.e., the lambda is directly nested), skip—there is no boundary to lift.
4. **Merge parameters**: Concatenate `outerParams ++ innerParams`.
5. **Rebuild lets**: Rewrap the inner body with the collected let definitions via `rebuildLets`.

The result is a single lambda with combined parameters and the let bindings inside the body.

## Case-Boundary Lifting

**Transformation**: Unify branch lambdas into an outer lambda.

`tryNormalizeCaseBoundary` handles the more complex case where a lambda body is a `Case` expression whose branches all produce lambdas:

1. **Hoist inline lambdas to jumps**: `hoistInlineLambdaChoicesToJumps` converts any `Inline` choice in the decision tree that contains a lambda into a `Jump` referencing a new entry in the jump table. This ensures all lambda branches are in the jump table where they can be uniformly processed.

2. **Guard against mixed branches**: If any `Inline` choices remain after hoisting (non-lambda branches), abort. Normalizing would change the case result type for some branches but not others, violating TOPT_004/GOPT_003.

3. **Extract and unify branch parameters**: `extractAndUnifyBranchParams` checks that:
   - Every jump target is a `Function` or `TrackedFunction`.
   - All branches have the **same arity** (number of parameters).
   - All branches have **matching parameter types** (by structural equality of `Can.Type`).

4. **Generate canonical parameters**: Fresh parameter names are generated with the `_hl_` suffix pattern (see Alpha-Renaming below). Each branch body is alpha-renamed to use these canonical names.

5. **Peel case result type**: `peelLambdaTypes arity caseType` strips `arity` layers of `TLambda` from the case result type. If the type is not sufficiently curried (fewer than `arity` arrows), the normalization aborts.

6. **Rebuild**: The outer lambda gains the canonical parameters, and the case expression's branches contain the renamed bodies (no longer lambdas).

## Fixpoint Iteration

`normalizeLambdaBodyFixpoint` applies let-lifting and case-lifting repeatedly until neither produces a change:

```elm
normalizeLambdaBodyFixpoint params body lambdaType =
    case tryNormalizeLetBoundary params body of
        Just ( newParams, newBody ) ->
            normalizeLambdaBodyFixpoint newParams newBody lambdaType

        Nothing ->
            case tryNormalizeCaseBoundary params body lambdaType of
                Just ( newParams, newBody ) ->
                    normalizeLambdaBodyFixpoint newParams newBody lambdaType

                Nothing ->
                    ( params, body )
```

Fixpoint iteration is necessary because one normalization step may expose another. For example, lifting a let boundary may reveal an inner case boundary, or vice versa.

## Alpha-Renaming Strategy

When case branches have different parameter names but compatible types, the pass generates fresh canonical names and renames each branch body.

### Suffix Pattern

Fresh names use the `_hl_` suffix (for "hoist lambda"): `originalName_hl_0`, `originalName_hl_1`, etc. The `RenameCtx` tracks a monotonically increasing counter.

```elm
type alias RenameCtx = { nextId : Int }

freshName : Name.Name -> RenameCtx -> ( Name.Name, RenameCtx )
```

### RenameEnv

A `RenameEnv` is a `Dict Name.Name Name.Name` mapping old parameter names to new canonical names.

### renameExpr

`renameExpr env expr` walks the AST, substituting variable references according to the environment. It handles all expression forms including nested lambdas, let bindings, case expressions, destructors, and decision trees.

Special care is taken with:
- **Decision tree paths and tests**: Path references and destructors within `Decider` structures are renamed.
- **Nested definitions**: Let-bound definitions have their bodies renamed recursively.
- **Shadowing**: The rename environment is applied as a simple substitution; shadowing is not an issue because the `_hl_` suffix pattern generates globally fresh names.

## Safety Constraints

The pass enforces several safety constraints to ensure correctness:

1. **Same arity across branches**: All case branches must have the same number of lambda parameters. Mixed arities would produce inconsistent calling conventions.

2. **Same types across branches**: Parameter types must match structurally across all branches. Type mismatches would violate monomorphization assumptions.

3. **No mixed Inline/Jump**: After hoisting, if any non-lambda `Inline` choices remain, the pass aborts. This prevents partially normalizing a case expression where some branches are lambdas and others are not.

4. **Type peeling**: The case result type must have enough `TLambda` layers to peel off the branch arity. If `peelLambdaTypes arity caseType` returns `Nothing`, the types are inconsistent and normalization aborts.

5. **Non-empty let boundary**: For let-lifting, there must be at least one let definition between the outer and inner lambda. Direct lambda nesting (`\x -> \y -> body`) without intervening bindings is left unchanged (it's already handled naturally by downstream passes).

## Pipeline Integration

In `Module.elm`, `normalizeLocalGraph` is called as part of the typed optimization pipeline:

```elm
|> addDecls ...
|> ReportingResult.map (LambdaNorm.normalizeLocalGraph >> finalizeLocalGraph)
```

The pass operates on the entire `LocalGraph`, normalizing every node:

```elm
normalizeLocalGraph (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data | nodes = Dict.map (\_ node -> normalizeNode node) data.nodes }
```

Within each node, `normalizeExpr` recursively walks the expression tree, applying `normalizeLambdaBodyFixpoint` at every `Function` and `TrackedFunction`.

## Pre-conditions

- The AST has complete type annotations (PostSolve has run).
- Pattern matching has been compiled to decision trees (Typed Optimization has run).
- Each expression carries a valid `Can.Type`.

## Post-conditions

- No `Function` or `TrackedFunction` has a body that is directly a `Let` wrapping another `Function`/`TrackedFunction` (let-boundaries are absorbed).
- No `Function` or `TrackedFunction` has a body that is a `Case` where all branches are lambdas of the same arity and type (case-boundaries are absorbed).
- All types remain consistent: case result types are peeled to reflect absorbed parameters.
- The transformation is semantically equivalent to the original (same denotational semantics).

## Example

### Let-Lifting

```elm
-- Before:
\x -> let helper = computeHelper x
      in \y -> helper + y

-- After:
\x y -> let helper = computeHelper x
        in helper + y
```

### Case-Lifting

```elm
-- Before:
\tag -> case tag of
    Red   -> \x -> x + 1
    Green -> \x -> x + 2
    Blue  -> \x -> x + 3

-- After (with fresh names):
\tag x_hl_0 -> case tag of
    Red   -> x_hl_0 + 1
    Green -> x_hl_0 + 2
    Blue  -> x_hl_0 + 3
```

## Relationship to Other Passes

- **Typed Optimization**: Provides the AST with type annotations and decision trees that this pass operates on.
- **Monomorphization**: Runs after this pass; benefits from flatter lambda structures that produce simpler `MFunction` types with fewer staging levels.
- **GlobalOpt**: The primary beneficiary. Flattened lambdas mean fewer distinct staging segmentations to resolve, reducing the complexity of the staging constraint graph.
- **MLIR Generation**: Fewer nested closures means fewer `eco.papCreate` operations and simpler control flow in the generated MLIR.

## See Also

- [Typed Optimization Theory](pass_typed_optimization_theory.md) — The AST representation this pass operates on
- [Global Optimization Theory](pass_global_optimization_theory.md) — Staging canonicalization that benefits from flattened lambdas
- [Staged Currying Theory](staged_currying_theory.md) — Calling conventions affected by lambda structure
