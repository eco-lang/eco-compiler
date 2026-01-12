# PostSolve Pass

## Overview

The PostSolve pass is a type-fixing phase that runs after the main type solver (`runWithIds`) and before conversion to TypedCanonical IR. It addresses two key problems: fixing incomplete types for "Group B" expressions and computing kernel function types from usage patterns.

**Phase**: Type Checking (Post-Solver)

**Pipeline Position**: After type solver, before `TypedCanonical.fromCanonical`

## Core Problems Addressed

### Problem 1: Group B Expression Types

The Elm type solver uses synthetic type variables for certain expressions. These fall into two groups:

- **Group A**: Expressions whose types are constrained by their context (Int literals, Negate, Binop, Call, If, Case, Access, Update). The solver computes meaningful types.
- **Group B**: Expressions whose types are unconstrained by the solver (Str, Chr, Float, Unit, List, Tuple, Record, Lambda, Accessor, Let/LetRec/LetDestruct). These have synthetic variables that need structural computation.

### Problem 2: VarKernel Types

Kernel functions (`VarKernel`) don't have type annotations in Elm source. Their types must be inferred from:
1. **Alias seeding**: When an Elm definition is a direct alias to a kernel function
2. **Usage inference**: When a kernel function is called, its type is inferred from argument/result types

## Algorithm Overview

The pass operates in two phases:

### Phase 0: Kernel Alias Seeding

Scans declarations for zero-argument definitions that are direct `VarKernel` references:

```
FUNCTION seedKernelAliases(annotations, decls):
    kernelEnv = empty
    FOR EACH def IN decls:
        IF def has no arguments AND body is VarKernel(home, name):
            type = lookupAnnotation(def.name, annotations)
            kernelEnv = insertFirstUsage(home, name, type, kernelEnv)
    RETURN kernelEnv
```

### Phase 1: Expression Traversal

Walks the AST, fixing Group B types and inferring kernel types from usage:

```
FUNCTION postSolveExpr(expr, nodeTypes, kernelEnv):
    CASE expr OF
        -- Group A: Trust solver's type, recurse into children
        Int | Negate | Binop | Call | If | Case | Access | Update:
            recurseIntoChildren(expr, nodeTypes, kernelEnv)

        -- VarKernel: Look up from kernelEnv
        VarKernel(home, name):
            IF kernelEnv.has(home, name):
                nodeTypes[expr.id] = kernelEnv.get(home, name)

        -- Group B: Compute type structurally
        Str: nodeTypes[expr.id] = String
        Chr: nodeTypes[expr.id] = Char
        Float: nodeTypes[expr.id] = Float
        Unit: nodeTypes[expr.id] = ()
        List(elems):
            elemType = typeOf(first elem) or TVar "a"
            nodeTypes[expr.id] = List elemType
        Tuple(a, b, cs):
            nodeTypes[expr.id] = (typeOf a, typeOf b, ...)
        Record(fields):
            nodeTypes[expr.id] = { field: typeOf(value), ... }
        Lambda(args, body):
            funcType = argTypes -> bodyType
            nodeTypes[expr.id] = funcType
        Let/LetRec/LetDestruct:
            nodeTypes[expr.id] = typeOf(body)
```

## Kernel Type Inference

### From Direct Calls

When a `VarKernel` is called directly:

```
FUNCTION postSolveCall(func, args, exprId, nodeTypes, kernelEnv):
    IF func IS VarKernel(home, name):
        -- Don't recurse into func first; infer its type from the call
        recurseIntoArgs(args, nodeTypes, kernelEnv)
        argTypes = [typeOf(arg) for arg in args]
        resultType = nodeTypes[exprId]  -- From solver (Group A)
        kernelType = buildFunctionType(argTypes, resultType)
        kernelEnv = insertFirstUsage(home, name, kernelType, kernelEnv)
        nodeTypes[func.id] = kernelType
```

### From Constructor Arguments

When a `VarKernel` is passed as an argument to a constructor:

