# Monomorphization Pass

## Overview

The Monomorphization pass transforms the TypedOptimized AST into a fully specialized Monomorphized IR where all polymorphic functions are specialized to their concrete type instantiations. This enables efficient native code generation without runtime type dispatch.

**Phase**: Specialization

**Pipeline Position**: After Typed Optimization, before MLIR Generation

## Purpose

Elm supports parametric polymorphism (generics). For native code generation, we must either:
1. **Box everything**: Pass all values uniformly (like JavaScript)
2. **Monomorphize**: Generate specialized code for each type instantiation

ECO chooses monomorphization for performance. A function like `List.map : (a -> b) -> List a -> List b` generates specialized versions for each concrete `(a, b)` pair used in the program.

## Core Concepts

### MonoType

The monomorphized type representation:

```elm
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple TupleLayout
    | MRecord RecordLayout
    | MCustom Name CustomLayout MonoType  -- name, layout, original type
    | MFunction (List MonoType) MonoType
    | MVar Name Constraint  -- Still polymorphic (for kernel ABIs)
```

### Constraints

Type variables can have constraints:

```elm
type Constraint
    = CUnconstrained
    | CEcoValue       -- Always boxed (heap pointer)
    | CNumber         -- Must resolve to Int or Float
```

- `CEcoValue`: Used for kernel functions that work on any boxed value
- `CNumber`: Used for `number` typeclass (arithmetic operations)

### SpecKey and SpecId

Functions are identified by their specialization:

```elm
type SpecKey = SpecKey Global (List MonoType)  -- function + type args
type SpecId = SpecId Int  -- unique numeric ID
```

### Substitution

Maps type variables to concrete MonoTypes:

```elm
type alias Substitution = Dict String Name MonoType
```

## Algorithm: Worklist-Based Specialization

The pass uses a worklist algorithm:

```
FUNCTION monomorphize(mainName, globalTypeEnv, globalGraph):
    state = initState(globalGraph, globalTypeEnv)

    -- Seed with main function (at concrete type)
    mainNode = lookupNode(mainName, globalGraph)
    mainType = lookupAnnotation(mainName, annotations)
    mainMonoType = canonToMono(mainType, emptySubst)
    enqueue(workItem(mainName, mainMonoType), state)

    -- Process worklist
    WHILE NOT isEmpty(state.worklist):
        item = dequeue(state)
        IF NOT alreadyProcessed(item, state):
            processWorkItem(item, state)

    RETURN buildMonoGraph(state)
```

### Work Item Processing

```
FUNCTION processWorkItem(item, state):
    node = lookupNode(item.global, state.globalGraph)

    CASE node OF
        Define expr deps type:
            -- Build substitution from annotation to concrete type
            subst = unifyTypes(type, item.monoType)

            -- Specialize the expression
            monoExpr = specializeExpr(expr, subst, state)

            -- Register the specialization
            specId = getOrCreateSpecId(item.global, item.monoType, state)
            registerSpec(specId, monoExpr, state)

        DefineTailFunc args body deps type:
            -- Similar, with arg types
            ...

        Ctor index arity type:
            -- Create constructor specialization
            specId = getOrCreateSpecId(item.global, item.monoType, state)
            registerCtor(specId, index, layout, state)

        Link target:
            -- Follow link, preserve type
            enqueue(workItem(target, item.monoType), state)

        Kernel chunks deps:
            -- Kernels have ABIs, not specializations
            registerKernel(item.global, chunks, state)
```

### Expression Specialization

```
FUNCTION specializeExpr(expr, subst, state):
    CASE expr OF
        VarLocal name type:
            monoType = applySubst(subst, canonToMono(type))
            RETURN MonoVarLocal name monoType

        VarGlobal region global type:
            monoType = applySubst(subst, canonToMono(type))
            -- Enqueue for specialization
            specId = getOrCreateSpecId(global, monoType, state)
            RETURN MonoVarGlobal specId monoType

        Call region func args type:
            func' = specializeExpr(func, subst, state)
            args' = [specializeExpr(arg, subst, state) | arg <- args]
            resultType = applySubst(subst, canonToMono(type))
            RETURN MonoCall func' args' resultType

        Function params body type:
            paramTypes = [(name, applySubst(subst, canonToMono(t))) | (name, t) <- params]
            body' = specializeExpr(body, subst, state)
            captures = computeCaptures(params, body, state)
            RETURN MonoFunction paramTypes captures body'

        -- ... similar for all expression types
```

## Layout Computation

### Record Layout

Records get concrete field layouts:

```elm
type alias RecordLayout =
    { fields : List FieldInfo
    , totalSize : Int  -- in words
    }

type alias FieldInfo =
    { name : Name
    , fieldType : MonoType
    , offset : Int  -- word offset
    }
```

### Tuple Layout

```elm
type alias TupleLayout =
    { elements : List MonoType
    , size : Int  -- 2 or 3 for Tuple2/Tuple3
    }
```

### Custom Type Layout

```elm
type alias CustomLayout =
    { typeName : Name
    , ctors : List CtorLayout
    }

type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List MonoType
    }
```

