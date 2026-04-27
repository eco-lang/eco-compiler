# Typed Optimization Pass

## Overview

The Typed Optimization pass transforms Canonical AST into TypedOptimized AST, preserving full type information on every expression. This IR serves as the input to the monomorphization pass and is essential for backends that require type information for code generation (like the MLIR/LLVM backend).

**Phase**: Optimization (Type-Preserving)

**Pipeline Position**: After PostSolve, before Monomorphization

## Purpose

The standard Elm compiler's Optimized AST discards type information after type checking because JavaScript doesn't need it. ECO's native backend requires types for:

1. **Monomorphization**: Specializing polymorphic functions to concrete types
2. **Memory layout**: Determining record/tuple/custom type layouts
3. **Unboxing optimization**: Identifying primitives that can be stored unboxed
4. **Debug printing**: Runtime type table for value inspection

## TypedOptimized AST Structure

### Expression Types

Every expression variant carries its canonical type as the last argument:

```elm
type Expr
    = Bool A.Region Bool Can.Type
    | Chr A.Region String Can.Type
    | Str A.Region String Can.Type
    | Int A.Region Int Can.Type
    | Float A.Region Float Can.Type
    | VarLocal Name Can.Type
    | VarGlobal A.Region Global Can.Type
    | VarKernel A.Region Name Name Can.Type
    | List A.Region (List Expr) Can.Type
    | Function (List (Name, Can.Type)) Expr Can.Type
    | Call A.Region Expr (List Expr) Can.Type
    | If (List (Expr, Expr)) Expr Can.Type
    | Let Def Expr Can.Type
    | Case Name Name (Decider Choice) (List (Int, Expr)) Can.Type
    | Record (Dict String Name Expr) Can.Type
    | Tuple A.Region Expr Expr (List Expr) Can.Type
    -- ... etc
```

### Type Extraction

The `typeOf` function extracts the type from any expression:

```elm
typeOf : Expr -> Can.Type
typeOf expr =
    case expr of
        Bool _ _ t -> t
        Chr _ _ t -> t
        Int _ _ t -> t
        VarLocal _ t -> t
        Call _ _ _ t -> t
        -- ... all variants
```

### Graph Types

**LocalGraph**: Per-module dependency graph with annotations:

```elm
type alias LocalGraphData =
    { main : Maybe Main
    , nodes : Dict (List String) Global Node
    , fields : Dict String Name Int
    , annotations : Annotations  -- Dict String Name Can.Annotation
    }
```

**GlobalGraph**: Cross-module graph with merged annotations and scheme roots:

```elm
type GlobalGraph =
    GlobalGraph
        (Dict (List String) Global Node)
        (Dict String Name Int)
        AnnotationsByGlobal    -- keyed by full Global, not bare Name (Apr 2026)
        SchemeRootsByGlobal    -- solver root mappings per definition (Apr 2026)
```

*(Apr 2026)*: Annotations are now keyed by full `Global` (module + name) instead of bare `Name`, preventing cross-module annotation collisions. `SchemeRootsByGlobal` maps each definition to its solver root variable set, enabling solver root-backed MVarId assignment in monomorphization.

*(Apr 2026)*: Constructor type annotations (e.g., `Just : a -> Maybe a`) are now recorded in the `AnnotationsByGlobal` map during typed optimization, so the monomorphizer's scheme cache stores polymorphic constructor types instead of being poisoned by the first concrete usage. When building the TypedOptimized IR, the solver-inferred type is used for `VarGlobal` references.

### Node Types

Nodes represent top-level definitions with type information:

```elm
type Node
    = Define Expr (EverySet (List String) Global) Can.Type
    | TrackedDefine A.Region Expr (EverySet (List String) Global) Can.Type
    | DefineTailFunc A.Region (List (A.Located Name, Can.Type)) Expr (EverySet (List String) Global) Can.Type
    | Ctor Index.ZeroBased Int Can.Type  -- index, arity, constructor type
    | Enum Index.ZeroBased Can.Type
    | Box Can.Type
    | Link Global
    | Cycle (List Name) (List (Name, Expr)) (List Def) (EverySet (List String) Global)
    | Kernel (List K.Chunk) (EverySet (List String) Global)
    | PortIncoming Expr (EverySet (List String) Global) Can.Type
    | PortOutgoing Expr (EverySet (List String) Global) Can.Type
    -- ... etc
```

## Transformation Process

### Input

From `optimizeTyped`:

```elm
optimizeTyped :
    Annotations            -- From type checking
    -> ExprTypes           -- nodeTypes from PostSolve
    -> KernelTypeEnv       -- kernelEnv from PostSolve
    -> TCan.Module         -- Typed Canonical module
    -> MResult i (List W.Warning) TOpt.LocalGraph
```

### Key Transformations

