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
    | MCustom IO.Canonical Name (List MonoType)  -- module, name, type args
    | MFunction (List MonoType) MonoType
    | MVar Name Constraint  -- Still polymorphic (for kernel ABIs)
```

### Constraints

Type variables can have constraints:

```elm
type Constraint
    = CEcoValue       -- Always boxed (heap pointer), can survive to codegen
    | CNumber         -- Must resolve to Int or Float before codegen
```

- `CEcoValue`: Used for kernel functions that work on any boxed value. Can remain unspecialized through to MLIR codegen where it becomes `eco.value`.
- `CNumber`: Used for `number` typeclass (arithmetic operations). MUST be resolved to `MInt` or `MFloat` by specialization; any remaining `CNumber` at codegen is a compiler bug.

### Monomorphizing Out Type Variables (Feb 2026)

The monomorphizer aggressively resolves type variables to concrete types, ensuring that the monomorphized AST is fully concrete. The key mechanism is `forceCNumberToInt`, which defaults unresolved numeric type variables to `MInt`:

```elm
-- forceCNumberToInt converts:
--   MVar "n" CNumber  -->  MInt
-- when no concrete numeric type is known from context.
```

This means:
- Type variables no longer escape into the monomorphized AST unless they are genuinely necessary (e.g., `CEcoValue` for polymorphic kernel function ABIs).
- The `CNumber` constraint is resolved to `MInt` by default when no concrete numeric type (Int or Float) is determined from the call-site context.
- **Strengthened invariant**: After monomorphization, MONO types should be fully concrete. The only surviving type variables are `MVar _ CEcoValue` for kernel ABIs.

This change tightens the contract between monomorphization and downstream passes (MLIR codegen), reducing the surface area for type variable handling in code generation.

### SpecKey and SpecId

Functions are identified by their specialization:

```elm
type SpecKey = SpecKey Global MonoType (Maybe LambdaId)  -- function + specialized type + optional lambda id
type alias SpecId = Int  -- unique numeric ID
```

The `LambdaId` identifies anonymous lambdas (closures) that need separate specializations:

```elm
type LambdaId = AnonymousLambda IO.Canonical Int  -- module + unique index
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

## Let-Bound Function Multi-Specialization (Feb 2026)

The monomorphizer supports demand-driven multi-specialization of let-bound polymorphic functions. When a polymorphic function is defined in a `let` expression and used at multiple call sites with different concrete types, the monomorphizer creates separate specialized instances for each distinct call-site type.

### Motivation

Consider:
```elm
let
    identity x = x
in
( identity 42, identity "hello" )
```

Without multi-specialization, `identity` would receive a single monomorphized type, losing the ability to generate type-specific code for each call site. With multi-specialization, the monomorphizer produces:
```elm
-- Generates:
--   identity_0 : Int -> Int
--   identity_1 : String -> String
```

### Mechanism

The algorithm works in three phases during expression specialization:

1. **Discovery**: When encountering a let-bound function definition, push a `localMulti` entry onto a stack within `MonoState`. This entry tracks the function's name and an initially empty dictionary of discovered instances.

2. **Collection**: Specialize the body expression of the `let`. Any calls to the let-bound function during body specialization record their concrete substitution in the stack entry. Each distinct type instantiation is keyed by its string representation, and a fresh name is generated for each.

3. **Emission**: After body specialization completes, pop the `localMulti` entry and examine the discovered instances:
   - **Multiple instances found**: Create separate `MonoDef` clones using `renameMonoDef`, each specialized with its call-site substitution. Build a nested `MonoLet` chain binding each specialized definition.
   - **Zero or one instances**: Fall back to single-instance behavior (the original let-specialization path).

### Data Structures

The multi-specialization state is stored in `MonoState`:

```elm
type alias MonoState =
    { ...
    , localMulti : List
        { defName : Name
        , instances : Dict String
            { freshName : Name
            , subst : Substitution
            , monoType : MonoType
            }
        }
    }
```