## Type Conversion: Canonical to Mono

```
FUNCTION canonToMono(canType, subst):
    CASE canType OF
        TType "Basics" "Int" []:    RETURN MInt
        TType "Basics" "Float" []:  RETURN MFloat
        TType "Basics" "Bool" []:   RETURN MBool
        TType "Char" "Char" []:     RETURN MChar
        TType "String" "String" []: RETURN MString
        TUnit:                      RETURN MUnit

        TType "List" "List" [elem]:
            RETURN MList (canonToMono elem subst)

        TTuple a b []:
            RETURN MTuple { elements = [canonToMono a, canonToMono b], size = 2 }

        TTuple a b [c]:
            RETURN MTuple { elements = [canonToMono a, b, c], size = 3 }

        TRecord fields Nothing:
            fieldInfos = [{ name, fieldType = canonToMono t, offset = i }
                         | (i, (name, FieldType _ t)) <- indexed fields]
            RETURN MRecord { fields = fieldInfos, totalSize = length fields }

        TLambda arg result:
            (argTypes, resultType) = peelLambdas(canType)
            RETURN MFunction (map canonToMono argTypes) (canonToMono resultType)

        TVar name:
            IF name IN subst: RETURN subst[name]
            ELSE: RETURN MVar name CUnconstrained

        TType home name args:
            -- Custom type: look up union definition
            unionDef = lookupUnion(home, name)
            layout = computeCustomLayout(unionDef, args, subst)
            RETURN MCustom name layout canType
```

## Closure Capture Analysis

For lambda expressions, we compute captured variables:

```
FUNCTION computeCaptures(params, body, env):
    paramNames = [name | (name, _) <- params]
    freeVars = freeVariables(body) - paramNames
    RETURN [(name, lookupType(name, env)) | name <- freeVars]
```

Captures are stored in closure layouts for code generation.

## Kernel ABI Handling

Kernel functions don't get specialized. Instead, they have ABIs:

```elm
type KernelAbi
    = KernelAbi
        { argTypes : List MonoType
        , resultType : MonoType
        }
```

Some kernel functions use `CEcoValue` constraint to accept any boxed value:

```elm
-- List.cons : a -> List a -> List a
-- ABI: (CEcoValue, MList CEcoValue) -> MList CEcoValue
```

## Specialization Registry

Tracks all generated specializations:

```elm
type alias SpecializationRegistry =
    { specIdToKey : Dict Int SpecId SpecKey
    , keyToSpecId : Dict (List String) SpecKey SpecId
    , nextSpecId : Int
    }
```

## MonoGraph Output

The final output:

```elm
type alias MonoGraph =
    { specs : Dict Int SpecId MonoNode
    , main : SpecId
    , registry : SpecializationRegistry
    , kernels : Dict (List String) Global KernelAbi
    , typeEnv : GlobalTypeEnv
    }

type MonoNode
    = MonoDefine MonoExpr (List SpecId)
    | MonoTailFunc (List (Name, MonoType)) MonoExpr
    | MonoCtor Int CtorLayout
    | MonoEnum Int
```

## Data Structures

### MonoState

Internal state during monomorphization:

```elm
type alias MonoState =
    { globalGraph : TOpt.GlobalGraph
    , typeEnv : GlobalTypeEnv
    , worklist : List WorkItem
    , processed : Set (List String) SpecKey
    , registry : SpecializationRegistry
    , specs : Dict Int SpecId MonoNode
    , kernels : Dict (List String) Global KernelAbi
    }
```

### WorkItem

```elm
type alias WorkItem =
    { global : Global
    , monoType : MonoType
    }
```

## Implementation Details

### File Locations

- `compiler/src/Compiler/Generate/Monomorphize.elm`: Main algorithm (~2500 lines)
- `compiler/src/Compiler/AST/Monomorphized.elm`: AST definitions (~750 lines)

### Entry Point

```elm
monomorphize :
    Name                    -- main function name
    -> TypeEnv.GlobalTypeEnv
    -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
```

## Pre-conditions

1. TypedOptimized AST with complete type annotations
2. All referenced definitions are in the GlobalGraph
3. Union definitions are available in GlobalTypeEnv

## Post-conditions

1. All polymorphic functions are specialized to concrete types
2. No type variables remain (except `CEcoValue`/`CNumber` in kernel ABIs)
3. All layouts are computed
4. SpecializationRegistry has unique IDs for all specializations

## Example

Input:
```elm
identity : a -> a
identity x = x

main = identity 42
```

Output specializations:
```
SpecId 0: main : Int
    body: MonoCall (MonoVarGlobal SpecId(1)) [MonoInt 42]

SpecId 1: identity<Int> : Int -> Int
    body: MonoFunction [("x", MInt)] [] (MonoVarLocal "x" MInt)
```

## Relationship to Other Passes

- **Requires**: Typed Optimization (GlobalGraph with types)
- **Enables**: MLIR Generation (type-directed code generation)
- **Key Output**: MonoGraph with all specializations