1. **Preserve Types**: Attach `Can.Type` to every expression
2. **Optimize Patterns**: Convert pattern matching to decision trees
3. **Simplify Let Bindings**: Float out/inline where beneficial
4. **Tail Call Optimization**: Mark tail-recursive functions
5. **Build Dependency Graph**: Track which definitions reference which
6. **Short-Circuit `&&` / `||`** *(Apr 24, 2026)*: Rewrite to `If`-form for short-circuit semantics

### Short-Circuit `&&` and `||` *(Apr 24, 2026)*

The `Binop` arm of `Compiler/LocalOpt/Typed/Expression.elm` rewrites the boolean `&&` and `||` operators when they appear in expression position:

```
a && b   →   if a then b else False
a || b   →   if a then True else b
```

After this rewrite, every backend inherits short-circuit semantics from the existing `If` codegen path — there is no separate "lazy boolean" lowering to maintain in MLIR generation, JS generation, or any future backend.

The strict `eco.bool.and` / `eco.bool.or` intrinsics and the JS `&&` / `||` infix arms remain for first-class uses of `Basics.and` / `Basics.or` (e.g. when these names are passed as values rather than applied), where strict evaluation is the only option. Plan: `plans/short-circuit-bool-via-if.md`.

### Decision Trees

Pattern matching is compiled to optimized decision trees:

```elm
type Decider a
    = Leaf a
    | Chain (List (DT.Path, DT.Test)) (Decider a) (Decider a)
    | FanOut DT.Path (List (DT.Test, Decider a)) (Decider a)

type Choice
    = Inline Expr  -- Inline the branch body
    | Jump Int     -- Jump to shared branch
```

### Container Hints

For destructuring, the pass tracks container types:

```elm
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom
    | HintUnknown

type Path
    = Index Index.ZeroBased ContainerHint Path
    | ArrayIndex Int Path
    | Field Name Path
    | Unbox Path
    | Root Name
```

Container hints enable type-specific projection operations in later passes.

## Type Preservation Rules

### Literals

Literals get their concrete types:

```
Bool _ value -> Bool region value (TType Basics Bool [])
Int _ value  -> Int region value (TType Basics Int [])
Str _ value  -> Str region value (TType String String [])
```

### Variables

Variables carry their looked-up types:

```
VarLocal name     -> VarLocal name (lookupType name env)
VarGlobal home n  -> VarGlobal region (Global home n) (lookupType home n)
VarKernel h n     -> VarKernel region h n (lookupKernel h n kernelEnv)
```

### Functions

Lambda types are the full function type:

```
Lambda args body ->
    argTypes = [typeOf arg | arg <- args]
    bodyType = typeOf body
    funcType = argTypes -> bodyType
    Function (zip argNames argTypes) body' funcType
```

### Calls

Call types come from the result type of the function:

```
Call func args ->
    funcType = typeOf func
    resultType = peelResult(funcType, length args)
    Call region func' args' resultType
```

### Let Expressions

Let types are the body type:

```
Let def body ->
    Let def' body' (typeOf body')
```

## Implementation Details

### File Locations

- `compiler/src/Compiler/AST/TypedOptimized.elm`: AST definitions
- `compiler/src/Compiler/Optimize/Typed/Module.elm`: Main optimization entry
- `compiler/src/Compiler/Optimize/Typed/Expression.elm`: Expression transformation
- `compiler/src/Compiler/Optimize/Typed/DecisionTree.elm`: Pattern compilation

### Entry Point

```elm
-- Module.elm
optimizeTyped :
    Annotations
    -> ExprTypes
    -> KernelTypeEnv
    -> TCan.Module
    -> MResult i (List W.Warning) TOpt.LocalGraph
```

## Pre-conditions

1. PostSolve has run, producing fixed `nodeTypes` and `kernelEnv`
2. All expressions have complete types
3. Canonical AST is well-formed

## Post-conditions

1. Every expression in output has a `Can.Type` attached
2. Pattern matching is compiled to decision trees
3. Dependency graph captures all references
4. Annotations dictionary includes all definition types
5. Container hints are computed for destructuring paths

## Example Transformation

Input (Canonical):
```elm
add : Int -> Int -> Int
add x y = x + y
```

Output (TypedOptimized):
```elm
Define
    (Function
        [("x", TType Basics Int []), ("y", TType Basics Int [])]
        (Call region
            (VarKernel region "Basics" "add" (Int -> Int -> Int))
            [VarLocal "x" Int, VarLocal "y" Int]
            Int)
        (Int -> Int -> Int))
    deps
    (Int -> Int -> Int)
```

## Relationship to Other Passes

- **Requires**: PostSolve (fixed nodeTypes, kernelEnv)
- **Enables**: Monomorphization (type-directed specialization)
- **Key Output**: `LocalGraph` / `GlobalGraph` with type information