Each entry in the `localMulti` stack corresponds to a let-bound function currently being analyzed. The `instances` dictionary maps a string key (derived from the concrete type) to:
- `freshName`: A uniquified name for this specialization (e.g., `identity_0`, `identity_1`)
- `subst`: The type substitution mapping type variables to concrete types at this call site
- `monoType`: The fully concrete monomorphized type of the function at this call site

### Example Walkthrough

```elm
let
    pair a b = (a, b)
in
( pair 1 2, pair "x" "y" )
```

1. Push `{ defName = "pair", instances = {} }` onto `localMulti`
2. Specialize body `( pair 1 2, pair "x" "y" )`:
   - `pair 1 2` records instance: `{ freshName = "pair_0", subst = {a: MInt, b: MInt}, monoType = MFunction [MInt, MInt] (MTuple ...) }`
   - `pair "x" "y"` records instance: `{ freshName = "pair_1", subst = {a: MString, b: MString}, monoType = MFunction [MString, MString] (MTuple ...) }`
3. Pop entry, find 2 instances. Generate:
   ```
   MonoLet "pair_0" (specialized def for Int,Int) (
     MonoLet "pair_1" (specialized def for String,String) (
       ( MonoCall pair_0 [1, 2], MonoCall pair_1 ["x", "y"] )
     )
   )
   ```

## Layout Computation

### Record Layout

Records get concrete field layouts with unboxing information:

```elm
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int      -- bitmask of which fields are unboxed
    , fields : List FieldInfo
    }

type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : MonoType
    , isUnboxed : Bool  -- True for MInt/MFloat stored inline
    }
```

### Tuple Layout

```elm
type alias TupleLayout =
    { arity : Int           -- 2 or 3
    , unboxedBitmap : Int   -- bitmask of which elements are unboxed
    , elements : List (MonoType, Bool)  -- (type, isUnboxed)
    }
```

### Constructor Layout

```elm
type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }
```

Note: Custom types don't have a separate `CustomLayout` type. The `MCustom` variant stores `(IO.Canonical, Name, List MonoType)` - the module path, type name, and type arguments. The monomorphization pass computes `CtorLayout` for all constructors of each instantiated `MCustom` type (including constructors never directly used in code) and stores them in `MonoGraph.ctorLayouts`. Backends (MLIR) only consume this map and must not re-derive constructor layouts from `GlobalTypeEnv`.

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

## Container Element Specialization

Lists, tuples, and records can store **unboxable values** (Int, Float, Char) inline without heap allocation:

**List Unboxing**: When a list contains unboxable elements, the Cons cells store the head value unboxed:
```elm
-- List Int: Cons cells have unboxed i64 head, boxed tail pointer
-- List (List Int): Cons cells have boxed head (pointer to inner list)
```

The `unboxed_head` flag in the Cons cell header indicates whether the head is unboxed.

**Tuple/Record Unboxing**: The `unboxedBitmap` indicates which fields are stored unboxed:
```elm
-- { x : Int, y : Float, name : String }
-- unboxedBitmap = 0b011 (x and y unboxed, name boxed)
```

This optimization is computed during monomorphization based on field types. The MLIR codegen uses these layouts to generate appropriate load/store operations.

## Staging-Agnostic Design

**Important**: Monomorphization is **staging-agnostic**. It preserves the curried type structure from Elm semantics without making any staging or calling-convention decisions:

```elm
-- Input: add : Int -> Int -> Int
-- Output: MFunction [Int] (MFunction [Int] Int)  -- Still curried!
```

All staging decisions (how to group arguments, how to handle incompatible case branches) are deferred to the **GlobalOpt** phase. This separation ensures:

1. Monomorphization stays simple—focused on type specialization
2. Staging logic is centralized in GlobalOpt
3. Changes to calling conventions don't affect specialization

