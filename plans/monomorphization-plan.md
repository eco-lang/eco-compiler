# Monomorphization Plan for Guida Compiler

## Executive Summary

This document outlines the design for adding monomorphization to the Guida compiler's MLIR backend. Monomorphization is the process of converting polymorphic (generic) functions into specialized versions for each concrete type they're used with. This is critical for efficient native code generation.

## Background Research: How Roc Does It

### Roc's Approach: Lambda Set Specialization (LSS)

Based on research into the Roc compiler ([PLDI 2023 paper](https://dl.acm.org/doi/10.1145/3591260), [Roc documentation](https://github.com/roc-lang/roc/blob/main/Glossary.md)), Roc uses a sophisticated approach called **Lambda Set Specialization**:

1. **Lambda Sets**: A type-level annotation tracking which concrete lambdas a function type can contain at runtime
2. **Defunctionalization**: Converting higher-order programs to first-order by replacing function calls with switch statements on tags
3. **Type Monomorphization**: Creating specialized versions of polymorphic functions for each concrete instantiation

### Key Insight from Roc

> "Because Roc monomorphizes type-polymorphic functions, and lambda sets are part of function types, Roc will produce unique instantiations of functions that use or produce unique lambda sets."

Roc's approach is particularly sophisticated because it handles closures at the type level. For Guida/Elm, we can use a simpler approach since:
- Elm has no rank-2 types (making full monomorphization feasible)
- Elm's closure semantics are well-defined
- We already have full type information in `TypedOptimized` IR

## Monomorphization Algorithm

### High-Level Overview

```
MONOMORPHIZE(globalGraph):
    worklist = findEntryPoints(globalGraph)
    specialized = {}

    while worklist is not empty:
        (global, concreteType) = worklist.pop()
        key = (global, concreteType)

        if key in specialized:
            continue

        node = lookup(global, globalGraph)
        specializedNode = specializeNode(node, concreteType, worklist)
        specialized[key] = specializedNode

    return specialized
```

### Phase 1: Collection (Find What Needs Specializing)

```
FIND_ENTRY_POINTS(globalGraph):
    entries = []

    -- Start from main
    if globalGraph.main exists:
        mainType = typeOf(globalGraph.main)
        entries.add((mainGlobal, mainType))

    -- Also include all exports with concrete types
    for each (global, node) in globalGraph.nodes:
        if isExported(global) and hasConcreteType(node):
            entries.add((global, typeOfNode(node)))

    return entries
```

### Phase 2: Type Substitution

When we encounter a polymorphic function called with concrete types:

```
SPECIALIZE_NODE(node, concreteType, worklist):
    case node of:
        Define(expr, deps, polyType):
            -- Compute substitution from polyType to concreteType
            subst = unifyTypes(polyType, concreteType)

            -- Apply substitution to expression
            specializedExpr = applySubst(subst, expr)

            -- Find new dependencies with their concrete types
            newDeps = collectCallsWithTypes(specializedExpr)
            for each (depGlobal, depType) in newDeps:
                worklist.add((depGlobal, depType))

            return Define(specializedExpr, newDeps, concreteType)

        DefineTailFunc(args, body, deps, returnType):
            subst = unifyTypes(functionType(args, returnType), concreteType)
            specializedArgs = [(name, applySubst(subst, argType)) for (name, argType) in args]
            specializedBody = applySubst(subst, body)
            specializedReturnType = applySubst(subst, returnType)

            newDeps = collectCallsWithTypes(specializedBody)
            for each dep in newDeps:
                worklist.add(dep)

            return DefineTailFunc(specializedArgs, specializedBody, newDeps, specializedReturnType)

        Ctor(index, arity, ctorType):
            -- Constructors are specialized by their result type
            subst = unifyTypes(ctorType, concreteType)
            return Ctor(index, arity, concreteType)

        -- Other node types...
```

### Phase 3: Expression Specialization

```
APPLY_SUBST(subst, expr):
    case expr of:
        VarLocal(name, type):
            return VarLocal(name, substituteType(subst, type))

        VarGlobal(region, global, type):
            -- The global reference stays the same, but we record the concrete type
            -- This will be used to generate a specialized call
            return VarGlobal(region, global, substituteType(subst, type))

        Call(region, func, args, resultType):
            specializedFunc = applySubst(subst, func)
            specializedArgs = [applySubst(subst, arg) for arg in args]
            specializedResult = substituteType(subst, resultType)
            return Call(region, specializedFunc, specializedArgs, specializedResult)

        Function(params, body, funcType):
            specializedParams = [(name, substituteType(subst, t)) for (name, t) in params]
            specializedBody = applySubst(subst, body)
            specializedFuncType = substituteType(subst, funcType)
            return Function(specializedParams, specializedBody, specializedFuncType)

        List(region, elements, listType):
            specializedElements = [applySubst(subst, e) for e in elements]
            specializedListType = substituteType(subst, listType)
            return List(region, specializedElements, specializedListType)

        -- Continue for all expression variants...
```

### Phase 4: Type Substitution Core

```
SUBSTITUTE_TYPE(subst, type):
    case type of:
        TVar(name):
            if name in subst:
                return subst[name]
            else:
                return TVar(name)  -- Remains polymorphic

        TLambda(from, to):
            return TLambda(substituteType(subst, from), substituteType(subst, to))

        TType(canonical, name, args):
            return TType(canonical, name, [substituteType(subst, a) for a in args])

        TRecord(fields, ext):
            specializedFields = {name: FieldType(idx, substituteType(subst, t))
                                 for (name, FieldType(idx, t)) in fields}
            return TRecord(specializedFields, ext)

        TTuple(a, b, rest):
            return TTuple(substituteType(subst, a),
                         substituteType(subst, b),
                         [substituteType(subst, r) for r in rest])

        TUnit:
            return TUnit

        TAlias(canonical, name, args, aliasType):
            specializedArgs = [(n, substituteType(subst, t)) for (n, t) in args]
            case aliasType of:
                Holey(inner):
                    return TAlias(canonical, name, specializedArgs, Holey(substituteType(subst, inner)))
                Filled(inner):
                    return TAlias(canonical, name, specializedArgs, Filled(substituteType(subst, inner)))


UNIFY_TYPES(polyType, concreteType):
    -- Returns a substitution (Dict Name Type) that makes polyType equal to concreteType
    subst = {}
    unifyHelper(polyType, concreteType, subst)
    return subst

UNIFY_HELPER(poly, concrete, subst):
    case (poly, concrete) of:
        (TVar(name), _):
            if name in subst:
                unifyHelper(subst[name], concrete, subst)
            else:
                subst[name] = concrete

        (TLambda(from1, to1), TLambda(from2, to2)):
            unifyHelper(from1, from2, subst)
            unifyHelper(to1, to2, subst)

        (TType(c1, n1, args1), TType(c2, n2, args2)):
            assert c1 == c2 and n1 == n2
            for (a1, a2) in zip(args1, args2):
                unifyHelper(a1, a2, subst)

        (TRecord(fields1, ext1), TRecord(fields2, ext2)):
            for name in keys(fields1):
                unifyHelper(fields1[name].type, fields2[name].type, subst)

        (TTuple(a1, b1, rest1), TTuple(a2, b2, rest2)):
            unifyHelper(a1, a2, subst)
            unifyHelper(b1, b2, subst)
            for (r1, r2) in zip(rest1, rest2):
                unifyHelper(r1, r2, subst)

        (TUnit, TUnit):
            pass

        (TAlias(_, _, _, Filled(inner1)), _):
            unifyHelper(inner1, concrete, subst)

        (_, TAlias(_, _, _, Filled(inner2))):
            unifyHelper(poly, inner2, subst)
```

## Mapping to TypedOptimized.GlobalGraph

### Current IR Structure

```elm
type GlobalGraph
    = GlobalGraph
        (Dict (List String) Global Node)    -- nodes: Global -> Node
        (Dict String Name Int)               -- fields
        Annotations                          -- type annotations

type Node
    = Define Expr (EverySet Global) Can.Type
    | TrackedDefine Region Expr (EverySet Global) Can.Type
    | DefineTailFunc Region (List (Located Name, Type)) Expr (EverySet Global) Type
    | Ctor Index.ZeroBased Int Can.Type
    | Enum Index.ZeroBased Can.Type
    | Box Can.Type
    | Link Global
    | Cycle (List Name) (List (Name, Expr)) (List Def) (EverySet Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet Global)
    | PortIncoming Expr (EverySet Global) Can.Type
    | PortOutgoing Expr (EverySet Global) Can.Type
```

### Proposed Monomorphized IR

Location: `Compiler/AST/Monomorphized.elm`

#### Monomorphic Types (No type variables)

```elm
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple MonoType MonoType (List MonoType)
    | MRecord RecordLayout
    | MCustom IO.Canonical Name (List MonoType) CustomLayout
    | MFunction (List MonoType) MonoType  -- arg types, return type
```

#### Layouts (Runtime representation info)

```elm
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int
    , fields : List FieldInfo
    }

type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : MonoType
    , isUnboxed : Bool
    }

type alias CustomLayout =
    { constructors : List CtorLayout
    }

type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo  -- Declaration order
    , unboxedCount : Int
    , unboxedBitmap : Int
    }

type alias TupleLayout =
    { unboxedBitmap : Int
    , fieldTypes : List ( MonoType, Bool )  -- type, isUnboxed
    }
```

#### Lambda Sets

```elm
type LambdaId
    = NamedFunction Global
    | AnonymousLambda ModuleName.Canonical Int CaptureSet  -- module, unique id, captures

type alias CaptureSet =
    List ( Name, MonoType )
```

#### Specialization Keys and IDs

```elm
type Global
    = Global IO.Canonical Name

type SpecKey
    = SpecKey Global MonoType (Maybe LambdaId)  -- original, concrete type, optional lambda

type alias SpecId = Int  -- Unique integer ID for each specialization

type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict SpecKey SpecId
    }
```

#### Mono Graph

```elm
type MonoGraph
    = MonoGraph
        { nodes : Dict SpecId MonoNode
        , main : Maybe SpecId
        , registry : SpecializationRegistry
        }
```

#### Mono Nodes

```elm
type MonoNode
    = MonoDefine MonoExpr (EverySet SpecId) MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr (EverySet SpecId) MonoType
    | MonoCtor CtorLayout MonoType
    | MonoEnum Int MonoType  -- tag, type
    | MonoExtern MonoType    -- External/kernel function
    | MonoPortIncoming MonoExpr (EverySet SpecId) MonoType
    | MonoPortOutgoing MonoExpr (EverySet SpecId) MonoType
```

#### Mono Expressions

```elm
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType  -- home, name, type
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType  -- captures, body, type
    | MonoCall Region MonoExpr (List MonoExpr) MonoType
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List MonoExpr) RecordLayout MonoType
    | MonoRecordAccess MonoExpr Name Int Bool MonoType  -- record, field, index, unboxed?, type
    | MonoRecordUpdate MonoExpr (List ( Int, MonoExpr )) RecordLayout MonoType
    | MonoTuple Region MonoExpr MonoExpr (List MonoExpr) TupleLayout MonoType
    | MonoTupleAccess MonoExpr Int Bool MonoType  -- tuple, index, unboxed?, type
    | MonoCustomCreate Name Int (List MonoExpr) CustomLayout MonoType  -- ctor, tag, args, layout, type
    | MonoUnit

type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String

type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )  -- name, value, isUnboxed
    }

type MonoDef
    = MonoDef Region Name MonoExpr MonoType
    | MonoTailDef Region Name (List ( Name, MonoType )) MonoExpr MonoType

type MonoDestructor
    = MonoDestructor Name MonoPath MonoType

type MonoPath
    = MonoIndex Index.ZeroBased MonoPath
    | MonoField Name Int MonoPath  -- name, index, path
    | MonoUnbox MonoPath
    | MonoRoot Name

type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)

type MonoChoice
    = Inline MonoExpr
    | Jump Int
```

#### Key Differences from TypedOptimized

| Aspect | TypedOptimized | Monomorphized |
|--------|----------------|---------------|
| Types | `Can.Type` (may have `TVar`) | `MonoType` (no type variables) |
| Globals | `Global` (original name) | `SpecId` (integer ID) |
| Records | Fields by name | `RecordLayout` with indices, bitmap |
| Custom types | Generic | `CustomLayout` with per-ctor layouts |
| Functions | Generic | Includes `LambdaId` when specialized |
| Closures | Implicit | Explicit `ClosureInfo` with captures |

### Key Naming Strategy

Specialized functions use integer IDs:

```
<Module>_<function>_$_<id>

Examples:
  identity_$_0       -- identity specialized for Int
  identity_$_1       -- identity specialized for List String
  List_map_$_0       -- map specialized for (String.length, String, Int)
  List_map_$_1       -- map specialized for (anon_42, Int, Int)
```

The `SpecializationRegistry` maintains the mapping from `(Global, MonoType, Maybe LambdaId)` to integer IDs.

### Algorithm Applied to TypedOptimized

Location: `Compiler/Generate/Monomorphize.elm`

#### State

```elm
type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict SpecId MonoNode
    , inProgress : EverySet SpecId  -- For detecting recursion
    , registry : SpecializationRegistry
    , errors : List Error
    }

type WorkItem
    = SpecializeGlobal Global MonoType (Maybe LambdaId)

type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict ComparableSpecKey SpecId
    }

-- For Dict keys, need comparable representation
type alias ComparableSpecKey = ( List String, List String, Maybe (List String) )

toComparableSpecKey : SpecKey -> ComparableSpecKey
```

#### Main Entry Point

```elm
monomorphize : TOpt.GlobalGraph -> Result (List Error) MonoGraph
monomorphize (TOpt.GlobalGraph nodes fields annotations) =
    let
        -- Find entry point (main)
        initialWorklist = findMain nodes

        initialState =
            { worklist = initialWorklist
            , nodes = Dict.empty
            , inProgress = EverySet.empty
            , registry = { nextId = 0, mapping = Dict.empty }
            , errors = []
            }

        finalState = processWorklist nodes initialState
    in
    if List.isEmpty finalState.errors then
        Ok (MonoGraph
            { nodes = finalState.nodes
            , main = findMainSpecId finalState.registry
            , registry = finalState.registry
            })
    else
        Err finalState.errors


findMain : Dict Global TOpt.Node -> List WorkItem
findMain nodes =
    -- Find the main function and determine its concrete type
    case findMainGlobal nodes of
        Just (global, mainType) ->
            [ SpecializeGlobal global (toMonoType mainType) Nothing ]

        Nothing ->
            []
```

#### Worklist Processing

```elm
processWorklist : Dict Global TOpt.Node -> MonoState -> MonoState
processWorklist toptNodes state =
    case state.worklist of
        [] ->
            state

        (SpecializeGlobal global monoType maybeLambda) :: rest ->
            let
                specKey = SpecKey global monoType maybeLambda
                comparableKey = toComparableSpecKey specKey
            in
            case Dict.get comparableKey state.registry.mapping of
                Just specId ->
                    -- Already specialized or in progress, skip
                    processWorklist toptNodes { state | worklist = rest }

                Nothing ->
                    -- Allocate new SpecId
                    let
                        specId = state.registry.nextId
                        newRegistry =
                            { nextId = specId + 1
                            , mapping = Dict.insert comparableKey specId state.registry.mapping
                            }

                        -- Mark as in progress (for recursive calls)
                        stateWithId =
                            { state
                            | registry = newRegistry
                            , inProgress = EverySet.insert specId state.inProgress
                            , worklist = rest
                            }
                    in
                    case Dict.get global toptNodes of
                        Nothing ->
                            -- External/kernel function
                            let
                                newState =
                                    { stateWithId
                                    | nodes = Dict.insert specId (MonoExtern monoType) stateWithId.nodes
                                    , inProgress = EverySet.remove specId stateWithId.inProgress
                                    }
                            in
                            processWorklist toptNodes newState

                        Just toptNode ->
                            -- Specialize the node
                            let
                                (monoNode, newWorkItems, stateAfterSpec) =
                                    specializeNode toptNode monoType maybeLambda stateWithId

                                newState =
                                    { stateAfterSpec
                                    | nodes = Dict.insert specId monoNode stateAfterSpec.nodes
                                    , inProgress = EverySet.remove specId stateAfterSpec.inProgress
                                    , worklist = stateAfterSpec.worklist ++ newWorkItems
                                    }
                            in
                            processWorklist toptNodes newState
```

#### Node Specialization

```elm
specializeNode : TOpt.Node -> MonoType -> Maybe LambdaId -> MonoState
               -> ( MonoNode, List WorkItem, MonoState )
specializeNode node monoType maybeLambda state =
    case node of
        TOpt.Define expr deps canType ->
            let
                subst = unify canType monoType
                (monoExpr, workItems, newState) =
                    specializeExpr expr subst maybeLambda state
                depIds = collectDependencies monoExpr
            in
            ( MonoDefine monoExpr depIds monoType
            , workItems
            , newState
            )

        TOpt.DefineTailFunc region args body deps returnType ->
            let
                funcType = buildFuncType args returnType
                subst = unify funcType monoType
                monoArgs = List.map (specializeArg subst) args
                (monoBody, workItems, newState) =
                    specializeExpr body subst maybeLambda state
                depIds = collectDependencies monoBody
            in
            ( MonoTailFunc monoArgs monoBody depIds (getReturnType monoType)
            , workItems
            , newState
            )

        TOpt.Ctor index arity ctorType ->
            let
                subst = unify ctorType monoType
                layout = buildCtorLayout monoType
            in
            ( MonoCtor layout monoType
            , []
            , state
            )

        TOpt.Enum index enumType ->
            ( MonoEnum index monoType
            , []
            , state
            )

        -- Handle other node types...
```

#### Expression Specialization with Lambda Set Tracking

```elm
specializeExpr : TOpt.Expr -> Substitution -> Maybe LambdaId -> MonoState
               -> ( MonoExpr, List WorkItem, MonoState )
specializeExpr expr subst currentLambda state =
    case expr of
        TOpt.VarGlobal region global canType ->
            let
                monoType = applySubst subst canType
                workItem = SpecializeGlobal global monoType Nothing
                (specId, newState) = getOrCreateSpecId global monoType Nothing state
            in
            ( MonoVarGlobal region specId monoType
            , [ workItem ]
            , newState
            )

        TOpt.Call region func args resultType ->
            let
                monoResultType = applySubst subst resultType
                (monoFunc, funcWorkItems, state1) = specializeExpr func subst currentLambda state
                (monoArgs, argsWorkItems, state2) = specializeExprs args subst currentLambda state1

                -- Check if func is a known global - if so, create lambda-specialized version
                (finalFunc, extraWorkItems, state3) =
                    case (monoFunc, detectLambdaArg monoArgs) of
                        (MonoVarGlobal r specId funcType, Just lambdaId) ->
                            -- This is a call like `List.map f xs` where f is a known lambda
                            -- Create a lambda-specialized version
                            let
                                originalGlobal = lookupGlobal specId state2.registry
                                workItem = SpecializeGlobal originalGlobal funcType (Just lambdaId)
                                (newSpecId, newState) = getOrCreateSpecId originalGlobal funcType (Just lambdaId) state2
                            in
                            ( MonoVarGlobal r newSpecId funcType
                            , [ workItem ]
                            , newState
                            )

                        _ ->
                            ( monoFunc, [], state2 )
            in
            ( MonoCall region finalFunc monoArgs monoResultType
            , funcWorkItems ++ argsWorkItems ++ extraWorkItems
            , state3
            )

        TOpt.Function params body funcType ->
            let
                monoFuncType = applySubst subst funcType
                monoParams = List.map (specializeParam subst) params

                -- Create a LambdaId for this function
                lambdaId = AnonymousLambda currentModule (allocateLambdaId state) (extractCaptures expr)

                (monoBody, workItems, newState) =
                    specializeExpr body subst (Just lambdaId) state

                closureInfo =
                    { lambdaId = lambdaId
                    , captures = computeCaptures expr subst
                    }
            in
            ( MonoClosure closureInfo monoBody monoFuncType
            , workItems
            , newState
            )

        TOpt.Record fields canType ->
            let
                monoType = applySubst subst canType
                layout = computeRecordLayout monoType
                (monoFields, workItems, newState) =
                    specializeRecordFields fields subst layout state
            in
            ( MonoRecordCreate monoFields layout monoType
            , workItems
            , newState
            )

        TOpt.Access record region fieldName canType ->
            let
                monoType = applySubst subst canType
                (monoRecord, workItems, newState) = specializeExpr record subst currentLambda state
                recordType = getType monoRecord
                layout = getRecordLayout recordType
                fieldInfo = lookupField fieldName layout
            in
            ( MonoRecordAccess monoRecord fieldName fieldInfo.index fieldInfo.isUnboxed monoType
            , workItems
            , newState
            )

        -- Continue for all expression variants...
```

#### Helper: Detecting Lambda Arguments

```elm
-- When we see `List.map f xs`, detect if `f` is a known lambda
detectLambdaArg : List MonoExpr -> Maybe LambdaId
detectLambdaArg args =
    case args of
        (MonoClosure info _ _) :: _ ->
            Just info.lambdaId

        (MonoVarGlobal _ specId _) :: _ ->
            -- This is a reference to a named function
            Just (NamedFunction (lookupGlobalFromSpecId specId))

        _ ->
            Nothing
```

#### Type Unification and Substitution

```elm
type alias Substitution = Dict Name MonoType

unify : Can.Type -> MonoType -> Substitution
unify canType monoType =
    unifyHelp canType monoType Dict.empty

unifyHelp : Can.Type -> MonoType -> Substitution -> Substitution
unifyHelp canType monoType subst =
    case ( canType, monoType ) of
        ( Can.TVar name, _ ) ->
            Dict.insert name monoType subst

        ( Can.TLambda from1 to1, MFunction args ret ) ->
            let
                subst1 = unifyHelp from1 (List.head args |> Maybe.withDefault MUnit) subst
                subst2 = unifyHelp to1 (MFunction (List.drop 1 args) ret) subst1
            in
            subst2

        ( Can.TType _ _ args1, MCustom _ _ args2 _ ) ->
            List.foldl
                (\( a1, a2 ) s -> unifyHelp a1 a2 s)
                subst
                (List.zip args1 args2)

        ( Can.TRecord fields1 _, MRecord layout ) ->
            List.foldl
                (\fieldInfo s ->
                    case Dict.get fieldInfo.name fields1 of
                        Just (Can.FieldType _ fieldType) ->
                            unifyHelp fieldType fieldInfo.monoType s
                        Nothing ->
                            s
                )
                subst
                layout.fields

        _ ->
            subst


applySubst : Substitution -> Can.Type -> MonoType
applySubst subst canType =
    case canType of
        Can.TVar name ->
            Dict.get name subst |> Maybe.withDefault MUnit

        Can.TLambda from to ->
            MFunction [ applySubst subst from ] (applySubst subst to)

        Can.TType canonical name args ->
            let
                monoArgs = List.map (applySubst subst) args
                layout = computeCustomLayout canonical name monoArgs
            in
            MCustom canonical name monoArgs layout

        Can.TRecord fields maybeExt ->
            let
                monoFields = Dict.map (\_ (Can.FieldType _ t) -> applySubst subst t) fields
                layout = computeRecordLayout monoFields
            in
            MRecord layout

        Can.TTuple a b rest ->
            MTuple (applySubst subst a) (applySubst subst b) (List.map (applySubst subst) rest)

        Can.TUnit ->
            MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            applySubst subst inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                argSubst = List.foldl (\( n, t ) s -> Dict.insert n (applySubst subst t) s) subst args
            in
            applySubst argSubst inner
```

## Implementation Plan

### Step 1: Monomorphized IR Module

Create `Compiler/AST/Monomorphized.elm`:
- All types defined in "Proposed Monomorphized IR" section above
- Comparison functions for `SpecKey`, `MonoType`, `LambdaId`
- Helper functions: `typeOf`, `getLayout`, `canUnbox`

### Step 2: Monomorphization Pass

Create `Compiler/Generate/Monomorphize.elm`:
- State management and worklist algorithm
- Type unification and substitution
- Node and expression specialization
- Layout computation for records, custom types, tuples

```elm
module Compiler.Generate.Monomorphize exposing (monomorphize)

monomorphize : TOpt.GlobalGraph -> Result (List Error) MonoGraph
```

### Step 3: Update MLIR Backend

Modify `Compiler/Generate/CodeGen/MLIR.elm` to accept `MonoGraph`:

See "MLIR Backend Integration" section below for details.

### Step 4: Integration

Modify `Compiler/Generate/Generate.elm`:
- Add monomorphization step before MLIR code generation
- Only run monomorphization for backends that need it

```elm
typedDev : TypedCodeGen -> ... -> Task Exit.Generate CodeGen.Output
typedDev backend ... artifacts =
    let
        globalGraph = buildTypedGlobalGraph artifacts
    in
    case Monomorphize.monomorphize globalGraph of
        Ok monoGraph ->
            generateFromMono backend monoGraph

        Err errors ->
            Task.throw (Exit.MonomorphizationFailed errors)
```

## MLIR Backend Integration

### Changes to MLIR.elm

The MLIR backend currently works with `TOpt.GlobalGraph`. After monomorphization, it will work with `MonoGraph`.

#### New Module Structure

```elm
module Compiler.Generate.CodeGen.MLIR exposing (generate)

import Compiler.AST.Monomorphized as Mono

generate : Mono.MonoGraph -> String
generate (Mono.MonoGraph { nodes, main, registry }) =
    let
        ctx = initContext registry
        ops = Dict.foldl (generateNode ctx) [] nodes
        mainOp = generateMain main
    in
    renderModule (ops ++ [ mainOp ])
```

#### Function Name Generation

```elm
generateFunctionName : Mono.SpecId -> SpecializationRegistry -> String
generateFunctionName specId registry =
    let
        (global, _, _) = lookupSpecKey specId registry
        (Mono.Global canonical name) = global
        moduleName = ModuleName.toHyphenatedString canonical
    in
    moduleName ++ "_" ++ name ++ "_$_" ++ String.fromInt specId
```

#### Type-Aware Code Generation

With `MonoType` instead of `Can.Type`, we can generate precise MLIR types:

```elm
generateMlirType : Mono.MonoType -> MlirType
generateMlirType monoType =
    case monoType of
        Mono.MInt ->
            I64Type

        Mono.MFloat ->
            F64Type

        Mono.MBool ->
            I1Type

        Mono.MChar ->
            I32Type  -- Unicode codepoint

        Mono.MString ->
            EcoStringType

        Mono.MUnit ->
            UnitType

        Mono.MList inner ->
            EcoListType (generateMlirType inner)

        Mono.MTuple a b rest ->
            EcoTupleType (List.map generateMlirType (a :: b :: rest))

        Mono.MRecord layout ->
            EcoRecordType layout

        Mono.MCustom _ name args layout ->
            EcoCustomType name (List.map generateMlirType args) layout

        Mono.MFunction args ret ->
            FunctionType (List.map generateMlirType args) (generateMlirType ret)
```

#### Record Operations

```elm
generateRecordCreate : List MlirValue -> Mono.RecordLayout -> MlirOp
generateRecordCreate values layout =
    mlirOp "eco.record_create"
        |> withAttr "field_count" (IntAttr layout.fieldCount)
        |> withAttr "unboxed_bitmap" (IntAttr layout.unboxedBitmap)
        |> withOperands values
        |> build

generateRecordAccess : MlirValue -> Int -> Bool -> MlirOp
generateRecordAccess record index isUnboxed =
    mlirOp "eco.record_get"
        |> withOperand record
        |> withAttr "index" (IntAttr index)
        |> withAttr "unboxed" (BoolAttr isUnboxed)
        |> build

generateRecordUpdate : MlirValue -> List ( Int, MlirValue ) -> Mono.RecordLayout -> MlirOp
generateRecordUpdate record updates layout =
    let
        -- First allocate new record
        allocOp = generateRecordAlloc layout

        -- Copy all fields from old record
        copyOps = List.map (generateFieldCopy record layout) (List.range 0 (layout.fieldCount - 1))

        -- Override with updated fields
        updateOps = List.map (\( idx, val ) -> generateFieldSet idx val layout) updates
    in
    mlirBlock (allocOp :: copyOps ++ updateOps)
```

#### Custom Type Operations

```elm
generateCustomCreate : Int -> List MlirValue -> Mono.CustomLayout -> MlirOp
generateCustomCreate tag values layout =
    let
        ctorLayout = getCtorByTag tag layout
    in
    mlirOp "eco.custom_create"
        |> withAttr "tag" (IntAttr tag)
        |> withAttr "unboxed_bitmap" (IntAttr ctorLayout.unboxedBitmap)
        |> withOperands values
        |> build

generateCustomMatch : MlirValue -> Mono.CustomLayout -> (Int -> MlirBlock) -> MlirOp
generateCustomMatch value layout branchGenerator =
    let
        branches =
            List.map
                (\ctor -> ( ctor.tag, branchGenerator ctor.tag ))
                layout.constructors
    in
    mlirOp "eco.custom_switch"
        |> withOperand value
        |> withRegions branches
        |> build
```

#### Closure Operations

```elm
generateClosure : Mono.ClosureInfo -> MlirValue -> MlirOp
generateClosure info bodyValue =
    let
        captureOps =
            List.map
                (\( name, expr, isUnboxed ) ->
                    generateCapture name expr isUnboxed
                )
                info.captures

        unboxedBitmap =
            List.indexedMap
                (\i ( _, _, isUnboxed ) -> if isUnboxed then 1 `shiftL` i else 0)
                info.captures
                |> List.foldl (|) 0
    in
    mlirOp "eco.closure_create"
        |> withAttr "lambda_id" (lambdaIdAttr info.lambdaId)
        |> withAttr "unboxed_bitmap" (IntAttr unboxedBitmap)
        |> withOperands (List.map Tuple.second captureOps)
        |> withRegion [ bodyValue ]
        |> build
```

#### Function Calls with Lambda Specialization

```elm
generateCall : MlirValue -> List MlirValue -> Mono.MonoType -> Context -> MlirOp
generateCall func args resultType ctx =
    case func of
        MonoVarGlobal _ specId _ ->
            -- Direct call to specialized function
            let
                funcName = generateFunctionName specId ctx.registry
            in
            mlirOp "eco.call"
                |> withAttr "callee" (SymbolAttr funcName)
                |> withOperands args
                |> withResultType (generateMlirType resultType)
                |> build

        MonoClosure info _ _ ->
            -- For lambda-specialized HOF, the closure is inlined
            -- The specialized function already has the lambda baked in
            mlirOp "eco.call"
                |> withAttr "callee" (SymbolAttr (getLambdaSpecializedName info ctx))
                |> withOperands (List.drop 1 args)  -- Drop the closure arg, it's baked in
                |> withResultType (generateMlirType resultType)
                |> build

        _ ->
            -- Indirect call (fallback, shouldn't happen often with lambda sets)
            mlirOp "eco.indirect_call"
                |> withOperand func
                |> withOperands args
                |> withResultType (generateMlirType resultType)
                |> build
```

### Example: Complete Transformation

**Elm source:**
```elm
main = List.map String.length ["hello", "world"]
```

**After monomorphization:**
```
MonoGraph {
  nodes = {
    0 -> MonoDefine                           -- main_$_0
           (MonoCall List_map_$_1 [...])
           {1}
           (MList MInt)

    1 -> MonoDefine                           -- List_map_$_1 (specialized for String.length)
           (MonoCase ...)                     -- Body with String.length inlined
           {2}
           (MFunction [MList MString] (MList MInt))

    2 -> MonoExtern                           -- String_length_$_2
           (MFunction [MString] MInt)
  }
  main = Just 0
}
```

**Generated MLIR:**
```mlir
module {
  // String.length - external
  func.func private @String_length_$_2(!eco.string) -> i64

  // List.map specialized for String.length
  func.func @List_map_$_1(%list: !eco.list<!eco.string>) -> !eco.list<i64> {
    // Implementation with String.length calls inlined/direct
    ...
  }

  // main
  func.func @main_$_0() -> !eco.list<i64> {
    %strings = "eco.list_create"() { ... } : () -> !eco.list<!eco.string>
    %result = call @List_map_$_1(%strings) : (!eco.list<!eco.string>) -> !eco.list<i64>
    return %result : !eco.list<i64>
  }

  // Entry point
  func.func @main() -> i32 {
    %result = call @main_$_0() : () -> !eco.list<i64>
    // ... print or return
    return %c0 : i32
  }
}
```

## Challenges and Considerations

### 1. Code Size Bloat

Monomorphization can significantly increase code size. Mitigations:
- Only specialize functions that are actually used
- Consider function merging for identical specializations
- Potentially add a "share code" mode for debug builds

### 2. Recursive Types

Recursive types (like `List a`) require care:
```elm
type List a = Nil | Cons a (List a)
```

When monomorphizing `List Int`:
- `Nil` constructor stays the same structurally
- `Cons` needs specialized layout for `Int`

### 3. Mutual Recursion

Functions that call each other must be specialized together:
```elm
isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)
```

Both must be specialized for the same integer type.

### 4. Higher-Order Functions

When a function takes a function argument:
```elm
map : (a -> b) -> List a -> List b
```

Called with `map String.length ["hello"]`:
- `a = String`, `b = Int`
- Result: `map_$_String_Int`

### 5. Partial Application

```elm
add : Int -> Int -> Int
addOne = add 1  -- addOne : Int -> Int
```

The partially applied function creates a closure with known type.

### 6. Kernel Modules

Kernel modules (written in JS) cannot be monomorphized. They remain polymorphic at runtime. The MLIR backend will need to:
- Generate extern declarations for kernel functions
- Handle boxing/unboxing at kernel boundaries

## Work Estimate

| Component | Complexity | Notes |
|-----------|------------|-------|
| Type utilities | Medium | Core substitution/unification |
| MonoType IR | Medium | New AST definitions |
| Collection phase | Low | Find entry points |
| Specialization | High | Main algorithm |
| Expression transform | High | Handle all Expr variants |
| MLIR updates | Medium | Use mono types for codegen |
| Testing | Medium | Property-based tests |
| Edge cases | High | Recursion, HOF, closures |

## Record Representation and Layout

### Runtime Representation (from Heap.hpp)

Records in eco-runtime use this C++ structure:

```cpp
typedef struct {
    Header header;  // Header.size contains field count (max 127)
    u64 unboxed;    // Bitmap: bit N set means field N is unboxed (primitive value)
    Unboxable values[];
} Record;

typedef union {
    HPointer p;  // Pointer to heap object
    i64 i;       // Unboxed integer
    f64 f;       // Unboxed float
    u16 c;       // Unboxed char
} Unboxable;
```

Key characteristics:
- **Field count** stored in `Header.size` (max 127 fields)
- **Unboxed bitmap** is 64 bits, indicating which fields are primitives stored inline
- **Values array** stores all fields as 8-byte `Unboxable` unions
- **Field order**: Unboxed fields first (alphabetically), then boxed fields (alphabetically)

The field ordering strategy places unboxed fields at the start of the values array. This means:
- Unboxed fields occupy indices 0..N-1 (where N = number of unboxed fields)
- Boxed fields occupy indices N..total-1
- The `unboxed` bitmap has bits 0..N-1 set, which is simply `(1 << N) - 1`
- This maximizes use of the 64-bit bitmap, allowing up to 64 unboxed fields + 63 boxed fields = 127 total

### Example: `{ name = "test", age = 23 }`

For record type `{ name : String, age : Int }`:
- `age : Int` is unboxed
- `name : String` is boxed

Field ordering: unboxed first (alphabetically), then boxed (alphabetically):
1. `age` (unboxed) → index 0
2. `name` (boxed) → index 1

```
Memory Layout (32 bytes total):
┌─────────────────────────────────────────┐
│ Header (8 bytes)                        │
│   tag = Tag_Record                      │
│   size = 2 (field count)                │
├─────────────────────────────────────────┤
│ unboxed bitmap (8 bytes)                │
│   = 0b01  (1 unboxed field at index 0)  │
├─────────────────────────────────────────┤
│ values[0]: age (Unboxable)              │
│   .i = 23  (unboxed integer)            │
├─────────────────────────────────────────┤
│ values[1]: name (Unboxable)             │
│   .p = <pointer to ElmString "test">    │
└─────────────────────────────────────────┘
```

### Example: `{ x = 1.5, y = 2.5, label = "point", id = 42 }`

For record type `{ x : Float, y : Float, label : String, id : Int }`:
- Unboxed: `id : Int`, `x : Float`, `y : Float`
- Boxed: `label : String`

Field ordering:
1. `id` (unboxed, alphabetically first) → index 0
2. `x` (unboxed) → index 1
3. `y` (unboxed) → index 2
4. `label` (boxed) → index 3

```
Memory Layout (48 bytes total):
┌─────────────────────────────────────────┐
│ Header (8 bytes)                        │
│   tag = Tag_Record, size = 4            │
├─────────────────────────────────────────┤
│ unboxed bitmap (8 bytes)                │
│   = 0b0111  (3 unboxed fields)          │
├─────────────────────────────────────────┤
│ values[0]: id   = 42       (i64)        │
│ values[1]: x    = 1.5      (f64)        │
│ values[2]: y    = 2.5      (f64)        │
│ values[3]: label = <ptr>   (HPointer)   │
└─────────────────────────────────────────┘
```

The bitmap is simply `(1 << 3) - 1 = 0b0111` since there are 3 unboxed fields.

### Compile-Time Layout Information

The monomorphizer computes a `RecordLayout` for each concrete record type:

```elm
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int            -- Number of unboxed fields (for bitmap calculation)
    , unboxedBitmap : Int           -- Always (1 << unboxedCount) - 1
    , fields : List FieldInfo       -- Ordered: unboxed (alpha) then boxed (alpha)
    }

type alias FieldInfo =
    { name : Name
    , index : Int                   -- Position in values[] array
    , monoType : MonoType
    , isUnboxed : Bool              -- True for Int, Float, Char, Bool
    }

computeRecordLayout : Dict Name MonoType -> RecordLayout
computeRecordLayout fields =
    let
        -- Partition into unboxed and boxed, each sorted alphabetically
        allFields = Dict.toList fields

        (unboxedFields, boxedFields) =
            List.partition (\(_, ty) -> canUnbox ty) allFields

        sortedUnboxed = List.sortBy Tuple.first unboxedFields
        sortedBoxed = List.sortBy Tuple.first boxedFields

        -- Unboxed fields come first, then boxed
        orderedFields = sortedUnboxed ++ sortedBoxed

        -- Assign indices based on this ordering
        indexedFields =
            List.indexedMap (\idx (name, ty) ->
                { name = name
                , index = idx
                , monoType = ty
                , isUnboxed = canUnbox ty
                })
                orderedFields

        unboxedCount = List.length sortedUnboxed

        -- Bitmap is simply the first N bits set, where N = unboxedCount
        -- e.g., 3 unboxed fields -> 0b0111 = (1 << 3) - 1 = 7
        unboxedBitmap =
            if unboxedCount == 0 then
                0
            else
                Bitwise.shiftLeftBy unboxedCount 1 - 1
    in
    { fieldCount = List.length orderedFields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    , fields = indexedFields
    }

canUnbox : MonoType -> Bool
canUnbox monoType =
    case monoType of
        MInt -> True
        MFloat -> True
        MChar -> True
        MBool -> True   -- Stored as i64 (0 or 1)
        _ -> False      -- String, List, Record, Custom, etc. are boxed
```

Note: With this ordering, determining if a field is unboxed at runtime is a simple comparison:
`isUnboxed = (fieldIndex < unboxedCount)` or equivalently `(unboxedBitmap >> fieldIndex) & 1`.

### Extensible Records

Extensible record types like `{ a | name : String }` are resolved during monomorphization:

```elm
-- Polymorphic function
setName : String -> { a | name : String } -> { a | name : String }
setName newName rec = { rec | name = newName }

-- Called with concrete type
person = { name = "test", age = 23 }
result = setName "Alice" person
```

**Unification process:**

1. **Polymorphic type**: `{ a | name : String }` where `a` represents "other fields"
2. **Concrete type at call site**: `{ name : String, age : Int }`
3. **Unification result**: `a` binds to `{ age : Int }`
4. **Resolved type**: `{ age : Int, name : String }` (fully concrete, alphabetically ordered)

```elm
unifyExtensibleRecord :
    Dict Name MonoType      -- required fields: { name : String }
    -> Maybe Name           -- extension variable: a
    -> MonoType             -- concrete: { name : String, age : Int }
    -> Result Error RecordLayout
unifyExtensibleRecord requiredFields maybeExt concreteType =
    case concreteType of
        MRecord allFields ->
            -- 1. Verify all required fields exist with matching types
            let
                requiredOk =
                    Dict.toList requiredFields
                        |> List.all (\(name, ty) ->
                            Dict.get name allFields == Just ty)
            in
            if requiredOk then
                -- 2. Compute full layout from concrete fields
                Ok (computeRecordLayout allFields)
            else
                Err FieldTypeMismatch

        _ ->
            Err ExpectedRecord
```

After monomorphization, **extensible records disappear** - we have only concrete record types with known layouts.

### Monomorphized Record Operations

The `MonoExpr` type carries layout information for record operations:

```elm
type MonoExpr
    = ...
    | MonoRecordCreate
        (List MonoExpr)             -- values in index order
        RecordLayout                -- layout (has bitmap, field count)
        MonoType

    | MonoRecordAccess
        MonoExpr                    -- record expression
        Name                        -- field name (for debugging)
        Int                         -- field index in values[]
        Bool                        -- is this field unboxed?
        MonoType                    -- result type

    | MonoRecordUpdate
        MonoExpr                    -- record being updated
        (List (Int, MonoExpr))      -- (index, new value) pairs
        RecordLayout                -- full layout for allocation
        MonoType
```

### Example: Specialized `setName`

```elm
-- After monomorphization for { name : String, age : Int }
-- Layout: age (unboxed) at index 0, name (boxed) at index 1
setName_$_age_Int_name_String : String -> { age : Int, name : String } -> { age : Int, name : String }
setName_$_age_Int_name_String newName rec =
    MonoRecordUpdate
        (MonoVarLocal "rec" recordType)
        [(1, MonoVarLocal "newName" MString)]  -- Update index 1 (name, boxed)
        { fieldCount = 2
        , unboxedCount = 1
        , unboxedBitmap = 1  -- 0b01 = (1 << 1) - 1
        , fields =
            [ { name = "age",  index = 0, monoType = MInt,    isUnboxed = True }
            , { name = "name", index = 1, monoType = MString, isUnboxed = False }
            ]
        }
        recordType
```

### Example: More complex record update

```elm
-- Function that updates a boxed field in a record with multiple unboxed fields
setLabel : String -> { x : Float, y : Float, label : String, id : Int } -> { ... }
setLabel newLabel rec = { rec | label = newLabel }

-- After monomorphization:
-- Layout: id (index 0), x (index 1), y (index 2) are unboxed; label (index 3) is boxed
setLabel_$_id_Int_x_Float_y_Float_label_String newLabel rec =
    MonoRecordUpdate
        (MonoVarLocal "rec" recordType)
        [(3, MonoVarLocal "newLabel" MString)]  -- Update index 3 (label, boxed)
        { fieldCount = 4
        , unboxedCount = 3
        , unboxedBitmap = 7  -- 0b0111 = (1 << 3) - 1
        , fields =
            [ { name = "id",    index = 0, monoType = MInt,    isUnboxed = True }
            , { name = "x",     index = 1, monoType = MFloat,  isUnboxed = True }
            , { name = "y",     index = 2, monoType = MFloat,  isUnboxed = True }
            , { name = "label", index = 3, monoType = MString, isUnboxed = False }
            ]
        }
        recordType
```

### MLIR Code Generation for Records

```mlir
// setName_$_age_Int_name_String
// Layout: age (unboxed, index 0), name (boxed, index 1)
func.func @"setName_$_age_Int_name_String"(%newName: !eco.value, %rec: !eco.value) -> !eco.value {
    // Allocate new record: Header(8) + unboxed_bitmap(8) + 2 fields(16) = 32 bytes
    %new_rec = "eco.alloc_record"() {
        field_count = 2,
        unboxed_count = 1,
        unboxed_bitmap = 1    // (1 << 1) - 1 = 0b01
    } : () -> !eco.value

    // Copy field 0 (age) - unboxed int at index 0
    %age = "eco.record_get"(%rec) { index = 0, unboxed = true } : (!eco.value) -> i64
    "eco.record_set"(%new_rec, %age) { index = 0, unboxed = true } : (!eco.value, i64) -> ()

    // Set field 1 (name) - boxed pointer at index 1 (the new value)
    "eco.record_set"(%new_rec, %newName) { index = 1, unboxed = false } : (!eco.value, !eco.value) -> ()

    eco.return %new_rec : !eco.value
}

// setLabel_$_id_Int_x_Float_y_Float_label_String
// Layout: id (index 0), x (index 1), y (index 2) unboxed; label (index 3) boxed
func.func @"setLabel_$_..."(%newLabel: !eco.value, %rec: !eco.value) -> !eco.value {
    // Allocate: Header(8) + bitmap(8) + 4 fields(32) = 48 bytes
    %new_rec = "eco.alloc_record"() {
        field_count = 4,
        unboxed_count = 3,
        unboxed_bitmap = 7    // (1 << 3) - 1 = 0b0111
    } : () -> !eco.value

    // Copy all unboxed fields (indices 0, 1, 2)
    %id = "eco.record_get"(%rec) { index = 0, unboxed = true } : (!eco.value) -> i64
    "eco.record_set"(%new_rec, %id) { index = 0, unboxed = true } : (!eco.value, i64) -> ()

    %x = "eco.record_get"(%rec) { index = 1, unboxed = true } : (!eco.value) -> f64
    "eco.record_set"(%new_rec, %x) { index = 1, unboxed = true } : (!eco.value, f64) -> ()

    %y = "eco.record_get"(%rec) { index = 2, unboxed = true } : (!eco.value) -> f64
    "eco.record_set"(%new_rec, %y) { index = 2, unboxed = true } : (!eco.value, f64) -> ()

    // Set the updated boxed field (index 3)
    "eco.record_set"(%new_rec, %newLabel) { index = 3, unboxed = false } : (!eco.value, !eco.value) -> ()

    eco.return %new_rec : !eco.value
}
```

The MLIR operations use the layout information to:
1. Allocate the correct size (header + bitmap + N × 8 bytes)
2. Set the unboxed bitmap in the allocated record (always `(1 << unboxedCount) - 1`)
3. Access/set fields by index, knowing indices < unboxedCount are unboxed

## Design Decisions

This section documents key design decisions made during planning.

### 1. Higher-Order Functions & Lambda Sets

**Decision:** Use lambda sets with full function specialization (no switches).

Instead of one `map` with a switch inside, we generate completely separate specialized versions for each lambda:

```elm
List.map String.length ["hello"]
-- Generates: List_map_$_0  (specialized for String.length)

List.map (\x -> x + 1) [1,2,3]
-- Generates: List_map_$_1  (specialized for this specific lambda)
```

Each specialization is a complete, standalone function with the specific lambda baked in. This enables future inlining optimizations.

**Two levels of specialization available:**

| Level | When to Use |
|-------|-------------|
| Type-only | When lambda set is large, or for simplicity |
| Lambda + Type | When we want inlining potential |

Lambda sets track what's *possible*, but we can choose how aggressively to specialize.

**Data structures:**

```elm
type LambdaId
    = NamedFunction Global
    | AnonymousLambda Int CaptureSet

type alias CaptureSet =
    List ( Name, MonoType )
```

### 2. Recursive Functions

**Decision:** Worklist algorithm with "in progress" markers; forward references allowed.

```elm
processWorklist nodes state =
    case state.worklist of
        (global, concreteType) :: rest ->
            let
                key = toMonoGlobal global concreteType
            in
            if Dict.member key state.specialized then
                -- Already done or in progress
                processWorklist nodes { state | worklist = rest }
            else
                -- Mark as "in progress" before processing body
                stateWithPlaceholder =
                    { state | specialized = Dict.insert key InProgress state.specialized }

                -- Specialize - recursive calls will see InProgress
                (specializedNode, newDeps) = specializeNode node concreteType

                -- Replace with real definition
                ...
```

This handles both direct recursion and mutual recursion without needing SCC detection.

### 3. Polymorphic Recursion

**Decision:** No special handling needed.

Elm uses Hindley-Milner type inference which does not support polymorphic recursion. A recursive function's type is monomorphic within its own body. If code type-checks, recursive calls are always at the same type.

### 4. Kernel Module Boundaries

**Decision:** Defer for now; rely on `eco.value` representation.

Kernel functions work with the polymorphic `!eco.value` representation. No specialized wrappers needed initially.

### 5. Entry Points

**Decision:** Whole-program monomorphization from `main` only.

- Packages are distributed as source code
- `TypedOptimized.GlobalGraph` represents the complete application
- Monomorphization starts from `main` and discovers all reachable specializations
- Ports have concrete types, so no complications

### 6. Specialization Naming

**Decision:** Integer IDs with a registry mapping.

```
<Module>_<function>_$_<id>
```

Examples:
```elm
identity_$_0   -- identity specialized for Int
identity_$_1   -- identity specialized for List String
List_map_$_0   -- map specialized for (String.length, String, Int)
List_map_$_1   -- map specialized for (anon_42, Int, Int)
```

**Registry structure:**

```elm
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict (Global, MonoType, Maybe LambdaId) Int
    }
```

Benefits:
- Short names
- Deterministic (same discovery order → same IDs)
- No escaping issues
- Fast comparison

A debug symbol table maps IDs back to types for debugging.

### 7. Code Size vs. Sharing

**Decision:** Defer; no thresholds or fallbacks for now.

- Elm programs are typically small
- LLVM has identical code folding
- We can add limits later if needed

### 8. Custom Types with Type Parameters

**Decision:** Layout depends on type args; declaration order for fields; no sharing of nullary constructors.

```elm
type alias CustomLayout =
    { typeName : Global
    , typeArgs : List MonoType
    , constructors : List CtorLayout
    }

type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo  -- Declaration order preserved
    , unboxedCount : Int
    , unboxedBitmap : Int
    }
```

`Maybe Int` and `Maybe String` have different layouts because unboxing differs. Each specialization has its own `Nothing` constructor (no sharing).

### 9. Type Classes (comparable, appendable, number)

**Decision:** No special handling needed.

These constraints are enforced during type checking. By the time we reach `TypedOptimized`, concrete types are already resolved. The constraints have served their purpose and are gone.

### 10. Incremental Compilation

**Decision:** No mono-level caching; run fresh each build.

- `.guidato` files cache `TypedOptimized.LocalGraph`
- Monomorphization runs fresh on each build
- Elm programs are small enough that this should be fast
- Can revisit if it becomes a bottleneck

## Testing Strategy

1. **Unit tests**: Type substitution, unification
2. **Property tests**: Specialized code preserves semantics
3. **Integration tests**: Full compilation pipeline
4. **Benchmark tests**: Verify performance improvements

## References

- [Better Defunctionalization through Lambda Set Specialization](https://dl.acm.org/doi/10.1145/3591260) (PLDI 2023)
- [Roc Compiler Design](https://github.com/roc-lang/roc/blob/main/crates/compiler/DESIGN.md)
- [Rust Monomorphization Guide](https://rustc-dev-guide.rust-lang.org/backend/monomorph.html)
- [How Roc Compiles Closures](https://www.rwx.com/blog/how-roc-compiles-closures)
- [WITS 2024: Type-directed defunctionalization](https://popl24.sigplan.org/details/wits-2024-papers/3/)