```
FUNCTION postSolveCallWithCtorKernelArgs(ctorAnnotation, args, ...):
    (ctorArgTypes, ctorResType) = peelFunctionType(ctorAnnotation)
    callResultType = nodeTypes[exprId]
    subst = unifySchemeToType(ctorResType, callResultType)

    FOR EACH (arg, expectedType) IN zip(args, ctorArgTypes):
        IF arg IS VarKernel(home, name) AND NOT kernelEnv.has(home, name):
            inferredType = applySubst(subst, expectedType)
            kernelEnv = insertFirstUsage(home, name, inferredType, kernelEnv)
```

### From Binary Operators

When a `VarKernel` is an operand to a binary operator:

```
FUNCTION postSolveBinop(opAnnotation, left, right, ...):
    (argTypes, _) = peelFunctionType(opAnnotation)
    IF left IS VarKernel AND NOT kernelEnv.has(left):
        kernelEnv = insertFirstUsage(left.home, left.name, argTypes[0], kernelEnv)
    IF right IS VarKernel AND NOT kernelEnv.has(right):
        kernelEnv = insertFirstUsage(right.home, right.name, argTypes[1], kernelEnv)
```

### From Case Branch Bodies

When a `VarKernel` is the body of a case branch:

```
FUNCTION postSolveCase(scrutinee, branches, caseExprId, ...):
    caseResultType = nodeTypes[caseExprId]
    FOR EACH branch IN branches:
        IF branch.body IS VarKernel AND NOT kernelEnv.has(branch.body):
            kernelEnv = insertFirstUsage(home, name, caseResultType, kernelEnv)
```

## Type Unification

The pass includes a one-way unifier for matching polymorphic scheme types against concrete types:

```
FUNCTION unifySchemeToType(scheme, concrete) -> Maybe Subst:
    CASE (scheme, concrete) OF
        (TVar v, t):
            IF v IN subst AND subst[v] != t: RETURN Nothing
            RETURN Just (subst + {v -> t})

        (TType h1 n1 args1, TType h2 n2 args2):
            IF h1 == h2 AND n1 == n2:
                RETURN unifyList(subst, args1, args2)
            ELSE: RETURN Nothing

        (TLambda a1 r1, TLambda a2 r2):
            subst1 = unifyHelp(subst, a1, a2)?
            RETURN unifyHelp(subst1, r1, r2)

        -- Similar cases for TTuple, TRecord, TUnit, TAlias
```

## Data Structures

### NodeTypes

Maps expression/pattern IDs to canonical types:

```elm
type alias NodeTypes =
    Dict Int Int Can.Type
```

### KernelTypeEnv

Kernel function type environment (from `KernelTypes` module):
- Maps `(home, name)` pairs to canonical types
- Uses "first-usage-wins" semantics to prevent type conflicts
- Built incrementally during traversal

## Implementation Details

### File Location

`compiler/src/Compiler/Type/PostSolve.elm`

### Key Functions

| Function | Purpose |
|----------|---------|
| `postSolve` | Main entry point |
| `seedKernelAliases` | Phase 0: Seed kernel env from aliases |
| `postSolveDecls` | Phase 1: Walk declarations |
| `postSolveExpr` | Main expression traversal |
| `postSolveCall` | Handle calls with kernel type inference |
| `propagateKernelArgTypes` | Infer kernel types from call arguments |
| `unifySchemeToType` | One-way type unification |
| `applySubst` | Apply substitution to a type |
| `peelFunctionType` | Extract arg and result types |

## Pre-conditions

1. Type solver has run and produced `nodeTypes` map
2. All expressions have unique IDs
3. Canonical AST is well-formed

## Post-conditions

1. All Group B expressions have concrete types in `nodeTypes`
2. All used kernel functions have types in `kernelEnv`
3. `nodeTypes` is suitable for conversion to TypedCanonical IR

## Example

```elm
-- Elm source
foo : Int -> Int
foo = Kernel.Basics.add1  -- VarKernel alias

bar = Kernel.List.map foo [1,2,3]  -- VarKernel called
```

Phase 0 seeds:
- `Kernel.Basics.add1 : Int -> Int` (from `foo` alias)

Phase 1 infers:
- `Kernel.List.map : (a -> b) -> List a -> List b` (from usage)
- Unifies with call site types to get concrete specialization

## Relationship to Other Passes

- **Requires**: Type solver (`runWithIds`)
- **Enables**: `TypedCanonical.fromCanonical` conversion
- **Outputs**: Fixed `nodeTypes` and `kernelEnv` for typed optimization