See **[Global Optimization Theory](pass_global_optimization_theory.md)** and **[Staged Currying Theory](staged_currying_theory.md)** for details on how staging is resolved after monomorphization.

## Kernel ABI Handling

Kernel functions don't get specialized. Instead, they have ABIs:

```elm
type KernelAbi
    = KernelAbi
        { argTypes : List MonoType
        , resultType : MonoType
        }
```

### ABI Modes

Different kernels use different ABI modes:

**AllBoxed** (CEcoValue): For kernels that work on any boxed value:
```elm
-- List.cons : a -> List a -> List a
-- ABI: (CEcoValue, MList CEcoValue) -> MList CEcoValue
```

**NumberBoxed** (CNumber): For kernels polymorphic over number (Int or Float). The type variable is treated as boxed CEcoValue so the C++ kernel receives a uniform uint64_t:
```elm
-- String.fromNumber : number -> String
-- At call site: fromNumber 42 passes boxed Int
-- Kernel receives uint64_t, checks tag to dispatch
```

Kernels using NumberBoxed mode include:
- `String.fromNumber`
- `Basics.add`, `sub`, `mul` (when used polymorphically)
- `Basics.pow` (polymorphic power)

**Specialized**: Some kernels can specialize to unboxable types and are converted back to boxed in codegen if necessary:
```elm
-- Kernel wrapper can specialize: List.cons with Int head
-- Codegen boxes the Int before calling the kernel
```

### Kernel Wrapper Specialization

The monomorphizer allows kernel wrappers to specialize to unboxable primitive types (Int, Float, Char). When the kernel ABI requires boxed values, the MLIR codegen phase handles the boxing/unboxing conversion. This enables container elements to be stored unboxed in the heap while still calling boxed-ABI kernels.

## Specialization Registry

Tracks all generated specializations:

```elm
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict (List String) (List String) SpecId    -- SpecKey -> SpecId
    , reverseMapping : Dict Int Int (Global, MonoType, Maybe LambdaId)  -- SpecId -> info
    }
```

## MonoGraph Output

The final output:

```elm
type MonoGraph =
    MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorLayouts : Dict (List String) (List String) (List CtorLayout)  -- type key -> complete ctor layouts
        }

type MainInfo
    = StaticMain SpecId  -- main specialization ID

type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List (Name, MonoType)) MonoExpr MonoType
    | MonoCtor CtorLayout MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType                    -- External/foreign function
    | MonoPortIncoming MonoExpr MonoType     -- Incoming port
    | MonoPortOutgoing MonoExpr MonoType     -- Outgoing port
    | MonoCycle (List (Name, MonoExpr)) MonoType  -- Mutually recursive definitions
```

## Data Structures

### MonoState

Internal state during monomorphization (conceptual; actual implementation may vary):

```elm
type alias MonoState =
    { globalGraph : TOpt.GlobalGraph
    , typeEnv : GlobalTypeEnv
    , worklist : List WorkItem
    , processed : Set (List String) SpecKey
    , registry : SpecializationRegistry
    , nodes : Dict Int Int MonoNode
    , localMulti : List                         -- Stack for let-bound multi-specialization (Feb 2026)
        { defName : Name
        , instances : Dict String
            { freshName : Name
            , subst : Substitution
            , monoType : MonoType
            }
        }
    }
```

### WorkItem

A work item identifies a function/definition to specialize at a particular type:

```elm
type alias WorkItem =
    { global : Global
    , monoType : MonoType
    , lambdaId : Maybe LambdaId  -- for closures
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
2. No type variables remain except `MVar _ CEcoValue` in kernel ABIs. `CNumber` variables are resolved to `MInt` by `forceCNumberToInt` when no concrete numeric type is determined from context (strengthened Feb 2026)
3. All layouts are computed
4. SpecializationRegistry has unique IDs for all specializations
5. Let-bound polymorphic functions used at multiple distinct types are multi-specialized into separate definitions with fresh names (Feb 2026)

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
